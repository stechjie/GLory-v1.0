"""服务控制：全局维护开关、关闭排位与休闲匹配，以及「谁正在对局中」的服务端账。

需求来源 docs/后台功能完善_核对结论_20261012.md 的 OPS-05；表在 database/035_service_control.sql。

## 这个模块的两件事

1. **开关状态**（`read` / `save`）—— 管理员设的意图，单行表 + 版本号乐观并发。
2. **入场登记**（`record_entry` / `clear_match` / `players_in_match`）——
   服务器自己签发名片的记录。维护时「谁能留下」只认它，理由见 035 的长注释：
   admission 的 RESUME 和 player_presence.in_match **都是客户端自报的**，
   拿它们当准入依据等于白送一个人人可用的绕过口。

## 🔴 三种「读不到」，处理方式完全不同

| 情况 | source | 怎么办 | 为什么 |
| --- | --- | --- | --- |
| 表不存在（035 没跑） | `absent` | **放行一切** | 表没建 = 维护从来没开过。按「拒绝」处理的话，一次部署顺序失误 = 全服停服。034 漏跑那次已经演示过代价 |
| 数据库这一下读失败，但缓存还新鲜 | `cache` | 按缓存值判 | 抖一下不该改变准入结论 |
| 读失败且没有可用缓存 | `unknown` | **拒绝新准入** | 任务书 §七.2 末尾：无法确定准入状态时拒绝新开局，不能假装正常 |

区分「表不存在」和「读失败」是本模块最要紧的一个判断，别合并。

## 缓存为什么可以这么短

`app/single_instance.py` 把 ② 钉死成单进程单实例，所以后台改完开关可以
**当场把本进程的缓存作废**（`invalidate`），不用等 TTL。
TTL 只是用来吸收读压力的兜底，不是状态传播的手段 ——
任务书 §七.3.5 要求「新准入必须按权威状态即时拒绝」，靠的是 invalidate 那条路。
"""

from __future__ import annotations

import asyncio
import dataclasses
import json
import logging
import pathlib
import time
import uuid

from app import db

log = logging.getLogger("glory.service_control")

# 缓存新鲜期。读失败时还能拿它顶多久，见 _STALE_GRACE_SEC。
_CACHE_TTL_SEC = 3.0

# 读失败后，缓存值还能继续用多久。超过就降级成 unknown（拒绝新准入）。
# 取 60 秒：数据库抖一下通常几秒内恢复；真的挂了一分钟以上，宁可停新准入也不要
# 在「其实正在维护」的时候继续放人进来。
_STALE_GRACE_SEC = 60.0

# 入场登记多久算陈旧。超过它就当这局已经结束（战报丢了 / 对局崩了 / 领了名片没去）。
# 🔴 这个值偏大是刻意的：判错方向的代价不对称 ——
#   · 判得太短 = 把还在打的人当成在大厅，维护时**踢掉正在打的人**（任务书 P0 明令禁止）
#   · 判得太长 = 某人维护时多留了一会儿，下次他自己退出就没了
# 所以宁可长。正常结束走战报删行，根本轮不到它。
MATCH_ENTRY_MAX_AGE_SEC = 45 * 60


# --- 读 -----------------------------------------------------------------------

# 模块常量而不是内联字符串：backend/app/schema_check.py 会把它们原样拿去 prepare，
# 这样「代码要的列」和「自检要的列」不可能漂移。加列时改这里一处就够。
_READ_STATE = """
select version, maintenance_enabled, matchmaking_enabled,
       maintenance_notice_zh, maintenance_notice_en,
       matchmaking_notice_zh, matchmaking_notice_en,
       expected_back_at, change_reason, actor, changed_at
from service_control where only_row
"""

_RECORD_ENTRY = """
insert into match_entries (player_id, match_uid, entered_at)
values ($1, $2, now())
on conflict (player_id) do update
  set match_uid = excluded.match_uid, entered_at = excluded.entered_at
"""

_PLAYERS_IN_MATCH = "select player_id from match_entries where entered_at > now() - ($1::double precision * interval '1 second')"

_CLEAR_MATCH = "delete from match_entries where match_uid = $1 and match_uid <> ''"

_CLEAR_PLAYER = "delete from match_entries where player_id = $1"

_SWEEP_ENTRIES = "delete from match_entries where entered_at <= now() - ($1::double precision * interval '1 second')"


@dataclasses.dataclass(frozen=True)
class State:
    """一次读到的开关状态。`source` 说明这份数据是从哪来的，见模块头的表。"""

    maintenance: bool = False
    matchmaking: bool = True
    maintenance_notice_zh: str = ""
    maintenance_notice_en: str = ""
    matchmaking_notice_zh: str = ""
    matchmaking_notice_en: str = ""
    expected_back_at: object = None
    change_reason: str = ""
    actor: str = ""
    changed_at: object = None
    version: int = 0
    source: str = "absent"


# 表不存在时的状态。注意 source="absent" —— 它和 unknown 的判定结果完全相反。
ABSENT = State(source="absent")
UNKNOWN = State(source="unknown")

_cache: State | None = None
_cache_at: float = 0.0
# 建过表之后就记住，省得每次读都判一遍错误类型。重启会重新探。
_table_seen = False


def invalidate() -> None:
    """让本进程的缓存立刻失效。后台写完开关必须调它 —— 这是状态「即时生效」那条路。"""
    global _cache, _cache_at
    _cache = None
    _cache_at = 0.0


def reset() -> None:
    """测试用：把模块恢复到刚导入的样子。"""
    global _table_seen
    invalidate()
    _table_seen = False


def _is_missing_table(exc: BaseException) -> bool:
    """这个异常是不是「表还不存在」。

    不 import asyncpg 的异常类来 isinstance —— 测试里用的是替身连接，
    抛的不是真的 asyncpg 异常。认 SQLSTATE 42P01（undefined_table）最稳，
    asyncpg 和 psycopg 都把它放在 .sqlstate / .pgcode 上。
    """
    code = getattr(exc, "sqlstate", None) or getattr(exc, "pgcode", None)
    if code == "42P01":
        return True
    # 替身或驱动没给 SQLSTATE 时的退路：认消息里的「relation ... does not exist」。
    # 宁可认成「表不存在」而放行，也不要把一次认不出的异常变成全服停服
    # —— 理由同模块头那张表。
    text = str(exc).lower()
    return "does not exist" in text and ("relation" in text or "table" in text)


async def read() -> State:
    """读当前状态。**自己不抛异常**，所有失败都折进 State.source。"""
    global _cache, _cache_at, _table_seen
    now = time.monotonic()
    if _cache is not None and now - _cache_at < _CACHE_TTL_SEC:
        return _cache
    if not db.is_connected():
        return _fallback("数据库还没连上")
    try:
        row = await db.pool().fetchrow(_READ_STATE)
    except Exception as exc:  # noqa: BLE001 - 失败类型决定放行还是拒绝，不能让它冒出去
        if not _table_seen and _is_missing_table(exc):
            # 035 还没跑。这不是故障，是功能还没部署。
            return ABSENT
        log.warning("读服务控制状态失败：%s", exc, exc_info=True)
        return _fallback(str(exc))
    _table_seen = True
    if row is None:
        # 表在但那唯一一行没了（有人手删过）。当成「没开任何开关」，别拦人。
        log.warning("service_control 表里没有那一行，当作全部关闭处理")
        state = State(source="db")
    else:
        state = State(
            maintenance=bool(row["maintenance_enabled"]),
            matchmaking=bool(row["matchmaking_enabled"]),
            maintenance_notice_zh=row["maintenance_notice_zh"],
            maintenance_notice_en=row["maintenance_notice_en"],
            matchmaking_notice_zh=row["matchmaking_notice_zh"],
            matchmaking_notice_en=row["matchmaking_notice_en"],
            expected_back_at=row["expected_back_at"],
            change_reason=row["change_reason"],
            actor=row["actor"],
            changed_at=row["changed_at"],
            version=int(row["version"]),
            source="db",
        )
    _cache = state
    _cache_at = now
    return state


def _fallback(why: str) -> State:
    """读失败时拿缓存顶一阵；顶不住就降级成 unknown（拒绝新准入）。"""
    if _cache is not None and time.monotonic() - _cache_at < _STALE_GRACE_SEC:
        return dataclasses.replace(_cache, source="cache")
    log.error("拿不到服务控制状态且无可用缓存，按「拒绝新准入」处理：%s", why)
    return UNKNOWN


# --- 闸（纯函数，不碰数据库，便于单测）------------------------------------------

def allows_new_entry(state: State) -> bool:
    """能不能放一个**新**玩家进游戏。已经在对局里的人不走这道闸。"""
    if state.source == "absent":
        return True
    if state.source == "unknown":
        return False
    return not state.maintenance


def allows_matchmaking(state: State) -> bool:
    """能不能开始排队 / 接受匹配 / 开新局。

    🔴 维护优先级高于关闭匹配（任务书 §七.2）：维护中时匹配一定也是关的，
    但这**不改**数据库里 matchmaking_enabled 的值 —— 解除维护不能顺带把
    之前单独关掉的匹配打开。
    """
    if state.source == "absent":
        return True
    if state.source == "unknown":
        return False
    return state.matchmaking and not state.maintenance


def entry_block_reason(state: State) -> str:
    """新准入被挡住的原因码。空串 = 没被挡。给客户端认的稳定错误码。"""
    if allows_new_entry(state):
        return ""
    return "service_unavailable" if state.source == "unknown" else "service_maintenance"


def matchmaking_block_reason(state: State) -> str:
    """匹配被挡住的原因码。空串 = 没被挡。

    维护与单独关匹配分成两个码：客户端要显示的话不一样
    （「游戏正在维护」vs「排位功能暂时关闭」），而且清理队列时
    任务书 §七.3.6 要求用独立原因码，不能复用带玩家责任的拒绝 / 逃跑路径。
    """
    if allows_matchmaking(state):
        return ""
    if state.source == "unknown":
        return "service_unavailable"
    return "service_maintenance" if state.maintenance else "matchmaking_disabled"


# WebSocket 关闭码。沿用 bans.CLOSE_BANNED(4003) 那一串，往下取一个。
# 🔴 **必须和认证失败（1008）区分开**（任务书 §二.8）：认证失败会让客户端清凭证重来，
# 而维护是暂时的 —— 清了凭证的人维护完还得重新注册一个号。同 403 不是 401 的道理。
CLOSE_MAINTENANCE = 4004

MESSAGE_TYPE = "service"


def maintenance_message(state: State) -> dict:
    """关连接之前先说清楚为什么。先发消息再关的理由同 realtime._close：
    只给一个关闭码的话，弱网下客户端多半来不及读，会当成普通掉线一直重连。
    """
    return {"t": MESSAGE_TYPE, "state": "maintenance",
            "code": entry_block_reason(state) or "service_maintenance",
            "notice_zh": state.maintenance_notice_zh,
            "notice_en": state.maintenance_notice_en,
            "expected_back_at": state.expected_back_at.isoformat() if state.expected_back_at else None}


def push_message(state: State) -> dict:
    """开关变了，主动推给所有在线玩家的那条消息。

    内容就是 `public_view` 那几个公开字段，外加一个 `t` 让客户端认得出来。
    **不含** actor / change_reason —— 那是内部信息。

    客户端拿到它就能立刻弹维护提示，不用等轮询（任务书 §七.3.5）。
    🔴 发它必须用 `hub.broadcast`（内部 gather + 每条超时），
    绝不能自己 for 循环 await `hub.send` —— 那正是 2026-10-11 把账号服务器
    搞卡的写法：一个卡死的 socket 就能拖住全部。
    """
    return {"t": MESSAGE_TYPE, "state": "switches", **public_view(state)}


def public_view(state: State) -> dict:
    """发给客户端的公开字段。**不含** actor / change_reason —— 那是内部信息。"""
    return {
        "maintenance": not allows_new_entry(state),
        "matchmaking": allows_matchmaking(state),
        "notice_zh": state.maintenance_notice_zh if state.maintenance else state.matchmaking_notice_zh,
        "notice_en": state.maintenance_notice_en if state.maintenance else state.matchmaking_notice_en,
        "expected_back_at": state.expected_back_at.isoformat() if state.expected_back_at else None,
        "version": state.version,
    }


# --- 入场登记 ------------------------------------------------------------------

async def record_entry(player_id: uuid.UUID, match_uid: str = "") -> None:
    """签发名片时记一笔：服务器亲手放了这个人进这一局。

    **绝不因为自己失败而挡住发名片** —— 登记不上最坏的结果是维护时这个人被当成
    在大厅，而发不出名片是他现在就进不去。两害相权，这里只记日志。
    """
    if not db.is_connected():
        return
    try:
        await db.pool().execute(_RECORD_ENTRY, player_id, (match_uid or "")[:40])
    except Exception:  # noqa: BLE001
        log.warning("入场登记写失败 player=%s match=%s", player_id, match_uid, exc_info=True)


async def clear_match(match_uid: str) -> int:
    """这一局的战报到了，把它那几个人从名册里删掉。返回删了几行。"""
    if not match_uid or not db.is_connected():
        return 0
    try:
        status = await db.pool().execute(_CLEAR_MATCH, match_uid[:40])
        return db.affected_rows(status)
    except Exception:  # noqa: BLE001
        log.warning("清理入场登记失败 match=%s", match_uid, exc_info=True)
        return 0


async def clear_player(player_id: uuid.UUID) -> None:
    """这个人明确退出对局了（主动退出 / 判负），把他从名册里拿掉。"""
    if not db.is_connected():
        return
    try:
        await db.pool().execute(_CLEAR_PLAYER, player_id)
    except Exception:  # noqa: BLE001
        log.warning("清理入场登记失败 player=%s", player_id, exc_info=True)


# 战斗服务器那份名册多久没刷新就算陈旧。它每 5 秒写一次，给 6 次的余量。
ROSTER_MAX_AGE_SEC = 30.0

# 名册新鲜时，入场登记只再多算这么久 —— 覆盖「刚领到名片、还在连战斗服务器」
# 的那一小撮人：他们还没进任何房间，所以不在名册上，但确实不该被踢。
# 名片本身只活 60 秒，加上加载时间，两分钟足够。
CONNECTING_GRACE_SEC = 120.0


def _read_battle_roster(path: str, now: float | None = None) -> set[uuid.UUID] | None:
    """读战斗服务器写的那份名册。返回 None = 没配 / 读不到 / 太旧 / 形状不对。

    **自己不抛异常**，任何问题都返回 None 让调用方退回启发式 ——
    这个文件是来提高精度的，不该成为新的故障源。
    """
    if not path:
        return None
    try:
        raw = pathlib.Path(path).read_text(encoding="utf-8")
        data = json.loads(raw)
        if not isinstance(data, dict) or int(data.get("protocol", 0)) != 1:
            return None
        age = (time.time() if now is None else now) - float(data.get("generated_at", 0.0))
        if age > ROSTER_MAX_AGE_SEC or age < -ROSTER_MAX_AGE_SEC:
            # 太旧 = 战斗服务器多半挂了或没配；太「新」= 两台机器的钟对不上，
            # 两种都不能信。退回启发式，宁可少踢几个人。
            log.warning("对局名册不新鲜（差 %.1f 秒），这一次退回入场登记", age)
            return None
        out: set[uuid.UUID] = set()
        for item in data.get("pids", []):
            try:
                out.add(uuid.UUID(str(item)))
            except (ValueError, AttributeError, TypeError):
                continue   # 一个坏值不该让整份名册作废
        return out
    except FileNotFoundError:
        return None
    except Exception:  # noqa: BLE001
        log.warning("读对局名册失败，这一次退回入场登记：%s", path, exc_info=True)
        return None


def _configured_roster_path() -> str:
    """名册文件路径。读配置而不是让每个调用点自己传 —— 漏传一处就是
    「那条路上悄悄退回了粗判」，而且不会报错。"""
    try:
        from app.config import get_settings

        return get_settings().battle_match_roster_file.strip()
    except Exception:  # noqa: BLE001 - 配置读不出来不该让维护判断整个失效
        return ""


async def players_in_match(roster_path: str | None = None) -> set[uuid.UUID] | None:
    """此刻不该被维护踢掉的人。返回 None = 读不出来（调用方必须按「谁都别踢」处理）。

    🔴 返回 None 和返回空集合是两回事，别让调用方把它们混在一起：
    空集合 = 确实没人在打，可以全踢；None = 不知道，一个都不能踢。

    两个来源，精度不同：

      1. **战斗服务器的名册**（权威）—— 它知道哪些房间真的在打。
         新鲜时用它，再并上「最近 2 分钟领过名片」的人（那些人还在连，
         还没进房间，所以不在名册上，但同样不该被踢）。
      2. **入场登记**（启发式）—— 名册读不到时的退路：「45 分钟内领过名片」。
         粗，但方向是安全的那一边（宁可多留几个人，也不踢掉正在打的）。
    """
    if not db.is_connected():
        return None
    roster = _read_battle_roster(
        _configured_roster_path() if roster_path is None else roster_path)
    window = CONNECTING_GRACE_SEC if roster is not None else float(MATCH_ENTRY_MAX_AGE_SEC)
    try:
        rows = await db.pool().fetch(_PLAYERS_IN_MATCH, window)
    except Exception:  # noqa: BLE001
        log.warning("读入场登记失败，按「谁都别踢」处理", exc_info=True)
        # 名册读到了就还能用它顶，只是少了正在连的那一小撮。
        return roster
    entries = {r["player_id"] for r in rows}
    return entries if roster is None else (roster | entries)


async def kick_lobby_players() -> dict:
    """维护刚打开：把**不在对局里**的人请出去（2026-10-12 用户拍板）。

    🔴 两条纪律，都是 2026-10-11 把账号服务器搞卡之后定下来的，别改：

      1. **名单一次性查完，查完立刻放掉数据库连接。** 绝不在握着连接的时候
         await 任何发送 —— 那次就是握着连接串行 await 无超时的 Hub.send，
         一个卡死的 socket 就把连接池耗干，整个账号服务器停止响应。
      2. **并发发、每条都有超时。** `hub.disconnect_player` 内部走的是
         `_send_bounded`（asyncio.wait_for），所以这里 gather 是安全的；
         但仍要 return_exceptions=True —— 一条炸了不能带走其余的。

    读不到名册就**一个都不踢**：把正在打的人踢掉违反那条 P0，
    而少踢几个大厅玩家只是维护慢一点生效。
    """
    from app import realtime  # 局部导入：避免 realtime ←→ service_control 兜圈子

    in_match = await players_in_match()
    if in_match is None:
        log.error("维护已打开，但读不到入场名册 —— 这一轮一个都不踢，等下一次切换再试")
        return {"kicked": 0, "skipped": 0, "aborted": True}

    hub = realtime.hub()
    # 到这里为止不再碰数据库。下面只动内存与 socket。
    targets = [pid for pid in hub.player_ids() if pid not in in_match]
    if not targets:
        return {"kicked": 0, "skipped": len(in_match), "aborted": False}

    payload = {"t": MESSAGE_TYPE, "state": "maintenance", "code": "service_maintenance"}
    results = await asyncio.gather(
        *(hub.disconnect_player(pid, CLOSE_MAINTENANCE, payload) for pid in targets),
        return_exceptions=True)
    kicked = sum(r for r in results if isinstance(r, int))
    for r in results:
        if isinstance(r, BaseException):
            log.warning("维护踢人时有一条出错：%s", r)
    log.info("维护踢人：断开 %d 条连接，放过对局中的 %d 人", kicked, len(in_match))
    return {"kicked": kicked, "skipped": len(in_match), "aborted": False}


async def sweep_entries() -> int:
    """扫掉陈旧的入场登记。由 app/maintenance.py 的定时清理调。

    没有它这张表只增不减，而且陈旧行会让维护时永远踢不掉那些人。
    """
    if not db.is_connected():
        return 0
    try:
        status = await db.pool().execute(_SWEEP_ENTRIES, float(MATCH_ENTRY_MAX_AGE_SEC))
    except Exception:  # noqa: BLE001
        log.warning("清理陈旧入场登记失败", exc_info=True)
        return 0
    return db.affected_rows(status)
