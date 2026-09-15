"""WebSocket 连接表（`docs/聊天系统设计.md` 批次 B）。

这里只管**连接**：谁连着、往谁发、什么时候断。
频道路由与消息落库是批次 C，不在本文件。

## 🔴 这张表在进程内存里

所以 ② 从此是**有状态的**，必须单进程单实例 —— 见 `app/single_instance.py`
那一整段。那个文件不是可选的洁癖，是这张表的前提。

## 一个玩家为什么可以有多条连接

因为顶号需要区分两种情况，而它们在网络层长得一模一样（都是「同一个账号又连进来一条」）：

| 新连接的 device_session_id | 语义 | 旧连接怎么处理 |
|---|---|---|
| 与旧连接**相同** | 同一台设备**重连**（切网、后台被杀、弱网抖动） | 悄悄断开，**不发 kicked** |
| 与旧连接**不同** | 真的在另一台设备登录了 | 断开并**下发 kicked** |

🔴 **不做这个区分的后果很具体**：手机切个网、锁屏一会儿再回来，玩家就会收到
一句「你的账号在其他设备登录」。他会去改密码、会来问客服，而实际上什么都没发生。
移动端重连是常态不是异常，把它误报成顶号是本文件最容易犯的错。
"""

from __future__ import annotations

import asyncio
import logging
import time
import uuid
from dataclasses import dataclass, field

from starlette.websockets import WebSocket, WebSocketState

log = logging.getLogger("glory.realtime")

# 客户端每 30 秒发一次 ping。这里给三倍余量 ——
# 必须大于心跳间隔且能容忍丢一两次，否则弱网下会把正常玩家踢下线。
# 与 presence 的「心跳 60 / TTL 150」是同一条不变量（TTL > 间隔，且容得下丢包）。
HEARTBEAT_INTERVAL_SEC = 30.0
IDLE_TIMEOUT_SEC = 95.0

# 扫描死连接的周期。不用每秒扫 —— 超时本来就是分钟级的判断。
SWEEP_INTERVAL_SEC = 15.0

# 单条消息的上界。来路是网络，任何没有上界的东西都会被人拿去打内存。
# 快捷短语与私聊都是短句，8 KiB 已经很宽。
MAX_MESSAGE_BYTES = 8192

# 广播时单条连接的发送上限（见 Hub.broadcast）。
BROADCAST_SEND_TIMEOUT_SEC = 5.0

# 顶号时给旧连接的关闭码。1000 是「正常关闭」，这里刻意用私有区间的码，
# 让客户端能把「被顶号」与「服务器重启 / 网络断」分开 ——
# 这两件事在玩家眼里完全不同，不能都显示成「连接已断开」。
CLOSE_KICKED = 4001
CLOSE_IDLE = 4002


@dataclass
class Connection:
    player_id: uuid.UUID
    device_session_id: str
    websocket: WebSocket
    # 单调时钟：墙钟会因为 NTP 校正跳变，而这个值只用来算「多久没说话了」。
    last_seen: float = field(default_factory=time.monotonic)

    def touch(self) -> None:
        self.last_seen = time.monotonic()

    def is_idle(self, now: float) -> bool:
        return now - self.last_seen > IDLE_TIMEOUT_SEC


class Hub:
    """所有活着的连接。进程内单例，见 `hub()`。"""

    def __init__(self) -> None:
        # player_id -> {device_session_id: Connection}
        #
        # 用两层字典而不是列表：顶号要按 device_session_id 找同设备的旧连接，
        # 而列表得线性扫。更重要的是字典让「同一设备只可能有一条连接」
        # 成为结构上的事实，不是靠代码自觉维持的约定。
        self._by_player: dict[uuid.UUID, dict[str, Connection]] = {}

    # --- 连接生命周期 ---------------------------------------------------------

    async def register(self, conn: Connection) -> None:
        """登记一条新连接，并按需踢掉同账号的旧连接。

        **必须在 websocket.accept() 之后调用** —— 踢旧连接会往它上面写数据，
        而这里可能就包含新连接自己（同设备重连时）。
        """
        devices = self._by_player.setdefault(conn.player_id, {})

        same_device = devices.pop(conn.device_session_id, None)
        if same_device is not None:
            # 同设备重连：旧的那条已经是僵尸了（客户端不会同时开两条）。
            # 悄悄断，**不发 kicked** —— 见文件头那张表。
            log.info("同设备重连，断开旧连接 player=%s", conn.player_id)
            await self._close(same_device, CLOSE_IDLE, notify_kicked=False)

        others = list(devices.values())
        for other in others:
            log.info("顶号：断开其他设备 player=%s", conn.player_id)
            devices.pop(other.device_session_id, None)
            await self._close(other, CLOSE_KICKED, notify_kicked=True)

        devices[conn.device_session_id] = conn

    def unregister(self, conn: Connection) -> None:
        """连接断开后清表。**幂等** —— 正常关闭与异常关闭都会走到这里。"""
        devices = self._by_player.get(conn.player_id)
        if devices is None:
            return
        # 只在还是自己那条时才删：顶号时旧连接已经被换掉了，
        # 它随后走到自己的 finally 时不能把新连接删掉。
        # 少这个判断的症状是「顶号之后新设备也收不到消息」，而且没有任何报错。
        if devices.get(conn.device_session_id) is conn:
            devices.pop(conn.device_session_id, None)
        if not devices:
            self._by_player.pop(conn.player_id, None)

    async def _close(self, conn: Connection, code: int, notify_kicked: bool) -> None:
        if notify_kicked:
            # 先说明原因再关。客户端要靠这条消息把「被顶号」与「掉线」分开 ——
            # 只给一个关闭码的话，弱网下客户端多半来不及读就当成断线重连了。
            await self.send(conn, {"t": "kicked", "reason": "another_device"})
        try:
            if conn.websocket.client_state is WebSocketState.CONNECTED:
                await conn.websocket.close(code=code)
        except (RuntimeError, OSError):
            # 对端已经没了。关一条死连接不该让新连接的登记流程失败。
            log.debug("关闭连接时对端已断开 player=%s", conn.player_id, exc_info=True)

    # --- 发送 -----------------------------------------------------------------

    async def send(self, conn: Connection, payload: dict) -> bool:
        """往一条连接发。失败返回 False，**不抛** —— 调用方通常在广播循环里。"""
        try:
            if conn.websocket.client_state is not WebSocketState.CONNECTED:
                return False
            await conn.websocket.send_json(payload)
            return True
        except (RuntimeError, OSError):
            log.debug("发送失败 player=%s", conn.player_id, exc_info=True)
            return False

    async def send_to_player(self, player_id: uuid.UUID, payload: dict) -> int:
        """发给某个玩家的所有在线设备。返回成功送达的连接数。

        返回 0 表示人不在线 —— 调用方据此决定要不要落成离线消息（批次 C）。
        """
        devices = self._by_player.get(player_id)
        if not devices:
            return 0
        sent = 0
        for conn in list(devices.values()):
            if await self.send(conn, payload):
                sent += 1
        return sent

    async def broadcast(self, payload: dict) -> int:
        """发给**所有**连着的设备（紧急公告，app/announcements.py）。返回成功送达的连接数。

        并发发，且每条都有超时：一条卡住的连接（手机进了隧道、TCP 还没断）
        不能让排在后面的几百个人收不到。同 admission._deliver 的理由。
        """
        conns = [conn for devices in self._by_player.values() for conn in devices.values()]
        if not conns:
            return 0
        results = await asyncio.gather(*(self._send_bounded(conn, payload) for conn in conns))
        return sum(1 for ok in results if ok)

    async def _send_bounded(self, conn: Connection, payload: dict) -> bool:
        try:
            # 读模块常量要放在函数体里 —— 写成参数默认值的话测试 monkeypatch 不到。
            return await asyncio.wait_for(self.send(conn, payload), BROADCAST_SEND_TIMEOUT_SEC)
        except TimeoutError:
            log.info("广播发送超时 player=%s", conn.player_id)
            return False

    # --- 巡检 -----------------------------------------------------------------

    async def sweep_idle(self) -> int:
        """断开超时的连接。返回断了几条。

        为什么需要它：**TCP 不会告诉你对端已经没了。** 手机进隧道、被系统冻结、
        NAT 表项过期，连接在服务端看起来仍然是「连着」的，直到下一次写才发现。
        没有这一步，连接表会被幽灵连接慢慢撑大，而每条幽灵都在占内存和一个玩家的位置。
        """
        now = time.monotonic()
        dead: list[Connection] = []
        for devices in self._by_player.values():
            for conn in devices.values():
                if conn.is_idle(now):
                    dead.append(conn)
        for conn in dead:
            log.info("心跳超时，断开 player=%s", conn.player_id)
            self.unregister(conn)
            await self._close(conn, CLOSE_IDLE, notify_kicked=False)
        return len(dead)

    # --- 观测 -----------------------------------------------------------------

    def connection_count(self) -> int:
        return sum(len(devices) for devices in self._by_player.values())

    def player_count(self) -> int:
        return len(self._by_player)

    def is_online(self, player_id: uuid.UUID) -> bool:
        return bool(self._by_player.get(player_id))


_hub: Hub | None = None


def hub() -> Hub:
    global _hub
    if _hub is None:
        _hub = Hub()
    return _hub


def reset_hub() -> None:
    """只给测试用。生产上连接表活到进程结束。"""
    global _hub
    _hub = None


async def sweep_loop(target: Hub) -> None:
    """后台巡检任务。由 lifespan 起、由它取消。"""
    try:
        while True:
            await asyncio.sleep(SWEEP_INTERVAL_SEC)
            try:
                await target.sweep_idle()
            except Exception:
                # 巡检自己出错不能把循环带走 —— 那样幽灵连接就再也不会被清理，
                # 而且没有任何症状（连接表只增不减，直到内存被吃光）。
                log.exception("巡检死连接时出错，继续下一轮")
    except asyncio.CancelledError:
        raise
