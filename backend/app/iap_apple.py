"""App Store：验 StoreKit 2 的签名交易（docs/充值系统设计.md 第五节）。

服务器端先做，客户端等 Mac 同事。客户端付款成功后拿到一段 JWS（Transaction.jwsRepresentation），
原样交给 /v1/iap/apple/confirm；服务器回已入账之后客户端才 finish()。

## 不连 Apple，只验这段 JWS

JWS 自带证书链（header 的 x5c：叶子、中间证书、根）。验三件事：

  1. 证书链：叶子 ← 中间证书 ← **我们钉住的** Apple Root CA - G3（GLORY_APPLE_ROOT_CERT_FILE），
     x5c 里自带的那张根不认；叶子、中间证书还要带 Apple 给 App Store 签名专用的两个扩展 OID
     （和 Apple 官方库 app-store-server-library 查的一样）。少了这条，任何人拿一套自签证书都能签出「付过款」；
  2. 签名：用叶子证书的公钥验 ES256；
  3. 内容：bundle id 是我们的、类型是消耗型、没被撤销、appAccountToken 等于订单号。

证书有效期按交易自己的 signedDate 判，不按现在：退款这类事可能几个月后才来，那时证书也许过期了，
但签的那一刻是有效的。（官方库关掉在线检查时也是这么判的。）

不引官方库：它带一整套同步的 requests 客户端，这里只用得到验签这一小段，
而这一段 cryptography + PyJWT 已经够了（两个都在用）。
"""

from __future__ import annotations

import base64
import dataclasses
import datetime as dt
import logging
import pathlib

import jwt
from cryptography import x509
from cryptography.exceptions import InvalidSignature

from app import iap
from app.config import get_settings

log = logging.getLogger("glory.iap.apple")

# Apple 给 App Store 签名证书加的扩展（官方库 SignedDataVerifier 查的同两个）。
LEAF_OID = x509.ObjectIdentifier("1.2.840.113635.100.6.11.1")
INTERMEDIATE_OID = x509.ObjectIdentifier("1.2.840.113635.100.6.2.1")

ENVIRONMENTS = {"Production": iap.PRODUCTION, "Sandbox": iap.SANDBOX}
# 订单上记价格只认两位小数的币种：Apple 给的是千分之一单位，换成「分」要知道小数位，
# 不认识的币种宁可不记（只是参考，结算以 Apple 报表为准）。
_TWO_DECIMAL = frozenset({"MYR", "USD", "SGD", "EUR", "GBP", "AUD"})


class AppleRejected(RuntimeError):
    """签名交易不对（伪造、不是我们的 App、不是消耗型、被撤销）。回 400。"""


class AppleUnavailable(RuntimeError):
    """服务器没配根证书。回 503。"""


@dataclasses.dataclass(frozen=True)
class Transaction:
    transaction_id: str
    bundle_id: str
    product_id: str
    type: str
    app_account_token: str
    environment: str        # Apple 原文：Production / Sandbox / Xcode …
    revoked: bool
    price: int | None       # Apple 的千分之一单位
    currency: str | None


_root_cache: tuple[float, x509.Certificate] | None = None


def _pinned_root() -> x509.Certificate:
    global _root_cache
    path = get_settings().apple_root_cert_file.strip()
    if not path:
        raise AppleUnavailable("服务器没配 Apple 根证书（GLORY_APPLE_ROOT_CERT_FILE）")
    file = pathlib.Path(path)
    try:
        mtime = file.stat().st_mtime
    except OSError:
        raise AppleUnavailable("读不到 Apple 根证书文件") from None
    if _root_cache is not None and _root_cache[0] == mtime:
        return _root_cache[1]
    raw = file.read_bytes()
    try:
        cert = (x509.load_pem_x509_certificate(raw) if raw.lstrip().startswith(b"-----BEGIN")
                else x509.load_der_x509_certificate(raw))
    except ValueError:
        raise AppleUnavailable("Apple 根证书文件读不出证书") from None
    _root_cache = (mtime, cert)
    return cert


def reset() -> None:
    """测试用：换根证书文件后清缓存。"""
    global _root_cache
    _root_cache = None


def _has(cert: x509.Certificate, oid: x509.ObjectIdentifier) -> bool:
    try:
        cert.extensions.get_extension_for_oid(oid)
        return True
    except x509.ExtensionNotFound:
        return False


def _verified(jws: str) -> dict:
    """验证书链和签名，返回 payload。签名交易和服务器通知是同一种 JWS，都走这里。"""
    root = _pinned_root()
    try:
        header = jwt.get_unverified_header(jws)
        chain = [x509.load_der_x509_certificate(base64.b64decode(c)) for c in header.get("x5c") or []]
        unverified = jwt.decode(jws, options={"verify_signature": False})
    except (jwt.PyJWTError, ValueError, TypeError):
        raise AppleRejected("签名交易格式不对") from None
    if header.get("alg") != "ES256" or len(chain) < 2:
        raise AppleRejected("签名交易格式不对")
    leaf, intermediate = chain[0], chain[1]

    signed_ms = unverified.get("signedDate")
    when = (dt.datetime.fromtimestamp(int(signed_ms) / 1000, tz=dt.timezone.utc)
            if isinstance(signed_ms, (int, float)) else dt.datetime.now(dt.timezone.utc))
    for cert in (leaf, intermediate):
        if not (cert.not_valid_before_utc <= when <= cert.not_valid_after_utc):
            raise AppleRejected("签名交易的证书不在有效期内")
    try:
        leaf.verify_directly_issued_by(intermediate)
        intermediate.verify_directly_issued_by(root)
    except (InvalidSignature, ValueError, TypeError):
        raise AppleRejected("签名交易的证书链不是 Apple 签的") from None
    if not _has(leaf, LEAF_OID) or not _has(intermediate, INTERMEDIATE_OID):
        raise AppleRejected("签名交易的证书不是 App Store 的")

    try:
        return jwt.decode(jws, key=leaf.public_key(), algorithms=["ES256"],
                          options={"verify_aud": False, "verify_iss": False})
    except jwt.PyJWTError:
        raise AppleRejected("签名交易的签名不对") from None


def verify(jws: str) -> Transaction:
    """验签名交易。通过了才返回；任何一步不对都抛 AppleRejected。"""
    payload = _verified(jws)
    bundle = str(payload.get("bundleId") or "")
    if bundle != get_settings().apple_bundle_id:
        raise AppleRejected("签名交易不是这个 App 的")
    price = payload.get("price")
    return Transaction(
        transaction_id=str(payload.get("transactionId") or ""),
        bundle_id=bundle,
        product_id=str(payload.get("productId") or ""),
        type=str(payload.get("type") or ""),
        app_account_token=str(payload.get("appAccountToken") or "").lower(),
        environment=str(payload.get("environment") or ""),
        revoked=payload.get("revocationDate") is not None,
        price=int(price) if isinstance(price, int) else None,
        currency=str(payload["currency"]) if payload.get("currency") else None,
    )


async def confirm(order: iap.Order, jws: str) -> iap.Outcome:
    """验签 + 入账。验签是纯计算（不连网），所以放在事务前做就满足「核实在事务外」。"""
    if order.platform != "apple":
        raise iap.IapRejected("wrong_platform", "这张单不是 App Store 的")
    tx = verify(jws)
    if tx.app_account_token != str(order.order_id) or tx.product_id != order.product_id:
        log.warning("Apple 交易上的订单号 / 档位对不上 order=%s", order.order_id)
        raise iap.IapRejected("proof_mismatch", "付款凭证和这张单对不上")
    if tx.type != "Consumable":
        raise AppleRejected("这笔交易不是消耗型商品")
    if not tx.transaction_id:
        raise AppleRejected("签名交易缺 transactionId")
    environment = ENVIRONMENTS.get(tx.environment)
    if environment is None:
        # Xcode 本地测试的交易不是 Apple 签的，走不到这里；真走到了也不收。
        raise AppleRejected("不收这个环境的交易：%s" % tx.environment)
    if tx.revoked:
        # 已经退了款的交易。从没入过账就取消；入过账的退款走 iap.refund（第 2 步的服务器通知）。
        return await iap.cancel(order.order_id, "apple_revoked")
    two_decimal = tx.price is not None and tx.currency in _TWO_DECIMAL
    return await iap.credit(iap.Proof(
        platform="apple", order_id=order.order_id, product_id=order.product_id,
        external_id=tx.transaction_id, environment=environment,
        price_amount=tx.price // 10 if two_decimal else None,
        price_currency=tx.currency if two_decimal else None,
    ))


# --- 服务器通知 V2（App Store Connect 里填的 /iap/apple/notifications）-------------------
#
# Apple POST 过来 {"signedPayload": <JWS>}。外层和里面的 signedTransactionInfo 都是 Apple 签的 JWS，
# 两层都走 _verified（同一套证书链检查）。第一期只自动处理 REFUND；
# REFUND_REVERSED（退款又撤销了）只记日志、交运营后台；CONSUMPTION_REQUEST（问用掉多少）不回。

@dataclasses.dataclass(frozen=True)
class Notification:
    type: str
    subtype: str
    uuid: str
    transaction: Transaction | None


def verify_notification(signed_payload: str) -> Notification:
    payload = _verified(signed_payload)
    data = payload.get("data") or {}
    if str(data.get("bundleId") or "") != get_settings().apple_bundle_id:
        raise AppleRejected("服务器通知不是这个 App 的")
    signed_tx = data.get("signedTransactionInfo")
    return Notification(
        type=str(payload.get("notificationType") or ""),
        subtype=str(payload.get("subtype") or ""),
        uuid=str(payload.get("notificationUUID") or ""),
        transaction=verify(str(signed_tx)) if signed_tx else None,
    )


async def on_notification(signed_payload: str) -> tuple[str, iap.Outcome | None]:
    """处理一条服务器通知。返回 (做了什么, 退款后的单)。验不过抛 AppleRejected。"""
    notice = verify_notification(signed_payload)
    tx = notice.transaction
    if notice.type == "REFUND" and tx is not None:
        outcome = await iap.refund("apple", tx.transaction_id, "apple_refund")
        return "refund", outcome
    if notice.type == "REFUND_REVERSED" and tx is not None:
        # 退款被撤销了（钱又回到我们这）。自动补回钻石容易和欠账、首充搅在一起，第一期交人看。
        log.warning("Apple 退款被撤销，需要人工处理 transaction=%s notification=%s", tx.transaction_id, notice.uuid)
        return "refund_reversed", None
    return "ignored", None
