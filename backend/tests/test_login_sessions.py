import asyncio
import uuid
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from starlette.websockets import WebSocketState

from app import db, login_sessions, realtime, players
from app.routes import auth, me
from app.supabase_auth import Session
from app.jwt_verify import Claims


class Pool:
    def __init__(self):
        self.rows = {}

    async def execute(self, sql, uid, sid):
        if sql.startswith("INSERT"):
            self.rows[uid] = sid
        elif self.rows.get(uid) == sid:
            del self.rows[uid]

    async def fetchval(self, sql, arg):
        if "EXISTS" in sql:
            return arg in self.rows.values()
        return self.rows.get(arg)


@pytest.fixture
def pool(monkeypatch):
    value = Pool()
    monkeypatch.setattr(db, "pool", lambda: value)
    monkeypatch.setattr(login_sessions, "ownership_lock", asyncio.Lock())
    return value


def test_replace_refresh_logout_and_restart(pool):
    async def run():
        uid = str(uuid.uuid4())
        old = await login_sessions.issue(uid)
        await login_sessions.require(uid, old)
        new = await login_sessions.issue(uid)
        with pytest.raises(HTTPException) as exc:
            await login_sessions.require(uid, old)
        assert exc.value.status_code == 409
        with pytest.raises(HTTPException):
            await login_sessions.require_refresh(uuid.UUID(old))
        # Delayed close/logout, even after rebuilding the WS hub, cannot clear B.
        realtime.reset_hub()
        await login_sessions.release(uid, old)
        await login_sessions.require(uid, new)
        await login_sessions.require_refresh(uuid.UUID(new))
        await login_sessions.release(uid, new)
        with pytest.raises(HTTPException):
            await login_sessions.require(uid, new)
    asyncio.run(run())


@pytest.mark.parametrize("sid", [None, "", "invalid", str(uuid.uuid4())])
def test_missing_invalid_and_foreign_generation_rejected(pool, sid):
    async def run():
        with pytest.raises(HTTPException):
            await login_sessions.require(str(uuid.uuid4()), sid)
    asyncio.run(run())


class Socket:
    client_state = WebSocketState.CONNECTED

    def __init__(self):
        self.messages = []
        self.closed = []

    async def send_json(self, payload):
        await asyncio.sleep(0)
        self.messages.append(payload)

    async def close(self, code):
        await asyncio.sleep(0)
        self.closed.append(code)


def test_concurrent_register_and_old_finally_cannot_erase_new():
    async def run():
        hub = realtime.Hub()
        pid = uuid.uuid4()
        a, b, c = [realtime.Connection(pid, d, Socket()) for d in ["a", "b", "c"]]
        await hub.register(a)
        await asyncio.gather(hub.register(b), hub.register(c))
        hub.unregister(a)
        hub.unregister(b)
        assert hub.connection_count() == 1
        assert hub._by_player[pid] == {"c": c}
        assert a.websocket.messages[0]["t"] == "kicked"
        assert b.websocket.closed == [realtime.CLOSE_KICKED]
        hub.unregister(c)
        assert hub.connection_count() == 0
    asyncio.run(run())


def test_http_stale_session_rejected_after_valid_jwt(pool, monkeypatch):
    uid = str(uuid.uuid4())
    class Verifier:
        async def verify(self, token):
            return Claims(uid, True, 9999999999)
    monkeypatch.setattr(me, "get_verifier", Verifier)
    monkeypatch.setattr(me, "get_settings", lambda: SimpleNamespace(supabase_url="configured"))
    async def run():
        a = await login_sessions.issue(uid)
        b = await login_sessions.issue(uid)
        with pytest.raises(HTTPException):
            await me.current_claims("Bearer valid", a)
        assert (await me.current_claims("Bearer valid", b)).auth_uid == uid
    asyncio.run(run())


def test_login_replaces_but_refresh_preserves_generation(pool, monkeypatch):
    uid = str(uuid.uuid4())
    pid = uuid.uuid4()
    async def lookup(*args):
        return SimpleNamespace(player_id=pid, player_name="test", created=False)
    monkeypatch.setattr(players, "resolve_or_create", lookup)
    hub = realtime.Hub()
    monkeypatch.setattr(realtime, "hub", lambda: hub)
    async def run():
        session = Session(uid, "access", "refresh", 3600)
        a = await auth._respond(session, None)
        conn = realtime.Connection(pid, "old-device", Socket())
        await hub.register(conn)
        renewed = await auth._respond(session, None, uuid.UUID(a.session_id))
        assert renewed.session_id == a.session_id and not conn.websocket.closed
        b = await auth._respond(session, None)
        assert b.session_id != a.session_id
        assert conn.websocket.messages[-1]["t"] == "kicked"
        with pytest.raises(HTTPException):
            await auth._respond(session, None, uuid.UUID(a.session_id))
        await login_sessions.require(uid, b.session_id)
    asyncio.run(run())


def test_websocket_rejects_replaced_session_before_registration(pool, monkeypatch):
    from fastapi.testclient import TestClient
    from app.main import app
    from app.routes import ws as ws_routes
    uid = str(uuid.uuid4())
    pid = uuid.uuid4()
    old = asyncio.run(login_sessions.issue(uid))
    asyncio.run(login_sessions.issue(uid))
    class Verifier:
        async def verify(self, token):
            return Claims(uid, True, 9999999999)
    async def lookup(auth_uid):
        return SimpleNamespace(player_id=pid)
    monkeypatch.setattr(ws_routes, "get_verifier", Verifier)
    monkeypatch.setattr(ws_routes, "get_settings", lambda: SimpleNamespace(supabase_url="configured"))
    monkeypatch.setattr(db, "is_connected", lambda: True)
    monkeypatch.setattr(players, "get_by_auth_uid", lookup)
    hub = realtime.Hub()
    monkeypatch.setattr(realtime, "hub", lambda: hub)
    client = TestClient(app)
    with client.websocket_connect("/v1/ws", headers={"Authorization": "Bearer valid",
            "X-Device-Session": "test-device-session", "X-Glory-Session": old}) as socket:
        assert socket.receive_json() == {"t": "kicked", "reason": "another_device"}
    assert hub.connection_count() == 0
