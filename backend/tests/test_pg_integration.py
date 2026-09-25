"""真 PostgreSQL 上的行为用例（底座见 pg_harness.py；没设 GLORY_TEST_PG 整组跳过）。

这里放的是假连接证明不了的东西：database/ 里的函数真跑一遍、两个事务真撞在一起。

跑（本机测试库，见 pg_harness 顶部）：
    GLORY_TEST_PG=postgresql://postgres@localhost:54329/postgres \\
        backend/.venv/Scripts/python.exe -m pytest backend/tests/test_pg_integration.py -q
"""

from __future__ import annotations

import asyncio
import uuid

import asyncpg
import pytest

from app import bans, db, mail, players, profile, shop
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
