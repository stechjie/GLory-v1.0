"""WebSocket 基础设施的行为用例（`docs/聊天系统设计.md` 批次 B）。

不连数据库、不连 Supabase：认证与玩家查询都注入掉，判据全在连接表自己的行为上。

最重要的两组，它们的失败模式都**不会报错**：

  1. **「同设备重连」与「换设备顶号」必须分开。** 不分的后果很具体 ——
     手机切个网、锁屏一会儿再回来，玩家就会收到「你的账号在其他设备登录」。
     他会去改密码、会来问客服，而实际上什么都没发生。移动端重连是常态。
  2. **顶号之后，旧连接自己走 finally 时不能把新连接从表里删掉。**
     删掉的症状是「顶号之后新设备也收不到消息」，而且没有任何报错 ——
     连接还连着，只是不在表里了。

跑（必须从 backend/ 目录，pytest.ini 在那里）：
    cd backend && .venv/Scripts/python -m pytest -q tests/test_ws.py
"""

from __future__ import annotations

import socket
import uuid
from dataclasses import dataclass

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app import db, players, realtime, single_instance
from app.config import get_settings
from app.jwt_verify import Claims, TokenError
from app.main import app
from app.routes import ws as ws_routes

DEVICE_A = "device-aaaaaaaa"
DEVICE_B = "device-bbbbbbbb"


@dataclass
class _FakePlayer:
    player_id: uuid.UUID


class _FakeVerifier:
    """按令牌串决定放不放行。生产上的 verify 会去打 JWKS，测试里不该联网。"""

    def __init__(self) -> None:
        self.accept = {"good-token": "auth-uid-1", "good-token-2": "auth-uid-2"}

    async def verify(self, token: str) -> Claims:
        uid = self.accept.get(token)
        if uid is None:
            raise TokenError("令牌校验失败：测试用的假 verifier 不认识它")
        return Claims(auth_uid=uid, is_anonymous=True, expires_at=0)


@pytest.fixture
def wired(monkeypatch: pytest.MonkeyPatch):
    """把 WS 端点接线到假的认证与玩家表上。"""
    # 单实例锁在测试里必须关掉：pytest 可能并行、CI 上也可能同时跑多个 job，
    # 真去抢端口会让测试彼此打架。生产上它是开着的（默认 False）。
    monkeypatch.setenv("GLORY_DISABLE_INSTANCE_LOCK", "true")
    monkeypatch.setenv("GLORY_SUPABASE_URL", "https://example.supabase.co")
    # 🔴 数据库串必须清空。不清的话 lifespan 会拿 backend/.env 里那串去
    # **连真库** —— 测试连生产库既慢又危险，而且在 CI 上（没有 .env）会直接失败。
    # db.connect("") 不建池也不抛异常，正是为这种情况留的。
    monkeypatch.setenv("GLORY_DATABASE_URL", "")
    # lru_cache 必须清，否则上面三条 setenv 一条都不生效。
    get_settings.cache_clear()

    monkeypatch.setattr(db, "is_connected", lambda: True)
    monkeypatch.setattr(ws_routes, "get_verifier", _FakeVerifier)

    known = {
        "auth-uid-1": _FakePlayer(uuid.UUID("11111111-1111-1111-1111-111111111111")),
        "auth-uid-2": _FakePlayer(uuid.UUID("22222222-2222-2222-2222-222222222222")),
    }

    async def _fake_lookup(auth_uid: str):
        return known.get(auth_uid)

    monkeypatch.setattr(players, "get_by_auth_uid", _fake_lookup)

    realtime.reset_hub()
    yield known
    realtime.reset_hub()
    get_settings.cache_clear()


def _headers(token: str = "good-token", device: str = DEVICE_A) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}", "X-Device-Session": device}


# --- 单实例令牌 ---------------------------------------------------------------


def test_second_claim_on_same_port_fails() -> None:
    """第二次抢同一个端口必须失败。

    这是 `app/single_instance.py` 的**全部价值**：让第二个进程起不来。
    它一旦失效不会有任何症状 —— 直到有人加了 worker，
    然后一部分玩家开始收不到消息，而日志里什么都没有。
    """
    port = _free_port()
    first = single_instance.claim(port)
    try:
        with pytest.raises(single_instance.SingleInstanceError):
            single_instance.claim(port)
    finally:
        single_instance.release(first)


def test_lock_is_reusable_after_release() -> None:
    """放锁之后能再抢到 —— 否则重启服务需要等 TIME_WAIT，运维会很难受。"""
    port = _free_port()
    first = single_instance.claim(port)
    single_instance.release(first)
    second = single_instance.claim(port)
    single_instance.release(second)


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


# --- 握手拒绝 -----------------------------------------------------------------


@pytest.mark.parametrize(
    "headers",
    [
        pytest.param({"X-Device-Session": DEVICE_A}, id="没有 Authorization"),
        pytest.param({"Authorization": "Bearer good-token"}, id="没有设备标识"),
        pytest.param(
            {"Authorization": "good-token", "X-Device-Session": DEVICE_A},
            id="缺 Bearer 前缀",
        ),
        pytest.param(
            {"Authorization": "Bearer nope", "X-Device-Session": DEVICE_A},
            id="令牌验不过",
        ),
        # 下面三条都是**合法的 HTTP header 值**，所以确实会发到服务端 ——
        # 测的是服务端那条 _DEVICE_RE，不是客户端库的防线。
        # （最早写的两条是中文和带换行的值，httpx 在本地就拒绝了，
        #   于是测试"通过"但一个字节都没到过服务端 —— 那是假绿。）
        pytest.param(
            {"Authorization": "Bearer good-token", "X-Device-Session": "ab"},
            id="设备标识太短",
        ),
        pytest.param(
            {"Authorization": "Bearer good-token", "X-Device-Session": "x" * 65},
            id="设备标识太长",
        ),
        pytest.param(
            {"Authorization": "Bearer good-token", "X-Device-Session": "device with spaces"},
            id="设备标识字符集不合",
        ),
    ],
)
def test_handshake_rejected(wired, headers: dict[str, str]) -> None:
    """这些一律连不上，且**不进连接表**。

    设备标识那两条不是洁癖：它会进日志，不限形状的话一个构造出来的值
    就能往日志里塞换行与控制字符。同 text_guard 对昵称做结构管控的理由。
    """
    client = TestClient(app)
    with client, pytest.raises(WebSocketDisconnect):
        with client.websocket_connect("/v1/ws", headers=headers) as ws:
            ws.receive_json()
    assert realtime.hub().connection_count() == 0


# --- 正常连接 -----------------------------------------------------------------


def test_ready_then_ping_pong(wired) -> None:
    client = TestClient(app)
    with client, client.websocket_connect("/v1/ws", headers=_headers()) as ws:
        ready = ws.receive_json()
        assert ready["t"] == "ready"
        assert ready["player_id"] == "11111111-1111-1111-1111-111111111111"
        # 心跳间隔由**服务端下发**，不写死在客户端。
        # 两边各写一份的话，改了服务端而客户端还按旧值发，会被判成超时掉线。
        assert ready["heartbeat_sec"] == realtime.HEARTBEAT_INTERVAL_SEC
        ws.send_json({"t": "ping"})
        assert ws.receive_json() == {"t": "pong"}


def test_unknown_type_does_not_close(wired) -> None:
    """未知消息类型只回一条错误，**不掐连接**。

    客户端比服务端新的时候（灰度、玩家没更新的旧包）一定会发服务端不认识的东西。
    为此掐掉整条连接是过度反应 —— 那会让一个本来只是「这条消息没处理」的问题
    升级成「聊天完全不能用」。
    """
    client = TestClient(app)
    with client, client.websocket_connect("/v1/ws", headers=_headers()) as ws:
        ws.receive_json()
        ws.send_json({"t": "no-such-type"})
        assert ws.receive_json() == {"t": "error", "code": "unknown_type"}
        # 连接还活着
        ws.send_json({"t": "ping"})
        assert ws.receive_json() == {"t": "pong"}


def test_oversized_message_rejected_but_connection_survives(wired) -> None:
    client = TestClient(app)
    with client, client.websocket_connect("/v1/ws", headers=_headers()) as ws:
        ws.receive_json()
        ws.send_text("x" * (realtime.MAX_MESSAGE_BYTES + 1))
        assert ws.receive_json() == {"t": "error", "code": "message_too_large"}
        ws.send_json({"t": "ping"})
        assert ws.receive_json() == {"t": "pong"}


def test_bad_json_rejected(wired) -> None:
    client = TestClient(app)
    with client, client.websocket_connect("/v1/ws", headers=_headers()) as ws:
        ws.receive_json()
        ws.send_text("{not json")
        assert ws.receive_json() == {"t": "error", "code": "bad_json"}


# --- 🔴 顶号 vs 重连 ----------------------------------------------------------


def test_other_device_gets_kicked_with_reason(wired) -> None:
    """换一台设备连进来 -> 旧设备收到 kicked，且**带得出原因**。

    只给一个关闭码不够：弱网下客户端多半来不及读就当成断线重连了，
    于是玩家看到的是「莫名其妙掉线又自动重连」，而不是「你的号在别处登录了」。
    这两件事在玩家眼里完全不同。
    """
    client = TestClient(app)
    with client:
        with client.websocket_connect("/v1/ws", headers=_headers(device=DEVICE_A)) as first:
            first.receive_json()
            with client.websocket_connect("/v1/ws", headers=_headers(device=DEVICE_B)) as second:
                assert second.receive_json()["t"] == "ready"
                kicked = first.receive_json()
                assert kicked == {"t": "kicked", "reason": "another_device"}


def test_same_device_reconnect_is_silent(wired) -> None:
    """🔴 同一台设备重连 -> 旧连接被断，但**绝不能发 kicked**。

    这是本文件最重要的一条。移动端切网、锁屏、被系统冻结之后重连是**常态**，
    把它误报成顶号会让玩家以为号被盗 —— 而代码里两种情况长得一模一样
    （都是「同一个账号又连进来一条」），区别只在 device_session_id。
    """
    client = TestClient(app)
    with client:
        with client.websocket_connect("/v1/ws", headers=_headers(device=DEVICE_A)) as first:
            first.receive_json()
            with client.websocket_connect("/v1/ws", headers=_headers(device=DEVICE_A)) as second:
                assert second.receive_json()["t"] == "ready"
                # 断开了 —— 但断开之前没有任何一条 kicked。
                # receive 直接抛 disconnect，而不是先给出一条消息，
                # 正是「悄悄断」的机器可读形式。
                with pytest.raises(WebSocketDisconnect):
                    first.receive_json()


def test_two_players_do_not_disturb_each_other(wired) -> None:
    """不同账号各连各的，谁也不该被谁踢掉。"""
    client = TestClient(app)
    with client:
        with client.websocket_connect("/v1/ws", headers=_headers("good-token")) as one:
            one.receive_json()
            with client.websocket_connect(
                "/v1/ws", headers=_headers("good-token-2", DEVICE_B)
            ) as two:
                two.receive_json()
                assert realtime.hub().player_count() == 2
                one.send_json({"t": "ping"})
                assert one.receive_json() == {"t": "pong"}


# --- 连接表自身 ---------------------------------------------------------------


def test_unregister_does_not_evict_the_replacement() -> None:
    """🔴 被顶掉的旧连接走 finally 时，不能把新连接从表里删掉。

    时序是这样的：新连接 register -> 旧连接被 close -> 旧连接的 handler 醒来 ->
    走到自己的 finally -> unregister(自己)。这时表里那个 key 上挂的已经是新连接了。
    照 key 删的话，**新连接会从表里消失但仍然连着** ——
    症状是「顶号之后新设备也收不到消息」，而且不报错、连接看着也是通的。
    """
    hub = realtime.Hub()
    pid = uuid.uuid4()
    old = realtime.Connection(player_id=pid, device_session_id=DEVICE_A, websocket=None)  # type: ignore[arg-type]
    new = realtime.Connection(player_id=pid, device_session_id=DEVICE_A, websocket=None)  # type: ignore[arg-type]
    hub._by_player[pid] = {DEVICE_A: new}

    hub.unregister(old)

    assert hub._by_player[pid][DEVICE_A] is new, "旧连接把顶替它的那条删掉了"
    hub.unregister(new)
    assert hub.connection_count() == 0


def test_idle_detection_uses_a_margin_over_heartbeat() -> None:
    """超时阈值必须明显大于心跳间隔，且容得下丢一两次。

    钉死这条不变量的理由与 friends.PRESENCE_TTL 完全相同：两个常数分别放在
    客户端与服务端，分开改不会有任何症状 —— 直到弱网玩家开始成片掉线。
    """
    assert realtime.IDLE_TIMEOUT_SEC > realtime.HEARTBEAT_INTERVAL_SEC * 2, (
        "IDLE_TIMEOUT_SEC 必须容得下连丢两次心跳，否则弱网下会踢掉正常玩家"
    )
    # 巡检周期要短于超时，否则一条死连接最长会在表里多待一个巡检周期。
    assert realtime.SWEEP_INTERVAL_SEC < realtime.IDLE_TIMEOUT_SEC
