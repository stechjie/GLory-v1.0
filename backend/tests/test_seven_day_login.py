"""Seven-day rewards must be atomic and impossible to claim twice in a game day."""

from __future__ import annotations

import asyncio
import datetime as dt
import uuid

import pytest

from app import db, seven_day_login, shop

PLAYER = uuid.UUID(int=913)
TODAY = dt.date(2026, 9, 29)


class _Context:
    def __init__(self, conn):
        self.conn = conn

    async def __aenter__(self):
        return self.conn

    async def __aexit__(self, *_args):
        return False


class _Conn:
    def __init__(self, rows):
        self.rows = rows
        self.writes: list[tuple[str, tuple]] = []

    def transaction(self):
        return _Context(self)

    async def fetchval(self, sql, *_args):
        if "from players" in sql:
            return PLAYER
        return None

    async def fetch(self, sql, *_args):
        if "seven_day_login_claims" in sql:
            return self.rows
        return []

    async def fetchrow(self, sql, *_args):
        if "player_wallets" in sql:
            return {"diamond_paid": 0, "diamond_free": 0, "coin": 0}
        return None

    async def execute(self, sql, *args):
        self.writes.append((" ".join(sql.split()), args))
        return "INSERT 0 1"

    def count(self, fragment):
        return sum(fragment in sql for sql, _ in self.writes)


def _wire(monkeypatch, rows):
    conn = _Conn(rows)

    class _Pool:
        def acquire(self):
            return _Context(conn)

    monkeypatch.setattr(db, "pool", lambda: _Pool())
    monkeypatch.setattr(seven_day_login, "game_day", lambda: TODAY)
    return conn


def test_claim_day_one_credits_free_diamonds_and_ledger(monkeypatch):
    conn = _wire(monkeypatch, [])
    result = asyncio.run(seven_day_login.claim(PLAYER))
    assert result["day"] == 1 and result["diamond"] == 100
    assert conn.count("update player_wallets") == 1
    assert conn.count("insert into wallet_ledger") == 1
    assert conn.count("insert into seven_day_login_claims") == 1


def test_second_claim_same_game_day_changes_nothing(monkeypatch):
    conn = _wire(monkeypatch, [{"day": 1, "game_day": TODAY}])
    with pytest.raises(shop.ShopRejected) as exc:
        asyncio.run(seven_day_login.claim(PLAYER))
    assert exc.value.code == "login_already_claimed"
    assert conn.count("update player_wallets") == 0
    assert conn.count("insert into seven_day_login_claims") == 0


def test_day_six_grants_exclusive_frame(monkeypatch):
    rows = [{"day": i, "game_day": TODAY - dt.timedelta(days=6 - i)} for i in range(1, 6)]
    conn = _wire(monkeypatch, rows)
    result = asyncio.run(seven_day_login.claim(PLAYER))
    assert result["day"] == 6
    grants = [args[1] for sql, args in conn.writes if "into player_entitlements" in sql]
    assert grants == ["preset:avatar_frame_7day_01"]
    assert conn.count("update player_wallets") == 0


def test_day_seven_grants_diamonds_and_skin_together(monkeypatch):
    rows = [{"day": i, "game_day": TODAY - dt.timedelta(days=7 - i)} for i in range(1, 7)]
    conn = _wire(monkeypatch, rows)
    result = asyncio.run(seven_day_login.claim(PLAYER))
    assert result["day"] == 7 and result["skin_unlocked"] is True
    assert result["diamond"] == 100
    grants = [args[1] for sql, args in conn.writes if "into player_entitlements" in sql]
    assert grants == ["prep_skin_ice"]
    assert conn.count("insert into wallet_ledger") == 1
    assert conn.count("insert into seven_day_login_claims") == 1
