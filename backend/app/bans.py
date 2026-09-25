"""封号（database/016_bans.sql，docs/运营后台设计.md 第二节）。

## 拦在哪几道

  1. 登录 / 续期：`players.resolve_or_create` 解析出被封的玩家 → 403。
  2. 每个要身份的接口：它们都经过 `players.get_by_auth_uid` → 403。手上还没过期的令牌也没用。
  3. 实时连接：握手时被封 → 说明原因后关掉；已经在线的 → `loop()` 每 SWEEP_SEC 查一次，
     查到就踢下线、摘掉匹配队列里的位置、收回在线名额。
  4. 出战名片：`/v1/me/battle-card` 走第 2 道。**战斗服务器不用改** ——
     名片 60 秒过期、一张只能用一次，拿不到新名片就坐不进任何新房间。正在打的那一局照常打完。

## 🔴 403，不是 401

旧版客户端续期收到 401 会清掉本机凭证、自动注册一个新的匿名号 —— 回 401 等于替他换号。
403 只显示登录失败，凭证留着，解封之后还是原来那个号。`main.py` 把 AccountBanned 统一映射成 403。

## 表还没建时放行

每个请求都要查一次这张表。部署时忘了先跑 016，查询会报「表不存在」——
这里把那种情况当成「没人被封」（表都没有，本来也封不了任何人），只在日志里大声报。
反过来 fail closed 的话，一次漏跑迁移 = 全体玩家进不了游戏。
"""

from __future__ import annotations

import asyncio
import dataclasses
import datetime as dt
import hashlib
import logging
import time
import uuid

import asyncpg

from app import admission, db, matchmaking, realtime
from app.ranked import MYT_OFFSET

log = logging.getLogger("glory.bans")

# 与 scripts/autoload/RealtimeService.gd 的同名常量对应。
CLOSE_BANNED = 4003
PUSH_TYPE = "banned"
# 403 响应体里的 code。与 scripts/autoload/AccountManager.gd 的 BANNED_CODE 对应。
ERROR_CODE = "account_banned"

# 在线的人多久查一次。封号之后最多这么久被踢下线（网页后台封号时当场踢，不用等）。
SWEEP_SEC = 10.0

# 这一刻生效的封号：没撤销、没到期。几条同时生效时取最晚结束的那条（永久最晚）。
_LIVE = """
select player_id, ban_id, reason, ends_at from player_bans
 where player_id = $1 and revoked_at is null and (ends_at is null or ends_at > now())
 order by ends_at desc nulls first
 limit 1
"""

_LIVE_AMONG = """
select distinct on (player_id) player_id, ban_id, reason, ends_at from player_bans
 where player_id = any($1::uuid[]) and revoked_at is null and (ends_at is null or ends_at > now())
 order by player_id, ends_at desc nulls first
"""

# 「表不存在」的日志多久报一次。每个请求报一次会把日志刷爆。
_MISSING_LOG_SEC = 60.0
_missing_logged_at = -_MISSING_LOG_SEC


@dataclasses.dataclass(frozen=True)
class Ban:
    player_id: uuid.UUID
    ban_id: int
    reason: str
    ends_at: dt.datetime | None   # None = 永久

    def to_client(self) -> dict:
        # 去掉微秒：now() + interval 带微秒，而客户端的解析（ServiceStatus.parse_iso_utc）不认小数秒。
        ends = None if self.ends_at is None else self.ends_at.astimezone(dt.UTC).replace(microsecond=0)
        return {"reason": self.reason, "ends_at": None if ends is None else ends.isoformat()}

    def message(self) -> str:
        """给旧版客户端显示的一句话（它们只认 detail）。新版客户端用 to_client() 自己排版。"""
        if self.ends_at is None:
            until = "永久封禁"
        else:
            local = (self.ends_at.astimezone(dt.UTC) + MYT_OFFSET).strftime("%Y-%m-%d %H:%M")
            until = "封禁到 %s（马来西亚时间）" % local
        return "账号已被封禁，%s。原因：%s" % (until, self.reason)


class AccountBanned(Exception):
    """这个玩家现在被封着。`main.py` 把它映射成 403。"""

    def __init__(self, ban: Ban) -> None:
        super().__init__(ban.message())
        self.ban = ban


def _row_to_ban(row: asyncpg.Record) -> Ban:
    return Ban(row["player_id"], int(row["ban_id"]), str(row["reason"]), row["ends_at"])


def _note_missing_table() -> None:
    global _missing_logged_at
    now = time.monotonic()
    if now - _missing_logged_at >= _MISSING_LOG_SEC:
        _missing_logged_at = now
        log.error("player_bans 表不存在：封号功能没有生效。先在 Supabase 跑 database/016_bans.sql")


async def live_ban(conn: asyncpg.Connection, player_id: uuid.UUID) -> Ban | None:
    """这个玩家现在生效的封号；没有返回 None。**不能在事务里调**（表不存在会废掉整个事务）。"""
    try:
        row = await conn.fetchrow(_LIVE, player_id)
    except asyncpg.UndefinedTableError:
        _note_missing_table()
        return None
    return None if row is None else _row_to_ban(row)


async def raise_if_banned(conn: asyncpg.Connection, player_id: uuid.UUID) -> None:
    ban = await live_ban(conn, player_id)
    if ban is not None:
        raise AccountBanned(ban)


async def live_bans_among(conn: asyncpg.Connection, player_ids: list[uuid.UUID]) -> dict[uuid.UUID, Ban]:
    if not player_ids:
        return {}
    try:
        rows = await conn.fetch(_LIVE_AMONG, player_ids)
    except asyncpg.UndefinedTableError:
        _note_missing_table()
        return {}
    return {row["player_id"]: _row_to_ban(row) for row in rows}


# --- 被封期间的续期凭证寄存（016 的 ban_refresh_handoff）---------------------------
#
# 为什么要有：见 016 那张表上面的说明。一句话：续期时 Supabase 已经把旧凭证换掉了，
# 不把新的存下来，旧版客户端下次拿旧凭证来会被 Supabase 当成重放 → 401 → 自动注册新号。


@dataclasses.dataclass(frozen=True)
class Handoff:
    player_id: uuid.UUID
    next_token: str


def token_hash(refresh_token: str) -> str:
    return hashlib.sha256(refresh_token.encode("utf-8")).hexdigest()


async def find_handoff(refresh_token: str) -> Handoff | None:
    async with db.pool().acquire() as conn:
        try:
            row = await conn.fetchrow(
                "select player_id, next_token from ban_refresh_handoff where token_hash = $1",
                token_hash(refresh_token))
        except asyncpg.UndefinedTableError:
            _note_missing_table()
            return None
    return None if row is None else Handoff(row["player_id"], str(row["next_token"]))


async def hold_handoff(refresh_token: str, player_id: uuid.UUID, next_token: str) -> None:
    """记下「拿 refresh_token 来的人，下一张凭证是 next_token」。同一张旧凭证再来就覆盖。"""
    async with db.pool().acquire() as conn:
        await conn.execute(
            "insert into ban_refresh_handoff (token_hash, player_id, next_token) values ($1, $2, $3)"
            " on conflict (token_hash) do update"
            " set next_token = excluded.next_token, player_id = excluded.player_id, updated_at = now()",
            token_hash(refresh_token), player_id, next_token)


async def drop_handoff(refresh_token: str) -> None:
    async with db.pool().acquire() as conn:
        await conn.execute("delete from ban_refresh_handoff where token_hash = $1", token_hash(refresh_token))


async def ensure_not_banned(player_id: uuid.UUID) -> None:
    async with db.pool().acquire() as conn:
        await raise_if_banned(conn, player_id)


# --- 踢下线 -------------------------------------------------------------------


def banned_message(ban: Ban) -> dict:
    return {"t": PUSH_TYPE, "ban": ban.to_client()}


async def kick(player_id: uuid.UUID, ban: Ban) -> None:
    """把一个刚被封的在线玩家请出去：匹配、名额、实时连接。"""
    # 匹配先摘：待确认阶段 = 那一桌当场解散，其他五个人回队列（同主动拒绝）。
    mm = matchmaking.current()
    mm.leave(player_id)
    mm.clear_assignment(player_id)
    # 名额直接收回，不进断线宽限 —— 他回不来了，占着只会让排队的人多等。
    admission.current().evict(player_id)
    closed = await realtime.hub().disconnect_player(player_id, CLOSE_BANNED, banned_message(ban))
    log.info("封号踢下线 player=%s ban=%d 连接=%d", player_id, ban.ban_id, closed)


async def sweep() -> int:
    """查一遍在线的人里有没有刚被封的，有就踢。返回踢了几个。"""
    if not db.is_connected():
        return 0
    online = realtime.hub().player_ids()
    if not online:
        return 0
    async with db.pool().acquire() as conn:
        found = await live_bans_among(conn, online)
    for player_id, ban in found.items():
        await kick(player_id, ban)
    return len(found)


async def kick_now(player_id: uuid.UUID) -> bool:
    """网页后台封号之后当场踢，不等下一轮。返回他是不是真的被封着。"""
    async with db.pool().acquire() as conn:
        ban = await live_ban(conn, player_id)
    if ban is None:
        return False
    await kick(player_id, ban)
    return True


async def loop() -> None:
    """后台巡检。由 app/main.py 的 lifespan 起停，同 mail.loop。"""
    while True:
        try:
            await asyncio.sleep(SWEEP_SEC)
            await sweep()
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - 一轮出错不该让循环停掉
            log.exception("封号巡检出错，下一轮再试")
