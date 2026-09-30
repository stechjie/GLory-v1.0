"""运营数据第一批（database/025_analytics.sql，app/analytics.py、app/analytics_report.py）的行为用例。

分两半：
  · 记（在线时长怎么结账、写库失败丢什么留什么）—— 不连数据库，用真的连接表 + 假时钟；
  · 算（日活、留存、在线、对局）—— 真 PostgreSQL（没设 GLORY_TEST_PG 就跳过）。

最要紧的几条，它们的失败模式都**不会报错**，只会让报表上的数悄悄不对：
  1. 手机切后台之后那 95 秒不算在线；同一个人几台设备只算一份。
  2. 写库失败时「今天来过」不能丢（丢了他今天就不算日活）。
  3. 留存：D1 是第二天那一整天；多天合计按人数相加，不是平均百分比；没到的日子是「未到」不是 0。
  4. 没采到的时段不是 0 人；内部账号不算；025 之前注册的号不进留存。
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
from fastapi.testclient import TestClient

from app import admin, analytics, analytics_report, db, realtime
from app.admin_auth import Admin
from app.main import app
from pg_harness import requires_pg, run_with_db

MYT = dt.timezone(dt.timedelta(hours=8))
OPS = Admin(uuid.UUID("aaaaaaaa-0000-0000-0000-000000000001"), "alice")


def myt(month: int, day: int, hour: int = 12, minute: int = 0, second: int = 0) -> dt.datetime:
    return dt.datetime(2026, month, day, hour, minute, second, tzinfo=MYT)


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def _connect(hub: realtime.Hub, pid: uuid.UUID, device: str, at: float) -> realtime.Connection:
    """直接往连接表里挂一条（不走 WebSocket），last_seen 定在 at。"""
    conn = realtime.Connection(player_id=pid, device_session_id=device, websocket=None)  # type: ignore[arg-type]
    conn.last_seen = at
    hub._by_player.setdefault(pid, {})[device] = conn
    return conn


def _recorder(hub: realtime.Hub, clock: Clock, wall=None, queued: int = 0) -> analytics.Recorder:
    return analytics.Recorder(hub=lambda: hub, queued=lambda: queued, clock=clock,
                              wall=wall or (lambda: myt(10, 2)))


# --- 记：在线时长 -----------------------------------------------------------------------


def test_background_time_after_the_last_heartbeat_is_not_online() -> None:
    """★ 手机切后台：心跳停了，连接还要挂 95 秒才被判死。那 95 秒不算在线。"""
    hub, clock = realtime.Hub(), Clock()
    rec = _recorder(hub, clock)
    pid = uuid.uuid4()
    conn = _connect(hub, pid, "dev-aaaaaaaa", clock.now)
    rec.on_connect(pid)
    clock.now += 300                       # 玩了 5 分钟，最后一次心跳在第 300 秒
    conn.last_seen = clock.now
    clock.now += realtime.IDLE_TIMEOUT_SEC  # 切后台，95 秒后被判死
    hub.unregister(conn)
    rec.on_disconnect(conn)
    assert rec._seconds[pid] == pytest.approx(300 + analytics.TRAILING_SEC)
    assert pid not in rec._since


def test_two_devices_count_once_and_one_leaving_does_not_stop_the_clock() -> None:
    hub, clock = realtime.Hub(), Clock()
    rec = _recorder(hub, clock)
    pid = uuid.uuid4()
    phone = _connect(hub, pid, "dev-phone000", clock.now)
    rec.on_connect(pid)
    pc = _connect(hub, pid, "dev-pc000000", clock.now)
    rec.on_connect(pid)
    clock.now += 60
    phone.last_seen = pc.last_seen = clock.now
    hub.unregister(phone)
    rec.on_disconnect(phone)
    assert pid in rec._since and pid not in rec._seconds, "还有一台连着，不该结账"
    clock.now += 60
    pc.last_seen = clock.now
    hub.unregister(pc)
    rec.on_disconnect(pc)
    assert rec._seconds[pid] == pytest.approx(120), "两台设备同时在线只算一份"
    assert rec._connects[pid] == 2


def test_same_device_reconnect_keeps_counting() -> None:
    """同设备重连：新连接先挂上、旧连接后走 finally —— 这时他仍在线，不结账。"""
    hub, clock = realtime.Hub(), Clock()
    rec = _recorder(hub, clock)
    pid = uuid.uuid4()
    old = _connect(hub, pid, "dev-aaaaaaaa", clock.now)
    rec.on_connect(pid)
    clock.now += 30
    _connect(hub, pid, "dev-aaaaaaaa", clock.now)   # 替换了 old
    rec.on_connect(pid)
    hub.unregister(old)
    rec.on_disconnect(old)
    assert rec._since[pid] == 1000.0 and pid not in rec._seconds


class FakeConn:
    def __init__(self, fail: bool = False, tags: list | None = None) -> None:
        self.fail = fail
        self.tags = tags or []
        self.calls: list[tuple] = []

    async def execute(self, sql: str, *args):
        if self.fail:
            raise OSError("数据库一时连不上")
        self.calls.append((sql, args))
        return "INSERT 0 1"

    async def fetch(self, sql: str, *args):
        return [{"player_id": pid} for pid in self.tags]


def test_flush_settles_online_players_up_to_their_last_heartbeat() -> None:
    import asyncio

    hub, clock = realtime.Hub(), Clock()
    rec = _recorder(hub, clock)
    pid = uuid.uuid4()
    conn = _connect(hub, pid, "dev-aaaaaaaa", clock.now)
    rec.on_connect(pid)
    clock.now += 60
    conn.last_seen = clock.now - 50          # 50 秒没心跳了（刚切后台）
    fake = FakeConn(tags=[pid])
    assert asyncio.run(rec.flush(fake)) == 1
    _sql, args = fake.calls[0]
    day, _now, pids, secs, connects = args
    assert day == dt.date(2026, 10, 2) and pids == [pid] and connects == [1]
    assert secs == [round(10 + analytics.TRAILING_SEC)]
    assert rec._since[pid] == clock.now, "结完账从此刻重新起算"
    assert rec.internal_online() == 1, "每分钟重读内部账号"


def test_failed_flush_keeps_who_came_today_but_drops_the_minute() -> None:
    """★ 写库失败：这一分钟的时长丢了没关系，但「今天连过」不能丢 —— 丢了他今天就不算日活。"""
    import asyncio

    hub, clock = realtime.Hub(), Clock()
    rec = _recorder(hub, clock)
    pid = uuid.uuid4()
    conn = _connect(hub, pid, "dev-aaaaaaaa", clock.now)
    rec.on_connect(pid)
    clock.now += 20
    conn.last_seen = clock.now
    hub.unregister(conn)
    rec.on_disconnect(conn)                  # 连了 20 秒就走了
    with pytest.raises(OSError):
        asyncio.run(rec.flush(FakeConn(fail=True)))
    assert rec._connects == {pid: 1}
    ok = FakeConn()
    asyncio.run(rec.flush(ok))
    _sql, (_day, _now, pids, secs, connects) = ok.calls[0]
    assert pids == [pid] and connects == [1] and secs == [0]


def test_sample_counts_people_not_connections_and_marks_internal() -> None:
    import asyncio

    hub, clock = realtime.Hub(), Clock()
    staff, player = uuid.uuid4(), uuid.uuid4()
    _connect(hub, staff, "dev-aaaaaaaa", clock.now)
    _connect(hub, player, "dev-phone000", clock.now)
    _connect(hub, player, "dev-pc000000", clock.now)
    rec = _recorder(hub, clock, queued=5)
    rec.set_internal(staff, True)
    fake = FakeConn()
    asyncio.run(rec.sample(fake))
    _sql, (_at, epoch, interval, players, internal, connections, queued) = fake.calls[0]
    assert (players, internal, connections) == (2, 1, 3)
    assert queued == 2, "排队的人一定连着：夹到在线人数以内，免得撞表约束"
    assert epoch == rec.epoch and interval == analytics.SAMPLE_SEC


def test_game_day_is_malaysia_time() -> None:
    # 马来西亚 10-02 00:30 = UTC 10-01 16:30
    assert analytics.game_day(dt.datetime(2026, 10, 1, 16, 30, tzinfo=dt.UTC)) == dt.date(2026, 10, 2)


# --- 接口 -------------------------------------------------------------------------------


def test_analytics_api_needs_an_admin_session() -> None:
    client = TestClient(app)
    for path in ("/admin/api/analytics/overview", "/admin/api/analytics/retention",
                 "/admin/api/analytics/matches", "/admin/api/analytics/tags",
                 "/admin/api/analytics/online?day=2026-10-01"):
        assert client.get(path).status_code == 401, path
        assert client.get(path, headers={"Authorization": "Bearer player-token"}).status_code == 401, path


# --- 算：真库 ---------------------------------------------------------------------------


async def _player(conn, created: dt.datetime) -> uuid.UUID:
    pid = uuid.uuid4()
    await conn.execute("insert into players (player_id, created_at) values ($1, $2)", pid, created)
    return pid


async def _came(conn, pid: uuid.UUID, day: dt.date, seconds: int = 600, connects: int = 1) -> None:
    await conn.execute(
        "insert into analytics_player_days (game_day, player_id, first_seen_at, last_seen_at, online_seconds, connects)"
        " values ($1, $2, now(), now(), $3, $4)", day, pid, seconds, connects)


async def _sample(conn, at: dt.datetime, players: int, internal: int = 0, epoch: uuid.UUID | None = None,
                  queued: int = 0) -> None:
    await conn.execute(
        "insert into analytics_online_samples (sampled_at, server_epoch, interval_sec, players, internal,"
        " connections, queued) values ($1, $2, 15, $3, $4, $3, $5)",
        at, epoch or uuid.UUID(int=1), players, internal, queued)


async def _golden(conn) -> dict:
    """docs 第 12.1 节的黄金数据集（做了等价缩写）。"""
    await _sample(conn, myt(10, 1, 0, 0, 5), 0)                  # 10-01 00:00:05 开始记录
    d = lambda day: dt.date(2026, 10, day)  # noqa: E731
    first = [await _player(conn, myt(10, 1, 9)) for _ in range(10)]
    for p in first:
        await _came(conn, p, d(1), connects=20)                  # 同一个人重连 20 次也只算一个
    for p in first[:4]:
        await _came(conn, p, d(2))
    for p in first[:3]:
        await _came(conn, p, d(3))
    for p in first[:2]:
        await _came(conn, p, d(4))
    await _came(conn, first[0], d(8))
    # 员工 2 个：天天来，但不算
    staff = [await _player(conn, myt(10, 1, 9)) for _ in range(2)]
    for p in staff:
        await conn.execute("insert into analytics_account_tags (player_id, kind, tagged_by) values ($1, 'staff', 'pytest')", p)
        for day in range(1, 9):
            await _came(conn, p, d(day))
    # 老号：记录开始前注册，10-02 来了 —— 算日活，不进任何一天的新增 / 留存
    old = await _player(conn, myt(9, 20))
    await _came(conn, old, d(2))
    # 10-02 注册 2 个，第二天都回来
    second = [await _player(conn, myt(10, 2, 20)) for _ in range(2)]
    for p in second:
        await _came(conn, p, d(2))
        await _came(conn, p, d(3))
    # 注销了的号：不进留存
    gone = await _player(conn, myt(10, 1, 10))
    await conn.execute("update players set deleted_at = now() where player_id = $1", gone)
    return {"first": first, "staff": staff, "old": old, "second": second}


def _cell(cohort: dict, n: int) -> dict:
    return next(c for c in cohort["cells"] if c["n"] == n)


@requires_pg
def test_retention_golden_dataset() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            await _golden(conn)
        # 10-07 看：10-01 那批的 D7（10-08）还没到
        early = await analytics_report.retention(30, now=myt(10, 7))
        oct1 = next(c for c in early["cohorts"] if c["day"] == "2026-10-01")
        assert oct1["size"] == 10, "员工、老号、注销的都不在里面"
        assert [(_cell(oct1, n)["returned"]) for n in (0, 1, 2, 3)] == [10, 4, 3, 2]
        assert _cell(oct1, 7) == {"n": 7, "state": "future", "returned": None}, "没到是「未到」，不是 0"
        assert _cell(oct1, 6)["state"] == "today"
        oct2 = next(c for c in early["cohorts"] if c["day"] == "2026-10-02")
        assert oct2["size"] == 2 and _cell(oct2, 1)["returned"] == 2
        # ★ 合计 D1 = (4+2)/(10+2) = 50%，不是 (40%+100%)/2 = 70%
        d1 = next(t for t in early["total"] if t["n"] == 1)
        assert (d1["returned"], d1["size"]) == (6, 12)
        # 10-09 看：D7 = 1/10
        later = await analytics_report.retention(30, now=myt(10, 9))
        oct1 = next(c for c in later["cohorts"] if c["day"] == "2026-10-01")
        assert _cell(oct1, 7) == {"n": 7, "state": "done", "returned": 1}
        d7 = next(t for t in later["total"] if t["n"] == 7)
        assert (d7["returned"], d7["size"], d7["cohorts"]) == (1, 10, 1), "10-02 那批的 D7（10-09）今天还没过完，不进合计"

    run_with_db(body)


@requires_pg
def test_overview_counts_people_excludes_staff_and_never_invents_zeros() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            await _golden(conn)
            # 10-02：前 12 小时每 15 秒一行，后 12 小时服务器没起来（没有行）
            start = myt(10, 2, 0, 0, 0)
            await conn.execute(
                "insert into analytics_online_samples (sampled_at, server_epoch, interval_sec, players, internal,"
                " connections, queued)"
                " select $1::timestamptz + make_interval(secs => 15 * i), $2, 15,"
                "        case when i = 100 then 9 else 3 end, 1, 9, 0"
                "   from generate_series(0, 12 * 240 - 1) as i", start, uuid.UUID(int=1))
        out = await analytics_report.overview(5, now=myt(10, 3, 12))
        days = {d["day"]: d for d in out["days"]}
        sep29 = days["2026-09-29"]
        assert sep29["recorded"] is False and sep29["active"] is None, "开始记录之前是「没记」，不是 0"
        oct2 = days["2026-10-02"]
        # 4（10-01 那批）+ 老号 + 2（10-02 新注册）= 7；员工 2 个另算
        assert (oct2["active"], oct2["active_internal"]) == (7, 2)
        assert oct2["registered"] == 2
        assert oct2["peak"] == 8 and oct2["peak_at"] == (start + dt.timedelta(seconds=1500)).astimezone(dt.UTC).isoformat()
        assert oct2["coverage"] == pytest.approx(0.5), "缺的半天是覆盖率不到，不是 0 人"
        assert oct2["minutes_avg"] == 10.0
        oct1 = days["2026-10-01"]
        assert oct1["registered"] == 11 and oct1["registered_internal"] == 2, "注销的也注册过；员工单列"
        assert oct1["weekly_partial"] is True, "近 7 天里有 6 天还没开始记"
        assert days["2026-10-03"]["weekly_active"] == 13, "按人去重：10 + 老号 + 2，不是日活相加"
        assert days["2026-10-03"]["coverage"] == 0.0, "那天一行采样都没有：覆盖 0，在线人数给不出"
        assert days["2026-10-03"]["peak"] is None
        assert out["ever_active"] == 13 and out["internal_accounts"] == 2

    run_with_db(body)


@requires_pg
def test_online_curve_breaks_on_gaps_and_marks_restarts() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            before, after = uuid.UUID(int=1), uuid.UUID(int=2)
            await _sample(conn, myt(10, 2, 0, 0, 10), 4, epoch=before)
            await _sample(conn, myt(10, 2, 0, 0, 40), 6, internal=1, epoch=before)
            await _sample(conn, myt(10, 2, 0, 1, 10), 2, epoch=before)
            await _sample(conn, myt(10, 2, 0, 30, 0), 1, epoch=after, queued=1)   # 重启过
        out = await analytics_report.online_curve(dt.date(2026, 10, 2))
        assert out["points"] == [[0, 5, 0], [1, 2, 0], [30, 1, 1]], "每分钟取最高；内部账号减掉"
        assert out["restarts"] == [myt(10, 2, 0, 30).astimezone(dt.UTC).isoformat()]

    run_with_db(body)


@requires_pg
def test_recorder_writes_one_row_per_person_per_day_and_splits_at_midnight() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            pid = await _player(conn, myt(10, 1, 9))
        hub, clock = realtime.Hub(), Clock()
        wall = [myt(10, 1, 23, 59)]
        rec = _recorder(hub, clock, wall=lambda: wall[0])
        conn_ = _connect(hub, pid, "dev-aaaaaaaa", clock.now)
        rec.on_connect(pid)
        async with db.pool().acquire() as conn:
            for _ in range(3):                                 # 23:59 前后各写几次，一直开着
                clock.now += 60
                conn_.last_seen = clock.now
                await rec.flush(conn)
                wall[0] += dt.timedelta(minutes=1)
            await rec.sample(conn)
            rows = await conn.fetch("select game_day, online_seconds, connects from analytics_player_days"
                                    " where player_id = $1 order by game_day", pid)
        assert [(r["game_day"], r["online_seconds"], r["connects"]) for r in rows] == [
            (dt.date(2026, 10, 1), 60, 1), (dt.date(2026, 10, 2), 120, 0)], "跨午夜两天各一行，不用重新登录"

    run_with_db(body)


@requires_pg
def test_tagging_is_audited_and_takes_effect_on_the_live_count() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            pid = await _player(conn, myt(10, 1, 9))
        analytics.reset()
        try:
            await admin.tag_player(OPS, pid, "qa", "测试机")
            assert pid in analytics.current()._internal
            await admin.tag_player(OPS, pid, "staff", "")
            with pytest.raises(admin.AdminRejected):
                await admin.tag_player(OPS, pid, "vip", "")
            await admin.untag_player(OPS, pid)
            assert pid not in analytics.current()._internal
            with pytest.raises(admin.AdminRejected) as refused:
                await admin.untag_player(OPS, pid)
            assert refused.value.status == 409
        finally:
            analytics.reset()
        async with db.pool().acquire() as conn:
            audit = await conn.fetch("select action, detail from admin_audit where player_id = $1 order by audit_id", pid)
        assert [a["action"] for a in audit] == ["analytics.tag", "analytics.tag", "analytics.untag"]
        assert '"previous": "qa"' in audit[1]["detail"]

    run_with_db(body)


@requires_pg
def test_erasing_an_account_removes_its_activity_rows() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            pid = await _player(conn, myt(10, 1, 9))
            await _came(conn, pid, dt.date(2026, 10, 1))
            await conn.execute("insert into analytics_account_tags (player_id, kind, tagged_by) values ($1, 'qa', 'pytest')", pid)
            assert await conn.fetchval("select erase_player($1)", pid) is True
            assert await conn.fetchval("select count(*) from analytics_player_days where player_id = $1", pid) == 0
            assert await conn.fetchval("select count(*) from analytics_account_tags where player_id = $1", pid) == 0

    run_with_db(body)


@requires_pg
def test_matches_summary_counts_games_not_seats() -> None:
    """一局 4 真人 + 2 AI = 1 局、4 个真人座位、2 个 AI 座位，不是 6 局。"""

    async def body() -> None:
        async with db.pool().acquire() as conn:
            humans = [await _player(conn, myt(10, 1, 9)) for _ in range(4)]
            for uid, rounds, online in (("a" * 32, 10, [True, True, True, False]), ("b" * 32, 21, [True] * 4)):
                await conn.execute(
                    "insert into match_records (match_uid, mode, protocol, server_epoch, room_id, started_at, ended_at,"
                    " rounds, outcome, team_a_hp, team_b_hp, gold_authoritative, carrot_authoritative)"
                    " values ($1, 'casual', 34, 1, 1, $2, $3, $4, 'team_a', 10, 0, false, true)",
                    uid, myt(10, 2, 10), myt(10, 2, 10, 20), rounds)
                for slot in range(6):
                    player = humans[slot] if slot < 4 else None
                    await conn.execute(
                        "insert into match_seats (match_uid, slot, team, player_id, was_ai, online_at_end, gold, carrots,"
                        " carrots_spent) values ($1, $2, $3, $4, $5, $6, 0, 0, 0)",
                        uid, slot, 0 if slot < 3 else 1, player, player is None,
                        online[slot] if slot < 4 else True)
        out = await analytics_report.matches(7, now=myt(10, 3))
        [casual] = out["modes"]
        assert (casual["matches"], casual["humans"], casual["bots"], casual["left_early"]) == (2, 8, 4, 1)
        assert casual["full_length"] == 1 and casual["all_human"] == 0 and casual["median_minutes"] == 20.0
        assert casual["end_rounds"] == [[10, "boss", 1], [21, "pvp", 1]]

    run_with_db(body)
