"""Preserve original account parties across battle and staggered returns."""
import copy
import random
import uuid
from unittest.mock import AsyncMock

import pytest
from app import matchmaking, party, ranked


@pytest.fixture
def anyio_backend():
    return "asyncio"


def create_party(store, mode, count, start=1):
    members = [uuid.UUID(int=i) for i in range(start, start + count)]
    profiles = {pid: {"friend_code": f"{pid.int:08d}", "player_name": f"P{pid.int}"}
                for pid in members}
    room = store.create(members[0], profiles[members[0]], mode, ["pet-original"])
    for player in members[1:]:
        store.invite(members[0], player)
        store.join(player, room.id, profiles[player])
    # Preserve non-default positions and leadership, not merely a member count.
    room.seats = {pid: 2 - i for i, pid in enumerate(members)}
    return room, members


@pytest.mark.parametrize("mode", ["ranked", "casual", "casual_normal"])
@pytest.mark.parametrize("count", [1, 2, 3])
@pytest.mark.parametrize("reverse", [False, True])
def test_original_party_survives_long_battle_and_staggered_returns(mode, count, reverse):
    clock = [1000.0]
    store = party.Parties(now=lambda: clock[0])
    room, members = create_party(store, mode, count)
    original = copy.deepcopy((room.id, room.host, room.members, room.seats,
                              room.mode, room.pets, room.profiles))
    store.finish_for_match(members, "a" * 32)
    for player in members:
        store.on_disconnect(player)
    clock[0] += 1200
    assert not store.prune_disconnected()
    assert all(store.of(pid) is room for pid in members)
    store.finish_match("a" * 32)
    # A report is not a return: viewers can remain on the reward screen.
    clock[0] += 600
    assert not store.prune_disconnected()
    for player in reversed(members) if reverse else members:
        snapshot = store.state_of(player)
        assert snapshot["id"] == original[0]
        assert len(snapshot["members"]) == count
        clock[0] += 120
        store.prune_disconnected()
    assert (room.id, room.host, room.members, room.seats,
            room.mode, room.pets, room.profiles) == original
    assert not room.return_pending
    assert not room.ready  # Return never auto-readies the next game.


def test_idle_party_still_prunes_disconnected_ghosts():
    clock = [1000.0]
    store = party.Parties(now=lambda: clock[0])
    room, members = create_party(store, "ranked", 3)
    for player in members:
        store.on_disconnect(player)
    clock[0] += party.LEFT_GRACE_SEC + 1
    store.prune_disconnected()
    assert store.by_id(room.id) is None


def test_returned_player_uses_normal_disconnect_grace_again():
    clock = [1000.0]
    store = party.Parties(now=lambda: clock[0])
    room, members = create_party(store, "ranked", 3)
    store.finish_for_match(members, "a" * 32)
    store.finish_match("a" * 32)
    store.state_of(members[0])
    store.on_disconnect(members[0])
    clock[0] += party.LEFT_GRACE_SEC + 1
    store.prune_disconnected()
    assert store.of(members[0]) is None
    assert room.members == members[1:]
    assert all(store.of(pid) is room for pid in members[1:])


@pytest.mark.parametrize("action", ["leave", "kick"])
def test_explicit_membership_change_is_not_undone_on_return(action):
    clock = [1000.0]
    store = party.Parties(now=lambda: clock[0])
    room, members = create_party(store, "ranked", 3)
    store.finish_for_match(members, "a" * 32)
    store.finish_match("a" * 32)
    if action == "kick":
        store.kick(members[0], members[2])
    else:
        store.leave(members[2])
    assert members[2] not in room.return_pending
    assert store.state_of(members[2])["state"] == "none"
    assert store.state_of(members[0])["id"] == room.id
    assert len(room.members) == 2


def test_http_presence_does_not_leave_an_old_disconnect_marker():
    clock = [1000.0]
    store = party.Parties(now=lambda: clock[0])
    room, members = create_party(store, "ranked", 1)
    store.on_disconnect(members[0])
    clock[0] += 59
    assert store.state_of(members[0])["id"] == room.id
    clock[0] += 2
    store.prune_disconnected()
    assert store.of(members[0]) is room


@pytest.mark.anyio
async def test_matchmaking_keeps_premade_trio_and_solo_parties_distinct(monkeypatch):
    clock = [1000.0]
    store = party.Parties(now=lambda: clock[0])
    monkeypatch.setattr(party, "current", lambda: store)
    monkeypatch.setattr(ranked, "accepting_now", lambda: True)
    trio, abc = create_party(store, "ranked", 3)
    originals = {pid: trio for pid in abc}
    for number in [4, 5, 6]:
        room, one = create_party(store, "ranked", 1, start=number)
        originals[one[0]] = room
    maker = matchmaking.Matchmaker(AsyncMock(return_value=1), now=lambda: clock[0],
                                   ai_fill_after_sec=10, rng=random.Random(7))
    maker.join_group(abc, matchmaking.RANKED)
    for player in list(originals)[3:]:
        maker.join_group([player], matchmaking.RANKED)
    await maker.tick()
    for player in originals:
        maker.accept(player)
    uid = maker.assignment_for(abc[0]).match_uid
    for player in originals:
        store.on_disconnect(player)
    clock[0] += 1200
    store.prune_disconnected()
    maker.finish_match(uid)
    clock[0] += 120
    store.prune_disconnected()
    for player, original in originals.items():
        snapshot = store.state_of(player)
        assert snapshot["id"] == original.id
        assert len(snapshot["members"]) == (3 if player in abc else 1)
