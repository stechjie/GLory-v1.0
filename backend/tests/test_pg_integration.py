"""真 PostgreSQL 上的行为用例（底座见 pg_harness.py；没设 GLORY_TEST_PG 整组跳过）。

这里放的是假连接证明不了的东西：database/ 里的函数真跑一遍、两个事务真撞在一起。

跑（本机测试库，见 pg_harness 顶部）：
    GLORY_TEST_PG=postgresql://postgres@localhost:54329/postgres \\
        backend/.venv/Scripts/python.exe -m pytest backend/tests/test_pg_integration.py -q
"""

from __future__ import annotations

import asyncio
import datetime as dt
import json
import pathlib
import uuid

import asyncpg
import pytest

from app import bans, battle_report, db, iap, mail, players, profile, schema_check, shop
from pg_harness import auth_uid_of, new_player, requires_pg, run_with_db

pytestmark = requires_pg

SOLD = [i.grants for i in shop.items()]


async def _send_mail(conn: asyncpg.Connection, player_id: uuid.UUID, *, diamond: int = 0,
                     items: list[str] | None = None) -> int:
    code = await conn.fetchval("select friend_code from players where player_id = $1", player_id)
    return int(await conn.fetchval(
        "select send_mail(p_friend_code => $1, p_title_zh => '补偿', p_body_zh => '正文',"
        " p_actor => 'pytest', p_diamond => $2, p_items => $3)",
        code, diamond, items or []))


# --- 009 手工发钻石 --------------------------------------------------------------


def test_grant_diamonds_writes_balance_and_ledger_together() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            after = await conn.fetchval("select grant_diamonds($1, 500, '补偿', 'pytest')", p)
            assert after == 500
            wallet = await shop.read_wallet_in(conn, p)
            assert (wallet.diamond_paid, wallet.diamond_free) == (0, 500)
            rows = await conn.fetch("select currency, delta, balance_after, source, actor from wallet_ledger"
                                    " where player_id = $1", p)
            assert [tuple(r) for r in rows] == [("diamond_free", 500, 500, "grant", "pytest")]
            with pytest.raises(asyncpg.RaiseError):
                await conn.fetchval("select grant_diamonds($1, -5, 'x', 'pytest')", p)
            with pytest.raises(asyncpg.RaiseError):
                await conn.fetchval("select grant_diamonds($1, 5, 'x', ' ')", p)

    run_with_db(body)


# --- 012 邮件：领取与撤回 🔴 -------------------------------------------------------


def test_claim_after_withdrawal_pays_nothing() -> None:
    """★ 玩家打开邮箱看到了这封，管理员随后撤回，玩家再点领取 —— 一分钱都不能到账。"""

    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn, created_days_ago=1)
            mail_id = await _send_mail(conn, p, diamond=300)
            # 事务外的可见性检查已经过了（玩家手上的列表里有它）……
            seen = await mail._visible(conn, p, mail_id)
            # ……这时管理员撤回。
            await conn.execute("select withdraw_mail($1)", mail_id)
            with pytest.raises(mail.MailRejected):
                async with conn.transaction():
                    await mail._claim_locked(conn, p, seen)
            assert (await shop.read_wallet_in(conn, p)).diamond == 0
            assert await conn.fetchval("select count(*) from wallet_ledger where player_id = $1", p) == 0
            assert await conn.fetchval(
                "select claimed_at from mail_states where player_id = $1 and mail_id = $2", p, mail_id) is None

    run_with_db(body)


def test_withdrawal_waits_for_a_claim_already_in_progress() -> None:
    """领取先锁住：撤回要等它提交。结果是「领到了、然后撤回」，账上一笔、邮件标撤回。"""

    async def body() -> None:
        async with db.pool().acquire() as a, db.pool().acquire() as b:
            p = await new_player(a, created_days_ago=1)
            mail_id = await _send_mail(a, p, diamond=300)
            seen = await mail._visible(a, p, mail_id)
            tx = a.transaction()
            await tx.start()
            await mail._claim_locked(a, p, seen)
            withdraw = asyncio.create_task(b.execute("select withdraw_mail($1)", mail_id))
            await asyncio.sleep(0.3)
            assert not withdraw.done(), "撤回没有等领取提交"
            await tx.commit()
            await withdraw
            assert (await shop.read_wallet_in(a, p)).diamond_free == 300
            assert await a.fetchval("select withdrawn_at is not null from mails where mail_id = $1", mail_id)

    run_with_db(body)


def test_claim_all_skips_withdrawn_and_pays_the_rest_once() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn, created_days_ago=1)
            keep = await _send_mail(conn, p, diamond=10)
            gone = await _send_mail(conn, p, diamond=99)
            await conn.execute("select withdraw_mail($1)", gone)
        result = await mail.claim_all(p)
        assert result.mail_ids == (keep,)
        assert result.wallet.diamond_free == 10
        again = await mail.claim_all(p)
        assert again.mail_ids == ()
        assert again.wallet.diamond_free == 10

    run_with_db(body)


def test_two_devices_claiming_at_once_pay_once() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn, created_days_ago=1)
            mail_id = await _send_mail(conn, p, diamond=50, items=SOLD[:1])
        results = await asyncio.gather(mail.claim(p, mail_id), mail.claim(p, mail_id))
        assert sorted(r.replayed for r in results) == [False, True]
        async with db.pool().acquire() as conn:
            assert (await shop.read_wallet_in(conn, p)).diamond_free == 50
            assert await conn.fetchval("select count(*) from wallet_ledger where player_id = $1", p) == 1

    run_with_db(body)


# --- 015 赛季结算（此前从没在真库上跑过）---------------------------------------------


def test_settle_season_archives_rewards_resets_and_is_idempotent() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            winner = await new_player(conn)
            idle = await new_player(conn)
            await conn.execute(
                "insert into ranked_seasons (season, started_at, ends_at)"
                " values (1, now() - interval '30 days', now() - interval '1 minute')")
            await conn.execute("insert into ranked_season_rewards (season, tier, diamond) values (1, 2, 200)")
            await conn.execute(
                "insert into player_ranked (player_id, season, score, games, wins) values"
                " ($1, 1, 250, 10, 7), ($2, 1, 0, 0, 0)", winner, idle)

            assert await conn.fetchval("select settle_season(1, 'pytest')") == 1
            history = await conn.fetch(
                "select player_id, tier, score from player_ranked_history where season = 1 order by score desc")
            assert [(r["player_id"], r["tier"], r["score"]) for r in history] == [(winner, 2, 250), (idle, 0, 0)]
            reward = await conn.fetchrow("select diamond, actor from mails where player_id = $1", winner)
            assert (reward["diamond"], reward["actor"]) == (200, "pytest")
            assert await conn.fetchval("select count(*) from mails where player_id = $1", idle) == 0
            ranked = await conn.fetchrow("select season, score, games from player_ranked where player_id = $1", winner)
            assert tuple(ranked) == (2, 0, 0)

            # 第二次：认领不到，一行都不再动。
            assert await conn.fetchval("select settle_season(1, 'pytest')") == -1
            assert await conn.fetchval("select count(*) from mails") == 1

    run_with_db(body)


# --- 016 封号 -------------------------------------------------------------------


async def _friend_code(conn: asyncpg.Connection, player_id: uuid.UUID) -> str:
    return str(await conn.fetchval("select friend_code from players where player_id = $1", player_id))


def test_ban_blocks_every_identity_lookup_until_unbanned() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            code = await _friend_code(conn, p)
            assert (await players.get_by_auth_uid(auth_uid_of(p))).player_id == p

            # 好友码带空格、小写也认（同 send_mail）。
            await conn.fetchval(
                "select ban_player(p_friend_code => $1, p_duration => interval '7 days',"
                " p_reason => '使用外挂', p_actor => 'pytest', p_note => '举报 #12')",
                " " + code.lower() + " ")
            with pytest.raises(bans.AccountBanned) as exc:
                await players.get_by_auth_uid(auth_uid_of(p))
            assert exc.value.ban.reason == "使用外挂"
            assert exc.value.ban.ends_at is not None
            with pytest.raises(bans.AccountBanned):
                await players.resolve_or_create(auth_uid_of(p))

            # 再叠一条永久的：取最晚结束的那条（永久）。
            await conn.fetchval(
                "select ban_player(p_friend_code => $1, p_duration => null, p_reason => '盗号', p_actor => 'pytest')",
                code)
            with pytest.raises(bans.AccountBanned) as exc:
                await players.get_by_auth_uid(auth_uid_of(p))
            assert exc.value.ban.ends_at is None and exc.value.ban.reason == "盗号"

            # 解封撤销全部生效的两条，行都还在。
            assert await conn.fetchval(
                "select unban_player(p_friend_code => $1, p_actor => 'pytest', p_note => '误封')", code) == 2
            assert (await players.get_by_auth_uid(auth_uid_of(p))).player_id == p
            assert await conn.fetchval("select count(*) from player_bans where player_id = $1", p) == 2
            assert await conn.fetchval(
                "select count(*) from player_bans where player_id = $1 and revoked_by = 'pytest'", p) == 2
            with pytest.raises(asyncpg.RaiseError):
                await conn.fetchval("select unban_player(p_friend_code => $1, p_actor => 'pytest')", code)

    run_with_db(body)


def test_expired_ban_no_longer_blocks_and_bad_input_is_refused() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            code = await _friend_code(conn, p)
            await conn.execute(
                "insert into player_bans (player_id, created_at, ends_at, reason, actor)"
                " values ($1, now() - interval '2 days', now() - interval '1 day', '旧的', 'pytest')", p)
            assert (await players.get_by_auth_uid(auth_uid_of(p))).player_id == p
            for args in [
                (code, "1 day", "x", " "),          # 没操作人
                (code, "1 day", " ", "pytest"),     # 没原因
                (code, "-1 day", "x", "pytest"),    # 负时长
                ("ZZZZZZZZ", "1 day", "x", "pytest"),  # 没这个人
            ]:
                with pytest.raises(asyncpg.RaiseError):
                    await conn.fetchval("select ban_player($1, $2::text::interval, $3, $4)", *args)

    run_with_db(body)


def test_online_sweep_finds_only_banned_players() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            good = await new_player(conn)
            bad = await new_player(conn)
            await conn.fetchval("select ban_player($1, null, '外挂', 'pytest')", await _friend_code(conn, bad))
            found = await bans.live_bans_among(conn, [good, bad])
        assert list(found) == [bad]

    run_with_db(body)


def test_refresh_handoff_round_trip() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
        assert await bans.find_handoff("T0") is None
        await bans.hold_handoff("T0", p, "T1")
        await bans.hold_handoff("T0", p, "T2")   # 同一张旧凭证再来：覆盖
        assert await bans.find_handoff("T0") == bans.Handoff(p, "T2")
        async with db.pool().acquire() as conn:
            stored = await conn.fetchval("select token_hash from ban_refresh_handoff")
        assert stored == bans.token_hash("T0") and "T0" not in stored

    run_with_db(body)


def test_missing_ban_tables_do_not_lock_everyone_out() -> None:
    """★ 部署时忘了跑 016：照常放行（表都没有，本来也封不了人），不能变成全员 500。"""

    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            await conn.execute("drop table ban_refresh_handoff; drop table player_bans")
        assert (await players.get_by_auth_uid(auth_uid_of(p))).player_id == p
        assert (await players.resolve_or_create(auth_uid_of(p))).player_id == p
        assert await bans.find_handoff("T0") is None
        async with db.pool().acquire() as conn:
            assert await bans.live_bans_among(conn, [p]) == {}

    run_with_db(body)


# --- 017 注销：删资料、留账目 -------------------------------------------------------


# --- 013 / 023 对局历史 -----------------------------------------------------------


def _report(match_uid: str, pids: list, settlement: dict | None) -> dict:
    """battle_report.verify() 验完之后的那种字典（这里不签名，直接给 record()）。"""
    now = dt.datetime.now(dt.UTC)
    return {
        "match_uid": match_uid, "mode": "custom", "protocol": 36, "server_epoch": 1, "room_id": 123456,
        "started_at": now - dt.timedelta(minutes=20), "ended_at": now, "rounds": 21,
        "outcome": "team_b", "team_a_hp": 0, "team_b_hp": 17,
        "gold_authoritative": False, "carrot_authoritative": True,
        "seats": [
            {"slot": slot, "team": 0 if slot < 3 else 1, "player_id": pid,
             "was_ai": pid is None, "online_at_end": pid is not None, "ai_rounds": 0,
             "gold": 10, "carrots": 1, "carrots_spent": 2,
             "board": json.dumps([{"slot": 4, "id": "unit_dark_dragon", "star": 3, "merc": False}]),
             "treasures": "[]"}
            for slot, pid in enumerate(pids)
        ],
        "settlement": settlement,
    }


def test_match_history_has_settlement_and_current_names() -> None:
    """023：详细战况原样存、原样取；名字按账号取现在的（改名后显示新名字，注销显示「已注销玩家」）。"""
    async def body() -> None:
        async with db.pool().acquire() as conn:
            me = await new_player(conn)
            mate = await new_player(conn)
            await conn.execute("update players set player_name = '旧名字' where player_id = $1", me)
        settlement = {
            "allies": ["圣骑守护", ""],
            "stats": [{"own": 3, "slot": 4, "id": "unit_dark_dragon", "name": "暗黑巨龙", "star": 3,
                       "merc": False, "stack": 1, "dmg": 999, "taken": 5, "heal": 0}],
            "seats": [{"stones": {"sky": 1}, "total_gold": 300 + slot} for slot in range(6)],
        }
        pids = [None, mate, None, me, None, None]
        assert await battle_report.record(_report("c" * 32, pids, settlement)) is True
        assert await battle_report.record(_report("d" * 32, pids, None)) is True   # 旧版本战报

        async with db.pool().acquire() as conn:
            await conn.execute("update players set player_name = '新名字' where player_id = $1", me)
        assert await profile.delete_player(mate) is True

        matches = {m["match_uid"]: m for m in await battle_report.list_for_player(me, 20)}
        detailed = matches["c" * 32]
        assert detailed["my_slot"] == 3
        assert detailed["settlement"] == settlement
        by_slot = {s["slot"]: s for s in detailed["seats"]}
        assert by_slot[3]["player_name"] == "新名字" and by_slot[3]["friend_code"]
        assert by_slot[1]["player_name"] == "已注销玩家"
        assert by_slot[0]["player_name"] is None and by_slot[0]["was_ai"] is True
        assert matches["d" * 32]["settlement"] is None

    run_with_db(body)


def test_erase_player_removes_identity_and_social_but_keeps_the_books() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            friend = await new_player(conn)
            old_code = await _friend_code(conn, p)
            low, high = sorted([p, friend])
            await conn.execute("insert into player_bio (player_id, gender, region) values ($1, 'male', 'MY')", p)
            await conn.execute(
                "insert into player_friendships (low_id, high_id, requested_by, status, accepted_at)"
                " values ($1, $2, $1, 'accepted', now())",
                low, high)
            await conn.execute("insert into chat_conversations (low_id, high_id) values ($1, $2)", low, high)
            await conn.execute(
                "insert into chat_messages (low_id, high_id, sender_id, body, client_msg_id)"
                " values ($1, $2, $3, 'hi', gen_random_uuid()), ($1, $2, $4, 'yo', gen_random_uuid())",
                low, high, p, friend)
            await conn.execute("update players set player_name = '张三', showcase_pet = 'pet_cat' where player_id = $1", p)
            await conn.fetchval("select grant_diamonds($1, 100, '补偿', 'pytest')", p)
            await conn.fetchval("select ban_player($1, null, '外挂', 'pytest')", old_code)
            await bans.hold_handoff("T0", p, "T1")

        assert await profile.delete_player(p) is True
        assert await profile.delete_player(p) is False   # 重复注销：什么都不再动

        async with db.pool().acquire() as conn:
            row = await conn.fetchrow(
                "select player_name, showcase_pet, friend_code, deleted_at from players where player_id = $1", p)
            assert row["player_name"] == "已注销玩家" and row["showcase_pet"] is None
            assert row["deleted_at"] is not None
            assert row["friend_code"] != old_code
            assert await conn.fetchval("select count(*) from players where friend_code = $1", old_code) == 0
            for table, where in [
                ("player_bio", "player_id = $1"),
                ("player_identities", "player_id = $1"),
                ("player_friendships", "low_id = $1 or high_id = $1"),
                ("chat_conversations", "low_id = $1 or high_id = $1"),
                ("chat_messages", "low_id = $1 or high_id = $1"),
                ("ban_refresh_handoff", "player_id = $1"),
            ]:
                assert await conn.fetchval("select count(*) from %s where %s" % (table, where), p) == 0, table
            # 账目都还在。
            assert await conn.fetchval("select count(*) from wallet_ledger where player_id = $1", p) == 1
            assert (await shop.read_wallet_in(conn, p)).diamond_free == 100
            assert await conn.fetchval("select count(*) from player_bans where player_id = $1", p) == 1
            # 好友那一边的资料不受影响。
            assert await conn.fetchval("select deleted_at from players where player_id = $1", friend) is None
        # 登录方式没了：这个 Auth 用户查不到这个号。
        assert await players.get_by_auth_uid(auth_uid_of(p)) is None

    run_with_db(body)


# --- 040 充值：入账、退款、欠账 🔴 ------------------------------------------------------


async def _iap_order(conn: asyncpg.Connection, player_id: uuid.UUID, product_id: str = "diamond_pack_3") -> uuid.UUID:
    """直接写一张待付款的 Google 单（建单那一步要看 .env 开关，这里只测入账之后的事）。"""
    order_id = uuid.uuid4()
    await conn.execute(
        "insert into iap_orders (order_id, player_id, client_order_id, platform, product_id)"
        " values ($1, $2, $3, 'google', $4)", order_id, player_id, uuid.uuid4(), product_id)
    return order_id


def _proof(order_id: uuid.UUID, external: str, environment: str = iap.PRODUCTION) -> iap.Proof:
    return iap.Proof(platform="google", order_id=order_id, product_id="diamond_pack_3",
                     external_id=external, environment=environment, purchase_token="tok-" + external)


async def _ledger_matches_wallet(conn: asyncpg.Connection, player_id: uuid.UUID) -> None:
    """钱包几列是流水的缓存（009 的注释）：每一列都必须等于那一列流水的总和。"""
    wallet = await shop.read_wallet_in(conn, player_id)
    for column in shop.COLUMNS:
        total = await conn.fetchval(
            "select coalesce(sum(delta), 0) from wallet_ledger where player_id = $1 and currency = $2",
            player_id, column)
        assert total == getattr(wallet, column), column


def test_iap_credit_refund_into_debt_and_repayment() -> None:
    """一整条：首充双倍入账 → 花掉 → 退款扣不回的记欠账 → 欠账时花不了 → 邮件先还欠账。"""

    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn, created_days_ago=1)
            first = await _iap_order(conn, p)
        outcome = await iap.credit(_proof(first, "ext-1"))
        assert outcome.order.first_bonus and outcome.wallet == shop.Wallet(500, 500, 0, 0)
        # 重放：一分钱不动。
        again = await iap.credit(_proof(first, "ext-1"))
        assert again.replayed and again.wallet == shop.Wallet(500, 500, 0, 0)

        async with db.pool().acquire() as conn:
            async with conn.transaction():
                wallet = await shop._lock_wallet(conn, p)
                await shop._apply(conn, p, wallet, {"diamond_free": -500, "diamond_paid": -300}, "pet_draw", None)

        refunded = await iap.refund("google", "ext-1", "voided")
        assert refunded.order.status == "refunded"
        assert refunded.wallet == shop.Wallet(0, 0, 0, 800) and refunded.wallet.diamond == -800
        assert (await iap.refund("google", "ext-1", "voided")).replayed, "通知重复推不重复扣"

        async with db.pool().acquire() as conn:
            mail_id = await _send_mail(conn, p, diamond=300)
            async with conn.transaction():
                await mail._claim_locked(conn, p, await mail._visible(conn, p, mail_id))
            assert await shop.read_wallet_in(conn, p) == shop.Wallet(0, 0, 0, 500), "邮件的钻石先还欠账"
            await _ledger_matches_wallet(conn, p)
            # 第二次买这一档：没有首充了，基础 500 全拿去还欠账，加送 60 进余额。
            second = await _iap_order(conn, p)
        outcome = await iap.credit(_proof(second, "ext-2"))
        assert not outcome.order.first_bonus
        assert outcome.wallet == shop.Wallet(0, 60, 0, 0)
        async with db.pool().acquire() as conn:
            await _ledger_matches_wallet(conn, p)

    run_with_db(body)


def test_debt_and_balance_cannot_coexist() -> None:
    """040 的 wallet_debt_exclusive：settle_debt 写错时宁可整笔失败，也不能「欠着 300 又有 500」。"""

    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            await conn.execute("insert into player_wallets (player_id, diamond_debt) values ($1, 300)", p)
            with pytest.raises(asyncpg.CheckViolationError):
                await conn.execute("update player_wallets set diamond_free = 10 where player_id = $1", p)
            with pytest.raises(asyncpg.CheckViolationError):
                await conn.execute("update player_wallets set diamond_debt = -1 where player_id = $1", p)

    run_with_db(body)


def test_two_orders_of_the_same_tier_at_once_double_only_once() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            a, b = await _iap_order(conn, p), await _iap_order(conn, p)
        results = await asyncio.gather(iap.credit(_proof(a, "ext-a")), iap.credit(_proof(b, "ext-b")))
        assert sorted(r.order.first_bonus for r in results) == [False, True]
        async with db.pool().acquire() as conn:
            assert (await shop.read_wallet_in(conn, p)).diamond == 500 + 500 + 500 + 60
            await _ledger_matches_wallet(conn, p)

    run_with_db(body)


def test_one_payment_cannot_land_on_two_orders() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            a, b = await _iap_order(conn, p), await _iap_order(conn, p)
        await iap.credit(_proof(a, "same"))
        with pytest.raises(iap.IapRejected) as exc:
            await iap.credit(_proof(b, "same"))
        assert exc.value.code == "proof_reused"
        async with db.pool().acquire() as conn:
            # 应用层那道漏了也还有唯一索引。
            with pytest.raises(asyncpg.UniqueViolationError):
                await conn.execute("update iap_orders set external_id = 'same' where order_id = $1", b)

    run_with_db(body)


def test_test_orders_go_free_and_stop_after_one_a_day() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            a, b = await _iap_order(conn, p), await _iap_order(conn, p)
        first = await iap.credit(_proof(a, "t-a", iap.SANDBOX))
        assert first.wallet == shop.Wallet(0, 1000, 0, 0)
        second = await iap.credit(_proof(b, "t-b", iap.SANDBOX))
        assert second.order.status == "cancelled" and second.order.note == "test_daily_limit"
        async with db.pool().acquire() as conn:
            assert await conn.fetchval("select count(*) from iap_first_bonus where player_id = $1", p) == 0
            await _ledger_matches_wallet(conn, p)

    run_with_db(body)


def test_iap_migration_can_be_run_twice() -> None:
    """040 是手工在 Supabase 里跑的，跑两遍（或者跑到一半重跑）不能报错、也不能动已有数据。"""

    async def body() -> None:
        sql = (pathlib.Path(__file__).resolve().parents[2] / "database" / "040_iap.sql").read_text(encoding="utf-8")
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            order = await _iap_order(conn, p)
            await conn.execute(sql)
            assert await conn.fetchval("select count(*) from iap_orders where order_id = $1", order) == 1

    run_with_db(body)


def test_startup_schema_check_is_clean_on_a_fully_migrated_database() -> None:
    """自检里新加的语句与探针在跑完全部迁移的库上必须全过 —— 否则部署后它会天天喊假警报。"""

    async def body() -> None:
        assert await schema_check.verify() == []

    run_with_db(body)
