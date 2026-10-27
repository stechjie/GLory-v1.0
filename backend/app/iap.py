"""充值：真钱买钻石（docs/充值系统设计.md）。

配套 `database/040_iap.sql`、`data/iap_products.json`。向三家平台核实单据的部分在
`iap_google.py` / `iap_apple.py` / `iap_steam.py`；这里只管和平台无关的那一半：
目录、建单、入账、取消、退款。

## 入账只有一个入口：credit()

客户端 confirm、平台通知、定时对账、运营后台「重新核实」都走它。它只收一份**已经向平台核实过**的
`Proof` —— 付没付钱由平台说了算，这里从不信客户端说的任何一个数。

## 🔴 核实在事务外，入账在事务里

核实要连 Google / Apple / Steam，慢的时候好几秒。账号服务器出过「握着数据库连接等网络」
把整台服务器拖卡的事（好友在线推送那次）。所以调用方先核实、拿到 Proof，再进 credit()；
credit() 里只有数据库语句。

## 钻石怎么算

    正式单：付费列 + 基础量；赠送列 + 平时加送。每档第一次买，加送换成再给一份基础量（双倍）。
    测试单：照同样的规则算，**全部进赠送列**、不占首充资格、每个号 24 小时最多入账 1 张。

首充资格按账号算、全平台共用；入账时插 iap_first_bonus，插进去了才算双倍 ——
和钱包行锁在同一个事务里，两笔同档的单同时到也只有一笔拿得到。退款不恢复资格。

## 退款

扣回这一单当初给的全部钻石（订单上的快照，不按目录重算）：先扣付费列，再扣赠送列，
还不够的记欠账（shop.Wallet.diamond_debt）。抽到的宠物不收回。
"""

from __future__ import annotations

import dataclasses
import datetime as dt
import json
import logging
import os
import pathlib
import re
import uuid

from app import db, shop
from app.config import get_settings

log = logging.getLogger("glory.iap")

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
_CATALOG_PATH = pathlib.Path(
    os.environ.get("GLORY_IAP_CATALOG", _REPO_ROOT / "data" / "iap_products.json"))

PLATFORMS = ("google", "apple", "steam")
PRODUCTION = "production"
SANDBOX = "sandbox"

_PRODUCT_ID_RE = re.compile(r"^[a-z0-9_]{1,64}$")
_CURRENCY_RE = re.compile(r"^[A-Z]{3}$")


class IapRejected(RuntimeError):
    """业务拒绝。code 由路由层映射成 HTTP 状态码，message 可以直接给玩家看。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


# --- 目录 ---------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Product:
    id: str            # diamond_pack_N，也是 Google / App Store 后台的商品编号
    tier: int          # Steam 下单的 itemid
    diamond: int       # 基础量，进付费列
    bonus: int         # 平时加送，进赠送列
    enabled: bool
    steam_prices: dict[str, int]   # 币种 -> 最小货币单位


_catalog_cache: tuple[float, dict[str, Product]] | None = None


def _load(path: pathlib.Path) -> dict[str, Product]:
    """读目录并校验。写错一律整份加载失败、接口 500、日志写清楚是哪一行 ——
    同 shop._catalog 的态度：充值目录写错的后果是钱对不上，不能「跳过那一行」了事。"""
    data = json.loads(path.read_text(encoding="utf-8"))
    out: dict[str, Product] = {}
    tiers: set[int] = set()
    for raw in data.get("products", []):
        product = Product(
            id=str(raw["id"]),
            tier=int(raw["tier"]),
            diamond=int(raw["diamond"]),
            bonus=int(raw.get("bonus", 0)),
            enabled=bool(raw.get("enabled", True)),
            steam_prices={str(k): int(v) for k, v in (raw.get("steam_prices") or {}).items()},
        )
        if not _PRODUCT_ID_RE.match(product.id):
            raise ValueError("iap_products.json 的商品编号不合法：%r" % product.id)
        if product.id in out:
            raise ValueError("iap_products.json 有重复的商品编号：%s" % product.id)
        if product.tier <= 0 or product.tier in tiers:
            raise ValueError("iap_products.json 的 %s 的 tier 必须是正数且不重复" % product.id)
        if product.diamond <= 0 or product.bonus < 0:
            raise ValueError("iap_products.json 的 %s 钻石数不对" % product.id)
        if "MYR" not in product.steam_prices:
            raise ValueError("iap_products.json 的 %s 缺 Steam 的 MYR 价" % product.id)
        for currency, amount in product.steam_prices.items():
            if not _CURRENCY_RE.match(currency) or amount <= 0:
                raise ValueError("iap_products.json 的 %s 的 Steam 价不对：%s=%s" % (product.id, currency, amount))
        tiers.add(product.tier)
        out[product.id] = product
    return out


def catalog() -> dict[str, Product]:
    """{商品编号: Product}，含已下架的（入账要按它算）。命中缓存时不读文件（先比 mtime）。"""
    global _catalog_cache
    try:
        mtime = _CATALOG_PATH.stat().st_mtime
    except OSError as exc:
        raise RuntimeError(
            "读不到充值目录 %s —— 检查 deploy/update.sh 的「复制后端要读的数据文件」那一段" % _CATALOG_PATH
        ) from exc
    if _catalog_cache is not None and _catalog_cache[0] == mtime:
        return _catalog_cache[1]
    parsed = _load(_CATALOG_PATH)
    _catalog_cache = (mtime, parsed)
    return parsed


def product(product_id: str) -> Product:
    found = catalog().get(product_id)
    if found is None:
        raise IapRejected("unknown_product", "没有这个充值档位")
    return found


def amounts(item: Product, first: bool) -> tuple[int, int]:
    """(付费列, 赠送列)。首充 = 再给一份基础量，**代替**平时加送，不叠加。"""
    return item.diamond, (item.diamond if first else item.bonus)


def platform_open(platform: str) -> bool:
    """这个平台现在收不收新单（.env 的开关）。

    🔴 只用来挡「建新单」。confirm、平台通知、定时对账一律不看它 ——
    关掉开关时已经付了钱的单必须照样能入账。
    """
    s = get_settings()
    return {"google": s.iap_google_enabled, "apple": s.iap_apple_enabled,
            "steam": s.iap_steam_enabled}.get(platform, False)


def test_orders_per_day() -> int:
    """测试单每个号 24 小时最多入账几张（.env，默认 1；docs/充值系统设计.md 第八节）。

    TestFlight 上的人买东西不花钱，又连着正式服 —— 不设上限就能无限白拿钻石。只在自己测流程时调大。
    """
    return max(0, int(get_settings().iap_test_orders_per_day))


def steam_sandbox_ids() -> frozenset[str]:
    """走 Steam 沙盒的测试员 Steam 编号（.env 里逗号分隔）。"""
    raw = get_settings().steam_sandbox_steam_ids
    return frozenset(part.strip() for part in raw.split(",") if part.strip())


# --- 订单 ---------------------------------------------------------------------

_ORDER_COLUMNS = (
    "order_id, order_no, player_id, client_order_id, platform, product_id, status, environment,"
    " external_id, purchase_token, steam_id, diamond_paid, diamond_free, first_bonus,"
    " price_amount, price_currency, note, created_at, credited_at, consumed_at, refunded_at")

# 入账、取消前锁订单的那一条。拿出来做常量，启动自检（app/schema_check.py）原样 prepare 它。
LOCK_ORDER = "select " + _ORDER_COLUMNS + " from iap_orders where order_id = $1 for update"


@dataclasses.dataclass(frozen=True)
class Order:
    order_id: uuid.UUID
    order_no: int
    player_id: uuid.UUID
    client_order_id: uuid.UUID
    platform: str
    product_id: str
    status: str
    environment: str | None
    external_id: str | None
    purchase_token: str | None
    steam_id: str | None
    diamond_paid: int
    diamond_free: int
    first_bonus: bool
    price_amount: int | None
    price_currency: str | None
    note: str | None
    created_at: dt.datetime
    credited_at: dt.datetime | None
    consumed_at: dt.datetime | None
    refunded_at: dt.datetime | None


def _order_of(row) -> Order:
    return Order(**{field.name: row[field.name] for field in dataclasses.fields(Order)})


@dataclasses.dataclass(frozen=True)
class Proof:
    """平台核实过的「这张单付了钱」。**只由 iap_google / iap_apple / iap_steam 生成**，
    路由层绝不能拿客户端给的字段直接拼一个出来。"""

    platform: str
    order_id: uuid.UUID
    product_id: str
    external_id: str
    environment: str
    purchase_token: str | None = None
    price_amount: int | None = None
    price_currency: str | None = None


@dataclasses.dataclass(frozen=True)
class Outcome:
    """一次 confirm / 入账 / 取消之后这张单的样子，加上**当前**余额（客户端直接拿它刷新）。"""

    order: Order
    wallet: shop.Wallet
    replayed: bool = False


async def create_order(
    player_id: uuid.UUID,
    client_order_id: uuid.UUID,
    platform: str,
    product_id: str,
    *,
    steam_id: str | None = None,
    environment: str | None = None,
    price_amount: int | None = None,
    price_currency: str | None = None,
    even_if_closed: bool = False,
) -> tuple[Order, bool]:
    """建一张待付款的单。返回 (单, 是不是这次新建的)。

    同一个 client_order_id 再来一次拿回同一张单（弱网重试）；换了平台或档位 = 客户端有 bug
    或者有人在试探，拒绝。Steam 的 steam_id / 环境 / 价格在这里就定了，另外两家要等核实。

    even_if_closed 只给服务器上跑的运营脚本用（deploy/check_iap_steam.py：开关还关着时先走一遍沙盒）。
    🔴 路由层绝不传它 —— 开关是给玩家关门的。
    """
    if platform not in PLATFORMS:
        raise IapRejected("unknown_platform", "不认识这个平台")
    if not even_if_closed and not platform_open(platform):
        raise IapRejected("iap_closed", "充值暂未开放")
    item = product(product_id)
    if not item.enabled:
        raise IapRejected("unknown_product", "这个充值档位目前没有上架")

    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(
            "insert into iap_orders (order_id, player_id, client_order_id, platform, product_id,"
            " steam_id, environment, price_amount, price_currency)"
            " values ($1, $2, $3, $4, $5, $6, $7, $8, $9)"
            " on conflict (player_id, client_order_id) do nothing"
            " returning " + _ORDER_COLUMNS,
            uuid.uuid4(), player_id, client_order_id, platform, product_id,
            steam_id, environment, price_amount, price_currency,
        )
        if row is not None:
            return _order_of(row), True
        row = await conn.fetchrow(
            "select " + _ORDER_COLUMNS + " from iap_orders where player_id = $1 and client_order_id = $2",
            player_id, client_order_id,
        )
    existing = _order_of(row)
    if (existing.platform, existing.product_id) != (platform, product_id):
        log.warning("充值单幂等键冲突 player=%s client_order=%s 原=%s/%s 这次=%s/%s",
                    player_id, client_order_id, existing.platform, existing.product_id, platform, product_id)
        raise IapRejected("order_conflict", "这个订单号已经用于另一个档位了")
    return existing, False


async def read_order(player_id: uuid.UUID, order_id: uuid.UUID) -> Outcome:
    """查自己的单。别人的单和不存在一样回 unknown_order —— 不透露那个编号存在。"""
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(
            "select " + _ORDER_COLUMNS + " from iap_orders where order_id = $1 and player_id = $2",
            order_id, player_id)
        if row is None:
            raise IapRejected("unknown_order", "没有这张充值单")
        wallet = await shop.read_wallet_in(conn, player_id)
    return Outcome(_order_of(row), wallet)


async def order_by_id(order_id: uuid.UUID) -> Order | None:
    """不限本人（平台通知、定时对账用）。"""
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(
            "select " + _ORDER_COLUMNS + " from iap_orders where order_id = $1", order_id)
    return None if row is None else _order_of(row)


async def outcome_of(order_id: uuid.UUID) -> Outcome:
    """这张单现在的样子 + 当前余额，什么都不改（「还在待付款」「已经处理过」时回给客户端）。"""
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(
            "select " + _ORDER_COLUMNS + " from iap_orders where order_id = $1", order_id)
        if row is None:
            raise IapRejected("unknown_order", "没有这张充值单")
        order = _order_of(row)
        wallet = await shop.read_wallet_in(conn, order.player_id)
    return Outcome(order, wallet, replayed=True)


async def mark_steam_txn(order_id: uuid.UUID, transid: str) -> None:
    """Steam 下单成功后记下 transid。只在还没有去重键时写 —— 入过账的单不许被改。"""
    async with db.pool().acquire() as conn:
        await conn.execute(
            "update iap_orders set external_id = $2 where order_id = $1 and external_id is null",
            order_id, transid)


async def mark_consumed(order_id: uuid.UUID) -> None:
    """Google 消耗成功。只记时间，不影响入账（入账在消耗之前就已经提交了）。"""
    async with db.pool().acquire() as conn:
        await conn.execute(
            "update iap_orders set consumed_at = now() where order_id = $1 and consumed_at is null",
            order_id)


async def cancel(order_id: uuid.UUID, note: str) -> Outcome:
    """把一张**还在待付款**的单置成已取消。已入账 / 已退款的单不动，原样回。"""
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            row = await conn.fetchrow(LOCK_ORDER, order_id)
            if row is None:
                raise IapRejected("unknown_order", "没有这张充值单")
            order = _order_of(row)
            changed = order.status == "pending"
            if changed:
                row = await conn.fetchrow(
                    "update iap_orders set status = 'cancelled', note = $2 where order_id = $1"
                    " returning " + _ORDER_COLUMNS, order_id, note[:200])
                order = _order_of(row)
                log.info("充值单取消 order=%s platform=%s note=%s", order_id, order.platform, note)
            wallet = await shop.read_wallet_in(conn, order.player_id)
    return Outcome(order, wallet, replayed=not changed)


async def credit(proof: Proof) -> Outcome:
    """入账。**唯一的入账路径**，见模块开头。调用方必须已经向平台核实过（Proof）。

    ## 🔴 语句顺序不能变

        1. 锁订单。已入账 / 已退款 / 已取消 → 原样回（重放），一分钱不动
        2. 这张凭证有没有被别的单用过 → 用过就拒
        3. 锁钱包 → 定首充（正式单插 iap_first_bonus）→ 测试单数上限
        4. shop._apply 入账（有欠账先还欠账）→ 订单置 credited

    第 1 步必须最先：「入账成功但回执丢了」的重试、Google 重复推的通知，都只能拿回原来那次的结果。
    已取消的单**不复活**：Google 那边付了钱也不入账、不消耗，3 天后它自动把钱退给玩家。
    """
    if proof.environment not in (PRODUCTION, SANDBOX):
        raise ValueError("Proof.environment 只能是 production / sandbox：%r" % proof.environment)
    item = product(proof.product_id)

    async with db.pool().acquire() as conn:
        async with conn.transaction():
            row = await conn.fetchrow(LOCK_ORDER, proof.order_id)
            if row is None:
                raise IapRejected("unknown_order", "没有这张充值单")
            order = _order_of(row)
            # Steam 单的环境和 transid 在下单时就定了（另外两家此时是空），凭证必须和它们一致。
            if ((order.platform, order.product_id) != (proof.platform, proof.product_id)
                    or order.environment not in (None, proof.environment)
                    or order.external_id not in (None, proof.external_id)):
                log.warning("充值凭证和订单对不上 order=%s 单=%s/%s/%s 凭证=%s/%s/%s", order.order_id,
                            order.platform, order.product_id, order.environment,
                            proof.platform, proof.product_id, proof.environment)
                raise IapRejected("proof_mismatch", "付款凭证和这张单对不上")
            if order.status != "pending":
                return Outcome(order, await shop.read_wallet_in(conn, order.player_id), replayed=True)

            taken = await conn.fetchval(
                "select order_id from iap_orders where platform = $1 and external_id = $2 and order_id <> $3",
                proof.platform, proof.external_id, proof.order_id)
            if taken is not None:
                log.warning("付款凭证已经用在另一张单上 order=%s 另一张=%s", proof.order_id, taken)
                raise IapRejected("proof_reused", "这笔付款已经入过账了")

            wallet = await shop._lock_wallet(conn, order.player_id)
            if proof.environment == SANDBOX:
                recent = await conn.fetchval(
                    "select count(*) from iap_orders where player_id = $1 and environment = 'sandbox'"
                    " and status in ('credited', 'refunded') and credited_at > now() - interval '24 hours'",
                    order.player_id)
                if int(recent or 0) >= test_orders_per_day():
                    row = await conn.fetchrow(
                        "update iap_orders set status = 'cancelled', environment = $2, external_id = $3,"
                        " purchase_token = $4, note = 'test_daily_limit' where order_id = $1"
                        " returning " + _ORDER_COLUMNS,
                        order.order_id, SANDBOX, proof.external_id, proof.purchase_token)
                    log.info("测试单超过每日上限，不入账 order=%s player=%s", order.order_id, order.player_id)
                    return Outcome(_order_of(row), wallet)
                # 测试单不占首充资格：只看，不插。TestFlight 上的人以后在 App Store 版真买时双倍还在。
                first = await conn.fetchval(
                    "select 1 from iap_first_bonus where player_id = $1 and product_id = $2",
                    order.player_id, item.id) is None
                paid, free = amounts(item, first)
                changes, source = {"diamond_free": paid + free}, "iap_test"
                credited_paid, credited_free = 0, paid + free
            else:
                first = await conn.fetchval(
                    "insert into iap_first_bonus (player_id, product_id, order_id) values ($1, $2, $3)"
                    " on conflict do nothing returning 1",
                    order.player_id, item.id, order.order_id) is not None
                paid, free = amounts(item, first)
                changes = {"diamond_paid": paid, "diamond_free": free}
                source = "iap"
                credited_paid, credited_free = paid, free

            after = await shop._apply(conn, order.player_id, wallet,
                                      {col: n for col, n in changes.items() if n}, source, order.order_id)
            row = await conn.fetchrow(
                "update iap_orders set status = 'credited', environment = $2, external_id = $3,"
                " purchase_token = coalesce($4, purchase_token), diamond_paid = $5, diamond_free = $6,"
                " first_bonus = $7, price_amount = coalesce($8, price_amount),"
                " price_currency = coalesce($9, price_currency), credited_at = now()"
                " where order_id = $1 returning " + _ORDER_COLUMNS,
                order.order_id, proof.environment, proof.external_id, proof.purchase_token,
                credited_paid, credited_free, first, proof.price_amount, proof.price_currency)

    order = _order_of(row)
    log.info("充值入账 order=%s player=%s platform=%s product=%s env=%s paid=%d free=%d first=%s",
             order.order_id, order.player_id, order.platform, order.product_id, order.environment,
             order.diamond_paid, order.diamond_free, order.first_bonus)
    return Outcome(order, after)


async def refund(platform: str, external_id: str, note: str) -> Outcome | None:
    """平台说这笔退款了 / 拒付了。返回 None = 没有这张单（交给运营后台看日志）。

    只处理已入账的单；已退款的原样回（通知会重复推）。待付款 / 已取消的单从来没给过钻石，不动。
    """
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            row = await conn.fetchrow(
                "select " + _ORDER_COLUMNS + " from iap_orders where platform = $1 and external_id = $2 for update",
                platform, external_id)
            if row is None:
                log.warning("收到退款但找不到订单 platform=%s note=%s", platform, note)
                return None
            order = _order_of(row)
            if order.status != "credited":
                return Outcome(order, await shop.read_wallet_in(conn, order.player_id), replayed=True)

            wallet = await shop._lock_wallet(conn, order.player_id)
            total = order.diamond_paid + order.diamond_free
            from_paid = min(wallet.diamond_paid, total)
            from_free = min(wallet.diamond_free, total - from_paid)
            debt = total - from_paid - from_free
            changes = {"diamond_paid": -from_paid, "diamond_free": -from_free, "diamond_debt": debt}
            after = await shop._apply(conn, order.player_id, wallet,
                                      {col: n for col, n in changes.items() if n},
                                      "refund", order.order_id, note=note[:200])
            row = await conn.fetchrow(
                "update iap_orders set status = 'refunded', refunded_at = now(), note = $2"
                " where order_id = $1 returning " + _ORDER_COLUMNS, order.order_id, note[:200])

    order = _order_of(row)
    log.warning("充值退款扣回 order=%s player=%s platform=%s 扣付费=%d 扣赠送=%d 记欠账=%d note=%s",
                order.order_id, order.player_id, platform, from_paid, from_free, debt, note)
    return Outcome(order, after)


# --- 定时对账要的查询（app/iap_sync.py）----------------------------------------


async def pending_orders(platform: str, max_age_sec: int) -> list[Order]:
    """这个平台还在待付款、而且是最近 max_age_sec 秒内建的单（最老的在前，一轮最多 200 张）。"""
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(
            "select " + _ORDER_COLUMNS + " from iap_orders where platform = $1 and status = 'pending'"
            " and created_at > now() - make_interval(secs => $2) order by created_at limit 200",
            platform, max_age_sec)
    return [_order_of(r) for r in rows]


async def unconsumed_google_orders(max_age_sec: int) -> list[Order]:
    """入了账（或测试单超上限被取消）、还没消耗的 Google 单。

    🔴 Google 3 天内收不到确认就自动退款，所以只看最近 max_age_sec 秒的 —— 再老的补了也没用。
    """
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(
            "select " + _ORDER_COLUMNS + " from iap_orders where platform = 'google'"
            " and consumed_at is null and purchase_token is not null"
            " and (status = 'credited' or note = 'test_daily_limit')"
            " and created_at > now() - make_interval(secs => $1) order by created_at limit 200",
            max_age_sec)
    return [_order_of(r) for r in rows]


# --- 后台入账 / 退款之后的通知邮件 ------------------------------------------------
#
# 平台通知、定时对账替玩家入了账（或扣回了退款）时，玩家多半不在游戏里，回来只看到钻石变了。
# 发一封**不带附件**的系统邮件说清楚是哪来的（docs/充值系统设计.md 第六、七节）。
#
# 🔴 绝不能用邮件附件补钻石：附件领取进的是赠送列（mail.py），付费口径就脏了。
# 钱在 credit() / refund() 里已经入了，邮件只是告诉他。


async def mail_notice(outcome: Outcome) -> None:
    """按这张单现在的状态发一封说明邮件。只认 credited / refunded，别的状态不发。

    **不抛异常**：钱已经动完了，邮件发不出去只是少一句话，不能让调用方把这笔当成失败去重试。
    """
    order = outcome.order
    total = order.diamond_paid + order.diamond_free
    ref = "#%d" % order.order_no
    if order.status == "credited":
        title = ("充值到账", "Top-up received")
        body_zh = "你购买的钻石已到账：%d 钻%s。订单 %s。" % (
            total, "（含首充赠送）" if order.first_bonus else "", ref)
        body_en = "%d diamonds have been added to your account%s. Order %s." % (
            total, " (first top-up bonus included)" if order.first_bonus else "", ref)
    elif order.status == "refunded":
        title = ("充值已退款", "Top-up refunded")
        debt = outcome.wallet.diamond_debt
        body_zh = "订单 %s 已退款，这笔充值给的 %d 钻已扣回。" % (ref, total)
        body_en = "Order %s was refunded, and the %d diamonds it gave have been taken back." % (ref, total)
        if debt:
            body_zh += "余额不够扣的部分记为欠账，目前欠 %d 钻；之后获得的钻石会先抵欠账。" % debt
            body_en += " The part your balance could not cover is owed: %d diamonds. Diamonds you get later repay it first." % debt
    else:
        return
    try:
        async with db.pool().acquire() as conn:
            await conn.execute(
                "insert into mails (player_id, title_zh, body_zh, title_en, body_en, actor, note)"
                " values ($1, $2, $3, $4, $5, 'iap', $6)",
                order.player_id, title[0], body_zh, title[1], body_en,
                "iap %s %s" % (order.status, order.order_id))
    except Exception:  # noqa: BLE001 - 见 docstring
        log.exception("充值通知邮件没发出去 order=%s", order.order_id)


# --- 目录给客户端 ---------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Shelf:
    """钻石商店要显示的东西。"""

    open: bool                            # 这个平台收不收新单
    products: list[tuple[Product, bool]]  # (档位, 这一档还有没有首充双倍)，只含上架的
    wallet: shop.Wallet


async def shelf(player_id: uuid.UUID, platform: str) -> Shelf:
    if platform not in PLATFORMS:
        raise IapRejected("unknown_platform", "不认识这个平台")
    listed = [item for item in catalog().values() if item.enabled]
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(
            "select product_id from iap_first_bonus where player_id = $1", player_id)
        wallet = await shop.read_wallet_in(conn, player_id)
    used = {str(r["product_id"]) for r in rows}
    return Shelf(platform_open(platform), [(item, item.id not in used) for item in listed], wallet)
