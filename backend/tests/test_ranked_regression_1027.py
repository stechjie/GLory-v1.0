"""2026-10-27 ranked lifecycle and selected-race regressions. No live DB."""
import asyncio
import dataclasses
import uuid
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock
import pytest
from fastapi import HTTPException
from app import loadout, matchmaking, party, ranked
from app.routes import battle_report as report_routes
from app.routes import matchmaking as match_routes
from app.routes import party as party_routes

MODES = ["casual", "casual_normal", "ranked", "ranked_normal"]
PIDS = [uuid.UUID(int=i+1) for i in range(6)]

@pytest.fixture
def anyio_backend(): return "asyncio"

@pytest.fixture
def services(monkeypatch):
    now = [1000.0]
    ps = party.Parties(now=lambda: now[0])
    mm = matchmaking.Matchmaker(AsyncMock(return_value=1), now=lambda: now[0])
    monkeypatch.setattr(party, "current", lambda: ps)
    monkeypatch.setattr(matchmaking, "current", lambda: mm)
    monkeypatch.setattr(ranked, "accepting_now", lambda *args: True)
    return ps, mm, now

async def allocate(services, mode):
    ps, mm, _ = services
    for pid in PIDS:
        ps.create(pid, {"friend_code": str(pid.int).zfill(8), "player_name": "P"+str(pid.int)},
                  "ranked" if mode.startswith("ranked") else mode, [])
        mm.join_group([pid], mode)
    await mm.tick()
    for pid in PIDS: mm.accept(pid)
    await asyncio.sleep(0)
    assert all(mm.state_of(pid)["state"] == "ready" for pid in PIDS)
    return mm.assignment_for(PIDS[0]).match_uid

@pytest.mark.anyio
@pytest.mark.parametrize("mode", MODES)
@pytest.mark.parametrize("recorded", [True, False])
async def test_committed_or_duplicate_report_finishes_all_assignments(services, monkeypatch, mode, recorded):
    ps, mm, _ = services
    match = await allocate(services, mode)
    report = {"match_uid": match, "mode": "ranked" if mode.startswith("ranked") else "casual", "rounds": 13, "outcome": 0}
    monkeypatch.setattr(report_routes, "_me", AsyncMock(return_value=SimpleNamespace(player_id=PIDS[0])))
    monkeypatch.setattr(report_routes.battle_report, "verify", Mock(return_value=report))
    monkeypatch.setattr(report_routes.battle_report, "record", AsyncMock(return_value=recorded))
    result = await report_routes.submit_report(report_routes.ReportBody(report="signed-fixture"), None)
    assert result.recorded is recorded
    assert all(mm.state_of(pid)["state"] == "idle" for pid in PIDS)
    assert all(ps.of(pid).in_match == "" for pid in PIDS)
    mm.join_group([PIDS[0]], mode)
    assert mm.state_of(PIDS[0])["state"] == "queued"

@pytest.mark.anyio
@pytest.mark.parametrize("mode", MODES)
async def test_queue_leave_does_not_lie_about_ready_allocation(services, mode):
    _, mm, _ = services
    await allocate(services, mode)
    assert mm.leave(PIDS[0]) == mm.state_of(PIDS[0])
    assert mm.state_of(PIDS[0])["state"] == "ready"

@pytest.mark.anyio
@pytest.mark.parametrize("mode", MODES)
async def test_personal_release_is_scoped_idempotent_and_requeues(services, mode):
    ps, mm, _ = services
    match = await allocate(services, mode)
    assert not mm.release_assignment(PIDS[0], "b"*32)
    assert mm.state_of(PIDS[0])["state"] == "ready"
    assert mm.release_assignment(PIDS[0], match)
    assert not mm.release_assignment(PIDS[0], match)
    assert mm.state_of(PIDS[0])["state"] == "idle"
    assert mm.state_of(PIDS[1])["state"] == "ready"
    assert ps.of(PIDS[0]).in_match == ""
    mm.join_group([PIDS[0]], mode)
    assert mm.state_of(PIDS[0])["state"] == "queued"

@pytest.mark.anyio
async def test_old_completion_and_release_cannot_erase_new_assignment(services):
    ps, mm, _ = services
    old = await allocate(services, "ranked")
    mm._assignments[PIDS[0]] = dataclasses.replace(mm._assignments[PIDS[0]], match_uid="b"*32)
    ps.of(PIDS[0]).in_match = "b"*32
    mm.finish_match(old)
    assert mm.assignment_for(PIDS[0]).match_uid == "b"*32
    assert ps.of(PIDS[0]).in_match == "b"*32
    assert not mm.release_assignment(PIDS[0], old)

@pytest.mark.anyio
async def test_failed_report_commit_does_not_finish_allocation(services, monkeypatch):
    _, mm, _ = services
    match = await allocate(services, "ranked")
    monkeypatch.setattr(report_routes, "_me", AsyncMock(return_value=SimpleNamespace(player_id=PIDS[0])))
    monkeypatch.setattr(report_routes.battle_report, "verify", Mock(return_value={"match_uid":match}))
    monkeypatch.setattr(report_routes.battle_report, "record", AsyncMock(side_effect=RuntimeError("DB unavailable")))
    with pytest.raises(RuntimeError): await report_routes.submit_report(report_routes.ReportBody(report="fixture"), None)
    assert mm.state_of(PIDS[0])["state"] == "ready"

@pytest.mark.parametrize("normal,count,allowed", [(False,0,False),(False,1,False),(False,2,False),(False,3,True),(False,4,True),(True,3,False),(True,4,True)])
def test_ranked_requires_equipped_races(normal, count, allowed):
    races=["human","god","dark","undead"][:count]
    if allowed: loadout.validate_ranked_races(races, normal)
    else:
        with pytest.raises(loadout.LoadoutRejected): loadout.validate_ranked_races(races, normal)

@pytest.mark.anyio
@pytest.mark.parametrize("mode,count", [("ranked",2),("ranked_normal",3)])
async def test_card_issuance_rechecks_equipped_races(monkeypatch, mode, count):
    profile=loadout.Loadout(str(PIDS[0]),"00000001","P","","","",["human","god","dark"][:count])
    monkeypatch.setattr(loadout,"build_loadout",AsyncMock(return_value=profile))
    sign=Mock(return_value="card");monkeypatch.setattr(loadout,"sign",sign)
    with pytest.raises(loadout.LoadoutRejected): await loadout.issue_card(PIDS[0],match_uid="a"*32,mode=mode)
    sign.assert_not_called()

class Acquire:
    def __init__(self, conn): self.conn=conn
    async def __aenter__(self): return self.conn
    async def __aexit__(self,*args): pass

def route_fixture(services, monkeypatch, mode="ranked", score=0):
    ps,mm,_=services;ps.create(PIDS[0],{"friend_code":"00000001"},mode,[])
    monkeypatch.setattr(party_routes,"_me",AsyncMock(return_value=SimpleNamespace(player_id=PIDS[0])))
    monkeypatch.setattr(party_routes.service_control,"read",AsyncMock(return_value=None))
    monkeypatch.setattr(party_routes.service_control,"matchmaking_block_reason",lambda _: "")
    conn=SimpleNamespace(fetch=AsyncMock(return_value=[{"player_id":PIDS[0],"score":score}]))
    monkeypatch.setattr(party_routes.db,"pool",lambda:SimpleNamespace(acquire=lambda:Acquire(conn)))
    return ps,mm

@pytest.mark.anyio
@pytest.mark.parametrize("reason",["need_three_races","ranked_window_closed","ranked_sanction","credit_banned","credit_too_low"])
async def test_party_gate_keeps_exact_reason(services,monkeypatch,reason):
    route_fixture(services,monkeypatch)
    monkeypatch.setattr(party_routes.ranked,"queue_gate",AsyncMock(return_value=reason))
    with pytest.raises(HTTPException) as e: await party_routes.start(party_routes.StartBody(),None)
    assert e.value.headers["X-Glory-Reason"]==reason
    assert e.value.detail==match_routes._GATE_TEXT[reason]
    assert "有队员暂时不能" not in e.value.detail

@pytest.mark.anyio
@pytest.mark.parametrize("score,count",[(0,2),(ranked.STARFORGE_FLOOR,3)])
async def test_party_start_rejects_too_few_selected_races(services,monkeypatch,score,count):
    ps,mm=route_fixture(services,monkeypatch,score=score)
    monkeypatch.setattr(party_routes.ranked,"queue_gate",AsyncMock(return_value=""))
    profile=SimpleNamespace(races=["human","god","dark"][:count])
    monkeypatch.setattr(loadout,"build_loadout",AsyncMock(return_value=profile))
    with pytest.raises(HTTPException) as e: await party_routes.start(party_routes.StartBody(),None)
    assert e.value.headers["X-Glory-Reason"] in ["need_three_races","ranked_need_four_races"]
    assert not ps.of(PIDS[0]).queued
    assert mm.state_of(PIDS[0])["state"]=="idle"

@pytest.mark.anyio
async def test_personal_release_route_never_releases_teammate(services,monkeypatch):
    _,mm,_=services;match=await allocate(services,"ranked")
    monkeypatch.setattr(match_routes,"_me",AsyncMock(return_value=SimpleNamespace(player_id=PIDS[0])))
    result=await match_routes.release_assignment(match_routes.ReleaseBody(match_uid=match),None)
    assert result.state["state"]=="idle"
    assert mm.state_of(PIDS[1])["state"]=="ready"

@pytest.mark.anyio
async def test_leaving_queued_party_does_not_restore_old_party(services,monkeypatch):
    ps,mm,_=services;room=ps.create(PIDS[0],{},"ranked",[]);old=room.id
    mm.join_group([PIDS[0]],"ranked");room.queued=True
    monkeypatch.setattr(party_routes,"_me",AsyncMock(return_value=SimpleNamespace(player_id=PIDS[0])))
    monkeypatch.setattr(party_routes.realtime,"hub",lambda:SimpleNamespace(send_to_player=AsyncMock(return_value=1)))
    await party_routes.leave(None)
    assert ps.of(PIDS[0]) is None
    assert mm.state_of(PIDS[0])["state"]=="idle"
    assert ps.create(PIDS[0],{},"ranked",[]).id != old
