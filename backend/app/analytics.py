"""运营数据第一批：在线人数、每日活跃（database/025_analytics.sql，docs/运营数据.md）。

报表怎么算在 app/analytics_report.py；这里只管**记**。

## 🔴 不在玩家的路上碰数据库

玩家连进来、断开时（routes/ws.py）只改内存。采样循环每 15 秒写一行在线人数，
每分钟把「这一分钟谁在线、在线多久、连过几次」批量写进每日活跃。
数据库慢了、挂了、025 还没跑：统计缺一段，**登录和游戏照常**。

## 在线时长怎么算

每个在线的玩家记一个「从什么时候起算」：连上时开始；每分钟写库时结一次账、从那一刻重新起算；
最后一台设备断开时结一次。结账都只结到**最后一次心跳后 TRAILING_SEC 秒** ——
手机切后台后心跳就停了，连接却还要挂 95 秒才被判死（realtime.IDLE_TIMEOUT_SEC），那段不算。
同一账号几台设备只算一份。

## 状态在进程内存里

同 realtime.Hub：单进程单实例（app/single_instance.py）。重启丢的是最后不到一分钟还没写库的那点；
正常关服时 lifespan 会先写一次（flush_on_shutdown）。
"""

from __future__ import annotations

import asyncio
import datetime as dt
import logging
import time
import uuid
from collections.abc import Callable
from zoneinfo import ZoneInfo

import asyncpg

from app import admission, db, realtime
from app.realtime import Connection

log = logging.getLogger("glory.analytics")

# 业务日。同后台（admin_web 按 +08:00 显示）和七日登录（data/seven_day_login.json）。
GAME_TZ = ZoneInfo("Asia/Kuala_Lumpur")

SAMPLE_SEC = 15
# 每几次采样写一次每日活跃：15 × 4 = 1 分钟。
FLUSH_EVERY = 4
# 最后一次心跳之后还算在线多久。客户端 30 秒一次心跳，多给一半容忍卡顿（加载时帧会停一下）。
TRAILING_SEC = realtime.HEARTBEAT_INTERVAL_SEC * 1.5
# 写不进库时多久提醒一次。数据库挂了或 025 没跑，别每 15 秒刷一条。
WARN_EVERY_SEC = 600.0
SHUTDOWN_FLUSH_TIMEOUT_SEC = 5.0

_INSERT_SAMPLE = """
insert into analytics_online_samples
  (sampled_at, server_epoch, interval_sec, players, internal, connections, queued)
values ($1, $2, $3, $4, $5, $6, $7)
on conflict (sampled_at) do nothing
"""

# join players：玩家行不会删（注销只清资料），这里只是不让一个意外的编号把整批写入拖垮。
_UPSERT_DAYS = """
insert into analytics_player_days as d
  (game_day, player_id, first_seen_at, last_seen_at, online_seconds, connects)
select $1, u.pid, $2, $2, least(u.secs, 86400), u.conns
  from unnest($3::uuid[], $4::int[], $5::int[]) as u(pid, secs, conns)
  join players p on p.player_id = u.pid
on conflict (game_day, player_id) do update
   set last_seen_at   = excluded.last_seen_at,
       online_seconds = least(86400, d.online_seconds + excluded.online_seconds),
       connects       = d.connects + excluded.connects
"""


def game_day(at: dt.datetime) -> dt.date:
    return at.astimezone(GAME_TZ).date()


def _queued_connected() -> int:
    return admission.current().stats()["queued_connected"]


def _utc_now() -> dt.datetime:
    return dt.datetime.now(dt.UTC)


class Recorder:
    def __init__(self, hub: Callable[[], realtime.Hub] = realtime.hub,
                 queued: Callable[[], int] = _queued_connected,
                 clock: Callable[[], float] = time.monotonic,
                 wall: Callable[[], dt.datetime] = _utc_now) -> None:
        # 这次启动的编号。在线采样里它换了 = 账号服务器中间重启过。
        self.epoch = uuid.uuid4()
        self._hub = hub
        self._queued = queued
        self._clock = clock
        self._wall = wall
        # 在线的玩家从哪一刻（单调时钟）开始还没结账。
        self._since: dict[uuid.UUID, float] = {}
        # 结了账、还没写库的秒数 / 连接次数。都以玩家为键，大小不超过真实玩家数。
        self._seconds: dict[uuid.UUID, float] = {}
        self._connects: dict[uuid.UUID, int] = {}
        # 内部账号（025 的 analytics_account_tags），每分钟从库里重读一次；后台打标签时当场改。
        self._internal: set[uuid.UUID] = set()
        self._ticks = 0
        self._warned_at = float("-inf")

    # --- 连接进出（routes/ws.py 调，只动内存）----------------------------------------

    def on_connect(self, player_id: uuid.UUID) -> None:
        self._connects[player_id] = self._connects.get(player_id, 0) + 1
        self._since.setdefault(player_id, self._clock())

    def on_disconnect(self, conn: Connection) -> None:
        """一条连接断了（已经从连接表摘掉之后调）。还有别的设备连着、或者同设备已经重连上，就接着算。"""
        if self._hub().is_online(conn.player_id):
            return
        start = self._since.pop(conn.player_id, None)
        if start is not None:
            self._credit(conn.player_id, min(self._clock(), conn.last_seen + TRAILING_SEC) - start)

    def set_internal(self, player_id: uuid.UUID, internal: bool) -> None:
        if internal:
            self._internal.add(player_id)
        else:
            self._internal.discard(player_id)

    def internal_online(self) -> int:
        return sum(1 for pid in self._hub().player_ids() if pid in self._internal)

    def _credit(self, player_id: uuid.UUID, seconds: float) -> None:
        if seconds > 0:
            self._seconds[player_id] = self._seconds.get(player_id, 0.0) + seconds

    # --- 写库 ---------------------------------------------------------------------------

    async def sample(self, conn: asyncpg.Connection) -> None:
        hub = self._hub()
        ids = hub.player_ids()
        internal = sum(1 for pid in ids if pid in self._internal)
        # 排队的人一定连着，但两张表不是同一刻摘的人，夹一下免得撞上表约束。
        queued = min(self._queued(), len(ids))
        await conn.execute(_INSERT_SAMPLE, self._wall(), self.epoch, SAMPLE_SEC,
                           len(ids), internal, hub.connection_count(), queued)

    def _settle(self) -> None:
        """在线的人结账到此刻（最多到最后一次心跳后 TRAILING_SEC），重新起算。"""
        now = self._clock()
        hub = self._hub()
        for pid in list(self._since):
            seen = hub.last_seen(pid)
            if seen is None:
                # 不在连接表里却没收到 on_disconnect：不该发生。不知道他什么时候走的，这一段不算。
                del self._since[pid]
                continue
            self._credit(pid, min(now, seen + TRAILING_SEC) - self._since[pid])
            self._since[pid] = now
        # 在线却没经过 on_connect 的（同上，不该发生）：从现在起算，别漏了「今天来过」。
        for pid in hub.player_ids():
            self._since.setdefault(pid, now)

    async def flush(self, conn: asyncpg.Connection) -> int:
        """把结了账的时长、连接次数写进今天那一行。返回写了几个人。"""
        self._settle()
        seconds, self._seconds = self._seconds, {}
        connects, self._connects = self._connects, {}
        pids = sorted(set(seconds) | set(connects) | set(self._since))
        if pids:
            now = self._wall()
            try:
                await conn.execute(_UPSERT_DAYS, game_day(now), now, pids,
                                   [round(seconds.get(p, 0.0)) for p in pids],
                                   [connects.get(p, 0) for p in pids])
            except BaseException:
                # 这一分钟的时长丢掉（数据库一时写不进，少算一分钟没关系）；
                # 「今天连过」留着下次再写 —— 那是日活，丢了这个人今天就不算来过。
                for pid, n in connects.items():
                    self._connects[pid] = self._connects.get(pid, 0) + n
                raise
        tagged = await conn.fetch("select player_id from analytics_account_tags")
        self._internal = {row["player_id"] for row in tagged}
        return len(pids)

    async def tick(self) -> None:
        self._ticks += 1
        if not db.is_connected():
            return
        async with db.pool().acquire() as conn:
            try:
                await self.sample(conn)
            except Exception as exc:  # noqa: BLE001 - 统计出错不能影响别的，下面统一提醒
                self._warn(exc)
            if self._ticks % FLUSH_EVERY == 0:
                try:
                    await self.flush(conn)
                except Exception as exc:  # noqa: BLE001
                    self._warn(exc)

    def _warn(self, exc: Exception) -> None:
        now = self._clock()
        if now - self._warned_at < WARN_EVERY_SEC:
            return
        self._warned_at = now
        if isinstance(exc, asyncpg.UndefinedTableError):
            log.warning("运营数据没在记：数据库还没跑 database/025_analytics.sql（%s）", exc)
        else:
            log.warning("运营数据写库失败，这一段会缺（%s: %s）", type(exc).__name__, exc)


_instance: Recorder | None = None


def install(instance: Recorder) -> Recorder:
    """由 lifespan 调。"""
    global _instance
    _instance = instance
    return instance


def current() -> Recorder:
    global _instance
    if _instance is None:
        # 没经过 lifespan 时的兜底（测试直接调 WS 端点时）：只记内存，不写库。
        _instance = Recorder()
    return _instance


def reset() -> None:
    """只给测试用。"""
    global _instance
    _instance = None


async def loop(target: Recorder) -> None:
    """由 lifespan 起、由它取消。"""
    try:
        while True:
            await asyncio.sleep(SAMPLE_SEC)
            try:
                await target.tick()
            except Exception:
                # 同 realtime.sweep_loop：出错不能把循环带走 —— 那样统计从此静悄悄地停了。
                log.exception("运营数据采样出错，继续下一轮")
    except asyncio.CancelledError:
        raise


async def flush_on_shutdown(target: Recorder) -> None:
    """关服前把最后不到一分钟写掉。写不进就算了，不能卡住关服。"""
    if not db.is_connected():
        return

    async def run() -> None:
        async with db.pool().acquire() as conn:
            await target.flush(conn)

    try:
        await asyncio.wait_for(run(), SHUTDOWN_FLUSH_TIMEOUT_SEC)
    except Exception as exc:  # noqa: BLE001
        log.warning("关服前写运营数据失败，最后不到一分钟会缺（%s）", type(exc).__name__)
