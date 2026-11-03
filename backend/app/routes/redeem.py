"""兑换码：玩家填码领奖（app/redeem.py）。奖励发到邮箱。"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from app import redeem
from app.jwt_verify import Claims
from app.routes.me import current_claims
from app.routes.shop import _me

router = APIRouter(prefix="/v1/me/redeem", tags=["redeem"])

# 「码不存在」和「格式不对」同一个状态码、同一个 reason：不给爆破的人多一个信号。
_STATUS_BY_CODE = {
    "redeem_invalid": 400,
}


class RedeemBody(BaseModel):
    code: str = Field(min_length=1, max_length=64)


@router.post("")
async def claim(body: RedeemBody, claims: Annotated[Claims, Depends(current_claims)]) -> dict:
    me = await _me(claims)
    try:
        result = await redeem.claim(me.player_id, body.code)
    except redeem.RedeemLocked as exc:
        raise HTTPException(status_code=429, detail=str(exc),
                            headers={"Retry-After": str(exc.retry_after),
                                     "X-Glory-Reason": "redeem_locked"}) from None
    except redeem.RedeemRejected as exc:
        raise HTTPException(status_code=_STATUS_BY_CODE.get(exc.code, 409), detail=exc.message,
                            headers={"X-Glory-Reason": exc.code}) from None
    return {"mail_id": result.mail_id, "diamond": result.diamond, "coin": result.coin,
            "items": list(result.items)}
