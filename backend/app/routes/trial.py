"""体验卡接口（backend/app/trial.py、database/047_trial_cards.sql）。

    GET  /v1/me/bag                     背包：体验卡、正在体验的东西、服务器当前时间
    POST /v1/me/bag/use                 用一张卡（开始计时 / 往后叠）
    POST /v1/me/bag/sell                出售卡（1/3/7 天 = 100/200/300 游戏币）
    GET  /v1/shop/race-trial/{race}     这个种族本周 1/3/7 天各买过没有
    POST /v1/shop/race-trial            游戏币买一张种族体验卡（放进背包）
    GET  /v1/me/trials/expired          到期了、还没提醒过的体验
    POST /v1/me/trials/expired/ack      这些到期提醒弹过了

请求体只带意图（哪张卡、几张）。价格、余额、还剩几张都以服务器为准。
购买 / 使用 / 出售都带 client_op_id：断网重发用同一个，服务器原样回上次的结果。
"""

from __future__ import annotations

import datetime as dt
import logging
import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app import shop, trial
from app.jwt_verify import Claims
from app.routes.me import current_claims
from app.routes.shop import _check_rate, _me

log = logging.getLogger("glory.trial")

router = APIRouter(prefix="/v1", tags=["trial"])

_STATUS_BY_CODE = {
    "unknown_target": 404,
    "already_owned": 409,
    "no_card": 409,
    "weekly_limit": 409,
    "op_conflict": 409,
    "insufficient_funds": 402,
    "bad_days": 400,
    "bad_count": 400,
}


def _reject(exc: shop.ShopRejected) -> HTTPException:
    return HTTPException(status_code=_STATUS_BY_CODE.get(exc.code, 400), detail=exc.message,
                         headers={"X-Glory-Reason": exc.code})


def _iso(value: dt.datetime | None) -> str:
    return value.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z") if value else ""


class CardModel(BaseModel):
    target: str
    kind: str
    days: int
    count: int
    sell_price: int
    owned: bool


class TrialModel(BaseModel):
    target: str
    kind: str
    expires_at: str


class BagResponse(BaseModel):
    cards: list[CardModel]
    trials: list[TrialModel]
    server_now: str


class UseBody(BaseModel):
    client_op_id: uuid.UUID
    target: str
    days: int


class SellBody(UseBody):
    count: int = 1


class BuyBody(BaseModel):
    client_op_id: uuid.UUID
    race: str
    days: int


class OpResponse(BaseModel):
    target: str
    days: int
    count: int
    expires_at: str
    coin_delta: int
    diamond: int
    coin: int
    replayed: bool


class RaceOfferResponse(BaseModel):
    race: str
    prices: dict[str, int]
    bought: list[int]
    owned: bool
    resets_at: str
    trial_expires_at: str


class ExpiredResponse(BaseModel):
    items: list[TrialModel]


class AckBody(BaseModel):
    targets: list[str]


class AckResponse(BaseModel):
    acked: int


def _op(r: trial.OpResult) -> OpResponse:
    return OpResponse(target=r.target, days=r.days, count=r.count, expires_at=_iso(r.expires_at),
                      coin_delta=r.coin_delta, diamond=r.wallet.diamond, coin=r.wallet.coin,
                      replayed=r.replayed)


@router.get("/me/bag", response_model=BagResponse)
async def my_bag(claims: Annotated[Claims, Depends(current_claims)]) -> BagResponse:
    me = await _me(claims)
    b = await trial.bag(me.player_id)
    return BagResponse(
        cards=[CardModel(**vars(c)) for c in b.cards],
        trials=[TrialModel(target=t.target, kind=t.kind, expires_at=_iso(t.expires_at)) for t in b.trials],
        server_now=_iso(b.server_now))


@router.post("/me/bag/use", response_model=OpResponse)
async def use_card(body: UseBody, claims: Annotated[Claims, Depends(current_claims)]) -> OpResponse:
    me = await _me(claims)
    _check_rate(me.player_id)
    try:
        result = await trial.use(me.player_id, body.client_op_id, body.target, body.days)
    except shop.ShopRejected as exc:
        raise _reject(exc) from None
    if not result.replayed:
        log.info("使用体验卡 player=%s target=%s days=%d expires=%s",
                 me.player_id, result.target, result.days, _iso(result.expires_at))
    return _op(result)


@router.post("/me/bag/sell", response_model=OpResponse)
async def sell_card(body: SellBody, claims: Annotated[Claims, Depends(current_claims)]) -> OpResponse:
    me = await _me(claims)
    _check_rate(me.player_id)
    try:
        result = await trial.sell(me.player_id, body.client_op_id, body.target, body.days, body.count)
    except shop.ShopRejected as exc:
        raise _reject(exc) from None
    if not result.replayed:
        log.info("出售体验卡 player=%s target=%s days=%d coin=+%d",
                 me.player_id, result.target, result.days, result.coin_delta)
    return _op(result)


@router.get("/shop/race-trial/{race}", response_model=RaceOfferResponse)
async def race_offer(race: str, claims: Annotated[Claims, Depends(current_claims)]) -> RaceOfferResponse:
    me = await _me(claims)
    try:
        offer = await trial.race_offer(me.player_id, race)
    except shop.ShopRejected as exc:
        raise _reject(exc) from None
    return RaceOfferResponse(race=offer.race, prices={str(k): v for k, v in offer.prices.items()},
                             bought=offer.bought, owned=offer.owned,
                             resets_at=_iso(offer.resets_at),
                             trial_expires_at=_iso(offer.trial_expires_at))


@router.post("/shop/race-trial", response_model=OpResponse)
async def buy_race_trial(body: BuyBody, claims: Annotated[Claims, Depends(current_claims)]) -> OpResponse:
    me = await _me(claims)
    _check_rate(me.player_id)
    try:
        result = await trial.buy_race(me.player_id, body.client_op_id, body.race, body.days)
    except shop.ShopRejected as exc:
        raise _reject(exc) from None
    if not result.replayed:
        log.info("购买种族体验卡 player=%s race=%s days=%d coin=%d",
                 me.player_id, result.target, result.days, result.coin_delta)
    return _op(result)


@router.get("/me/trials/expired", response_model=ExpiredResponse)
async def expired(claims: Annotated[Claims, Depends(current_claims)]) -> ExpiredResponse:
    me = await _me(claims)
    items = await trial.expired_notices(me.player_id)
    return ExpiredResponse(items=[TrialModel(target=t.target, kind=t.kind, expires_at=_iso(t.expires_at))
                                  for t in items])


@router.post("/me/trials/expired/ack", response_model=AckResponse)
async def ack_expired(body: AckBody, claims: Annotated[Claims, Depends(current_claims)]) -> AckResponse:
    me = await _me(claims)
    return AckResponse(acked=await trial.ack_notices(me.player_id, body.targets))
