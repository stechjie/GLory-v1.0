"""21-round ranked format, race admission and mixed-rank parties. No live DB."""
import uuid
from types import SimpleNamespace
from unittest.mock import AsyncMock
import pytest
from app import loadout, matchmaking, party, ranked
from app.routes import matchmaking as routes
from app.routes import party as parties

@pytest.fixture
def anyio_backend(): return "asyncio"

@pytest.mark.parametrize("mode", ["ranked", "ranked_normal", "casual_normal", "casual"])
def test_card_schedule_matches_mode(mode):
    profile = loadout.Loadout(player_id=uuid.UUID(int=1), friend_code="ABCDEFGH", player_name="Test",
                             avatar="", avatar_frame="", pet="", races=["human", "god", "dark", "undead"])
    payload = loadout.card_payload(profile, match_uid="a" * 32, team=0, mode=mode)
    assert payload["ruleset"] == ("seedling" if mode == "casual" else "normal")

@pytest.mark.parametrize("normal", [False, True])
@pytest.mark.parametrize("count", [0, 1, 2, 3, 4])
def test_all_ranked_race_gates(normal, count):
    races = ["human", "god", "dark", "undead"][:count]
    if count >= 4:
        loadout.validate_ranked_races(races, normal)
    else:
        with pytest.raises(loadout.LoadoutRejected) as exc: loadout.validate_ranked_races(races, normal)
        assert exc.value.code == "ranked_need_four_races"

class Acquire:
    def __init__(self, conn): self.conn = conn
    async def __aenter__(self): return self.conn
    async def __aexit__(self, *args): pass

@pytest.mark.anyio
@pytest.mark.parametrize("mode", ["ranked", "ranked_normal"])
async def test_single_ranked_uses_one_queue(monkeypatch, mode):
    pid = uuid.UUID(int=1)
    mm = matchmaking.Matchmaker(AsyncMock(return_value=1))
    monkeypatch.setattr(routes, "_me", AsyncMock(return_value=SimpleNamespace(player_id=pid)))
    monkeypatch.setattr(routes, "_service_gate", AsyncMock())
    monkeypatch.setattr(routes, "_limit", lambda *args: None)
    monkeypatch.setattr(routes.db, "pool", lambda: SimpleNamespace(acquire=lambda: Acquire(SimpleNamespace())))
    monkeypatch.setattr(ranked, "queue_gate", AsyncMock(return_value=""))
    monkeypatch.setattr(loadout, "require_ranked_races", AsyncMock())
    monkeypatch.setattr(matchmaking, "current", lambda: mm)
    result = await routes.join_queue(routes.QueueBody(mode=mode), None)
    assert result.state["mode"] == "ranked_normal"
    loadout.require_ranked_races.assert_awaited_once_with(pid, True)

@pytest.mark.anyio
@pytest.mark.parametrize("scores", [[0, 0, 0], [0, ranked.STARFORGE_FLOOR, 5000]])
async def test_mixed_rank_party_uses_one_format(monkeypatch, scores):
    ids = [uuid.UUID(int=i + 1) for i in range(3)]
    ps = party.Parties()
    room = ps.create(ids[0], {"friend_code": "ABCDEFGH"}, "ranked", [])
    # Use the existing seat service for admission; ready and account gates are isolated.
    room.members = ids
    room.profiles = {pid: {"friend_code": str(pid.int).zfill(8)} for pid in ids}
    room.ready = set(ids[1:])
    monkeypatch.setattr(ps, "members_for_start", lambda pid: (room, ids))
    monkeypatch.setattr(ps, "seat_of", lambda r, pid: ids.index(pid))
    monkeypatch.setattr(ps, "broadcast", AsyncMock())
    monkeypatch.setattr(parties, "_me", AsyncMock(return_value=SimpleNamespace(player_id=ids[0])))
    monkeypatch.setattr(party, "current", lambda: ps)
    monkeypatch.setattr(parties.service_control, "read", AsyncMock(return_value=None))
    monkeypatch.setattr(parties.service_control, "matchmaking_block_reason", lambda _: "")
    conn = SimpleNamespace(fetch=AsyncMock(return_value=[{"player_id": pid, "score": score} for pid, score in zip(ids, scores)]))
    monkeypatch.setattr(parties.db, "pool", lambda: SimpleNamespace(acquire=lambda: Acquire(conn)))
    monkeypatch.setattr(ranked, "queue_gate", AsyncMock(return_value=""))
    monkeypatch.setattr(loadout, "require_ranked_races", AsyncMock())
    mm = matchmaking.Matchmaker(AsyncMock(return_value=1))
    monkeypatch.setattr(matchmaking, "current", lambda: mm)
    monkeypatch.setattr(parties.realtime, "hub", lambda: SimpleNamespace(send_to_player=AsyncMock()))
    await parties.start(parties.StartBody(), None)
    for pid in ids: assert mm.state_of(pid)["mode"] == "ranked_normal"
    assert loadout.require_ranked_races.await_count == 3
