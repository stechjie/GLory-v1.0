"""游戏上报的事件（database/026_client_events.sql，app/client_events.py，routes/events.py）。

最要紧的几条，失败模式都**不会报错**：
  1. 名单外的字段丢掉、名单外的事件拒收 —— 客户端据此从队列里删，不会卡住后面的；
  2. 客户端的钟不准 / 被改过，发生时刻仍然对（按发送那一刻对齐）；
  3. 同一条发两次只记一次（没收到回复重发是常态）；
  4. 事件记在令牌那个人名下，不看请求体；
  5. 026 没跑时回 503（客户端留着以后再发），不是 500、也不是「收下了」。
"""

from __future__ import annotations

import datetime as dt
import json
import uuid
from dataclasses import dataclass

import pytest
from fastapi.testclient import TestClient

from app import client_events, db, players
from app.config import get_settings
from app.jwt_verify import Claims, TokenError
from app.main import app
from app.routes import events as event_routes
from app.routes import me as me_routes
from pg_harness import requires_pg, run_with_db

PLAYER = uuid.UUID("aaaaaaaa-1111-2222-3333-444444444444")
NOW = dt.datetime(2026, 10, 2, 4, 0, tzinfo=dt.UTC)
NOW_MS = int(NOW.timestamp() * 1000)


# --- 字段与时间 ---------------------------------------------------------------------


def test_unknown_fields_and_wrong_types_are_dropped_not_rejected() -> None:
    props = client_events.clean_props("round_result", {
        "round": 5, "won": True, "gold": 12.0, "hp": True, "kind": "x" * 500, "new_field": 1, "mode": 3})
    assert props == {"round": 5, "won": True, "gold": 12, "kind": "x" * client_events.MAX_STRING}, \
        "新包多带的字段丢掉；True 不算整数；12.0 当 12；类型不对的丢掉"


def test_client_clock_is_aligned_at_send_time() -> None:
    """★ 手机的钟快了一天（或者被改过）：事件发生在「发送前 60 秒」，就记成服务器的 60 秒前。"""
    wrong_clock_sent = NOW_MS + 86_400_000
    at = client_events.occurred_at(wrong_clock_sent - 60_000, wrong_clock_sent, NOW)
    assert at == NOW - dt.timedelta(seconds=60)
    assert client_events.occurred_at(NOW_MS + 5_000, NOW_MS, NOW) == NOW, "晚于现在的按现在算"
    assert client_events.occurred_at(NOW_MS - 8 * 86_400_000, NOW_MS, NOW) is None, "7 天前的不收"


# --- 接口 ---------------------------------------------------------------------------


@dataclass
class _FakePlayer:
    player_id: uuid.UUID


class _FakeVerifier:
    async def verify(self, token: str) -> Claims:
        if token != "token-a":
            raise TokenError("令牌校验失败")
        return Claims(auth_uid="auth-a", is_anonymous=True, expires_at=0)


@pytest.fixture
def wired(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("GLORY_DISABLE_INSTANCE_LOCK", "true")
    monkeypatch.setenv("GLORY_SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("GLORY_DATABASE_URL", "")
    get_settings.cache_clear()
    monkeypatch.setattr(db, "is_connected", lambda: True)
    monkeypatch.setattr(me_routes, "get_verifier", _FakeVerifier)

    async def _lookup(auth_uid: str):
        return _FakePlayer(PLAYER) if auth_uid == "auth-a" else None

    monkeypatch.setattr(players, "get_by_auth_uid", _lookup)
    calls: list[tuple] = []

    async def _record(player_id, events, sent_at, install_id, build):
        calls.append((player_id, events, sent_at, install_id, build))
        return {"accepted": [str(e["id"]) for e in events], "duplicate": [], "rejected": []}

    monkeypatch.setattr(client_events, "record", _record)
    event_routes._limiter.reset()
    yield calls
    event_routes._limiter.reset()
    get_settings.cache_clear()


AUTH = {"Authorization": "Bearer token-a", "X-Glory-Client": "protocol=34; build=57; kinds=prep_skin"}

# Godot 的 JSON.stringify 写出来的样子（tools/analytics_check 钉着：整数是整数、键按字母排）。
GODOT_BODY = (
    '{"events":[{"id":"6f1c2b9e-3d4a-4b5c-8d7e-9f0a1b2c3d4e","name":"round_result",'
    '"props":{"battle":"b5","gold":1234567,"hp":40,"kind":"boss","mode":"ranked","round":5,"won":true},'
    '"sid":"0a1b2c3d-4e5f-4a6b-8c7d-8e9f0a1b2c3d","t":1790740800000}],'
    '"install_id":"11111111-2222-4333-8444-555555555555","player_id":"99999999-9999-4999-8999-999999999999",'
    '"sent_at":1790740805000}')


def test_needs_login(wired) -> None:
    assert TestClient(app).post("/v1/events", json={"sent_at": 1, "events": []}).status_code == 401


def test_godot_payload_is_recorded_under_the_token_owner(wired) -> None:
    """★ 请求体里就算写了别人的 player_id，也只记在令牌那个人名下；版本号从请求头拿。"""
    r = TestClient(app).post("/v1/events", content=GODOT_BODY,
                             headers={**AUTH, "Content-Type": "application/json"})
    assert r.status_code == 200, r.text
    assert r.json()["accepted"] == ["6f1c2b9e-3d4a-4b5c-8d7e-9f0a1b2c3d4e"]
    [(player_id, events, sent_at, install_id, build)] = wired
    assert player_id == PLAYER and build == 57 and sent_at == 1790740805000
    assert install_id == uuid.UUID("11111111-2222-4333-8444-555555555555")
    assert events[0]["t"] == 1790740800000 and events[0]["props"]["won"] is True


def test_oversized_batch_is_refused_whole(wired) -> None:
    events = [{"id": str(uuid.uuid4()), "name": "perf", "t": NOW_MS, "props": {}}
              for _ in range(client_events.BATCH_MAX + 1)]
    r = TestClient(app).post("/v1/events", json={"sent_at": NOW_MS, "events": events}, headers=AUTH)
    assert r.status_code == 422 and wired == []


def test_rate_limited_per_player(wired) -> None:
    client = TestClient(app)
    for _ in range(event_routes.EVENTS_PER_MINUTE):
        assert client.post("/v1/events", json={"sent_at": NOW_MS, "events": []}, headers=AUTH).status_code == 200
    r = client.post("/v1/events", json={"sent_at": NOW_MS, "events": []}, headers=AUTH)
    assert r.status_code == 429 and r.headers.get("Retry-After")


def test_missing_table_is_503_so_the_client_keeps_its_queue(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    async def _not_ready(*_args):
        raise client_events.NotReady("数据库还没跑 026")

    monkeypatch.setattr(client_events, "record", _not_ready)
    r = TestClient(app).post("/v1/events", json={"sent_at": NOW_MS, "events": []}, headers=AUTH)
    assert r.status_code == 503


def test_every_event_the_client_sends_is_on_the_list() -> None:
    """AnalyticsService.gd / BattleScreen.gd 里每一处 track("xxx")，名单里都要有（反方向由 tools/analytics_check 钉）。"""
    import pathlib
    import re

    repo = pathlib.Path(__file__).resolve().parents[2]
    sent = set()
    for path in ("scripts/autoload/AnalyticsService.gd", "scenes/battle/BattleScreen.gd"):
        sent |= set(re.findall(r'track\("([a-z_]+)"', (repo / path).read_text(encoding="utf-8")))
    assert sent, "一处 track 都没找到 —— 这条断言失效了"
    assert sent <= set(client_events.EVENTS), "客户端会报、服务器不收：%s" % sorted(sent - set(client_events.EVENTS))


# --- 真库 ---------------------------------------------------------------------------


async def _event(conn, player: uuid.UUID, name: str, at: dt.datetime, **props) -> None:
    await conn.execute(
        "insert into analytics_client_events (player_id, event_id, name, occurred_at, build, props)"
        " values ($1, $2, $3, $4, 57, $5::jsonb)", player, uuid.uuid4(), name, at, json.dumps(props))


@requires_pg
def test_report_funnel_rounds_and_first_play() -> None:
    """教学漏斗：到达第 N 步 = 完成了上一步；同队三个人报同一回合只算一次；员工不算。"""
    from app import analytics_report

    at = NOW - dt.timedelta(days=1)

    async def body() -> None:
        async with db.pool().acquire() as conn:
            people = []
            for _ in range(4):
                pid = uuid.uuid4()
                await conn.execute("insert into players (player_id, created_at) values ($1, $2)",
                                   pid, NOW - dt.timedelta(days=2))
                people.append(pid)
            a, b, c, staff = people
            await conn.execute("insert into analytics_account_tags (player_id, kind, tagged_by) values ($1, 'staff', 't')", staff)
            for p in (a, b, c, staff):
                await _event(conn, p, "tutorial_start", at)
                await _event(conn, p, "tutorial_step", at, **{"from": "BUY_3", "to": "PLACE_3", "index": 1, "ms": 4000})
            # a 走完；b 在第 2 步跳过；c 停在第 2 步
            await _event(conn, a, "tutorial_step", at, **{"from": "PLACE_3", "to": "DONE", "index": 2, "ms": 9000})
            await _event(conn, b, "tutorial_skip", at, step="PLACE_3", index=2, ms=100)
            # a、b 同队打第 5 回合（输了、法阵归零），各报一次；c 在另一队赢了
            for p in (a, b):
                await _event(conn, p, "round_result", at, round=5, kind="boss", battle="x", team=0, won=False,
                             hp=0, over=True, mode="casual")
            await _event(conn, c, "round_result", at, round=5, kind="boss", battle="x", team=1, won=True,
                         hp=40, over=True, mode="casual")
            await _event(conn, a, "match_start", at, m="m1", mode="casual")
            await _event(conn, a, "replay_failed", at, round=5, reason="timeout")
            await _event(conn, a, "replay_done", at, round=4, ms=30000)
            await conn.execute(
                "insert into analytics_player_days (game_day, player_id, first_seen_at, last_seen_at) values ($1, $2, now(), now())",
                (NOW - dt.timedelta(days=1)).astimezone(dt.timezone(dt.timedelta(hours=8))).date(), a)
        out = await analytics_report.client_report(7, now=NOW)
        t = out["tutorial"]
        assert (t["started"], t["completed"], t["skipped"]) == (3, 1, 1), "员工不算"
        assert [(s["index"], s["reached"], s["done"], s["skipped"], s["stuck"]) for s in t["steps"]] == [
            (1, 3, 3, 0, 0), (2, 3, 1, 1, 1)]
        assert t["steps"][0]["p50_sec"] == 4.0
        [r5] = out["rounds"]
        assert (r5["round"], r5["teams"], r5["lost"], r5["eliminated"]) == (5, 2, 1, 1), "同队两个人报只算一支队伍"
        assert (await analytics_report.client_report(7, mode="ranked", now=NOW))["rounds"] == []
        f = out["first_play"]
        assert (f["players"], f["tutorial_done"], f["tutorial_skipped"], f["match_started"], f["match_finished"]) == (3, 1, 1, 1, 3)
        assert (f["d1_ready"], f["d1_back"]) == (3, 1)
        q = out["quality"]
        assert (q["replay_done"], q["replay_failed"]) == (1, 1)
        assert q["reasons"] == [{"event": "replay_failed", "reason": "timeout", "times": 1, "players": 1}]

    run_with_db(body)


@requires_pg
def test_accepted_duplicate_rejected() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            await conn.execute("insert into players (player_id) values ($1)", PLAYER)
        first, second = uuid.uuid4(), uuid.uuid4()
        batch = [
            {"id": first, "name": "tutorial_step", "t": NOW_MS - 1000, "sid": None,
             "props": {"from": "BUY_3", "to": "PLACE_3", "index": 1, "ms": 5300, "extra": "丢掉"}},
            {"id": first, "name": "tutorial_step", "t": NOW_MS - 1000, "sid": None, "props": {}},  # 同批重复
            {"id": uuid.uuid4(), "name": "hack_the_planet", "t": NOW_MS, "sid": None, "props": {}},
            {"id": uuid.uuid4(), "name": "perf", "t": NOW_MS - 8 * 86_400_000, "sid": None, "props": {}},
        ]
        out = await client_events.record(PLAYER, batch, NOW_MS, None, 57, now=NOW)
        assert out["accepted"] == [str(first)]
        assert sorted(r["reason"] for r in out["rejected"]) == ["too_old", "unknown_event"]
        # 没收到回复，整批重发：记过的算 duplicate，不再多一行。
        again = await client_events.record(PLAYER, batch[:1] + [
            {"id": second, "name": "tutorial_skip", "t": NOW_MS, "sid": None, "props": {"step": "PLACE_3"}}],
            NOW_MS, None, 57, now=NOW)
        assert again["accepted"] == [str(second)] and again["duplicate"] == [str(first)]
        async with db.pool().acquire() as conn:
            rows = await conn.fetch("select name, props, occurred_at, build from analytics_client_events"
                                    " where player_id = $1 order by occurred_at", PLAYER)
            assert [r["name"] for r in rows] == ["tutorial_step", "tutorial_skip"]
            assert json.loads(rows[0]["props"]) == {"from": "BUY_3", "to": "PLACE_3", "index": 1, "ms": 5300}
            assert rows[0]["occurred_at"] == NOW - dt.timedelta(seconds=1) and rows[0]["build"] == 57
            # 注销：上报的事件一起删。
            assert await conn.fetchval("select erase_player($1)", PLAYER) is True
            assert await conn.fetchval("select count(*) from analytics_client_events where player_id = $1", PLAYER) == 0

    run_with_db(body)
