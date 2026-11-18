"""Sign in with Apple 的一次性授权撤销。

注销时用刚取得的授权码换取 Apple token，核对它属于当前绑定身份后立即撤销。
不存授权码、Apple token 或邮箱，不回显 Apple 的响应体。
https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens
"""

from __future__ import annotations

import time
from pathlib import Path

import httpx
import jwt

from app.config import get_settings

APPLE_ISSUER = "https://appleid.apple.com"
_TIMEOUT = httpx.Timeout(10.0, connect=5.0)


class RevocationError(RuntimeError):
    def __init__(self, message: str, *, wrong_identity: bool = False) -> None:
        super().__init__(message)
        self.wrong_identity = wrong_identity


def _client_secret() -> tuple[str, str]:
    settings = get_settings()
    if not (settings.apple_signin_team_id and settings.apple_signin_key_id and settings.apple_signin_key_file):
        raise RevocationError("Apple 授权撤销尚未配置")
    now = int(time.time())
    try:
        secret = jwt.encode(
            {"iss": settings.apple_signin_team_id, "iat": now, "exp": now + 300,
             "aud": APPLE_ISSUER, "sub": settings.apple_bundle_id},
            Path(settings.apple_signin_key_file).read_bytes(), algorithm="ES256",
            headers={"kid": settings.apple_signin_key_id},
        )
    except (OSError, ValueError, jwt.PyJWTError):
        raise RevocationError("Apple 授权撤销密钥不可用") from None
    return settings.apple_bundle_id, secret


def _response_identity(id_token: str, client_id: str) -> str:
    # 只解析本函数从固定 Apple HTTPS /auth/token 端点直接拿到的令牌，绝不接受
    # 客户端传入的未验签 JWT。TLS 已认证响应来源；再检查签发方、受众和有效期。
    try:
        claims = jwt.decode(
            id_token, options={"verify_signature": False, "verify_exp": True,
                               "verify_aud": True, "verify_iss": True,
                               "require": ["sub", "iss", "aud", "exp"]},
            audience=client_id, issuer=APPLE_ISSUER,
        )
        subject = claims["sub"]
        if not isinstance(subject, str) or not subject:
            raise ValueError("missing subject")
        return subject
    except (ValueError, TypeError, jwt.PyJWTError):
        raise RevocationError("Apple 返回的授权身份无效") from None


async def revoke_authorization(
    authorization_code: str, expected_subject: str,
    transport: httpx.AsyncBaseTransport | None = None,
) -> None:
    if not expected_subject:
        raise RevocationError("无法核对已绑定的 Apple 身份")
    client_id, client_secret = _client_secret()
    form = {"client_id": client_id, "client_secret": client_secret}
    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT, transport=transport) as client:
            exchanged = await client.post(f"{APPLE_ISSUER}/auth/token", data={
                **form, "grant_type": "authorization_code", "code": authorization_code,
            })
            if exchanged.status_code != 200:
                raise RevocationError("Apple 授权码验证失败，请重新确认 Apple 账号")
            try:
                payload = exchanged.json()
                if not isinstance(payload, dict):
                    raise ValueError("invalid response")
                subject = _response_identity(payload["id_token"], client_id)
                token = payload.get("refresh_token") or payload.get("access_token")
                hint = "refresh_token" if payload.get("refresh_token") else "access_token"
                if not isinstance(token, str) or not token:
                    raise ValueError("missing token")
            except (KeyError, ValueError, TypeError):
                raise RevocationError("Apple 没有返回可撤销的授权") from None
            if subject != expected_subject:
                raise RevocationError("请选择当前游戏账号绑定的 Apple 账号", wrong_identity=True)
            revoked = await client.post(f"{APPLE_ISSUER}/auth/revoke", data={
                **form, "token": token, "token_type_hint": hint,
            })
            if revoked.status_code != 200:
                raise RevocationError("Apple 授权撤销暂时不可用")
    except httpx.HTTPError:
        raise RevocationError("无法连接 Apple 授权服务") from None
