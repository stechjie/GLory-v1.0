"""世界频道（docs/聊天系统设计.md 批次 E，database/019_world_chat.sql）。

## 收发两条路

  发：`POST /v1/world/messages`（routes/world.py）。走 HTTP 的理由同私聊：要一个绑在这次请求上的
      明确答复 —— 发出去了 / 太快了 / 被禁言 / 文字不合规。
  收：WebSocket 推送 {"t": "world", ...}，**只推给正开着世界页签的人**（客户端发
      {"t": "sub", "topic": "world"}，关掉页签发 unsub，见 routes/ws.py）。对局中、停在别的界面的人
      一个字节都不收；服务器每条消息也只发给真正在看的人。
  打开页签先拉最近 RING_SIZE 条垫底（进程内，不查库）；往上翻才查库，最远到 RETENTION_DAYS 天前。

## 进程内这 100 条

  重启时从库里补回来（warm）。不补的话每次部署完频道都是空的 —— 空白界面在玩家眼里就是坏了
  （设计文档第八节第 9 条）。连接表与它都在进程内存里，单实例（app/single_instance.py）保证只有一份。

## 发一条要过的关（2026-09-27 用户定：第一版只用本地规则，靠举报 + 禁言 + 删单条兜底）

  can_speak_in_world → text_guard.clean_world_message（结构 + 联系方式 + 词表）
  → 每人 COOLDOWN_SEC 秒一条 → 全服每秒 GLOBAL_PER_SEC 条 → 禁言 → 写库 → 推送。
  前三道在 routes/world.py，后面在这里（要连库）。

## 019 没跑时

  表不存在 → WorldUnavailable → 503「世界频道暂时不可用」。游戏其余部分照常（同 016 没跑时封号放行）。
"""

from __future__ import annotations

import collections
import dataclasses
import datetime as dt
import logging
import uuid

import asyncpg

from app import db, realtime
from app.players import Player
from app.ranked import MYT_OFFSET

log = logging.getLogger("glory.world")

# 进程内留多少条、打开页签一次给多少条。
RING_SIZE = 100
# 往上翻一页最多给多少条。
PAGE_MAX = 100
# 与 database/019 文件头一致：库里只存 7 天（maintenance.py 每小时清一次）。
RETENTION_DAYS = 7
# 每人多久能发一条（设计文档第四节「频率控制」，2026-09-10 已定 8 秒）。
COOLDOWN_SEC = 8.0
# 全服每秒最多放行几条。**不是**给人用的额度，是保护推送：每条消息要发给所有正在看的人，
# 一个脚本号群刷的时候，这一道让推送量有个天花板。正常人碰不到（8 秒 CD × 在线人数）。
GLOBAL_PER_SEC = 10

# 推送类型与订阅主题。与客户端 ChatService.WORLD_TYPE / WORLD_HIDE_TYPE / WORLD_TOPIC 一致
# （tools/chat_check.gd 钉着）—— 对不上的话推送落进 RealtimeService 的「未知类型」分支，不报错，就是收不到。
TOPIC = "world"
PUSH_TYPE = "world"
HIDE_TYPE = "world_hide"


class WorldUnavailable(RuntimeError):
    """019 没跑（表不存在）或者数据库没配。路由层映射成 503。"""


@dataclasses.dataclass(frozen=True)
class Mute:
    reason: str
    ends_at: dt.datetime | None   # None = 永久

    def to_client(self) -> dict:
        ends = None if self.ends_at is None else self.ends_at.astimezone(dt.UTC).replace(microsecond=0)
        return {"reason": self.reason, "ends_at": None if ends is None else ends.isoformat()}

    def message(self) -> str:
        if self.ends_at is None:
            until = "永久禁言"
        else:
            local = (self.ends_at.astimezone(dt.UTC) + MYT_OFFSET).strftime("%Y-%m-%d %H:%M")
            until = "禁言到 %s（马来西亚时间）" % local
        return "你在世界频道被%s。原因：%s" % (until, self.reason)


class Muted(RuntimeError):
    def __init__(self, mute: Mute) -> None:
        super().__init__(mute.message())
        self.mute = mute


@dataclasses.dataclass(frozen=True)
class WorldMessage:
    message_id: int
    sender_id: uuid.UUID          # 内部身份，**不发给客户端**
    friend_code: str
    name: str
    avatar: str
    avatar_frame: str
    body: str
    created_at: dt.datetime

    def to_client(self) -> dict:
        # 「是不是我发的」由客户端拿 from_code 和自己的好友码比：推送是同一份发给所有人的。
        return {
            "message_id": self.message_id,
            "from_code": self.friend_code,
            "name": self.name,
            "avatar": self.avatar,
            "avatar_frame": self.avatar_frame,
            "body": self.body,
            "created_at": self.created_at.astimezone(dt.UTC).isoformat(),
        }


_COLUMNS = """
select w.message_id, w.sender_id, p.friend_code, w.sender_name, w.sender_avatar, w.sender_frame,
       w.body, w.created_at
  from world_messages w join players p on p.player_id = w.sender_id
"""

_RECENT = _COLUMNS + """
 where w.hidden_at is null and w.created_at > now() - ($1 * interval '1 day')
 order by w.message_id desc limit $2
"""

_OLDER = _COLUMNS + """
 where w.hidden_at is null and w.message_id < $1 and w.created_at > now() - ($2 * interval '1 day')
 order by w.message_id desc limit $3
"""

_LIVE_MUTE = """
select reason, ends_at from player_mutes
 where player_id = $1 and scope = 'world' and revoked_at is null and (ends_at is null or ends_at > now())
 order by ends_at desc nulls first
 limit 1
"""

_SENDER = "select player_name, avatar, avatar_frame, friend_code from players where player_id = $1"

_INSERT = """
insert into world_messages (sender_id, client_msg_id, body, sender_name, sender_avatar, sender_frame)
values ($1, $2, $3, $4, $5, $6)
on conflict (sender_id, client_msg_id) do nothing
returning message_id, created_at
"""

_EXISTING = """
select message_id, created_at, body, sender_name, sender_avatar, sender_frame
  from world_messages where sender_id = $1 and client_msg_id = $2
"""

_PURGE = "delete from world_messages where created_at < now() - ($1 * interval '1 day')"


def _row_to_message(row: asyncpg.Record) -> WorldMessage:
    return WorldMessage(int(row["message_id"]), row["sender_id"], str(row["friend_code"]),
                        str(row["sender_name"]), str(row["sender_avatar"]), str(row["sender_frame"]),
                        str(row["body"]), row["created_at"])


# --- 进程内的最近 RING_SIZE 条 ------------------------------------------------------


class WorldChannel:
    def __init__(self) -> None:
        self._recent: collections.deque[WorldMessage] = collections.deque(maxlen=RING_SIZE)
        self.warmed = False
        # 每人最后一条（client_msg_id -> 消息）：网络重试同一条时直接回它，不吃 8 秒 CD、不查库。
        self._last_post: dict[uuid.UUID, tuple[uuid.UUID, WorldMessage]] = {}

    async def warm(self) -> None:
        """从库里补回最近 RING_SIZE 条（启动时，或者第一次有人打开页签时）。"""
        rows = await _fetch(_RECENT, RETENTION_DAYS, RING_SIZE)
        self._recent = collections.deque((_row_to_message(r) for r in reversed(rows)), maxlen=RING_SIZE)
        self.warmed = True

    def recent(self) -> list[WorldMessage]:
        return list(self._recent)

    def add(self, message: WorldMessage) -> None:
        self._recent.append(message)

    def drop(self, message_id: int) -> bool:
        for message in self._recent:
            if message.message_id == message_id:
                self._recent.remove(message)
                return True
        return False

    def remember_post(self, message: WorldMessage, client_msg_id: uuid.UUID) -> None:
        self._last_post[message.sender_id] = (client_msg_id, message)
        # 有上界：只记最近说过话的一批人。被挤掉的人重试时走数据库那条去重，结果一样。
        while len(self._last_post) > 10_000:
            self._last_post.pop(next(iter(self._last_post)))

    def replayed_post(self, sender_id: uuid.UUID, client_msg_id: uuid.UUID) -> WorldMessage | None:
        last = self._last_post.get(sender_id)
        return last[1] if last is not None and last[0] == client_msg_id else None


_channel: WorldChannel | None = None


def channel() -> WorldChannel:
    global _channel
    if _channel is None:
        _channel = WorldChannel()
    return _channel


def reset_channel() -> None:
    """只给测试用。"""
    global _channel
    _channel = None


async def _fetch(sql: str, *args) -> list[asyncpg.Record]:
    if not db.is_connected():
        raise WorldUnavailable("数据库未配置")
    try:
        async with db.pool().acquire() as conn:
            return await conn.fetch(sql, *args)
    except asyncpg.UndefinedTableError:
        log.error("world_messages 表不存在：世界频道没有开。先在 Supabase 跑 database/019_world_chat.sql")
        raise WorldUnavailable("019 没跑") from None


async def warm_at_startup() -> None:
    """lifespan 里调。失败只记日志：世界频道第一次有人打开时会再补一次。"""
    try:
        await channel().warm()
        log.info("世界频道：从库里补回最近 %d 条", len(channel().recent()))
    except WorldUnavailable:
        pass
    except Exception:
        log.exception("世界频道启动时补回最近消息失败，第一次有人打开时再补")


# --- 谁能说话 -------------------------------------------------------------------------


def can_speak_in_world(player: Player) -> bool:
    """世界频道的发言门槛（设计文档第四节「等级门槛」）。

    2026-09-27 用户定：**所有人都能说**，以后有等级制度再加门槛。判据函数和调用点今天就在
    （routes/world.py），需要的那天只换这个函数体 —— 现成的判据是 players.created_at，
    广告号的共同特征正是「刚建的」。
    """
    return True


async def live_mute(conn: asyncpg.Connection, player_id: uuid.UUID) -> Mute | None:
    row = await conn.fetchrow(_LIVE_MUTE, player_id)
    return None if row is None else Mute(str(row["reason"]), row["ends_at"])


# --- 读 ---------------------------------------------------------------------------


async def latest(limit: int) -> list[WorldMessage]:
    ch = channel()
    if not ch.warmed:
        await ch.warm()
    return ch.recent()[-limit:] if limit > 0 else []


async def older(before_id: int, limit: int) -> list[WorldMessage]:
    rows = await _fetch(_OLDER, before_id, RETENTION_DAYS, limit)
    return [_row_to_message(r) for r in reversed(rows)]


# --- 写 ---------------------------------------------------------------------------


async def post(player: Player, body: str, client_msg_id: uuid.UUID) -> tuple[WorldMessage, bool]:
    """禁言 → 写库（按 client_msg_id 去重）→ 进最近 N 条 → 推送。返回 (消息, 这次是否新建)。

    文字必须已经过 text_guard.clean_world_message，频率限制已经在路由层判过。
    """
    if not db.is_connected():
        raise WorldUnavailable("数据库未配置")
    try:
        async with db.pool().acquire() as conn:
            mute = await live_mute(conn, player.player_id)
            if mute is not None:
                raise Muted(mute)
            sender = await conn.fetchrow(_SENDER, player.player_id)
            if sender is None:
                raise WorldUnavailable("没有这个玩家")
            row = await conn.fetchrow(_INSERT, player.player_id, client_msg_id, body,
                                      str(sender["player_name"]), str(sender["avatar"] or ""),
                                      str(sender["avatar_frame"] or ""))
            created = row is not None
            if not created:
                # 同一条的重试（第一次其实成功了）：回第一次那条，不再推一次。
                row = await conn.fetchrow(_EXISTING, player.player_id, client_msg_id)
                message = WorldMessage(int(row["message_id"]), player.player_id, str(sender["friend_code"]),
                                       str(row["sender_name"]), str(row["sender_avatar"]),
                                       str(row["sender_frame"]), str(row["body"]), row["created_at"])
            else:
                message = WorldMessage(int(row["message_id"]), player.player_id, str(sender["friend_code"]),
                                       str(sender["player_name"]), str(sender["avatar"] or ""),
                                       str(sender["avatar_frame"] or ""), body, row["created_at"])
    except asyncpg.UndefinedTableError:
        log.error("world_messages / player_mutes 表不存在：先在 Supabase 跑 database/019_world_chat.sql")
        raise WorldUnavailable("019 没跑") from None
    ch = channel()
    ch.remember_post(message, client_msg_id)
    if created:
        if not ch.warmed:
            await ch.warm()      # 补回来的已经包含刚写进去的这一条
        else:
            ch.add(message)
        # 写库之后才推：先推的话，有人收到推送、往上翻却在库里找不到这一条。
        await realtime.hub().publish(TOPIC, {"t": PUSH_TYPE, "message": message.to_client()})
    return message, created


async def hide(conn: asyncpg.Connection, message_id: int, actor: str, reason: str | None) -> uuid.UUID | None:
    """运营删一条（网页后台，app/admin.py）。打标记不删行；返回发言人，没有这条 / 已经删过返回 None。

    调用方提交事务之后要调 announce_hidden()，让正开着页签的人那边也消失。
    """
    return await conn.fetchval(
        "update world_messages set hidden_at = now(), hidden_by = $2, hidden_reason = $3"
        " where message_id = $1 and hidden_at is null returning sender_id",
        message_id, actor, reason)


async def announce_hidden(message_id: int) -> None:
    channel().drop(message_id)
    await realtime.hub().publish(TOPIC, {"t": HIDE_TYPE, "message_id": message_id})


async def purge(conn: asyncpg.Connection) -> int:
    """7 天前的删掉（maintenance.py 每小时一轮）。019 没跑时返回 0，不报错。"""
    try:
        return db.affected_rows(await conn.execute(_PURGE, RETENTION_DAYS))
    except asyncpg.UndefinedTableError:
        return 0
