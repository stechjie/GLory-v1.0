"""令牌校验的行为用例。

用本地生成的一对 EC 密钥 + MockTransport 伪造出一个 JWKS，所以这些判据
**不需要真实凭据**就能进门禁。真实令牌那一遍是手动做的（见 README 第 4 步）。

最重要的是 test_hs256_forgery_is_rejected —— 它挡的是 JWT 最经典的那个洞。
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import time

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.jwt_verify import TokenError, TokenVerifier

BASE = "https://example.supabase.co"
ISSUER = f"{BASE}/auth/v1"
KID = "test-key-1"

_private_key = ec.generate_private_key(ec.SECP256R1())
_public_key = _private_key.public_key()

_PRIVATE_PEM = _private_key.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption(),
).decode()

# 公钥的 PEM。它是**公开**的 —— jwks.json 里人人可取。
# 下面那个伪造用例正是拿它当 HMAC 密钥。
_PUBLIC_PEM = _public_key.public_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PublicFormat.SubjectPublicKeyInfo,
).decode()


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def _jwks_body() -> dict:
    entry = json.loads(jwt.algorithms.ECAlgorithm.to_jwk(_public_key))
    entry.update({"kid": KID, "alg": "ES256", "use": "sig"})
    return {"keys": [entry]}


def _transport() -> httpx.MockTransport:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path.endswith("/.well-known/jwks.json")
        return httpx.Response(200, json=_jwks_body())

    return httpx.MockTransport(handler)


def _verifier() -> TokenVerifier:
    return TokenVerifier(BASE, transport=_transport())


def _claims(**overrides) -> dict:
    now = int(time.time())
    base = {
        "sub": "auth-uid-1",
        "aud": "authenticated",
        "iss": ISSUER,
        "iat": now,
        "exp": now + 3600,
        "is_anonymous": True,
        "role": "authenticated",
    }
    base.update(overrides)
    return base


def _forge_hs256(**overrides) -> str:
    """手工拼一个用**公钥**当 HMAC 密钥签的 HS256 令牌 —— 真实攻击者的做法。

    不能用 jwt.encode 来造：PyJWT 在**编码侧**就拒绝拿 PEM 公钥当 HMAC 密钥
    （InvalidKeyError）。那是它的一层好心保护，但它保护不了验签方 ——
    攻击者不会用我们的库，他会像下面这样自己拼字节。
    """
    header = _b64(json.dumps({"alg": "HS256", "typ": "JWT", "kid": KID}).encode())
    payload = _b64(json.dumps(_claims(**overrides)).encode())
    signing_input = f"{header}.{payload}".encode()
    sig = hmac.new(_PUBLIC_PEM.encode(), signing_input, hashlib.sha256).digest()
    return f"{header}.{payload}.{_b64(sig)}"


def _sign_es256(**overrides) -> str:
    return jwt.encode(_claims(**overrides), _PRIVATE_PEM, algorithm="ES256", headers={"kid": KID})


def _verify(token: str):
    return asyncio.run(_verifier().verify(token))


# --- 正例 ---------------------------------------------------------------------


def test_valid_token_is_accepted() -> None:
    claims = _verify(_sign_es256())
    assert claims.auth_uid == "auth-uid-1"
    assert claims.is_anonymous is True


# --- 安全判据 ------------------------------------------------------------------


def test_hs256_forgery_is_rejected() -> None:
    """**本文件最重要的一条：algorithm confusion。**

    验签方若同时接受非对称（ES/RS）和对称（HS）算法，攻击者可以拿那把
    **公开的**公钥当 HMAC 密钥去签一个 HS256 令牌。公钥就在 jwks.json 里人人可取，
    于是任何人都能伪造任意身份 —— 包括别人的 sub。

    唯一可靠的挡法是把算法写成白名单。这条用例钉住 ALLOWED_ALGORITHMS
    里永远不出现 HS256。
    """
    forged = _forge_hs256(sub="attacker")
    with pytest.raises(TokenError) as exc:
        _verify(forged)
    assert "HS256" in str(exc.value)


def test_none_algorithm_is_rejected() -> None:
    """alg=none 是同一族的老洞：不签名也想被接受。"""
    forged = jwt.encode(_claims(sub="attacker"), key=None, algorithm=None, headers={"kid": KID})
    with pytest.raises(TokenError):
        _verify(forged)


def test_wrong_issuer_is_rejected() -> None:
    """别的 Supabase 项目签发的令牌不能在这里用。

    没有这条，任何人建一个自己的 Supabase 项目就能签出被我们接受的令牌。
    """
    with pytest.raises(TokenError):
        _verify(_sign_es256(iss="https://attacker.supabase.co/auth/v1"))


def test_wrong_audience_is_rejected() -> None:
    with pytest.raises(TokenError):
        _verify(_sign_es256(aud="anon"))


def test_expired_token_is_rejected() -> None:
    now = int(time.time())
    with pytest.raises(TokenError) as exc:
        _verify(_sign_es256(iat=now - 7200, exp=now - 3600))
    assert "过期" in str(exc.value)


def test_unknown_kid_is_rejected() -> None:
    token = jwt.encode(_claims(), _PRIVATE_PEM, algorithm="ES256", headers={"kid": "no-such-key"})
    with pytest.raises(TokenError):
        _verify(token)


def test_missing_required_claim_is_rejected() -> None:
    """缺 sub 就没有身份。不能因为"其它都对"就放过去。"""
    claims = _claims()
    del claims["sub"]
    token = jwt.encode(claims, _PRIVATE_PEM, algorithm="ES256", headers={"kid": KID})
    with pytest.raises(TokenError):
        _verify(token)


def test_error_messages_never_contain_the_token() -> None:
    """报错会进日志、进监控。令牌是凭证，一个字节都不该出现在里面。"""
    now = int(time.time())
    bad_tokens = [
        "garbage",
        _sign_es256(iat=now - 7200, exp=now - 3600),
        _forge_hs256(),
    ]
    for token in bad_tokens:
        try:
            _verify(token)
        except TokenError as exc:
            assert token not in str(exc), "错误信息里出现了令牌本身"
        else:
            raise AssertionError(f"这个令牌本应被拒绝：{token[:12]}...")
