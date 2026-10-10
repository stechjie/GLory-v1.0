"""在线状态的读写（player_presence）。

配套：database/005_friends.sql、docs/交友系统设计.md 第二节。

**读**在 friends.py 里（好友列表一次 join 把 presence 带出来），
这里只有写：心跳与两个可见性开关。分成两个模块是因为读永远是「好友列表的一部分」，
单独提供一个「查某人在不在线」的接口反而会变成探测器。

## 这一层的全部安全边界：room_id 是客户端自报的

谎报的后果只是让好友进错房间，而房间号本来就是任何人知道号就能进
（NetworkService.team_request_join_room）—— 没有新增攻击面。

⚠️ **这条边界只对「说谎没有收益」的数据成立。**
战绩、排行、奖励一律不能建在这张表上。要做那些，只能等 ②↔③ 通道
（docs/账号系统RFC.md 9.2，未拍板）。
"""

from __future__ import annotations

import asyncio
import datetime as dt
import logging
import uuid

from app import db, friends, realtime

log = logging.getLogger("glory.presence")

VISIBILITIES = frozenset({"friends", "nobody"})

# 房间号由 shard * SHARD_ID_STRIDE + 六位随机组成
# （scripts/multiplayer/NetworkConfig.gd），恒为正。
# 上界给得很松：它只是挡住明显的垃圾值，不是业务校验 ——
# 真正的门是「房间号本来就公开可进」。
MAX_ROOM_ID = 1_000_000_000


class PresenceRejected(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


async def heartbeat(player_id: uuid.UUID, room_id: int | None, in_match: bool = False) -> None:
    """一次心跳。room_id 为 None = 在线但不在房间（主菜单等）。

    in_match（10.11 bug 第 3/9 条）= 这名玩家**正在一局对局里**，由他自己的客户端上报。
    好友列表靠它显示「对局中」、把邀请按钮变灰并按「可邀请 → 对局中 → 离线」排序。
    与 room_id 同一个信任级别（客户端自报、谎报无收益），见 database/032 的长注释。
    默认 False 是为了**旧客户端**：不带这个字段的心跳仍旧写得进来（整份覆盖成「不在对局中」）。

    **upsert 而不是「先查再插」**：心跳是这套系统里唯一的高频写，
    多一次往返就是多一倍成本，而且两段式在并发下还会撞主键。

    可见性开关**不在这里写** —— on conflict 只更新 last_seen_at 和 room_id。
    心跳顺手覆盖开关的话，玩家设的「隐身」会被下一次心跳冲掉，
    而这个 bug 不报错，只表现为「设置没保存」。
    """
    if room_id is not None and not (0 < room_id <= MAX_ROOM_ID):
        raise PresenceRejected("bad_room_id", "房间号不合法")
    async with db.pool().acquire() as conn:
        # 一条语句同时做两件事：写心跳，并把**改之前**的房间号带回来。
        #
        # CTE 里的 prev 读的是同一个快照，所以拿到的是更新前的值 ——
        # 用 `returning` 拿不到（那返回的是更新后的行）。
        # 分成「先 select 再 upsert」两次往返也行，但心跳是这套系统里
        # 唯一的高频写，能一次做完就别做两次。
        # prev 现在多带三样（都是**改之前**的值，同一个快照）：
        #   last_seen_at              判「是不是刚上线」—— 上一拍超过 TTL 就是刚上线。
        #                             null = 压根没有这一行，也是刚上线
        #   presence/room_visibility  推送要照搬拉取那边的隐私规则，见 _notify_watchers。
        #                             心跳的 on conflict 不碰这两列，所以 prev 的值就是现值
        #   friend_code               推送的收件人按好友码认人（客户端列表是按它建的）
        #   in_match（032）            改**之前**的对局标记 —— should_notify 靠它判「进/出对局了」
        #
        # ⚠️ 最终 select **从 players 出发 left join prev**，不是直接 select prev ——
        # 第一次心跳时 prev 是空集，`select ... from prev` 整行返回 None，
        # 那恰好就是「刚上线」这个最该推的时刻，friend_code 却拿不到了。
        row = await conn.fetchrow(
            """
            with prev as (
                select room_id, last_seen_at, presence_visibility, room_visibility, in_match
                from player_presence where player_id = $1
            ), upsert as (
                insert into player_presence (player_id, last_seen_at, room_id, in_match)
                values ($1, now(), $2, $3)
                on conflict (player_id) do update
                  set last_seen_at = now(), room_id = excluded.room_id,
                      in_match = excluded.in_match
            )
            select p.friend_code, prev.room_id, prev.last_seen_at,
                   prev.presence_visibility, prev.room_visibility, prev.in_match
            from players p left join prev on true
            where p.player_id = $1
            """,
            player_id,
            room_id,
            in_match,
        )
        previous = row["room_id"] if row is not None else None
        if previous != room_id:
            await _record_room_transition(conn, player_id, previous, room_id)
        if should_notify(row, room_id, in_match):
            await _notify_watchers(conn, player_id, room_id, row, in_match)


# 在线状态变化的推送事件名。客户端在 RealtimeService 上按这个字段分发。
PRESENCE_EVENT = "presence"


def _stale(last_seen: dt.datetime | None) -> bool:
    """上一拍是不是已经算离线了。TTL 用 friends 那一份，**不另定义一个** ——
    两份 TTL 一定会分叉，而分叉的症状是「推说上线了、拉回来还是离线」。
    """
    if last_seen is None:
        return True
    return dt.datetime.now(dt.timezone.utc) - last_seen >= friends.PRESENCE_TTL


def should_notify(row, room_id: int | None, in_match: bool = False) -> bool:
    """这一拍要不要推在线状态（docs/交友系统设计.md 第二节「推上线、轮询兜下线」）。

    `row` 是心跳**之前**那一行的快照；`last_seen_at` 为 None = 这人第一次心跳。
    判定是纯的，所以抽出来让用例直接钉 —— 这里要钉死的不是「算得对」，
    而是下面这条：

    🔴 **只在跳变时推，不是每次心跳都推。** 心跳 10 秒一拍，无条件推等于把一个
    事件系统变成一个**更贵的**轮询（还被扇出放大了一遍）。所以「还在线、房间也
    没换、对局状态也没变」这一拍必须返回 False。

    三种跳变：
      刚上线   上一拍压根没有，或者 last_seen_at 已经超过 TTL（= 上一拍算离线）
      换房间   房间号和上一拍不同
      进/出对局（032）in_match 和上一拍不同 —— 好友列表上的「对局中」要跟得上，
                        而它在一局里只翻两次（开打、打完），不是高频事件

    ⚠️ **「下线」不在这里，也不可能在这里** —— 它没有事件可挂：进程被杀、网断了，
    客户端不会发「我下线了」。离线是 friends._online 按 TTL 推算的，所以客户端那边
    保留一个慢轮询兜它。要把下线也做成即时，就得加一个扫 last_seen_at 的后台循环，
    而那需要给 last_seen_at 建索引 —— 005_friends.sql 是**刻意不建**的（每次心跳
    都要维护的索引压在全系统最热的写上）。这个取舍没变。
    """
    if row is None or row["last_seen_at"] is None:
        return True
    if _stale(row["last_seen_at"]):
        return True
    if row["room_id"] != room_id:
        return True
    return bool(row["in_match"]) != bool(in_match)


def _hub() -> realtime.Hub:
    """**每次现取** —— 测试会换掉它。同 mail.push_to_player / announcements.hub_broadcast。"""
    return realtime.hub()


async def _notify_watchers(conn, player_id: uuid.UUID, room_id: int | None, row,
                           in_match: bool = False) -> None:
    """把「我上线了 / 我换房间了 / 我进对局了」推给在线的好友。

    🔴 **隐私规则必须和拉取那条路一致**（friends.list_friends 那两行）：
      presence_visibility != 'friends'  -> 一个字都不推。隐身的人不该因为多了一条
                                          推送通道就被看见 —— 那是把开关悄悄作废
      room_visibility     != 'friends'  -> 推「在线」但不带房间号，也**不带 in_match**。
                                          in_match 与 room_id 同属「房间状态」：
                                          「我在打」和「我在 12345 号房」泄漏的是同一类
                                          东西（在做什么），所以同一个开关管。
                                          拉取那条路（friends._in_match_visible）同口径。

    推送失败不抛：它是**锦上添花**，客户端那边还有慢轮询兜底。为了一条推没发出去
    让心跳接口返回 500，是拿主路径给旁路赔命。
    """
    if row is None:
        return
    # 第一次心跳时 prev 侧全是 null，而那一行刚被 insert 成默认值（两个都是 'friends'）。
    presence_visible = (row["presence_visibility"] or "friends") == "friends"
    room_visible = (row["room_visibility"] or "friends") == "friends"
    if not presence_visible:
        return
    payload = {
        "t": PRESENCE_EVENT,
        "friend_code": row["friend_code"],
        "online": True,
        "room_id": room_id if room_visible else None,
        "in_match": bool(in_match) if room_visible else False,
    }
    # 查好友用调用方那条连接（本地、快、没有风险）。**发送绝不在这里 await** ——
    # 理由见 _fan_out 顶部那段 🔴。
    try:
        watchers = await friends.presence_watchers(conn, player_id)
    except Exception:  # noqa: BLE001 - 推送是旁路，不许影响心跳本身
        log.warning("在线状态推送：查好友失败 player=%s", player_id, exc_info=True)
        return
    if watchers:
        _spawn(_fan_out(watchers, payload, player_id))


# _spawn 起的发送任务。事件循环只弱引用任务，不留一份就可能还没跑完就被回收。
# 同 matchmaking._background。
_background: set[asyncio.Task] = set()


def _spawn(coro) -> None:
    """把推送排进事件循环，**不等它**。没有事件循环（同步测试）就不发。

    同 matchmaking._spawn。
    """
    try:
        task = asyncio.get_running_loop().create_task(coro)
    except RuntimeError:
        coro.close()
        return
    _background.add(task)
    task.add_done_callback(_background.discard)


async def _fan_out(watchers: list[uuid.UUID], payload: dict, player_id: uuid.UUID) -> None:
    """把一条在线状态推给这些人。

    🔴 **这个函数绝不能在心跳的请求里被 await，也绝不能串行发。**
    2026-10-08 线上事故就是这么来的：原实现在 `async with db.pool().acquire()` 里
    串行 `await hub.send_to_player(...)`，而 `realtime.Hub.send()` **没有超时**
    （只有 broadcast / publish 才包 `_send_bounded`，那两处的注释写得很清楚：
    「一条卡住的连接（手机进了隧道、TCP 还没断）不能让排在后面的几百个人收不到」）。
    于是只要有一个好友的 TCP 发送缓冲塞住：
      · 那个人的心跳请求**挂住不返回**
      · 而且**一直占着一条数据库连接**
    心跳是 10 秒一次、每个在线玩家都在发 —— 连接池很快被占满，
    **整个账号服务器停止响应**（登录、好友、组队、匹配一起卡）。
    `try/except` 挡不住这种情况：卡住不是异常。

    所以这里有三道：**后台任务**（心跳不等）、**并发**（互不挡）、**每条有超时**。
    """
    hub = _hub()
    timeout = realtime.BROADCAST_SEND_TIMEOUT_SEC

    async def one(watcher_id: uuid.UUID) -> None:
        try:
            await asyncio.wait_for(hub.send_to_player(watcher_id, payload), timeout)
        except TimeoutError:
            log.info("在线状态推送超时 watcher=%s", watcher_id)
        except Exception:  # noqa: BLE001 - 一条发不出去不该影响其他人
            log.warning("在线状态推送失败 watcher=%s", watcher_id, exc_info=True)

    try:
        await asyncio.gather(*(one(w) for w in watchers))
    except Exception:  # noqa: BLE001 - 后台任务，异常只能记日志
        log.warning("在线状态扇出失败 player=%s", player_id, exc_info=True)


async def _record_room_transition(
    conn, player_id: uuid.UUID, previous: int | None, current: int | None
) -> None:
    """房间号变了才写访问记录。**不是每次心跳都写。**

    心跳 10 秒一次，逐条记录等于每个在线玩家每分钟六行；
    只记进出的话，一局对战只产生一行。

    ⚠️ 闭合上一段用 `left_at is null` 而不是取最新一行：客户端崩溃、
    进程被杀、重连换房 —— 这些都会留下未闭合的记录，
    而查询侧一律用 coalesce(left_at, now())，所以留着不致命，
    但同一个玩家不该有两条同时开着的。这里一次把该玩家所有未闭合的都闭上。
    """
    if previous is not None:
        await conn.execute(
            """
            update player_room_visits set left_at = now()
            where player_id = $1 and left_at is null
            """,
            player_id,
        )
    if current is not None:
        await conn.execute(
            "insert into player_room_visits (player_id, room_id) values ($1, $2)",
            player_id,
            current,
        )


async def set_visibility(
    player_id: uuid.UUID, presence_visibility: str, room_visibility: str
) -> dict:
    """两个开关一起写。整份覆盖，不是打补丁。

    分成两个开关的理由：「在不在线」和「在哪个房间」泄漏的东西不是一回事 ——
    后者是行为轨迹。已确认在线状态**只对好友可见**，所以没有 'public' 档。
    """
    for value in (presence_visibility, room_visibility):
        if value not in VISIBILITIES:
            raise PresenceRejected(
                "bad_visibility", "可见性只能是 %s" % " / ".join(sorted(VISIBILITIES))
            )
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(
            """
            insert into player_presence (player_id, presence_visibility, room_visibility)
            values ($1, $2, $3)
            on conflict (player_id) do update
              set presence_visibility = excluded.presence_visibility,
                  room_visibility     = excluded.room_visibility
            returning presence_visibility, room_visibility
            """,
            player_id,
            presence_visibility,
            room_visibility,
        )
    return {
        "presence_visibility": row["presence_visibility"],
        "room_visibility": row["room_visibility"],
    }


async def get_visibility(player_id: uuid.UUID) -> dict:
    """没有行时返回默认值，而不是 404 —— 没上报过心跳是完全正常的状态
    （新玩家第一次打开设置页就是这样），不该让界面处理一个特例。
    """
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(
            "select presence_visibility, room_visibility from player_presence where player_id = $1",
            player_id,
        )
    if row is None:
        return {"presence_visibility": "friends", "room_visibility": "friends"}
    return {
        "presence_visibility": row["presence_visibility"],
        "room_visibility": row["room_visibility"],
    }
