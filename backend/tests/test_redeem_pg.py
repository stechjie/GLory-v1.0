"""兑换码在真 PostgreSQL 上的行为（底座见 pg_harness.py；没设 GLORY_TEST_PG 整组跳过）。

  · 两边的规范化对得上（后台建码存的是 SQL 规范化的，玩家填码比的是 Python 规范化的）
  · 防爆破只数「码不存在」
  · 并发不超发；同一个人同时填同一活动的两个码，只领到一个，而且不是 500
  · 后台：建码要另一个人批、撤回一个人就行，撤回之后填不了

跑：
    GLORY_TEST_PG=postgresql://postgres@localhost:5432/postgres \\
        backend/.venv/Scripts/python.exe -m pytest backend/tests/test_redeem_pg.py -q
"""

from __future__ import annotations

import asyncio
import pathlib
import uuid

import asyncpg
import pytest

from app import admin, db, mail, redeem, shop
from app.admin_auth import Admin
from app.config import get_settings
from pg_harness import new_player, requires_pg, run_with_db

pytestmark = requires_pg

SOLD = [i.grants for i in shop.items()]
ARVIN = Admin(auth_uid=uuid.UUID(int=1), name="arvin")
LENO = Admin(auth_uid=uuid.UUID(int=2), name="leno")


@pytest.fixture(autouse=True)
def _fresh(monkeypatch: pytest.MonkeyPatch):
    for key in ("GLORY_REDEEM_FAILURE_LIMIT", "GLORY_REDEEM_FAILURE_WINDOW_SECONDS"):
        monkeypatch.delenv(key, raising=False)
    get_settings.cache_clear()
    redeem._limiter_cache = None
    yield
    get_settings.cache_clear()
    redeem._limiter_cache = None


async def _warm_pool() -> None:
    """并发之前先把连接池借满再还（原因见 test_invites_pg._warm_pool）。"""
    conns = [await db.pool().acquire() for _ in range(db.pool().get_max_size())]
    for conn in conns:
        await db.pool().release(conn)


async def _make(conn: asyncpg.Connection, code: str, *, max_uses: int | None = 100, diamond: int = 100, coin: int = 0,
                items: list[str] | None = None, campaign: str | None = None, days: int = 30,
                starts_in_hours: int = 0) -> int:
    return int(await conn.fetchval(
        "select create_redeem_code(p_code => $1, p_max_uses => $2, p_actor => 'pytest', p_diamond => $3,"
        " p_coin => $4, p_items => $5, p_days => $6, p_campaign => $7,"
        " p_starts_at => now() + make_interval(hours => $8))",
        code, max_uses, diamond, coin, items or [], days, campaign, starts_in_hours))


async def _rejected(code: str, coro) -> None:
    with pytest.raises(redeem.RedeemRejected) as exc:
        await coro
    assert exc.value.code == code, exc.value.message


# --- 规范化 ---------------------------------------------------------------------


def test_python_and_sql_normalize_agree_on_ascii() -> None:
    """🔴 后台建码时存的是 SQL 规范化的结果，玩家填码时比的是 Python 规范化的结果。两边不一致 = 码永远对不上。"""

    async def body() -> None:
        samples = ["glory2026", " GLORY-2026 ", "gl-or-y 20 26", "\tabc\n123 ", "A-B-C-D", "x", "ab_cd", ""]
        async with db.pool().acquire() as conn:
            for raw in samples:
                assert await conn.fetchval("select glory_normalize_redeem_code($1)", raw) == redeem.normalize(raw), raw

    run_with_db(body)


# --- 领取 -----------------------------------------------------------------------


def test_claim_sends_a_mail_and_the_mail_pays_into_free_diamonds() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            code_id = await _make(conn, "GLORY2026", diamond=100, coin=300, items=SOLD[:1])
        got = await redeem.claim(p, "glory-2026")
        assert (got.diamond, got.coin, got.items) == (100, 300, tuple(SOLD[:1]))
        async with db.pool().acquire() as conn:
            row = await conn.fetchrow("select * from mails where mail_id = $1", got.mail_id)
            assert (row["player_id"], row["diamond"], row["coin"], row["actor"]) == (p, 100, 300, "redeem")
            assert await conn.fetchval("select used_count from redeem_codes where code_id = $1", code_id) == 1
            assert await conn.fetchval(
                "select mail_id from redeem_claims where code_id = $1 and player_id = $2", code_id, p) == got.mail_id
        await mail.claim(p, got.mail_id)
        async with db.pool().acquire() as conn:
            wallet = await shop.read_wallet_in(conn, p)
        assert (wallet.diamond_paid, wallet.diamond_free) == (0, 100), "进赠送列，不进付费列"

    run_with_db(body)


def test_rejections() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p, q = await new_player(conn), await new_player(conn)
            await _make(conn, "ONCE", max_uses=1)
            await _make(conn, "NOVA", campaign="nov")
            await _make(conn, "NOVB", campaign="nov")
            await _make(conn, "LATER", starts_in_hours=5)
            await _make(conn, "PULLED")
            await conn.execute("select withdraw_redeem_code('PULLED')")
            await _make(conn, "BADITEM", items=["not_a_real_item"])
            await _make(conn, "OLDIE")
            await conn.execute("update redeem_codes set starts_at = now() - interval '2 days',"
                               " expires_at = now() - interval '1 day' where code = 'OLDIE'")

        await redeem.claim(p, "ONCE")
        await _rejected("redeem_already_claimed", redeem.claim(p, "ONCE"))
        await _rejected("redeem_used_up", redeem.claim(q, "ONCE"))
        await redeem.claim(p, "NOVA")
        await _rejected("redeem_campaign_claimed", redeem.claim(p, "NOVB"))
        await redeem.claim(q, "NOVB")  # 互斥是按人的，别人照样能领
        await _rejected("redeem_not_started", redeem.claim(p, "LATER"))
        await _rejected("redeem_expired", redeem.claim(p, "PULLED"))
        await _rejected("redeem_expired", redeem.claim(p, "OLDIE"))
        await _rejected("redeem_unavailable", redeem.claim(p, "BADITEM"))
        await _rejected("redeem_invalid", redeem.claim(p, "NOPE"))
        await _rejected("redeem_invalid", redeem.claim(p, "a!"))
        async with db.pool().acquire() as conn:
            assert await conn.fetchval("select used_count from redeem_codes where code = 'BADITEM'") == 0, \
                "附件发不出去时不能白扣一次"

    run_with_db(body)


def test_only_missing_codes_count_toward_the_lockout(monkeypatch) -> None:
    monkeypatch.setenv("GLORY_REDEEM_FAILURE_LIMIT", "3")
    get_settings.cache_clear()

    async def body() -> None:
        async with db.pool().acquire() as conn:
            p, other = await new_player(conn), await new_player(conn)
            await _make(conn, "REAL")
            await _make(conn, "GONE")
            await conn.execute("select withdraw_redeem_code('GONE')")
        # 过期、格式不对的不数：试多少次都不锁。
        for _ in range(5):
            await _rejected("redeem_expired", redeem.claim(p, "GONE"))
            await _rejected("redeem_invalid", redeem.claim(p, "!!"))
        for guess in ("AAAA", "BBBB", "CCCC"):
            await _rejected("redeem_invalid", redeem.claim(p, guess))
        with pytest.raises(redeem.RedeemLocked):
            await redeem.claim(p, "REAL")  # 锁住之后连真码也先不让试 —— 不然爆破的人能拿它当探针
        assert (await redeem.claim(other, "REAL")).diamond == 100, "按账号锁，不连坐别人"

    run_with_db(body)


# --- 并发 -----------------------------------------------------------------------


def test_many_players_at_once_never_oversell() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            code_id = await _make(conn, "RUSH", max_uses=3)
            people = [await new_player(conn) for _ in range(10)]
        await _warm_pool()
        results = await asyncio.gather(*(redeem.claim(p, "RUSH") for p in people), return_exceptions=True)
        assert sum(isinstance(r, redeem.Claimed) for r in results) == 3
        assert {r.code for r in results if isinstance(r, Exception)} == {"redeem_used_up"}
        async with db.pool().acquire() as conn:
            assert await conn.fetchval("select used_count from redeem_codes where code_id = $1", code_id) == 3
            assert await conn.fetchval("select count(*) from redeem_claims where code_id = $1", code_id) == 3

    run_with_db(body)


def test_same_player_two_codes_of_one_campaign_at_once_gets_one_and_no_500() -> None:
    """两个码各锁各的行，互相挡不住 —— 挡住这种情况的是按人排队那把锁。

    没有它的话，两边都查到「这个活动没领过」，后插的撞唯一索引，玩家看到 HTTP 500。
    """

    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            await _make(conn, "DUOA", campaign="duo")
            await _make(conn, "DUOB", campaign="duo")
        await _warm_pool()
        results = await asyncio.gather(redeem.claim(p, "DUOA"), redeem.claim(p, "DUOB"), return_exceptions=True)
        assert sum(isinstance(r, redeem.Claimed) for r in results) == 1, results
        others = [r for r in results if not isinstance(r, redeem.Claimed)]
        assert all(isinstance(r, redeem.RedeemRejected) for r in others),             "另一个请求必须是正常的业务拒绝，不能是撞唯一索引（那就是玩家看到的 500）：%r" % others
        assert [r.code for r in others] == ["redeem_campaign_claimed"]

    run_with_db(body)


# --- 后台 -----------------------------------------------------------------------


def _draft(**kw) -> admin.RedeemDraft:
    base = dict(mode="code", code="Glory 2026", max_uses=500, count=0, campaign="", diamond=100, coin=0,
                items=(), days=14, starts_at="", note="11 月活动")
    base.update(kw)
    return admin.RedeemDraft(**base)


def test_admin_code_needs_a_second_person_and_withdraw_needs_one() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
        queued = await admin.request_redeem(ARVIN, _draft(), uuid.uuid4())
        assert queued["queued"] and queued["status"] == "pending"
        assert "最多一共发出 50,000 钻石" in queued["summary"]
        async with db.pool().acquire() as conn:
            assert await conn.fetchval("select count(*) from redeem_codes") == 0, "没批之前一个码都不能有"

        with pytest.raises(admin.AdminRejected):
            await admin.decide(ARVIN, queued["request_id"], True, "")  # 自己不能批自己
        done = await admin.decide(LENO, queued["request_id"], True, "")
        assert done["result"]["code"] == "GLORY2026"
        async with db.pool().acquire() as conn:
            row = await conn.fetchrow("select actor, max_uses, note from redeem_codes where code = 'GLORY2026'")
        assert row["actor"] == "arvin/leno" and row["max_uses"] == 500
        assert (await redeem.claim(p, "GLORY2026")).diamond == 100

        with pytest.raises(admin.AdminRejected):
            await admin.request_redeem(ARVIN, _draft(), uuid.uuid4())  # 重名在申请时就挡下

        assert (await admin.withdraw_redeem(ARVIN, "glory2026", None)) == {"withdrawn": 1}  # 一个人就行
        await _rejected("redeem_expired", redeem.claim(p, "GLORY2026"))
        groups = await admin.recent_redeem()
        assert [(g["code"], g["used"], g["withdrawn"]) for g in groups] == [("GLORY2026", 1, 1)]

    run_with_db(body)


def test_unlimited_code_never_runs_out_but_each_player_still_gets_one() -> None:
    """不限人数（045，11-04 用户定）：后台批出来 max_uses 是 null；领多少次都不会「已领完」，一人仍只能一次。

    🔴 领取那条条件 update 写成 `used_count < max_uses` 的话，和 null 比是 null —— 一次都领不了。
    """

    async def body() -> None:
        queued = await admin.request_redeem(ARVIN, _draft(code="OPEN2026", max_uses=None), uuid.uuid4())
        assert "不限人数" in queued["summary"] and "最多一共发出" not in queued["summary"]
        await admin.decide(LENO, queued["request_id"], True, "")
        async with db.pool().acquire() as conn:
            assert await conn.fetchval("select max_uses from redeem_codes where code = 'OPEN2026'") is None
            players = [await new_player(conn) for _ in range(6)]
        for p in players:
            assert (await redeem.claim(p, "OPEN2026")).diamond == 100
        await _rejected("redeem_already_claimed", redeem.claim(players[0], "OPEN2026"))
        async with db.pool().acquire() as conn:
            assert await conn.fetchval("select used_count from redeem_codes where code = 'OPEN2026'") == 6
        [group] = await admin.recent_redeem()
        assert group["max_uses"] is None and group["used"] == 6

        # 同一个活动里一个不限、一个限 100：整组是「不限」。sum 会悄悄跳过 null，算成一个偏小的 100。
        async with db.pool().acquire() as conn:
            await _make(conn, "MIXOPEN", max_uses=None, campaign="mix")
            await _make(conn, "MIXCAP", max_uses=100, campaign="mix")
        mixed = next(g for g in await admin.recent_redeem() if g["campaign"] == "mix")
        assert mixed["codes"] == 2 and mixed["max_uses"] is None, "列表要显示「不限」"

    run_with_db(body)


def test_admin_batch_is_one_campaign_exported_and_withdrawn_together() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
        queued = await admin.request_redeem(ARVIN, _draft(mode="batch", count=20, diamond=50), uuid.uuid4())
        done = await admin.decide(LENO, queued["request_id"], True, "")
        campaign = done["result"]["campaign"]
        assert campaign.startswith("batch_") and done["result"]["count"] == 20
        assert "codes" not in done["result"], "码是秘密，不进审批结果"

        codes = [r["code"] for r in await admin.export_redeem(LENO, campaign)]
        assert len(codes) == 20 and all(len(c) == 12 for c in codes)
        await redeem.claim(p, codes[0])
        await _rejected("redeem_campaign_claimed", redeem.claim(p, codes[1]))  # 一批只能领一个

        assert await admin.withdraw_redeem(ARVIN, None, campaign) == {"withdrawn": 20}
        async with db.pool().acquire() as conn:
            q = await new_player(conn)
            assert await conn.fetchval(
                "select count(*) from admin_audit where action in ('redeem.export', 'redeem.withdraw')") == 2
        await _rejected("redeem_expired", redeem.claim(q, codes[2]))

    run_with_db(body)


def test_migrations_can_be_run_twice_without_touching_data() -> None:
    """043–045 是手工在 Supabase 里跑的：跑两遍（或者跑到一半重跑）不能报错、也不能动已有数据。

    044 在 045 之后重跑，不能把 045 放开的「不限人数」改回去（建码函数两份要一致）。
    """

    async def body() -> None:
        root = pathlib.Path(__file__).resolve().parents[2] / "database"
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
            await _make(conn, "KEEP")
            await conn.execute("insert into player_invites (invitee, inviter) values ($1, $2)",
                               p, await new_player(conn))
            await _make(conn, "OPENKEEP", max_uses=None)
            for name in ("043_invites.sql", "044_redeem_codes.sql", "045_redeem_unlimited.sql", "044_redeem_codes.sql"):
                await conn.execute((root / name).read_text(encoding="utf-8"))
            assert await conn.fetchval("select count(*) from redeem_codes where code in ('KEEP', 'OPENKEEP')") == 2
            assert await conn.fetchval("select count(*) from player_invites") == 1
            await _make(conn, "OPENAGAIN", max_uses=None)

    run_with_db(body)
