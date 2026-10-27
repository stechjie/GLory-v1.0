"""Real matchmaker: FIFO teams, independent 30-second deadlines and recovery."""
import random
import uuid
from unittest.mock import AsyncMock

import pytest
from app import matchmaking, party, ranked


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture
def setup(monkeypatch):
    clock = [1000.0]
    store = party.Parties(now=lambda: clock[0])
    monkeypatch.setattr(party, "current", lambda: store)
    monkeypatch.setattr(party, "startable_sizes", lambda: frozenset({1, 2, 3}))
    monkeypatch.setattr(ranked, "accepting_now", lambda: True)
    monkeypatch.setattr(ranked, "punish_no_accept", AsyncMock())
    maker = matchmaking.Matchmaker(AsyncMock(return_value=1), now=lambda: clock[0],
                                   ai_fill_after_sec=10, rng=random.Random(7))
    return maker, clock


def pid(number):
    return uuid.UUID(int=number)


def pending_for(maker, number=1):
    return maker._pending[maker._pending_of[pid(number)]]


def humans_on(pending, team):
    return {m.player_id for m in pending.members if m.team == team}


@pytest.mark.anyio
@pytest.mark.parametrize("mode", [matchmaking.RANKED, matchmaking.RANKED_NORMAL])
@pytest.mark.parametrize("grouped", [False, True])
async def test_fifo_teams_replace_six_person_snake_split(setup, mode, grouped):
    maker, _ = setup
    # UUID sorting deliberately differs from queue order.
    order = [pid(i) for i in [6, 1, 5, 2, 4, 3]]
    for player in order:
        if grouped:
            maker.join_group([player], mode)
        else:
            maker.join(player, mode)
    await maker.tick()
    pending = pending_for(maker)
    assert humans_on(pending, 0) == set(order[:3])
    assert humans_on(pending, 1) == set(order[3:])
    assert not pending.ai_seats
    assert len(pending.found_for(order[0], 30)["seats"]) == 6


@pytest.mark.anyio
@pytest.mark.parametrize("elapsed,matched", [(10, False), (29.999, False), (30, True), (30.001, True)])
async def test_ranked_uses_30_seconds_even_when_old_ai_setting_is_10(setup, elapsed, matched):
    maker, clock = setup
    maker.join(pid(1), matchmaking.RANKED)
    clock[0] += elapsed
    await maker.tick()
    assert (maker.state_of(pid(1))["state"] == "found") is matched
    if matched:
        pending = pending_for(maker)
        assert len(pending.ai_seats) == 5
        assert humans_on(pending, 0) == {pid(1)}


@pytest.mark.anyio
async def test_four_players_do_not_drag_a_fresh_opponent_into_ai_match(setup):
    maker, clock = setup
    for i in [1, 2, 3]:
        maker.join(pid(i), matchmaking.RANKED)
    await maker.tick()
    clock[0] += 20
    maker.join(pid(4), matchmaking.RANKED)
    await maker.tick()
    clock[0] += 10
    await maker.tick()
    pending = pending_for(maker)
    assert humans_on(pending, 0) == {pid(1), pid(2), pid(3)}
    assert humans_on(pending, 1) == set()
    assert len(pending.ai_seats) == 3
    assert maker.state_of(pid(4))["state"] == "queued"


@pytest.mark.anyio
async def test_e_and_f_complete_d_team_before_a_deadline(setup):
    maker, clock = setup
    for i in range(1, 5):
        maker.join(pid(i), matchmaking.RANKED)
    await maker.tick()
    clock[0] += 29
    for i in [5, 6]:
        maker.join(pid(i), matchmaking.RANKED)
    await maker.tick()
    pending = pending_for(maker)
    assert humans_on(pending, 0) == {pid(i) for i in [1, 2, 3]}
    assert humans_on(pending, 1) == {pid(i) for i in [4, 5, 6]}
    assert not pending.ai_seats


@pytest.mark.anyio
async def test_two_fresh_opponents_are_not_prematurely_filled(setup):
    maker, clock = setup
    for i in [1, 2, 3]:
        maker.join(pid(i), matchmaking.RANKED)
    await maker.tick()
    clock[0] += 20
    for i in [4, 5]:
        maker.join(pid(i), matchmaking.RANKED)
    await maker.tick()
    clock[0] += 10
    await maker.tick()
    assert len(pending_for(maker).ai_seats) == 3
    assert all(maker.state_of(pid(i))["state"] == "queued" for i in [4, 5])
    clock[0] += 20
    await maker.tick()
    assert len(pending_for(maker, 4).ai_seats) == 4


@pytest.mark.anyio
async def test_same_tick_expiry_pairs_existing_teams_before_pure_ai(setup):
    maker, clock = setup
    for i in range(1, 6):
        maker.join(pid(i), matchmaking.RANKED)
    clock[0] += 30
    await maker.tick()
    pending = pending_for(maker)
    assert humans_on(pending, 0) == {pid(i) for i in [1, 2, 3]}
    assert humans_on(pending, 1) == {pid(i) for i in [4, 5]}
    assert len(pending.ai_seats) == 1
    assert len(maker._pending) == 1


@pytest.mark.anyio
async def test_full_team_does_not_reset_original_oldest_clock(setup):
    maker, clock = setup
    maker.join(pid(1), matchmaking.RANKED)
    await maker.tick()
    clock[0] += 29
    for i in [2, 3]:
        maker.join(pid(i), matchmaking.RANKED)
    await maker.tick()
    assert not maker._pending
    clock[0] += 1
    await maker.tick()
    assert humans_on(pending_for(maker), 0) == {pid(i) for i in [1, 2, 3]}


@pytest.mark.anyio
async def test_full_team_stays_together_when_premade_opponent_arrives(setup):
    maker, clock = setup
    for i in [1, 2, 3, 4]:
        maker.join(pid(i), matchmaking.RANKED)
    await maker.tick()
    clock[0] += 1
    maker.join_group([pid(5), pid(6), pid(7)], matchmaking.RANKED,
                     seats={pid(5): 2, pid(6): 0, pid(7): 1})
    await maker.tick()
    pending = pending_for(maker)
    assert humans_on(pending, 0) == {pid(i) for i in [1, 2, 3]}
    assert humans_on(pending, 1) == {pid(i) for i in [5, 6, 7]}
    assert {m.player_id: m.seat for m in pending.members if m.team == 1} == {
        pid(5): 2, pid(6): 0, pid(7): 1}
    assert maker.state_of(pid(4))["state"] == "queued"


@pytest.mark.anyio
async def test_duo_is_never_split_and_mode_stages_do_not_mix(setup):
    maker, clock = setup
    maker.join_group([pid(1), pid(2)], matchmaking.RANKED)
    maker.join(pid(3), matchmaking.RANKED)
    for i in [4, 5, 6]:
        maker.join(pid(i), matchmaking.RANKED_NORMAL)
    await maker.tick()
    assert not maker._pending
    clock[0] += 30
    await maker.tick()
    assert len(maker._pending) == 2
    assert humans_on(pending_for(maker), 0) == {pid(i) for i in [1, 2, 3]}
    assert humans_on(pending_for(maker, 4), 0) == {pid(i) for i in [4, 5, 6]}


@pytest.mark.anyio
async def test_cancelled_entry_is_removed_without_resetting_teammates(setup):
    maker, clock = setup
    for i in [1, 2, 3]:
        maker.join(pid(i), matchmaking.RANKED)
    await maker.tick()
    clock[0] += 20
    maker.leave(pid(1))
    maker.join(pid(4), matchmaking.RANKED)
    await maker.tick()
    clock[0] += 10
    await maker.tick()
    assert humans_on(pending_for(maker, 2), 0) == {pid(i) for i in [2, 3, 4]}
    assert maker.state_of(pid(1))["state"] == "idle"


@pytest.mark.anyio
async def test_disconnected_party_not_paired_or_filled(setup):
    maker, clock = setup
    maker.join_group([pid(1), pid(2)], matchmaking.RANKED)
    maker.on_disconnect(pid(2))
    maker.join(pid(3), matchmaking.RANKED)
    clock[0] += 30
    await maker.tick()
    assert humans_on(pending_for(maker, 3), 0) == {pid(3)}
    assert pid(1) not in maker._pending_of and pid(2) not in maker._pending_of


@pytest.mark.anyio
@pytest.mark.parametrize("grouped", [False, True])
async def test_declined_opponent_preserves_team_and_original_wait(setup, grouped):
    maker, clock = setup
    for i in range(1, 7):
        if grouped:
            maker.join_group([pid(i)], matchmaking.RANKED)
        else:
            maker.join(pid(i), matchmaking.RANKED)
    await maker.tick()
    clock[0] += 25
    maker.leave(pid(4))
    await maker.tick()
    teams = maker._ranked_team_queues[matchmaking.RANKED].teams
    abc = next(t for t in teams if pid(1) in {p for e in t.entries for p in e.waiter.party})
    assert {p for e in abc.entries for p in e.waiter.party} == {pid(i) for i in [1, 2, 3]}
    assert abc.age_key[0] == 1000.0
    clock[0] += 5
    await maker.tick()
    assert humans_on(pending_for(maker), 0) == {pid(i) for i in [1, 2, 3]}


@pytest.mark.anyio
async def test_ranked_ai_confirmation_and_battle_assignment_keep_team(setup):
    maker, clock = setup
    for i in [1, 2]:
        maker.join(pid(i), matchmaking.RANKED)
    clock[0] += 30
    await maker.tick()
    for i in [1, 2]:
        maker.accept(pid(i))
    assert maker.state_of(pid(1))["state"] == "found"
    clock[0] += 5
    await maker.tick()
    a, b = maker.assignment_for(pid(1)), maker.assignment_for(pid(2))
    assert a.match_uid == b.match_uid and a.team == b.team == 0
    assert len(a.ai_seats) == 4 and a.seat != b.seat


@pytest.mark.anyio
async def test_casual_keeps_existing_ten_second_wait(setup):
    maker, clock = setup
    maker.join(pid(1), matchmaking.CASUAL)
    clock[0] += 10
    await maker.tick()
    assert maker.state_of(pid(1))["state"] == "found"


@pytest.mark.anyio
@pytest.mark.parametrize("count", range(1, 13))
async def test_all_due_humans_get_exactly_one_valid_six_seat_match(setup, count):
    maker, clock = setup
    players = [pid(i) for i in range(1, count + 1)]
    for player in players:
        maker.join(player, matchmaking.RANKED)
    await maker.tick()
    clock[0] += 30
    # Full human tables are already confirming; accept them before their own
    # confirmation timeout while leaving queue timers at the deadline.
    for pending in list(maker._pending.values()):
        for member in list(pending.members):
            maker.accept(member.player_id)
    await maker.tick()
    located = set(maker._pending_of) | set(maker._assignments)
    assert located == set(players)
    assert not maker._queues[matchmaking.RANKED]
    for pending in maker._pending.values():
        slots = {(m.team, m.seat) for m in pending.members}
        slots.update((a["team"], a["seat"]) for a in pending.ai_seats)
        assert slots == {(team, seat) for team in [0, 1] for seat in range(3)}
        assert len(pending.members) + len(pending.ai_seats) == 6


@pytest.mark.anyio
async def test_ai_disabled_still_allows_full_human_teams(setup):
    maker, clock = setup
    maker._ai_fill_after = None
    for i in [1, 2, 3]:
        maker.join(pid(i), matchmaking.RANKED)
    clock[0] += 100
    await maker.tick()
    assert not maker._pending
    for i in [4, 5, 6]:
        maker.join(pid(i), matchmaking.RANKED)
    await maker.tick()
    assert not pending_for(maker).ai_seats
