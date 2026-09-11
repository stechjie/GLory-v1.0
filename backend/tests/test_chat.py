"""好友私聊（`docs/聊天系统设计.md` 批次 C）的行为用例。

同 test_friends / test_ws 的分工：**不连数据库**。判据是纯函数、SQL 文本的静态一致性、
路由接线与推送。需要真库的部分（裁剪到 200 条、游标单调、重发去重在并发下的表现）
归真机 / 线上验证。

最重要的几组，它们的失败模式都**不会报错**：

  1. 推送：发出去的消息要推到对方的 WebSocket 上，而且 from 是**发送者**的好友码。
     写反了不报错，对方只会看到「自己给自己发了一条」。
  2. 静默丢弃（被拉黑后发的）：响应与真发出去的**长得一模一样**，且不推送。
  3. 已读游标：greatest() 只进不退、least() 不越过真实的最后一条。
  4. 容量的结构性上界：每对 200 条、会话不外键到好友关系（删好友后再留 30 天）。

跑（从 backend/ 目录，pytest.ini 在那里）：
    cd backend && .venv/Scripts/python -m pytest -q tests/test_chat.py
"""

from __future__ import annotations

import asyncio
import contextlib
import datetime as dt
import inspect
import pathlib
import re
import uuid
from dataclasses import dataclass

import pytest
from fastapi.testclient import TestClient

from app import chat, db, maintenance, players, realtime, text_guard
from app.config import get_settings
from app.jwt_verify import Claims, TokenError
from app.main import app
from app.routes import chat as chat_routes
from app.routes import me as me_routes
from app.routes import ws as ws_routes

REPO = pathlib.Path(__file__).resolve().parents[2]
SQL_007 = (REPO / "database" / "007_chat.sql").read_text(encoding="utf-8")
CHAT_PY = (REPO / "backend" / "app" / "chat.py").read_text(encoding="utf-8")

NEW_TABLES = ("chat_conversations", "chat_messages", "chat_read_state")

PLAYER_A = uuid.UUID("11111111-1111-1111-1111-111111111111")
PLAYER_B = uuid.UUID("22222222-2222-2222-2222-222222222222")
CODE_A = "AAAA2222"
CODE_B = "BBBB3333"
DEVICE_B = "device-bbbbbbbb"


def _sql_code(sql: str) -> str:
    """去掉 SQL 注释，只留代码。

    007 的注释里**写着**「绝不存 unread_count」「不外键到 player_friendships」——
    直接在全文里搜这些词，断言会被注释自己满足或者误伤。
    同 tools/procedural_ui_ratchet_check.gd 里那句「整文件 contains 被自己写的注释满足」。
    """
    return "\n".join(line.split("--", 1)[0] for line in sql.splitlines())


SQL_007_CODE = _sql_code(SQL_007)


# --- 测试替身 -----------------------------------------------------------------


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
    """按令牌串决定放不放行。生产上的 verify 会去打 JWKS，测试里不该联网。"""

    accept = {"token-a": "auth-a", "token-b": "auth-b"}

    async def verify(self, token: str) -> Claims:
        uid = self.accept.get(token)
        if uid is None:
            raise TokenError("令牌校验失败：测试用的假 verifier 不认识它")
        return Claims(auth_uid=uid, is_anonymous=True, expires_at=0)


@pytest.fixture
def wired(monkeypatch: pytest.MonkeyPatch):
    """HTTP 接口与 WS 端点都接到假的认证与玩家表上。"""
    monkeypatch.setenv("GLORY_DISABLE_INSTANCE_LOCK", "true")
    monkeypatch.setenv("GLORY_SUPABASE_URL", "https://example.supabase.co")
    # 🔴 数据库串必须清空，理由同 test_ws：不清的话 lifespan 会拿 backend/.env
    # 里那串去**连真库**。
    monkeypatch.setenv("GLORY_DATABASE_URL", "")
    get_settings.cache_clear()

    monkeypatch.setattr(db, "is_connected", lambda: True)
    monkeypatch.setattr(me_routes, "get_verifier", _FakeVerifier)
    monkeypatch.setattr(ws_routes, "get_verifier", _FakeVerifier)

    async def _lookup(auth_uid: str):
        return _KNOWN.get(auth_uid)

    monkeypatch.setattr(players, "get_by_auth_uid", _lookup)

    realtime.reset_hub()
    chat_routes._send_limiter.reset()
    yield
    realtime.reset_hub()
    chat_routes._send_limiter.reset()
    get_settings.cache_clear()


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": "Bearer %s" % token}


def _ws_headers(token: str = "token-b", device: str = DEVICE_B) -> dict[str, str]:
    return {"Authorization": "Bearer %s" % token, "X-Device-Session": device}


_WHEN = dt.datetime(2026, 9, 11, 12, 0, tzinfo=dt.timezone.utc)


def _fake_send(deliver_to: uuid.UUID | None, message_id: int = 41):
    calls: list[tuple] = []

    async def _send(sender_id, target_code, body, client_msg_id):
        calls.append((sender_id, target_code, body, client_msg_id))
        return chat.SendResult(
            message=chat.Message(message_id, sender_id, body, _WHEN),
            deliver_to=deliver_to,
        )

    return _send, calls


def _post_message(client: TestClient, token: str, to_code: str, body: str = "你好"):
    return client.post(
        "/v1/me/chats/%s/messages" % to_code,
        json={"body": body, "client_msg_id": str(uuid.uuid4())},
        headers=_auth(token),
    )


# --- 🔴 推送 ------------------------------------------------------------------


def test_send_pushes_to_recipient_websocket(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    """发出去的消息要推到对方的 WS 上，from 是**发送者**的好友码。

    推送里的 from_me 是相对**接收者**说的（False），响应里的是相对发送者（True）。
    两处用同一个 _item() 组装，只是视角不同 —— 写成同一个值的话，
    对方界面上会显示成「自己给自己发了一条」，而且不报错。
    """
    send, calls = _fake_send(deliver_to=PLAYER_B)
    monkeypatch.setattr(chat, "send", send)
    client = TestClient(app)
    with client, client.websocket_connect("/v1/ws", headers=_ws_headers()) as ws_b:
        assert ws_b.receive_json()["t"] == "ready"
        # 好友码小写发过去 —— 服务端要归一成大写（玩家会照着截图手抄）。
        r = _post_message(client, "token-a", CODE_B.lower())
        assert r.status_code == 200, r.text
        sent = r.json()["message"]
        assert sent["from_me"] is True

        pushed = ws_b.receive_json()
        assert pushed["t"] == chat_routes.DM_TYPE == "dm"
        assert pushed["from"] == CODE_A
        assert pushed["message"]["from_me"] is False
        assert pushed["message"]["message_id"] == sent["message_id"]
        assert pushed["message"]["body"] == "你好"

    assert calls[0][0] == PLAYER_A
    assert calls[0][1] == CODE_B


def test_silent_drop_looks_like_success_and_pushes_nothing(
    wired, monkeypatch: pytest.MonkeyPatch
) -> None:
    """被拉黑后发的：响应**长得和真发出去的一样**，而且不推送。

    已定（设计文档第八节第 7 条）：对发送方显示「已发送」。响应里只要多一个字段、
    少一个字段、或者 message_id 是 0 / null，被拉黑的人就能从响应里认出来。
    """
    normal_send, _ = _fake_send(deliver_to=PLAYER_B, message_id=41)
    dropped_send, _ = _fake_send(deliver_to=None, message_id=42)
    client = TestClient(app)
    with client, client.websocket_connect("/v1/ws", headers=_ws_headers()) as ws_b:
        ws_b.receive_json()

        monkeypatch.setattr(chat, "send", normal_send)
        normal = _post_message(client, "token-a", CODE_B)
        ws_b.receive_json()  # 真发的那条推过来了

        monkeypatch.setattr(chat, "send", dropped_send)
        dropped = _post_message(client, "token-a", CODE_B)
        assert dropped.status_code == normal.status_code == 200
        assert set(dropped.json()["message"]) == set(normal.json()["message"])
        assert dropped.json()["message"]["message_id"] > 0

        # 没有推送：下一条收到的必须是 pong，而不是一条 dm。
        ws_b.send_json({"t": "ping"})
        assert ws_b.receive_json() == {"t": "pong"}


def test_offline_recipient_is_not_an_error(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    """对方不在线时照样 200 —— 消息已经在库里，他下次打开时按游标拉。"""
    send, _ = _fake_send(deliver_to=PLAYER_B)
    monkeypatch.setattr(chat, "send", send)
    with TestClient(app) as client:
        assert _post_message(client, "token-a", CODE_B).status_code == 200


def test_delivery_does_not_consult_presence_visibility() -> None:
    """🔴 投递**绝不能**查隐身开关。

    已定：隐身的人照样收私聊（设计文档第八节第 6 条）。隐身管的是「别人能不能看到
    我在线」，与「消息能不能送到我这里」是两回事 —— 混在一起会造出
    「我隐身了所以朋友的消息收不到」这种没人能理解的行为。
    """
    source = inspect.getsource(chat_routes.send_message)
    assert "presence" not in source


# --- 限流与文本 ---------------------------------------------------------------


def test_rate_limit_is_per_player(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    """每人每分钟 SEND_PER_MINUTE 条，超了 429；**另一个玩家不受影响**。

    测试里两个人来自同一个 IP，所以第二个人还能发，证明计数按的是 player_id ——
    按 IP 计的话，运营商 NAT 下成片的正常玩家会互相挤掉额度。
    """
    send, _ = _fake_send(deliver_to=None)
    monkeypatch.setattr(chat, "send", send)
    with TestClient(app) as client:
        for _ in range(chat_routes.SEND_PER_MINUTE):
            assert _post_message(client, "token-a", CODE_B).status_code == 200
        limited = _post_message(client, "token-a", CODE_B)
        assert limited.status_code == 429
        assert int(limited.headers["Retry-After"]) >= 1
        assert _post_message(client, "token-b", CODE_A).status_code == 200


def test_text_is_cleaned_before_it_reaches_the_database(
    wired, monkeypatch: pytest.MonkeyPatch
) -> None:
    send, calls = _fake_send(deliver_to=None)
    monkeypatch.setattr(chat, "send", send)
    with TestClient(app) as client:
        ok = _post_message(client, "token-a", CODE_B, "第一行\n第二行")
        assert ok.status_code == 200
        assert calls[-1][2] == "第一行 第二行"
        # 响应里是**存下来的**那个版本，客户端据此显示 —— 不是它自己发的原文。
        assert ok.json()["message"]["body"] == "第一行 第二行"

        before = len(calls)
        zalgo = _post_message(client, "token-a", CODE_B, "a" + chr(0x0301) * 3)
        assert zalgo.status_code == 400
        assert zalgo.headers["X-Glory-Reason"] == "zalgo"
        assert len(calls) == before, "文本没过校验就不该进数据库层"


def test_rejection_maps_to_status_and_reason(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    async def _refuse(*_args):
        raise chat.ChatRejected("not_friends", "你们不是好友，发不了消息")

    monkeypatch.setattr(chat, "send", _refuse)
    with TestClient(app) as client:
        r = _post_message(client, "token-a", CODE_B)
    assert r.status_code == 403
    assert r.headers["X-Glory-Reason"] == "not_friends"
    assert r.json()["detail"] == "你们不是好友，发不了消息"


def test_every_rejection_code_has_a_status() -> None:
    """chat.py 里 raise 的每一个 code 都必须在 _STATUS_BY_CODE 里登记。

    漏登记的会静默落到 400 —— 同 test_friends 里同名的那一条。
    """
    codes = set(re.findall(r'ChatRejected\(\s*"(\w+)"', CHAT_PY))
    assert codes, "一个 code 都没搜到 —— 正则可能已经失效"
    missing = codes - set(chat_routes._STATUS_BY_CODE)
    assert not missing, "这些 code 没登记 HTTP 状态：%s" % sorted(missing)


def test_chat_text_collapses_line_breaks() -> None:
    assert text_guard.clean_chat_message("第一行\r\n第二行\t尾") == "第一行 第二行 尾"


def test_chat_text_keeps_contact_info_that_signatures_reject() -> None:
    """已定：私聊**不拦**引流（点对点、对方已经同意加好友）。签名则拦。"""
    text = "加我微信 abc123456789"
    assert text_guard.clean_chat_message(text) == text
    with pytest.raises(text_guard.TextRejected):
        text_guard.clean_signature(text)


def test_chat_text_ignores_the_name_blocklist(monkeypatch: pytest.MonkeyPatch) -> None:
    """昵称词表不套在聊天上 —— 同一份表在聊天里会同时漏和误杀（设计文档第四节）。"""
    monkeypatch.setattr(text_guard, "_load_blocklist", lambda: frozenset({"坏词"}))
    with pytest.raises(text_guard.TextRejected):
        text_guard.clean_player_name("坏词")
    assert text_guard.clean_chat_message("坏词") == "坏词"


def test_chat_text_strips_zwj_but_rejects_other_invisibles() -> None:
    """组合 emoji 里的 ZWJ 去掉（退化成几个单独的 emoji），其余不可见字符照旧拒。"""
    family = chr(0x1F468) + chr(0x200D) + chr(0x1F469) + chr(0x200D) + chr(0x1F467)
    assert text_guard.clean_chat_message(family) == chr(0x1F468) + chr(0x1F469) + chr(0x1F467)
    with pytest.raises(text_guard.TextRejected) as exc:
        text_guard.clean_chat_message("a" + chr(0x200B) + "b")
    assert exc.value.code == "invisible_char"
    with pytest.raises(text_guard.TextRejected) as exc:
        text_guard.clean_chat_message("abc" + chr(0x202E) + "def")
    assert exc.value.code == "bidi_override"


def test_chat_text_length_boundary() -> None:
    assert len(text_guard.clean_chat_message("字" * text_guard.CHAT_MAX)) == text_guard.CHAT_MAX
    with pytest.raises(text_guard.TextRejected) as exc:
        text_guard.clean_chat_message("字" * (text_guard.CHAT_MAX + 1))
    assert exc.value.code == "length"


@pytest.mark.parametrize("raw", ["", "   ", "\n\t", None])
def test_chat_text_rejects_empty(raw) -> None:
    with pytest.raises(text_guard.TextRejected) as exc:
        text_guard.clean_chat_message(raw)
    assert exc.value.code == "empty"


# --- 其余三个接口 -------------------------------------------------------------


def test_history_marks_from_me_and_passes_the_cursor(
    wired, monkeypatch: pytest.MonkeyPatch
) -> None:
    seen: list[tuple] = []

    async def _history(viewer_id, other_code, after_id):
        seen.append((viewer_id, other_code, after_id))
        return [
            chat.Message(7, PLAYER_A, "我说的", _WHEN),
            chat.Message(8, PLAYER_B, "他说的", _WHEN),
        ]

    monkeypatch.setattr(chat, "history", _history)
    with TestClient(app) as client:
        r = client.get("/v1/me/chats/%s/messages?after=6" % CODE_B, headers=_auth("token-a"))
    assert r.status_code == 200
    assert [m["from_me"] for m in r.json()["messages"]] == [True, False]
    assert seen == [(PLAYER_A, CODE_B, 6)]


def test_chat_list_shape(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    async def _list(_player_id):
        return [
            chat.ChatSummary(CODE_B, "阿乙", "a1", "f1", True,
                             chat.Message(9, PLAYER_B, "在吗", _WHEN), True),
            chat.ChatSummary("CCCC4444", "阿丙", "a2", "f2", False, None, False),
        ]

    monkeypatch.setattr(chat, "list_chats", _list)
    with TestClient(app) as client:
        r = client.get("/v1/me/chats", headers=_auth("token-a"))
    assert r.status_code == 200
    first, second = r.json()["chats"]
    assert first["unread"] is True
    assert first["last_message"]["from_me"] is False
    # 没聊过的好友也在列表里，last_message 是 null —— 聊天界面兼做选人。
    assert second["last_message"] is None


def test_mark_read(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    seen: list[tuple] = []

    async def _mark(player_id, other_code, last_read_id):
        seen.append((player_id, other_code, last_read_id))

    monkeypatch.setattr(chat, "mark_read", _mark)
    with TestClient(app) as client:
        ok = client.post("/v1/me/chats/%s/read" % CODE_B, json={"last_read_id": 5},
                         headers=_auth("token-a"))
        negative = client.post("/v1/me/chats/%s/read" % CODE_B, json={"last_read_id": -1},
                               headers=_auth("token-a"))
    assert ok.status_code == 204
    assert negative.status_code == 422
    assert seen == [(PLAYER_A, CODE_B, 5)]


def test_routes_are_registered() -> None:
    paths = app.openapi()["paths"]
    assert "get" in paths["/v1/me/chats"]
    assert {"get", "post"} <= set(paths["/v1/me/chats/{code}/messages"])
    assert "post" in paths["/v1/me/chats/{code}/read"]


# --- 未读与游标 ---------------------------------------------------------------


def test_is_unread() -> None:
    assert chat.is_unread(None, 0) is False, "没聊过的好友不是未读"
    assert chat.is_unread(5, 3) is True
    assert chat.is_unread(5, 5) is False


def test_read_cursor_is_monotonic_and_bounded() -> None:
    """🔴 两道闸缺一不可（见 chat._ADVANCE_READ 的注释）。

    少 greatest()：两台设备时滞后的那台把游标拉回去 —— 看过的消息又变成未读。
    少 least()：客户端报一个特别大的数，以后所有新消息都被当成已读 —— 红点再也不亮。
    两种都不报错。
    """
    sql = chat._ADVANCE_READ
    assert "greatest(chat_read_state.last_read_id, excluded.last_read_id)" in sql
    assert "least($4::bigint, coalesce(c.last_message_id, 0))" in sql


def test_sender_reads_their_own_message() -> None:
    """发送者的游标在同一个事务里推到自己那条 —— 否则自己刚发的会让自己亮红点。"""
    send_src = inspect.getsource(chat.send)
    assert "_ADVANCE_READ, sender_id" in send_src


# --- 容量与保留 ---------------------------------------------------------------


def test_keep_per_conversation_is_the_decided_value() -> None:
    """2026-09-11 拍板：每对好友存最近 200 条，也就是能显示的全部。"""
    assert chat.KEEP_PER_CONVERSATION == 200


def test_trim_keeps_exactly_keep_per_conversation() -> None:
    """offset 取第 KEEP 新的那条（下标 KEEP-1），比它老的全删 —— 正好留 KEEP 条。

    写成 offset KEEP 会多留一条；写成 `<=` 会少留一条。都不报错。
    """
    assert "order by message_id desc\n    offset $3 limit 1" in chat._TRIM
    assert "message_id < (" in chat._TRIM
    assert "_TRIM, low, high, KEEP_PER_CONVERSATION - 1" in inspect.getsource(chat.send)


def test_conversations_do_not_cascade_from_friendships() -> None:
    """会话**不能**外键到好友关系。

    外键 + 级联会让「删好友 = 删记录」在结构上成立 —— 正是「再留 30 天」要防的：
    骂完立刻删好友的人，记录不能跟着好友关系一起没了。
    """
    assert "references player_friendships" not in SQL_007_CODE


def test_purge_only_touches_ended_conversations() -> None:
    sql = chat._PURGE_ENDED
    assert "not exists" in sql and "status = 'accepted'" in sql
    assert chat.ENDED_RETENTION_DAYS == 30


# --- SQL 与 Python 的一致性 ---------------------------------------------------


def test_cursor_is_bigserial() -> None:
    """🔴 游标用时间戳会撞、会倒退，症状是「偶尔丢一条 / 重复一条」。一次做对。"""
    assert re.search(r"message_id\s+bigserial\s+primary key", SQL_007_CODE)


def test_no_unread_counter_column() -> None:
    """🔴 未读由游标推出来，不存计数器 —— 计数器会漂，而且不报错。"""
    assert "unread" not in SQL_007_CODE


def test_conversations_are_canonical_pairs() -> None:
    assert "check (low_id < high_id)" in SQL_007_CODE


def test_body_length_matches_text_guard() -> None:
    """数据库那层是最后一道，text_guard 是第一道；两边对不上是「客户端说可以、后端 500」。"""
    assert "char_length(body) between 1 and %d" % text_guard.CHAT_MAX in SQL_007_CODE


def test_client_msg_id_dedupe_is_unique_per_sender() -> None:
    assert "unique (sender_id, client_msg_id)" in SQL_007_CODE
    assert "on conflict (sender_id, client_msg_id) do nothing" in CHAT_PY


def test_every_new_table_has_rls_and_is_checked() -> None:
    """repo 的硬规则：每张表开 RLS 且默认零 policy；并登记进 /v1/debug/schema 的检查清单。"""
    for table in NEW_TABLES:
        assert "create table %s" % table in SQL_007_CODE
        assert "alter table %s enable row level security" % table in SQL_007_CODE
        assert table in db.EXPECTED_TABLES
    assert "create policy" not in SQL_007_CODE


# --- 定时清理 -----------------------------------------------------------------


class _FakeConn:
    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple]] = []

    async def execute(self, sql: str, *args):
        self.calls.append((sql, args))
        return "DELETE 2"


class _FakePool:
    def __init__(self, conn: _FakeConn) -> None:
        self._conn = conn

    def acquire(self):
        conn = self._conn

        @contextlib.asynccontextmanager
        async def _acquire():
            yield conn

        return _acquire()


def test_maintenance_purges_both_tables(monkeypatch: pytest.MonkeyPatch) -> None:
    """两张表都要清：过期会话（007）和 friend_request_log（005 写了必须清，一直没人清）。"""
    conn = _FakeConn()
    monkeypatch.setattr(db, "pool", lambda: _FakePool(conn))
    result = asyncio.run(maintenance.run_once())
    assert result == {"chat_conversations": 2, "friend_request_log": 2}
    statements = [sql for sql, _ in conn.calls]
    assert any("delete from chat_conversations" in s for s in statements)
    assert any("delete from friend_request_log" in s for s in statements)
    assert (chat.ENDED_RETENTION_DAYS,) in [args for _, args in conn.calls]


def test_maintenance_loop_survives_errors(monkeypatch: pytest.MonkeyPatch) -> None:
    """清理自己出错不能把循环带走 —— 否则那两张表重新变成只增不减，而且没有症状。"""
    calls: list[int] = []

    async def _flaky():
        calls.append(1)
        if len(calls) == 1:
            raise RuntimeError("第一轮故意失败")
        return {}

    monkeypatch.setattr(maintenance, "INTERVAL_SEC", 0)
    monkeypatch.setattr(maintenance, "run_once", _flaky)
    monkeypatch.setattr(db, "is_connected", lambda: True)

    async def _scenario() -> None:
        task = asyncio.create_task(maintenance.loop())
        while len(calls) < 2:
            await asyncio.sleep(0)
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task

    asyncio.run(_scenario())
    assert len(calls) >= 2, "第一轮失败之后循环没有继续"


def test_affected_rows_parses_command_tags() -> None:
    assert db.affected_rows("DELETE 12") == 12
    assert db.affected_rows("DELETE 0") == 0
    assert db.affected_rows("garbage") == 0
