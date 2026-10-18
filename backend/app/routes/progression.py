"""Account level, next rewards, and pending level-up reveals."""
from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app import db, players, progression
from app.jwt_verify import Claims
from app.routes.me import current_claims

router = APIRouter(prefix="/v1/me", tags=["progression"])


class AcknowledgeBody(BaseModel):
    levels: list[int]


async def _player(claims: Claims):
    player = await players.get_by_auth_uid(claims.auth_uid)
    if player is None:
        raise HTTPException(404, "该身份没有对应的玩家")
    return player


@router.get("/progression")
async def my_progression(claims: Annotated[Claims, Depends(current_claims)]) -> dict:
    player = await _player(claims)
    async with db.pool().acquire() as conn:
        return await progression.state(conn, player.player_id)


@router.post("/progression/seen")
async def seen_levels(body: AcknowledgeBody,
                      claims: Annotated[Claims, Depends(current_claims)]) -> dict:
    player = await _player(claims)
    clean = sorted({n for n in body.levels if 2 <= n <= 20})
    async with db.pool().acquire() as conn:
        await progression.acknowledge(conn, player.player_id, clean)
    return {"seen": clean}
