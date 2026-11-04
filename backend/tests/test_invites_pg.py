"""邀请码在真 PostgreSQL 上的行为（底座见 pg_harness.py；没设 GLORY_TEST_PG 整组跳过）。

假连接证明不了的四件事都在这里：
  · 达到 5 级那一局真的给两边各发一封邮件，领了进赠送列，而且只发一次
  · 上限算「发了奖的」不算「绑定了的」，两个被邀请人同时达标也不会超
  · 🔴 发奖出错不回滚对局结算
  · 同一个被邀请人被两处同时发奖，只发一次

跑：
    GLORY_TEST_PG=postgresql://postgres@localhost:5432/postgres \\
        backend/.venv/Scripts/python.exe -m pytest backend/tests/test_invites_pg.py -q
"""

from __future__ import annotations

import asyncio
import uuid

import asyncpg
import pytest

from app import db, invites, mail, progression, shop
from app.config import get_settings
from pg_harness import new_player, requires_pg, run_with_db

pytestmark = requires_pg


@pytest.fixture(autouse=True)
def _fresh_settings(monkeypatch: pytest.MonkeyPatch):
    for key in ("GLORY_INVITE_ENABLED", "GLORY_INVITE_MAX_REWARDED"):
        monkeypatch.delenv(key, raising=False)
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


def _set(monkeypatch: pytest.MonkeyPatch, key: str, value: str) -> None:
    monkeypatch.setenv(key, value)
    get_settings.cache_clear()


async def _code(conn: asyncpg.Connection, player_id: uuid.UUID) -> str:
    return await conn.fetchval("select friend_code from players where player_id = $1", player_id)


async def _almost_level_five(conn: asyncpg.Connection, player_id: uuid.UUID) -> None:
    """4 级、差一局到 5 级（330 XP）。"""
    await conn.execute(
        "insert into player_progression (player_id, xp, level) values ($1, 320, 4)"
        " on conflict (player_id) do update set xp = 320, level = 4", player_id)


async def _play(player_id: uuid.UUID, match_uid: str) -> None:
    """一局休闲短局赢：+90 XP。和战报结算一样，在一个事务里调 award_match。"""
    async with db.pool().acquire() as conn, conn.transaction():
        await progression.award_match(conn, player_id, match_uid, "casual", 10, "win")


async def _invite_mails(conn: asyncpg.Connection, player_id: uuid.UUID) -> list[asyncpg.Record]:
    return await conn.fetch(
        "select mail_id, diamond, title_zh from mails where player_id = $1 and actor = 'invite' order by mail_id",
        player_id)


async def _row(conn: asyncpg.Connection, invitee: uuid.UUID) -> asyncpg.Record:
    return await conn.fetchrow("select * from player_invites where invitee = $1", invitee)


async def _warm_pool() -> None:
    """🔴 并发测试之前必须先调它。

    连接池初始只有 1 条连接（db.py 的 min_size=1），其余要现建 —— 建一条要几十毫秒，
    而一次发奖事务在本机只要几毫秒。不预热的话，第一个事务在别人还在建连接时就提交完了，
    「并发」的几个事务其实是一个接一个跑的，什么竞争都撞不出来，测试永远是绿的。
    （2026-11-03 拿掉上限锁验证过：不预热时这几条照样绿。）
    """
    conns = [await db.pool().acquire() for _ in range(db.pool().get_max_size())]
    for conn in conns:
        await db.pool().release(conn)


async def _rejected(code: str, coro) -> None:
    with pytest.raises(invites.InviteRejected) as exc:
        await coro
    assert exc.value.code == code, exc.value.message


# --- 填码 -----------------------------------------------------------------------


def test_bind_rules() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            me = await new_player(conn)
            friend = await new_player(conn, created_days_ago=100)
            old = await new_player(conn, created_days_ago=8)
            gone = await new_player(conn)
            friend_code = await _code(conn, friend)
            gone_code = await _code(conn, gone)
            await conn.execute("select erase_player($1)", gone)
            my_code = await _code(conn, me)

        await _rejected("invite_code_invalid", invites.bind(me, "ABC"))
        await _rejected("invite_code_not_found", invites.bind(me, "ZZZZ2222"))
        await _rejected("invite_code_not_found", invites.bind(me, gone_code))  # 注销后旧码不认
        await _rejected("invite_self", invites.bind(me, my_code))
        await _rejected("invite_window_closed", invites.bind(old, friend_code))

        # 全角 + 小写 + 空格（中文输入法打出来的样子）也要对得上。
        fullwidth = "".join(chr(ord(c) + 0xFEE0) for c in friend_code.lower()[:4]) + " " + friend_code[4:]
        status = await invites.bind(me, fullwidth)
        assert status.bound and not status.can_bind and not status.rewarded
        await _rejected("invite_already_bound", invites.bind(me, friend_code))

        async with db.pool().acquire() as conn:
            assert (await _row(conn, me))["inviter"] == friend
        assert (await invites.status(old)).can_bind is False, "过了 7 天，入口不该出现"

    run_with_db(body)


def test_double_tap_bind_is_one_row_not_a_500() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            me = await new_player(conn)
            code = await _code(conn, await new_player(conn))
        await _warm_pool()
        results = await asyncio.gather(invites.bind(me, code), invites.bind(me, code), return_exceptions=True)
        assert sum(isinstance(r, invites.Status) for r in results) == 1
        assert [r.code for r in results if isinstance(r, Exception)] == ["invite_already_bound"]

    run_with_db(body)


# --- 发奖 -----------------------------------------------------------------------


def test_reaching_level_five_pays_both_once_into_free_diamonds() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            me = await new_player(conn)
            friend = await new_player(conn, created_days_ago=30)
            code = await _code(conn, friend)
        await invites.bind(me, code)
        async with db.pool().acquire() as conn:
            await _almost_level_five(conn, me)
        await _play(me, "m-1")

        async with db.pool().acquire() as conn:
            row = await _row(conn, me)
            assert row["rewarded_at"] is not None and row["inviter_skipped"] is None
            mine, theirs = await _invite_mails(conn, me), await _invite_mails(conn, friend)
            assert [m["diamond"] for m in mine] == [50] and [m["diamond"] for m in theirs] == [100]
            assert row["invitee_mail"] == mine[0]["mail_id"] and row["inviter_mail"] == theirs[0]["mail_id"]

        await _play(me, "m-2")  # 已经发过：再升经验也不再发
        async with db.pool().acquire() as conn:
            assert len(await _invite_mails(conn, me)) == 1 and len(await _invite_mails(conn, friend)) == 1

        await mail.claim(me, mine[0]["mail_id"])
        async with db.pool().acquire() as conn:
            wallet = await shop.read_wallet_in(conn, me)
        # 5 级本身没有钻石奖励（DIAMOND_BY_LEVEL 是 7、15 级），所以赠送列里就是邀请这 50。
        assert (wallet.diamond_paid, wallet.diamond_free) == (0, 50), "邮件的钻石进赠送列，不进付费列"
        assert (await invites.status(me)).rewarded

    run_with_db(body)


def test_binding_after_already_level_five_pays_on_the_spot() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            me = await new_player(conn)
            friend = await new_player(conn)
            code = await _code(conn, friend)
        await _play_to_five(me)
        status = await invites.bind(me, code)
        assert status.rewarded
        async with db.pool().acquire() as conn:
            assert len(await _invite_mails(conn, friend)) == 1

    async def _play_to_five(player: uuid.UUID) -> None:
        async with db.pool().acquire() as conn:
            await _almost_level_five(conn, player)
        await _play(player, "pre-%s" % player)

    run_with_db(body)


def test_cap_counts_rewarded_not_bound(monkeypatch) -> None:
    """上限 1：两个人都能绑（绑定不占名额），第二个达标时被邀请人照拿、邀请人记 capped。"""
    _set(monkeypatch, "GLORY_INVITE_MAX_REWARDED", "1")

    async def body() -> None:
        async with db.pool().acquire() as conn:
            inviter = await new_player(conn)
            a, b, c = await new_player(conn), await new_player(conn), await new_player(conn)
            code = await _code(conn, inviter)
        for p in (a, b, c):
            await invites.bind(p, code)  # 三个都能绑：烧不掉别人的名额
        for p in (a, b):
            async with db.pool().acquire() as conn:
                await _almost_level_five(conn, p)
            await _play(p, "m-%s" % p)
        async with db.pool().acquire() as conn:
            assert (await _row(conn, a))["inviter_skipped"] is None
            second = await _row(conn, b)
            assert second["inviter_skipped"] == "capped" and second["inviter_mail"] is None
            assert len(await _invite_mails(conn, b)) == 1, "上限只管邀请人，被邀请人照拿"
            assert [m["diamond"] for m in await _invite_mails(conn, inviter)] == [100]

    run_with_db(body)


def test_deleted_inviter_is_skipped_and_invitee_still_paid() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            me = await new_player(conn)
            friend = await new_player(conn)
            code = await _code(conn, friend)
        await invites.bind(me, code)
        async with db.pool().acquire() as conn:
            await conn.execute("select erase_player($1)", friend)
            await _almost_level_five(conn, me)
        await _play(me, "m-1")
        async with db.pool().acquire() as conn:
            row = await _row(conn, me)
            assert row["inviter_skipped"] == "deleted" and row["inviter_mail"] is None
            assert len(await _invite_mails(conn, me)) == 1

    run_with_db(body)


def test_switch_off_holds_rewards_until_switched_back_on(monkeypatch) -> None:
    """关总闸：不能再填；已经达标的先不发、留着；开回来之后的下一局照发（「达到或超过」）。"""

    async def body() -> None:
        async with db.pool().acquire() as conn:
            me = await new_player(conn)
            late = await new_player(conn)
            code = await _code(conn, await new_player(conn))
        await invites.bind(me, code)
        _set(monkeypatch, "GLORY_INVITE_ENABLED", "false")
        await _rejected("invite_disabled", invites.bind(late, code))
        assert (await invites.status(late)).can_bind is False
        async with db.pool().acquire() as conn:
            await _almost_level_five(conn, me)
        await _play(me, "m-1")
        async with db.pool().acquire() as conn:
            assert (await _row(conn, me))["rewarded_at"] is None

        _set(monkeypatch, "GLORY_INVITE_ENABLED", "true")
        await _play(me, "m-2")  # 已经 5 级了，不是「刚好跨过」也要发
        async with db.pool().acquire() as conn:
            assert (await _row(conn, me))["rewarded_at"] is not None

    run_with_db(body)


def test_payout_failure_never_rolls_back_the_match(monkeypatch) -> None:
    """🔴 发奖那一段炸了：对局经验照常提交，邀请留着没发，修好之后的下一局补上。"""

    async def body() -> None:
        async with db.pool().acquire() as conn:
            me = await new_player(conn)
            code = await _code(conn, await new_player(conn))
        await invites.bind(me, code)
        async with db.pool().acquire() as conn:
            await _almost_level_five(conn, me)

        good = invites._SEND
        monkeypatch.setattr(invites, "_SEND", good.replace("insert into mails", "insert into mails_gone"))
        await _play(me, "m-broken")
        async with db.pool().acquire() as conn:
            prog = await conn.fetchrow("select xp, level from player_progression where player_id = $1", me)
            assert (prog["xp"], prog["level"]) == (410, 5), "对局经验必须照常进账"
            assert await conn.fetchval(
                "select count(*) from level_up_events where player_id = $1 and match_uid = 'm-broken'", me) == 1
            assert (await _row(conn, me))["rewarded_at"] is None

        monkeypatch.setattr(invites, "_SEND", good)
        await _play(me, "m-fixed")
        async with db.pool().acquire() as conn:
            assert (await _row(conn, me))["rewarded_at"] is not None

    run_with_db(body)


# --- 并发 -----------------------------------------------------------------------


async def _reward_in_own_transaction(invitee: uuid.UUID) -> bool:
    async with db.pool().acquire() as conn, conn.transaction():
        return await invites.maybe_reward(conn, invitee, 5)


def test_two_payouts_for_one_invitee_at_once_pay_once() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            me = await new_player(conn)
            friend = await new_player(conn)
            code = await _code(conn, friend)
        await invites.bind(me, code)
        await _warm_pool()
        results = await asyncio.gather(*(_reward_in_own_transaction(me) for _ in range(4)))
        assert sorted(results) == [False, False, False, True]
        async with db.pool().acquire() as conn:
            assert len(await _invite_mails(conn, me)) == 1 and len(await _invite_mails(conn, friend)) == 1

    run_with_db(body)


def test_invitees_reaching_level_at_once_do_not_exceed_the_cap(monkeypatch) -> None:
    """不加邀请人锁的话，几个人同时达标都会数到 0，邀请人一下拿好几份。

    「数邀请人已经拿了几份」那条语句里塞 0.3 秒 pg_sleep：快照在语句开始时就取了，
    没有锁的话 5 个事务一定都在别人提交之前数完 —— 竞争**必然**发生，不靠调度碰运气。
    （只预热连接池时，拿掉锁之后这条三次里只红一次。）
    """
    _set(monkeypatch, "GLORY_INVITE_MAX_REWARDED", "1")
    monkeypatch.setattr(invites, "_INVITER",
                        invites._INVITER.replace("select p.deleted_at", "select pg_sleep(0.3), p.deleted_at"))

    async def body() -> None:
        async with db.pool().acquire() as conn:
            inviter = await new_player(conn)
            friends = [await new_player(conn) for _ in range(5)]
            code = await _code(conn, inviter)
        for f in friends:
            await invites.bind(f, code)
        await _warm_pool()
        assert all(await asyncio.gather(*(_reward_in_own_transaction(f) for f in friends)))
        async with db.pool().acquire() as conn:
            assert len(await _invite_mails(conn, inviter)) == 1
            assert await conn.fetchval(
                "select count(*) from player_invites where inviter = $1 and inviter_skipped = 'capped'", inviter) == 4

    run_with_db(body)
