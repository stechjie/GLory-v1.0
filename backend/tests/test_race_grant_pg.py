"""邮件 / 兑换码发「整族」在真 PostgreSQL 上的行为（底座见 pg_harness.py；没设 GLORY_TEST_PG 整组跳过）。

2026-11-04 用户定：后台能一次勾整个种族。整族只占一件附件，领的时候补齐这个人缺的棋子、种族跟着集齐解锁
（shop.grant_content）。🔴 不能只发种族那一行 —— 那样能拿这个种族出战，商城却把棋子当没买过继续卖。

跑：
    GLORY_TEST_PG=postgresql://postgres@localhost:5432/postgres \\
        backend/.venv/Scripts/python.exe -m pytest backend/tests/test_race_grant_pg.py -q
"""

from __future__ import annotations

import asyncio
import uuid

import asyncpg

from app import db, mail, redeem, shop
from pg_harness import new_player, requires_pg, run_with_db

pytestmark = requires_pg


def _parts(race: str) -> list[str]:
    return list(shop.content_item(race).requires)


async def _owned(conn: asyncpg.Connection, player_id: uuid.UUID) -> set[str]:
    rows = await conn.fetch(
        "select item_id from player_entitlements where player_id = $1 and revoked_at is null", player_id)
    return {r["item_id"] for r in rows}


async def _mail_to(conn: asyncpg.Connection, player_id: uuid.UUID, items: list[str]) -> int:
    return int(await conn.fetchval(
        "insert into mails (player_id, title_zh, body_zh, items, actor) values ($1, '补偿', '', $2, 'pytest')"
        " returning mail_id", player_id, items))


def test_whole_race_fills_the_missing_units_then_unlocks_the_race() -> None:
    async def body() -> None:
        dark = _parts("dark")
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            for part in dark[:3]:
                await shop._grant(conn, p, part, "shop", None)
            mail_id = await _mail_to(conn, p, ["dark"])
        result = await mail.claim(p, mail_id)
        assert set(result.granted) == {"dark", *dark[3:]}, "已经有的 3 个不算这次发的"
        assert result.skipped == ()
        async with db.pool().acquire() as conn:
            assert {"dark", *dark} <= await _owned(conn, p)
            # 早就有的那 3 个，来源还是当初买的那一笔（客服查「哪来的」不能被这封邮件盖掉）。
            assert await conn.fetchval(
                "select count(*) from player_entitlements where player_id = $1 and item_id = any($2::text[])"
                " and source = 'shop'", p, dark[:3]) == 3
            # 集齐解锁那条路的副作用照样有：新种族自动进出战选择。
            assert "dark" in await conn.fetchval("select selected_races from players where player_id = $1", p)

    run_with_db(body)


def test_whole_race_already_owned_is_skipped_like_any_owned_item() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            async with conn.transaction():
                for part in _parts("undead"):
                    await shop.grant_content(conn, p, part, "shop", None)
            assert "undead" in await _owned(conn, p)
            mail_id = await _mail_to(conn, p, ["undead"])
        result = await mail.claim(p, mail_id)
        assert result.granted == () and result.skipped == ("undead",)

    run_with_db(body)


def test_all_units_but_no_race_row_still_gets_the_race() -> None:
    """八个棋子全有、种族那一行缺着（绕过 grant_content 发的老数据）：整族补的就是这一行。"""

    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            for part in _parts("god"):
                await shop._grant(conn, p, part, "level_reward", None)
            assert "god" not in await _owned(conn, p)
            mail_id = await _mail_to(conn, p, ["god"])
        result = await mail.claim(p, mail_id)
        assert result.granted == ("god",)
        async with db.pool().acquire() as conn:
            assert "god" in await _owned(conn, p)

    run_with_db(body)


def test_one_redeem_code_can_carry_two_races_and_a_skin() -> None:
    """一个码最多 10 件附件；一族 8 个棋子，按棋子发两族就装不下 —— 整族算一件才装得下。"""

    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            await conn.execute(
                "select create_redeem_code(p_code => 'RACES2', p_max_uses => null, p_actor => 'pytest',"
                " p_items => array['dark', 'crimson', 'prep_skin_sakura'])")
        claimed = await redeem.claim(p, "RACES2")
        result = await mail.claim(p, claimed.mail_id)
        assert result.skipped == ()
        async with db.pool().acquire() as conn:
            owned = await _owned(conn, p)
        assert {"dark", "crimson", "prep_skin_sakura", *_parts("dark"), *_parts("crimson")} <= owned

    run_with_db(body)


def test_two_whole_race_mails_claimed_at_once_grant_once() -> None:
    """同一个人两台设备同时领两封都带「暗族」的邮件：不报错，归属不重复，种族只发一次。"""

    async def body() -> None:
        conns = [await db.pool().acquire() for _ in range(db.pool().get_max_size())]
        for conn in conns:
            await db.pool().release(conn)
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            first = await _mail_to(conn, p, ["dark"])
            second = await _mail_to(conn, p, ["dark"])
        results = await asyncio.gather(mail.claim(p, first), mail.claim(p, second))
        assert all(r.mail_ids for r in results)
        async with db.pool().acquire() as conn:
            assert await conn.fetchval(
                "select count(*) from player_entitlements where player_id = $1 and item_id = any($2::text[])",
                p, ["dark", *_parts("dark")]) == 9
            races = await conn.fetchval("select selected_races from players where player_id = $1", p)
            assert races.count("dark") == 1

    run_with_db(body)
