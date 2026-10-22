"""Steam 身份证明签发方的公开地址（app/steam_oidc.py）。给 Supabase 看的，不是给客户端的。

    GET /oidc/steam/.well-known/openid-configuration
    GET /oidc/steam/jwks.json
    GET /oidc/steam/authorize, /oidc/steam/token    只回 400：这个签发方不提供网页登录

路径不在 /v1 下：Supabase 来取的时候不带客户端版本头，/v1 前面那道版本检查会把它挡掉。
"""

from __future__ import annotations

from fastapi import APIRouter, HTTPException
from fastapi.responses import JSONResponse

from app import steam_oidc

router = APIRouter(prefix="/oidc/steam", tags=["steam-oidc"])

# 公钥换了以后 Supabase 要能很快拿到新的；同时别让它每次登录都来取一遍。
_CACHE = {"Cache-Control": "public, max-age=300"}


def _or_503(build) -> JSONResponse:
    try:
        return JSONResponse(build(), headers=_CACHE)
    except steam_oidc.NotConfigured as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from None


@router.get("/.well-known/openid-configuration")
async def openid_configuration() -> JSONResponse:
    return _or_503(steam_oidc.discovery)


@router.get("/jwks.json")
async def jwks() -> JSONResponse:
    return _or_503(steam_oidc.jwks)


@router.get("/authorize")
@router.post("/token")
async def not_offered() -> None:
    raise HTTPException(status_code=400, detail="这个签发方只给账号服务器内部用，不提供网页登录")
