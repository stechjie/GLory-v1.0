"""体验卡在真 PostgreSQL 上的行为（底座见 pg_harness.py；没设 GLORY_TEST_PG 整组跳过）。

规则见 backend/app/trial.py 开头（2026-11-20 用户拍板）。最要紧的几条：

  1. 🔴 体验不是拥有：用了种族卡，归属表里不能出现那个种族（否则一张卡换永久种族），
     但出战校验（存种族、出战名片）要认它。
  2. 每个账号、每个种族、每周 1/3/7 天各只能买一次；买到的卡进背包、不自动使用。
  3. 用卡往后叠；出售按天数给游戏币；同一个 client_op_id 重发只执行一次。
  4. 到期后有一次提醒，弹过就不再弹；永久拥有了就不提醒。

跑：
    GLORY_TEST_PG=postgresql://postgres@localhost:54329/postgres \\
        python -m pytest backend/tests/test_trial_pg.py -q -p no:cacheprovider
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest

from app import db, loadout, pet_draw, shop, skin_draw, trial
from pg_harness import new_player, requires_pg, run_with_db

pytestmark = requires_pg


async def _coin(conn, p: uuid.UUID, amount: int) -> None:
    async with conn.transaction():
        wallet = await shop._lock_wallet(conn, p)
        await shop._apply(conn, p, wallet, {"coin": amount}, "grant", None, actor="pytest")


async def _cards(p: uuid.UUID) -> dict[tuple[str, int], int]:
    return {(c.target, c.days): c.count for c in (await trial.bag(p)).cards}


def test_race_card_is_bought_once_per_week_used_and_never_becomes_ownership() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            await _coin(conn, p, 1000)
        op = uuid.uuid4()
        bought = await trial.buy_race(p, op, "dark", 3)
        assert bought.count == 1 and bought.coin_delta == -200 and bought.wallet.coin == 800
        # 同一个操作号重发：原样回，不再扣钱
        again = await trial.buy_race(p, op, "dark", 3)
        assert again.replayed and again.wallet.coin == 800 and again.count == 1
        # 本周再买同样天数：拒；别的天数可以
        with pytest.raises(shop.ShopRejected) as limit:
            await trial.buy_race(p, uuid.uuid4(), "dark", 3)
        assert limit.value.code == "weekly_limit"
        await trial.buy_race(p, uuid.uuid4(), "dark", 1)
        offer = await trial.race_offer(p, "dark")
        assert offer.bought == [1, 3] and not offer.owned and offer.trial_expires_at is None
        assert await _cards(p) == {("dark", 1): 1, ("dark", 3): 1}

        # 没用之前不能出战
        assert "dark" not in await trial.read_usable(p)
        used = await trial.use(p, uuid.uuid4(), "dark", 3)
        assert used.count == 0
        assert dt.timedelta(days=2, hours=23) < used.expires_at - dt.datetime.now(dt.timezone.utc) \
            <= dt.timedelta(days=3)
        # 叠加：再用 1 天卡，到期往后推 1 天
        stacked = await trial.use(p, uuid.uuid4(), "dark", 1)
        assert stacked.expires_at - used.expires_at == dt.timedelta(days=1)
        assert await _cards(p) == {}

        # 🔴 体验不是拥有
        assert "dark" not in await shop.read_entitlements(p)
        assert "dark" in await trial.read_usable(p)
        async with db.pool().acquire() as conn:
            assert not await shop._owns(conn, p, "dark")
            # 不满 4 个种族时自动带上（同集齐解锁）
            assert "dark" in await conn.fetchval("select selected_races from players where player_id = $1", p)
        assert "dark" in (await loadout.build_loadout(p)).races
        bag = await trial.bag(p)
        assert [(t.target, t.kind) for t in bag.trials] == [("dark", "race")]

    run_with_db(body)


def test_buy_rejects_owned_race_and_missing_coin_without_charging() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            await _coin(conn, p, 50)
        with pytest.raises(shop.ShopRejected) as poor:
            await trial.buy_race(p, uuid.uuid4(), "god", 1)
        assert poor.value.code == "insufficient_funds"
        async with db.pool().acquire() as conn:
            await shop._grant(conn, p, "god", "grant", None)
            await _coin(conn, p, 1000)
        with pytest.raises(shop.ShopRejected) as owned:
            await trial.buy_race(p, uuid.uuid4(), "god", 1)
        assert owned.value.code == "already_owned"
        with pytest.raises(shop.ShopRejected) as bad:
            await trial.buy_race(p, uuid.uuid4(), "pet_cat", 1)
        assert bad.value.code == "unknown_target"
        assert (await shop.read_wallet(p)).coin == 1050
        # 这两次都没占掉本周额度
        assert (await trial.race_offer(p, "undead")).bought == []

    run_with_db(body)


def test_sell_pays_by_days_and_owned_target_card_can_only_be_sold() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            async with conn.transaction():
                await shop._lock_wallet(conn, p)
                await trial.add_cards(conn, p, "pet_cat", 7, 2, "grant")
                await trial.add_cards(conn, p, "prep_skin_sakura", 1, 1, "grant")
            await shop._grant(conn, p, "pet_cat", "shop", None)
        cards = {c.target: c for c in (await trial.bag(p)).cards}
        assert cards["pet_cat"].owned and cards["pet_cat"].sell_price == 300
        with pytest.raises(shop.ShopRejected) as owned:
            await trial.use(p, uuid.uuid4(), "pet_cat", 7)
        assert owned.value.code == "already_owned"

        op = uuid.uuid4()
        sold = await trial.sell(p, op, "pet_cat", 7, 2)
        assert sold.coin_delta == 600 and sold.count == 0 and sold.wallet.coin == 600
        assert (await trial.sell(p, op, "pet_cat", 7, 2)).replayed
        assert (await shop.read_wallet(p)).coin == 600
        with pytest.raises(shop.ShopRejected) as none_left:
            await trial.sell(p, uuid.uuid4(), "prep_skin_sakura", 1, 2)
        assert none_left.value.code == "no_card"
        with pytest.raises(shop.ShopRejected) as conflict:
            await trial.sell(p, op, "prep_skin_sakura", 1, 1)
        assert conflict.value.code == "op_conflict"
        async with db.pool().acquire() as conn:
            ledger = await conn.fetchval(
                "select sum(delta) from wallet_ledger where player_id = $1 and source = 'trial_sell'", p)
            assert ledger == 600

    run_with_db(body)


def test_trial_skin_and_pet_can_be_equipped_and_fall_back_when_expired() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            await shop._grant(conn, p, "pet_cat", "starter_pick", None)
            async with conn.transaction():
                await shop._lock_wallet(conn, p)
                await trial.add_cards(conn, p, "pet_tiger", 1, 1, "grant")
                await trial.add_cards(conn, p, "prep_skin_sakura", 1, 1, "grant")
        with pytest.raises(loadout.LoadoutRejected):
            await loadout.save_prep_skin(p, "prep_skin_sakura")
        await trial.use(p, uuid.uuid4(), "pet_tiger", 1)
        await trial.use(p, uuid.uuid4(), "prep_skin_sakura", 1)
        pets = await shop.set_active_pet(p, "pet_tiger")
        assert pets.active == "pet_tiger" and "pet_tiger" in pets.trials
        assert not pets.needs_starter_pick
        assert await loadout.save_prep_skin(p, "prep_skin_sakura") == "prep_skin_sakura"
        card = await loadout.build_loadout(p)
        assert card.pet == "pet_tiger" and card.prep_skin == "prep_skin_sakura"

        # 到期：出战名片退回永久拥有的宠物、默认皮肤；read_pets 和名片说的是同一只
        async with db.pool().acquire() as conn:
            await conn.execute("update player_trials set expires_at = now() - interval '1 minute'"
                               " where player_id = $1", p)
        card = await loadout.build_loadout(p)
        assert card.pet == "pet_cat" and card.prep_skin == ""
        assert (await shop.read_pets(p)).active == "pet_cat"
        assert await loadout.read_prep_skin(p) is None

        # 到期提醒：弹一次；确认过就不再弹
        notices = await trial.expired_notices(p)
        assert sorted(n.target for n in notices) == ["pet_tiger", "prep_skin_sakura"]
        assert await trial.ack_notices(p, ["pet_tiger", "prep_skin_sakura"]) == 2
        assert await trial.expired_notices(p) == []

    run_with_db(body)


def test_expired_race_is_noticed_once_and_owned_race_is_not() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            async with conn.transaction():
                await shop._lock_wallet(conn, p)
                await trial.add_cards(conn, p, "undead", 1, 2, "grant")
                await trial.add_cards(conn, p, "god", 1, 1, "grant")
        await trial.use(p, uuid.uuid4(), "undead", 1)
        await trial.use(p, uuid.uuid4(), "god", 1)
        # 还没到期：没有提醒，确认也不会误标
        assert await trial.expired_notices(p) == []
        assert await trial.ack_notices(p, ["undead"]) == 0
        async with db.pool().acquire() as conn:
            await conn.execute("update player_trials set expires_at = now() - interval '1 minute'"
                               " where player_id = $1", p)
            # god 后来永久拿到了：不提醒
            await shop._grant(conn, p, "god", "grant", None)
        assert [n.target for n in await trial.expired_notices(p)] == ["undead"]
        assert "undead" not in (await loadout.build_loadout(p)).races
        # 再用一张续上：提醒状态清掉，重新可用
        renewed = await trial.use(p, uuid.uuid4(), "undead", 1)
        assert renewed.expires_at > dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=23)
        assert await trial.expired_notices(p) == []

    run_with_db(body)


def test_draw_cards_land_in_the_bag_and_survive_the_new_constraints(monkeypatch) -> None:
    """047 的约束在真库上放行「只给卡、不给游戏币」的回执；卡进背包。"""
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            async with conn.transaction():
                wallet = await shop._lock_wallet(conn, p)
                await shop._apply(conn, p, wallet, {"diamond_free": 1000}, "grant", None, actor="pytest")
        monkeypatch.setattr(trial, "roll_miss", lambda: (False, 3))
        monkeypatch.setattr(pet_draw.secrets, "randbelow", lambda _n: 5)   # 宠物没中
        receipt = await pet_draw.draw(p, uuid.uuid4())
        assert receipt.pet_id == "" and receipt.coin_reward == 0 and receipt.trial_days == 3
        assert receipt.trial_target in pet_draw.PET_IDS

        monkeypatch.setattr(skin_draw.secrets, "randbelow", lambda n: 99 if n == 100 else 0)  # 没出碎片，游戏币最低档
        monkeypatch.setattr(trial, "roll_miss", lambda: (True, 7))
        wish = await skin_draw.draw(p, "prep_skin_sakura", uuid.uuid4())
        assert wish.shards_gained == 0 and wish.coin_reward > 0 and wish.trial_days == 7
        assert await _cards(p) == {(receipt.trial_target, 3): 1, ("prep_skin_sakura", 7): 1}
        async with db.pool().acquire() as conn:
            kinds = sorted(r["kind"] for r in await conn.fetch(
                "select kind from trial_card_ops where player_id = $1", p))
            assert kinds == ["pet_draw", "skin_draw"]

    run_with_db(body)


def test_week_starts_monday_beijing_time() -> None:
    # 2026-11-22 是周日。北京时间周日 23:30 还在本周；周一 00:10 已经是下一周。
    sunday_night = dt.datetime(2026, 11, 22, 15, 30, tzinfo=dt.timezone.utc)   # 北京 23:30
    monday_early = dt.datetime(2026, 11, 22, 16, 10, tzinfo=dt.timezone.utc)   # 北京 周一 00:10
    assert trial.week_start(sunday_night) == dt.date(2026, 11, 16)
    assert trial.week_start(monday_early) == dt.date(2026, 11, 23)
    assert trial.week_resets_at(sunday_night) == dt.datetime(2026, 11, 22, 16, 0, tzinfo=dt.timezone.utc)


def test_miss_roll_respects_the_published_weights() -> None:
    assert sum(w for _, w in trial.MISS_OUTCOMES) == 100
    assert sum(w for _, w in trial.DAY_WEIGHTS) == 100
    seen = {trial.roll_miss() for _ in range(5000)}
    assert all(coin or days for coin, days in seen), "没抽中至少给一样"
    assert {days for _, days in seen} == {0, 1, 3, 7}


def test_routes_round_trip_through_real_handlers() -> None:
    """接口层：背包 / 购买 / 使用 / 出售 / 到期提醒 / 归属里的 trials 字段，字段名是客户端认的那几个。"""
    import types

    from app.routes import shop as shop_routes
    from app.routes import trial as trial_routes
    from pg_harness import auth_uid_of

    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            await _coin(conn, p, 500)
        claims = types.SimpleNamespace(auth_uid=auth_uid_of(p))
        offer = await trial_routes.race_offer("dark", claims)
        assert offer.prices == {"1": 100, "3": 200, "7": 300} and offer.bought == []
        bought = await trial_routes.buy_race_trial(
            trial_routes.BuyBody(client_op_id=uuid.uuid4(), race="dark", days=7), claims)
        assert bought.coin == 200 and bought.count == 1
        bag = await trial_routes.my_bag(claims)
        assert [(c.target, c.kind, c.days, c.count) for c in bag.cards] == [("dark", "race", 7, 1)]
        used = await trial_routes.use_card(
            trial_routes.UseBody(client_op_id=uuid.uuid4(), target="dark", days=7), claims)
        assert used.expires_at.endswith("Z") and used.count == 0
        ent = await shop_routes.entitlements(claims)
        assert "dark" not in ent.items and set(ent.trials) == {"dark"}
        with pytest.raises(trial_routes.HTTPException) as again:
            await trial_routes.buy_race_trial(
                trial_routes.BuyBody(client_op_id=uuid.uuid4(), race="dark", days=7), claims)
        assert again.value.status_code == 409
        assert again.value.headers["X-Glory-Reason"] == "weekly_limit"
        assert (await trial_routes.expired(claims)).items == []

    run_with_db(body)
