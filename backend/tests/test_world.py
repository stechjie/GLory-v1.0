"""世界频道、禁言、举报（`docs/聊天系统设计.md` 批次 E，database/019_world_chat.sql）。

前半段**不连数据库**（同 test_chat 的分工）：路由接线、推送只给订阅的人、各道关的顺序、文本规则。
后半段是真库（pg_harness；没设 GLORY_TEST_PG 就跳过）：019 的函数、去重、翻页、证据快照、注销。

最重要的几条，失败模式都**不会报错**：
  1. 推送只给**订阅了**世界频道的连接 —— 写成全体广播不报错，只是对局里的人白白收流量。
  2. 同一条重试（client_msg_id 相同）回原来那条、不再推、不吃 8 秒 CD —— 否则玩家看到「发太快了」，
     那句话却已经在频道里。
  3. 文字先判、CD 后判：被拦下来的一条改一改能马上重发。
  4. 名字按发言那一刻存：往上翻查出来的、进程内的、推送的是同一个名字。
  5. 举报的证据是服务器当场复制的，不收客户端上传的记录；重复举报只算一条。

跑（从 backend/ 目录）：
    .venv/Scripts/python -m pytest -q tests/test_world.py
"""

from __future__ import annotations

import datetime as dt
import pathlib
import uuid
from dataclasses import dataclass

import asyncpg
import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketState

from app import admin, db, players, realtime, reports, text_guard, world_chat
from app.admin_auth import Admin
from app.config import get_settings
from app.jwt_verify import Claims, TokenError
from app.main import app
from app.routes import me as me_routes
from app.routes import reports as report_routes
from app.routes import world as world_routes
from app.routes import ws as ws_routes
from pg_harness import new_player, requires_pg, run_with_db

REPO = pathlib.Path(__file__).resolve().parents[2]
SQL_019 = (REPO / "database" / "019_world_chat.sql").read_text(encoding="utf-8")
NEW_TABLES = ("world_messages", "player_mutes", "player_reports")

PLAYER_A = uuid.UUID("11111111-1111-1111-1111-111111111111")
PLAYER_B = uuid.UUID("22222222-2222-2222-2222-222222222222")
CODE_A = "AAAA2222"
CODE_B = "BBBB3333"
_WHEN = dt.datetime(2026, 9, 27, 12, 0, tzinfo=dt.UTC)


def _sql_code(sql: str) -> str:
    return "\n".join(line.split("--", 1)[0] for line in sql.splitlines())


# --- 测试替身（同 test_chat）--------------------------------------------------------


@dataclass
class _FakePlayer:
    player_id: uuid.UUID
    player_name: str
    friend_code: str


_KNOWN = {
    "auth-a": _FakePlayer(PLAYER_A, "阿甲", CODE_A),
    "auth-b": _FakePlayer(PLAYER_B, "阿乙", CODE_B),
}


class _FakeVerifier:
    accept = {"token-a": "auth-a", "token-b": "auth-b"}

    async def verify(self, token: str) -> Claims:
        uid = self.accept.get(token)
        if uid is None:
            raise TokenError("令牌校验失败")
        return Claims(auth_uid=uid, is_anonymous=True, expires_at=0)


def _reset_limiters() -> None:
    world_routes._cooldown.reset()
    world_routes._global.reset()
    world_routes._history_limiter.reset()
    report_routes._limiter.reset()


@pytest.fixture
def wired(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("GLORY_DISABLE_INSTANCE_LOCK", "true")
    monkeypatch.setenv("GLORY_SUPABASE_URL", "https://example.supabase.co")
    # 🔴 清空数据库串（同 test_ws）：不清的话 lifespan 会拿 backend/.env 里那串去连真库。
    monkeypatch.setenv("GLORY_DATABASE_URL", "")
    get_settings.cache_clear()
    monkeypatch.setattr(db, "is_connected", lambda: True)
    monkeypatch.setattr(me_routes, "get_verifier", _FakeVerifier)
    monkeypatch.setattr(ws_routes, "get_verifier", _FakeVerifier)

    async def _lookup(auth_uid: str):
        return _KNOWN.get(auth_uid)

    monkeypatch.setattr(players, "get_by_auth_uid", _lookup)
    realtime.reset_hub()
    world_chat.reset_channel()
    _reset_limiters()
    yield
    realtime.reset_hub()
    world_chat.reset_channel()
    _reset_limiters()
    get_settings.cache_clear()


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": "Bearer %s" % token}


def _ws_headers(token: str, device: str) -> dict[str, str]:
    return {"Authorization": "Bearer %s" % token, "X-Device-Session": device}


def _fake_post(calls: list):
    """代替 world_chat.post（那个要连库）：照真的那样推给订阅了的连接。"""

    async def _post(player, body, client_msg_id):
        calls.append((player.player_id, body, client_msg_id))
        message = world_chat.WorldMessage(len(calls), player.player_id, player.friend_code, player.player_name,
                                          "preset:avatar_001", "", body, _WHEN)
        world_chat.channel().remember_post(message, client_msg_id)
        await realtime.hub().publish(world_chat.TOPIC, {"t": world_chat.PUSH_TYPE, "message": message.to_client()})
        return message, True

    return _post


def _send(client: TestClient, token: str, body: str = "有人一起排吗", client_msg_id: str | None = None):
    return client.post("/v1/world/messages", headers=_auth(token),
                       json={"body": body, "client_msg_id": client_msg_id or str(uuid.uuid4())})


def _subscribe(ws) -> None:
    ws.send_json({"t": "sub", "topic": "world"})
    # 服务端按顺序处理同一条连接上的消息：pong 回来说明 sub 已经生效了。
    ws.send_json({"t": "ping"})
    assert ws.receive_json() == {"t": "pong"}


# --- 🔴 推送只给订阅了的连接 ---------------------------------------------------------


def test_push_reaches_only_subscribed_connections(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list = []
    monkeypatch.setattr(world_chat, "post", _fake_post(calls))
    client = TestClient(app)
    with client, client.websocket_connect("/v1/ws", headers=_ws_headers("token-a", "device-aaaaaaaa")) as ws_a, \
            client.websocket_connect("/v1/ws", headers=_ws_headers("token-b", "device-bbbbbbbb")) as ws_b:
        assert ws_a.receive_json()["t"] == "ready"
        assert ws_b.receive_json()["t"] == "ready"
        _subscribe(ws_b)
        r = _send(client, "token-a")
        assert r.status_code == 200, r.text
        pushed = ws_b.receive_json()
        assert pushed["t"] == "world"
        assert pushed["message"]["from_code"] == CODE_A and pushed["message"]["body"] == "有人一起排吗"
        # 没订阅的 A 什么都没收到：下一条必须是 pong。
        ws_a.send_json({"t": "ping"})
        assert ws_a.receive_json() == {"t": "pong"}
        # 退订之后 B 也不收了。
        ws_b.send_json({"t": "unsub", "topic": "world"})
        ws_b.send_json({"t": "ping"})
        assert ws_b.receive_json() == {"t": "pong"}
        assert _send(client, "token-b").status_code == 200
        ws_b.send_json({"t": "ping"})
        assert ws_b.receive_json() == {"t": "pong"}


def test_unknown_topic_is_refused_without_dropping_the_connection(wired) -> None:
    client = TestClient(app)
    with client, client.websocket_connect("/v1/ws", headers=_ws_headers("token-b", "device-bbbbbbbb")) as ws:
        ws.receive_json()
        ws.send_json({"t": "sub", "topic": "everything"})
        assert ws.receive_json() == {"t": "error", "code": "unknown_topic"}
        ws.send_json({"t": "ping"})
        assert ws.receive_json() == {"t": "pong"}
    assert realtime.TOPICS == {world_chat.TOPIC}


# --- 各道关的顺序 ------------------------------------------------------------------


def test_cooldown_is_per_player_and_retry_after_is_set(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list = []
    monkeypatch.setattr(world_chat, "post", _fake_post(calls))
    with TestClient(app) as client:
        assert _send(client, "token-a").status_code == 200
        limited = _send(client, "token-a")
        assert limited.status_code == 429
        assert limited.headers["X-Glory-Reason"] == "cooldown"
        assert 1 <= int(limited.headers["Retry-After"]) <= int(world_chat.COOLDOWN_SEC) + 1
        # 另一个人不受影响（按 player_id 计，不按 IP）。
        assert _send(client, "token-b").status_code == 200
    assert len(calls) == 2


def test_rejected_text_does_not_burn_the_cooldown(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    """文字先判：留了电话号码被拦下来，改一改马上能重发，不用干等 8 秒。"""
    calls: list = []
    monkeypatch.setattr(world_chat, "post", _fake_post(calls))
    with TestClient(app) as client:
        rejected = _send(client, "token-a", "加我 012-345 6789")
        assert rejected.status_code == 400
        assert rejected.headers["X-Glory-Reason"] == "contact_phone"
        assert _send(client, "token-a", "加我好友吧").status_code == 200
    assert len(calls) == 1


def test_retry_with_same_client_msg_id_returns_the_first_message(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    """同一条重试：回第一次那条，不吃 CD、不再写、不再推。"""
    calls: list = []
    monkeypatch.setattr(world_chat, "post", _fake_post(calls))
    msg_id = str(uuid.uuid4())
    with TestClient(app) as client:
        first = _send(client, "token-a", client_msg_id=msg_id)
        again = _send(client, "token-a", client_msg_id=msg_id)
        assert first.status_code == again.status_code == 200
        assert again.json() == first.json()
    assert len(calls) == 1


def test_muted_player_gets_a_readable_reason(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    async def _muted(player, body, client_msg_id):
        raise world_chat.Muted(world_chat.Mute("世界频道刷屏", None))

    monkeypatch.setattr(world_chat, "post", _muted)
    with TestClient(app) as client:
        r = _send(client, "token-a")
    assert r.status_code == 403
    assert r.headers["X-Glory-Reason"] == "muted"
    assert "永久禁言" in r.json()["detail"] and "世界频道刷屏" in r.json()["detail"]


def test_missing_tables_answer_503_not_500(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    """019 没跑：世界频道回 503，其余照常（同 016 没跑时封号放行的思路）。"""

    async def _unavailable(*_args):
        raise world_chat.WorldUnavailable("019 没跑")

    monkeypatch.setattr(world_chat, "post", _unavailable)
    monkeypatch.setattr(world_chat, "latest", _unavailable)
    with TestClient(app) as client:
        assert _send(client, "token-a").status_code == 503
        r = client.get("/v1/world/messages", headers=_auth("token-a"))
        assert r.status_code == 503 and r.headers["X-Glory-Reason"] == "world_unavailable"


def test_history_pages_and_has_more(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    seen: list = []

    def _msg(i: int) -> world_chat.WorldMessage:
        return world_chat.WorldMessage(i, PLAYER_A, CODE_A, "阿甲", "", "", "第%d句" % i, _WHEN)

    async def _latest(limit):
        seen.append(("latest", limit))
        return [_msg(i) for i in range(101 - limit, 101)]

    async def _older(before, limit):
        seen.append(("older", before, limit))
        return [_msg(1)]

    monkeypatch.setattr(world_chat, "latest", _latest)
    monkeypatch.setattr(world_chat, "older", _older)
    with TestClient(app) as client:
        first = client.get("/v1/world/messages", headers=_auth("token-a")).json()
        assert [m["message_id"] for m in first["messages"]] == list(range(1, 101))
        assert first["has_more"] is True
        page = client.get("/v1/world/messages?before=50&limit=20", headers=_auth("token-a")).json()
        assert page == {"messages": [_msg(1).to_client()], "has_more": False}
        assert client.get("/v1/world/messages?limit=500", headers=_auth("token-a")).status_code == 422
    assert seen == [("latest", world_chat.RING_SIZE), ("older", 50, 20)]


def test_history_paging_is_rate_limited(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    async def _older(before, limit):
        return []

    monkeypatch.setattr(world_chat, "older", _older)
    with TestClient(app) as client:
        for _ in range(world_routes.HISTORY_PER_MINUTE):
            assert client.get("/v1/world/messages?before=9", headers=_auth("token-a")).status_code == 200
        assert client.get("/v1/world/messages?before=9", headers=_auth("token-a")).status_code == 429


def test_send_route_calls_the_level_gate() -> None:
    """门槛函数今天放行所有人，但**调用点必须在**（设计文档第四节「等级门槛」）。"""
    import inspect
    assert "can_speak_in_world(me)" in inspect.getsource(world_routes.send_world_message)
    assert world_chat.can_speak_in_world(_KNOWN["auth-a"]) is True


def test_routes_are_registered() -> None:
    paths = app.openapi()["paths"]
    assert {"get", "post"} <= set(paths["/v1/world/messages"])
    assert "post" in paths["/v1/reports"]
    for path in ["/admin/api/world/{message_id}/hide", "/admin/api/players/{player_id}/mute",
                 "/admin/api/players/{player_id}/unmute", "/admin/api/reports/{report_id}/resolve"]:
        assert "post" in paths[path], path
    for path in ["/admin/api/reports", "/admin/api/reports/{report_id}", "/admin/api/world"]:
        assert "get" in paths[path], path


# --- 进程内的最近 N 条 ----------------------------------------------------------------


def test_ring_keeps_the_newest_and_drops_hidden() -> None:
    ch = world_chat.WorldChannel()
    for i in range(world_chat.RING_SIZE + 5):
        ch.add(world_chat.WorldMessage(i + 1, PLAYER_A, CODE_A, "阿甲", "", "", str(i), _WHEN))
    recent = ch.recent()
    assert len(recent) == world_chat.RING_SIZE and recent[-1].message_id == world_chat.RING_SIZE + 5
    assert ch.drop(recent[-1].message_id) and not ch.drop(999_999)
    assert all(m.message_id != world_chat.RING_SIZE + 5 for m in ch.recent())


def test_client_payload_hides_the_internal_player_id() -> None:
    payload = world_chat.WorldMessage(7, PLAYER_A, CODE_A, "阿甲", "a", "f", "hi", _WHEN).to_client()
    assert str(PLAYER_A) not in str(payload)
    assert set(payload) == {"message_id", "from_code", "name", "avatar", "avatar_frame", "body", "created_at"}


# --- 文本规则 ------------------------------------------------------------------------


@pytest.mark.parametrize("raw", [
    "加我 012-345 6789", "+6012 3456789", "打给我 0123456789", "whatsapp 我", "WA: 60123456789",
    "进 discord.gg/abcd", "看 www.example.my", "fb: glory.player", "我的号 123 456 7890",
    "t.me/gloryshop", "加V: abc123",
])
def test_world_text_rejects_contact_info(raw: str) -> None:
    with pytest.raises(text_guard.TextRejected) as exc:
        text_guard.clean_world_message(raw)
    assert exc.value.code.startswith("contact_")
    assert "世界频道" in exc.value.message


@pytest.mark.parametrize("raw", [
    "2026-09-27 晚上 8:30 开一局", "第 3 回合我升三星", "100 金币就够了", "class 真好玩", "我这把稳了",
])
def test_world_text_keeps_ordinary_chat(raw: str) -> None:
    assert text_guard.clean_world_message(raw) == raw


def test_world_text_flattens_lines_and_checks_length() -> None:
    assert text_guard.clean_world_message("第一行\n第二行") == "第一行 第二行"
    assert text_guard.clean_world_message("字" * text_guard.WORLD_MAX) == "字" * text_guard.WORLD_MAX
    with pytest.raises(text_guard.TextRejected) as exc:
        text_guard.clean_world_message("字" * (text_guard.WORLD_MAX + 1))
    assert exc.value.code == "length"


def test_blocklist_latin_words_match_whole_words_only(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(text_guard, "_load_blocklist", lambda: frozenset({"ass", "fuck*", "傻逼", "haram jadah"}))
    for bad in ["you ass", "ASS!", "fucking noob", "what the fuck", "你个傻逼", "dasar haram jadah"]:
        with pytest.raises(text_guard.TextRejected):
            text_guard.clean_world_message(bad)
    for ok in ["class", "pass me", "assassin", "grass"]:
        assert text_guard.clean_world_message(ok) == ok


def test_shipped_blocklist_loads_and_catches_the_obvious() -> None:
    words = text_guard._load_blocklist()
    assert len(words) > 50, "data/blocked_words.txt 是空的？世界频道第一版只靠本地规则"
    for bad in ["操你妈", "fuck you", "babi", "cibai"]:
        with pytest.raises(text_guard.TextRejected):
            text_guard.clean_world_message(bad)
    # 🔴 误伤：常见的正常话不能被拦（「妈的」这种短词故意没收，见文件头）。
    for ok in ["我妈的手机没电了", "class", "assist 一下", "上去死守", "打得好"]:
        assert text_guard.clean_world_message(ok) == ok


def test_signature_uses_the_same_contact_rules() -> None:
    with pytest.raises(text_guard.TextRejected) as exc:
        text_guard.clean_signature("WA 012-345 6789")
    assert exc.value.message == "签名里不能留联系方式或外链"


def test_report_detail_is_structural_only() -> None:
    assert text_guard.clean_report_detail("  ") is None
    assert text_guard.clean_report_detail("他说 012-345 6789 加他") == "他说 012-345 6789 加他"
    with pytest.raises(text_guard.TextRejected):
        text_guard.clean_report_detail("x" + chr(0x202E) + "y")
    with pytest.raises(text_guard.TextRejected):
        text_guard.clean_report_detail("字" * (text_guard.REPORT_DETAIL_MAX + 1))


# --- 跨语言与 SQL 的一致性 --------------------------------------------------------------


def test_limits_match_the_database() -> None:
    code = _sql_code(SQL_019)
    assert "char_length(body) between 1 and %d" % text_guard.WORLD_MAX in code
    assert "char_length(detail) <= %d" % text_guard.REPORT_DETAIL_MAX in code
    for value in reports.CONTEXTS + reports.REASONS:
        assert "'%s'" % value in code


def test_every_new_table_has_rls_and_is_checked() -> None:
    code = _sql_code(SQL_019)
    for table in NEW_TABLES:
        assert "create table %s" % table in code
        assert "alter table %s enable row level security" % table in code
        assert table in db.EXPECTED_TABLES
    assert "create policy" not in code


# --- 举报接口（不连库的部分）------------------------------------------------------------


def test_report_route_validates_and_rate_limits(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list = []

    async def _create(reporter, target_code, context, reason, message_id, detail):
        calls.append((reporter.player_id, target_code, context, reason, message_id, detail))
        if context not in reports.CONTEXTS:
            raise reports.ReportRejected("bad_context", "不认识的举报场合")
        return 41, len(calls) > 1

    monkeypatch.setattr(reports, "create", _create)
    with TestClient(app) as client:
        ok = client.post("/v1/reports", headers=_auth("token-a"),
                         json={"target_code": CODE_B.lower(), "context": "world", "reason": "abuse",
                               "message_id": 7, "detail": " 骂人 "})
        assert ok.status_code == 200 and ok.json() == {"report_id": 41}
        # 重复举报：响应和第一次长得一样（不告诉他「你举报过了」）。
        again = client.post("/v1/reports", headers=_auth("token-a"),
                            json={"target_code": CODE_B, "context": "world", "reason": "abuse"})
        assert again.json() == ok.json()
        bad = client.post("/v1/reports", headers=_auth("token-a"),
                          json={"target_code": CODE_B, "context": "moon", "reason": "abuse"})
        assert bad.status_code == 400 and bad.headers["X-Glory-Reason"] == "bad_context"
        for _ in range(report_routes.REPORTS_PER_HOUR - 3):
            client.post("/v1/reports", headers=_auth("token-a"),
                        json={"target_code": CODE_B, "context": "profile", "reason": "name"})
        assert client.post("/v1/reports", headers=_auth("token-a"),
                           json={"target_code": CODE_B, "context": "profile", "reason": "name"}).status_code == 429
    # 好友码归一成大写、补充说明去掉首尾空白。
    assert calls[0] == (PLAYER_A, CODE_B, "world", "abuse", 7, "骂人")


# ==============================================================================
# 真库（pg_harness）
# ==============================================================================

ALICE = Admin(uuid.uuid4(), "alice")


class _CaptureSocket:
    """假的 WebSocket：只记下推过来的东西。"""

    def __init__(self) -> None:
        self.client_state = WebSocketState.CONNECTED
        self.sent: list[dict] = []

    async def send_json(self, payload: dict) -> None:
        self.sent.append(payload)


async def _player(conn: asyncpg.Connection, name: str) -> players.Player:
    pid = await new_player(conn)
    await conn.execute("update players set player_name = $2 where player_id = $1", pid, name)
    code = await conn.fetchval("select friend_code from players where player_id = $1", pid)
    return players.Player(pid, name, False, str(code))


async def _watcher() -> _CaptureSocket:
    sock = _CaptureSocket()
    conn = realtime.Connection(player_id=uuid.uuid4(), device_session_id="watcher-0001", websocket=sock)
    await realtime.hub().register(conn)
    conn.topics.add(world_chat.TOPIC)
    return sock


@requires_pg
def test_post_stores_snapshot_dedupes_and_pushes() -> None:
    async def body() -> None:
        realtime.reset_hub()
        world_chat.reset_channel()
        async with db.pool().acquire() as conn:
            a = await _player(conn, "阿甲")
        sock = await _watcher()
        key = uuid.uuid4()
        first, created = await world_chat.post(a, "有人一起排吗", key)
        assert created and first.name == "阿甲" and first.friend_code == a.friend_code
        again, created_again = await world_chat.post(a, "有人一起排吗", key)
        assert not created_again and again.message_id == first.message_id
        assert [p["t"] for p in sock.sent] == ["world"], "重试不能再推一次"
        # 改名之后：库里、进程内都还是发言那一刻的名字。
        async with db.pool().acquire() as conn:
            await conn.execute("update players set player_name = '新名字' where player_id = $1", a.player_id)
        world_chat.reset_channel()
        latest = await world_chat.latest(10)
        assert [(m.message_id, m.name) for m in latest] == [(first.message_id, "阿甲")]

    run_with_db(body)


@requires_pg
def test_paging_hidden_and_purge() -> None:
    async def body() -> None:
        realtime.reset_hub()
        world_chat.reset_channel()
        async with db.pool().acquire() as conn:
            a = await _player(conn, "阿甲")
        ids = [(await world_chat.post(a, "第%d句" % i, uuid.uuid4()))[0].message_id for i in range(5)]
        older = await world_chat.older(ids[3], 2)
        assert [m.message_id for m in older] == ids[1:3]
        # 运营删一条：往上翻、进程内都看不到；推一条 world_hide。
        sock = await _watcher()
        await admin.hide_world_message(ALICE, ids[2], "广告")
        assert sock.sent == [{"t": "world_hide", "message_id": ids[2]}]
        assert ids[2] not in [m.message_id for m in await world_chat.older(ids[4], 10)]
        assert ids[2] not in [m.message_id for m in world_chat.channel().recent()]
        with pytest.raises(admin.AdminRejected):
            await admin.hide_world_message(ALICE, ids[2], "又删一次")
        # 7 天前的清掉，别的不动。
        async with db.pool().acquire() as conn:
            await conn.execute("update world_messages set created_at = now() - interval '8 days'"
                               " where message_id = $1", ids[0])
            assert await world_chat.purge(conn) == 1
            assert await conn.fetchval("select count(*) from world_messages") == 4
            actions = [r["action"] for r in await conn.fetch("select action from admin_audit")]
        assert actions == ["world.hide"]

    run_with_db(body)


@requires_pg
def test_mute_blocks_world_posts_until_lifted() -> None:
    async def body() -> None:
        realtime.reset_hub()
        world_chat.reset_channel()
        async with db.pool().acquire() as conn:
            a = await _player(conn, "阿甲")
        await admin.mute(ALICE, a.player_id, 24, "世界频道刷屏", "举报 #1")
        with pytest.raises(world_chat.Muted) as exc:
            await world_chat.post(a, "我又来了", uuid.uuid4())
        assert exc.value.mute.reason == "世界频道刷屏" and exc.value.mute.ends_at is not None
        detail = await admin.player_detail(a.player_id)
        assert detail["mute"]["reason"] == "世界频道刷屏" and len(detail["mutes"]) == 1
        await admin.unmute(ALICE, a.player_id, "误判")
        message, created = await world_chat.post(a, "好了", uuid.uuid4())
        assert created
        with pytest.raises(admin.AdminRejected):
            await admin.unmute(ALICE, a.player_id, "")
        async with db.pool().acquire() as conn:
            with pytest.raises(asyncpg.RaiseError):
                await conn.fetchval("select mute_player($1, interval '1 day', ' ', 'pytest')", a.friend_code)
            actions = [r["action"] for r in await conn.fetch("select action from admin_audit order by audit_id")]
        assert actions == ["mute", "unmute"]

    run_with_db(body)


@requires_pg
def test_report_snapshots_evidence_server_side_and_counts_once() -> None:
    async def body() -> None:
        realtime.reset_hub()
        world_chat.reset_channel()
        async with db.pool().acquire() as conn:
            reporter = await _player(conn, "路人")
            target = await _player(conn, "喷子")
        bad, _ = await world_chat.post(target, "你们都是垃圾", uuid.uuid4())
        report_id, dup = await reports.create(reporter, target.friend_code, "world", "abuse", bad.message_id, "骂人")
        assert not dup
        again, dup_again = await reports.create(reporter, target.friend_code, "world", "abuse", None, None)
        assert dup_again and again == report_id
        detail = await admin.report_detail(report_id)
        evidence = detail["evidence"]
        assert evidence["world_message"]["body"] == "你们都是垃圾"
        assert [m["body"] for m in evidence["world_recent"]] == ["你们都是垃圾"]
        assert evidence["profile"]["player_name"] == "喷子"
        assert detail["note_from_reporter"] == "骂人" and detail["target_code"] == target.friend_code
        # 7 天后原消息被清掉，证据还在。
        async with db.pool().acquire() as conn:
            await conn.execute("delete from world_messages")
        assert (await admin.report_detail(report_id))["evidence"]["world_message"]["body"] == "你们都是垃圾"
        # 处理之后同一个人可以再举报一次（新的一条）。
        await admin.resolve_report(ALICE, report_id, "resolved", "已禁言")
        with pytest.raises(admin.AdminRejected):
            await admin.resolve_report(ALICE, report_id, "dismissed", "")
        new_id, _ = await reports.create(reporter, target.friend_code, "world", "ads", None, None)
        assert new_id != report_id
        assert [r["report_id"] for r in await admin.list_reports("open")] == [new_id]
        with pytest.raises(reports.ReportRejected):
            await reports.create(reporter, reporter.friend_code, "profile", "name", None, None)

    run_with_db(body)


@requires_pg
def test_dm_report_takes_the_conversation_from_the_server() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            reporter = await _player(conn, "路人")
            target = await _player(conn, "骗子")
            low, high = sorted([reporter.player_id, target.player_id])
            await conn.execute("insert into chat_conversations (low_id, high_id) values ($1, $2)", low, high)
            await conn.execute(
                "insert into chat_messages (low_id, high_id, sender_id, body, client_msg_id)"
                " values ($1, $2, $3, '把号借我', gen_random_uuid()), ($1, $2, $4, '不要', gen_random_uuid())",
                low, high, target.player_id, reporter.player_id)
        report_id, _ = await reports.create(reporter, target.friend_code, "dm", "cheat", None, None)
        dm = (await admin.report_detail(report_id))["evidence"]["dm_recent"]
        assert dm == [{"from": "target", "body": "把号借我", "created_at": dm[0]["created_at"]},
                      {"from": "reporter", "body": "不要", "created_at": dm[1]["created_at"]}]

    run_with_db(body)


@requires_pg
def test_erase_player_deletes_world_messages_but_keeps_sanctions() -> None:
    async def body() -> None:
        realtime.reset_hub()
        world_chat.reset_channel()
        async with db.pool().acquire() as conn:
            reporter = await _player(conn, "路人")
            target = await _player(conn, "喷子")
        await world_chat.post(target, "垃圾", uuid.uuid4())
        await reports.create(reporter, target.friend_code, "world", "abuse", None, None)
        await admin.mute(ALICE, target.player_id, None, "辱骂", "")
        async with db.pool().acquire() as conn:
            assert await conn.fetchval("select erase_player($1)", target.player_id)
            assert await conn.fetchval("select count(*) from world_messages") == 0
            assert await conn.fetchval("select count(*) from player_mutes") == 1
            assert await conn.fetchval("select count(*) from player_reports") == 1

    run_with_db(body)


@requires_pg
def test_missing_019_tables_make_world_unavailable_not_broken() -> None:
    async def body() -> None:
        world_chat.reset_channel()
        async with db.pool().acquire() as conn:
            a = await _player(conn, "阿甲")
            b = await _player(conn, "阿乙")
            await conn.execute("drop table world_messages; drop table player_mutes; drop table player_reports")
        with pytest.raises(world_chat.WorldUnavailable):
            await world_chat.latest(10)
        with pytest.raises(world_chat.WorldUnavailable):
            await world_chat.post(a, "hi", uuid.uuid4())
        with pytest.raises(reports.ReportsUnavailable):
            await reports.create(a, b.friend_code, "profile", "name", None, None)
        # 玩家页照常打开，只是这三样是空的。
        detail = await admin.player_detail(a.player_id)
        assert detail["mutes"] == [] and detail["world_recent"] == [] and detail["mute"] is None
        async with db.pool().acquire() as conn:
            assert await world_chat.purge(conn) == 0

    run_with_db(body)
