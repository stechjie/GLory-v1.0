"""Exercise the same team lifecycle through every real queue identifier."""
import random
import uuid
from unittest.mock import AsyncMock

import pytest
from app import matchmaking, party, ranked


MODES = [(matchmaking.CASUAL, 10), (matchmaking.CASUAL_NORMAL, 30),
         (matchmaking.RANKED, 30), (matchmaking.RANKED_NORMAL, 30)]


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture(params=MODES, ids=[x[0] for x in MODES])
def queue(request, monkeypatch):
    mode, wait = request.param
    clock = [1000.0]
    store = party.Parties(now=lambda: clock[0])
    monkeypatch.setattr(party, "current", lambda: store)
    monkeypatch.setattr(party, "startable_sizes", lambda: frozenset({1, 2, 3}))
    monkeypatch.setattr(ranked, "accepting_now", lambda: True)
    monkeypatch.setattr(ranked, "punish_no_accept", AsyncMock())
    # Legacy configuration must not override the mode's agreed deadline.
    maker = matchmaking.Matchmaker(AsyncMock(return_value=1), now=lambda: clock[0],
                                   ai_fill_after_sec=1, rng=random.Random(9))
    return maker, clock, mode, wait


def pid(i):
    return uuid.UUID(int=i)


def pending(maker, i=1):
    return maker._pending[maker._pending_of[pid(i)]]


def team(match, side):
    return {m.player_id for m in match.members if m.team == side}


@pytest.mark.anyio
@pytest.mark.parametrize("size", [1, 2, 3])
@pytest.mark.parametrize("grouped", [False, True])
async def test_deadline_fills_own_team_and_pure_ai_opponent(queue, size, grouped):
    maker, clock, mode, wait = queue
    players = [pid(i) for i in range(1, size + 1)]
    if grouped:
        maker.join_group(players, mode)
    else:
        for player in players:
            maker.join(player, mode)
    clock[0] += wait - 0.001
    await maker.tick()
    assert not maker._pending
    clock[0] += 0.001
    await maker.tick()
    match = pending(maker)
    assert team(match, 0) == set(players) and not team(match, 1)
    assert len(match.ai_seats) == 6 - size
    assert match.mode == mode


@pytest.mark.anyio
async def test_full_fifo_teams_match_immediately_without_splitting(queue):
    maker, _, mode, _ = queue
    order = [6, 1, 5, 2, 4, 3]
    for i in order:
        maker.join(pid(i), mode)
    await maker.tick()
    assert team(pending(maker), 0) == {pid(i) for i in order[:3]}
    assert team(pending(maker), 1) == {pid(i) for i in order[3:]}
    assert not pending(maker).ai_seats


@pytest.mark.anyio
async def test_abc_stays_together_when_ef_complete_d_before_deadline(queue):
    maker, clock, mode, wait = queue
    for i in range(1, 5):
        maker.join(pid(i), mode)
    await maker.tick()
    clock[0] += wait - 1
    maker.join(pid(5), mode)
    maker.join(pid(6), mode)
    await maker.tick()
    assert team(pending(maker), 0) == {pid(i) for i in [1, 2, 3]}
    assert team(pending(maker), 1) == {pid(i) for i in [4, 5, 6]}
    assert not pending(maker).ai_seats


@pytest.mark.anyio
async def test_own_timeout_does_not_force_fresh_incomplete_opponent(queue):
    maker, clock, mode, wait = queue
    for i in [1, 2, 3]:
        maker.join(pid(i), mode)
    await maker.tick()
    clock[0] += wait - 1
    maker.join(pid(4), mode)
    maker.join(pid(5), mode)
    clock[0] += 1
    await maker.tick()
    assert team(pending(maker), 0) == {pid(i) for i in [1, 2, 3]}
    assert not team(pending(maker), 1)
    assert all(maker.state_of(pid(i))["state"] == "queued" for i in [4, 5])


@pytest.mark.anyio
async def test_due_partial_teams_pair_instead_of_creating_two_ai_matches(queue):
    maker, clock, mode, wait = queue
    for i in range(1, 6):
        maker.join(pid(i), mode)
    clock[0] += wait
    await maker.tick()
    assert len(maker._pending) == 1
    assert team(pending(maker), 0) == {pid(i) for i in [1, 2, 3]}
    assert team(pending(maker), 1) == {pid(i) for i in [4, 5]}
    assert len(pending(maker).ai_seats) == 1


@pytest.mark.anyio
async def test_team_completion_and_cancel_do_not_reset_oldest_wait(queue):
    maker, clock, mode, wait = queue
    maker.join(pid(1), mode)
    maker.join(pid(2), mode)
    await maker.tick()
    clock[0] += wait - 1
    maker.leave(pid(2))
    maker.join(pid(3), mode)
    maker.join(pid(4), mode)
    await maker.tick()
    assert not maker._pending
    clock[0] += 1
    await maker.tick()
    assert team(pending(maker), 0) == {pid(i) for i in [1, 3, 4]}
    assert maker.state_of(pid(2))["state"] == "idle"


@pytest.mark.anyio
async def test_premade_seats_survive_matching_and_ai_confirmation(queue):
    maker, clock, mode, wait = queue
    players = [pid(i) for i in [1, 2, 3]]
    seats = {pid(1): 2, pid(2): 0, pid(3): 1}
    maker.join_group(players, mode, seats=seats)
    clock[0] += wait
    await maker.tick()
    for player in players:
        maker.accept(player)
    clock[0] += 5
    await maker.tick()
    assignments = [maker.assignment_for(p) for p in players]
    assert len({a.match_uid for a in assignments}) == 1
    assert {p: a.seat for p, a in zip(players, assignments)} == seats
    assert {a.team for a in assignments} == {0}


@pytest.mark.anyio
@pytest.mark.parametrize("grouped", [False, True])
async def test_decline_restores_confirmed_team_with_original_deadline(queue, grouped):
    maker, clock, mode, wait = queue
    for i in range(1, 7):
        if grouped:
            maker.join_group([pid(i)], mode)
        else:
            maker.join(pid(i), mode)
    await maker.tick()
    for i in [1, 2, 3]:
        maker.accept(pid(i))
    clock[0] += wait - 1
    maker.leave(pid(4))
    await maker.tick()
    assert maker.state_of(pid(1))["state"] == "queued"
    clock[0] += 1
    await maker.tick()
    assert team(pending(maker), 0) == {pid(i) for i in [1, 2, 3]}


@pytest.mark.anyio
async def test_disconnected_group_is_not_dragged_into_match(queue):
    maker, clock, mode, wait = queue
    maker.join_group([pid(1), pid(2)], mode)
    maker.on_disconnect(pid(2))
    maker.join(pid(3), mode)
    clock[0] += wait
    await maker.tick()
    assert team(pending(maker, 3), 0) == {pid(3)}
    assert not {pid(1), pid(2)} & set(maker._pending_of)


@pytest.mark.anyio
@pytest.mark.parametrize("count", range(1, 13))
async def test_every_due_human_has_one_match_with_six_unique_slots(queue, count):
    maker, clock, mode, wait = queue
    players = [pid(i) for i in range(1, count + 1)]
    for p in players:
        maker.join(p, mode)
    await maker.tick()
    for match in list(maker._pending.values()):
        for member in match.members:
            maker.accept(member.player_id)
    clock[0] += wait
    await maker.tick()
    assert set(maker._pending_of) | set(maker._assignments) == set(players)
    assert not maker._queues[mode]
    for match in maker._pending.values():
        slots = {(m.team, m.seat) for m in match.members}
        slots.update((a["team"], a["seat"]) for a in match.ai_seats)
        assert slots == {(t, s) for t in [0, 1] for s in range(3)}


@pytest.mark.anyio
async def test_ai_disable_keeps_human_team_matches_available(queue):
    maker, clock, mode, wait = queue
    maker._ai_fill_after = None
    for i in [1, 2, 3]:
        maker.join(pid(i), mode)
    clock[0] += wait * 3
    await maker.tick()
    assert not maker._pending
    for i in [4, 5, 6]:
        maker.join(pid(i), mode)
    await maker.tick()
    assert not pending(maker).ai_seats


@pytest.mark.anyio
async def test_modes_remain_separate_with_independent_deadlines(queue):
    maker, clock, _, _ = queue
    for i, (mode, _) in enumerate(MODES, 1):
        maker.join(pid(i), mode)
    clock[0] += 10
    await maker.tick()
    maker.accept(pid(1))
    assert pending(maker, 1).mode == matchmaking.CASUAL
    assert all(maker.state_of(pid(i))["state"] == "queued" for i in [2, 3, 4])
    clock[0] += 20
    await maker.tick()
    assert len(maker._pending) + len({a.match_uid for a in maker._assignments.values()}) == 4
    for i in [2, 3, 4]:
        assert team(pending(maker, i), 0) == {pid(i)}
