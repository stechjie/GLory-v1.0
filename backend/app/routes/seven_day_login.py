"""Seven-day login status and explicit daily claim."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException

from app import seven_day_login, shop
from app.jwt_verify import Claims
from app.routes.me import current_claims
from app.routes.shop import _me

router = APIRouter(prefix="/v1/me/seven-day-login", tags=["seven-day-login"])


@router.get("")
async def status(claims: Annotated[Claims, Depends(current_claims)]) -> dict:
    me = await _me(claims)
    return await seven_day_login.status(me.player_id)


@router.post("/claim")
async def claim(claims: Annotated[Claims, Depends(current_claims)]) -> dict:
    me = await _me(claims)
    try:
        return await seven_day_login.claim(me.player_id)
    except shop.ShopRejected as exc:
        raise HTTPException(status_code=409, detail=exc.message,
                            headers={"X-Glory-Reason": exc.code}) from None
