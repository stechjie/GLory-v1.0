"""Google Play 结算：账号服务器向 Google 核实付款凭证、消耗（docs/充值系统设计.md 第五节）。

用 Android Publisher API v3 的 purchases.products.get / consume。认证走服务账号：
用它的私钥签一张 JWT 去换访问令牌（RFC 7523）。不引 google-auth —— 只用得到这一个功能，
而 PyJWT + cryptography 已经在用了（jwt_verify.py、steam_oidc.py）。

## 怎么认定「这张凭证是这张单的」

客户端付款时把两个值塞进付款请求（BillingFlowParams）：

    obfuscatedAccountId = account_tag(玩家编号)   玩家编号的 sha256
    obfuscatedProfileId = 订单号

Google 把它们原样存在这笔付款上，我们查单时读回来比对。于是一张凭证拿到别的号上交、
或者交到同一个号的另一张单上，都对不上。

## 消耗

入账提交之后才消耗（consume 同时算确认）。🔴 Google 3 天内收不到确认就自动退款 ——
所以入了账却没消耗不能放着不管：消耗失败时客户端下次启动会再交这张凭证，
服务器看到已入账就只补消耗（第 2 步的定时任务也会补）。

⚠️ 付款凭证能拿去查这笔付款，算半个凭证：不进日志、不进报错。它出现在请求地址里，
所以 httpx 的请求日志（INFO 级会打完整地址）压到 WARNING，同 steam.py。
"""

from __future__ import annotations

import base64
import dataclasses
import hashlib
import json
import logging
import pathlib
import re
import time
import uuid

import httpx
import jwt

from app import iap
from app.config import get_settings

log = logging.getLogger("glory.iap.google")
logging.getLogger("httpx").setLevel(logging.WARNING)

API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"
_TIMEOUT = httpx.Timeout(10.0, connect=5.0)
# 实测的凭证由字母、数字、点、横线、下划线组成。挡住斜杠 —— 它要拼进请求地址。
_TOKEN_RE = re.compile(r"^[A-Za-z0-9._\-]{16,4096}$")

# purchaseState
PURCHASED, CANCELED, PENDING = 0, 1, 2


class GoogleRejected(RuntimeError):
    """凭证不对（伪造、过期、不是这个档位的）。玩家的事，回 400。message 可以外传。"""


class GoogleUnavailable(RuntimeError):
    """没配好服务账号、Google 拒了服务账号、连不上。我们的事，回 503。message 不含任何密钥。"""


def account_tag(player_id: uuid.UUID) -> str:
    """付款时填进 obfuscatedAccountId 的值。Google 要求它认不出人、最长 64 个字符。"""
    return hashlib.sha256(str(player_id).encode("utf-8")).hexdigest()


def token_key(token: str) -> str:
    """付款凭证的去重键（iap_orders.external_id）。凭证本身太长、长度也不定，存它的 sha256。"""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


@dataclasses.dataclass(frozen=True)
class Purchase:
    state: int          # PURCHASED / CANCELED / PENDING
    test: bool          # purchaseType == 0：许可测试员的测试单
    profile_id: str     # obfuscatedExternalProfileId —— 我们的订单号
    account_id: str     # obfuscatedExternalAccountId —— account_tag(玩家编号)
    consumed: bool


_sa_cache: tuple[float, dict] | None = None
_access: tuple[str, float] | None = None


def reset() -> None:
    """测试用：清掉缓存的服务账号、访问令牌和推送公钥。"""
    global _sa_cache, _access, _certs
    _sa_cache = None
    _access = None
    _certs = None


def _service_account() -> dict:
    global _sa_cache, _access
    path = get_settings().google_play_service_account_file.strip()
    if not path:
        raise GoogleUnavailable("服务器没配 Google Play 服务账号（GLORY_GOOGLE_PLAY_SERVICE_ACCOUNT_FILE）")
    file = pathlib.Path(path)
    try:
        mtime = file.stat().st_mtime
    except OSError:
        raise GoogleUnavailable("读不到 Google Play 服务账号的密钥文件") from None
    if _sa_cache is not None and _sa_cache[0] == mtime:
        return _sa_cache[1]
    try:
        data = json.loads(file.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise GoogleUnavailable("Google Play 服务账号的密钥文件不是 JSON") from None
    for field in ("client_email", "private_key", "token_uri"):
        if not data.get(field):
            raise GoogleUnavailable("Google Play 服务账号的密钥文件缺 %s" % field)
    _sa_cache = (mtime, data)
    _access = None  # 换了密钥文件，旧令牌作废
    return data


async def _access_token(client: httpx.AsyncClient) -> str:
    global _access
    now = time.time()
    if _access is not None and _access[1] - 60 > now:
        return _access[0]
    sa = _service_account()
    assertion = jwt.encode(
        {"iss": sa["client_email"], "scope": SCOPE, "aud": sa["token_uri"],
         "iat": int(now), "exp": int(now) + 3600},
        sa["private_key"], algorithm="RS256",
        headers={"kid": str(sa.get("private_key_id") or "")},
    )
    resp = await client.post(sa["token_uri"], data={
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion})
    if resp.status_code >= 400:
        raise GoogleUnavailable("Google 不给访问令牌（HTTP %d）：检查服务账号密钥" % resp.status_code)
    try:
        body = resp.json()
        token = str(body["access_token"])
        expires = now + int(body.get("expires_in", 3600))
    except (ValueError, KeyError, TypeError):
        raise GoogleUnavailable("Google 的访问令牌回得不对") from None
    _access = (token, expires)
    return token


def _url(product_id: str, token: str) -> str:
    return "%s/%s/purchases/products/%s/tokens/%s" % (
        API, get_settings().google_play_package, product_id, token)


async def get_purchase(product_id: str, token: str,
                       transport: httpx.AsyncBaseTransport | None = None) -> Purchase:
    global _access
    if not _TOKEN_RE.match(token):
        raise GoogleRejected("付款凭证格式不对")
    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT, transport=transport) as client:
            access = await _access_token(client)
            resp = await client.get(_url(product_id, token), headers={"Authorization": "Bearer " + access})
    except httpx.HTTPError as exc:
        raise GoogleUnavailable("连不上 Google（%s）" % type(exc).__name__) from None
    if resp.status_code in (401, 403):
        _access = None
        raise GoogleUnavailable(
            "Google 拒绝了服务账号（HTTP %d）：检查 Play Console「用户和权限」里给它的权限" % resp.status_code)
    if resp.status_code in (400, 404, 410):
        raise GoogleRejected("Google 不认这张付款凭证")
    if resp.status_code >= 400:
        raise GoogleUnavailable("Google 核实出错（HTTP %d）" % resp.status_code)
    try:
        body = resp.json()
        return Purchase(
            state=int(body.get("purchaseState", -1)),
            test=body.get("purchaseType") == 0,
            profile_id=str(body.get("obfuscatedExternalProfileId") or ""),
            account_id=str(body.get("obfuscatedExternalAccountId") or ""),
            consumed=int(body.get("consumptionState", 0)) == 1,
        )
    except (ValueError, TypeError, AttributeError):
        raise GoogleUnavailable("Google 回的付款信息看不懂") from None


async def consume(product_id: str, token: str,
                  transport: httpx.AsyncBaseTransport | None = None) -> bool:
    """消耗。**不抛异常** —— 入账已经提交了，消耗失败只是要补，不能让这次 confirm 变成失败。"""
    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT, transport=transport) as client:
            access = await _access_token(client)
            resp = await client.post(_url(product_id, token) + ":consume",
                                     headers={"Authorization": "Bearer " + access})
    except (httpx.HTTPError, GoogleUnavailable) as exc:
        log.warning("Google 消耗失败，之后补：%s", type(exc).__name__)
        return False
    if resp.status_code >= 400:
        log.warning("Google 消耗失败，之后补（HTTP %d）", resp.status_code)
        return False
    return True


async def confirm(order: iap.Order, token: str,
                  transport: httpx.AsyncBaseTransport | None = None) -> iap.Outcome:
    """核实 + 入账 + 消耗。客户端交凭证走这里；实时通知走 on_purchase_notice，最后是同一段 _settle。"""
    if order.platform != "google":
        raise iap.IapRejected("wrong_platform", "这张单不是 Google Play 的")
    return await _settle(order, token, await get_purchase(order.product_id, token, transport), transport)


async def _settle(order: iap.Order, token: str, purchase: Purchase,
                  transport: httpx.AsyncBaseTransport | None) -> iap.Outcome:
    if purchase.profile_id != str(order.order_id) or purchase.account_id != account_tag(order.player_id):
        log.warning("Google 凭证上的订单号 / 玩家对不上 order=%s", order.order_id)
        raise iap.IapRejected("proof_mismatch", "付款凭证和这张单对不上")
    if purchase.state == PENDING:
        # 便利店付现金这类：钱还没到。不入账，等玩家付完（实时通知会来）。
        return await iap.outcome_of(order.order_id)
    if purchase.state == CANCELED:
        return await iap.cancel(order.order_id, "google_canceled")
    if purchase.state != PURCHASED:
        raise GoogleUnavailable("Google 回了不认识的付款状态 %d" % purchase.state)

    outcome = await iap.credit(iap.Proof(
        platform="google", order_id=order.order_id, product_id=order.product_id,
        external_id=token_key(token), environment=iap.SANDBOX if purchase.test else iap.PRODUCTION,
        purchase_token=token,
    ))
    # 入了账（含重放）的要消耗；测试单超上限被取消的也消耗，免得客户端一直重交。
    # 别的取消不消耗：3 天后 Google 自己把钱退给玩家。
    settled = outcome.order
    should_consume = settled.status == "credited" or settled.note == "test_daily_limit"
    if should_consume and settled.consumed_at is None:
        if purchase.consumed or await consume(order.product_id, token, transport):
            await iap.mark_consumed(order.order_id)
    return outcome


# --- 实时通知（RTDN，Pub/Sub 推送到 /iap/google/rtdn）----------------------------------
#
# 玩家付完钱就关了游戏、客户端永远不来交凭证 —— 这一路替他入账。退款也从这里来。
# 推送地址是公开的，所以先验身份：Pub/Sub 在 Authorization 头里带一张 Google 签的身份令牌，
# 签发方是 Google、受众和服务账号邮箱都要是我们在推送订阅里配的那两个（.env）。

CERTS_URL = "https://www.googleapis.com/oauth2/v3/certs"
_ISSUERS = ("accounts.google.com", "https://accounts.google.com")
_CERTS_TTL = 3600.0
_MIN_REFETCH = 60.0
_certs: tuple[dict[str, jwt.PyJWK], float] | None = None


async def _push_key(kid: str, transport: httpx.AsyncBaseTransport | None) -> jwt.PyJWK:
    global _certs
    now = time.monotonic()
    age = now - _certs[1] if _certs is not None else float("inf")
    if _certs is None or age > _CERTS_TTL or (kid not in _certs[0] and age > _MIN_REFETCH):
        try:
            async with httpx.AsyncClient(timeout=_TIMEOUT, transport=transport) as client:
                resp = await client.get(CERTS_URL)
            keys = jwt.PyJWKSet.from_dict(resp.json()).keys
        except (httpx.HTTPError, ValueError, jwt.PyJWTError):
            raise GoogleUnavailable("拉不到 Google 的公钥") from None
        _certs = ({k.key_id: k for k in keys if k.key_id}, now)
    found = _certs[0].get(kid)
    if found is None:
        raise GoogleRejected("推送令牌的签名密钥不是 Google 的")
    return found


async def verify_push(authorization: str | None,
                      transport: httpx.AsyncBaseTransport | None = None) -> None:
    """不是我们配的那个推送订阅发来的就抛 GoogleRejected。"""
    s = get_settings()
    account, audience = s.google_rtdn_service_account.strip(), s.google_rtdn_audience.strip()
    if not account or not audience:
        raise GoogleUnavailable(
            "服务器没配 Google 实时通知的推送身份（GLORY_GOOGLE_RTDN_SERVICE_ACCOUNT / GLORY_GOOGLE_RTDN_AUDIENCE）")
    scheme, _, token = (authorization or "").partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise GoogleRejected("实时通知没带身份令牌")
    try:
        header = jwt.get_unverified_header(token.strip())
    except jwt.PyJWTError:
        raise GoogleRejected("实时通知的身份令牌格式不对") from None
    # 只认 RS256，同 jwt_verify.ALLOWED_ALGORITHMS 那段说的 algorithm confusion。
    if header.get("alg") != "RS256" or not header.get("kid"):
        raise GoogleRejected("实时通知的身份令牌算法不对")
    key = await _push_key(str(header["kid"]), transport)
    try:
        claims = jwt.decode(token.strip(), key=key.key, algorithms=["RS256"], audience=audience,
                            options={"require": ["exp", "iat", "iss", "aud", "email"]})
    except jwt.PyJWTError as exc:
        raise GoogleRejected("实时通知的身份令牌不对（%s）" % type(exc).__name__) from None
    if claims.get("iss") not in _ISSUERS:
        raise GoogleRejected("实时通知的身份令牌不是 Google 签的")
    if claims.get("email") != account or claims.get("email_verified") is not True:
        raise GoogleRejected("实时通知不是我们配的那个推送订阅发来的")


@dataclasses.dataclass(frozen=True)
class Notice:
    kind: str           # purchased / canceled / voided / test / ignored
    token: str = ""
    product_id: str = ""


def parse_rtdn(body: dict) -> Notice:
    """拆 Pub/Sub 推来的那一层和里面的 RTDN。看不懂的抛 ValueError（路由层确认收到并记日志，不让它一直重推）。"""
    data = json.loads(base64.b64decode(str(body["message"]["data"])))
    if data.get("packageName") != get_settings().google_play_package:
        return Notice("ignored")
    if "testNotification" in data:
        return Notice("test")
    one = data.get("oneTimeProductNotification")
    if one:
        kind = {1: "purchased", 2: "canceled"}.get(int(one.get("notificationType") or 0), "ignored")
        return Notice(kind, str(one.get("purchaseToken") or ""), str(one.get("sku") or ""))
    voided = data.get("voidedPurchaseNotification")
    if voided:
        # productType 1 是订阅，我们不卖；2 是一次性商品。
        if int(voided.get("productType") or 0) != 2:
            return Notice("ignored")
        return Notice("voided", str(voided.get("purchaseToken") or ""))
    return Notice("ignored")  # 订阅类通知


async def on_purchase_notice(product_id: str, token: str,
                             transport: httpx.AsyncBaseTransport | None = None) -> iap.Outcome | None:
    """「已购买」/「待付款被取消」通知。按付款上的混淆订单号找到我们的单再走 _settle。

    返回 None = 这笔付款不是从我们的建单接口来的（没有订单号、或者订单号查不到），只记日志。
    """
    purchase = await get_purchase(product_id, token, transport)
    try:
        order_id = uuid.UUID(purchase.profile_id)
    except ValueError:
        log.warning("Google 通知的付款上没有我们的订单号 product=%s", product_id)
        return None
    order = await iap.order_by_id(order_id)
    if order is None or order.platform != "google" or order.product_id != product_id:
        log.warning("Google 通知找不到对应的单 order=%s product=%s", order_id, product_id)
        return None
    return await _settle(order, token, purchase, transport)


@dataclasses.dataclass(frozen=True)
class Voided:
    token: str
    voided_ms: int


async def voided_since(start_ms: int, transport: httpx.AsyncBaseTransport | None = None) -> list[Voided]:
    """Voided Purchases API：start_ms 之后被作废（退款、拒付、撤销）的一次性购买。实时通知丢了靠它补。

    Google 只给最近 30 天，调用方自己别传更早的。翻页最多 20 页，防一个坏游标把循环卡死。
    """
    global _access
    out: list[Voided] = []
    page = ""
    url = "%s/%s/purchases/voidedpurchases" % (API, get_settings().google_play_package)
    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT, transport=transport) as client:
            for _ in range(20):
                params = {"startTime": str(start_ms), "type": "0", "maxResults": "1000"}
                if page:
                    params["token"] = page
                resp = await client.get(url, params=params,
                                        headers={"Authorization": "Bearer " + await _access_token(client)})
                if resp.status_code in (401, 403):
                    _access = None
                    raise GoogleUnavailable("Google 拒绝了服务账号（HTTP %d）" % resp.status_code)
                if resp.status_code >= 400:
                    raise GoogleUnavailable("查作废购买出错（HTTP %d）" % resp.status_code)
                body = resp.json()
                for row in body.get("voidedPurchases") or []:
                    if row.get("purchaseToken"):
                        out.append(Voided(str(row["purchaseToken"]), int(row.get("voidedTimeMillis") or 0)))
                page = str((body.get("tokenPagination") or {}).get("nextPageToken") or "")
                if not page:
                    break
    except httpx.HTTPError as exc:
        raise GoogleUnavailable("连不上 Google（%s）" % type(exc).__name__) from None
    except (ValueError, TypeError, AttributeError):
        raise GoogleUnavailable("Google 回的作废列表看不懂") from None
    return out
