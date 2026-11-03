"""邀请码：查自己的状态、填码（app/invites.py）。

自己的邀请码就是好友码，资料页本来就有，这里不再返回一遍。
邀请了几个人、到账几个**不返回**：2026-11-03 用户定玩家那边不显示，不显示的数字就不下发。
客服要看去后台的玩家详情。
"""

from __future__ import annotations

from dataclasses import asdict
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from app import invites
from app.jwt_verify import Claims
from app.routes.me import current_claims
from app.routes.shop import _me

router = APIRouter(prefix="/v1/me/invite", tags=["invite"])

_STATUS_BY_CODE = {
    "invite_code_invalid": 400,
    "invite_code_not_found": 404,
    "invite_no_player": 404,
}


class BindBody(BaseModel):
    code: str = Field(min_length=1, max_length=64)


def _reject(exc: invites.InviteRejected) -> HTTPException:
    return HTTPException(status_code=_STATUS_BY_CODE.get(exc.code, 409), detail=exc.message,
                         headers={"X-Glory-Reason": exc.code})


@router.get("")
async def status(claims: Annotated[Claims, Depends(current_claims)]) -> dict:
    me = await _me(claims)
    return asdict(await invites.status(me.player_id))


@router.post("/bind")
async def bind(body: BindBody, claims: Annotated[Claims, Depends(current_claims)]) -> dict:
    me = await _me(claims)
    try:
        return asdict(await invites.bind(me.player_id, body.code))
    except invites.InviteRejected as exc:
        raise _reject(exc) from None
