"""校验客户端带来的 Supabase access token。

第 3 步是**发**令牌，这里是**收**令牌。之后所有「需要知道你是谁」的接口都靠它。

实测过这个项目签发的令牌长这样：

    header  {"alg": "ES256", "kid": "...", "typ": "JWT"}
    claims  aud="authenticated"  iss="<SUPABASE_URL>/auth/v1"
            sub=<auth uid>  exp=iat+3600  is_anonymous=true  role="authenticated"

签名是 **ES256 非对称**，公钥在 /auth/v1/.well-known/jwks.json。
所以后端**不需要任何 JWT 密钥** —— 只用公钥验签，密钥轮换靠重新拉 JWKS。

⚠️ 令牌本身是凭证。任何日志与异常都不准带上它。
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass

import httpx
import jwt

log = logging.getLogger("glory.jwt")

# ⛔ 只接受非对称算法。**绝不能**把 HS256 放进来。
#
# 这是 JWT 最经典的一个洞（algorithm confusion）：验签方同时接受 RS/ES 和 HS 时，
# 攻击者可以拿**公开的**公钥当作 HMAC 密钥去签一个 HS256 令牌。公钥本来就是
# 公开的（就在上面那个 jwks.json 里），于是任何人都能伪造任意身份的令牌。
#
# 把算法写死成白名单是唯一可靠的挡法。改这一行前先想清楚。
ALLOWED_ALGORITHMS = ["ES256", "RS256"]

# 令牌里必须存在的 claim。缺任何一个都拒绝 —— 不给"某个校验项恰好缺失所以被跳过"
# 留任何空间。
REQUIRED_CLAIMS = ["exp", "iat", "sub", "aud", "iss"]

_JWKS_TTL = 600.0
# 收到未知 kid 时才会提前重拉（密钥轮换）。这里限制最小间隔，
# 否则攻击者发一串随机 kid 的令牌就能让我们不停打 Supabase。
_MIN_REFETCH_INTERVAL = 30.0

_TIMEOUT = httpx.Timeout(10.0, connect=5.0)


class TokenError(Exception):
    """令牌不可信。message 里**绝不含令牌本身**，可以安全外传。"""


@dataclass(frozen=True)
class Claims:
    auth_uid: str
    is_anonymous: bool
    expires_at: int


class TokenVerifier:
    def __init__(
        self,
        supabase_url: str,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        base = supabase_url.rstrip("/")
        self._issuer = f"{base}/auth/v1"
        self._jwks_uri = f"{base}/auth/v1/.well-known/jwks.json"
        # 测试注入点，同 supabase_auth.SupabaseAuth。生产上永远是 None。
        self._transport = transport
        self._keys: dict[str, jwt.PyJWK] = {}
        self._fetched_at = 0.0

    @property
    def configured(self) -> bool:
        return bool(self._issuer and not self._issuer.startswith("/"))

    async def _fetch_jwks(self) -> None:
        async with httpx.AsyncClient(timeout=_TIMEOUT, transport=self._transport) as client:
            resp = await client.get(self._jwks_uri)
        if resp.status_code >= 400:
            raise TokenError(f"拉取 JWKS 失败（HTTP {resp.status_code}）")
        key_set = jwt.PyJWKSet.from_dict(resp.json())
        self._keys = {k.key_id: k for k in key_set.keys if k.key_id}
        self._fetched_at = time.monotonic()
        log.info("JWKS 已更新，公钥 %d 个", len(self._keys))

    async def _signing_key(self, kid: str) -> jwt.PyJWK:
        age = time.monotonic() - self._fetched_at
        if not self._keys or age > _JWKS_TTL:
            await self._fetch_jwks()
        if kid in self._keys:
            return self._keys[kid]
        # 未知 kid：可能是密钥刚轮换过。重拉一次，但受最小间隔保护。
        if age > _MIN_REFETCH_INTERVAL:
            await self._fetch_jwks()
        if kid not in self._keys:
            raise TokenError("令牌的签名密钥不在 JWKS 里")
        return self._keys[kid]

    async def verify(self, token: str) -> Claims:
        try:
            header = jwt.get_unverified_header(token)
        except jwt.PyJWTError as exc:
            # 不把 token 拼进消息 —— 它是凭证。
            raise TokenError(f"令牌头解析失败：{type(exc).__name__}") from None

        alg = header.get("alg")
        if alg not in ALLOWED_ALGORITHMS:
            # 这里挡的就是上面说的 algorithm confusion。
            raise TokenError(f"不接受的签名算法：{alg}")
        kid = header.get("kid")
        if not kid:
            raise TokenError("令牌头缺少 kid")

        signing_key = await self._signing_key(str(kid))
        try:
            claims = jwt.decode(
                token,
                key=signing_key.key,
                algorithms=ALLOWED_ALGORITHMS,
                audience="authenticated",
                issuer=self._issuer,
                options={"require": REQUIRED_CLAIMS},
            )
        except jwt.ExpiredSignatureError:
            raise TokenError("令牌已过期") from None
        except jwt.PyJWTError as exc:
            raise TokenError(f"令牌校验失败：{type(exc).__name__}") from None

        sub = str(claims.get("sub") or "")
        if not sub:
            raise TokenError("令牌缺少 sub")
        return Claims(
            auth_uid=sub,
            is_anonymous=bool(claims.get("is_anonymous", False)),
            expires_at=int(claims["exp"]),
        )
