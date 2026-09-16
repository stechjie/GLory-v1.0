"""商城：目录、钱包、归属、订单。

配套 `database/009_wallet.sql`、`database/010_shop.sql`、`data/shop.json`，
设计见 `docs/商城系统设计.md`。

## 这里管什么，不管什么

管的是**账号级**的钱与东西：钻石、黄金、头像、头像框、宠物的归属。
**不管局内经济** —— 那是 `room.slot_gold` 与 `EconomyService`，属于战斗服务器，
一局一清（`docs/金币系统.md`、`docs/P1经济账本RFC.md`）。两本账不相通，
代码里也刻意不共用一个词：局内叫 gold，这里叫 coin。

## 🔴 不在目录里的内容一律免费

现有那 20 张头像和 `frame_default` 上线时就是免费的。做商城**不能**把它们变成付费 ——
那是对已经在用它的玩家的回收。所以判定不是「有没有归属记录」，而是
`requires_entitlement()`：只有出现在 `data/shop.json` 里的内容才需要归属。

好处是存量玩家一行数据都不用发。要卖新头像就出新图、给新 id。

## 扣款顺序固定：先扣赠送，后扣付费

钻石分 `diamond_paid` / `diamond_free` 两列，退款与对账要的是「他还剩多少是花钱买的」。
反过来扣的话，玩家充值后先花掉付费那部分、剩一堆赠送余额，那个数就算不出来了。

**对客户端合并成一个数下发** —— 游戏里从来只显示总数，分账纯粹是后台账目。

## 两条跟钱有关的纪律

🔴 **`source` 填错等于把账弄脏，而且当时没有任何症状**：手工发放记 `grant`、
充值记 `iap`，别图省事混用。

🔴 **`wallet_ledger` 永远不许裁剪** —— 「这个号的钻石哪来的」是客服最常被问的，
而且钱包那两列本质是流水的缓存，对不上时没有东西可以拿来核对。
`database/009_wallet.sql` 里有一整段说这件事：这个仓库别处**是有**裁剪先例的
（`maintenance.py` 清私聊与好友日志、chat 每对留 200 条），照抄过来当天毫无症状。
"""

from __future__ import annotations

import dataclasses
import datetime as dt
import json
import logging
import os
import pathlib
import uuid

import asyncpg

from app import db

log = logging.getLogger("glory.shop")

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
_SHOP_PATH = pathlib.Path(os.environ.get("GLORY_SHOP_CATALOG", _REPO_ROOT / "data" / "shop.json"))
_PETS_PATH = pathlib.Path(
    os.environ.get("GLORY_PETS_TABLE", _REPO_ROOT / "data" / "pets" / "pets.json")
)

# 钱包的三列，也是流水的 currency 合法值。与 database/009_wallet.sql 一一对应 ——
# 写错列名不会报错，只会让那笔流水永远对不上任何一列余额。
COLUMNS = ("diamond_paid", "diamond_free", "coin")

# 商品能用哪些货币。**货币不等于列**：diamond 会落到 diamond_free / diamond_paid
# 两列上（先扣赠送，见 split_charge）；coin 一对一。
CURRENCIES = ("diamond", "coin")

# 流水与订单的 source 合法值。**这里是唯一真相** ——
# 数据库那层刻意不加 check（加了以后运营手工发一种新名目就要先跑迁移，
# 而那通常发生在出事故的当天），所以这一层漏了就等于没校验。
SOURCES = ("shop", "iap", "grant", "refund", "starter_pick", "match_reward")


class ShopRejected(RuntimeError):
    """业务拒绝。code 会被路由层映射成 HTTP 状态码，message 可以直接给玩家看。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


# --- 目录 ---------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Item:
    id: str          # 商品 id，只出现在订单里
    kind: str        # avatar / avatar_frame / pet
    grants: str      # 内容 id，归属表存的是它
    currency: str
    price: int
    name: str
    name_en: str


_shop_cache: tuple[float, dict] | None = None
_pets_cache: tuple[float, dict] | None = None


def _mtime(path: pathlib.Path, what: str) -> float:
    """取文件时间戳，读不到就抛。

    **不降级成空表** —— 同 avatar_catalog._load 的理由：空目录意味着
    「所有商品都不存在」，玩家会发现商城是空的却没有任何提示，
    而运维那边什么错都看不到。宁可让接口 500 并在日志里留下原因。

    这个失败有一个具体且会重复发生的原因：部署脚本**只**把 backend/ 和 deploy/
    同步到运行目录，数据文件靠 deploy/update.sh 里「复制后端要读的数据文件」
    那一段单独复制，而那一段的文件名列表是写死的。报这个错基本就是
    新文件没加进那个列表，或者服务器上的脚本是旧版。
    """
    try:
        return path.stat().st_mtime
    except OSError as exc:
        raise RuntimeError(
            "读不到%s %s —— 检查 deploy/update.sh 的「复制后端要读的数据文件」那一段"
            % (what, path)
        ) from exc


def _catalog() -> dict:
    """商品目录。返回 {商品 id: Item} 与 {内容 id: Item} 两张索引。

    ⚠️ 命中缓存时**不读文件也不解析** —— 先 stat 拿 mtime 再决定。
    每次都 json.loads 一遍的话缓存等于没有，而这是每个商城请求都要走的路。
    """
    global _shop_cache
    mtime = _mtime(_SHOP_PATH, "商品目录")
    if _shop_cache is not None and _shop_cache[0] == mtime:
        return _shop_cache[1]
    data = json.loads(_SHOP_PATH.read_text(encoding="utf-8"))

    by_item: dict[str, Item] = {}
    by_content: dict[str, Item] = {}
    for raw in data.get("items", []):
        item = Item(
            id=str(raw["id"]),
            kind=str(raw["kind"]),
            grants=str(raw["grants"]),
            currency=str(raw["currency"]),
            price=int(raw["price"]),
            name=str(raw.get("name", raw["id"])),
            name_en=str(raw.get("name_en", raw.get("name", raw["id"]))),
        )
        if item.currency not in CURRENCIES:
            raise ValueError("shop.json 的 %s 用了未知货币 %s" % (item.id, item.currency))
        if item.price < 0:
            raise ValueError("shop.json 的 %s 价格是负数" % item.id)
        if item.id in by_item:
            raise ValueError("shop.json 有重复的商品 id：%s" % item.id)
        # 同一个内容 id 允许被多个商品指向（同一只宠物在不同活动里不同包装），
        # 但 by_content 只用于「这个内容要不要归属」，留第一个就够。
        by_item[item.id] = item
        by_content.setdefault(item.grants, item)

    parsed = {"by_item": by_item, "by_content": by_content}
    _shop_cache = (mtime, parsed)
    return parsed


def _pets() -> dict:
    """宠物表。服务端与客户端读**同一份** data/pets/pets.json ——
    starter_ids 有两处定义的话，迟早会出现「客户端让选、服务端说不是新手宠物」。"""
    global _pets_cache
    mtime = _mtime(_PETS_PATH, "宠物表")
    if _pets_cache is not None and _pets_cache[0] == mtime:
        return _pets_cache[1]
    data = json.loads(_PETS_PATH.read_text(encoding="utf-8"))

    parsed = {
        "ids": {str(p["id"]) for p in data.get("pets", [])},
        "starters": [str(x) for x in data.get("starter_ids", [])],
    }
    for sid in parsed["starters"]:
        if sid not in parsed["ids"]:
            raise ValueError("pets.json 的 starter_ids 里有不存在的宠物：%s" % sid)
    _pets_cache = (mtime, parsed)
    return parsed


def items() -> list[Item]:
    """整份目录，按 shop.json 里的顺序。"""
    return list(_catalog()["by_item"].values())


def item_by_id(item_id: str) -> Item:
    found = _catalog()["by_item"].get(item_id)
    if found is None:
        raise ShopRejected("unknown_item", "没有这个商品")
    return found


def requires_entitlement(content_id: str) -> bool:
    """这个内容要不要归属才能用？

    🔴 **不在目录里 = 免费**，见模块开头。别反过来写成「不在归属表里就是没有」——
    那会让现有玩家正在用的头像一夜之间变成「你没有」。
    """
    return content_id in _catalog()["by_content"]


def starter_ids() -> list[str]:
    return list(_pets()["starters"])


def is_pet(content_id: str) -> bool:
    return content_id in _pets()["ids"]


# --- 钱包 ---------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Wallet:
    diamond_paid: int
    diamond_free: int
    coin: int

    @property
    def diamond(self) -> int:
        """对客户端合并成一个数。游戏里从来只显示总数，分账纯粹是后台账目。"""
        return self.diamond_paid + self.diamond_free

    def balance_of(self, currency: str) -> int:
        return self.diamond if currency == "diamond" else self.coin


EMPTY_WALLET = Wallet(0, 0, 0)


async def _lock_wallet(conn: asyncpg.Connection, player_id: uuid.UUID) -> Wallet:
    """锁住钱包行并读出来。**必须已经在事务里。**

    钱包行是惰性建的（见 009 的注释）。先 insert … on conflict do nothing
    是为了让后面的 `for update` 一定锁得到一行 —— 没有行的话 `for update`
    锁不到任何东西，两笔并发的首次扣款会都以为余额是 0。
    """
    await conn.execute(
        "insert into player_wallets (player_id) values ($1) on conflict do nothing",
        player_id,
    )
    row = await conn.fetchrow(
        "select diamond_paid, diamond_free, coin from player_wallets"
        " where player_id = $1 for update",
        player_id,
    )
    return Wallet(row["diamond_paid"], row["diamond_free"], row["coin"])


async def read_wallet(player_id: uuid.UUID) -> Wallet:
    """只读，不建行。没有行 = 余额全 0，不是错误。"""
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(
            "select diamond_paid, diamond_free, coin from player_wallets where player_id = $1",
            player_id,
        )
    if row is None:
        return EMPTY_WALLET
    return Wallet(row["diamond_paid"], row["diamond_free"], row["coin"])


def split_charge(wallet: Wallet, currency: str, amount: int) -> dict[str, int]:
    """把一笔扣款拆到具体的列上。返回 {列名: 扣多少}（正数）。

    钻石**先扣赠送、后扣付费**。反过来扣的话，玩家充值后会先花掉付费那部分、
    剩一堆赠送余额，退款时「他还剩多少是花钱买的」就算不出来了。

    纯函数，单独拿出来是为了能直接测 —— 这段写反不会报错，
    要到第一次退款时才发现口径不对。
    """
    if amount <= 0:
        return {}
    if currency == "coin":
        return {"coin": amount}
    from_free = min(amount, wallet.diamond_free)
    out: dict[str, int] = {}
    if from_free:
        out["diamond_free"] = from_free
    if amount - from_free:
        out["diamond_paid"] = amount - from_free
    return out


async def _apply(
    conn: asyncpg.Connection,
    player_id: uuid.UUID,
    wallet: Wallet,
    changes: dict[str, int],
    source: str,
    order_id: uuid.UUID | None,
    actor: str | None = None,
    note: str | None = None,
) -> Wallet:
    """把一组列变更写进钱包并**在同一事务里**写流水。changes 是有符号的。

    余额是结果，流水是过程。只写余额不写流水的账查不动 ——
    所以这两件事在这一个函数里，**没有第二条改余额的路径**。
    这也是 player_wallets 那两列与流水始终对得上的唯一保证。

    🔴 source 不能填错：手工发放记 grant、充值记 iap。填错当时没有任何症状，
    坏的是以后对账。
    """
    if source not in SOURCES:
        raise ValueError("未知的流水来源：%s（合法值在 shop.SOURCES）" % source)

    after = dataclasses.asdict(wallet)
    for column, delta in changes.items():
        if column not in COLUMNS:
            raise ValueError("未知的钱包列：%s（合法值在 shop.COLUMNS）" % column)
        after[column] += delta

    await conn.execute(
        "update player_wallets set diamond_paid = $2, diamond_free = $3, coin = $4,"
        " updated_at = now() where player_id = $1",
        player_id, after["diamond_paid"], after["diamond_free"], after["coin"],
    )
    # 一笔钱跨两列时写两条流水，每条的 balance_after 是**那一列**的余额。
    # 合成一条的话就没法对账到具体某一列。
    for column, delta in changes.items():
        await conn.execute(
            "insert into wallet_ledger"
            " (player_id, currency, delta, balance_after, source, order_id, actor, note)"
            " values ($1, $2, $3, $4, $5, $6, $7, $8)",
            player_id, column, delta, after[column], source, order_id, actor, note,
        )
    return Wallet(after["diamond_paid"], after["diamond_free"], after["coin"])


# --- 归属 ---------------------------------------------------------------------


async def read_entitlements(player_id: uuid.UUID) -> list[str]:
    """拥有的**内容 id**。不含已退款收回的。"""
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(
            "select item_id from player_entitlements"
            " where player_id = $1 and revoked_at is null order by granted_at, item_id",
            player_id,
        )
    return [r["item_id"] for r in rows]


async def _owns(conn: asyncpg.Connection, player_id: uuid.UUID, content_id: str) -> bool:
    return bool(await conn.fetchval(
        "select 1 from player_entitlements"
        " where player_id = $1 and item_id = $2 and revoked_at is null",
        player_id, content_id,
    ))


async def _grant(
    conn: asyncpg.Connection,
    player_id: uuid.UUID,
    content_id: str,
    source: str,
    order_id: uuid.UUID | None,
) -> None:
    """发货。**必须已经在事务里**，与扣款同一个。

    `on conflict do update` 而不是 `do nothing`：退款收回之后又重新买的话，
    主键已经被那一行占着，`do nothing` 会让钱扣了东西不到。
    这一条把 revoked_at 置回 null（010 的注释里写了同一件事）。
    """
    await conn.execute(
        "insert into player_entitlements (player_id, item_id, source, order_id)"
        " values ($1, $2, $3, $4)"
        " on conflict (player_id, item_id) do update"
        " set revoked_at = null, granted_at = now(),"
        "     source = excluded.source, order_id = excluded.order_id",
        player_id, content_id, source, order_id,
    )


# --- 购买 ---------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Receipt:
    order_id: uuid.UUID
    item_id: str
    granted: str
    currency: str
    price: int
    wallet: Wallet
    replayed: bool
    created_at: dt.datetime


async def purchase(
    player_id: uuid.UUID,
    client_order_id: uuid.UUID,
    item_id: str,
) -> Receipt:
    """买一件商品。

    ## 🔴 handler 顺序不能变

        1. 查目录（商品存不存在、价格、货币）
        2. ★ 先查订单：同 client_order_id 命中就直接重放，不再执行
        3. 只有新请求才继续：查归属 → 锁钱包查余额 → 事务内扣款 + 发货 + 写流水 + 写订单

    **第 2 步必须在第 3 步之前。** 反过来的话，「执行成功但回执丢了」的重试会被
    第 3 步的「你已经拥有了」拒掉 —— 玩家钱扣了，东西看不见，而且再也拿不回那张回执。
    这是整个幂等设计里最容易写反的一处（同 docs/P1经济账本RFC.md 第六节）。

    拒绝**不落库**，理由见 database/010_shop.sql 的 status 注释。
    """
    item = item_by_id(item_id)

    async with db.pool().acquire() as conn:
        async with conn.transaction():
            existing = await conn.fetchrow(
                "select order_id, item_id, currency, price_snapshot, created_at"
                " from shop_orders where player_id = $1 and client_order_id = $2",
                player_id, client_order_id,
            )
            if existing is not None:
                if existing["item_id"] != item_id:
                    # 同一个幂等键被用来买两样东西。这不是弱网重试，是客户端有 bug
                    # 或者有人在试探。拒绝并留日志，**不要**当成新订单处理。
                    log.warning(
                        "订单幂等键冲突 player=%s client_order=%s 原商品=%s 这次=%s",
                        player_id, client_order_id, existing["item_id"], item_id,
                    )
                    raise ShopRejected(
                        "order_conflict", "这笔订单号已经用于另一件商品了")
                # ⚠️ 商品与价格**原样重放**，但余额给的是**当前**余额 ——
                # 重放期间玩家可能已经买过别的，把历史余额回给客户端会让界面倒退。
                return Receipt(
                    order_id=existing["order_id"],
                    item_id=existing["item_id"],
                    granted=item.grants,
                    currency=existing["currency"],
                    price=existing["price_snapshot"],
                    wallet=await _lock_wallet(conn, player_id),
                    replayed=True,
                    created_at=existing["created_at"],
                )

            if await _owns(conn, player_id, item.grants):
                raise ShopRejected("already_owned", "你已经拥有它了")

            wallet = await _lock_wallet(conn, player_id)
            if wallet.balance_of(item.currency) < item.price:
                raise ShopRejected("insufficient_funds", "余额不足")

            order_id = uuid.uuid4()
            # 0 价商品拆出来是空 dict，于是一条流水都不写 ——
            # 009 的 `delta <> 0` 会挡下 delta=0 的流水。今天只有三选一是 0 价、
            # 它走 pick_starter 不走这里，但目录里随时可能出现一件免费商品。
            changes = {col: -n for col, n in split_charge(wallet, item.currency, item.price).items()}
            after = await _apply(conn, player_id, wallet, changes, "shop", order_id)
            await _grant(conn, player_id, item.grants, "shop", order_id)
            created_at = await conn.fetchval(
                "insert into shop_orders"
                " (order_id, player_id, client_order_id, item_id, currency,"
                "  price_snapshot, status, source, settled_at)"
                " values ($1, $2, $3, $4, $5, $6, 'ok', 'shop', now())"
                " returning created_at",
                order_id, player_id, client_order_id, item.id, item.currency, item.price,
            )

    return Receipt(
        order_id=order_id,
        item_id=item.id,
        granted=item.grants,
        currency=item.currency,
        price=item.price,
        wallet=after,
        replayed=False,
        created_at=created_at,
    )


# --- 宠物 ---------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Pets:
    owned: list[str]
    active: str
    needs_starter_pick: bool


async def read_pets(player_id: uuid.UUID) -> Pets:
    """拥有的宠物、出战的那只、要不要弹三选一。

    出战宠物存在 players.showcase_pet —— 上云之后「展示」和「出战」是同一只，
    不另开一列（两列就会有两处不一致）。
    """
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(
            "select item_id from player_entitlements"
            " where player_id = $1 and revoked_at is null order by granted_at, item_id",
            player_id,
        )
        active = await conn.fetchval(
            "select showcase_pet from players where player_id = $1", player_id)

    owned = [r["item_id"] for r in rows if is_pet(r["item_id"])]
    active = str(active or "")
    # 出战的那只被退款收回了（或者数据被手工改坏了）就当没选。
    if active not in owned:
        active = owned[0] if owned else ""
    return Pets(owned=owned, active=active, needs_starter_pick=not owned)


async def set_active_pet(player_id: uuid.UUID, pet_id: str) -> Pets:
    """设出战宠物。**校验归属。**

    `players.showcase_pet` 原本没有任何归属校验 —— 和 avatar_catalog 注释里
    预告的是同一个洞。宠物一旦卖钱，不校验就是「改个请求体就能用没买的宠物」。
    """
    if not is_pet(pet_id):
        raise ShopRejected("unknown_pet", "没有这只宠物")
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            if not await _owns(conn, player_id, pet_id):
                raise ShopRejected("not_owned", "你还没有这只宠物")
            await conn.execute(
                "update players set showcase_pet = $2 where player_id = $1",
                player_id, pet_id,
            )
    return await read_pets(player_id)


async def pick_starter(
    player_id: uuid.UUID,
    client_order_id: uuid.UUID,
    pet_id: str,
) -> Receipt:
    """新手三选一。

    走的是**和购买完全一样的发货路径**（同一张订单表、同一个幂等键、同一条
    `_grant`），只是 source 是 starter_pick、价格是 0。

    刻意不给它写一条专用的简化路径：这样发货与幂等在第一天就被每一个新玩家
    压满，不用等到充值上线才第一次被真实流量压。
    """
    if pet_id not in starter_ids():
        raise ShopRejected("not_a_starter", "这只宠物不在新手三选一里")

    async with db.pool().acquire() as conn:
        async with conn.transaction():
            existing = await conn.fetchrow(
                "select order_id, item_id, created_at from shop_orders"
                " where player_id = $1 and client_order_id = $2",
                player_id, client_order_id,
            )
            if existing is not None:
                if existing["item_id"] != pet_id:
                    raise ShopRejected(
                        "order_conflict", "这笔订单号已经用于另一件商品了")
                return Receipt(
                    order_id=existing["order_id"], item_id=pet_id, granted=pet_id,
                    currency="diamond", price=0,
                    wallet=await _lock_wallet(conn, player_id),
                    replayed=True, created_at=existing["created_at"],
                )

            # 三选一只发一次。已经有任何宠物就不再发 —— 否则买过宠物的老玩家
            # 清一次本地数据就能再白拿一只。
            #
            # ⚠️ 必须**按宠物 id 过滤**去问，不能只取归属表的第一行来判 ——
            # 那个人可能同时拥有头像，第一行取到头像时 is_pet 是 false，
            # 于是一个已经有宠物的人又被发了一只。
            has_pet = await conn.fetchval(
                "select 1 from player_entitlements"
                " where player_id = $1 and revoked_at is null and item_id = any($2::text[])",
                player_id, sorted(_pets()["ids"]))
            if has_pet:
                raise ShopRejected("starter_already_picked", "你已经领过新手宠物了")

            await _grant(conn, player_id, pet_id, "starter_pick", None)
            await conn.execute(
                "update players set showcase_pet = $2 where player_id = $1",
                player_id, pet_id,
            )
            order_id = uuid.uuid4()
            created_at = await conn.fetchval(
                "insert into shop_orders"
                " (order_id, player_id, client_order_id, item_id, currency,"
                "  price_snapshot, status, source, settled_at)"
                " values ($1, $2, $3, $4, 'diamond', 0, 'ok', 'starter_pick', now())"
                " returning created_at",
                order_id, player_id, client_order_id, pet_id,
            )
            wallet = await _lock_wallet(conn, player_id)

    return Receipt(
        order_id=order_id, item_id=pet_id, granted=pet_id, currency="diamond", price=0,
        wallet=wallet, replayed=False, created_at=created_at,
    )
