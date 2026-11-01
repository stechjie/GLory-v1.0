"""樱花祈愿（钻石抽棋盘皮肤碎片）：一个事务、第 10 抽补满、集满发皮肤、重发不重复扣钱、公示与规则一致。"""
from __future__ import annotations

import asyncio
import json
import pathlib
import uuid

import pytest

from app import shop, skin_draw

REPO = pathlib.Path(__file__).resolve().parents[2]
SKIN = "prep_skin_sakura"


class FakeConn:
    def __init__(self):
        self.wallet = shop.Wallet(diamond_paid=2000, diamond_free=50, coin=0)
        self.owned: set[str] = set()
        self.progress: dict | None = None
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
        if "from skin_draws" in sql:
            return self.draws.get(args[1])
        assert "from skin_draw_progress" in sql, sql
        return self.progress

    async def execute(self, sql, *args):
        if "insert into skin_draw_progress" in sql:
            self.progress = {"shards": args[2], "draws": args[3]}
        elif "insert into skin_draws" in sql:
            self.draws[args[2]] = {
                "draw_id": args[0], "skin_id": args[3], "shards_gained": args[4],
                "coin_reward": args[5], "shards_after": args[7], "draws_after": args[8],
                "unlocked": args[9],
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
    monkeypatch.setattr(skin_draw.db, "pool", lambda: Pool(conn))

    async def lock_wallet(c, _player):
        return c.wallet

    async def apply(c, _player, wallet, changes, source, _draw_id):
        assert source == "skin_draw"
        c.money_writes.append(changes.copy())
        c.wallet = shop.Wallet(
            wallet.diamond_paid + changes.get("diamond_paid", 0),
            wallet.diamond_free + changes.get("diamond_free", 0),
            wallet.coin + changes.get("coin", 0),
        )
        return c.wallet

    async def grant(c, _player, content_id, source, _draw_id):
        assert source == "skin_draw"
        c.owned.add(content_id)
        c.grants.append(content_id)

    async def owns(c, _player, content_id):
        return content_id in c.owned

    monkeypatch.setattr(shop, "_lock_wallet", lock_wallet)
    monkeypatch.setattr(shop, "_apply", apply)
    monkeypatch.setattr(shop, "_grant", grant)
    monkeypatch.setattr(shop, "_owns", owns)
    return conn


def _rolls(monkeypatch, values):
    """按顺序喂给 secrets.randbelow 的结果。"""
    queue = list(values)
    monkeypatch.setattr(skin_draw.secrets, "randbelow", lambda _n: queue.pop(0))
    return queue


def test_miss_pays_coin_and_replay_never_charges_twice(draw_db, monkeypatch):
    # 第一个数 ≥ 60 = 没出碎片；第二个数是游戏币档位（0..10 → 200..300）
    _rolls(monkeypatch, [75, 5])
    player = uuid.uuid4()
    draw_id = uuid.uuid4()

    miss = asyncio.run(skin_draw.draw(player, SKIN, draw_id))
    assert miss.shards_gained == 0 and miss.coin_reward == 250
    assert miss.shards == 0 and miss.draws == 1 and not miss.unlocked
    # 先扣赠送再扣付费（shop.split_charge）
    assert draw_db.money_writes == [{"diamond_free": -50, "diamond_paid": -50}, {"coin": 250}]

    replay = asyncio.run(skin_draw.draw(player, SKIN, draw_id))
    assert replay.replayed and replay.draw_id == miss.draw_id and replay.coin_reward == 250
    assert len(draw_db.money_writes) == 2


def test_tenth_draw_tops_up_to_ten_and_unlocks(draw_db, monkeypatch):
    _rolls(monkeypatch, [])   # 保底那一抽不掷骰
    player = uuid.uuid4()
    draw_db.progress = {"shards": 4, "draws": 9}

    receipt = asyncio.run(skin_draw.draw(player, SKIN, uuid.uuid4()))
    assert receipt.shards_gained == 6 and receipt.coin_reward == 0
    assert receipt.shards == 10 and receipt.draws == 10
    assert receipt.unlocked and receipt.owned and draw_db.grants == [SKIN]
    assert draw_db.money_writes == [{"diamond_free": -50, "diamond_paid": -50}]


def test_early_unlock_caps_at_ten_then_refuses_without_charging(draw_db, monkeypatch):
    # 每抽：< 60 出碎片；权重掷 90（≥ 50+35）→ 3 片
    _rolls(monkeypatch, [0, 90] * 4)
    player = uuid.uuid4()
    got = [asyncio.run(skin_draw.draw(player, SKIN, uuid.uuid4())) for _ in range(4)]
    assert [r.shards for r in got] == [3, 6, 9, 10]
    assert got[-1].shards_gained == 1, "超出 10 片的部分不发"
    assert got[-1].unlocked and draw_db.grants == [SKIN]

    charged = len(draw_db.money_writes)
    with pytest.raises(shop.ShopRejected) as owned:
        asyncio.run(skin_draw.draw(player, SKIN, uuid.uuid4()))
    assert owned.value.code == "already_owned"
    assert len(draw_db.money_writes) == charged


def test_rejected_draw_never_charges(draw_db):
    draw_db.wallet = shop.Wallet(0, 99, 0)
    with pytest.raises(shop.ShopRejected) as poor:
        asyncio.run(skin_draw.draw(uuid.uuid4(), SKIN, uuid.uuid4()))
    assert poor.value.code == "insufficient_funds"
    assert draw_db.money_writes == [] and draw_db.progress is None

    with pytest.raises(shop.ShopRejected) as unknown:
        asyncio.run(skin_draw.draw(uuid.uuid4(), "prep_skin_ice", uuid.uuid4()))
    assert unknown.value.code == "unknown_item"


def test_shard_roll_matches_published_table(monkeypatch):
    """randbelow(100) < 60 出碎片；权重 0..49 → 1 片、50..84 → 2 片、85..99 → 3 片。"""
    cases = {(59, 0): 1, (59, 49): 1, (0, 50): 2, (0, 84): 2, (0, 85): 3, (0, 99): 3}
    for (hit, weight), want in cases.items():
        _rolls(monkeypatch, [hit, weight])
        assert skin_draw._roll_shards() == want
    _rolls(monkeypatch, [60])
    assert skin_draw._roll_shards() == 0
    for step, coin in ((0, 200), (10, 300)):
        _rolls(monkeypatch, [step])
        assert skin_draw._roll_coin() == coin


def test_never_more_than_ten_draws_with_real_randomness():
    """真随机跑一万张：没有一张超过 PITY_LIMIT 抽，也没有一张超出 10 片。"""
    worst = 0
    for _ in range(10000):
        shards = draws = 0
        while shards < skin_draw.TARGET_SHARDS:
            gained, coin = skin_draw.outcome(shards, draws)
            assert (gained > 0) != (coin > 0)
            assert coin == 0 or skin_draw.MISS_COIN_MIN <= coin <= skin_draw.MISS_COIN_MAX
            shards += gained
            draws += 1
        assert shards == skin_draw.TARGET_SHARDS
        worst = max(worst, draws)
    assert worst <= skin_draw.PITY_LIMIT


def test_catalog_makes_sakura_draw_only():
    """樱花必须登记成「要归属、不直接卖」：漏了它就是免费皮肤，抽它等于收钱卖空气。"""
    for skin in skin_draw.SKIN_IDS:
        assert shop.requires_entitlement(skin)
        assert all(item.grants != skin for item in shop.items()), "%s 不该能直接买" % skin
    client = json.loads((REPO / "data" / "prep_skins.json").read_text(encoding="utf-8"))
    client_ids = {str(entry["id"]) for entry in client["skins"]}
    assert set(skin_draw.SKIN_IDS) <= client_ids
    assert "skin_draw" in shop.SOURCES


def test_odds_shown_to_players_match_the_server():
    """Google / Apple 要求付款前公示概率。公示文字写在客户端，真规则在 skin_draw.py —— 两边必须一致。"""
    dialog = (REPO / "scenes" / "menu" / "SkinWishDialog.gd").read_text(encoding="utf-8")
    total = sum(w for _, w in skin_draw.SHARD_WEIGHTS)
    for count, weight in skin_draw.SHARD_WEIGHTS:
        percent = skin_draw.SHARD_CHANCE_PERCENT * weight // total
        assert "碎片 ×%d  %d%%" % (count, percent) in dialog
        assert "%d shard%s  %d%%" % (count, "" if count == 1 else "s", percent) in dialog
    miss = 100 - skin_draw.SHARD_CHANCE_PERCENT
    assert "游戏币 %d～%d  %d%%" % (skin_draw.MISS_COIN_MIN, skin_draw.MISS_COIN_MAX, miss) in dialog
    assert "第 %d 抽" % skin_draw.PITY_LIMIT in dialog
    assert "PRICE := %d" % skin_draw.PRICE in dialog
    assert "TARGET := %d" % skin_draw.TARGET_SHARDS in dialog
