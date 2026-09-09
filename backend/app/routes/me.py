"""GET /v1/me —— 「我是谁」。

这是第一个**需要携带令牌**的接口，也是之后所有账号接口的模板：
    Authorization: Bearer <access_token>
        -> 验签（jwt_verify）拿到 auth_uid
        -> 查 player_identities 拿到 player_id
        -> 之后一切游戏数据都用 player_id

注意这里**只读，不建**。玩家不存在就是 404，不会顺手补一个 ——
建账号只有 /v1/auth/anonymous 一条路，多一条就多一个可以绕开的入口。
"""

from __future__ import annotations

import logging
import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel

from app import db, players
from app.config import get_settings
from app.jwt_verify import Claims, TokenError, TokenVerifier

log = logging.getLogger("glory.me")

router = APIRouter(prefix="/v1", tags=["me"])

# 进程内共用一个 verifier，这样 JWKS 缓存才有意义 ——
# 每个请求新建一个的话，等于每次都去拉一遍公钥。
_verifier: TokenVerifier | None = None


def get_verifier() -> TokenVerifier:
    global _verifier
    if _verifier is None:
        _verifier = TokenVerifier(get_settings().supabase_url)
    return _verifier


async def current_claims(
    authorization: Annotated[str | None, Header()] = None,
) -> Claims:
    """从 Authorization 头解出并校验令牌。所有需要身份的接口都依赖它。"""
    if not get_settings().supabase_url:
        raise HTTPException(status_code=503, detail="Supabase 未配置：缺 GLORY_SUPABASE_URL")
    if not authorization:
        raise HTTPException(status_code=401, detail="缺少 Authorization 头")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise HTTPException(status_code=401, detail="Authorization 头应为 'Bearer <token>'")
    try:
        return await get_verifier().verify(token.strip())
    except TokenError as exc:
        # TokenError 的 message 里不含令牌本身（见 jwt_verify），可以外传。
        raise HTTPException(status_code=401, detail=str(exc)) from None


async def optional_claims(
    authorization: Annotated[str | None, Header()] = None,
) -> Claims | None:
    """**能解出身份就解，解不出就当匿名，永不抛异常。**

    只给「公开但带了身份会更好用」的接口用 —— 目前是
    GET /v1/players/by-code/{code}（要显示「加好友 / 已是好友 / 待通过」）。

    为什么令牌无效时不回 401：那是一个**公开视图**，身份只是增强。
    带着过期令牌的玩家点进别人资料页时，401 会让整页打不开；
    降级成匿名最多让按钮显示成「加好友」，他点下去会收到
    「你们已经是好友了」——那句话本身就解释了发生什么。
    两种坏结果里，后者明显轻。

    ⚠️ **绝不能把这个依赖用在会改数据的接口上。** 那里必须是 current_claims，
    无效令牌就该 401。这条只在读接口上成立。
    """
    if not authorization or not get_settings().supabase_url:
        return None
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        return None
    try:
        return await get_verifier().verify(token.strip())
    except TokenError:
        return None


class MeResponse(BaseModel):
    player_id: uuid.UUID
    player_name: str
    is_anonymous: bool


@router.get("/me", response_model=MeResponse)
async def me(claims: Annotated[Claims, Depends(current_claims)]) -> MeResponse:
    if not db.is_connected():
        raise HTTPException(
            status_code=503,
            detail="数据库未配置：backend/.env 里的 GLORY_DATABASE_URL 是空的",
        )
    player = await players.get_by_auth_uid(claims.auth_uid)
    if player is None:
        # 令牌有效但没有对应玩家。正常流程走不到这里 —— 多半是令牌来自
        # 另一个 Supabase 项目，或者玩家行被手工删了。不自动补建。
        raise HTTPException(status_code=404, detail="该身份没有对应的玩家，请重新登录")
    return MeResponse(
        player_id=player.player_id,
        player_name=player.player_name,
        is_anonymous=claims.is_anonymous,
    )
