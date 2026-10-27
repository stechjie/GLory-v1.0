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


async def user_currency(steam_id: str, sandbox: bool, transport: httpx.AsyncBaseTransport | None = None,
                        ipaddress: str | None = None) -> str:
    """玩家 Steam 钱包的币种（GetUserInfo）。浏览器确认那种单要带玩家的公网 IP（Steam 的要求）。"""
    query = {"steamid": steam_id}
    if ipaddress:
        query["ipaddress"] = ipaddress
    params = await _call("GET", "GetUserInfo/v2", query, sandbox, transport)
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
    outcome, _url = await _begin(player_id, client_order_id, product_id, steam_id, language, None,
                                 even_if_closed=False, transport=transport)
    return outcome


async def begin_in_browser(player_id: uuid.UUID, client_order_id: uuid.UUID, product_id: str, steam_id: str,
                           language: str, ipaddress: str, *, even_if_closed: bool = False,
                           transport: httpx.AsyncBaseTransport | None = None) -> tuple[iap.Outcome, str]:
    """同 begin，但让玩家在浏览器里确认（usersession=web）。返回 (单, 要打开的 Steam 网址)。

    两处用：deploy/check_iap_steam.py 不经过游戏走一遍沙盒；以后游戏里 overlay 弹不出来时的退路
    （docs/充值系统设计.md 第五节）。ipaddress 是玩家的公网 IP —— Steam 对这种单要求带上。
    重试拿回原单时网址是空串（Steam 只在下单那一次给）。
    """
    return await _begin(player_id, client_order_id, product_id, steam_id, language, ipaddress,
                        even_if_closed=even_if_closed, transport=transport)


async def _begin(player_id: uuid.UUID, client_order_id: uuid.UUID, product_id: str, steam_id: str,
                 language: str, web_ip: str | None, *, even_if_closed: bool,
                 transport: httpx.AsyncBaseTransport | None) -> tuple[iap.Outcome, str]:
    sandbox = steam_id in iap.steam_sandbox_ids()
    item = iap.product(product_id)
    currency, amount = pick_price(item, await user_currency(steam_id, sandbox, transport, web_ip))
    order, _created = await iap.create_order(
        player_id, client_order_id, "steam", product_id, steam_id=steam_id,
        environment=iap.SANDBOX if sandbox else iap.PRODUCTION,
        price_amount=amount, price_currency=currency, even_if_closed=even_if_closed)
    if order.status != "pending" or order.external_id is not None:
        return await iap.outcome_of(order.order_id), ""
    sandbox = order.environment == iap.SANDBOX  # 重试时以第一次建单时定的为准
    session = {"usersession": "web", "ipaddress": web_ip} if web_ip else {"usersession": "client"}
    try:
        params = await _call("POST", "InitTxn/v3", {
            "orderid": str(order.order_no), "steamid": order.steam_id or steam_id,
            "itemcount": "1", "language": language, "currency": order.price_currency or currency,
            **session,
            "itemid[0]": str(item.tier), "qty[0]": "1",
            "amount[0]": str(order.price_amount if order.price_amount is not None else amount),
            "description[0]": "%d Diamonds" % item.diamond, "category[0]": "Diamonds",
        }, sandbox, transport)
        transid = str(params.get("transid") or "")
        steamurl = str(params.get("steamurl") or "")
    except SteamTxnFailed as exc:
        # 可能是上一次其实下成功了、只是回执丢了，这次撞了同一个 orderid —— 问一下。
        try:
            transid, steamurl = (await query_txn(order.order_no, sandbox, transport)).transid, ""
        except SteamTxnFailed:
            await iap.cancel(order.order_id, "steam_init_failed:%d" % exc.code)
            log.warning("Steam 下单失败 order=%s code=%d %s", order.order_id, exc.code, exc)
            raise iap.IapRejected("steam_init_failed", "Steam 下单失败，请稍后再试") from None
    if not transid:
        raise steam.SteamUnavailable("Steam 下单没回 transid")
    await iap.mark_steam_txn(order.order_id, transid)
    log.info("Steam 下单 order=%s player=%s product=%s %s=%s sandbox=%s web=%s",
             order.order_id, player_id, product_id, order.price_currency, order.price_amount, sandbox, bool(web_ip))
    return await iap.outcome_of(order.order_id), steamurl


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


# --- 退款与拒付（GetReport）-------------------------------------------------------
#
# Steam 不推送，要我们自己问。文档要求至少每天一次；app/iap_sync.py 每 10 分钟一次。
# 只问正式接口：沙盒单没花钱，不会有退款。

# 这些状态 = 钱退回去了，入过账的要扣回。
REVERSED = frozenset({"Refunded", "Chargedback", "RefundedSuspectedFraud", "RefundedFriendlyFraud"})


@dataclasses.dataclass(frozen=True)
class ReportRow:
    order_no: int
    transid: str
    status: str
    time: str        # RFC 3339，这一行最后一次变化的时间；下一次从这里往后问


async def report(since: str, transport: httpx.AsyncBaseTransport | None = None) -> list[ReportRow]:
    """since（RFC 3339 UTC）之后有变化的单。每次最多 1000 行，调用方用最后一行的 time 接着问。"""
    params = await _call("GET", "GetReport/v5", {"type": "GAMESALES", "time": since, "maxresults": "1000"},
                         False, transport)
    rows = []
    for raw in params.get("orders") or []:
        try:
            rows.append(ReportRow(order_no=int(raw.get("orderid")), transid=str(raw.get("transid") or ""),
                                  status=str(raw.get("status") or ""), time=str(raw.get("time") or "")))
        except (TypeError, ValueError):
            log.warning("Steam 报表里有一行看不懂，跳过")
    return rows
