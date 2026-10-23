"""Steam 登录与电脑关联手机号（docs/三方登录设计.md 第八节）。

真连 Steam 要等游戏接上 GodotSteam（第 2 步）；真连 Supabase 的那一遍是 deploy/check_steam_oidc.py。
这里用 httpx.MockTransport 和替身钉住：
  1. 发行商密钥绝不出现在任何报错里
  2. 票不对 400、服务器没配好 / Steam 拒了密钥 503 —— 两种要分开，前者是玩家的事，后者是我们的事
  3. Steam 登录交给 Supabase 的是 custom:steam + 带 steam.invalid 假邮箱的证明，客户端碰不到证明
  4. 关联码：一个 Steam 只有一个有效码、过期作废、只能用一次、冲突不合并、失败可以重试
"""

from __future__ import annotations

import asyncio
import json
import uuid
from types import SimpleNamespace

import httpx
import pytest
from fastapi import HTTPException

from app import admin_auth, db, players, steam, steam_link, steam_oidc
from app.jwt_verify import Claims
from app.routes import auth
from app.supabase_auth import STEAM_PROVIDER, AuthError, LinkedIdentity, Session

KEY = "SECRETPUBLISHERKEY0123456789ABCD"
TICKET = "14000000" + "ab" * 100
STEAM_ID = "76561198000000042"


def _settings(key: str = KEY) -> SimpleNamespace:
    return SimpleNamespace(steam_web_api_key=key, steam_app_id=4919850, steam_ticket_identity="glory-account")


@pytest.fixture(autouse=True)
def _steam_settings(monkeypatch):
    monkeypatch.setattr(steam, "get_settings", lambda: _settings())
    steam_link.reset()
    yield
    steam_link.reset()


# --- 验票 ----------------------------------------------------------------------------


def test_ticket_ok_and_request_shape() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"response": {"params": {
            "result": "OK", "steamid": STEAM_ID, "ownersteamid": "76561198000000001",
            "vacbanned": False, "publisherbanned": False}}})

    user = asyncio.run(steam.authenticate_ticket(TICKET, httpx.MockTransport(handler)))
    assert user.steam_id == STEAM_ID and user.owner_steam_id == "76561198000000001"
    q = seen[0].url.params
    assert seen[0].url.host == "partner.steam-api.com"
    assert (q["appid"], q["identity"], q["ticket"]) == ("4919850", "glory-account", TICKET)


def test_bad_ticket_never_leaks_the_key() -> None:
    def handler(_r):
        return httpx.Response(200, json={"response": {"error": {"errorcode": 101, "errordesc": "Invalid ticket"}}})

    with pytest.raises(steam.SteamRejected) as exc:
        asyncio.run(steam.authenticate_ticket(TICKET, httpx.MockTransport(handler)))
    assert KEY not in str(exc.value) and "101" in str(exc.value)


@pytest.mark.parametrize("status", [401, 403])
def test_rejected_key_is_our_problem_not_the_players(status) -> None:
    transport = httpx.MockTransport(lambda _r: httpx.Response(status, text="Forbidden"))
    with pytest.raises(steam.SteamUnavailable) as exc:
        asyncio.run(steam.authenticate_ticket(TICKET, transport))
    assert KEY not in str(exc.value)


def test_network_error_never_leaks_the_url() -> None:
    def handler(request):
        raise httpx.ConnectError("boom " + str(request.url))

    with pytest.raises(steam.SteamUnavailable) as exc:
        asyncio.run(steam.authenticate_ticket(TICKET, httpx.MockTransport(handler)))
    assert KEY not in str(exc.value)


def test_malformed_ticket_never_reaches_steam() -> None:
    def handler(_r):
        raise AssertionError("不该发请求")

    for bad in ["", "zz" * 20, "ab"]:
        with pytest.raises(steam.SteamRejected):
            asyncio.run(steam.authenticate_ticket(bad, httpx.MockTransport(handler)))


def test_missing_key_is_unavailable(monkeypatch) -> None:
    monkeypatch.setattr(steam, "get_settings", lambda: _settings(""))
    with pytest.raises(steam.SteamUnavailable):
        asyncio.run(steam.authenticate_ticket(TICKET))


def test_persona_name_is_best_effort() -> None:
    ok = httpx.MockTransport(lambda _r: httpx.Response(200, json={"response": {"players": [{"personaname": "Gabe"}]}}))
    assert asyncio.run(steam.persona_name(STEAM_ID, ok)) == "Gabe"
    broken = httpx.MockTransport(lambda _r: httpx.Response(500, text="nope"))
    assert asyncio.run(steam.persona_name(STEAM_ID, broken)) == ""


def test_placeholder_email_is_undeliverable() -> None:
    assert steam.placeholder_email(STEAM_ID) == f"steam-{STEAM_ID}@steam.invalid"


# --- 路由：Steam 登录 ------------------------------------------------------------------

UID = str(uuid.uuid4())
CLAIMS = Claims(UID, True, 9999999999)
SID = str(uuid.uuid4())


class FakeClient:
    def __init__(self, *, error: AuthError | None = None, auth_uid: str = UID) -> None:
        self.error = error
        self.auth_uid = auth_uid
        self.calls: list[tuple[str, str, str]] = []

    async def sign_in_with_id_token(self, provider, id_token, nonce=None) -> Session:
        self.calls.append(("sign_in", provider, id_token))
        if self.error:
            raise self.error
        return Session(self.auth_uid, "a", "r", 3600)

    async def link_identity(self, token, provider, id_token, nonce=None) -> Session:
        self.calls.append(("link", provider, id_token))
        if self.error:
            raise self.error
        return Session(self.auth_uid, "a2", "r2", 3600)


@pytest.fixture
def wired(monkeypatch):
    slot = {"client": FakeClient(), "respond": []}

    async def verified(ticket):
        assert ticket == TICKET
        return steam.SteamUser(STEAM_ID, STEAM_ID)

    async def name(_sid):
        return "Gabe"

    async def respond(session, proposed, existing=None):
        slot["respond"].append((session, proposed, existing))
        return SimpleNamespace(player_id=uuid.uuid4(), created=False)

    async def found(_uid):
        return SimpleNamespace(player_id=uuid.uuid4())

    async def not_admin(_uid):
        return False

    monkeypatch.setattr(db, "is_connected", lambda: True)
    monkeypatch.setattr(auth, "_auth_client", lambda: slot["client"])
    monkeypatch.setattr(auth, "_respond", respond)
    monkeypatch.setattr(steam, "authenticate_ticket", verified)
    monkeypatch.setattr(steam, "persona_name", name)
    monkeypatch.setattr(steam_oidc, "mint", lambda sub, name="", email="": json.dumps(
        {"sub": sub, "name": name, "email": email}))
    monkeypatch.setattr(players, "get_by_auth_uid", found)
    monkeypatch.setattr(admin_auth, "is_admin_account", not_admin)
    for limiter in ("_provider_limiter", "_link_code_issue_limiter", "_link_code_try_limiter",
                    "_link_code_poll_limiter"):
        monkeypatch.setattr(auth, limiter, auth.SlidingWindowLimiter(1000, 60.0))
    return slot


def _request():
    return SimpleNamespace(client=SimpleNamespace(host="203.0.113.9"), headers={})


def test_steam_login_hands_supabase_our_own_proof(wired) -> None:
    pid = uuid.uuid4()
    asyncio.run(auth.steam_login(auth.SteamLoginRequest(ticket=TICKET, player_id=pid), _request()))
    kind, provider, token = wired["client"].calls[0]
    assert (kind, provider) == ("sign_in", STEAM_PROVIDER)
    assert json.loads(token) == {"sub": STEAM_ID, "name": "Gabe", "email": f"steam-{STEAM_ID}@steam.invalid"}
    assert wired["respond"][0][1:] == (pid, None)  # 新的登录会话：别的设备会被踢


def test_steam_login_refuses_admin_accounts(wired, monkeypatch) -> None:
    async def admin(_uid):
        return True

    monkeypatch.setattr(admin_auth, "is_admin_account", admin)
    with pytest.raises(HTTPException) as exc:
        asyncio.run(auth.steam_login(auth.SteamLoginRequest(ticket=TICKET), _request()))
    assert exc.value.status_code == 403 and wired["respond"] == []


@pytest.mark.parametrize("error,status", [(steam.SteamRejected("bad"), 400), (steam.SteamUnavailable("down"), 503)])
def test_steam_login_ticket_failures(wired, monkeypatch, error, status) -> None:
    async def fail(_t):
        raise error

    monkeypatch.setattr(steam, "authenticate_ticket", fail)
    with pytest.raises(HTTPException) as exc:
        asyncio.run(auth.steam_login(auth.SteamLoginRequest(ticket=TICKET), _request()))
    assert exc.value.status_code == status and wired["client"].calls == []


def test_steam_identity_is_shown_by_name_not_placeholder_email() -> None:
    out = auth._identity_out(LinkedIdentity(STEAM_PROVIDER, f"steam-{STEAM_ID}@steam.invalid", "Gabe"))
    assert (out.provider, out.email, out.name) == ("steam", "", "Gabe")
    google = auth._identity_out(LinkedIdentity("google", "abcdef@gmail.com"))
    assert (google.provider, google.email) == ("google", "ab***@gmail.com")


# --- 关联码的状态 ----------------------------------------------------------------------


def test_one_live_code_per_steam_and_expiry() -> None:
    first = steam_link.issue(STEAM_ID, "Gabe", now=1000.0)
    second = steam_link.issue(STEAM_ID, "Gabe", now=1001.0)
    assert len(first.code) == 6 and first.code.isdigit()
    assert steam_link.pending(first.code, now=1002.0) is None  # 旧码作废
    assert steam_link.pending(second.code, now=1002.0) is second
    assert steam_link.status(first.poll_token, now=1002.0) == steam_link.EXPIRED
    assert steam_link.pending(second.code, now=1001.0 + steam_link.CODE_TTL_SEC + 1) is None
    assert steam_link.status(second.poll_token, now=1001.0 + steam_link.CODE_TTL_SEC + 1) == steam_link.EXPIRED
    assert steam_link.status("no-such-token") == steam_link.EXPIRED


def test_linking_looks_pending_to_the_pc() -> None:
    item = steam_link.issue(STEAM_ID, "Gabe")
    item.state = steam_link.LINKING
    assert steam_link.status(item.poll_token) == steam_link.PENDING
    assert steam_link.pending(item.code) is None  # 第二台手机用不了正在绑的码


# --- 路由：关联码 ----------------------------------------------------------------------


def _issue(wired) -> auth.LinkCodeIssued:
    return asyncio.run(auth.steam_link_code(auth.LinkCodeIssueRequest(ticket=TICKET), _request()))


def _confirm(code: str):
    return asyncio.run(auth.steam_link_code_confirm(auth.LinkCodeRequest(code=code), CLAIMS,
                                                    "Bearer phone-access", SID))


def test_full_link_flow(wired) -> None:
    issued = _issue(wired)
    assert issued.name == "Gabe" and issued.expires_in == 300
    preview = asyncio.run(auth.steam_link_code_preview(auth.LinkCodeRequest(code=issued.code), CLAIMS))
    assert preview.name == "Gabe"
    _confirm(issued.code)
    kind, provider, token = wired["client"].calls[-1]
    assert (kind, provider) == ("link", STEAM_PROVIDER)
    assert json.loads(token)["email"] == f"steam-{STEAM_ID}@steam.invalid"  # 游客号绑 Steam 必须带它
    assert wired["respond"][-1][2] == uuid.UUID(SID)  # 不开新登录会话，手机不被踢
    poll = asyncio.run(auth.steam_link_code_status(auth.LinkCodeStatusRequest(poll_token=issued.poll_token),
                                                   _request()))
    assert poll == {"state": steam_link.LINKED}
    with pytest.raises(HTTPException) as exc:  # 只能用一次
        _confirm(issued.code)
    assert exc.value.status_code == 404


def test_wrong_code_is_404(wired) -> None:
    with pytest.raises(HTTPException) as exc:
        asyncio.run(auth.steam_link_code_preview(auth.LinkCodeRequest(code="000000"), CLAIMS))
    assert exc.value.status_code == 404


def test_steam_already_owned_is_409_and_pc_hears_taken(wired) -> None:
    issued = _issue(wired)
    wired["client"] = FakeClient(error=AuthError("taken", 422, "identity_already_exists"))
    response = _confirm(issued.code)
    assert response.status_code == 409 and json.loads(response.body)["code"] == auth.IDENTITY_TAKEN
    assert steam_link.status(issued.poll_token) == steam_link.TAKEN


def test_transient_failure_lets_the_code_be_retried(wired) -> None:
    issued = _issue(wired)
    wired["client"] = FakeClient(error=AuthError("down", 503, ""))
    with pytest.raises(HTTPException):
        _confirm(issued.code)
    assert steam_link.pending(issued.code) is not None
    wired["client"] = FakeClient()
    _confirm(issued.code)
    assert steam_link.status(issued.poll_token) == steam_link.LINKED


def test_banned_phone_cannot_confirm(wired, monkeypatch) -> None:
    issued = _issue(wired)

    class Banned(Exception):
        pass

    async def banned(_uid):
        raise Banned

    monkeypatch.setattr(players, "get_by_auth_uid", banned)
    with pytest.raises(Banned):
        _confirm(issued.code)
    assert steam_link.pending(issued.code) is not None and wired["client"].calls == []
