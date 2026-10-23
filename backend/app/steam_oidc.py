"""账号服务器当 Steam 的身份证明签发方（docs/三方登录设计.md 第八节）。

Supabase 不认识 Steam。做法是：账号服务器找 Steam 验完票、知道这个人的 SteamID 之后，
**自己签一张 5 分钟的身份证明**（OIDC id_token），交给 Supabase 里登记的自定义提供方
`custom:steam`。Supabase 照着下面公开的说明地址拿公钥验签，之后 Steam 就和 Google 一样：
登录、绑定、冲突（identity_already_exists）、注销删用户，全部复用同一套。

公开出去的只有两样，都不是秘密：
  {issuer}/.well-known/openid-configuration   说明这个签发方是谁、公钥在哪
  {issuer}/jwks.json                           公钥

🔴 **身份证明只在账号服务器内部签、内部用，绝不交给客户端。** 谁拿到私钥谁就能冒充任意 Steam 玩家，
所以私钥只在这台机器的一个文件里（config.steam_oidc_key_file）。
"""

from __future__ import annotations

import base64
import hashlib
import json
import time
from dataclasses import dataclass
from pathlib import Path

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.config import get_settings

ALGORITHM = "ES256"
# 签完当场交给 Supabase。给几分钟余量只为容忍两台机器的时钟差。
TOKEN_TTL_SEC = 300


class NotConfigured(RuntimeError):
    """没配私钥或签发方地址。message 不含密钥，可以外传。"""


@dataclass(frozen=True)
class SigningKey:
    private_key: ec.EllipticCurvePrivateKey
    kid: str
    public_jwk: dict


_cache: tuple[str, float, SigningKey] | None = None


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _jwk_of(public_key: ec.EllipticCurvePublicKey) -> tuple[str, dict]:
    numbers = public_key.public_numbers()
    x = _b64url(numbers.x.to_bytes(32, "big"))
    y = _b64url(numbers.y.to_bytes(32, "big"))
    # RFC 7638 指纹当 kid：同一把钥匙永远是同一个 kid，换了钥匙 kid 自然变。
    thumbprint = json.dumps({"crv": "P-256", "kty": "EC", "x": x, "y": y}, separators=(",", ":"), sort_keys=True)
    kid = _b64url(hashlib.sha256(thumbprint.encode("ascii")).digest())
    return kid, {"kty": "EC", "crv": "P-256", "x": x, "y": y, "kid": kid, "alg": ALGORITHM, "use": "sig"}


def signing_key() -> SigningKey:
    """读私钥（按文件修改时间缓存：换了钥匙不用重启也能生效）。"""
    global _cache
    path = get_settings().steam_oidc_key_file.strip()
    if not path:
        raise NotConfigured("没配 GLORY_STEAM_OIDC_KEY_FILE")
    file = Path(path)
    try:
        mtime = file.stat().st_mtime
    except OSError:
        raise NotConfigured("Steam 登录的签名私钥文件不存在") from None
    if _cache is not None and _cache[0] == path and _cache[1] == mtime:
        return _cache[2]
    key = serialization.load_pem_private_key(file.read_bytes(), password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != "secp256r1":
        raise NotConfigured("Steam 登录的签名私钥不是 EC P-256")
    kid, jwk = _jwk_of(key.public_key())
    loaded = SigningKey(key, kid, jwk)
    _cache = (path, mtime, loaded)
    return loaded


def issuer() -> str:
    value = get_settings().steam_oidc_issuer.strip().rstrip("/")
    if not value:
        raise NotConfigured("没配 GLORY_STEAM_OIDC_ISSUER")
    if not value.startswith("https://"):
        # Supabase 只认 https 的签发方。
        raise NotConfigured("GLORY_STEAM_OIDC_ISSUER 必须是 https 地址")
    return value


def discovery() -> dict:
    iss = issuer()
    signing_key()  # 没有钥匙就别对外说自己能签
    return {
        "issuer": iss,
        "jwks_uri": f"{iss}/jwks.json",
        # 这两个是 OIDC 说明文件的必填项。这个签发方不提供网页登录，地址存在但只回 400。
        "authorization_endpoint": f"{iss}/authorize",
        "token_endpoint": f"{iss}/token",
        "response_types_supported": ["id_token"],
        "subject_types_supported": ["public"],
        "id_token_signing_alg_values_supported": [ALGORITHM],
        "scopes_supported": ["openid"],
        "claims_supported": ["iss", "sub", "aud", "exp", "iat", "name", "email", "email_verified"],
    }


def jwks() -> dict:
    return {"keys": [signing_key().public_jwk]}


def mint(subject: str, *, name: str = "", email: str = "", now: float | None = None) -> str:
    """给一个已经验证过的 SteamID 签身份证明。**只给账号服务器自己用**，不许出现在任何响应里。

    email：Steam 本身不给邮箱。但 Supabase 往一个**没有邮箱的号**（游客）上绑登录方式时，会从新身份
    拿邮箱回填，拿到空串就报 email_address_invalid（2026-10-23 第 0 步实测）。所以要带一个固定格式、
    收不到信的假邮箱，并标成已验证 —— 标成未验证的话 Supabase 会去发确认信。具体写法见第 0 步的结论。
    """
    if not subject:
        raise ValueError("subject 不能为空")
    key = signing_key()
    issued = int(now if now is not None else time.time())
    claims = {
        "iss": issuer(),
        "aud": get_settings().steam_oidc_client_id,
        "sub": subject,
        "iat": issued,
        "exp": issued + TOKEN_TTL_SEC,
    }
    if name:
        claims["name"] = name
    if email:
        claims["email"] = email
        claims["email_verified"] = True
    return jwt.encode(claims, key.private_key, algorithm=ALGORITHM, headers={"kid": key.kid})
