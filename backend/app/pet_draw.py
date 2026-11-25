"""Server-authoritative draw. Charge, award and summon energy commit together."""
from __future__ import annotations

import dataclasses
import secrets
import uuid

from app import db, shop, trial

PRICE = 75
MISS_COIN = 100
PITY_LIMIT = 10
PET_IDS = ("pet_squirrel", "pet_tiger", "pet_monkey")


@dataclasses.dataclass(frozen=True)
class DrawState:
    owned: list[str]
    available: list[str]
    energy: int


@dataclasses.dataclass(frozen=True)
class DrawReceipt:
    draw_id: uuid.UUID
    pet_id: str
    coin_reward: int
    energy: int
    wallet: shop.Wallet
    replayed: bool
    # 没抽中时可能附带的体验卡（trial.py）：目标宠物与天数；没有卡时是 "" / 0。
    trial_target: str = ""
    trial_days: int = 0


def _available(owned: list[str]) -> list[str]:
    return [pet_id for pet_id in PET_IDS if pet_id not in owned]


def _outcome(available: list[str], energy: int) -> str:
    """Cryptographic server roll; the tenth draw is guaranteed."""
    if energy >= PITY_LIMIT - 1 or secrets.randbelow(10) == 0:
        return secrets.choice(available)
    return ""


async def _owned(conn, player_id: uuid.UUID) -> list[str]:
    rows = await conn.fetch(
        "select item_id from player_entitlements where player_id = $1"
        " and revoked_at is null and item_id = any($2::text[])",
        player_id, list(PET_IDS),
    )
    return [str(row["item_id"]) for row in rows]


async def state(player_id: uuid.UUID) -> DrawState:
    async with db.pool().acquire() as conn:
        owned = await _owned(conn, player_id)
        energy = await conn.fetchval(
            "select misses from pet_draw_progress where player_id = $1", player_id)
    return DrawState(owned, _available(owned), int(energy or 0))


async def draw(player_id: uuid.UUID, client_draw_id: uuid.UUID) -> DrawReceipt:
    # Disabled catalog entries still mark the pets as paid content for entitlement checks.
    for pet_id in PET_IDS:
        if not shop.requires_entitlement(pet_id) or not shop.is_pet(pet_id):
            raise RuntimeError("pet draw pool is missing catalog entitlement: " + pet_id)
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            wallet = await shop._lock_wallet(conn, player_id)
            # Wallet lock serializes same-player requests before checking the idempotency key.
            existing = await conn.fetchrow(
                "select draw_id, pet_id, coin_reward, misses_after, trial_target, trial_days"
                " from pet_draws"
                " where player_id = $1 and client_draw_id = $2",
                player_id, client_draw_id)
            if existing is not None:
                current_energy = await conn.fetchval(
                    "select misses from pet_draw_progress where player_id = $1", player_id)
                return DrawReceipt(existing["draw_id"], str(existing["pet_id"] or ""),
                                   int(existing["coin_reward"]), int(current_energy or 0),
                                   wallet, True, str(existing["trial_target"] or ""),
                                   int(existing["trial_days"] or 0))

            owned = await _owned(conn, player_id)
            available = _available(owned)
            if not available:
                raise shop.ShopRejected("pool_complete", "奖池宠物已全部拥有")
            if wallet.diamond < PRICE:
                raise shop.ShopRejected("insufficient_funds", "钻石不足")
            energy = int(await conn.fetchval(
                "select misses from pet_draw_progress where player_id = $1", player_id) or 0)
            pet_id = _outcome(available, energy)
            # The legacy DB column is named misses; it now stores paid-draw energy.
            # An early pet keeps progress. Only the guaranteed tenth draw resets it.
            after_energy = 0 if energy >= PITY_LIMIT - 1 else energy + 1
            draw_id = uuid.uuid4()
            debit = {col: -amount for col, amount in
                     shop.split_charge(wallet, "diamond", PRICE).items()}
            after = await shop._apply(conn, player_id, wallet, debit, "pet_draw", draw_id)
            coin = 0
            card_target, card_days = "", 0
            if pet_id:
                await shop._grant(conn, player_id, pet_id, "pet_draw", draw_id)
            else:
                # 没抽中：三选一（只给游戏币 / 只给体验卡 / 两样都给，trial.MISS_OUTCOMES）。
                # 卡从这个人还没拥有的奖池宠物里挑一只。
                give_coin, card_days = trial.roll_miss()
                if give_coin:
                    coin = MISS_COIN
                    after = await shop._apply(conn, player_id, after, {"coin": MISS_COIN},
                                              "pet_draw", draw_id)
                if card_days:
                    card_target = secrets.choice(available)
                    await trial.add_cards(conn, player_id, card_target, card_days, 1, "pet_draw",
                                          draw_id=draw_id)
            await conn.execute(
                "insert into pet_draw_progress (player_id, misses) values ($1, $2)"
                " on conflict (player_id) do update set misses = excluded.misses",
                player_id, after_energy)
            await conn.execute(
                "insert into pet_draws (draw_id, player_id, client_draw_id, pet_id,"
                " coin_reward, price_snapshot, misses_after, trial_target, trial_days)"
                " values ($1,$2,$3,$4,$5,$6,$7,$8,$9)",
                draw_id, player_id, client_draw_id, pet_id or None,
                coin, PRICE, after_energy, card_target or None, card_days or None)
    return DrawReceipt(draw_id, pet_id, coin, after_energy, after, False, card_target, card_days)
