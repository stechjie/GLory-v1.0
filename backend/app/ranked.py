"""排位分、段位与信誉分（`docs/排位系统设计.md` 第三、四节）。第 5a 步。

配套 `database/014_ranked.sql`。结算入口是 `settle()`，由 `app/battle_report.py`
在把一局写进 `match_records` 的**同一个事务**里调用。

## 🔴 一局只结算一次，靠的是 013 的主键

`match_uid` 是 `match_records` 的主键，重复的战报在 `on conflict do nothing`
那一步就没了 —— 后面的结算根本不会跑。**不要在这里再加一套去重**：
两套幂等机制意味着两处会分叉。

## 段位不存，是分数的显示切片

    段位 = clamp(score // 100, 0, 7)     八段，第 8 段不封顶

不加 `tier` 列的理由写在 014 的文件头。改段位宽窄就是改这里的常量。

## 信誉分的「每天 +5」是读到时现算的

不跑定时任务。按 `last_daily_grant` 到今天差几天补几个 +5，封顶 100。
几万个玩家里绝大多数当天没上线，给他们跑一遍是纯浪费；而且定时任务漏跑一天，
补起来要另写脚本。懒惰发放天然自愈。

## 三处调用方

    app/battle_report.py   写 match_records 的同一个事务里调 settle()
    app/routes/matchmaking.py  排队前调 queue_gate()（窗口 / 禁赛 / 信誉分）
    app/matchmaking.py     确认框没点的人，tick 里调 punish_no_accept()

## 还没做的

- **「每段 0 分是地板」没实现** —— 那条还没拍板（第三节「待确认」）。
  要加是在 `apply_delta` 里加，不是在调用方各写一遍。
- **定级赛没做**（同上，未拍板）。`player_ranked.placement` 那类列也没建。
- **赛季只有一个**。`player_ranked.season` 恒为 1，赛季切换是第 6 步。
"""

from __future__ import annotations

import datetime as dt
import logging
import uuid

log = logging.getLogger("glory.ranked")

# --- 段位 ---------------------------------------------------------------------

# 八段，每段 100 分。第 8 段（>=700）不封顶。
TIER_SIZE = 100
TIER_COUNT = 8
MAX_TIER = TIER_COUNT - 1


def tier_of(score: int) -> int:
    """分数 → 段位（0..7）。**唯一的换算口径**，别在别处再写一遍。"""
    return max(0, min(MAX_TIER, int(score) // TIER_SIZE))


def tier_progress(score: int) -> int:
    """本段内的进度（0..99）。第 8 段返回溢出量（可能 >= 100），界面自己决定怎么显示。"""
    if tier_of(score) >= MAX_TIER:
        return max(0, int(score) - MAX_TIER * TIER_SIZE)
    return max(0, int(score) % TIER_SIZE)


# --- 一局加减多少 ---------------------------------------------------------------

BASE_DELTA = 25
# 段位差修正的上下限。实际每局是 10 ~ 40 / −10 ~ −40。
MAX_CORRECTION = 15
# 对手队伍平均分每高这么多分，修正 +1。
CORRECTION_DIVISOR = 20

# 连胜：3 连胜起每局 +20%，上限 +60%。
STREAK_FROM = 3
STREAK_STEP = 0.2
STREAK_MAX_STEPS = 3

# 跑路的额外扣分倍率（第四节：本局按输算，再额外扣输的那一份 × 1.5）。
ABANDON_PENALTY_MULT = 1.5


def score_delta(won: bool, own_avg: int, rival_avg: int, win_streak: int = 0) -> int:
    """这一局加减多少分。

    🔴 **必须有段位差修正。** 固定 ±25 是跑步机：只要胜率 >50%、局数够多，
    所有人最后都会到第 8 段（满梯 800 分 = 净胜 32 局），段位反映的是
    「打了多少局」而不是「多强」。加上修正之后数学上就是 Elo，会自动收敛。

    连胜加成只加在**赢**的那一份上 —— 连胜是奖励，不该让输的时候少扣。
    """
    diff = int(rival_avg) - int(own_avg)
    correction = max(-MAX_CORRECTION, min(MAX_CORRECTION, diff // CORRECTION_DIVISOR))
    if not won:
        # 打比自己强的队伍输了少扣，打比自己弱的输了多扣 —— 所以这里是 -diff。
        return -(BASE_DELTA + max(-MAX_CORRECTION, min(MAX_CORRECTION, -diff // CORRECTION_DIVISOR)))
    gained = BASE_DELTA + correction
    if win_streak >= STREAK_FROM:
        steps = min(STREAK_MAX_STEPS, int(win_streak) - STREAK_FROM + 1)
        gained = int(round(gained * (1.0 + STREAK_STEP * steps)))
    return gained


def apply_delta(score: int, delta: int) -> int:
    """加减之后的分数。**下限 0，没有上限**（第 8 段不封顶）。

    ⚠️ 这里**没有实现「每段 0 分是地板」** —— 那条还没拍板
    （docs/排位系统设计.md 第三节「待确认」）。要加的话是在这里加，
    而不是在调用方各写一遍。
    """
    return max(0, int(score) + int(delta))


# --- 信誉分 -------------------------------------------------------------------

CREDIT_START = 100
CREDIT_MAX = 100
CREDIT_MIN = 0

# 阈值（第四节）。
CREDIT_WARN = 85
CREDIT_RANKED_MIN = 70
CREDIT_CASUAL_MIN = 60

# 恢复：每天 +5（无条件），正常完成一局 +2。
CREDIT_DAILY = 5
CREDIT_PER_MATCH = 2

# 惩罚：最近 7 天滚动，**7 次一档**（跟着天数走），每档 ×1.5。
PENALTY_WINDOW_DAYS = 7
PENALTY_TIER_SIZE = 7
ABANDON_BASE = 5
PENALTY_MULT = 1.5

# 禁排位时长，按档。封顶 60 分钟 —— 排位窗口只有 4 小时，60 分钟已经是当晚的 1/4，
# 再长不如交给信誉分（它是跨天的，禁赛不是）。
BAN_MINUTES_BY_TIER = [0, 15, 30, 45]
BAN_MINUTES_MAX = 60


def penalty_tier(count_in_window: int) -> int:
    """7 天窗口里这是第 N 次 → 第几档（0 起）。

    count_in_window 是**包含这一次**的次数。第 1~7 次是第 0 档，第 8~14 次第 1 档。
    """
    return max(0, (max(1, int(count_in_window)) - 1) // PENALTY_TIER_SIZE)


def abandon_penalty(count_in_window: int) -> int:
    """跑路扣多少信誉分（正数）。5 / 8 / 11 / 17 / 25 …（`round(5 × 1.5^档)`）。"""
    return int(round(ABANDON_BASE * (PENALTY_MULT ** penalty_tier(count_in_window))))


def ban_minutes(count_in_window: int) -> int:
    """禁排位多少分钟。第 0 档不禁。"""
    tier = penalty_tier(count_in_window)
    if tier < len(BAN_MINUTES_BY_TIER):
        return BAN_MINUTES_BY_TIER[tier]
    return BAN_MINUTES_MAX


def apply_credit(score: int, delta: int) -> int:
    return max(CREDIT_MIN, min(CREDIT_MAX, int(score) + int(delta)))


def daily_grant(score: int, last_grant: dt.date | None, today: dt.date) -> tuple[int, int]:
    """懒惰发放「每天 +5」。返回 (新分数, 补发了多少)。

    last_grant 为 None = 从没发过。新玩家本来就是 100，补不补都一样；
    但要把游标钉在今天，否则下次会从 1970 年开始算天数。
    """
    if score >= CREDIT_MAX:
        return CREDIT_MAX, 0
    if last_grant is None:
        return int(score), 0
    days = (today - last_grant).days
    if days <= 0:
        return int(score), 0
    granted = min(CREDIT_MAX - int(score), days * CREDIT_DAILY)
    return int(score) + granted, granted


def can_queue(credit: int, mode: str) -> bool:
    """信誉分够不够排这个模式。第 5b 步接到队列接口上。"""
    if mode == "ranked":
        return int(credit) >= CREDIT_RANKED_MIN
    return int(credit) >= CREDIT_CASUAL_MIN


def is_banned(banned_until: dt.datetime | None, now: dt.datetime | None = None) -> bool:
    if banned_until is None:
        return False
    return banned_until > (now or dt.datetime.now(dt.UTC))


# --- 结算 ---------------------------------------------------------------------


async def settle(conn, report: dict) -> None:
    """一局打完的全部结算。**必须在写 match_records 的同一个事务里调。**

    做三件事：
      1. 排位局：算分、写 player_ranked
      2. 所有模式：正常打完 +2 信誉分
      3. 所有模式：跑路的扣信誉分 + 禁排位

    ⚠️ 信誉分对**休闲局也算** —— 跑路给别人造成的损失和模式无关。
    只有排位分是排位局才动的。
    """
    seats = [s for s in report["seats"] if s["player_id"] is not None]
    if not seats:
        return
    known = await _known_players(conn, [s["player_id"] for s in seats])
    seats = [s for s in seats if s["player_id"] in known]
    if not seats:
        return

    if report["mode"] == "ranked":
        await _settle_ranked(conn, report, seats)
    await _settle_credit(conn, report, seats)


async def _settle_ranked(conn, report: dict, seats: list[dict]) -> None:
    rows = await _ranked_rows(conn, [s["player_id"] for s in seats])
    # 队伍平均分要用**打之前**的分数。边算边写的话，先结算的人会影响后结算的人。
    team_scores: dict[int, list[int]] = {0: [], 1: []}
    for seat in seats:
        team_scores[seat["team"]].append(rows[seat["player_id"]]["score"])
    averages = {
        team: (sum(vals) // len(vals) if vals else 0)
        for team, vals in team_scores.items()
    }

    outcome = report["outcome"]
    for seat in seats:
        row = rows[seat["player_id"]]
        if outcome == "draw":
            # 平局不动分，但算一场。连胜不中断也不增加 —— 平局既不是赢也不是输。
            delta = 0
            won = False
            streak = row["win_streak"]
        else:
            won = (outcome == "team_a") == (seat["team"] == 0)
            delta = score_delta(won, averages[seat["team"]], averages[1 - seat["team"]],
                                row["win_streak"])
            streak = row["win_streak"] + 1 if won else 0
        # 🔴 跑路的人额外再扣一份（第四节：输的那一份 × 1.5）。
        # 判定线是 online_at_end，不是 was_ai —— 转过 AI 但回来了的不算。
        if not seat["online_at_end"]:
            delta -= int(round(BASE_DELTA * ABANDON_PENALTY_MULT))
            streak = 0
        await conn.execute(
            """
            update player_ranked
               set score = $2, games = games + 1, wins = wins + $3,
                   win_streak = $4, updated_at = now()
             where player_id = $1
            """,
            seat["player_id"], apply_delta(row["score"], delta), 1 if won else 0, streak,
        )
    log.info("排位结算 match=%s outcome=%s seats=%d", report["match_uid"], outcome, len(seats))


async def _settle_credit(conn, report: dict, seats: list[dict]) -> None:
    today = dt.datetime.now(dt.UTC).date()
    for seat in seats:
        pid = seat["player_id"]
        row = await _credit_row(conn, pid, today)
        if seat["online_at_end"]:
            # 正常打完 +2。
            await _credit_event(conn, pid, "match", CREDIT_PER_MATCH, report["match_uid"])
            await _write_credit(conn, pid, apply_credit(row["score"], CREDIT_PER_MATCH), None)
            continue
        # 跑路：按 7 天滚动窗口里的第几次定档。count 包含这一次。
        count = await conn.fetchval(
            """
            select count(*) + 1 from credit_events
             where player_id = $1 and kind = 'abandon'
               and created_at > now() - ($2 || ' days')::interval
            """,
            pid, str(PENALTY_WINDOW_DAYS),
        )
        penalty = abandon_penalty(int(count))
        minutes = ban_minutes(int(count))
        banned_until = (
            dt.datetime.now(dt.UTC) + dt.timedelta(minutes=minutes) if minutes > 0 else None
        )
        await _credit_event(conn, pid, "abandon", -penalty, report["match_uid"])
        await _write_credit(conn, pid, apply_credit(row["score"], -penalty), banned_until)
        log.info("跑路扣分 player=%s match=%s 第%d次 -%d 禁%d分钟",
                 pid, report["match_uid"], int(count), penalty, minutes)


# --- 取行（不存在就建）-----------------------------------------------------------


async def _known_players(conn, ids: list[uuid.UUID]) -> set[uuid.UUID]:
    rows = await conn.fetch(
        "select player_id from players where player_id = any($1::uuid[])", ids)
    return {r["player_id"] for r in rows}


async def _ranked_rows(conn, ids: list[uuid.UUID]) -> dict[uuid.UUID, dict]:
    """取排位行，没有就建一行默认的。第一次打排位的人走这条。"""
    await conn.executemany(
        "insert into player_ranked (player_id) values ($1) on conflict do nothing",
        [(pid,) for pid in ids])
    rows = await conn.fetch(
        "select player_id, score, win_streak from player_ranked"
        " where player_id = any($1::uuid[])", ids)
    return {r["player_id"]: {"score": r["score"], "win_streak": r["win_streak"]} for r in rows}


async def _credit_row(conn, player_id: uuid.UUID, today: dt.date) -> dict:
    """取信誉行（没有就建），并**顺手把「每天 +5」补上**。

    补发写在这里而不是一个定时任务里：绝大多数玩家当天没上线，扫全表是纯浪费，
    而且定时任务漏跑一天要另写脚本补。懒惰发放天然自愈。
    """
    await conn.execute(
        "insert into player_credit (player_id, last_daily_grant) values ($1, $2)"
        " on conflict do nothing", player_id, today)
    row = await conn.fetchrow(
        "select score, banned_until, last_daily_grant from player_credit where player_id = $1",
        player_id)
    score, granted = daily_grant(int(row["score"]), row["last_daily_grant"], today)
    if granted > 0:
        await _credit_event(conn, player_id, "daily", granted, None)
    if granted > 0 or row["last_daily_grant"] != today:
        await conn.execute(
            "update player_credit set score = $2, last_daily_grant = $3, updated_at = now()"
            " where player_id = $1", player_id, score, today)
    return {"score": score, "banned_until": row["banned_until"]}


async def _write_credit(conn, player_id: uuid.UUID, score: int,
                        banned_until: dt.datetime | None) -> None:
    if banned_until is None:
        await conn.execute(
            "update player_credit set score = $2, updated_at = now() where player_id = $1",
            player_id, score)
        return
    # 禁赛只延长、不缩短：已经被禁到更晚的人不该因为又犯一次而提前解禁。
    await conn.execute(
        """
        update player_credit
           set score = $2,
               banned_until = greatest(coalesce(banned_until, $3), $3),
               updated_at = now()
         where player_id = $1
        """,
        player_id, score, banned_until)


async def _credit_event(conn, player_id: uuid.UUID, kind: str, delta: int,
                        match_uid: str | None) -> None:
    await conn.execute(
        "insert into credit_events (player_id, kind, delta, match_uid) values ($1,$2,$3,$4)",
        player_id, kind, delta, match_uid)


# --- 时间窗口（docs/排位系统设计.md 第二节）----------------------------------------

# 马来西亚时间 = UTC+8，**没有夏令时**，固定偏移。
#
# 🔴 **不引 tz 数据库。** 马来西亚不会有夏令时，为一个固定偏移多一个依赖不值。
# 后端其余部分全是 UTC（`dt.datetime.now(dt.UTC)`），这里只在判窗口时加 8 小时。
MYT_OFFSET = dt.timedelta(hours=8)

# 19:00 开放排队 → 23:00 停止匹配新局 → 00:00 当日排位期结束。
#
# ⚠️ **23:00 是「最后开局时间」，要能改。** 它等于
# `00:00 − 一局 P95 时长 − 10 分钟余量`；数值调过、回合变慢之后写死的 23:00
# 就会变成每晚固定事故（第二节）。现在是常量，做成配置是以后的事 ——
# 但**先把它单独命名**，免得下一个人以为 23 是从 19 算出来的。
RANKED_OPEN_HOUR = 19
RANKED_LAST_START_HOUR = 23
# 00:00 结束 = 第二天的 0 点。关的是**队列**，不是对局 ——
# 已经开打的局让它打完，照常算分（第二节的拍板）。
RANKED_CLOSE_HOUR = 24


def myt_now(now_utc: dt.datetime | None = None) -> dt.datetime:
    return (now_utc or dt.datetime.now(dt.UTC)) + MYT_OFFSET


def window_state(now_utc: dt.datetime | None = None) -> dict:
    """排位窗口的当前状态。**只有服务器说了算** —— 客户端改系统时区就能绕过，
    而排位是发分的，不能像 `app/admission.py` 那样接受「拦人的是客户端」。

    返回：
      accepting     现在能不能排队 / 能不能凑出新的一桌（19:00–23:00）
      open          当日排位期还在不在（19:00–24:00）。只影响文案
      opens_in_sec  距离下次 19:00 还有多久（accepting 时为 0）
      closes_in_sec 距离 23:00 还有多久（不 accepting 时为 0）
    """
    local = myt_now(now_utc)
    hour = local.hour
    accepting = RANKED_OPEN_HOUR <= hour < RANKED_LAST_START_HOUR
    day_start = local.replace(hour=0, minute=0, second=0, microsecond=0)
    opens_at = day_start + dt.timedelta(hours=RANKED_OPEN_HOUR)
    if local >= opens_at:
        opens_at += dt.timedelta(days=1)
    closes_at = day_start + dt.timedelta(hours=RANKED_LAST_START_HOUR)
    return {
        "accepting": accepting,
        "open": RANKED_OPEN_HOUR <= hour < RANKED_CLOSE_HOUR,
        "opens_in_sec": 0 if accepting else max(0, int((opens_at - local).total_seconds())),
        "closes_in_sec": max(0, int((closes_at - local).total_seconds())) if accepting else 0,
    }


# --- 排队前的闸（第 5b 步）--------------------------------------------------------

# 不让排队的原因。原样回给客户端，所以不许带任何内部细节。
GATE_OK = ""
GATE_WINDOW_CLOSED = "ranked_window_closed"
GATE_CREDIT_TOO_LOW = "credit_too_low"
GATE_BANNED = "credit_banned"


async def queue_gate(conn, player_id: uuid.UUID, mode: str,
                     now_utc: dt.datetime | None = None) -> str:
    """能不能排这个模式。返回空串 = 能，否则是原因码。

    三道闸，顺序有讲究：
      1. **时间窗口**（只管排位）—— 最常见、最好解释，先说
      2. 禁赛到期时间
      3. 信誉分阈值

    ⚠️ 禁赛与信誉分是**两件事**，不能合并：禁赛有到期时间，信誉分低没有。
    合并的话禁赛一到期，信誉分那条限制会跟着被解除（014 里那一列的注释同此）。
    """
    if mode == "ranked" and not window_state(now_utc)["accepting"]:
        return GATE_WINDOW_CLOSED
    row = await conn.fetchrow(
        "select score, banned_until from player_credit where player_id = $1", player_id)
    if row is None:
        return GATE_OK          # 从没打过的人是满分
    if is_banned(row["banned_until"], now_utc):
        return GATE_BANNED
    if not can_queue(int(row["score"]), mode):
        return GATE_CREDIT_TOO_LOW
    return GATE_OK


# --- 没按准备（第 5b 步）----------------------------------------------------------

# 没按准备：**按次递增，不分档**（第四节）。
#
# 它给别人造成的损失只有 30 秒（局还没开），比跑路轻得多；但它是最容易被拿来
# **躲匹配**的动作 —— 看到对手段位不想打就不确认。所以递增要比跑路快。
NO_ACCEPT_LADDER = [1, 2, 5]
NO_ACCEPT_BAN_MINUTES = [0, 0, 3, 15, 30]


def no_accept_penalty(count_in_window: int) -> int:
    """7 天窗口里第 N 次没按准备，扣多少信誉分（正数）。1 / 2 / 5 / 8 / 11 / 17…"""
    n = max(1, int(count_in_window))
    if n <= len(NO_ACCEPT_LADDER):
        return NO_ACCEPT_LADDER[n - 1]
    return int(round(ABANDON_BASE * (PENALTY_MULT ** (n - len(NO_ACCEPT_LADDER)))))


def no_accept_ban_minutes(count_in_window: int) -> int:
    n = max(1, int(count_in_window))
    if n <= len(NO_ACCEPT_BAN_MINUTES):
        return NO_ACCEPT_BAN_MINUTES[n - 1]
    return BAN_MINUTES_MAX


async def punish_no_accept(player_ids: list[uuid.UUID]) -> None:
    """匹配确认框没点的人。由 `app/matchmaking.py` 的 tick 调。

    🔴 **另外五个人一个字都不动。** 他们已经等过排队、等过确认框了，
    再罚他们就是拿别人的锅（第四节）。调用方只传没确认的那几个。
    """
    if not player_ids:
        return
    from app import db

    if not db.is_connected():
        return
    today = dt.datetime.now(dt.UTC).date()
    async with db.pool().acquire() as conn, conn.transaction():
        known = await _known_players(conn, player_ids)
        for pid in player_ids:
            if pid not in known:
                continue
            row = await _credit_row(conn, pid, today)
            count = await conn.fetchval(
                """
                select count(*) + 1 from credit_events
                 where player_id = $1 and kind = 'no_accept'
                   and created_at > now() - ($2 || ' days')::interval
                """,
                pid, str(PENALTY_WINDOW_DAYS),
            )
            penalty = no_accept_penalty(int(count))
            minutes = no_accept_ban_minutes(int(count))
            banned_until = (
                dt.datetime.now(dt.UTC) + dt.timedelta(minutes=minutes) if minutes > 0 else None
            )
            await _credit_event(conn, pid, "no_accept", -penalty, None)
            await _write_credit(conn, pid, apply_credit(row["score"], -penalty), banned_until)
            log.info("没按准备扣分 player=%s 第%d次 -%d 禁%d分钟", pid, int(count), penalty, minutes)
