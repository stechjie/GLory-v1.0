"""排位分、段位、信誉分与时间窗口（`docs/排位系统设计.md` 第二、三、四节）。第 5 步。

算法那一半是纯函数，直接算；入库那一半用假连接。

最重要的几组，失败时都**不报错**：

  1. **段位差修正**。少了它，固定 ±25 是跑步机 —— 只要胜率 >50%、局数够多，
     所有人最后都会到第 8 段，段位反映的是「打了多少局」而不是「多强」。
  2. **队伍平均分要用打之前的分**。边算边写的话，先结算的人会影响后结算的人，
     而六个人的加减分会**悄悄不对称**。
  3. **7 次一档**。写成「每次一档」惩罚会指数跑飞（一年断 8 次网就永久掉线），
     写成「永不递增」则等于没有惩罚。两种都不报错。
  4. **禁赛只延长不缩短**。写成直接覆盖的话，一个被禁 30 分钟的人再犯一次轻的
     会**提前解禁**。
  5. **时间窗口只管排位**。把休闲也关进窗口里，等于每天 20 小时没得玩。

跑：
    backend\\.venv\\Scripts\\python.exe -m pytest backend/tests/test_ranked.py -q -p no:cacheprovider
"""

from __future__ import annotations

import datetime as dt
import pathlib
import re
import uuid

import pytest

from app import ranked

REPO = pathlib.Path(__file__).resolve().parents[2]
SQL_014 = (REPO / "database" / "014_ranked.sql").read_text(encoding="utf-8")


@pytest.fixture
def anyio_backend():
    return "asyncio"


# --- 段位是分数的切片 -------------------------------------------------------------


@pytest.mark.parametrize("score, tier", [
    (0, 0), (99, 0), (100, 1), (250, 2), (699, 6), (700, 7), (1200, 7), (99999, 7),
])
def test_tier_slices(score, tier) -> None:
    assert ranked.tier_of(score) == tier


def test_top_tier_is_uncapped() -> None:
    """🔴 第 8 段不封顶。封了的话高手之间就分不出来了（第三节）。"""
    assert ranked.tier_of(700) == ranked.tier_of(5000) == ranked.MAX_TIER
    assert ranked.tier_progress(700) == 0
    assert ranked.tier_progress(950) == 250, "第 8 段的进度应该是溢出量"


def test_tier_is_not_a_column() -> None:
    """🔴 段位不存。存了就有两个真相，改段位宽窄要写数据迁移，
    而迁移漏掉一部分行的话那些人的段位会**永久对不上、且不报错**。"""
    assert "tier" not in SQL_014.replace("-- ", "").split("create table player_ranked")[1].split(")")[0]


# --- 一局加减多少 -----------------------------------------------------------------


def test_even_match_is_the_base() -> None:
    assert ranked.score_delta(True, 400, 400) == 25
    assert ranked.score_delta(False, 400, 400) == -25


def test_tier_gap_correction() -> None:
    """🔴 没有这一条，段位反映的是「打了多少局」而不是「多强」。"""
    # 打高 300 分的队伍：赢得多、输得少
    assert ranked.score_delta(True, 400, 700) == 40
    assert ranked.score_delta(False, 400, 700) == -10
    # 打低 300 分的：反过来
    assert ranked.score_delta(True, 700, 400) == 10
    assert ranked.score_delta(False, 700, 400) == -40


def test_correction_is_clamped() -> None:
    """分差再大也就 ±15。不夹的话打一个 0 分号能一局涨几百。"""
    assert ranked.score_delta(True, 0, 99999) == 40
    assert ranked.score_delta(False, 99999, 0) == -40


def test_win_streak_only_boosts_wins() -> None:
    """连胜是奖励，不该让输的时候少扣。"""
    assert ranked.score_delta(True, 400, 400, win_streak=2) == 25, "2 连胜还不该有加成"
    assert ranked.score_delta(True, 400, 400, win_streak=3) == 30    # +20%
    assert ranked.score_delta(True, 400, 400, win_streak=5) == 40    # +60% 封顶
    assert ranked.score_delta(True, 400, 400, win_streak=99) == 40, "连胜加成要封顶"
    assert ranked.score_delta(False, 400, 400, win_streak=99) == -25


def test_score_never_goes_below_zero() -> None:
    assert ranked.apply_delta(10, -40) == 0
    assert ranked.apply_delta(0, -40) == 0


def test_score_has_no_upper_bound() -> None:
    assert ranked.apply_delta(5000, 40) == 5040


# --- 信誉分 ---------------------------------------------------------------------


def test_thresholds_match_the_design() -> None:
    assert (ranked.CREDIT_START, ranked.CREDIT_WARN) == (100, 85)
    assert (ranked.CREDIT_RANKED_MIN, ranked.CREDIT_CASUAL_MIN) == (70, 60)
    assert ranked.can_queue(70, "ranked") and not ranked.can_queue(69, "ranked")
    assert ranked.can_queue(60, "casual") and not ranked.can_queue(59, "casual")
    assert not ranked.can_queue(65, "ranked"), "65 分能打休闲但不能排位"


def test_abandon_ladder_is_seven_per_tier() -> None:
    """🔴 7 次一档，每档 ×1.5（第四节算过账：每次一档会跑飞，不递增等于没惩罚）。"""
    assert [ranked.abandon_penalty(n) for n in (1, 7)] == [5, 5]
    assert [ranked.abandon_penalty(n) for n in (8, 14)] == [8, 8]
    assert [ranked.abandon_penalty(n) for n in (15, 21)] == [11, 11]
    assert ranked.abandon_penalty(22) == 17


def test_ban_minutes_are_capped() -> None:
    """封顶 60 分钟：排位窗口只有 4 小时，60 分钟已经是当晚的 1/4。"""
    assert ranked.ban_minutes(1) == 0, "第一档不禁赛"
    assert ranked.ban_minutes(8) == 15
    assert ranked.ban_minutes(15) == 30
    assert ranked.ban_minutes(999) == ranked.BAN_MINUTES_MAX == 60


def test_no_accept_ladder_rises_faster_than_abandon() -> None:
    """没按准备造成的损失只有 30 秒，但它最容易被拿来躲匹配，所以递增要快。"""
    assert [ranked.no_accept_penalty(n) for n in (1, 2, 3)] == [1, 2, 5]
    assert ranked.no_accept_penalty(4) > ranked.no_accept_penalty(3)
    # 头两次比跑路轻
    assert ranked.no_accept_penalty(1) < ranked.abandon_penalty(1)
    assert ranked.no_accept_ban_minutes(1) == 0
    assert ranked.no_accept_ban_minutes(3) == 3


def test_daily_grant_is_lazy_and_catches_up() -> None:
    """一个月没上线的人下次登录应该一次性补到 100，不是补一天。"""
    today = dt.date(2026, 9, 22)
    assert ranked.daily_grant(100, today - dt.timedelta(days=30), today) == (100, 0)
    assert ranked.daily_grant(60, today - dt.timedelta(days=1), today) == (65, 5)
    assert ranked.daily_grant(60, today - dt.timedelta(days=30), today) == (100, 40)
    assert ranked.daily_grant(60, today, today) == (60, 0), "同一天不重复发"
    assert ranked.daily_grant(60, None, today) == (60, 0), "没发过的不补历史"


def test_credit_is_clamped() -> None:
    assert ranked.apply_credit(98, 5) == 100
    assert ranked.apply_credit(3, -50) == 0


# --- 时间窗口 --------------------------------------------------------------------


def _at_myt(hour: int, minute: int = 0) -> dt.datetime:
    """构造一个「马来西亚时间是 hour:minute」的 UTC 时刻。"""
    return dt.datetime(2026, 9, 22, hour, minute, tzinfo=dt.UTC) - ranked.MYT_OFFSET


@pytest.mark.parametrize("hour, accepting", [
    (0, False), (12, False), (18, False), (18 + 0, False),
    (19, True), (20, True), (22, True), (22, True),
    (23, False), (23, False),
])
def test_window_accepting_hours(hour, accepting) -> None:
    assert ranked.window_state(_at_myt(hour))["accepting"] is accepting


def test_window_open_covers_the_tail_hour() -> None:
    """23:00–24:00 不再匹配新局，但当日排位期还没结束（只影响文案）。"""
    late = ranked.window_state(_at_myt(23, 30))
    assert late["accepting"] is False and late["open"] is True


def test_window_countdown() -> None:
    assert ranked.window_state(_at_myt(18, 0))["opens_in_sec"] == 3600
    assert ranked.window_state(_at_myt(22, 0))["closes_in_sec"] == 3600
    # 窗口内不报「还有多久开」，窗口外不报「还有多久关」—— 免得界面两个都显示
    assert ranked.window_state(_at_myt(20))["opens_in_sec"] == 0
    assert ranked.window_state(_at_myt(12))["closes_in_sec"] == 0


def test_window_uses_a_fixed_offset_not_a_tz_database() -> None:
    """马来西亚没有夏令时。引 tz 库是多一个依赖（第二节）。"""
    assert ranked.MYT_OFFSET == dt.timedelta(hours=8)
    src = (REPO / "backend" / "app" / "ranked.py").read_text(encoding="utf-8")
    assert "zoneinfo" not in src and "pytz" not in src


# --- 结算（假连接）----------------------------------------------------------------


class _FakeConn:
    """够 ranked.settle 用的最小假连接。记下所有写入。"""

    def __init__(self, known: set[uuid.UUID], scores: dict[uuid.UUID, int],
                 abandon_counts: dict[uuid.UUID, int] | None = None) -> None:
        self.known = known
        self.scores = scores
        self.abandon_counts = abandon_counts or {}
        self.ranked_writes: list[tuple] = []
        self.credit_writes: list[tuple] = []
        self.events: list[tuple] = []

    async def fetch(self, sql, *args):
        if "from players" in sql:
            return [{"player_id": p} for p in args[0] if p in self.known]
        if "player_ranked" in sql:
            return [{"player_id": p, "score": self.scores.get(p, 0), "win_streak": 0}
                    for p in args[0]]
        return []

    async def fetchrow(self, sql, *args):
        if "player_credit" in sql:
            return {"score": 100, "banned_until": None, "last_daily_grant": dt.date.today()}
        return None

    async def fetchval(self, sql, *args):
        if "kind = 'abandon'" in sql:
            return self.abandon_counts.get(args[0], 0) + 1
        return 1

    async def execute(self, sql, *args):
        if "update player_ranked" in sql:
            self.ranked_writes.append(args)
        elif "update player_credit" in sql:
            self.credit_writes.append(args)
        elif "insert into credit_events" in sql:
            self.events.append(args)
        return "UPDATE 1"

    async def executemany(self, sql, rows):
        return None


def _report(mode: str, outcome: str, players_: list[uuid.UUID],
            offline: set[uuid.UUID] | None = None) -> dict:
    offline = offline or set()
    return {
        "match_uid": "a" * 32, "mode": mode, "outcome": outcome,
        "seats": [
            {"slot": i, "team": 0 if i < 3 else 1, "player_id": p,
             "online_at_end": p not in offline, "was_ai": False}
            for i, p in enumerate(players_)
        ],
    }


def _six() -> list[uuid.UUID]:
    return [uuid.UUID(int=i + 1) for i in range(6)]


@pytest.mark.anyio
async def test_ranked_settlement_uses_pre_match_averages() -> None:
    """🔴 队伍平均分要用**打之前**的分。

    边算边写的话，先结算的人会影响后结算的人 —— 六个人的加减分会悄悄不对称，
    而且完全不报错。
    """
    players_ = _six()
    # A 队 0/0/0，B 队 600/600/600。A 队赢 = 以弱胜强，每个人都该拿满 40。
    scores = {p: (0 if i < 3 else 600) for i, p in enumerate(players_)}
    conn = _FakeConn(set(players_), scores)
    await ranked.settle(conn, _report("ranked", "team_a", players_))
    winners = [w for w in conn.ranked_writes if w[0] in players_[:3]]
    assert len(winners) == 3
    assert {w[1] for w in winners} == {40}, "三个赢家的新分数应该一样（都是 0 + 40）"


@pytest.mark.anyio
async def test_casual_does_not_touch_ranked_score() -> None:
    players_ = _six()
    conn = _FakeConn(set(players_), {p: 300 for p in players_})
    await ranked.settle(conn, _report("casual", "team_a", players_))
    assert conn.ranked_writes == [], "休闲局不该动排位分"
    assert len(conn.credit_writes) == 6, "但信誉分照算 —— 跑路的损失和模式无关"


@pytest.mark.anyio
async def test_abandoner_loses_extra_and_gets_credit_penalty() -> None:
    players_ = _six()
    runner = players_[0]
    conn = _FakeConn(set(players_), {p: 300 for p in players_}, {runner: 0})
    await ranked.settle(conn, _report("ranked", "team_a", players_, offline={runner}))
    by_player = {w[0]: w[1] for w in conn.ranked_writes}
    # 他在赢的那一队，但跑了：25（赢）− 38（额外罚）→ 300 − 13
    assert by_player[runner] < by_player[players_[1]]
    kinds = {e[1] for e in conn.events}
    assert "abandon" in kinds
    assert all(e[2] < 0 for e in conn.events if e[1] == "abandon")


@pytest.mark.anyio
async def test_draw_does_not_move_score() -> None:
    players_ = _six()
    conn = _FakeConn(set(players_), {p: 300 for p in players_})
    await ranked.settle(conn, _report("ranked", "draw", players_))
    assert {w[1] for w in conn.ranked_writes} == {300}, "平局不动分"


@pytest.mark.anyio
async def test_unknown_players_are_skipped_not_fatal() -> None:
    """一个人在对局结束到交战报之间注销，不该让另外五个的结算一起回滚。"""
    players_ = _six()
    conn = _FakeConn(set(players_[1:]), {p: 300 for p in players_})
    await ranked.settle(conn, _report("ranked", "team_a", players_))
    assert len(conn.ranked_writes) == 5


@pytest.mark.anyio
async def test_ai_seats_are_skipped() -> None:
    players_ = _six()
    report = _report("ranked", "team_a", players_)
    report["seats"][5]["player_id"] = None
    conn = _FakeConn(set(players_), {p: 300 for p in players_})
    await ranked.settle(conn, report)
    assert len(conn.ranked_writes) == 5


# --- 闸 --------------------------------------------------------------------------


class _GateConn:
    def __init__(self, row: dict | None) -> None:
        self.row = row

    async def fetchrow(self, sql, *args):
        return self.row


@pytest.mark.anyio
async def test_gate_blocks_ranked_outside_the_window() -> None:
    conn = _GateConn({"score": 100, "banned_until": None})
    assert await ranked.queue_gate(conn, uuid.UUID(int=1), "ranked",
                                   _at_myt(12)) == ranked.GATE_WINDOW_CLOSED
    assert await ranked.queue_gate(conn, uuid.UUID(int=1), "ranked",
                                   _at_myt(20)) == ranked.GATE_OK


@pytest.mark.anyio
async def test_gate_does_not_apply_the_window_to_casual() -> None:
    """🔴 窗口只管排位。把休闲也关进去等于每天 20 小时没得玩。"""
    conn = _GateConn({"score": 100, "banned_until": None})
    assert await ranked.queue_gate(conn, uuid.UUID(int=1), "casual", _at_myt(12)) == ranked.GATE_OK


@pytest.mark.anyio
async def test_gate_blocks_banned_and_low_credit() -> None:
    now = _at_myt(20)
    banned = _GateConn({"score": 100, "banned_until": now + dt.timedelta(minutes=5)})
    assert await ranked.queue_gate(banned, uuid.UUID(int=1), "ranked", now) == ranked.GATE_BANNED
    expired = _GateConn({"score": 100, "banned_until": now - dt.timedelta(minutes=5)})
    assert await ranked.queue_gate(expired, uuid.UUID(int=1), "ranked", now) == ranked.GATE_OK
    low = _GateConn({"score": 65, "banned_until": None})
    assert await ranked.queue_gate(low, uuid.UUID(int=1), "ranked", now) == ranked.GATE_CREDIT_TOO_LOW
    assert await ranked.queue_gate(low, uuid.UUID(int=1), "casual", now) == ranked.GATE_OK


@pytest.mark.anyio
async def test_gate_lets_brand_new_players_through() -> None:
    assert await ranked.queue_gate(_GateConn(None), uuid.UUID(int=1), "ranked",
                                   _at_myt(20)) == ranked.GATE_OK


# --- 跨文件约定 -------------------------------------------------------------------


def test_ban_only_extends_never_shortens() -> None:
    """🔴 直接覆盖的话，被禁 30 分钟的人再犯一次轻的会**提前解禁**。"""
    src = (REPO / "backend" / "app" / "ranked.py").read_text(encoding="utf-8")
    assert "greatest(coalesce(banned_until" in src


def test_credit_event_kinds_match_the_sql_constraint() -> None:
    kinds = set(re.findall(r"'(\w+)'",
                           re.search(r"check \(kind in \(([^)]+)\)", SQL_014).group(1)))
    assert kinds == {"abandon", "no_accept", "match", "daily"}


def test_ranked_mode_is_open_now() -> None:
    from app import matchmaking

    assert matchmaking.RANKED in matchmaking.OPEN_MODES
