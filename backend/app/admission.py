"""同时在线上限与排队（2026-09-14 定）。

    口径：数的是**登录着、连着 WebSocket 的玩家**。一进游戏就判，
    超过上限的人停在启动画面排队（scenes/bootstrap/Bootstrap.gd），进不了主界面。

## 拦人的是客户端，不是这里

这里只回答「你可以进 / 你排第几」。战斗服务器不认识账号，也不看这里发的任何东西，
所以改过的客户端能跳过排队 —— 已知、已接受：它能插队，但战斗服务器自己的上限
（512 条连接 / 200 个房间）照旧挡着。真要堵死，得这里签票、战斗服务器验票，
见 docs/账号系统RFC.md 第三节「座位票」。

没有排队逻辑的旧版客户端靠顶协议号挡：它们连不上新版战斗服务器。

## 客户端握手时报的来意（X-Glory-Admission）

| 值 | 谁 | 满了怎么办 |
|---|---|---|
| `enter` | 冷启动进游戏 | 排队 |
| `resume` | 这个进程里已经被放进来过（断线重连），或本地有没打完的对局 | **直接放行，允许超出上限** |
| 没有这个头 | 旧版客户端 | 直接放行、计入人数，**不发任何排队消息**（它不认识） |
| 其他值 | —— | 当 `enter` |

`resume` 超上限是刻意的：已经在游戏里的人（很可能在一局 30 分钟的对局里）
绝不能因为这里重启了一次、或者手机切了一次后台，就被踢回排队画面。

## 名额什么时候收回

连接断开后名额**再留 SEAT_GRACE_SEC**。手机切后台时引擎不跑帧、不发心跳，
realtime 要 IDLE_TIMEOUT_SEC(95) 才判断开，所以从切后台到名额真正收回约 95 + 180 秒。
在这之内回来，名额还在，不用重新排。

排队的人断开同理，位置留 QUEUE_GRACE_SEC；期间轮到他就先跳过，回来仍在原位。

**没有「挂机踢人」。** 手机锁屏等于切后台，走上面那条自然收回；
亮着屏幕放在主界面不动的人会一直占着名额。要不要做、多久踢，还没定。

## 🔴 状态在进程内存里

与 realtime.Hub 同一个前提：单进程单实例（app/single_instance.py）。
**重启 = 名额表与队列清空。** 在游戏里的人重连时带 `resume`，照样进得来；
排队的人按重连先后重新排，原来的顺序没了 —— 所以高峰期别部署。

重启后 WARMUP_SEC 内**只放 `resume`，不放 `enter`**。不然先重连回来的是排队的人
（名额表是空的，个个都能进），在游戏里的人随后带着 `resume` 回来，
人数一下子超出一整个队列那么多。
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from collections import OrderedDict
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from pathlib import Path

from app import realtime
from app.realtime import Connection

log = logging.getLogger("glory.admission")

# 暂定值，**还没按线上机器的实测容量校准**（2026-09-14）。
# 生产上改 admission_file 指向的那个文件，不用改这里、也不用重启。
DEFAULT_ONLINE_LIMIT = 1000

SEAT_GRACE_SEC = 180.0
QUEUE_GRACE_SEC = 90.0
# 要盖住客户端重连退避的前几档（RealtimeService：1、2、4、8、16 秒）。
WARMUP_SEC = 45.0

TICK_SEC = 1.0
# 每秒最多放多少人。上限一次调大几百、或者重启预热结束时，不让几百个客户端
# 同一秒涌进主界面 —— 每个人进门都要拉资料、报在线、连聊天。
ADMIT_PER_TICK = 20
POSITION_PUSH_SEC = 5.0
CONFIG_RELOAD_SEC = 5.0
STATS_LOG_SEC = 60.0
# 单条推送的上限。一条卡住的连接不能让整轮放人停下来。
SEND_TIMEOUT_SEC = 5.0

# 与 scripts/autoload/RealtimeService.gd 的 ADMISSION_* 对应。⚠️ 两处都有，tools/chat_check 钉着。
# 对不上的症状是新客户端被当成旧版（从不排队），或者永远收不到放行、卡在启动画面 ——
# 两种都不报错。
HEADER = "x-glory-admission"
MESSAGE_TYPE = "admission"
ENTER = "enter"
RESUME = "resume"
LEGACY = "legacy"

Send = Callable[[Connection, dict], Awaitable[bool]]


def parse_intent(raw: str | None) -> str:
    """握手头 -> 来意。看不懂的值往严了算（当 enter）：来意是客户端自报的。"""
    if raw is None:
        return LEGACY
    return RESUME if raw.strip().lower() == RESUME else ENTER


def admitted_message() -> dict:
    return {"t": MESSAGE_TYPE, "state": "admitted"}


def queued_message(position: int) -> dict:
    return {"t": MESSAGE_TYPE, "state": "queued", "position": position}


@dataclass
class _Seat:
    # None = 断开了，名额还在宽限期里。
    conn: Connection | None
    released_at: float = 0.0


@dataclass
class _Waiter:
    conn: Connection | None
    dropped_at: float = 0.0
    # 上一次告诉他的位次。没变就不重发。
    sent_position: int = 0


class Admission:
    """名额表 + 队列。进程内单例，见 `install()` / `current()`。

    join / leave 是同步的、中间没有 await —— 在同一个事件循环里它们天然是原子的，
    不需要锁。只有 tick 里的发送会让出执行权，而发送前状态已经改完了。
    """

    def __init__(
        self,
        send: Send,
        *,
        limit: int = DEFAULT_ONLINE_LIMIT,
        config_path: str = "",
        now: Callable[[], float] = time.monotonic,
        warmup_sec: float | None = None,
    ) -> None:
        self._send = send
        self._now = now
        self._default_limit = max(1, int(limit))
        self.limit = self._default_limit
        self._config_path = config_path.strip()
        self._config_mtime: float | None = None
        started = now()
        # 读模块常量要放在函数体里，别写成参数默认值 —— 那样测试 monkeypatch 不到。
        self._warm_until = started + (WARMUP_SEC if warmup_sec is None else warmup_sec)
        self._seats: dict[uuid.UUID, _Seat] = {}
        self._queue: OrderedDict[uuid.UUID, _Waiter] = OrderedDict()
        self._next_position_push = started
        self._next_config_check = started + CONFIG_RELOAD_SEC
        self._next_stats_log = started + STATS_LOG_SEC
        self._last_stats: tuple[int, ...] | None = None
        self._reload_config()

    # --- 连接生命周期 ---------------------------------------------------------

    def join(self, conn: Connection, intent: str) -> dict:
        """一条连接进来。返回要发给它的名额消息（旧版客户端由调用方决定不发）。

        **必须在 Hub.register 之后调**：同一个人换设备时，新连接要接过旧连接的名额。
        """
        pid = conn.player_id
        seat = self._seats.get(pid)
        if seat is not None:
            # 已经有名额（在线、或在断线宽限里）：认回来，不重复计数。
            seat.conn = conn
            seat.released_at = 0.0
            self._queue.pop(pid, None)
            return admitted_message()

        if intent != ENTER:
            # resume / 旧版客户端：直接放，允许超上限。理由见文件头那张表。
            self._queue.pop(pid, None)
            self._seats[pid] = _Seat(conn)
            return admitted_message()

        waiter = self._queue.get(pid)
        if waiter is not None:
            waiter.conn = conn
            waiter.dropped_at = 0.0
            position = self.position_of(pid)
            waiter.sent_position = position
            return queued_message(position)

        # 🔴 队列里有人就不许直接进，哪怕恰好空着位子 —— 先来后到。
        # 空出来的位子由下一轮 tick 按顺序放给排在前面的人。
        if not self._queue and not self.is_warming() and len(self._seats) < self.limit:
            self._seats[pid] = _Seat(conn)
            return admitted_message()

        position = len(self._queue) + 1
        self._queue[pid] = _Waiter(conn, sent_position=position)
        return queued_message(position)

    def leave(self, conn: Connection) -> None:
        """连接断开。**幂等**，且只认自己那条 —— 换设备时旧连接晚到的 leave 不能放掉新连接的名额。"""
        now = self._now()
        pid = conn.player_id
        seat = self._seats.get(pid)
        if seat is not None and seat.conn is conn:
            seat.conn = None
            seat.released_at = now
        waiter = self._queue.get(pid)
        if waiter is not None and waiter.conn is conn:
            waiter.conn = None
            waiter.dropped_at = now

    # --- 巡检 -----------------------------------------------------------------

    async def tick(self) -> None:
        """收回过期名额、按顺序放人、推位次。由 `loop()` 每 TICK_SEC 调一次。"""
        now = self._now()
        if now >= self._next_config_check:
            self._next_config_check = now + CONFIG_RELOAD_SEC
            self._reload_config()
        self._expire(now)
        admitted = self._promote(now)
        if admitted:
            await self._deliver([(conn, admitted_message()) for conn in admitted])
        if now >= self._next_position_push:
            self._next_position_push = now + POSITION_PUSH_SEC
            await self._deliver(self._position_updates())
        if now >= self._next_stats_log:
            self._next_stats_log = now + STATS_LOG_SEC
            self._log_stats()

    def _expire(self, now: float) -> None:
        for pid in [p for p, s in self._seats.items()
                    if s.conn is None and now - s.released_at >= SEAT_GRACE_SEC]:
            del self._seats[pid]
        for pid in [p for p, w in self._queue.items()
                    if w.conn is None and now - w.dropped_at >= QUEUE_GRACE_SEC]:
            del self._queue[pid]

    def _promote(self, now: float) -> list[Connection]:
        if now < self._warm_until:
            return []
        budget = min(self.limit - len(self._seats), ADMIT_PER_TICK)
        admitted: list[Connection] = []
        if budget <= 0:
            return admitted
        for pid, waiter in list(self._queue.items()):
            if len(admitted) >= budget:
                break
            if waiter.conn is None:
                # 断开了但还在宽限里：跳过、不出队。回来时仍然排在前面。
                continue
            del self._queue[pid]
            self._seats[pid] = _Seat(waiter.conn)
            admitted.append(waiter.conn)
        return admitted

    def _position_updates(self) -> list[tuple[Connection, dict]]:
        updates: list[tuple[Connection, dict]] = []
        for position, waiter in enumerate(self._queue.values(), start=1):
            if waiter.conn is not None and waiter.sent_position != position:
                waiter.sent_position = position
                updates.append((waiter.conn, queued_message(position)))
        return updates

    async def _deliver(self, messages: list[tuple[Connection, dict]]) -> None:
        if messages:
            # 并发发：排在后面的人不该因为前面某条连接卡住而收不到。
            await asyncio.gather(*(self._send_one(conn, payload) for conn, payload in messages))

    async def _send_one(self, conn: Connection, payload: dict) -> bool:
        try:
            return await asyncio.wait_for(self._send(conn, payload), SEND_TIMEOUT_SEC)
        except TimeoutError:
            log.info("名额消息发送超时 player=%s", conn.player_id)
            return False

    # --- 上限配置 -------------------------------------------------------------

    def _reload_config(self) -> None:
        """读 {"online_limit": N}。文件没了回到启动时的默认值；内容不对就保留当前值。"""
        if not self._config_path:
            return
        path = Path(self._config_path)
        try:
            mtime = path.stat().st_mtime
        except FileNotFoundError:
            if self._config_mtime is not None:
                self._config_mtime = None
                self._apply_limit(self._default_limit, f"{path} 不在了，回到默认值")
            return
        except OSError:
            log.warning("读不到排队配置 %s，保留当前上限 %d", path, self.limit, exc_info=True)
            return
        if mtime == self._config_mtime:
            return
        # 坏内容也记下 mtime，否则每 5 秒刷一条警告。修好文件时 mtime 会变（纳秒精度），会被重读。
        self._config_mtime = mtime
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            log.warning("排队配置 %s 读不出来或不是 JSON，保留当前上限 %d", path, self.limit)
            return
        value = data.get("online_limit") if isinstance(data, dict) else None
        # bool 是 int 的子类：{"online_limit": true} 不能被当成 1。
        if isinstance(value, bool) or not isinstance(value, int) or value < 1:
            log.warning("排队配置 %s 的 online_limit 不是正整数（%r），保留当前上限 %d",
                        path, value, self.limit)
            return
        self._apply_limit(value, f"读取 {path}")

    def _apply_limit(self, value: int, reason: str) -> None:
        if value != self.limit:
            log.info("在线上限 %d -> %d（%s）", self.limit, value, reason)
            self.limit = value

    # --- 观测 -----------------------------------------------------------------

    def is_warming(self) -> bool:
        return self._now() < self._warm_until

    def position_of(self, player_id: uuid.UUID) -> int:
        """1 起的位次；不在队列里返回 0。"""
        for position, pid in enumerate(self._queue, start=1):
            if pid == player_id:
                return position
        return 0

    def stats(self) -> dict[str, int]:
        return {
            "limit": self.limit,
            "online": len(self._seats),
            "online_connected": sum(1 for s in self._seats.values() if s.conn is not None),
            "queued": len(self._queue),
            "queued_connected": sum(1 for w in self._queue.values() if w.conn is not None),
        }

    def _log_stats(self) -> None:
        stats = self.stats()
        key = tuple(stats.values())
        # 有人排队时每分钟都记（运维要看队伍在不在动）；没人排队时只在数字变了才记。
        if key == self._last_stats and not self._queue:
            return
        self._last_stats = key
        log.info("在线 %d（连着 %d）/ 上限 %d，排队 %d（连着 %d）",
                 stats["online"], stats["online_connected"], stats["limit"],
                 stats["queued"], stats["queued_connected"])


_instance: Admission | None = None


async def hub_send(conn: Connection, payload: dict) -> bool:
    """默认的发送方式：走连接表。**每次现取 hub()** —— 测试会换掉它。"""
    return await realtime.hub().send(conn, payload)


def install(instance: Admission) -> Admission:
    """由 lifespan 调。预热期从实例创建那一刻算起。"""
    global _instance
    _instance = instance
    return instance


def current() -> Admission:
    global _instance
    if _instance is None:
        # 没经过 lifespan 时的兜底（不该发生在生产上）。
        _instance = Admission(hub_send)
    return _instance


def reset() -> None:
    """只给测试用。"""
    global _instance
    _instance = None


async def loop(target: Admission) -> None:
    """后台巡检。由 lifespan 起、由它取消。"""
    try:
        while True:
            await asyncio.sleep(TICK_SEC)
            try:
                await target.tick()
            except Exception:
                # 同 realtime.sweep_loop：巡检自己出错不能把循环带走 ——
                # 那样队伍永远不动，而且没有任何报错。
                log.exception("排队巡检出错，继续下一轮")
    except asyncio.CancelledError:
        raise
