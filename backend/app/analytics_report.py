"""后台「数据」页怎么算（口径见 docs/运营数据.md 第二节）。

读 025 的两张表（在线采样、每日活跃），加上早就有的注册时间（players.created_at）
和对局历史（013 的 match_records / match_seats）。**只读**，不改任何东西。

## 三种「没有数字」分开，都不是 0

- 还没开始记：025 上线之前的日子，日活、在线给 None（页面写「没记」）；
- 记了但缺一段：账号服务器重启、数据库一时写不进 —— 给采集覆盖率，页面标出来；
- 日子还没到：留存的 D7 要等第 7 天过完，给 None + 状态 future（页面写「未到」）。

## 内部账号默认排除

员工 / QA / 压测号（analytics_account_tags）不进日活、新增、留存、在线人数；排除了几个另给数。
按「现在」的标签算 —— 只有在线采样是按采样那一刻（见 025 文件头）。

## 留存

按注册日分组（注册 = 第一次打开游戏时自动建号）。D1 = 注册后第二天那一整天来过，不是「两天内来过」。
多天合计 = 各天回来的人数相加 / 各天人数相加（只算已经过完的那些天），**不是把百分比平均**。
只算 025 开始记录之后注册的号：之前注册的号，他们注册那几天来没来过已经没法知道。
"""

from __future__ import annotations

import collections
import datetime as dt
import json
import pathlib
import statistics

import asyncpg

from app import admission, analytics, db, realtime
from app.admin import AdminRejected

MAX_DAYS = 90
RETENTION_OFFSETS = (0, 1, 2, 3, 4, 5, 6, 7, 14, 30)
TZ_NAME = "Asia/Kuala_Lumpur"

_ROUND_SCHEDULE = pathlib.Path(__file__).resolve().parents[2] / "data" / "rounds" / "round_schedule.json"


def _utc_now() -> dt.datetime:
    return dt.datetime.now(dt.UTC)


def _iso(value: dt.datetime | None) -> str | None:
    return None if value is None else value.astimezone(dt.UTC).isoformat()


def _bounds(first: dt.date, last: dt.date) -> tuple[dt.datetime, dt.datetime]:
    """[first 那天 0 点, last 第二天 0 点)，马来西亚时间。"""
    start = dt.datetime.combine(first, dt.time(), tzinfo=analytics.GAME_TZ)
    end = dt.datetime.combine(last + dt.timedelta(days=1), dt.time(), tzinfo=analytics.GAME_TZ)
    return start, end


def _check_days(days: int) -> None:
    if not 1 <= days <= MAX_DAYS:
        raise AdminRejected("天数要在 1 到 %d 之间" % MAX_DAYS)


def _not_ready() -> AdminRejected:
    return AdminRejected("数据库还没跑 database/025_analytics.sql，运营数据还没开始记", 503)


# --- 每天 ------------------------------------------------------------------------------

_ACTIVE = """
select a.game_day,
       count(*) filter (where t.player_id is null)     as active,
       count(*) filter (where t.player_id is not null) as internal,
       coalesce(sum(a.online_seconds) filter (where t.player_id is null), 0) as seconds,
       percentile_cont(0.5) within group (order by a.online_seconds) filter (where t.player_id is null) as p50,
       percentile_cont(0.9) within group (order by a.online_seconds) filter (where t.player_id is null) as p90
  from analytics_player_days a
  left join analytics_account_tags t on t.player_id = a.player_id
 where a.game_day between $1 and $2
 group by a.game_day
"""

# 近 7 天（含当天）来过的人，按人去重 —— 不是 7 天日活相加。
_WEEKLY = """
select g.day::date as day, count(distinct a.player_id) as active
  from generate_series($1::date, $2::date, interval '1 day') as g(day)
  join analytics_player_days a on a.game_day between g.day::date - 6 and g.day::date
 where not exists (select 1 from analytics_account_tags t where t.player_id = a.player_id)
 group by g.day
"""

_SAMPLES = """
select (sampled_at at time zone $3)::date as day,
       sum(interval_sec)        as covered,
       avg(players - internal)  as avg_online,
       max(players - internal)  as peak,
       max(queued)              as queue_peak
  from analytics_online_samples
 where sampled_at >= $1 and sampled_at < $2
 group by 1
"""

# 每天最高在线出现在哪一刻（同样高取最早那次）。
_PEAKS = """
select distinct on ((sampled_at at time zone $3)::date)
       (sampled_at at time zone $3)::date as day, sampled_at
  from analytics_online_samples
 where sampled_at >= $1 and sampled_at < $2
 order by (sampled_at at time zone $3)::date, players - internal desc, sampled_at
"""

_REGISTERED = """
select (p.created_at at time zone $3)::date as day,
       count(*) filter (where t.player_id is null)     as registered,
       count(*) filter (where t.player_id is not null) as internal
  from players p
  left join analytics_account_tags t on t.player_id = p.player_id
 where p.created_at >= $1 and p.created_at < $2
 group by 1
"""

_MATCHES_PER_DAY = """
select (ended_at at time zone $3)::date as day, count(*) as matches
  from match_records
 where ended_at >= $1 and ended_at < $2
 group by 1
"""

_EVER_ACTIVE = """
select count(distinct a.player_id)
  from analytics_player_days a
 where not exists (select 1 from analytics_account_tags t where t.player_id = a.player_id)
"""


def _minutes(seconds: float | None) -> float | None:
    return None if seconds is None else round(float(seconds) / 60.0, 1)


async def overview(days: int, now: dt.datetime | None = None) -> dict:
    _check_days(days)
    now = now or _utc_now()
    today = analytics.game_day(now)
    first = today - dt.timedelta(days=days - 1)
    start, end = _bounds(first, today)
    async with db.pool().acquire() as conn:
        try:
            started = await conn.fetchval("select min(sampled_at) from analytics_online_samples")
            active = {r["game_day"]: r for r in await conn.fetch(_ACTIVE, first, today)}
            weekly = {r["day"]: int(r["active"]) for r in await conn.fetch(_WEEKLY, first, today)}
            samples = {r["day"]: r for r in await conn.fetch(_SAMPLES, start, end, TZ_NAME)}
            peaks = {r["day"]: r["sampled_at"] for r in await conn.fetch(_PEAKS, start, end, TZ_NAME)}
            registered = {r["day"]: r for r in await conn.fetch(_REGISTERED, start, end, TZ_NAME)}
            ever_active = int(await conn.fetchval(_EVER_ACTIVE))
            tagged = int(await conn.fetchval("select count(*) from analytics_account_tags"))
        except asyncpg.UndefinedTableError:
            raise _not_ready() from None
        matches = {r["day"]: int(r["matches"]) for r in await conn.fetch(_MATCHES_PER_DAY, start, end, TZ_NAME)}

    start_day = analytics.game_day(started) if started is not None else None
    rows = []
    for back in range(days):
        day = today - dt.timedelta(days=back)
        a, s, reg = active.get(day), samples.get(day), registered.get(day)
        # 这天有没有记：025 上线之前、或者整天一行都没写进去（服务器一直没起来）—— 都是「没有数」，不是 0。
        recorded = start_day is not None and day >= start_day and (a is not None or s is not None)
        day_start, day_end = _bounds(day, day)
        elapsed = (min(now, day_end) - day_start).total_seconds()
        coverage = None
        if recorded and elapsed > 0:
            coverage = min(1.0, float(s["covered"]) / elapsed) if s is not None else 0.0
        count = int(a["active"]) if a is not None else 0
        rows.append({
            "day": day.isoformat(),
            "recorded": recorded,
            "active": count if recorded else None,
            "active_internal": (int(a["internal"]) if a is not None else 0) if recorded else None,
            "weekly_active": weekly.get(day, 0) if recorded else None,
            # 近 7 天里有几天还没开始记：这个数偏小。
            "weekly_partial": bool(recorded and day - dt.timedelta(days=6) < start_day),
            "registered": int(reg["registered"]) if reg is not None else 0,
            "registered_internal": int(reg["internal"]) if reg is not None else 0,
            "peak": int(s["peak"]) if s is not None else None,
            "peak_at": _iso(peaks.get(day)),
            "avg_online": round(float(s["avg_online"]), 1) if s is not None else None,
            "queue_peak": int(s["queue_peak"]) if s is not None else None,
            "coverage": coverage,
            "minutes_avg": _minutes(float(a["seconds"]) / count) if recorded and count else None,
            "minutes_p50": _minutes(a["p50"]) if recorded and count else None,
            "minutes_p90": _minutes(a["p90"]) if recorded and count else None,
            "matches": matches.get(day, 0),
        })

    recorder = analytics.current()
    internal_now = recorder.internal_online()
    return {
        "as_of": _iso(now),
        "today": today.isoformat(),
        "timezone": TZ_NAME,
        "collection_started_at": _iso(started),
        "now": {
            # 这一刻连着账号服务器的真人（内部账号已减掉）。
            "players": realtime.hub().player_count() - internal_now,
            "internal": internal_now,
            "queued": admission.current().stats()["queued_connected"],
        },
        "ever_active": ever_active,
        "internal_accounts": tagged,
        "days": rows,
    }


# --- 某一天的在线曲线 ---------------------------------------------------------------------

_CURVE = """
select date_trunc('minute', sampled_at) as minute,
       max(players - internal) as players,
       max(queued)             as queued
  from analytics_online_samples
 where sampled_at >= $1 and sampled_at < $2
 group by 1
 order by 1
"""

_EPOCHS = """
select server_epoch, min(sampled_at) as first
  from analytics_online_samples
 where sampled_at >= $1 and sampled_at < $2
 group by server_epoch
 order by first
"""


async def online_curve(day: dt.date) -> dict:
    """每分钟一个点（那一分钟里最高的一次采样）。没采到的分钟没有点 —— 页面上断开，不画成 0。"""
    start, end = _bounds(day, day)
    async with db.pool().acquire() as conn:
        try:
            rows = await conn.fetch(_CURVE, start, end)
            epochs = await conn.fetch(_EPOCHS, start, end)
        except asyncpg.UndefinedTableError:
            raise _not_ready() from None
    return {
        "day": day.isoformat(),
        # [第几分钟（0–1439，马来西亚时间）, 在线, 排队]
        "points": [[int((r["minute"] - start).total_seconds() // 60), int(r["players"]), int(r["queued"])]
                   for r in rows],
        # 这一天里账号服务器（重新）启动的时刻：前面那段空白是重启，不是没人。
        "restarts": [_iso(r["first"]) for r in epochs[1:]],
    }


# --- 留存 -------------------------------------------------------------------------------

# $1 开始记录的时刻、$2..$3 注册日范围、$4 时区。注销了的号不算：他的每日活跃已经删了，算进来只会压低留存。
_COHORT = """
with cohort as (
  select p.player_id, (p.created_at at time zone $4)::date as day
    from players p
   where p.created_at >= $1
     and p.deleted_at is null
     and (p.created_at at time zone $4)::date between $2 and $3
     and not exists (select 1 from analytics_account_tags t where t.player_id = p.player_id)
)
"""

_COHORT_SIZES = _COHORT + "select day, count(*) as size from cohort group by day"

# 每日活跃一人一天最多一行（主键），count 就是人数。
_COHORT_RETURNS = _COHORT + """
select c.day, n.k, count(*) as returned
  from cohort c
  cross join unnest($5::int[]) as n(k)
  join analytics_player_days a on a.player_id = c.player_id and a.game_day = c.day + n.k
 group by c.day, n.k
"""


async def retention(days: int, now: dt.datetime | None = None) -> dict:
    _check_days(days)
    now = now or _utc_now()
    today = analytics.game_day(now)
    first = today - dt.timedelta(days=days - 1)
    async with db.pool().acquire() as conn:
        try:
            started = await conn.fetchval("select min(sampled_at) from analytics_online_samples")
            if started is None:
                sizes, returns = {}, {}
            else:
                sizes = {r["day"]: int(r["size"])
                         for r in await conn.fetch(_COHORT_SIZES, started, first, today, TZ_NAME)}
                returns = {(r["day"], int(r["k"])): int(r["returned"])
                           for r in await conn.fetch(_COHORT_RETURNS, started, first, today, TZ_NAME,
                                                     list(RETENTION_OFFSETS))}
        except asyncpg.UndefinedTableError:
            raise _not_ready() from None

    totals = {k: [0, 0, 0] for k in RETENTION_OFFSETS}   # 回来的人、人数、几天
    cohorts = []
    for day in sorted(sizes, reverse=True):
        size = sizes[day]
        cells = []
        for k in RETENTION_OFFSETS:
            target = day + dt.timedelta(days=k)
            state = "done" if target < today else ("today" if target == today else "future")
            returned = returns.get((day, k), 0)
            cells.append({"n": k, "state": state, "returned": None if state == "future" else returned})
            if state == "done":
                totals[k][0] += returned
                totals[k][1] += size
                totals[k][2] += 1
        cohorts.append({"day": day.isoformat(), "size": size, "cells": cells})
    return {
        "as_of": _iso(now),
        "today": today.isoformat(),
        "collection_started_at": _iso(started),
        "offsets": list(RETENTION_OFFSETS),
        "cohorts": cohorts,
        # 只算已经过完的格子：回来的人相加 / 人数相加。
        "total": [{"n": k, "returned": r, "size": s, "cohorts": c} for k, (r, s, c) in totals.items()],
    }


# --- 对局 -------------------------------------------------------------------------------

# 只有打完、并且有人把战报交上来的局（013）。中途散了、全员掉线没人交的局这里没有。
_MATCH_ROWS = """
select r.mode, r.rounds, r.outcome,
       extract(epoch from r.ended_at - r.started_at)::int as seconds,
       count(s.slot) filter (where s.player_id is not null) as humans,
       count(s.slot) filter (where s.player_id is null) as bots,
       count(s.slot) filter (where s.player_id is not null and not s.online_at_end) as left_early
  from match_records r
  left join match_seats s on s.match_uid = r.match_uid
 where r.ended_at >= $1 and r.ended_at < $2
 group by r.match_uid
"""


def _round_kinds() -> tuple[int, dict[int, str]]:
    """回合 → boss / pvp / 普通（data/rounds/round_schedule.json）。读不到就只给回合号。"""
    try:
        schedule = json.loads(_ROUND_SCHEDULE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return 21, {}
    kinds = {int(r): "boss" for r in schedule.get("boss_rounds", [])}
    kinds.update({int(r): "pvp" for r in schedule.get("pvp_rounds", [])})
    return int(schedule.get("final_round", 21)), kinds


async def matches(days: int, now: dt.datetime | None = None) -> dict:
    _check_days(days)
    now = now or _utc_now()
    today = analytics.game_day(now)
    start, end = _bounds(today - dt.timedelta(days=days - 1), today)
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(_MATCH_ROWS, start, end)
    final_round, kinds = _round_kinds()
    modes: dict[str, dict] = {}
    for r in rows:
        m = modes.setdefault(r["mode"], {
            "mode": r["mode"], "matches": 0, "rounds": 0, "full_length": 0, "all_human": 0,
            "humans": 0, "bots": 0, "left_early": 0, "draws": 0, "minutes": [],
            "end_rounds": collections.Counter()})
        m["matches"] += 1
        m["rounds"] += int(r["rounds"])
        m["full_length"] += int(r["rounds"]) >= final_round
        m["all_human"] += int(r["humans"]) == 6
        m["humans"] += int(r["humans"])
        m["bots"] += int(r["bots"])
        m["left_early"] += int(r["left_early"])
        m["draws"] += r["outcome"] == "draw"
        m["minutes"].append(max(0, int(r["seconds"])) / 60.0)
        m["end_rounds"][int(r["rounds"])] += 1
    out = []
    for m in sorted(modes.values(), key=lambda x: -x["matches"]):
        out.append({
            "mode": m["mode"], "matches": m["matches"],
            "avg_rounds": round(m["rounds"] / m["matches"], 1),
            "median_minutes": round(statistics.median(m["minutes"]), 1),
            "full_length": m["full_length"], "all_human": m["all_human"], "draws": m["draws"],
            "humans": m["humans"], "bots": m["bots"], "left_early": m["left_early"],
            "end_rounds": [[rnd, kinds.get(rnd, "normal"), n] for rnd, n in sorted(m["end_rounds"].items())],
        })
    return {"as_of": _iso(now), "final_round": final_round, "modes": out}


# --- 游戏上报的事件（第二批，database/026）----------------------------------------------------
#
# 只有装了新包的人才会报。所以下面每一块的分母都是「报过事件的人」，不是全部日活 ——
# 新包覆盖率那一块单独给出这个比例。回合结果虽然是服务器算的，但经客户端转来，只做统计。

MODES = ("all", "custom", "casual", "ranked")

_EXTERNAL = "not exists (select 1 from analytics_account_tags t where t.player_id = e.player_id)"
_IN_RANGE = "e.occurred_at >= $1 and e.occurred_at < $2 and " + _EXTERNAL

_COVERAGE = """
select (e.occurred_at at time zone $3)::date as day, count(distinct e.player_id) as players, count(*) as events
  from analytics_client_events e
 where """ + _IN_RANGE + """
 group by 1
"""

_BUILDS = """
select coalesce(e.build, 0) as build, count(distinct e.player_id) as players, max(e.occurred_at) as last_seen
  from analytics_client_events e
 where """ + _IN_RANGE + """
 group by 1 order by 2 desc limit 20
"""

# 在这段时间里开始过教学的人（重玩的也算一个人）。他们之后的每一步都算，不管落在哪天。
_STARTERS = """
with starters as (
  select distinct e.player_id from analytics_client_events e
   where e.name = 'tutorial_start' and """ + _IN_RANGE + """
)
"""

_TUTORIAL_TOTALS = _STARTERS + """
select (select count(*) from starters) as started,
       count(distinct e.player_id) filter (where e.name = 'tutorial_step' and e.props->>'to' = 'DONE') as completed,
       count(distinct e.player_id) filter (where e.name = 'tutorial_skip') as skipped
  from analytics_client_events e join starters s on s.player_id = e.player_id
 where e.name in ('tutorial_step', 'tutorial_skip')
"""

_TUTORIAL_STEPS = _STARTERS + """
select (e.props->>'index')::int as idx, e.props->>'from' as step,
       count(distinct e.player_id) as done,
       percentile_cont(0.5) within group (order by (e.props->>'ms')::bigint) as p50,
       percentile_cont(0.9) within group (order by (e.props->>'ms')::bigint) as p90
  from analytics_client_events e join starters s on s.player_id = e.player_id
 where e.name = 'tutorial_step' and e.props ? 'index'
 group by 1, 2
"""

_TUTORIAL_SKIPS = _STARTERS + """
select (e.props->>'index')::int as idx, count(distinct e.player_id) as skipped
  from analytics_client_events e join starters s on s.player_id = e.player_id
 where e.name = 'tutorial_skip' and e.props ? 'index'
 group by 1
"""

# 新玩家第一次体验：这段时间注册、装的是新包（报过事件）的号。第二天回没回来只算已经过完第二天的。
_FIRST_PLAY = """
with cohort as (
  select p.player_id, (p.created_at at time zone $3)::date as day
    from players p
   where p.created_at >= $1 and p.created_at < $2 and p.deleted_at is null
     and not exists (select 1 from analytics_account_tags t where t.player_id = p.player_id)
     and exists (select 1 from analytics_client_events x where x.player_id = p.player_id)
),
did as (
  select c.player_id, c.day,
    bool_or(e.name = 'tutorial_start') as tutorial_started,
    bool_or(e.name = 'tutorial_step' and e.props->>'to' = 'DONE') as tutorial_done,
    bool_or(e.name = 'tutorial_skip') as tutorial_skipped,
    bool_or(e.name = 'match_start') as match_started,
    bool_or(e.name = 'round_result' and (e.props->>'over')::boolean) as match_finished
  from cohort c join analytics_client_events e on e.player_id = c.player_id
  group by c.player_id, c.day
)
select count(*) as players,
       count(*) filter (where tutorial_started) as tutorial_started,
       count(*) filter (where tutorial_done) as tutorial_done,
       count(*) filter (where tutorial_skipped and not tutorial_done) as tutorial_skipped,
       count(*) filter (where match_started) as match_started,
       count(*) filter (where match_finished) as match_finished,
       count(*) filter (where d.day + 1 < $4) as d1_ready,
       count(*) filter (where d.day + 1 < $4 and exists (
         select 1 from analytics_player_days a where a.player_id = d.player_id and a.game_day = d.day + 1)) as d1_back
  from did d
"""

# 回合：一支队伍的一回合 = (battle, team)。同队三个人都报，按它去重。
_ROUNDS = """
select (e.props->>'round')::int as round, max(e.props->>'kind') as kind,
       count(distinct (e.props->>'battle') || ':' || (e.props->>'team')) as teams,
       count(distinct (e.props->>'battle') || ':' || (e.props->>'team'))
         filter (where not (e.props->>'won')::boolean) as lost,
       count(distinct (e.props->>'battle') || ':' || (e.props->>'team'))
         filter (where (e.props->>'over')::boolean and (e.props->>'hp')::int <= 0) as eliminated,
       avg((e.props->>'hp')::int) as avg_hp
  from analytics_client_events e
 where e.name = 'round_result' and """ + _IN_RANGE + """
   and e.props ? 'battle' and e.props ? 'round' and e.props ? 'won'
   and ($3 = 'all' or e.props->>'mode' = $3)
 group by 1 order by 1
"""

_REASONS = """
select e.name, coalesce(e.props->>'reason', '') as reason, count(*) as times, count(distinct e.player_id) as players
  from analytics_client_events e
 where e.name in ('replay_failed', 'reconnect', 'room_action_failed', 'match_leave') and """ + _IN_RANGE + """
   and (e.name <> 'reconnect' or not (e.props->>'ok')::boolean)
 group by 1, 2 order by 3 desc
"""

_COUNTS = """
select e.name, count(*) as times, count(distinct e.player_id) as players
  from analytics_client_events e
 where e.name in ('replay_done', 'replay_failed', 'reconnect', 'match_start', 'match_leave', 'events_dropped')
   and """ + _IN_RANGE + """
 group by 1
"""

_ERRORS = """
select e.props->>'kind' as kind, e.props->>'where' as place, e.props->>'msg' as msg,
       count(*) as times, count(distinct e.player_id) as players, max(e.build) as build, max(e.occurred_at) as last_seen
  from analytics_client_events e
 where e.name = 'client_error' and """ + _IN_RANGE + """
 group by 1, 2, 3 order by 5 desc, 4 desc limit 30
"""

_PERF = """
select coalesce(e.props->>'ctx', '') as ctx, count(*) as samples, count(distinct e.player_id) as players,
       percentile_cont(0.5) within group (order by (e.props->>'fps')::float) as fps_p50,
       percentile_cont(0.1) within group (order by (e.props->>'fps')::float) as fps_p10,
       sum((e.props->>'slow')::bigint)::float / nullif(sum((e.props->>'sec')::bigint), 0) as slow_per_sec
  from analytics_client_events e
 where e.name = 'perf' and e.props ? 'fps' and """ + _IN_RANGE + """
 group by 1 order by 2 desc
"""

_LAUNCH = """
select count(*) as launches,
       percentile_cont(0.5) within group (order by (e.props->>'t3')::int) as t3_p50,
       percentile_cont(0.9) within group (order by (e.props->>'t3')::int) as t3_p90
  from analytics_client_events e
 where e.name = 'app_launch' and (e.props->>'t3')::int > 0 and """ + _IN_RANGE + """
"""


def _num(value: float | None, digits: int = 1) -> float | None:
    return None if value is None else round(float(value), digits)


async def client_report(days: int, mode: str = "all", now: dt.datetime | None = None) -> dict:
    _check_days(days)
    if mode not in MODES:
        raise AdminRejected("模式只能是 %s" % " / ".join(MODES))
    now = now or _utc_now()
    today = analytics.game_day(now)
    start, end = _bounds(today - dt.timedelta(days=days - 1), today)
    async with db.pool().acquire() as conn:
        try:
            coverage = await conn.fetch(_COVERAGE, start, end, TZ_NAME)
            builds = await conn.fetch(_BUILDS, start, end)
            totals = await conn.fetchrow(_TUTORIAL_TOTALS, start, end)
            steps = await conn.fetch(_TUTORIAL_STEPS, start, end)
            skips = {r["idx"]: int(r["skipped"]) for r in await conn.fetch(_TUTORIAL_SKIPS, start, end)}
            first = await conn.fetchrow(_FIRST_PLAY, start, end, TZ_NAME, today)
            rounds = await conn.fetch(_ROUNDS, start, end, mode)
            reasons = await conn.fetch(_REASONS, start, end)
            counts = {r["name"]: r for r in await conn.fetch(_COUNTS, start, end)}
            errors = await conn.fetch(_ERRORS, start, end)
            perf = await conn.fetch(_PERF, start, end)
            launch = await conn.fetchrow(_LAUNCH, start, end)
            active = {r["game_day"]: int(r["active"]) for r in await conn.fetch(_ACTIVE, start.date(), today)}
        except asyncpg.UndefinedTableError:
            raise AdminRejected("数据库还没跑 database/026_client_events.sql，游戏上报的事件还没开始收", 503) from None

    # 教学漏斗：到达第 i 步 = 完成了第 i-1 步的人（第 1 步 = 开始教学的人）。
    by_index: dict[int, dict] = {}
    for r in steps:
        by_index[int(r["idx"])] = {"index": int(r["idx"]), "step": r["step"], "done": int(r["done"]),
                                   "p50_sec": _num(r["p50"] and r["p50"] / 1000.0),
                                   "p90_sec": _num(r["p90"] and r["p90"] / 1000.0)}
    last_index = max([*by_index, *skips, 0])
    funnel = []
    reached = int(totals["started"])
    for i in range(1, last_index + 1):
        row = by_index.get(i, {"index": i, "step": None, "done": 0, "p50_sec": None, "p90_sec": None})
        skipped = skips.get(i, 0)
        funnel.append({**row, "reached": reached, "skipped": skipped,
                       "stuck": max(0, reached - row["done"] - skipped)})
        reached = row["done"]

    count = lambda name, key="times": int(counts[name][key]) if name in counts else 0  # noqa: E731
    return {
        "as_of": _iso(now),
        "mode": mode,
        "coverage": [{"day": r["day"].isoformat(), "players": int(r["players"]), "events": int(r["events"]),
                      "active": active.get(r["day"])} for r in sorted(coverage, key=lambda r: r["day"], reverse=True)],
        "builds": [{"build": int(r["build"]), "players": int(r["players"]), "last_seen": _iso(r["last_seen"])}
                   for r in builds],
        "tutorial": {"started": int(totals["started"]), "completed": int(totals["completed"]),
                     "skipped": int(totals["skipped"]), "steps": funnel},
        "first_play": {k: int(first[k]) for k in first.keys()},
        "rounds": [{"round": int(r["round"]), "kind": r["kind"], "teams": int(r["teams"]), "lost": int(r["lost"]),
                    "eliminated": int(r["eliminated"]), "avg_hp": _num(r["avg_hp"])} for r in rounds],
        "quality": {
            "replay_done": count("replay_done"), "replay_failed": count("replay_failed"),
            "reconnects": count("reconnect"), "matches_started": count("match_start"),
            "match_leaves": count("match_leave"), "match_leave_players": count("match_leave", "players"),
            "events_dropped": count("events_dropped"),
            "reasons": [{"event": r["name"], "reason": r["reason"], "times": int(r["times"]),
                         "players": int(r["players"])} for r in reasons],
            "launch": {"launches": int(launch["launches"]), "t3_p50_sec": _num(launch["t3_p50"] and launch["t3_p50"] / 1000.0),
                       "t3_p90_sec": _num(launch["t3_p90"] and launch["t3_p90"] / 1000.0)},
            "perf": [{"ctx": r["ctx"], "samples": int(r["samples"]), "players": int(r["players"]),
                      "fps_p50": _num(r["fps_p50"]), "fps_p10": _num(r["fps_p10"]),
                      "slow_per_min": _num(r["slow_per_sec"] and r["slow_per_sec"] * 60.0)} for r in perf],
            "errors": [{"kind": r["kind"], "where": r["place"], "msg": r["msg"], "times": int(r["times"]),
                        "players": int(r["players"]), "build": r["build"], "last_seen": _iso(r["last_seen"])}
                       for r in errors],
        },
    }


# --- 内部账号 ----------------------------------------------------------------------------

async def tags() -> list[dict]:
    async with db.pool().acquire() as conn:
        try:
            rows = await conn.fetch(
                "select t.player_id, p.friend_code, p.player_name, t.kind, t.note, t.tagged_by, t.tagged_at"
                "  from analytics_account_tags t join players p on p.player_id = t.player_id"
                " order by t.tagged_at desc")
        except asyncpg.UndefinedTableError:
            raise _not_ready() from None
    return [{**dict(r), "player_id": str(r["player_id"]), "tagged_at": _iso(r["tagged_at"])} for r in rows]
