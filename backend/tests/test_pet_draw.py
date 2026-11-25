"""Diamond pet draw: one transaction, summon energy, and idempotent retry."""
from __future__ import annotations

import asyncio
import uuid

import pytest

from app import pet_draw, shop, trial


class FakeConn:
    def __init__(self):
        self.wallet = shop.Wallet(diamond_paid=500, diamond_free=50, coin=0)
        self.owned: set[str] = set()
        self.misses = 0
        self.draws: dict[uuid.UUID, dict] = {}
        self.money_writes: list[dict] = []
        self.grants: list[str] = []
        self.cards: list[tuple[str, int]] = []

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
                "trial_target": args[7], "trial_days": args[8],
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

    # 047 体验卡：没抽中默认「只给游戏币」，要测卡的用例自己改 roll_miss。
    monkeypatch.setattr(trial, "roll_miss", lambda: (True, 0))

    async def add_cards(c, _player, target, days, count, kind, **kw):
        assert kind == "pet_draw" and count == 1 and kw.get("draw_id")
        c.cards.append((target, days))
        return 1

    monkeypatch.setattr(trial, "add_cards", add_cards)
    return conn


def test_miss_replay_and_tenth_draw(draw_db, monkeypatch):
    monkeypatch.setattr(pet_draw.secrets, "randbelow", lambda _: 1)
    monkeypatch.setattr(pet_draw.secrets, "choice", lambda available: available[0])
    player = uuid.uuid4()
    draw_id = uuid.uuid4()

    miss = asyncio.run(pet_draw.draw(player, draw_id))
    assert miss.pet_id == "" and miss.coin_reward == 100 and miss.energy == 1
    assert miss.wallet.diamond == 475 and miss.wallet.coin == 100
    assert draw_db.money_writes == [
        {"diamond_free": -50, "diamond_paid": -25}, {"coin": 100}]

    replay = asyncio.run(pet_draw.draw(player, draw_id))
    assert replay.replayed and replay.draw_id == miss.draw_id
    assert len(draw_db.money_writes) == 2

    draw_db.misses = 9
    win = asyncio.run(pet_draw.draw(player, uuid.uuid4()))
    assert win.pet_id == "pet_squirrel" and win.energy == 0
    assert win.coin_reward == 0 and draw_db.grants == ["pet_squirrel"]
    state = asyncio.run(pet_draw.state(player))
    assert state.available == ["pet_tiger", "pet_monkey"]


def test_early_pet_keeps_energy_and_never_repeats_owned_pet(draw_db, monkeypatch):
    monkeypatch.setattr(pet_draw.secrets, "randbelow", lambda _: 0)
    monkeypatch.setattr(pet_draw.secrets, "choice", lambda available: available[0])
    player = uuid.uuid4()
    draw_db.misses = 3

    first = asyncio.run(pet_draw.draw(player, uuid.uuid4()))
    assert first.pet_id == "pet_squirrel" and first.energy == 4
    assert draw_db.owned == {"pet_squirrel"}

    second = asyncio.run(pet_draw.draw(player, uuid.uuid4()))
    assert second.pet_id == "pet_tiger" and second.energy == 5

    # 11-25 奖池加了猴子：第三抽抽到它，之后奖池才算抽完。
    third = asyncio.run(pet_draw.draw(player, uuid.uuid4()))
    assert third.pet_id == "pet_monkey" and third.energy == 6
    assert draw_db.grants == ["pet_squirrel", "pet_tiger", "pet_monkey"]

    charged_count = len(draw_db.money_writes)
    with pytest.raises(shop.ShopRejected) as complete:
        asyncio.run(pet_draw.draw(player, uuid.uuid4()))
    assert complete.value.code == "pool_complete"
    assert len(draw_db.money_writes) == charged_count
    assert draw_db.misses == 6


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


def test_miss_can_give_a_trial_card_for_an_unowned_pet(draw_db, monkeypatch):
    """047：没抽中时三选一。只给卡 = 不给游戏币；两样都给 = 游戏币 + 卡；卡挑的是还没拥有的奖池宠物。"""
    monkeypatch.setattr(pet_draw.secrets, "randbelow", lambda _: 1)
    monkeypatch.setattr(pet_draw.secrets, "choice", lambda available: available[-1])
    draw_db.owned = {"pet_squirrel"}
    player = uuid.uuid4()

    monkeypatch.setattr(trial, "roll_miss", lambda: (False, 3))
    card_only = asyncio.run(pet_draw.draw(player, uuid.uuid4()))
    assert card_only.pet_id == "" and card_only.coin_reward == 0
    # 没拥有的奖池宠物是 [老虎, 猴子]，假 choice 取最后一个。
    assert (card_only.trial_target, card_only.trial_days) == ("pet_monkey", 3)
    assert draw_db.money_writes == [{"diamond_free": -50, "diamond_paid": -25}]

    monkeypatch.setattr(trial, "roll_miss", lambda: (True, 7))
    draw_id = uuid.uuid4()
    both = asyncio.run(pet_draw.draw(player, draw_id))
    assert both.coin_reward == 100 and (both.trial_target, both.trial_days) == ("pet_monkey", 7)
    assert draw_db.cards == [("pet_monkey", 3), ("pet_monkey", 7)]

    replay = asyncio.run(pet_draw.draw(player, draw_id))
    assert replay.replayed and (replay.trial_target, replay.trial_days) == ("pet_monkey", 7)
    assert len(draw_db.cards) == 2


def test_trial_card_odds_shown_to_players_match_the_server():
    """047：没抽中时的三选一与体验卡天数也要公示（同 test_iap 钉着的抽中概率）。改了 trial.py 两边一起改。"""
    import pathlib
    dialog = (pathlib.Path(__file__).resolve().parents[2] / "scenes" / "menu" / "PetDrawDialog.gd").read_text(
        encoding="utf-8")
    outcomes = dict(trial.MISS_OUTCOMES)
    assert "只得 %d 金币 %d%%" % (pet_draw.MISS_COIN, outcomes["coin"]) in dialog
    assert "只得宠物体验卡 %d%%" % outcomes["card"] in dialog
    assert "两样都得 %d%%" % outcomes["both"] in dialog
    for days, weight in trial.DAY_WEIGHTS:
        assert "%d天 %d%%" % (days, weight) in dialog
        assert "%dd %d%%" % (days, weight) in dialog


def test_summon_dialog_lists_every_pool_pet():
    """11-25：召唤界面左栏的宠物卡（PetDrawDialog.POOL_PETS）要和服务器奖池一致，加宠物时两边一起改。"""
    import pathlib
    import re
    dialog = (pathlib.Path(__file__).resolve().parents[2] / "scenes" / "menu" / "PetDrawDialog.gd").read_text(
        encoding="utf-8")
    listed = re.search(r"const POOL_PETS := \[([^\]]*)\]", dialog)
    assert listed, "PetDrawDialog.gd 里找不到 POOL_PETS"
    assert tuple(re.findall(r'"([^"]+)"', listed.group(1))) == pet_draw.PET_IDS
