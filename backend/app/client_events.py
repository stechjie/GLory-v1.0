"""游戏上报的事件（database/026_client_events.sql，docs/运营数据.md 第六节）。

客户端 scripts/autoload/AnalyticsService.gd 攒一批（最多 50 条）发过来，这里逐条判：

  accepted   记下了
  duplicate  这个编号记过了（客户端没收到上次的回复又发了一次）
  rejected   不认识的事件名、太旧 —— 重发也没用

三种客户端都从队列里删掉。只有整批格式不对才回 4xx；数据库不可用回 503，客户端留着以后再发。

## 只收名单上的事件、名单上的字段

EVENTS 列出每种事件能带哪些字段、什么类型。**名单外的字段悄悄丢掉**（新包多带一个字段，
不该让还没更新的服务器整条拒收）；类型不对的字段也丢掉；名单外的事件名整条拒收。

## 时间：对齐到服务器的钟

客户端的钟可能不准，也可能被改过。它发送时带上自己的「现在」（sent_at），这里按
「发生时刻 = 服务器现在 −（sent_at − 事件时刻）」换算 —— 两个数出自同一个钟，差值不受钟准不准影响。
换算后晚于现在的按现在算；早于 MAX_AGE 的拒收（客户端本来也只留 7 天）。
"""

from __future__ import annotations

import datetime as dt
import json
import math
import uuid
from typing import Any

import asyncpg

from app import db

BATCH_MAX = 50
MAX_AGE = dt.timedelta(days=7)
MAX_STRING = 160

# 事件名 → 字段名 → 类型。改这里要同时改 AnalyticsService.gd 里 track() 的那一处。
EVENTS: dict[str, dict[str, type]] = {
    "app_open": {"first": bool, "platform": str, "model": str, "gpu": str, "screen": str,
                 "cpus": int, "locale": str, "build": int},
    "app_launch": {"t0": int, "t1": int, "t2": int, "t3": int},
    "tutorial_start": {},
    "tutorial_resume": {"step": str, "index": int},
    "tutorial_step": {"from": str, "to": str, "index": int, "ms": int},
    "tutorial_skip": {"step": str, "index": int, "ms": int},
    "match_start": {"m": str, "mode": str, "slot": int, "humans": int, "bots": int},
    "round_result": {"m": str, "mode": str, "round": int, "kind": str, "battle": str, "team": int,
                     "won": bool, "hp": int, "enemy_hp": int, "gold": int, "carrots": int,
                     "harvest": int, "over": bool, "run_won": bool, "outcome": int},
    "match_leave": {"m": str, "mode": str, "round": int, "reason": str},
    "reconnect": {"ok": bool, "reason": str, "m": str},
    "room_action_failed": {"reason": str, "mode": str},
    "replay_done": {"round": int, "ms": int},
    "replay_failed": {"round": int, "reason": str},
    "client_error": {"kind": str, "where": str, "fn": str, "msg": str},
    "perf": {"sec": int, "fps": float, "slow": int, "errors": int, "mem_mb": int, "ctx": str},
    "events_dropped": {"n": int},
}

_INT_MIN, _INT_MAX = -(2 ** 31), 2 ** 31 - 1

_INSERT = """
insert into analytics_client_events
  (player_id, event_id, name, occurred_at, session_id, install_id, build, props)
select $1, u.id, u.name, u.at, u.sid, $2, $3, u.props::jsonb
  from unnest($4::uuid[], $5::text[], $6::timestamptz[], $7::uuid[], $8::text[]) as u(id, name, at, sid, props)
on conflict (player_id, event_id) do nothing
returning event_id
"""


class NotReady(RuntimeError):
    """026 还没跑。客户端收到 503，事件留在它那边以后再发。"""


def _value(kind: type, value: Any) -> Any:
    """合规就返回（可能规整过的）值，不合规返回 None。bool 要先判：Python 里 True 也是 int。"""
    if kind is bool:
        return value if isinstance(value, bool) else None
    if isinstance(value, bool):
        return None
    if kind is int:
        if isinstance(value, float) and math.isfinite(value) and value.is_integer():
            value = int(value)
        return value if isinstance(value, int) and _INT_MIN <= value <= _INT_MAX else None
    if kind is float:
        return round(float(value), 3) if isinstance(value, (int, float)) and math.isfinite(value) else None
    if kind is str:
        return value[:MAX_STRING] if isinstance(value, str) else None
    return None


def clean_props(name: str, props: dict) -> dict:
    allowed = EVENTS[name]
    out = {}
    for key, value in props.items():
        kind = allowed.get(key)
        if kind is None:
            continue
        cleaned = _value(kind, value)
        if cleaned is not None:
            out[key] = cleaned
    return out


def occurred_at(t_ms: int, sent_at_ms: int, now: dt.datetime) -> dt.datetime | None:
    """换算到服务器的钟。太旧返回 None。"""
    try:
        at = now - dt.timedelta(milliseconds=sent_at_ms - t_ms)
    except OverflowError:
        return None
    if at > now:
        at = now
    if at < now - MAX_AGE:
        return None
    return at


async def record(player_id: uuid.UUID, events: list[dict], sent_at_ms: int, install_id: uuid.UUID | None,
                 build: int | None, now: dt.datetime | None = None) -> dict:
    """events 里每条是 {id, name, t, sid, props}（已过路由层的格式校验）。"""
    now = now or dt.datetime.now(dt.UTC)
    rejected: list[dict] = []
    rows: dict[uuid.UUID, tuple] = {}
    for event in events:
        event_id, name = event["id"], event["name"]
        if name not in EVENTS:
            rejected.append({"id": str(event_id), "reason": "unknown_event"})
            continue
        at = occurred_at(int(event["t"]), sent_at_ms, now)
        if at is None:
            rejected.append({"id": str(event_id), "reason": "too_old"})
            continue
        # 同一批里同一个编号出现两次：只算一条（第二条会在下面算成 duplicate）。
        rows.setdefault(event_id, (name, at, event.get("sid"),
                                   json.dumps(clean_props(name, event.get("props") or {}), ensure_ascii=False)))
    accepted: set[uuid.UUID] = set()
    if rows:
        ids = list(rows)
        try:
            async with db.pool().acquire() as conn:
                returned = await conn.fetch(
                    _INSERT, player_id, install_id, build, ids,
                    [rows[i][0] for i in ids], [rows[i][1] for i in ids],
                    [rows[i][2] for i in ids], [rows[i][3] for i in ids])
        except asyncpg.UndefinedTableError:
            raise NotReady("数据库还没跑 database/026_client_events.sql") from None
        accepted = {r["event_id"] for r in returned}
    rejected_ids = {r["id"] for r in rejected}
    duplicate = [str(e["id"]) for e in events
                 if e["id"] not in accepted and str(e["id"]) not in rejected_ids]
    return {"accepted": sorted(str(i) for i in accepted), "duplicate": sorted(set(duplicate)),
            "rejected": rejected}
