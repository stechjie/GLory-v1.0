"""Server-authoritative cumulative seven-day login rewards.

Claiming locks the player's row and writes wallet, ledger, entitlements and claim
record in one transaction. A repeated request cannot advance a second day.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import pathlib
import uuid
from zoneinfo import ZoneInfo

from app import db, shop

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
_CONFIG_PATH = pathlib.Path(os.environ.get(
    "GLORY_SEVEN_DAY_CONFIG", _REPO_ROOT / "data" / "seven_day_login.json"))
_cache: tuple[float, dict] | None = None


def config() -> dict:
    global _cache
    mtime = _CONFIG_PATH.stat().st_mtime
    if _cache is not None and _cache[0] == mtime:
        return _cache[1]
    data = json.loads(_CONFIG_PATH.read_text(encoding="utf-8"))
    rewards = data.get("rewards", [])
    if [r.get("day") for r in rewards] != list(range(1, 8)):
        raise ValueError("seven_day_login.json must configure days 1 through 7 in order")
    for reward in rewards:
        if reward.get("reward_type") not in ("diamond", "coin", "avatar_frame"):
            raise ValueError("Unknown seven-day reward type")
        if int(reward.get("amount", 0)) <= 0:
            raise ValueError("Seven-day reward amount must be positive")
    ZoneInfo(data["game_timezone"])
    _cache = (mtime, data)
    return data


def game_day() -> dt.date:
    return dt.datetime.now(ZoneInfo(config()["game_timezone"])).date()


def _state(rows: list, today: dt.date) -> dict:
    claimed = [int(row["day"]) for row in rows]
    next_day = min(len(claimed) + 1, 7)
    completed = len(claimed) == 7
    claimable = not completed and (not rows or rows[-1]["game_day"] < today)
    return {
        "current_day": next_day,
        "claimed_days": claimed,
        "claimable_today": claimable,
        "completed": completed,
        "ice_skin_progress": len(claimed),
        "game_day": today.isoformat(),
        "rewards": config()["rewards"],
    }


async def status(player_id: uuid.UUID) -> dict:
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(
            "select day, game_day from seven_day_login_claims"
            " where player_id = $1 order by day", player_id)
    return _state(rows, game_day())


async def claim(player_id: uuid.UUID) -> dict:
    async with db.pool().acquire() as conn, conn.transaction():
        # Exists for every authenticated account. Lock serializes concurrent taps
        # before reading the claims table, including the first claim with no row.
        await conn.fetchval("select player_id from players where player_id = $1 for update", player_id)
        today = game_day()
        rows = await conn.fetch(
            "select day, game_day from seven_day_login_claims"
            " where player_id = $1 order by day", player_id)
        state = _state(rows, today)
        if state["completed"]:
            raise shop.ShopRejected("login_completed", "七日奖励已经全部领取")
        if not state["claimable_today"]:
            raise shop.ShopRejected("login_already_claimed", "今天的奖励已领取，请明天再来")
        day = state["current_day"]
        reward = config()["rewards"][day - 1]
        wallet = await shop._lock_wallet(conn, player_id)
        reward_type = reward["reward_type"]
        amount = int(reward["amount"])
        if reward_type == "diamond":
            wallet = await shop._apply(conn, player_id, wallet, {"diamond_free": amount},
                                       "seven_day_login", None, note=f"seven-day day {day}")
        elif reward_type == "coin":
            wallet = await shop._apply(conn, player_id, wallet, {"coin": amount},
                                       "seven_day_login", None, note=f"seven-day day {day}")
        else:
            await shop._grant(conn, player_id, reward["item_id"], "seven_day_login", None)
        unlock = reward.get("extra_unlock")
        if unlock:
            await shop._grant(conn, player_id, str(unlock), "seven_day_login", None)
        await conn.execute(
            "insert into seven_day_login_claims"
            " (player_id, day, game_day, reward_type, reward_amount)"
            " values ($1, $2, $3, $4, $5)",
            player_id, day, today, reward_type, amount)
    return {
        "day": day,
        "reward": reward,
        "ice_skin_progress": day,
        "skin_unlocked": bool(unlock),
        "unlocked_item_id": str(unlock) if unlock else None,
        "diamond": wallet.diamond,
        "coin": wallet.coin,
    }
