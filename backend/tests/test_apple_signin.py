"""Apple 一次性授权码撤销：归属核对、凭证保密和删号降级。"""

from __future__ import annotations

import asyncio
import time
import uuid
from types import SimpleNamespace
from urllib.parse import parse_qs

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import HTTPException

from app import apple_signin
from app.jwt_verify import Claims
from app.routes import auth, profile as profile_routes
from app.supabase_auth import LinkedIdentity

CODE = "one-use-apple-code-secret"
REFRESH = "apple-refresh-secret"
SUBJECT = "apple-user-123"
BUNDLE = "com.superforge.glory"


@pytest.fixture
def signing(monkeypatch, tmp_path):
    key = ec.generate_private_key(ec.SECP256R1())
    path = tmp_path / "synthetic.p8"
    path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                      serialization.NoEncryption()))
    monkeypatch.setattr(apple_signin, "get_settings", lambda: SimpleNamespace(
        apple_signin_team_id="TEAM123", apple_signin_key_id="KEY123", apple_signin_key_file=str(path),
        apple_bundle_id=BUNDLE))
    return key


def _id_token(**claims):
    return jwt.encode({"sub": SUBJECT, "iss": apple_signin.APPLE_ISSUER, "aud": BUNDLE,
                       "exp": int(time.time()) + 300, **claims}, "", algorithm="none")


def test_code_exchanged_then_refresh_revoked_without_persistence(signing):
    seen = []

    def handler(request):
        data = {key: values[0] for key, values in parse_qs(request.content.decode()).items()}
        seen.append((request.url.path, data))
        secret_claims = jwt.decode(data["client_secret"], signing.public_key(), algorithms=["ES256"],
                                   audience=apple_signin.APPLE_ISSUER)
        assert secret_claims["iss"] == "TEAM123" and secret_claims["sub"] == BUNDLE
        assert secret_claims["exp"] - secret_claims["iat"] == 300
        assert jwt.get_unverified_header(data["client_secret"])["kid"] == "KEY123"
        if request.url.path == "/auth/token":
            assert data["code"] == CODE and data["grant_type"] == "authorization_code"
            assert "redirect_uri" not in data  # 原生 Apple 请求没有 redirect_uri。
            return httpx.Response(200, json={"id_token": _id_token(), "refresh_token": REFRESH})
        assert data["token"] == REFRESH and data["token_type_hint"] == "refresh_token"
        return httpx.Response(200)

    asyncio.run(apple_signin.revoke_authorization(CODE, SUBJECT, httpx.MockTransport(handler)))
    assert [path for path, _ in seen] == ["/auth/token", "/auth/revoke"]


def test_wrong_apple_account_is_not_revoked(signing):
    paths = []

    def handler(request):
        paths.append(request.url.path)
        return httpx.Response(200, json={"id_token": _id_token(sub="someone-else"), "refresh_token": REFRESH})

    with pytest.raises(apple_signin.RevocationError) as exc:
        asyncio.run(apple_signin.revoke_authorization(CODE, SUBJECT, httpx.MockTransport(handler)))
    assert exc.value.wrong_identity is True
    assert paths == ["/auth/token"]


@pytest.mark.parametrize("claims", [{"aud": "other-app"}, {"iss": "https://wrong.example"}, {"exp": 1}])
def test_apple_token_response_claims_checked(signing, claims):
    paths = []

    def handler(request):
        paths.append(request.url.path)
        return httpx.Response(200, json={"id_token": _id_token(**claims), "refresh_token": REFRESH})

    with pytest.raises(apple_signin.RevocationError):
        asyncio.run(apple_signin.revoke_authorization(CODE, SUBJECT, httpx.MockTransport(handler)))
    assert paths == ["/auth/token"]


@pytest.mark.parametrize("failure_stage", ["exchange", "revoke", "network", "malformed"])
def test_apple_failures_never_echo_credentials(signing, failure_stage):
    def handler(request):
        if failure_stage == "network":
            raise httpx.ConnectError(CODE + REFRESH, request=request)
        if failure_stage == "malformed":
            return httpx.Response(200, json=[])
        if failure_stage == "exchange" or request.url.path == "/auth/revoke":
            return httpx.Response(400, text=CODE + REFRESH)
        return httpx.Response(200, json={"id_token": _id_token(), "refresh_token": REFRESH})

    with pytest.raises(apple_signin.RevocationError) as exc:
        asyncio.run(apple_signin.revoke_authorization(CODE, SUBJECT, httpx.MockTransport(handler)))
    assert CODE not in str(exc.value) and REFRESH not in str(exc.value)


def test_missing_key_is_safe_and_never_contacts_apple(monkeypatch):
    monkeypatch.setattr(apple_signin, "get_settings", lambda: SimpleNamespace(
        apple_signin_team_id="", apple_signin_key_id="", apple_signin_key_file=""))

    def handler(_request):
        raise AssertionError("missing config must not send a request")

    with pytest.raises(apple_signin.RevocationError):
        asyncio.run(apple_signin.revoke_authorization(CODE, SUBJECT, httpx.MockTransport(handler)))


@pytest.mark.parametrize("provider,code,revoked,expected", [
    ("google", None, False, False),
    ("apple", None, False, True),
    ("apple", CODE, True, False),
    ("apple", CODE, False, True),
])
def test_delete_checks_binding_and_reports_manual_revocation(monkeypatch, provider, code, revoked, expected):
    called = []

    class Client:
        async def linked_identities(self, access):
            assert access == "player-access"
            return False, [LinkedIdentity(provider, "", subject=SUBJECT)]

    async def revoke(actual_code, subject):
        called.append((actual_code, subject))
        if not revoked:
            raise apple_signin.RevocationError("unavailable")

    monkeypatch.setattr(auth, "_auth_client", Client)
    monkeypatch.setattr(apple_signin, "revoke_authorization", revoke)
    assert asyncio.run(profile_routes._apple_revocation_required("Bearer player-access", code)) is expected
    assert called == ([(CODE, SUBJECT)] if provider == "apple" and code else [])


def test_wrong_apple_identity_aborts_before_deleting(monkeypatch):
    uid = str(uuid.uuid4())

    async def current(_claims):
        return SimpleNamespace(friend_code="ABCD2345", player_id=uuid.uuid4())

    async def check(_authorization, _code):
        raise HTTPException(400, "请选择当前游戏账号绑定的 Apple 账号")

    async def erase(_player_id):
        raise AssertionError("wrong identity must not erase data")

    monkeypatch.setattr(profile_routes, "_current_profile", current)
    monkeypatch.setattr(profile_routes, "_apple_revocation_required", check)
    monkeypatch.setattr(profile_routes.profile, "delete_player", erase)
    with pytest.raises(HTTPException) as exc:
        asyncio.run(profile_routes.delete_me(profile_routes.DeleteRequest(friend_code="ABCD2345",
            apple_authorization_code=CODE), Claims(uid, False, 9999999999), "Bearer player-access"))
    assert exc.value.status_code == 400


@pytest.mark.parametrize("manual_required", [False, True])
def test_deleted_account_explicitly_reports_revocation_requirement(monkeypatch, manual_required):
    uid = str(uuid.uuid4())

    async def current(_claims):
        return SimpleNamespace(friend_code="ABCD2345", player_id=uuid.uuid4())

    async def manual(_authorization, _code):
        return manual_required

    async def erase(_player_id):
        return True

    async def erase_auth(_uid):
        pass

    monkeypatch.setattr(profile_routes, "_current_profile", current)
    monkeypatch.setattr(profile_routes, "_apple_revocation_required", manual)
    monkeypatch.setattr(profile_routes.profile, "delete_player", erase)
    monkeypatch.setattr(profile_routes.supabase_admin, "delete_user", erase_auth)
    result = asyncio.run(profile_routes.delete_me(profile_routes.DeleteRequest(friend_code="ABCD2345"),
        Claims(uid, False, 9999999999), "Bearer player-access"))
    assert result == {"deleted": True, "apple_revocation_required": manual_required}
    assert type(result["apple_revocation_required"]) is bool
