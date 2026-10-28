"""Real PostgreSQL regression for a receipt constraint rolling back all players."""
from pathlib import Path

import asyncpg
import pytest
from app import battle_report, db, ranked, schema_check
from pg_harness import new_player, requires_pg, run_with_db
from test_pg_integration import _report

pytestmark = requires_pg
MIGRATION = Path(__file__).resolve().parents[2] / "database/041_ranked_reward_coin_limit.sql"


async def six_players():
    async with db.pool().acquire() as conn:
        return [await new_player(conn) for _ in range(6)]


@pytest.mark.parametrize("rounds", [13, 21])
@pytest.mark.parametrize("roll", range(7))
def test_every_ranked_reward_amount_settles_all_six_once(monkeypatch, rounds, roll):
    monkeypatch.setattr(ranked.secrets, "randbelow", lambda n: min(roll, n - 1))

    async def body():
        players = await six_players()
        report = _report("e" * 32, players, None)
        report.update(mode="ranked", rounds=rounds, outcome="team_a")
        assert await battle_report.record(report)
        async with db.pool().acquire() as conn:
            rows = await conn.fetch("select result,coin from ranked_reward_receipts order by result")
            assert len(rows) == 6
            assert sorted(r["coin"] for r in rows if r["result"] == "win") == [15 + min(roll, 5)] * 3
            assert sorted(r["coin"] for r in rows if r["result"] == "lose") == [9 + roll] * 3
            wallets = list(await conn.fetch("select * from player_wallets order by player_id"))
            progression = list(await conn.fetch("select * from player_progression order by player_id"))
        for _ in players:
            assert not await battle_report.record(report)
        async with db.pool().acquire() as conn:
            assert await conn.fetchval("select count(*) from ranked_reward_receipts") == 6
            assert list(await conn.fetch("select * from player_wallets order by player_id")) == wallets
            assert list(await conn.fetch("select * from player_progression order by player_id")) == progression
            with pytest.raises(asyncpg.CheckViolationError):
                async with conn.transaction():
                    await conn.execute("update ranked_reward_receipts set coin=21")

    run_with_db(body)


def test_old_cap_rolls_back_everyone_and_migration_allows_retry(monkeypatch):
    monkeypatch.setattr(ranked.secrets, "randbelow", lambda n: n - 1)

    async def body():
        players = await six_players()
        report = _report("f" * 32, players, None)
        report.update(mode="ranked", outcome="team_a")
        async with db.pool().acquire() as conn:
            await conn.execute("alter table ranked_reward_receipts drop constraint ranked_reward_receipts_coin_check;"
                               "alter table ranked_reward_receipts add constraint ranked_reward_receipts_coin_check"
                               " check (coin between 3 and 15)")
        assert any("041" in issue for issue in await schema_check.verify())
        with pytest.raises(asyncpg.CheckViolationError):
            await battle_report.record(report)
        async with db.pool().acquire() as conn:
            for table in ["match_records", "ranked_reward_receipts", "wallet_ledger", "player_ranked"]:
                assert await conn.fetchval("select count(*) from " + table) == 0
            await conn.execute(MIGRATION.read_text(encoding="utf-8"))
            await conn.execute(MIGRATION.read_text(encoding="utf-8"))
        assert await schema_check.verify() == []
        assert await battle_report.record(report)
        assert not await battle_report.record(report)
        async with db.pool().acquire() as conn:
            assert await conn.fetchval("select count(*) from ranked_reward_receipts") == 6

    run_with_db(body)


@pytest.mark.parametrize("rounds", [13, 21])
def test_ranked_draw_still_pays_eleven_to_everyone(rounds):
    async def body():
        players = await six_players()
        report = _report("d" * 32, players, None)
        report.update(mode="ranked", rounds=rounds, outcome="draw")
        assert await battle_report.record(report)
        async with db.pool().acquire() as conn:
            rows = await conn.fetch("select result,coin from ranked_reward_receipts")
        assert len(rows) == 6 and all(r["result"] == "draw" and r["coin"] == 11 for r in rows)

    run_with_db(body)
