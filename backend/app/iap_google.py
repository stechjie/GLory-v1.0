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
    """测试用：清掉缓存的服务账号与访问令牌。"""
    global _sa_cache, _access
    _sa_cache = None
    _access = None


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
    """核实 + 入账 + 消耗。客户端 confirm 和（第 2 步的）实时通知都走这里。"""
    if order.platform != "google":
        raise iap.IapRejected("wrong_platform", "这张单不是 Google Play 的")
    purchase = await get_purchase(order.product_id, token, transport)
    if purchase.profile_id != str(order.order_id) or purchase.account_id != account_tag(order.player_id):
        log.warning("Google 凭证上的订单号 / 玩家对不上 order=%s", order.order_id)
        raise iap.IapRejected("proof_mismatch", "付款凭证和这张单对不上")
    if purchase.state == PENDING:
        # 便利店付现金这类：钱还没到。不入账，等玩家付完（第 2 步的实时通知会来）。
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
