"""出战配置与出战名片（docs/商城系统设计.md 第五节）。

    GET  /v1/me/races        出战种族（null = 没选过，用默认）
    PUT  /v1/me/races        存出战种族
    POST /v1/battle/card     领一张出战名片，连战斗服务器前用

出战宠物走 /v1/me/pets（routes/shop.py），头像头像框走 /v1/me/profile —— 它们本来就在那。
名片只是把这些**已经存在账号服务器上的东西**签个名打包，不另开一套存储。
"""

from __future__ import annotations

import logging
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app import db, loadout, players
from app.jwt_verify import Claims
from app.rate_limit import RateLimited, SlidingWindowLimiter
from app.routes.me import current_claims

log = logging.getLogger("glory.loadout")

router = APIRouter(prefix="/v1", tags=["loadout"])

# 名片的领取额度。正常玩家一局领一次（开局或加入房间时）；
# 按 player_id 计，不按 IP —— 运营商 NAT 下同一出口 IP 是成片的正常玩家。
CARD_PER_MINUTE = 20
_card_limiter = SlidingWindowLimiter(CARD_PER_MINUTE, 60.0)

_STATUS_BY_CODE = {
    "bad_races": 400,
    "race_not_owned": 403,
    "player_not_found": 404,
}


class RacesBody(BaseModel):
    races: list[str]


class RacesResponse(BaseModel):
    # null = 没选过。**不要**在这里替客户端填默认：默认值是战斗服务器按棋子表算的，
    # 这边填一份就是第二个真相。
    races: list[str] | None


class CardResponse(BaseModel):
    # 不透明字符串。客户端原样交给战斗服务器，**不解析、不改**。
    card: str
    expires_in: int


async def _me(claims: Claims) -> players.Player:
    if not db.is_connected():
        raise HTTPException(
            status_code=503,
            detail="数据库未配置：backend/.env 里的 GLORY_DATABASE_URL 是空的",
        )
    player = await players.get_by_auth_uid(claims.auth_uid)
    if player is None:
        raise HTTPException(status_code=404, detail="该身份没有对应的玩家，请重新登录")
    return player


def _reject(exc: loadout.LoadoutRejected) -> HTTPException:
    return HTTPException(
        status_code=_STATUS_BY_CODE.get(exc.code, 400),
        detail=exc.message,
        headers={"X-Glory-Reason": exc.code},
    )


@router.get("/me/races", response_model=RacesResponse)
async def my_races(claims: Annotated[Claims, Depends(current_claims)]) -> RacesResponse:
    me = await _me(claims)
    return RacesResponse(races=await loadout.read_races(me.player_id))


@router.put("/me/races", response_model=RacesResponse)
async def set_races(
    body: RacesBody,
    claims: Annotated[Claims, Depends(current_claims)],
) -> RacesResponse:
    me = await _me(claims)
    try:
        races = await loadout.save_races(me.player_id, body.races)
    except loadout.LoadoutRejected as exc:
        raise _reject(exc) from None
    return RacesResponse(races=races)


@router.post("/battle/card", response_model=CardResponse)
async def battle_card(claims: Annotated[Claims, Depends(current_claims)]) -> CardResponse:
    """领一张出战名片。

    没配私钥回 **503**，不是 500：那是服务器配置问题，客户端据此提示「稍后再试」。
    """
    me = await _me(claims)
    try:
        _card_limiter.check(str(me.player_id))
    except RateLimited as exc:
        raise HTTPException(
            status_code=429,
            detail="操作太快了，%d 秒后再试" % exc.retry_after,
            headers={"Retry-After": str(exc.retry_after)},
        ) from None
    try:
        card = await loadout.issue_card(me.player_id)
    except loadout.CardKeyMissing as exc:
        # 日志里留原因，给玩家的只有一句「稍后再试」—— 路径不外传。
        log.error("发不了出战名片：%s", exc)
        raise HTTPException(status_code=503, detail="对战服务暂时不可用，稍后再试") from None
    except loadout.LoadoutRejected as exc:
        raise _reject(exc) from None
    return CardResponse(card=card, expires_in=loadout.CARD_TTL_SEC)
