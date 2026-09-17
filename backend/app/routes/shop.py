"""商城接口（docs/商城系统设计.md 第七节）。

    GET  /v1/shop                商品目录
    GET  /v1/me/wallet           余额
    GET  /v1/me/entitlements     拥有的内容 id
    POST /v1/shop/orders         买一件
    GET  /v1/me/pets             拥有的宠物 / 出战的那只 / 要不要弹三选一
    PUT  /v1/me/pets/active      设出战宠物
    POST /v1/me/pets/starter     新手三选一

出战名片（POST /v1/battle/card）在 routes/loadout.py，系统邮件在 routes/mail.py。

## 中英文两份都发，客户端自己选

同公告那条（routes/announcements.py 的 title_zh / title_en）。服务端按
Accept-Language 挑的话，同一份目录要按语言各缓存一份，而且玩家在设置里切语言
还得重新拉一次 —— 客户端本来就有 LocaleManager，让它挑更省事。

## 余额只发一个数

`shop.Wallet.diamond` 把付费与赠送合并。分账是退款与对账的口径，客户端没有
用到它的场景，下发了只是多一个泄露面（见 database/009_wallet.sql 的注释）。
"""

from __future__ import annotations

import logging
import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app import db, players, shop
from app.jwt_verify import Claims
from app.rate_limit import RateLimited, SlidingWindowLimiter
from app.routes.me import current_claims

log = logging.getLogger("glory.shop")

router = APIRouter(prefix="/v1", tags=["shop"])

# 每人每分钟最多下多少单。**只防脚本刷**，不负责总量 ——
# 总量由余额在结构上封顶。按 player_id 计，不按 IP（运营商 NAT 下同一出口 IP
# 是成片的正常玩家，同 routes/chat.py 的同名限流）。
#
# 弱网重试会带同一个 client_order_id、被重放，也照样占额度 —— 这是有意的：
# 额度防的是「请求量」，而重放请求一样要查库。30 对正常玩家绰绰有余。
ORDER_PER_MINUTE = 30
_order_limiter = SlidingWindowLimiter(ORDER_PER_MINUTE, 60.0)

# 业务拒绝 -> HTTP 状态码。集中一张表，理由同 routes/chat.py 的同名表：
# 这些 code 会出现在客户端的错误处理里，散在各处迟早会出现同一个 code 两种状态。
_STATUS_BY_CODE = {
    "unknown_item": 404,
    "unknown_pet": 404,
    "already_owned": 409,
    "order_conflict": 409,
    "starter_already_picked": 409,
    "not_owned": 403,
    "not_a_starter": 400,
    # 402 Payment Required 就是为这件事定义的，而且客户端能一眼把它和
    # 「参数不对」(400)、「你没资格」(403) 分开 —— 余额不足要弹的是充值入口，
    # 另外两个要弹的是错误提示。
    "insufficient_funds": 402,
}


class ItemModel(BaseModel):
    id: str
    kind: str
    grants: str
    currency: str
    price: int
    name: str
    name_en: str


class ShopResponse(BaseModel):
    """列表包一层对象，不返回顶层数组 —— 客户端 _request 只接受 Dictionary，
    顶层数组会静默变成空（同 test_friends 钉着的那条）。"""

    items: list[ItemModel]


class WalletResponse(BaseModel):
    diamond: int
    coin: int


class EntitlementsResponse(BaseModel):
    items: list[str]


class PetsResponse(BaseModel):
    owned: list[str]
    active: str
    needs_starter_pick: bool


class OrderBody(BaseModel):
    client_order_id: uuid.UUID
    item_id: str


class StarterBody(BaseModel):
    client_order_id: uuid.UUID
    pet_id: str


class ActivePetBody(BaseModel):
    pet_id: str


class ReceiptModel(BaseModel):
    order_id: uuid.UUID
    item_id: str
    granted: str
    currency: str
    price: int
    # 扣完之后的余额。客户端直接拿它刷新 UI，不用再拉一次 /v1/me/wallet。
    diamond: int
    coin: int
    # 这次是重放还是真的执行了。客户端可以据此决定要不要放发货动画 ——
    # 重放时玩家早就看过一次了。
    replayed: bool


class OrderResponse(BaseModel):
    receipt: ReceiptModel


# --- 组装 ---------------------------------------------------------------------


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


def _reject(exc: shop.ShopRejected) -> HTTPException:
    return HTTPException(
        status_code=_STATUS_BY_CODE.get(exc.code, 400),
        detail=exc.message,
        headers={"X-Glory-Reason": exc.code},
    )


def _receipt(r: shop.Receipt) -> ReceiptModel:
    return ReceiptModel(
        order_id=r.order_id,
        item_id=r.item_id,
        granted=r.granted,
        currency=r.currency,
        price=r.price,
        diamond=r.wallet.diamond,
        coin=r.wallet.coin,
        replayed=r.replayed,
    )


def _check_rate(player_id: uuid.UUID) -> None:
    try:
        _order_limiter.check(str(player_id))
    except RateLimited as exc:
        raise HTTPException(
            status_code=429,
            detail="操作太快了，%d 秒后再试" % exc.retry_after,
            headers={"Retry-After": str(exc.retry_after)},
        ) from None


# --- 接口 ---------------------------------------------------------------------


@router.get("/shop", response_model=ShopResponse)
async def catalog() -> ShopResponse:
    """目录。**不需要登录** —— 它对所有人都一样，而且不含任何玩家数据。

    「我有没有买过」由客户端拿 /v1/me/entitlements 自己比对，不在这里合并：
    合并了这个响应就变成按人不同，没法缓存。
    """
    return ShopResponse(items=[ItemModel(**vars(i)) for i in shop.items()])


@router.get("/me/wallet", response_model=WalletResponse)
async def wallet(claims: Annotated[Claims, Depends(current_claims)]) -> WalletResponse:
    me = await _me(claims)
    w = await shop.read_wallet(me.player_id)
    return WalletResponse(diamond=w.diamond, coin=w.coin)


@router.get("/me/entitlements", response_model=EntitlementsResponse)
async def entitlements(
    claims: Annotated[Claims, Depends(current_claims)],
) -> EntitlementsResponse:
    me = await _me(claims)
    return EntitlementsResponse(items=await shop.read_entitlements(me.player_id))


@router.post("/shop/orders", response_model=OrderResponse)
async def place_order(
    body: OrderBody,
    claims: Annotated[Claims, Depends(current_claims)],
) -> OrderResponse:
    """买一件商品。

    ⚠️ 请求体里**没有价格**，也没有「我有多少钱」。客户端只发意图，
    价格从服务端目录取、余额从服务端钱包取 —— 同 docs/P1经济账本RFC.md 第六节。
    """
    me = await _me(claims)
    _check_rate(me.player_id)
    try:
        receipt = await shop.purchase(me.player_id, body.client_order_id, body.item_id)
    except shop.ShopRejected as exc:
        raise _reject(exc) from None
    if not receipt.replayed:
        # 真正扣了钱的那次才记。重放记的话，弱网下一笔购买会在日志里出现很多行，
        # 对账时看着像买了很多次。
        log.info(
            "购买成功 player=%s item=%s %s=%d order=%s",
            me.player_id, receipt.item_id, receipt.currency, receipt.price, receipt.order_id,
        )
    return OrderResponse(receipt=_receipt(receipt))


@router.get("/me/pets", response_model=PetsResponse)
async def my_pets(claims: Annotated[Claims, Depends(current_claims)]) -> PetsResponse:
    me = await _me(claims)
    pets = await shop.read_pets(me.player_id)
    return PetsResponse(
        owned=pets.owned, active=pets.active, needs_starter_pick=pets.needs_starter_pick)


@router.put("/me/pets/active", response_model=PetsResponse)
async def set_active_pet(
    body: ActivePetBody,
    claims: Annotated[Claims, Depends(current_claims)],
) -> PetsResponse:
    me = await _me(claims)
    try:
        pets = await shop.set_active_pet(me.player_id, body.pet_id)
    except shop.ShopRejected as exc:
        raise _reject(exc) from None
    return PetsResponse(
        owned=pets.owned, active=pets.active, needs_starter_pick=pets.needs_starter_pick)


@router.post("/me/pets/starter", response_model=OrderResponse)
async def pick_starter(
    body: StarterBody,
    claims: Annotated[Claims, Depends(current_claims)],
) -> OrderResponse:
    """新手三选一。走和购买完全一样的发货路径，只是价格是 0。"""
    me = await _me(claims)
    _check_rate(me.player_id)
    try:
        receipt = await shop.pick_starter(me.player_id, body.client_order_id, body.pet_id)
    except shop.ShopRejected as exc:
        raise _reject(exc) from None
    return OrderResponse(receipt=_receipt(receipt))
