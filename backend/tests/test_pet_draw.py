"""Diamond pet draw: one transaction, pity, and idempotent retry."""
from __future__ import annotations

import asyncio
import uuid

import pytest

from app import pet_draw, shop


class FakeConn:
    def __init__(self):
        self.wallet = shop.Wallet(diamond_paid=500, diamond_free=50, coin=0)
        self.owned: set[str] = set()
        self.misses = 0
        self.draws: dict[uuid.UUID, dict] = {}
        self.money_writes: list[dict] = []
        self.grants: list[str] = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        return False

    def transaction(self):
        return self

    async def fetchrow(self, sql, *args):
        assert "from pet_draws" in sql
        return self.draws.get(args[1])

    async def fetch(self, sql, *args):
        assert "from player_entitlements" in sql
        return [{"item_id": pet_id} for pet_id in sorted(self.owned)]

    async def fetchval(self, sql, *args):
        assert "from pet_draw_progress" in sql
        return self.misses

    async def execute(self, sql, *args):
        if "insert into pet_draw_progress" in sql:
            self.misses = args[1]
        elif "insert into pet_draws" in sql:
            self.draws[args[2]] = {
                "draw_id": args[0], "pet_id": args[3],
                "coin_reward": args[4], "misses_after": args[6],
            }
        else:
            raise AssertionError(sql)


class Pool:
    def __init__(self, conn):
        self.conn = conn

    def acquire(self):
        return self.conn


@pytest.fixture
def draw_db(monkeypatch):
    conn = FakeConn()
    monkeypatch.setattr(pet_draw.db, "pool", lambda: Pool(conn))

    async def lock_wallet(c, _player):
        return c.wallet

    async def apply(c, _player, wallet, changes, source, _draw_id):
        assert source == "pet_draw"
        c.money_writes.append(changes.copy())
        c.wallet = shop.Wallet(
            wallet.diamond_paid + changes.get("diamond_paid", 0),
            wallet.diamond_free + changes.get("diamond_free", 0),
            wallet.coin + changes.get("coin", 0),
        )
        return c.wallet

    async def grant(c, _player, pet_id, source, _draw_id):
        assert source == "pet_draw"
        c.owned.add(pet_id)
        c.grants.append(pet_id)

    monkeypatch.setattr(shop, "_lock_wallet", lock_wallet)
    monkeypatch.setattr(shop, "_apply", apply)
    monkeypatch.setattr(shop, "_grant", grant)
    return conn


def test_miss_replay_and_tenth_draw(draw_db, monkeypatch):
    monkeypatch.setattr(pet_draw.secrets, "randbelow", lambda _: 1)
    monkeypatch.setattr(pet_draw.secrets, "choice", lambda available: available[0])
    player = uuid.uuid4()
    draw_id = uuid.uuid4()

    miss = asyncio.run(pet_draw.draw(player, draw_id))
    assert miss.pet_id == "" and miss.coin_reward == 100 and miss.misses == 1
    assert miss.wallet.diamond == 475 and miss.wallet.coin == 100
    assert draw_db.money_writes == [
        {"diamond_free": -50, "diamond_paid": -25}, {"coin": 100}]

    replay = asyncio.run(pet_draw.draw(player, draw_id))
    assert replay.replayed and replay.draw_id == miss.draw_id
    assert len(draw_db.money_writes) == 2

    draw_db.misses = 9
    win = asyncio.run(pet_draw.draw(player, uuid.uuid4()))
    assert win.pet_id == "pet_squirrel" and win.misses == 0
    assert win.coin_reward == 0 and draw_db.grants == ["pet_squirrel"]
    state = asyncio.run(pet_draw.state(player))
    assert state.available == ["pet_tiger"]


def test_rejected_draw_never_charges(draw_db):
    player = uuid.uuid4()
    draw_db.wallet = shop.Wallet(0, 0, 0)
    with pytest.raises(shop.ShopRejected) as insufficient:
        asyncio.run(pet_draw.draw(player, uuid.uuid4()))
    assert insufficient.value.code == "insufficient_funds"
    assert draw_db.money_writes == []

    draw_db.owned.update(pet_draw.PET_IDS)
    with pytest.raises(shop.ShopRejected) as complete:
        asyncio.run(pet_draw.draw(player, uuid.uuid4()))
    assert complete.value.code == "pool_complete"
    assert draw_db.money_writes == []
