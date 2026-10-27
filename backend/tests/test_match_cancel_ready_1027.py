"""Late cancellation must keep a committed allocation visible to its caller."""
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from app import matchmaking, party
from app.routes import party as party_routes
from test_all_mode_team_queue_1027 import queue, pid, pending


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.mark.anyio
@pytest.mark.parametrize("endpoint", ["solo", "party"])
async def test_late_cancel_reports_ready_without_clearing_other_players(queue, monkeypatch, endpoint):
    maker, _, mode, _ = queue
    for i in range(1, 7):
        maker.join(pid(i), mode)
    await maker.tick()
    for i in range(1, 7):
        maker.accept(pid(i))
    uid = maker.assignment_for(pid(1)).match_uid
    monkeypatch.setattr(matchmaking, "current", lambda: maker)
    monkeypatch.setattr(party_routes, "_me", AsyncMock(return_value=SimpleNamespace(player_id=pid(1))))
    # There is deliberately no queued party room after confirmation. The endpoint
    # must return the allocation before attempting queued-room lookup or idle push.
    if endpoint == "party":
        response = (await party_routes.cancel(None)).state
    else:
        response = maker.leave(pid(1))
    assert response["state"] == "ready" and response["match_uid"] == uid
    assert all(maker.assignment_for(pid(i)).match_uid == uid for i in range(1, 7))


@pytest.mark.anyio
async def test_cancel_before_last_confirmation_dissolves_match_and_keeps_others_waiting(queue):
    maker, _, mode, _ = queue
    for i in range(1, 7):
        maker.join(pid(i), mode)
    await maker.tick()
    for i in range(1, 6):
        maker.accept(pid(i))
    assert maker.leave(pid(6))["state"] == "idle"
    assert not maker._assignments
    assert all(maker.state_of(pid(i))["state"] == "queued" for i in range(1, 6))
