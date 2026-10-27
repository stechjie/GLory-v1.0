"""Steam 微交易（ISteamMicroTxn）：下单、核实、扣款（docs/充值系统设计.md 第五节）。

和 Google / Apple 反过来：**服务器先下单**（InitTxn），Steam 在游戏里弹 overlay 让玩家确认，
确认之后服务器调 FinalizeTxn —— **这一步才真正扣钱**。所以入账永远在 Finalize 成功之后。

## 客户端说的 authorized 只是提示

overlay 回调（MicroTxnAuthorizationResponse）里的 authorized 只当「现在来查一下」：
要不要扣钱、要不要入账，一律以 QueryTxn 问到的状态为准（settle）。
点了确认但游戏崩了、回调没送到的单，第 2 步的定时任务也走 settle。

## 测试员走沙盒

GLORY_STEAM_SANDBOX_STEAM_IDS 里的人下单走 ISteamMicroTxnSandbox（同样的请求、不扣钱），
订单记成测试单。走哪边在下单时就定了，存在订单的 environment 上，之后每一步都照它。

发行商密钥就是登录验票那把（steam.py 的 _key），请求日志的压制也在 steam.py 里。
"""

from __future__ import annotations

import dataclasses
import logging
import uuid

import httpx

from app import iap, steam
from app.config import get_settings

log = logging.getLogger("glory.iap.steam")

_TIMEOUT = httpx.Timeout(10.0, connect=5.0)


class SteamTxnFailed(RuntimeError):
    """Steam 回了 Failure（下单被拒、单不存在、超时没 Finalize 等）。code 是 Steam 的 errorcode。"""

    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclasses.dataclass(frozen=True)
class Txn:
    status: str      # Init / Approved / Succeeded / Failed / Refunded / Chargedback …
    transid: str
    steam_id: str


def _iface(sandbox: bool) -> str:
    return "ISteamMicroTxnSandbox" if sandbox else "ISteamMicroTxn"


async def _call(method: str, name: str, params: dict[str, str], sandbox: bool,
                transport: httpx.AsyncBaseTransport | None) -> dict:
    params = {"key": steam._key(), "appid": str(get_settings().steam_app_id), **params}
    url = "%s/%s/%s/" % (steam.PARTNER_API, _iface(sandbox), name)
    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT, transport=transport) as client:
            if method == "GET":
                resp = await client.get(url, params=params)
            else:
                resp = await client.post(url, data=params)
    except httpx.HTTPError as exc:
        raise steam.SteamUnavailable("连不上 Steam（%s）" % type(exc).__name__) from None
    if resp.status_code in (401, 403):
        raise steam.SteamUnavailable(
            "Steam 拒绝了服务器的密钥（HTTP %d），检查发行商密钥所在的组有没有微交易权限" % resp.status_code)
    if resp.status_code >= 400:
        raise steam.SteamUnavailable("Steam 出错（HTTP %d）" % resp.status_code)
    try:
        body = resp.json().get("response") or {}
    except (ValueError, AttributeError):
        raise steam.SteamUnavailable("Steam 回的不是 JSON") from None
    if body.get("result") != "OK":
        error = body.get("error") or {}
        raise SteamTxnFailed(int(error.get("errorcode") or 0), str(error.get("errordesc") or "")[:120])
    return body.get("params") or {}


async def user_currency(steam_id: str, sandbox: bool,
                        transport: httpx.AsyncBaseTransport | None = None) -> str:
    """玩家 Steam 钱包的币种（GetUserInfo）。"""
    params = await _call("GET", "GetUserInfo/v2", {"steamid": steam_id}, sandbox, transport)
    return str(params.get("currency") or "")


def pick_price(item: iap.Product, wallet_currency: str) -> tuple[str, int]:
    """(币种, 最小单位金额)。目录里有钱包的币种就用它，没有就 USD（Steam 按汇率换算），再没有就 MYR。"""
    for currency in (wallet_currency, "USD", "MYR"):
        if currency in item.steam_prices:
            return currency, item.steam_prices[currency]
    raise AssertionError("iap._load 保证每档都有 MYR 价")


async def query_txn(order_no: int, sandbox: bool,
                    transport: httpx.AsyncBaseTransport | None = None) -> Txn:
    params = await _call("GET", "QueryTxn/v3", {"orderid": str(order_no)}, sandbox, transport)
    return Txn(status=str(params.get("status") or ""), transid=str(params.get("transid") or ""),
               steam_id=str(params.get("steamid") or ""))


async def begin(player_id: uuid.UUID, client_order_id: uuid.UUID, product_id: str, steam_id: str,
                language: str, transport: httpx.AsyncBaseTransport | None = None) -> iap.Outcome:
    """建单 + 向 Steam 下单。成功后 Steam 会在游戏里弹 overlay。

    steam_id 必须是调用方**验过票**、并核对过绑在这个号上的那个（routes/iap.py 做）。
    弱网重试带同一个 client_order_id：已经下过 Steam 单的直接回原单，不再下第二次。
    """
    sandbox = steam_id in iap.steam_sandbox_ids()
    item = iap.product(product_id)
    currency, amount = pick_price(item, await user_currency(steam_id, sandbox, transport))
    order, _created = await iap.create_order(
        player_id, client_order_id, "steam", product_id, steam_id=steam_id,
        environment=iap.SANDBOX if sandbox else iap.PRODUCTION,
        price_amount=amount, price_currency=currency)
    if order.status != "pending" or order.external_id is not None:
        return await iap.outcome_of(order.order_id)
    sandbox = order.environment == iap.SANDBOX  # 重试时以第一次建单时定的为准
    try:
        params = await _call("POST", "InitTxn/v3", {
            "orderid": str(order.order_no), "steamid": order.steam_id or steam_id,
            "itemcount": "1", "language": language, "currency": order.price_currency or currency,
            "usersession": "client",
            "itemid[0]": str(item.tier), "qty[0]": "1",
            "amount[0]": str(order.price_amount if order.price_amount is not None else amount),
            "description[0]": "%d Diamonds" % item.diamond, "category[0]": "Diamonds",
        }, sandbox, transport)
        transid = str(params.get("transid") or "")
    except SteamTxnFailed as exc:
        # 可能是上一次其实下成功了、只是回执丢了，这次撞了同一个 orderid —— 问一下。
        try:
            transid = (await query_txn(order.order_no, sandbox, transport)).transid
        except SteamTxnFailed:
            await iap.cancel(order.order_id, "steam_init_failed:%d" % exc.code)
            log.warning("Steam 下单失败 order=%s code=%d %s", order.order_id, exc.code, exc)
            raise iap.IapRejected("steam_init_failed", "Steam 下单失败，请稍后再试") from None
    if not transid:
        raise steam.SteamUnavailable("Steam 下单没回 transid")
    await iap.mark_steam_txn(order.order_id, transid)
    log.info("Steam 下单 order=%s player=%s product=%s %s=%s sandbox=%s",
             order.order_id, player_id, product_id, order.price_currency, order.price_amount, sandbox)
    return await iap.outcome_of(order.order_id)


async def settle(order: iap.Order, declined: bool = False,
                 transport: httpx.AsyncBaseTransport | None = None) -> iap.Outcome:
    """按 Steam 那边的状态把这张单往前推：该扣款就扣款、该入账就入账、该取消就取消。

    declined = 客户端说玩家在 overlay 里点了取消。只有 Steam 那边还停在 Init 时才据此取消；
    Steam 说已经批准了，就照样扣款入账 —— 以 Steam 为准，不以客户端为准。
    """
    if order.platform != "steam":
        raise iap.IapRejected("wrong_platform", "这张单不是 Steam 的")
    if order.status != "pending":
        return await iap.outcome_of(order.order_id)
    sandbox = order.environment == iap.SANDBOX
    txn = await query_txn(order.order_no, sandbox, transport)
    if txn.steam_id and txn.steam_id != order.steam_id:
        log.warning("Steam 单上的 Steam 账号对不上 order=%s", order.order_id)
        raise iap.IapRejected("proof_mismatch", "付款凭证和这张单对不上")
    status = txn.status
    if status == "Approved":
        try:
            await _call("POST", "FinalizeTxn/v2", {"orderid": str(order.order_no)}, sandbox, transport)
            status = "Succeeded"
        except SteamTxnFailed:
            # 可能被定时任务抢先 Finalize 了。再问一次，以 Steam 为准。
            txn = await query_txn(order.order_no, sandbox, transport)
            status = txn.status
    if status == "Succeeded":
        transid = txn.transid or order.external_id
        if not transid:
            raise steam.SteamUnavailable("Steam 说扣款成功了，但没回 transid")
        return await iap.credit(iap.Proof(
            platform="steam", order_id=order.order_id, product_id=order.product_id,
            external_id=transid, environment=order.environment or iap.PRODUCTION,
            price_amount=order.price_amount, price_currency=order.price_currency,
        ))
    if status == "Init":
        if declined:
            return await iap.cancel(order.order_id, "steam_declined")
        return await iap.outcome_of(order.order_id)
    # Failed，或者还没入账就被退了 / 拒付了：这张单从没给过钻石，取消即可。
    return await iap.cancel(order.order_id, ("steam_" + status.lower())[:200])
