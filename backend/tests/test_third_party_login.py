"""Google / Apple 登录与绑定（docs/三方登录设计.md）。

真连 Supabase 跑通那一遍是 2026-10-22 的第 0 步（设计文档第七节第 1 条），
这里用 httpx.MockTransport 和替身覆盖不需要真实凭据的判据：
  1. 身份证明是凭证：错误信息里绝不能出现它
  2. 两种「已经属于别的号」都回 409 identity_taken，客户端才能弹同一个冲突窗
  3. 被封的人在动 Supabase **之前**就被挡住
  4. 管理员账号不能登录游戏
  5. 注销会删 Supabase 用户，删失败也不影响注销本身
"""

from __future__ import annotations

import asyncio
import json
import uuid
from types import SimpleNamespace

import httpx
import pytest
from fastapi import HTTPException

from app import admin_auth, db, players, supabase_admin
from app.jwt_verify import Claims
from app.routes import auth, profile as profile_routes
from app.supabase_auth import AuthError, LinkedIdentity, Session, SupabaseAuth

SECRET_LOOKING_ID_TOKEN = "eyJhbGciOiJSUzI1NiJ9.SUPER_SECRET_ID_TOKEN.sig"
SESSION_PAYLOAD = {"access_token": "at", "refresh_token": "rt", "expires_in": 3600,
                   "user": {"id": "auth-uid-1", "is_anonymous": False}}


def _auth_with(handler) -> SupabaseAuth:
    return SupabaseAuth("https://example.supabase.co", "pk_test", httpx.MockTransport(handler))


# --- Supabase 客户端层 ---------------------------------------------------------


def test_id_token_login_request_shape() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json=SESSION_PAYLOAD)

    session = asyncio.run(_auth_with(handler).sign_in_with_id_token("google", SECRET_LOOKING_ID_TOKEN))
    request = seen[0]
    body = json.loads(request.content)
    assert request.url.path == "/auth/v1/token" and request.url.params["grant_type"] == "id_token"
    assert body == {"provider": "google", "id_token": SECRET_LOOKING_ID_TOKEN}
    assert request.headers["Authorization"] == "Bearer pk_test"  # 登录不带任何用户令牌
    assert session.auth_uid == "auth-uid-1"


def test_link_uses_the_players_own_token() -> None:
    """绑定只能挂到令牌所属的那个用户上 —— 所以必须带玩家自己的令牌，不是 publishable key。"""
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json=SESSION_PAYLOAD)

    asyncio.run(_auth_with(handler).link_identity("player-access", "apple", SECRET_LOOKING_ID_TOKEN, "raw-nonce"))
    body = json.loads(seen[0].content)
    assert seen[0].headers["Authorization"] == "Bearer player-access"
    assert body["link_identity"] is True and body["nonce"] == "raw-nonce" and body["provider"] == "apple"


@pytest.mark.parametrize("status,code", [(422, "identity_already_exists"), (400, "email_exists")])
def test_conflict_code_is_kept_and_token_never_leaks(status: int, code: str) -> None:
    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(status, json={"code": status, "error_code": code, "msg": "taken"})

    with pytest.raises(AuthError) as exc:
        asyncio.run(_auth_with(handler).link_identity("player-access", "google", SECRET_LOOKING_ID_TOKEN))
    assert exc.value.code == code and exc.value.status == status
    assert SECRET_LOOKING_ID_TOKEN not in str(exc.value)


def test_unknown_provider_never_reaches_supabase() -> None:
    def handler(_request: httpx.Request) -> httpx.Response:
        raise AssertionError("不该发请求")

    with pytest.raises(AuthError):
        asyncio.run(_auth_with(handler).sign_in_with_id_token("steam", SECRET_LOOKING_ID_TOKEN))


def test_linked_identities_only_lists_google_and_apple() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.headers["Authorization"] == "Bearer player-access"
        return httpx.Response(200, json={"is_anonymous": False, "identities": [
            {"provider": "google", "identity_data": {"email": "abcdef@gmail.com"}},
            {"provider": "apple", "email": "x@privaterelay.appleid.com", "identity_data": {}},
            {"provider": "email", "identity_data": {"email": "admin@example.com"}},
        ]})

    anonymous, linked = asyncio.run(_auth_with(handler).linked_identities("player-access"))
    assert anonymous is False
    assert linked == [LinkedIdentity("google", "abcdef@gmail.com"),
                      LinkedIdentity("apple", "x@privaterelay.appleid.com")]


@pytest.mark.parametrize("email,masked", [
    ("abcdef@gmail.com", "ab***@gmail.com"),
    ("ab@gmail.com", "a***@gmail.com"),
    ("a@x.com", "a***@x.com"),
    ("", ""),
    ("not-an-email", ""),
])
def test_mask_email(email: str, masked: str) -> None:
    assert auth.mask_email(email) == masked


# --- 路由层 ------------------------------------------------------------------------

UID = str(uuid.uuid4())
CLAIMS = Claims(UID, True, 9999999999)
SID = str(uuid.uuid4())


class FakeClient:
    def __init__(self, *, error: AuthError | None = None, auth_uid: str = UID) -> None:
        self.error = error
        self.auth_uid = auth_uid
        self.calls: list[str] = []

    async def link_identity(self, token, provider, id_token, nonce=None) -> Session:
        self.calls.append("link")
        if self.error:
            raise self.error
        return Session(self.auth_uid, "new-access", "new-refresh", 3600)

    async def sign_in_with_id_token(self, provider, id_token, nonce=None) -> Session:
        self.calls.append("sign_in")
        if self.error:
            raise self.error
        return Session(self.auth_uid, "new-access", "new-refresh", 3600)

    async def linked_identities(self, token):
        return True, [LinkedIdentity("google", "abcdef@gmail.com")]


@pytest.fixture
def wired(monkeypatch):
    """数据库在、玩家在、限流清零。返回一个可以替换的 FakeClient 槽位。"""
    slot = {"client": FakeClient()}
    monkeypatch.setattr(db, "is_connected", lambda: True)
    monkeypatch.setattr(auth, "_auth_client", lambda: slot["client"])
    monkeypatch.setattr(auth, "_link_limiter", auth.SlidingWindowLimiter(100, 60.0))
    monkeypatch.setattr(auth, "_provider_limiter", auth.SlidingWindowLimiter(100, 3600.0))

    async def found(_auth_uid):
        return SimpleNamespace(player_id=uuid.uuid4())

    monkeypatch.setattr(players, "get_by_auth_uid", found)
    return slot


def _link(slot) -> object:
    body = auth.LinkRequest(provider="google", id_token=SECRET_LOOKING_ID_TOKEN)
    return asyncio.run(auth.link(body, CLAIMS, "Bearer player-access", SID))


@pytest.mark.parametrize("code", ["identity_already_exists", "email_exists"])
def test_link_conflict_is_409_identity_taken(wired, code: str) -> None:
    wired["client"] = FakeClient(error=AuthError("taken", 422, code))
    response = _link(wired)
    assert response.status_code == 409
    assert json.loads(response.body)["code"] == auth.IDENTITY_TAKEN


def test_link_bad_id_token_is_400(wired) -> None:
    wired["client"] = FakeClient(error=AuthError("bad", 400, "bad_jwt"))
    with pytest.raises(HTTPException) as exc:
        _link(wired)
    assert exc.value.status_code == 400


def test_link_checks_the_player_before_touching_supabase(wired, monkeypatch) -> None:
    """被封的人（get_by_auth_uid 抛 AccountBanned）不能先绑上再被拒。"""

    class Banned(Exception):
        pass

    async def banned(_auth_uid):
        raise Banned

    monkeypatch.setattr(players, "get_by_auth_uid", banned)
    with pytest.raises(Banned):
        _link(wired)
    assert wired["client"].calls == []


def test_link_keeps_the_login_session_and_returns_new_tokens(wired, monkeypatch) -> None:
    seen = {}

    async def respond(session, proposed, existing=None):
        seen.update(session=session, proposed=proposed, existing=existing)
        return SimpleNamespace(player_id=uuid.uuid4())

    monkeypatch.setattr(auth, "_respond", respond)
    _link(wired)
    assert seen["existing"] == uuid.UUID(SID)  # 不开新的登录会话，不踢别的设备
    assert seen["proposed"] is None
    assert seen["session"].refresh_token == "new-refresh"


def test_link_result_for_another_user_is_refused(wired) -> None:
    wired["client"] = FakeClient(auth_uid=str(uuid.uuid4()))
    with pytest.raises(HTTPException) as exc:
        _link(wired)
    assert exc.value.status_code == 502


def _provider_login(player_id=None):
    body = auth.ProviderLoginRequest(provider="google", id_token=SECRET_LOOKING_ID_TOKEN, player_id=player_id)
    request = SimpleNamespace(client=SimpleNamespace(host="203.0.113.9"), headers={})
    return asyncio.run(auth.provider_login(body, request))


def test_provider_login_refuses_admin_accounts(wired, monkeypatch) -> None:
    async def is_admin(_uid):
        return True

    async def respond(*_args, **_kwargs):
        raise AssertionError("管理员不能建玩家")

    monkeypatch.setattr(admin_auth, "is_admin_account", is_admin)
    monkeypatch.setattr(auth, "_respond", respond)
    with pytest.raises(HTTPException) as exc:
        _provider_login()
    assert exc.value.status_code == 403


def test_provider_login_passes_the_local_player_id(wired, monkeypatch) -> None:
    seen = {}

    async def not_admin(_uid):
        return False

    async def respond(session, proposed, existing=None):
        seen.update(proposed=proposed, existing=existing)
        return "ok"

    monkeypatch.setattr(admin_auth, "is_admin_account", not_admin)
    monkeypatch.setattr(auth, "_respond", respond)
    local = uuid.uuid4()
    assert _provider_login(local) == "ok"
    assert seen == {"proposed": local, "existing": None}  # 新的登录会话：别的设备会被踢


def test_identities_masks_email(wired) -> None:
    out = asyncio.run(auth.identities(CLAIMS, "Bearer player-access"))
    assert out.is_anonymous is True
    assert [(i.provider, i.email) for i in out.identities] == [("google", "ab***@gmail.com")]


# --- 注销删 Supabase 用户 ------------------------------------------------------------


def _settings(key: str) -> SimpleNamespace:
    return SimpleNamespace(supabase_url="https://example.supabase.co", supabase_secret_key=key)


@pytest.mark.parametrize("key,has_bearer", [("sb_secret_abc", False), ("eyJlegacy.jwt.sig", True)])
def test_delete_user_headers(monkeypatch, key: str, has_bearer: bool) -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={})

    monkeypatch.setattr(supabase_admin, "get_settings", lambda: _settings(key))
    asyncio.run(supabase_admin.delete_user(UID, httpx.MockTransport(handler)))
    assert seen[0].method == "DELETE" and seen[0].url.path == f"/auth/v1/admin/users/{UID}"
    assert seen[0].headers["apikey"] == key
    assert ("Authorization" in seen[0].headers) is has_bearer


def test_delete_user_already_gone_is_fine(monkeypatch) -> None:
    monkeypatch.setattr(supabase_admin, "get_settings", lambda: _settings("sb_secret_abc"))
    transport = httpx.MockTransport(lambda _r: httpx.Response(404, json={"msg": "User not found"}))
    asyncio.run(supabase_admin.delete_user(UID, transport))


def test_delete_user_failure_never_echoes_the_key(monkeypatch) -> None:
    monkeypatch.setattr(supabase_admin, "get_settings", lambda: _settings("sb_secret_abc"))
    transport = httpx.MockTransport(lambda _r: httpx.Response(500, text="sb_secret_abc boom"))
    with pytest.raises(supabase_admin.AdminUnavailable) as exc:
        asyncio.run(supabase_admin.delete_user(UID, transport))
    assert "sb_secret_abc" not in str(exc.value)


def test_delete_user_without_key_is_unavailable(monkeypatch) -> None:
    monkeypatch.setattr(supabase_admin, "get_settings", lambda: _settings(""))
    with pytest.raises(supabase_admin.AdminUnavailable):
        asyncio.run(supabase_admin.delete_user(UID))


@pytest.mark.parametrize("fails", [False, True])
def test_delete_me_removes_the_supabase_user(monkeypatch, fails: bool) -> None:
    """Supabase 用户删不掉时注销照样算成功：游戏资料已经删了，回滚不了，交给管理员补删。"""
    deleted: list[str] = []
    row = SimpleNamespace(player_id=uuid.uuid4(), friend_code="ABCD2345")

    async def current(_claims):
        return row

    async def erase(_player_id):
        return True

    async def delete_user(auth_uid):
        deleted.append(auth_uid)
        if fails:
            raise supabase_admin.AdminUnavailable("boom")

    monkeypatch.setattr(profile_routes, "_current_profile", current)
    monkeypatch.setattr(profile_routes.profile, "delete_player", erase)
    monkeypatch.setattr(supabase_admin, "delete_user", delete_user)
    out = asyncio.run(profile_routes.delete_me(profile_routes.DeleteRequest(friend_code="abcd2345"), CLAIMS))
    assert out == {"deleted": True}
    assert deleted == [UID]


# --- 换手机登回老号不再重过教学（10-22：等级 ≥ 2 或者已经有宠物）---------------------------


class _LevelPool:
    def __init__(self, level=None, error: Exception | None = None) -> None:
        self.level = level
        self.error = error

    def acquire(self):
        pool = self

        class _Conn:
            async def fetchval(self, _sql, _pid):
                if pool.error:
                    raise pool.error
                return pool.level

        class _Ctx:
            async def __aenter__(self):
                return _Conn()

            async def __aexit__(self, *exc):
                return False

        return _Ctx()


def _onboarded(monkeypatch, *, level=None, level_error=None, pets=(), pets_error=None) -> bool:
    from app import shop

    async def read_pets(_pid):
        if pets_error:
            raise pets_error
        return SimpleNamespace(owned=list(pets))

    monkeypatch.setattr(db, "pool", lambda: _LevelPool(level, level_error))
    monkeypatch.setattr(shop, "read_pets", read_pets)
    return asyncio.run(auth._onboarded(uuid.uuid4()))


def test_onboarded_by_level(monkeypatch) -> None:
    assert _onboarded(monkeypatch, level=2) is True
    assert _onboarded(monkeypatch, level=7) is True


def test_onboarded_by_pets(monkeypatch) -> None:
    """跳过了教学、但选过初始宠物的人也算玩过（他就是从三选一那一步进主菜单的）。"""
    assert _onboarded(monkeypatch, level=1, pets=["pet_cat"]) is True
    assert _onboarded(monkeypatch, level=None, pets=["pet_cat"]) is True


def test_brand_new_account_is_not_onboarded(monkeypatch) -> None:
    assert _onboarded(monkeypatch, level=1) is False
    assert _onboarded(monkeypatch, level=None) is False


def test_onboarded_never_breaks_login(monkeypatch) -> None:
    """等级表还没建（迁移没跑）、宠物表读不出来：按没玩过处理，最坏多看一遍教学，登录照常。"""
    import asyncpg

    missing = asyncpg.exceptions.UndefinedTableError("relation does not exist")
    assert _onboarded(monkeypatch, level_error=missing, pets=["pet_cat"]) is True
    assert _onboarded(monkeypatch, level_error=missing) is False
    assert _onboarded(monkeypatch, level=1, pets_error=FileNotFoundError("pets.json")) is False
    # 连接池本身出状况（db.NotConfigured 不是 PostgresError）也一样不能挡住登录。
    assert _onboarded(monkeypatch, level_error=db.NotConfigured("no pool"), pets=["pet_cat"]) is True


@pytest.mark.parametrize("created,existing,expected", [
    (False, None, True),        # 登回老号：要告诉客户端
    (True, None, False),        # 刚建的号：不用查
    (False, uuid.uuid4(), False),  # 续期：客户端不看它，也不多查两次库
])
def test_respond_reports_onboarded_only_on_new_logins(monkeypatch, created, existing, expected) -> None:
    from app import login_sessions, realtime

    pid = uuid.uuid4()
    asked: list[uuid.UUID] = []

    async def resolve(*_args):
        return SimpleNamespace(player_id=pid, player_name="p", created=created)

    async def onboarded(player_id):
        asked.append(player_id)
        return True

    async def issue(_uid):
        return str(uuid.uuid4())

    async def require(_uid, _sid):
        return None

    class _Hub:
        async def disconnect_player(self, *_args):
            return None

    monkeypatch.setattr(players, "resolve_or_create", resolve)
    monkeypatch.setattr(auth, "_onboarded", onboarded)
    monkeypatch.setattr(login_sessions, "issue", issue)
    monkeypatch.setattr(login_sessions, "require", require)
    monkeypatch.setattr(login_sessions, "ownership_lock", asyncio.Lock())
    monkeypatch.setattr(realtime, "hub", lambda: _Hub())
    out = asyncio.run(auth._respond(Session(UID, "a", "r", 3600), None, existing))
    assert out.onboarded is expected
    assert asked == ([pid] if expected else [])
