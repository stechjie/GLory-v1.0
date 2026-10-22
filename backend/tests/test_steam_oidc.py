"""Steam 身份证明签发方（app/steam_oidc.py，docs/三方登录设计.md 第八节）。

真连 Supabase 的那一遍在服务器上跑 deploy/check_steam_oidc.py。这里钉的是不需要 Supabase 的判据：
  1. 没配置时两个公开地址回 503，不能冒充「能签」
  2. 说明文件里的签发方、公钥地址和配置一字不差（Supabase 按它核对）
  3. 签出来的证明能用公开的公钥验过，aud / iss / sub / exp / kid 都对
  4. 换钥匙不用重启
  5. 公开地址不在 /v1 下：Supabase 来取时不带客户端版本头
"""

from __future__ import annotations

import json
import os
import time
from types import SimpleNamespace

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from app import steam_oidc
from app.main import app

ISSUER = "https://api.example.com/oidc/steam"
client = TestClient(app)


def _write_key(path) -> None:
    key = ec.generate_private_key(ec.SECP256R1())
    path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                       serialization.NoEncryption()))


@pytest.fixture
def configured(monkeypatch, tmp_path):
    key_file = tmp_path / "steam_oidc_key.pem"
    _write_key(key_file)
    settings = SimpleNamespace(steam_oidc_key_file=str(key_file), steam_oidc_issuer=ISSUER + "/",
                               steam_oidc_client_id="glory-steam")
    monkeypatch.setattr(steam_oidc, "get_settings", lambda: settings)
    monkeypatch.setattr(steam_oidc, "_cache", None)
    return settings, key_file


def test_unconfigured_endpoints_are_503(monkeypatch) -> None:
    settings = SimpleNamespace(steam_oidc_key_file="", steam_oidc_issuer="", steam_oidc_client_id="glory-steam")
    monkeypatch.setattr(steam_oidc, "get_settings", lambda: settings)
    monkeypatch.setattr(steam_oidc, "_cache", None)
    assert client.get("/oidc/steam/.well-known/openid-configuration").status_code == 503
    assert client.get("/oidc/steam/jwks.json").status_code == 503


def test_discovery_matches_the_configured_issuer(configured) -> None:
    r = client.get("/oidc/steam/.well-known/openid-configuration")
    assert r.status_code == 200
    body = r.json()
    assert body["issuer"] == ISSUER  # 末尾的斜杠去掉：Supabase 按字面核对
    assert body["jwks_uri"] == ISSUER + "/jwks.json"
    assert body["id_token_signing_alg_values_supported"] == ["ES256"]
    for required in ("authorization_endpoint", "response_types_supported", "subject_types_supported"):
        assert required in body
    assert "max-age" in r.headers["cache-control"]


def test_minted_token_verifies_with_the_public_jwks(configured) -> None:
    keys = client.get("/oidc/steam/jwks.json").json()["keys"]
    assert len(keys) == 1 and "d" not in keys[0]  # 公开的只有公钥
    token = steam_oidc.mint("76561198000000001", name="Gabe")
    header = jwt.get_unverified_header(token)
    assert header["alg"] == "ES256" and header["kid"] == keys[0]["kid"]
    claims = jwt.decode(token, jwt.PyJWK(keys[0]).key, algorithms=["ES256"],
                        audience="glory-steam", issuer=ISSUER)
    assert claims["sub"] == "76561198000000001" and claims["name"] == "Gabe"
    assert 0 < claims["exp"] - claims["iat"] <= 300


def test_token_expires(configured) -> None:
    keys = client.get("/oidc/steam/jwks.json").json()["keys"]
    old = steam_oidc.mint("76561198000000001", now=time.time() - 3600)
    with pytest.raises(jwt.ExpiredSignatureError):
        jwt.decode(old, jwt.PyJWK(keys[0]).key, algorithms=["ES256"], audience="glory-steam", issuer=ISSUER)


def test_rotating_the_key_needs_no_restart(configured) -> None:
    _settings, key_file = configured
    before = steam_oidc.signing_key().kid
    _write_key(key_file)
    stat = key_file.stat()
    os.utime(key_file, (stat.st_atime, stat.st_mtime + 10))
    assert steam_oidc.signing_key().kid != before
    assert client.get("/oidc/steam/jwks.json").json()["keys"][0]["kid"] == steam_oidc.signing_key().kid


def test_plain_http_issuer_is_refused(configured) -> None:
    settings, _ = configured
    settings.steam_oidc_issuer = "http://api.example.com/oidc/steam"
    assert client.get("/oidc/steam/.well-known/openid-configuration").status_code == 503
    with pytest.raises(steam_oidc.NotConfigured):
        steam_oidc.mint("76561198000000001")


def test_wrong_curve_key_is_refused(configured) -> None:
    _settings, key_file = configured
    key = ec.generate_private_key(ec.SECP384R1())
    key_file.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                           serialization.NoEncryption()))
    stat = key_file.stat()
    os.utime(key_file, (stat.st_atime, stat.st_mtime + 20))
    with pytest.raises(steam_oidc.NotConfigured):
        steam_oidc.signing_key()


def test_web_login_endpoints_are_not_offered(configured) -> None:
    assert client.get("/oidc/steam/authorize").status_code == 400
    assert client.post("/oidc/steam/token").status_code == 400


def test_public_endpoints_skip_the_client_version_gate(configured, monkeypatch) -> None:
    """/v1 前面那道版本检查会挡掉不带客户端头的请求；Supabase 来取说明文件时就不带。"""
    from app import patch_gate

    monkeypatch.setattr(patch_gate, "problem", lambda _headers: {"status": 426, "code": "update", "detail": "x"})
    assert client.get("/oidc/steam/jwks.json").status_code == 200


def test_jwk_thumbprint_is_stable(configured) -> None:
    kid1 = steam_oidc.signing_key().kid
    steam_oidc._cache = None
    assert steam_oidc.signing_key().kid == kid1
    assert json.dumps(steam_oidc.jwks())  # 可以原样序列化
