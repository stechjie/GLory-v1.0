"""Server-authoritative account XP and automatic level rewards.

Called inside the battle-report transaction, after match_uid was inserted.
The report primary key and (player_id, level) receipt key make grants idempotent.
"""
from __future__ import annotations

import uuid

from app import shop

MAX_LEVEL = 20
# Cumulative XP to enter each level, indexed by level - 1.
XP_FLOORS = (0, 60, 140, 230, 330, 440, 560, 690, 830, 980,
             1160, 1380, 1640, 1940, 2280, 2660, 3080, 3540, 4040, 4580)
GOD_BY_LEVEL = {
    2: ("god_priest",),
    4: ("god_priestess", "god_guard"),
    6: ("god_aurora", "god_angel"),
    8: ("god_arbiter", "god_archangel"),
    10: ("god_king",),
}
COIN_BY_LEVEL = {3: 300, 5: 500, 9: 500, **{n: 100 for n in range(11, 21) if n != 15}}
DIAMOND_BY_LEVEL = {7: 100, 15: 100}
HUMAN_UNITS = (
    "human_militia", "human_merchant", "human_archer", "human_swordsman",
    "human_mage", "human_cleric", "human_death_servant", "human_king",
)


def level_for_xp(xp: int) -> int:
    return max(i + 1 for i, floor in enumerate(XP_FLOORS) if xp >= floor)


def reward_for(level: int) -> dict:
    return {"level": level, "coin": COIN_BY_LEVEL.get(level, 0),
            "diamond": DIAMOND_BY_LEVEL.get(level, 0),
            "units": list(GOD_BY_LEVEL.get(level, ())),
            "prep_prompt": level == 10}


def xp_for_match(mode: str, rounds: int, result: str) -> int:
    long_match = rounds > 13
    if mode == "ranked":
        return (170 if result == "win" else 125) if long_match else (
            110 if result == "win" else 80)
    if mode == "casual":
        return (140 if result == "win" else 105) if long_match else (
            90 if result == "win" else 70)
    return 0


async def starter_human(conn, player_id: uuid.UUID) -> None:
    """Only for a newly created account; no wallet debit."""
    for unit in HUMAN_UNITS:
        await shop._grant(conn, player_id, f"unit:{unit}", "grant", None)
    await shop._grant(conn, player_id, "human", "grant", None)
    await conn.execute(
        "update players set selected_races = array['human']::text[] where player_id = $1",
        player_id)
    await conn.execute(
        "insert into player_progression (player_id) values ($1)", player_id)


async def award_match(conn, player_id: uuid.UUID, match_uid: str,
                      mode: str, rounds: int, result: str) -> int:
    """Award XP and each newly crossed level's reward in one transaction."""
    gained = xp_for_match(mode, rounds, result)
    if gained <= 0:
        return 0
    await conn.execute(
        "insert into player_progression (player_id) values ($1) on conflict do nothing",
        player_id)
    row = await conn.fetchrow(
        "select xp, level from player_progression where player_id = $1 for update",
        player_id)
    before = int(row["level"])
    after_xp = min(XP_FLOORS[-1], int(row["xp"]) + gained)
    after = level_for_xp(after_xp)
    await conn.execute(
        "update player_progression set xp = $2, level = $3, updated_at = now()"
        " where player_id = $1", player_id, after_xp, after)
    for level in range(before + 1, after + 1):
        await _grant_level(conn, player_id, level, match_uid)
    return gained


async def award_tutorial(conn, player_id: uuid.UUID) -> int:
    """Complete the first local lesson once. The progression row serializes retries.

    A tutorial cannot be a signed multiplayer battle report. Its authenticated
    completion request is only available while the account is still level one.
    Set XP to at least 90, never above 90, so this milestone reaches Lv2 only.
    """
    await conn.execute(
        "insert into player_progression (player_id) values ($1) on conflict do nothing",
        player_id)
    row = await conn.fetchrow(
        "select xp, level from player_progression where player_id = $1 for update",
        player_id)
    if int(row["level"]) >= 2:
        return 0
    before_xp = int(row["xp"])
    after_xp = max(before_xp, 90)
    await conn.execute(
        "update player_progression set xp = $2, level = 2, updated_at = now()"
        " where player_id = $1", player_id, after_xp)
    await _grant_level(conn, player_id, 2, f"tutorial:{player_id}")
    return after_xp - before_xp


async def _grant_level(conn, player_id: uuid.UUID, level: int, match_uid: str) -> None:
    await conn.execute(
        "insert into level_up_events (player_id, level, match_uid)"
        " values ($1, $2, $3) on conflict do nothing",
        player_id, level, match_uid)
    reward = reward_for(level)
    changes = {}
    if reward["coin"]:
        changes["coin"] = reward["coin"]
    if reward["diamond"]:
        changes["diamond_free"] = reward["diamond"]
    if changes:
        wallet = await shop._lock_wallet(conn, player_id)
        await shop._apply(conn, player_id, wallet, changes, "level_reward",
                          None, note=f"level {level} match {match_uid}")
    for unit in reward["units"]:
        content_id = f"unit:{unit}"
        # Keep an existing entitlement's receipt and source intact.
        if not await shop._owns(conn, player_id, content_id):
            await shop.grant_content(conn, player_id, content_id,
                                     "level_reward", None)


async def state(conn, player_id: uuid.UUID) -> dict:
    row = await conn.fetchrow(
        "select xp, level from player_progression where player_id = $1", player_id)
    xp = int(row["xp"]) if row else 0
    level = int(row["level"]) if row else 1
    unseen = await conn.fetch(
        "select level from level_up_events where player_id = $1 and seen_at is null"
        " order by level", player_id)
    return {"level": level, "xp": xp, "level_xp": XP_FLOORS[level - 1],
            "next_xp": XP_FLOORS[level] if level < 20 else None,
            "max_level": MAX_LEVEL,
            "rewards": [reward_for(n) for n in range(2, MAX_LEVEL + 1)],
            "unseen_levels": [int(r["level"]) for r in unseen]}


async def acknowledge(conn, player_id: uuid.UUID, levels: list[int]) -> None:
    if levels:
        await conn.execute(
            "update level_up_events set seen_at = now() where player_id = $1"
            " and level = any($2::smallint[]) and seen_at is null",
            player_id, levels)
