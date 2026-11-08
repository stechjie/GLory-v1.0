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
async def test_fresh_fourth_player_joins_the_due_table_two_and_two(setup):
    # 11-07：到点的一队拉上另一队（不论它到没到点），再平均分：2+1AI 对 2+1AI。
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
    assert len(maker._pending) == 1
    assert humans_on(pending, 0) == {pid(1), pid(2)}
    assert humans_on(pending, 1) == {pid(3), pid(4)}
    assert len(pending.ai_seats) == 2


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
async def test_staggered_five_solos_share_one_table_not_two_ai_tables(setup):
    # 用户 11-07 报的场景：五个单排先后进队，以前拆成「3 对 3AI」+「2+1AI 对 3AI」。
    maker, clock = setup
    for i in range(1, 6):
        maker.join(pid(i), matchmaking.RANKED)
        await maker.tick()
        clock[0] += 2
    clock[0] += 22
    await maker.tick()
    pending = pending_for(maker)
    assert len(maker._pending) == 1
    assert humans_on(pending, 0) == {pid(1), pid(2), pid(3)}
    assert humans_on(pending, 1) == {pid(4), pid(5)}
    assert len(pending.ai_seats) == 1


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
    # 三个单排凑的队到点后平均分：最晚进队的那个坐对面。
    pending = pending_for(maker)
    assert humans_on(pending, 0) == {pid(1), pid(2)}
    assert humans_on(pending, 1) == {pid(3)}


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
    # 双人队不拆，单排坐对面；另一个模式的三个单排同样 2 对 1。
    assert humans_on(pending_for(maker), 0) == {pid(1), pid(2)}
    assert humans_on(pending_for(maker), 1) == {pid(3)}
    assert humans_on(pending_for(maker, 4), 0) == {pid(4), pid(5)}
    assert humans_on(pending_for(maker, 4), 1) == {pid(6)}


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
    assert humans_on(pending_for(maker, 2), 0) == {pid(2), pid(3)}
    assert humans_on(pending_for(maker, 2), 1) == {pid(4)}
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
    teams = maker._team_queues[matchmaking.RANKED].teams
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
    # 两个单排平均分到两边（11-07），各带两个 AI。
    assert a.match_uid == b.match_uid and {a.team, b.team} == {0, 1}
    assert len(a.ai_seats) == 4


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


# --- 11-07 开桌前平均分 ------------------------------------------------------------


def _entries(sizes):
    from types import SimpleNamespace
    from app.ranked_team_queue import QueuedEntry
    out = []
    for order, size in enumerate(sizes):
        members = [uuid.uuid4() for _ in range(size)]
        waiter = SimpleNamespace(party=members, joined_at=1000.0 + order, queue_order=order)
        out.append(QueuedEntry(members[0], waiter, size > 1))
    return out


@pytest.mark.parametrize("sizes", [
    [1], [1, 1], [2], [1, 1, 1], [2, 1], [3], [1, 1, 1, 1], [2, 2], [2, 1, 1], [3, 1],
    [1, 1, 1, 1, 1], [2, 2, 1], [3, 2], [3, 1, 1], [2, 1, 1, 1],
])
def test_balance_keeps_groups_whole_and_ai_gap_minimal(sizes):
    import itertools
    from app.ranked_team_queue import balance_sides
    entries = _entries(sizes)
    sides = balance_sides([entries[:1], entries[1:]])
    assert sorted(id(e) for side in sides for e in side) == sorted(id(e) for e in entries)
    counts = [sum(e.size for e in side) for side in sides]
    assert max(counts) <= 3
    assert entries[0] in sides[0], "等得最久的那份固定在 0 号队"
    # 与所有合法分法比：真人数差必须是最小的那个。
    best = min(abs(sum(s for s, pick in zip(sizes, bits) if pick)
                   - sum(s for s, pick in zip(sizes, bits) if not pick))
               for bits in itertools.product([0, 1], repeat=len(sizes))
               if sum(s for s, pick in zip(sizes, bits) if pick) <= 3
               and sum(s for s, pick in zip(sizes, bits) if not pick) <= 3)
    assert abs(counts[0] - counts[1]) == best


def test_balance_moves_the_latest_solo_and_leaves_full_humans_alone():
    from app.ranked_team_queue import balance_sides
    entries = _entries([1, 1, 1, 1])
    sides = balance_sides([entries[:3], entries[3:]])
    assert sides == [entries[:2], entries[2:]]
    six = _entries([1, 1, 1, 1, 1, 1])
    assert balance_sides([six[:3], six[3:]]) == [six[:3], six[3:]]


# --- 11-07 AI 难度跟段位 -----------------------------------------------------------


@pytest.mark.anyio
async def test_ai_tier_is_the_average_human_rank_and_same_for_every_ai(setup):
    maker, clock = setup
    maker.join(pid(1), matchmaking.RANKED, rating=450)   # 天曜
    maker.join(pid(2), matchmaking.RANKED, rating=850)   # 荣耀之冠 → 平均 650 = 天曜（3）
    clock[0] += 30
    await maker.tick()
    pending = pending_for(maker)
    assert len(pending.ai_seats) == 4
    assert {ai["tier"] for ai in pending.ai_seats} == {ranked.tier_of(650)} == {3}


@pytest.mark.anyio
async def test_party_scores_count_per_member(setup):
    maker, clock = setup
    maker.join_group([pid(1), pid(2)], matchmaking.RANKED, ratings={pid(1): 0, pid(2): 0})
    clock[0] += 30
    await maker.tick()
    assert {ai["tier"] for ai in pending_for(maker).ai_seats} == {0}


def test_card_carries_one_ai_tier():
    from app import loadout
    profile = loadout.Loadout(player_id=str(pid(1)), friend_code="AAAA2222", player_name="a",
                              avatar="", avatar_frame="", pet="", races=[])
    ai = matchmaking.ai_identities([(1, 0), (1, 1)], random.Random(1), avatars=["avatar_001"], tier=4)
    payload = loadout.card_payload(profile, match_uid="f" * 32, team=0, seat=0, ai_seats=ai)
    assert payload["ai_tier"] == 4
    assert all(len(entry) == 4 for entry in payload["ai"])
