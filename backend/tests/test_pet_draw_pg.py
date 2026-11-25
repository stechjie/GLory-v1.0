"""宠物抽取在真 PostgreSQL 上（底座见 pg_harness.py；没设 GLORY_TEST_PG 整组跳过）。

2026-11-25 奖池加猴子（pet_monkey）。数据库里没有任何地方列举宠物 id ——
pet_draws.pet_id、player_entitlements.item_id、player_trial_cards.target 只限长度，
players.showcase_pet 只限格式（004 的 showcase_pet_format）；奖池在 backend/app/pet_draw.py，
目录在 data/shop.json、data/pets/pets.json —— 所以加宠物**不用新迁移**。
这组测试在跑完 database/ 全部迁移的真库上把这件事钉住：

  1. 以前集齐松鼠 + 白虎（「奖池已全部拥有」）的老玩家能接着抽，库里存的能量（misses 列）照常用；
  2. 抽到的猴子进归属表，能设出战、进出战名片；三只都有了又回到「已全部拥有」；
  3. 猴子体验卡（没抽中时发的那种）能用、能出战。

跑：
    GLORY_TEST_PG=postgresql://postgres@localhost:54329/postgres \\
        python -m pytest backend/tests/test_pet_draw_pg.py -q -p no:cacheprovider
"""

from __future__ import annotations

import uuid

import pytest

from app import db, loadout, pet_draw, shop, trial
from pg_harness import new_player, requires_pg, run_with_db

pytestmark = requires_pg


async def _diamonds(conn, p: uuid.UUID, amount: int) -> None:
    async with conn.transaction():
        wallet = await shop._lock_wallet(conn, p)
        await shop._apply(conn, p, wallet, {"diamond_free": amount}, "grant", None, actor="pytest")


def test_old_pool_owner_draws_the_monkey_and_can_field_it() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            await shop._grant(conn, p, "pet_squirrel", "pet_draw", None)
            await shop._grant(conn, p, "pet_tiger", "pet_draw", None)
            await _diamonds(conn, p, pet_draw.PRICE)
            # 老玩家库里留着的能量原样接着用：差一抽保底
            await conn.execute("insert into pet_draw_progress (player_id, misses) values ($1, $2)",
                               p, pet_draw.PITY_LIMIT - 1)
        assert (await pet_draw.state(p)).available == ["pet_monkey"]

        receipt = await pet_draw.draw(p, uuid.uuid4())
        assert receipt.pet_id == "pet_monkey" and receipt.energy == 0 and receipt.wallet.diamond == 0
        async with db.pool().acquire() as conn:
            row = await conn.fetchrow(
                "select pet_id, price_snapshot, misses_after from pet_draws where player_id = $1", p)
            assert dict(row) == {"pet_id": "pet_monkey", "price_snapshot": pet_draw.PRICE, "misses_after": 0}
            assert await conn.fetchval(
                "select source from player_entitlements where player_id = $1 and item_id = 'pet_monkey'"
                " and revoked_at is null", p) == "pet_draw"

        # 三只都有了：再抽是「奖池已全部拥有」，先于余额判断
        with pytest.raises(shop.ShopRejected) as complete:
            await pet_draw.draw(p, uuid.uuid4())
        assert complete.value.code == "pool_complete"

        assert (await shop.set_active_pet(p, "pet_monkey")).active == "pet_monkey"
        assert (await loadout.build_loadout(p)).pet == "pet_monkey"

    run_with_db(body)


def test_monkey_trial_card_can_be_fielded() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            await shop._grant(conn, p, "pet_cat", "starter_pick", None)
            async with conn.transaction():
                await shop._lock_wallet(conn, p)
                await trial.add_cards(conn, p, "pet_monkey", 1, 1, "grant")
        # 卡在背包里、还没用：不能出战
        with pytest.raises(shop.ShopRejected):
            await shop.set_active_pet(p, "pet_monkey")
        await trial.use(p, uuid.uuid4(), "pet_monkey", 1)
        pets = await shop.set_active_pet(p, "pet_monkey")
        assert pets.active == "pet_monkey" and "pet_monkey" in pets.trials
        assert (await loadout.build_loadout(p)).pet == "pet_monkey"

    run_with_db(body)
