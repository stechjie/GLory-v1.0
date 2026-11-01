"""钻石抽棋盘皮肤碎片（樱花祈愿）。扣钻石、发碎片 / 游戏币、集满发皮肤在同一个事务里。

规则（改数字只改这里，公示文字在 scenes/menu/SkinWishDialog.gd，test_skin_draw 钉着两边一致）：

  · 每抽 PRICE 钻石；
  · 出碎片的概率 SHARD_CHANCE_PERCENT，出了按 SHARD_WEIGHTS 给 1 / 2 / 3 片；
  · 没出碎片给 MISS_COIN_MIN～MISS_COIN_MAX 游戏币（按 10 一档）；
  · 第 PITY_LIMIT 抽碎片还不够 TARGET_SHARDS，直接补满 —— 一张皮肤最多 PRICE × PITY_LIMIT 钻石；
  · 集满当场发皮肤归属；已经有这张皮肤就不能再抽（不卖没用的碎片）。

随机数用 secrets（加密随机），由服务端决定；客户端只发「我要抽一次」和一个防重复的 id。
"""
from __future__ import annotations

import dataclasses
import secrets
import uuid

from app import db, shop

PRICE = 100
TARGET_SHARDS = 10
PITY_LIMIT = 10
SHARD_CHANCE_PERCENT = 60
# (片数, 权重)。出碎片时按权重挑：1 片 50%、2 片 35%、3 片 15%（各占总抽数 30% / 21% / 9%）。
SHARD_WEIGHTS = ((1, 50), (2, 35), (3, 15))
MISS_COIN_MIN = 200
MISS_COIN_MAX = 300
MISS_COIN_STEP = 10

# 能抽的皮肤。每一张都必须在 data/shop.json 里登记成 enabled=false（要归属才能用、但不直接卖）。
SKIN_IDS = ("prep_skin_sakura", "prep_skin_nightwisp")


@dataclasses.dataclass(frozen=True)
class DrawState:
    skin_id: str
    shards: int
    draws: int
    owned: bool


@dataclasses.dataclass(frozen=True)
class DrawReceipt:
    draw_id: uuid.UUID
    skin_id: str
    shards_gained: int
    coin_reward: int
    shards: int
    draws: int
    unlocked: bool
    owned: bool
    wallet: shop.Wallet
    replayed: bool


def _roll_shards() -> int:
    """一抽出几片（0 = 没出，给游戏币）。"""
    if secrets.randbelow(100) >= SHARD_CHANCE_PERCENT:
        return 0
    total = sum(weight for _, weight in SHARD_WEIGHTS)
    pick = secrets.randbelow(total)
    for count, weight in SHARD_WEIGHTS:
        if pick < weight:
            return count
        pick -= weight
    return SHARD_WEIGHTS[-1][0]


def _roll_coin() -> int:
    steps = (MISS_COIN_MAX - MISS_COIN_MIN) // MISS_COIN_STEP
    return MISS_COIN_MIN + MISS_COIN_STEP * secrets.randbelow(steps + 1)


def outcome(shards: int, draws: int) -> tuple[int, int]:
    """这一抽的结果 (碎片, 游戏币)。shards / draws 是抽之前的进度。

    第 PITY_LIMIT 抽（之前已经抽了 PITY_LIMIT - 1 次）直接补满；补出来的片数可能是 1～10。
    """
    missing = TARGET_SHARDS - shards
    if draws >= PITY_LIMIT - 1:
        return missing, 0
    gained = _roll_shards()
    if gained == 0:
        return 0, _roll_coin()
    return min(gained, missing), 0


def _check_skin(skin_id: str) -> None:
    if skin_id not in SKIN_IDS:
        raise shop.ShopRejected("unknown_item", "没有这个祈愿")
    # 不在目录里的皮肤免费（shop.requires_entitlement）。抽一张免费的皮肤等于收钱卖空气。
    if not shop.requires_entitlement(skin_id):
        raise RuntimeError("skin draw pool is missing catalog entitlement: " + skin_id)


_PROGRESS = ("select shards, draws from skin_draw_progress"
             " where player_id = $1 and skin_id = $2")


async def state(player_id: uuid.UUID, skin_id: str) -> DrawState:
    _check_skin(skin_id)
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(_PROGRESS, player_id, skin_id)
        owned = await shop._owns(conn, player_id, skin_id)
    shards = int(row["shards"]) if row is not None else 0
    draws = int(row["draws"]) if row is not None else 0
    return DrawState(skin_id, shards, draws, owned)


async def draw(player_id: uuid.UUID, skin_id: str, client_draw_id: uuid.UUID) -> DrawReceipt:
    _check_skin(skin_id)
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            wallet = await shop._lock_wallet(conn, player_id)
            # 钱包行锁先把同一个玩家的请求排好队，再查防重复 id：重发的请求原样回上次的结果。
            existing = await conn.fetchrow(
                "select draw_id, skin_id, shards_gained, coin_reward, shards_after, draws_after, unlocked"
                " from skin_draws where player_id = $1 and client_draw_id = $2",
                player_id, client_draw_id)
            if existing is not None:
                owned = await shop._owns(conn, player_id, str(existing["skin_id"]))
                return DrawReceipt(existing["draw_id"], str(existing["skin_id"]),
                                   int(existing["shards_gained"]), int(existing["coin_reward"]),
                                   int(existing["shards_after"]), int(existing["draws_after"]),
                                   bool(existing["unlocked"]), owned, wallet, True)

            if await shop._owns(conn, player_id, skin_id):
                raise shop.ShopRejected("already_owned", "已经拥有这张棋盘皮肤")
            if wallet.diamond < PRICE:
                raise shop.ShopRejected("insufficient_funds", "钻石不足")
            row = await conn.fetchrow(_PROGRESS, player_id, skin_id)
            shards = int(row["shards"]) if row is not None else 0
            draws = int(row["draws"]) if row is not None else 0

            gained, coin = outcome(shards, draws)
            shards_after = shards + gained
            draws_after = draws + 1
            unlocked = shards_after >= TARGET_SHARDS
            draw_id = uuid.uuid4()

            debit = {col: -amount for col, amount in
                     shop.split_charge(wallet, "diamond", PRICE).items()}
            after = await shop._apply(conn, player_id, wallet, debit, "skin_draw", draw_id)
            if coin:
                after = await shop._apply(conn, player_id, after, {"coin": coin}, "skin_draw", draw_id)
            if unlocked:
                await shop._grant(conn, player_id, skin_id, "skin_draw", draw_id)
            await conn.execute(
                "insert into skin_draw_progress (player_id, skin_id, shards, draws) values ($1, $2, $3, $4)"
                " on conflict (player_id, skin_id) do update"
                " set shards = excluded.shards, draws = excluded.draws, updated_at = now()",
                player_id, skin_id, shards_after, draws_after)
            await conn.execute(
                "insert into skin_draws (draw_id, player_id, client_draw_id, skin_id, shards_gained,"
                " coin_reward, price_snapshot, shards_after, draws_after, unlocked)"
                " values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
                draw_id, player_id, client_draw_id, skin_id, gained, coin, PRICE,
                shards_after, draws_after, unlocked)
    return DrawReceipt(draw_id, skin_id, gained, coin, shards_after, draws_after,
                       unlocked, unlocked, after, False)
