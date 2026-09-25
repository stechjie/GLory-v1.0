"""封号（database/016_bans.sql，app/bans.py）的行为用例。不连数据库。

真库上的部分（SQL 函数、查询、续期凭证寄存的表）在 test_pg_integration.py。

最要紧的几条，它们的失败模式都**不会报错**：

  1. 被封一律 403、绝不是 401 —— 旧版客户端收到 401 会自动注册新号，封号等于白封。
  2. 续期时 Supabase 已经换掉了旧凭证：被封那一刻要把新凭证存下来；
     下次拿旧凭证来、还封着 → 直接 403，**不能再去碰 Supabase**（会被当成重放、整条会话作废）。
  3. 解封之后拿旧凭证来 → 用存着的那张去续，回到原来的号。
  4. 实时连接被封：先说原因、再用专门的关闭码关，客户端才不会一直重连。
"""

from __future__ import annotations

import asyncio
import datetime as dt
import pathlib
import re
import uuid
from dataclasses import dataclass

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app import admission, bans, db, matchmaking, players, realtime
from app.config import get_settings
from app.jwt_verify import Claims, TokenError
from app.main import app
from app.routes import auth as auth_routes
from app.routes import ws as ws_routes
from app.supabase_auth import AuthError, Session

REPO = pathlib.Path(__file__).resolve().parents[2]
PLAYER = uuid.UUID("11111111-1111-1111-1111-111111111111")
UNTIL = dt.datetime(2026, 10, 1, 12, 0, tzinfo=dt.UTC)
TIMED = bans.Ban(PLAYER, 7, "使用外挂", UNTIL)
FOREVER = bans.Ban(PLAYER, 8, "盗号", None)


# --- 文案与载荷 -------------------------------------------------------------------


def test_message_uses_malaysia_time_and_says_permanent() -> None:
    assert TIMED.message() == "账号已被封禁，封禁到 2026-10-01 20:00（马来西亚时间）。原因：使用外挂"
    assert FOREVER.message() == "账号已被封禁，永久封禁。原因：盗号"


def test_client_payload_has_reason_and_utc_end_but_nothing_internal() -> None:
    assert TIMED.to_client() == {"reason": "使用外挂", "ends_at": "2026-10-01T12:00:00+00:00"}
    assert FOREVER.to_client() == {"reason": "盗号", "ends_at": None}
    # now() + interval 带微秒；客户端的解析不认小数秒，下发前要去掉。
    precise = bans.Ban(PLAYER, 9, "x", UNTIL.replace(microsecond=123456) + dt.timedelta(hours=8))
    assert precise.to_client()["ends_at"] == "2026-10-01T20:00:00+00:00"


# --- 接口：403 不是 401 🔴 -----------------------------------------------------------


@pytest.fixture
def api(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("GLORY_SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("GLORY_SUPABASE_PUBLISHABLE_KEY", "pk_test")
    monkeypatch.setenv("GLORY_DATABASE_URL", "")
    get_settings.cache_clear()
    monkeypatch.setattr(db, "is_connected", lambda: True)
    yield TestClient(app)
    get_settings.cache_clear()


def test_any_endpoint_answers_a_banned_player_with_403_and_the_reason(api, monkeypatch) -> None:
    from app.routes import me as me_routes

    class _Verifier:
        async def verify(self, _token: str) -> Claims:
            return Claims(auth_uid="auth-1", is_anonymous=True, expires_at=0)

    async def _banned(_auth_uid: str):
        raise bans.AccountBanned(TIMED)

    monkeypatch.setattr(me_routes, "get_verifier", _Verifier)
    monkeypatch.setattr(players, "get_by_auth_uid", _banned)
    r = api.get("/v1/me/wallet", headers={"Authorization": "Bearer x"})
    assert r.status_code == 403
    body = r.json()
    assert body["code"] == bans.ERROR_CODE == "account_banned"
    assert body["ban"] == TIMED.to_client()
    # 旧版客户端只显示 detail：必须是一句完整的话。
    assert body["detail"] == TIMED.message()


class _FakeAuth:
    """记下拿什么凭证去续了。"""

    def __init__(self, fail: bool = False) -> None:
        self.refreshed: list[str] = []
        self.fail = fail
        self.configured = True

    async def refresh(self, token: str) -> Session:
        self.refreshed.append(token)
        if self.fail:
            raise AuthError("Invalid Refresh Token: Already Used", status=400)
        return Session(auth_uid="auth-1", access_token="at", refresh_token="rotated-" + token,
                       expires_in=3600)


@dataclass
class _Handoffs:
    rows: dict[str, tuple[uuid.UUID, str]]
    held: list[tuple[str, uuid.UUID, str]]


@pytest.fixture
def refresh_wired(api, monkeypatch):
    auth = _FakeAuth()
    store = _Handoffs({}, [])
    banned: set[uuid.UUID] = set()

    async def find(token: str):
        row = store.rows.get(token)
        return None if row is None else bans.Handoff(*row)

    async def hold(token: str, player_id: uuid.UUID, next_token: str) -> None:
        store.held.append((token, player_id, next_token))
        store.rows[token] = (player_id, next_token)

    async def ensure(player_id: uuid.UUID) -> None:
        if player_id in banned:
            raise bans.AccountBanned(TIMED)

    async def resolve(_auth_uid: str, _proposed=None):
        if PLAYER in banned:
            raise bans.AccountBanned(TIMED)
        return players.Player(PLAYER, "p", created=False, friend_code="ABCD2345")

    monkeypatch.setattr(auth_routes, "_auth_client", lambda: auth)
    monkeypatch.setattr(bans, "find_handoff", find)
    monkeypatch.setattr(bans, "hold_handoff", hold)
    monkeypatch.setattr(bans, "ensure_not_banned", ensure)
    monkeypatch.setattr(players, "resolve_or_create", resolve)
    return api, auth, store, banned


def test_refresh_of_a_banned_player_keeps_the_rotated_token(refresh_wired) -> None:
    """★ Supabase 已经把 T0 换成了 T1。回 403 的同时必须把 T1 存下来，不然 T0 再来就是重放。"""
    api, auth, store, banned = refresh_wired
    banned.add(PLAYER)
    r = api.post("/v1/auth/refresh", json={"refresh_token": "T0"})
    assert r.status_code == 403
    assert r.json()["code"] == "account_banned"
    assert auth.refreshed == ["T0"]
    assert store.held == [("T0", PLAYER, "rotated-T0")]


def test_old_token_while_still_banned_never_reaches_supabase(refresh_wired) -> None:
    """★ 还封着：直接 403。拿 T0（或存着的 T1）再去 Supabase 续都会出事。"""
    api, auth, store, banned = refresh_wired
    banned.add(PLAYER)
    store.rows["T0"] = (PLAYER, "T1")
    for _ in range(3):
        r = api.post("/v1/auth/refresh", json={"refresh_token": "T0"})
        assert r.status_code == 403
    assert auth.refreshed == []


def test_old_token_after_unban_resumes_the_same_account(refresh_wired) -> None:
    """★ 解封后：用存着的 T1 去续，玩家拿到新凭证，还是原来那个号。行改存最新的一张。"""
    api, auth, store, _banned = refresh_wired
    store.rows["T0"] = (PLAYER, "T1")
    r = api.post("/v1/auth/refresh", json={"refresh_token": "T0"})
    assert r.status_code == 200
    assert r.json()["player_id"] == str(PLAYER)
    assert r.json()["refresh_token"] == "rotated-T1"
    assert auth.refreshed == ["T1"]
    assert store.rows["T0"] == (PLAYER, "rotated-T1")


def test_normal_refresh_touches_no_handoff(refresh_wired) -> None:
    api, auth, store, _banned = refresh_wired
    r = api.post("/v1/auth/refresh", json={"refresh_token": "T0"})
    assert r.status_code == 200
    assert auth.refreshed == ["T0"]
    assert store.held == []


def test_dead_refresh_token_is_still_401(refresh_wired) -> None:
    """没被封、凭证真的失效了：照旧 401（客户端走重新登录那条路）。"""
    api, auth, _store, _banned = refresh_wired
    auth.fail = True
    assert api.post("/v1/auth/refresh", json={"refresh_token": "T0"}).status_code == 401


# --- 实时连接 ---------------------------------------------------------------------


@pytest.fixture
def ws_wired(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("GLORY_DISABLE_INSTANCE_LOCK", "true")
    monkeypatch.setenv("GLORY_SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("GLORY_DATABASE_URL", "")
    get_settings.cache_clear()
    monkeypatch.setattr(db, "is_connected", lambda: True)

    class _Verifier:
        async def verify(self, token: str) -> Claims:
            if token != "good":
                raise TokenError("bad")
            return Claims(auth_uid="auth-1", is_anonymous=True, expires_at=0)

    async def _banned(_auth_uid: str):
        raise bans.AccountBanned(FOREVER)

    monkeypatch.setattr(ws_routes, "get_verifier", _Verifier)
    monkeypatch.setattr(players, "get_by_auth_uid", _banned)
    realtime.reset_hub()
    admission.reset()
    yield TestClient(app)
    realtime.reset_hub()
    admission.reset()
    get_settings.cache_clear()


def test_banned_handshake_is_told_why_then_closed_with_its_own_code(ws_wired) -> None:
    headers = {"Authorization": "Bearer good", "X-Device-Session": "device-aaaaaaaa"}
    with ws_wired, ws_wired.websocket_connect("/v1/ws", headers=headers) as ws:
        assert ws.receive_json() == {"t": "banned", "ban": FOREVER.to_client()}
        with pytest.raises(WebSocketDisconnect) as exc:
            ws.receive_json()
        assert exc.value.code == bans.CLOSE_BANNED
    assert realtime.hub().connection_count() == 0
    assert admission.current().stats()["online"] == 0


# --- 在线的人被封：踢 ----------------------------------------------------------------


class _Socket:
    def __init__(self) -> None:
        self.sent: list[dict] = []
        self.closed_with: int | None = None
        from starlette.websockets import WebSocketState
        self.client_state = WebSocketState.CONNECTED

    async def send_json(self, payload: dict) -> None:
        self.sent.append(payload)

    async def close(self, code: int) -> None:
        from starlette.websockets import WebSocketState
        self.closed_with = code
        self.client_state = WebSocketState.DISCONNECTED


def test_kick_tells_why_closes_every_device_and_frees_queue_and_slot(monkeypatch) -> None:
    realtime.reset_hub()
    admission.reset()
    other = uuid.uuid4()
    sockets = []
    for pid, device in [(PLAYER, "device-aaaaaaaa"), (PLAYER, "device-bbbbbbbb"), (other, "device-cccccccc")]:
        sock = _Socket()
        sockets.append(sock)
        realtime.hub()._by_player.setdefault(pid, {})[device] = realtime.Connection(pid, device, sock)
    gate = admission.current()
    gate._seats[PLAYER] = admission._Seat(None)
    mm = matchmaking.Matchmaker(lambda *_a: asyncio.sleep(0, 0))
    monkeypatch.setattr(matchmaking, "current", lambda: mm)
    mm.join(PLAYER, matchmaking.CASUAL)

    asyncio.run(bans.kick(PLAYER, TIMED))

    for sock in sockets[:2]:
        assert sock.sent == [{"t": "banned", "ban": TIMED.to_client()}]
        assert sock.closed_with == bans.CLOSE_BANNED
    assert sockets[2].sent == [] and sockets[2].closed_with is None
    assert PLAYER not in gate._seats
    assert mm.position_of(PLAYER, matchmaking.CASUAL) == 0
    realtime.reset_hub()
    admission.reset()


def test_sweep_only_kicks_online_players_who_are_banned(monkeypatch) -> None:
    realtime.reset_hub()
    other = uuid.uuid4()
    for pid in (PLAYER, other):
        realtime.hub()._by_player[pid] = {"device-aaaaaaaa": realtime.Connection(pid, "device-aaaaaaaa", _Socket())}
    asked: list[list[uuid.UUID]] = []
    kicked: list[uuid.UUID] = []

    class _Pool:
        def acquire(self):
            class _A:
                async def __aenter__(self):
                    return None

                async def __aexit__(self, *exc):
                    return False
            return _A()

    async def among(_conn, ids):
        asked.append(sorted(ids))
        return {PLAYER: TIMED}

    async def kick(pid, _ban):
        kicked.append(pid)

    monkeypatch.setattr(db, "is_connected", lambda: True)
    monkeypatch.setattr(db, "pool", lambda: _Pool())
    monkeypatch.setattr(bans, "live_bans_among", among)
    monkeypatch.setattr(bans, "kick", kick)
    assert asyncio.run(bans.sweep()) == 1
    assert asked == [sorted([PLAYER, other])]
    assert kicked == [PLAYER]
    realtime.reset_hub()


# --- 接线与跨语言约定 -------------------------------------------------------------------


def test_every_identity_lookup_goes_through_the_ban_check() -> None:
    """★ 拦截放在 players 的两个解析函数里 —— 新加的接口不用记得查，默认就拦。"""
    source = (REPO / "backend" / "app" / "players.py").read_text(encoding="utf-8")
    assert source.count("bans.raise_if_banned(") == 2
    for route in (REPO / "backend" / "app" / "routes").glob("*.py"):
        text = route.read_text(encoding="utf-8")
        # 路由不许绕开 players 自己去查 player_identities。
        assert "from player_identities" not in text, route.name


def test_ban_loop_is_started_by_the_app() -> None:
    source = (REPO / "backend" / "app" / "main.py").read_text(encoding="utf-8")
    assert "bans.loop()" in source
    assert "exception_handler(bans.AccountBanned)" in source


def test_client_constants_match() -> None:
    realtime_gd = (REPO / "scripts" / "autoload" / "RealtimeService.gd").read_text(encoding="utf-8")
    account_gd = (REPO / "scripts" / "autoload" / "AccountManager.gd").read_text(encoding="utf-8")
    assert re.search(r"const CLOSE_BANNED := %d\b" % bans.CLOSE_BANNED, realtime_gd)
    assert 'const BANNED_PUSH_TYPE := "%s"' % bans.PUSH_TYPE in realtime_gd
    assert 'const BANNED_CODE := "%s"' % bans.ERROR_CODE in account_gd


def test_sql_functions_require_an_actor_and_never_delete() -> None:
    sql = (REPO / "database" / "016_bans.sql").read_text(encoding="utf-8")
    code = "\n".join(line.split("--", 1)[0] for line in sql.splitlines()).lower()
    assert "delete from player_bans" not in code
    assert code.count("必须填操作人") == 2
    assert "enable row level security" in code
    assert "create policy" not in code
