"""Server-authoritative diamond pet draw. Charge, award and pity commit together."""
from __future__ import annotations

import dataclasses
import secrets
import uuid

from app import db, shop

PRICE = 75
MISS_COIN = 100
PITY_LIMIT = 10
PET_IDS = ("pet_squirrel", "pet_tiger")


@dataclasses.dataclass(frozen=True)
class DrawState:
    owned: list[str]
    available: list[str]
    misses: int


@dataclasses.dataclass(frozen=True)
class DrawReceipt:
    draw_id: uuid.UUID
    pet_id: str
    coin_reward: int
    misses: int
    wallet: shop.Wallet
    replayed: bool


def _available(owned: list[str]) -> list[str]:
    return [pet_id for pet_id in PET_IDS if pet_id not in owned]


def _outcome(available: list[str], misses: int) -> str:
    """Cryptographic server roll; the tenth draw is guaranteed."""
    if misses >= PITY_LIMIT - 1 or secrets.randbelow(10) == 0:
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
        misses = await conn.fetchval(
            "select misses from pet_draw_progress where player_id = $1", player_id)
    return DrawState(owned, _available(owned), int(misses or 0))


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
                "select draw_id, pet_id, coin_reward, misses_after from pet_draws"
                " where player_id = $1 and client_draw_id = $2",
                player_id, client_draw_id)
            if existing is not None:
                current_misses = await conn.fetchval(
                    "select misses from pet_draw_progress where player_id = $1", player_id)
                return DrawReceipt(existing["draw_id"], str(existing["pet_id"] or ""),
                                   int(existing["coin_reward"]), int(current_misses or 0),
                                   wallet, True)

            owned = await _owned(conn, player_id)
            available = _available(owned)
            if not available:
                raise shop.ShopRejected("pool_complete", "奖池宠物已全部拥有")
            if wallet.diamond < PRICE:
                raise shop.ShopRejected("insufficient_funds", "钻石不足")
            misses = int(await conn.fetchval(
                "select misses from pet_draw_progress where player_id = $1", player_id) or 0)
            pet_id = _outcome(available, misses)
            after_misses = 0 if pet_id else misses + 1
            draw_id = uuid.uuid4()
            debit = {col: -amount for col, amount in
                     shop.split_charge(wallet, "diamond", PRICE).items()}
            after = await shop._apply(conn, player_id, wallet, debit, "pet_draw", draw_id)
            if pet_id:
                await shop._grant(conn, player_id, pet_id, "pet_draw", draw_id)
            else:
                after = await shop._apply(conn, player_id, after, {"coin": MISS_COIN},
                                          "pet_draw", draw_id)
            await conn.execute(
                "insert into pet_draw_progress (player_id, misses) values ($1, $2)"
                " on conflict (player_id) do update set misses = excluded.misses",
                player_id, after_misses)
            await conn.execute(
                "insert into pet_draws (draw_id, player_id, client_draw_id, pet_id,"
                " coin_reward, price_snapshot, misses_after) values ($1,$2,$3,$4,$5,$6,$7)",
                draw_id, player_id, client_draw_id, pet_id or None,
                0 if pet_id else MISS_COIN, PRICE, after_misses)
    return DrawReceipt(draw_id, pet_id, 0 if pet_id else MISS_COIN,
                       after_misses, after, False)
