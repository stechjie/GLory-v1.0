"""充值接口（docs/充值系统设计.md 第四节）。

    GET  /v1/iap/catalog?platform=     档位、每档还有没有首充、当前余额与欠账
    POST /v1/iap/orders                建单（Steam 同时向 Steam 下单）
    POST /v1/iap/google/confirm        交 Google 的付款凭证
    POST /v1/iap/apple/confirm         交 StoreKit 2 的签名交易
    POST /v1/iap/steam/confirm         overlay 回调之后来查
    GET  /v1/iap/orders/{order_id}     查单（「处理中」时轮询）

平台推过来的（不在 /v1 下，同 /oidc/steam，避开客户端版本检查；不收玩家令牌，各自验平台的签名）：

    POST /iap/google/rtdn              Google 实时通知（Pub/Sub 推送）
    POST /iap/apple/notifications      Apple 服务器通知 V2

## 客户端看到的三种结果

    status = credited    已到账（diamond 是新余额）
    status = cancelled   已取消（只有平台明确说没付款才这么回）
    status = pending     处理中，钻石会自动到账

🔴 503（平台连不上、服务器没配好）也要显示成「处理中」，**不能显示失败**：钱多半已经扣了，
只是这一趟没核实完。客户端下次启动会再交一次（商店刷新超时那次的教训：超时 ≠ 失败）。
"""

from __future__ import annotations

import logging
import uuid
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field

from app import db, iap, iap_apple, iap_google, iap_steam, players, steam
from app.config import get_settings
from app.jwt_verify import Claims
from app.rate_limit import RateLimited, SlidingWindowLimiter
from app.routes.me import current_claims
from app.supabase_auth import STEAM_PROVIDER, AuthError, SupabaseAuth

log = logging.getLogger("glory.iap")

router = APIRouter(prefix="/v1/iap", tags=["iap"])

# 每人每分钟。只防脚本刷：建单一分钟 10 张绰绰有余；confirm 会被「处理中」轮询和启动补交带起来，给宽一点。
_order_limiter = SlidingWindowLimiter(10, 60.0)
_confirm_limiter = SlidingWindowLimiter(30, 60.0)

# 业务拒绝 -> HTTP 状态码。集中一张表，同 routes/shop.py。
_STATUS_BY_CODE = {
    "unknown_platform": 400,
    "wrong_platform": 400,
    "unknown_product": 404,
    "unknown_order": 404,
    "order_conflict": 409,
    "proof_mismatch": 409,
    "proof_reused": 409,
    "steam_not_linked": 403,
    "iap_closed": 503,
    "steam_init_failed": 502,
}


class CatalogProduct(BaseModel):
    id: str
    diamond: int        # 基础量
    bonus: int          # 平时加送
    first_bonus: bool   # 这一档还有首充双倍（有的话这次给 diamond × 2，不给 bonus）
    # 只有 platform=steam 才有：Steam 不给游戏查价格，客户端拿它显示。币种 -> 最小单位。
    steam_prices: dict[str, int] = {}


class CatalogResponse(BaseModel):
    open: bool          # 这个平台现在收不收新单；false 时客户端显示「暂未开放」
    products: list[CatalogProduct]
    diamond: int        # 当前余额，欠账时是负数
    coin: int
    debt: int           # 欠账


class CreateOrderBody(BaseModel):
    client_order_id: uuid.UUID
    platform: Literal["google", "apple", "steam"]
    product_id: str = Field(min_length=1, max_length=64)
    # 只有 Steam 要：GetAuthTicketForWebApi 拿的新票（十六进制），服务器验票才知道付款的是哪个 Steam 账号。
    steam_ticket: str | None = Field(default=None, max_length=8192)
    # Steam overlay 的语言（ISO 639-1）。
    language: str = Field(default="en", pattern=r"^[a-z]{2}$")


class OrderOut(BaseModel):
    order_id: uuid.UUID
    platform: str
    product_id: str
    status: str             # pending / credited / cancelled / refunded
    first_bonus: bool
    credited: int           # 这张单给了多少钻（付费 + 赠送）；没入账是 0
    note: str
    diamond: int            # 当前余额（客户端直接拿它刷新），欠账时是负数
    coin: int
    replayed: bool
    # 付款时要塞进平台请求的值：Google 的 obfuscatedAccountId（obfuscatedProfileId 填 order_id）、
    # Apple 的 appAccountToken（就是 order_id）。
    obfuscated_account_id: str = ""
    app_account_token: str = ""


class GoogleConfirmBody(BaseModel):
    order_id: uuid.UUID
    purchase_token: str = Field(min_length=16, max_length=4096)


class AppleConfirmBody(BaseModel):
    order_id: uuid.UUID
    signed_transaction: str = Field(min_length=32, max_length=16384)


class SteamConfirmBody(BaseModel):
    order_id: uuid.UUID
    # overlay 回调里的 authorized。只是提示：扣不扣、入不入以 Steam 那边的状态为准。
    authorized: bool


# --- 组装 ---------------------------------------------------------------------


async def _me(claims: Claims) -> players.Player:
    if not db.is_connected():
        raise HTTPException(status_code=503, detail="数据库未配置：backend/.env 里的 GLORY_DATABASE_URL 是空的")
    player = await players.get_by_auth_uid(claims.auth_uid)
    if player is None:
        raise HTTPException(status_code=404, detail="该身份没有对应的玩家，请重新登录")
    return player


def _http(status: int, code: str, detail: str) -> HTTPException:
    return HTTPException(status_code=status, detail=detail, headers={"X-Glory-Reason": code})


def _limit(limiter: SlidingWindowLimiter, player_id: uuid.UUID) -> None:
    try:
        limiter.check(str(player_id))
    except RateLimited as exc:
        raise HTTPException(status_code=429, detail="操作太快了，%d 秒后再试" % exc.retry_after,
                            headers={"Retry-After": str(exc.retry_after)}) from None


async def _run(call):
    """跑一次和平台打交道的操作，把各家的异常统一翻成 HTTP。

    玩家的事（凭证不对、票不对）400；我们的事（没配好、连不上）503 —— 客户端据此决定是报错还是「处理中」。
    """
    try:
        return await call
    except iap.IapRejected as exc:
        raise _http(_STATUS_BY_CODE.get(exc.code, 400), exc.code, exc.message) from None
    except (iap_google.GoogleRejected, iap_apple.AppleRejected, steam.SteamRejected) as exc:
        raise _http(400, "proof_rejected", str(exc)) from None
    except (iap_google.GoogleUnavailable, iap_apple.AppleUnavailable, steam.SteamUnavailable) as exc:
        log.warning("充值核实暂时做不了：%s", exc)
        raise _http(503, "platform_unavailable", str(exc)) from None
    except iap_steam.SteamTxnFailed as exc:
        log.warning("Steam 微交易失败 code=%d %s", exc.code, exc)
        raise _http(502, "steam_failed", "Steam 处理失败（%d），请稍后再试" % exc.code) from None


def _out(outcome: iap.Outcome) -> OrderOut:
    order = outcome.order
    return OrderOut(
        order_id=order.order_id, platform=order.platform, product_id=order.product_id,
        status=order.status, first_bonus=order.first_bonus,
        credited=order.diamond_paid + order.diamond_free if order.status == "credited" else 0,
        note=order.note or "", diamond=outcome.wallet.diamond, coin=outcome.wallet.coin,
        replayed=outcome.replayed,
        obfuscated_account_id=iap_google.account_tag(order.player_id) if order.platform == "google" else "",
        app_account_token=str(order.order_id) if order.platform == "apple" else "",
    )


async def _own_order(player_id: uuid.UUID, order_id: uuid.UUID) -> iap.Order:
    return (await _run(iap.read_order(player_id, order_id))).order


async def _verified_steam_id(ticket: str | None, authorization: str) -> str:
    """验票拿到 Steam 编号，并核对它绑在当前这个号上（防止用 A 的 Steam 钱包给 B 充）。"""
    if not ticket:
        raise _http(400, "steam_ticket_missing", "Steam 下单要带 Steam 票")
    user = await _run(steam.authenticate_ticket(ticket))
    s = get_settings()
    try:
        _anonymous, linked = await SupabaseAuth(s.supabase_url, s.supabase_publishable_key).linked_identities(
            authorization.partition(" ")[2].strip())
    except AuthError as exc:
        raise _http(503, "platform_unavailable", "查不到这个号绑的登录方式：%s" % exc) from None
    # Steam 身份在 Supabase 上的邮箱是 steam.placeholder_email 那个占位，里面就是 Steam 编号。
    if not any(i.provider == STEAM_PROVIDER and i.email == steam.placeholder_email(user.steam_id) for i in linked):
        log.warning("Steam 下单的 Steam 账号没绑在这个号上")
        raise _http(403, "steam_not_linked", "这个 Steam 账号没有绑定当前游戏账号")
    return user.steam_id


# --- 接口 ---------------------------------------------------------------------


@router.get("/catalog", response_model=CatalogResponse)
async def catalog(
    claims: Annotated[Claims, Depends(current_claims)],
    platform: Annotated[Literal["google", "apple", "steam"], Query()],
) -> CatalogResponse:
    me = await _me(claims)
    shelf = await _run(iap.shelf(me.player_id, platform))
    return CatalogResponse(
        open=shelf.open,
        products=[CatalogProduct(id=item.id, diamond=item.diamond, bonus=item.bonus, first_bonus=first,
                                 steam_prices=dict(item.steam_prices) if platform == "steam" else {})
                  for item, first in shelf.products],
        diamond=shelf.wallet.diamond, coin=shelf.wallet.coin, debt=shelf.wallet.diamond_debt,
    )


@router.post("/orders", response_model=OrderOut)
async def create_order(
    body: CreateOrderBody,
    claims: Annotated[Claims, Depends(current_claims)],
    authorization: Annotated[str, Header()],
) -> OrderOut:
    """建单。请求体里没有价格、没有钻石数 —— 都从服务器目录取（同商城的 /v1/shop/orders）。"""
    me = await _me(claims)
    _limit(_order_limiter, me.player_id)
    if body.platform == "steam":
        if not iap.platform_open("steam"):
            # 先挡开关再验票：关着的时候不该为一个注定被拒的请求去连 Steam 和 Supabase。
            raise _http(503, "iap_closed", "充值暂未开放")
        steam_id = await _verified_steam_id(body.steam_ticket, authorization)
        outcome = await _run(iap_steam.begin(me.player_id, body.client_order_id, body.product_id,
                                             steam_id, body.language))
        return _out(outcome)
    order, created = await _run(iap.create_order(me.player_id, body.client_order_id,
                                                 body.platform, body.product_id))
    if created:
        log.info("充值建单 order=%s player=%s platform=%s product=%s",
                 order.order_id, me.player_id, order.platform, order.product_id)
    return _out(await _run(iap.outcome_of(order.order_id)))


@router.post("/google/confirm", response_model=OrderOut)
async def google_confirm(
    body: GoogleConfirmBody,
    claims: Annotated[Claims, Depends(current_claims)],
) -> OrderOut:
    me = await _me(claims)
    _limit(_confirm_limiter, me.player_id)
    order = await _own_order(me.player_id, body.order_id)
    return _out(await _run(iap_google.confirm(order, body.purchase_token)))


@router.post("/apple/confirm", response_model=OrderOut)
async def apple_confirm(
    body: AppleConfirmBody,
    claims: Annotated[Claims, Depends(current_claims)],
) -> OrderOut:
    me = await _me(claims)
    _limit(_confirm_limiter, me.player_id)
    order = await _own_order(me.player_id, body.order_id)
    return _out(await _run(iap_apple.confirm(order, body.signed_transaction)))


@router.post("/steam/confirm", response_model=OrderOut)
async def steam_confirm(
    body: SteamConfirmBody,
    claims: Annotated[Claims, Depends(current_claims)],
) -> OrderOut:
    me = await _me(claims)
    _limit(_confirm_limiter, me.player_id)
    order = await _own_order(me.player_id, body.order_id)
    return _out(await _run(iap_steam.settle(order, declined=not body.authorized)))


@router.get("/orders/{order_id}", response_model=OrderOut)
async def read_order(
    order_id: uuid.UUID,
    claims: Annotated[Claims, Depends(current_claims)],
) -> OrderOut:
    """只读数据库，不连平台 —— 「处理中」时客户端会每隔几秒问一次。"""
    me = await _me(claims)
    return _out(await _run(iap.read_order(me.player_id, order_id)))


# --- 平台推过来的通知 ----------------------------------------------------------------
#
# 回什么状态码决定平台会不会重推，所以分三种：
#   · 不是平台发来的（验不过签名 / 身份）         401 / 400
#   · 我们这边暂时做不了（没配好、连不上、库出错） 503 / 500 —— 让它重推，配好后自动补上
#   · 看不懂、不是我们的单、已经处理过            2xx —— 重推也没用，确认收到、记日志
#
# 地址是公开的、不要登录，限一个总量挡住刷接口（验签名要算几次 ECDSA / RSA）。

notify_router = APIRouter(prefix="/iap", tags=["iap"])
_notify_limiter = SlidingWindowLimiter(300, 60.0)


def _notify_limit(platform: str) -> None:
    try:
        _notify_limiter.check(platform)
    except RateLimited as exc:
        raise HTTPException(status_code=429, detail="太多了", headers={"Retry-After": str(exc.retry_after)}) from None


@notify_router.post("/google/rtdn", status_code=204)
async def google_rtdn(request: Request, authorization: Annotated[str | None, Header()] = None) -> Response:
    """Google 实时通知。Pub/Sub 收到 2xx 才算送达，别的会退避重推（订阅默认留 7 天）。"""
    _notify_limit("google")
    try:
        await iap_google.verify_push(authorization)
    except iap_google.GoogleRejected as exc:
        log.warning("Google 实时通知身份不对：%s", exc)
        raise HTTPException(status_code=401, detail="不是 Google 推来的") from None
    except iap_google.GoogleUnavailable as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from None
    try:
        notice = iap_google.parse_rtdn(await request.json())
    except (ValueError, KeyError, TypeError, AttributeError):
        log.warning("Google 实时通知看不懂，确认收到后丢掉")
        return Response(status_code=204)

    outcome = None
    try:
        if notice.kind in ("purchased", "canceled") and notice.token:
            outcome = await iap_google.on_purchase_notice(notice.product_id, notice.token)
            if outcome is not None and (outcome.order.status != "credited" or outcome.replayed):
                outcome = None  # 只有这一次真的入了账才发到账邮件
        elif notice.kind == "voided" and notice.token:
            outcome = await iap.refund("google", iap_google.token_key(notice.token), "google_voided")
            if outcome is not None and outcome.replayed:
                outcome = None
        elif notice.kind == "test":
            log.info("收到 Google 实时通知的测试消息：推送通道是通的")
    except (iap_google.GoogleRejected, iap.IapRejected) as exc:
        log.warning("Google 实时通知处理不了，确认收到后丢掉：%s", exc)
        return Response(status_code=204)
    except iap_google.GoogleUnavailable as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from None
    if outcome is not None:
        await iap.mail_notice(outcome)
    return Response(status_code=204)


class AppleNotificationBody(BaseModel):
    signedPayload: str = Field(min_length=32, max_length=65536)  # noqa: N815 - Apple 定的字段名


@notify_router.post("/apple/notifications")
async def apple_notifications(body: AppleNotificationBody) -> Response:
    """Apple 服务器通知 V2。Apple 收到 200 才算送达，别的会隔一段时间重试几次。"""
    _notify_limit("apple")
    try:
        _what, outcome = await iap_apple.on_notification(body.signedPayload)
    except iap_apple.AppleRejected as exc:
        log.warning("Apple 服务器通知验不过：%s", exc)
        raise HTTPException(status_code=400, detail="不是 Apple 签的") from None
    except iap_apple.AppleUnavailable as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from None
    if outcome is not None and not outcome.replayed:
        await iap.mail_notice(outcome)
    return Response(status_code=200)
