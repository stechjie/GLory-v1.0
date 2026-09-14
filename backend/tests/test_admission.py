"""同时在线上限与排队（app/admission.py）。

不连网络、不起服务：假时钟 + 记下发出去的消息。判据全在名额表与队列自己的行为上。
WebSocket 端点的接线在 test_ws.py 末尾。

最要紧的几条，失败时都不报错：
  1. 🔴 resume 一律放行 —— 否则在游戏里的人会因为一次重连被踢回排队画面
  2. 🔴 断线宽限期内名额不收回 —— 否则切一次后台就要重新排
  3. 🔴 先来后到 —— 有人在排时，新来的不许因为恰好空出位子就插到前面
  4. 重启预热期不放 enter —— 否则一次重启就把整个队列放进来
"""

from __future__ import annotations

import asyncio
import json
import os
import uuid
from pathlib import Path

import pytest

from app import admission
from app.realtime import Connection

ADMITTED = admission.admitted_message()
ENTER = admission.ENTER
RESUME = admission.RESUME


class _Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


class _Outbox:
    def __init__(self) -> None:
        self.sent: list[tuple[uuid.UUID, dict]] = []

    async def __call__(self, conn: Connection, payload: dict) -> bool:
        self.sent.append((conn.player_id, payload))
        return True

    def to(self, player_id: uuid.UUID) -> list[dict]:
        return [payload for pid, payload in self.sent if pid == player_id]


def _conn(player_id: uuid.UUID, device: str = "device-aaaaaaaa") -> Connection:
    return Connection(player_id=player_id, device_session_id=device, websocket=None)  # type: ignore[arg-type]


def _gate(limit: int, *, warmup: float = 0.0, config_path: str = ""):
    clock = _Clock()
    outbox = _Outbox()
    gate = admission.Admission(
        outbox, limit=limit, config_path=config_path, now=clock, warmup_sec=warmup)
    return gate, clock, outbox


def _tick(gate: admission.Admission) -> None:
    asyncio.run(gate.tick())


# --- 来意 ---------------------------------------------------------------------


def test_parse_intent() -> None:
    assert admission.parse_intent(None) == admission.LEGACY
    assert admission.parse_intent("enter") == ENTER
    assert admission.parse_intent(" Resume ") == RESUME
    # 看不懂的值当 enter：来意是客户端自报的，往严了算。
    assert admission.parse_intent("vip") == ENTER
    assert admission.parse_intent("") == ENTER


# --- 放行与排队 ---------------------------------------------------------------


def test_under_limit_admits_immediately() -> None:
    gate, _, _ = _gate(2)
    assert gate.join(_conn(uuid.uuid4()), ENTER) == ADMITTED
    assert gate.join(_conn(uuid.uuid4()), ENTER) == ADMITTED
    assert gate.stats()["online"] == 2


def test_full_enter_is_queued_in_order() -> None:
    gate, _, _ = _gate(1)
    gate.join(_conn(uuid.uuid4()), ENTER)
    assert gate.join(_conn(uuid.uuid4()), ENTER) == admission.queued_message(1)
    assert gate.join(_conn(uuid.uuid4()), ENTER) == admission.queued_message(2)
    assert gate.stats()["queued"] == 2


def test_resume_is_admitted_over_limit() -> None:
    """🔴 已经在游戏里的人重连，满了也放。

    他很可能正在一局 30 分钟的对局里。把他挡在排队画面，等于让 AI 替他打完这一局。
    """
    gate, _, _ = _gate(1)
    gate.join(_conn(uuid.uuid4()), ENTER)
    assert gate.join(_conn(uuid.uuid4()), RESUME) == ADMITTED
    stats = gate.stats()
    assert stats["online"] == 2
    assert stats["queued"] == 0


def test_legacy_client_is_admitted_and_counted() -> None:
    """旧版客户端不会排队，只能放；但它确实在线、确实在用服务器，所以计入人数。"""
    gate, _, _ = _gate(1)
    assert gate.join(_conn(uuid.uuid4()), admission.LEGACY) == ADMITTED
    assert gate.join(_conn(uuid.uuid4()), ENTER) == admission.queued_message(1)


def test_new_entrant_queues_behind_waiters_even_with_free_slots() -> None:
    """🔴 先来后到。

    上限刚调大、或者刚空出位子而下一轮放人还没跑的那一瞬间进来的人，
    不许插到已经在排的人前面。
    """
    gate, _, outbox = _gate(1)
    gate.join(_conn(uuid.uuid4()), ENTER)
    early = uuid.uuid4()
    gate.join(_conn(early), ENTER)
    gate.limit = 5
    late = uuid.uuid4()
    assert gate.join(_conn(late), ENTER) == admission.queued_message(2)
    _tick(gate)
    assert [pid for pid, payload in outbox.sent if payload == ADMITTED] == [early, late]


# --- 断线宽限 -----------------------------------------------------------------


def test_seat_is_held_through_grace_then_released_to_queue() -> None:
    """🔴 名额在宽限期内不收回。否则手机切一次后台，回来就得重新排。"""
    gate, clock, outbox = _gate(1)
    first = _conn(uuid.uuid4())
    gate.join(first, ENTER)
    waiting = uuid.uuid4()
    gate.join(_conn(waiting), ENTER)
    gate.leave(first)

    clock.advance(admission.SEAT_GRACE_SEC - 1)
    _tick(gate)
    assert ADMITTED not in outbox.to(waiting), "宽限期还没过，名额就被收回给下一个人了"

    clock.advance(2)
    _tick(gate)
    assert ADMITTED in outbox.to(waiting)
    assert gate.stats()["online"] == 1
    assert gate.stats()["queued"] == 0


def test_reconnect_within_grace_reclaims_seat_without_overflow() -> None:
    """🔴 宽限期内回来是认回原来的名额，不是「超上限再塞一个」。

    冷启动回来带的是 enter —— 仍然要认得出是同一个人。
    """
    gate, clock, _ = _gate(1)
    pid = uuid.uuid4()
    old = _conn(pid)
    gate.join(old, ENTER)
    gate.leave(old)
    clock.advance(admission.SEAT_GRACE_SEC - 10)
    assert gate.join(_conn(pid), ENTER) == ADMITTED
    assert gate.stats()["online"] == 1
    assert gate.join(_conn(uuid.uuid4()), ENTER) == admission.queued_message(1)


def test_other_device_inherits_the_seat() -> None:
    """换设备：新连接接过名额；旧连接随后走 finally 的 leave 不能把它放掉。

    同 realtime.Hub.unregister 那条：少了「只认自己那条」的判断，
    症状是名额被悄悄放掉、多放进来一个人，而且没有任何报错。
    """
    gate, _, _ = _gate(1)
    pid = uuid.uuid4()
    old = _conn(pid, "device-aaaaaaaa")
    new = _conn(pid, "device-bbbbbbbb")
    gate.join(old, ENTER)
    assert gate.join(new, ENTER) == ADMITTED
    gate.leave(old)
    stats = gate.stats()
    assert stats["online"] == 1
    assert stats["online_connected"] == 1


def test_queued_player_keeps_place_through_a_short_drop() -> None:
    gate, clock, _ = _gate(1)
    gate.join(_conn(uuid.uuid4()), ENTER)
    first = uuid.uuid4()
    old = _conn(first)
    gate.join(old, ENTER)
    gate.join(_conn(uuid.uuid4()), ENTER)
    gate.leave(old)
    clock.advance(admission.QUEUE_GRACE_SEC - 1)
    _tick(gate)
    assert gate.join(_conn(first), ENTER) == admission.queued_message(1)


def test_disconnected_waiter_is_skipped_then_dropped() -> None:
    """断开的人轮到时先跳过（不挡后面的人），宽限过了才出队。"""
    gate, clock, outbox = _gate(1)
    holder = _conn(uuid.uuid4())
    gate.join(holder, ENTER)
    gone_pid, next_pid = uuid.uuid4(), uuid.uuid4()
    gone = _conn(gone_pid)
    gate.join(gone, ENTER)
    gate.join(_conn(next_pid), ENTER)

    gate.leave(holder)
    clock.advance(admission.SEAT_GRACE_SEC - 10)
    gate.leave(gone)
    clock.advance(10)
    _tick(gate)
    assert ADMITTED in outbox.to(next_pid), "断开的人挡住了后面的人"
    assert ADMITTED not in outbox.to(gone_pid)
    assert gate.position_of(gone_pid) == 1, "还在宽限期里的人被挤出队列了"

    clock.advance(admission.QUEUE_GRACE_SEC)
    _tick(gate)
    assert gate.position_of(gone_pid) == 0


# --- 放人节奏 -----------------------------------------------------------------


def test_warmup_holds_enter_but_not_resume() -> None:
    """重启预热期：排队的人先别放，在游戏里的人照常回来。理由见 admission 文件头。"""
    gate, clock, outbox = _gate(10, warmup=admission.WARMUP_SEC)
    fresh = uuid.uuid4()
    assert gate.join(_conn(fresh), ENTER) == admission.queued_message(1)
    assert gate.join(_conn(uuid.uuid4()), RESUME) == ADMITTED
    _tick(gate)
    assert ADMITTED not in outbox.to(fresh)

    clock.advance(admission.WARMUP_SEC)
    _tick(gate)
    assert ADMITTED in outbox.to(fresh)


def test_warmup_covers_client_reconnect_backoff() -> None:
    """预热期要盖住客户端重连退避的前五档（RealtimeService：1、2、4、8、16 秒）。

    盖不住的话，退避到第五档才回来的「在游戏里的人」会发现名额已经被排队的人占满了 ——
    他带着 resume 照样能进，但人数就超出去了。
    """
    assert admission.WARMUP_SEC > 1 + 2 + 4 + 8 + 16


def test_admissions_per_tick_are_capped() -> None:
    gate, clock, _ = _gate(1000, warmup=1.0)
    for _ in range(admission.ADMIT_PER_TICK + 5):
        gate.join(_conn(uuid.uuid4()), ENTER)
    clock.advance(1.0)
    _tick(gate)
    assert gate.stats()["online"] == admission.ADMIT_PER_TICK
    clock.advance(admission.TICK_SEC)
    _tick(gate)
    assert gate.stats()["online"] == admission.ADMIT_PER_TICK + 5


def test_positions_are_pushed_only_when_they_change() -> None:
    gate, clock, outbox = _gate(1)
    holder = _conn(uuid.uuid4())
    gate.join(holder, ENTER)
    gate.join(_conn(uuid.uuid4()), ENTER)
    third = uuid.uuid4()
    gate.join(_conn(third), ENTER)

    gate.leave(holder)
    clock.advance(admission.SEAT_GRACE_SEC)
    _tick(gate)
    assert outbox.to(third)[-1] == admission.queued_message(1)

    before = len(outbox.to(third))
    clock.advance(admission.POSITION_PUSH_SEC)
    _tick(gate)
    assert len(outbox.to(third)) == before, "位次没变也在重发"


def test_loop_survives_a_failing_tick(monkeypatch: pytest.MonkeyPatch) -> None:
    """巡检出一次错不能把循环带走 —— 那样队伍永远不动，而且不报错。"""
    monkeypatch.setattr(admission, "TICK_SEC", 0.0)
    calls = 0

    class _Flaky:
        async def tick(self) -> None:
            nonlocal calls
            calls += 1
            if calls == 1:
                raise RuntimeError("第一轮故意失败")

    async def _run() -> None:
        task = asyncio.create_task(admission.loop(_Flaky()))  # type: ignore[arg-type]
        while calls < 3:
            await asyncio.sleep(0)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    asyncio.run(asyncio.wait_for(_run(), 5))


# --- 上限文件 -----------------------------------------------------------------


def _rewrite(path: Path, text: str) -> None:
    before = path.stat().st_mtime
    path.write_text(text, encoding="utf-8")
    # 同一时刻连写两次时有的文件系统 mtime 不变 —— 显式推一下，别让测试碰运气。
    os.utime(path, (before + 10, before + 10))


def test_limit_file_is_applied_and_hot_reloaded(tmp_path: Path) -> None:
    path = tmp_path / "admission.json"
    path.write_text(json.dumps({"online_limit": 3}), encoding="utf-8")
    gate, clock, _ = _gate(1000, config_path=str(path))
    assert gate.limit == 3, "启动时就该读文件，不能等第一轮巡检"

    _rewrite(path, json.dumps({"online_limit": 5}))
    clock.advance(admission.CONFIG_RELOAD_SEC)
    _tick(gate)
    assert gate.limit == 5


@pytest.mark.parametrize(
    "bad",
    [
        pytest.param("{not json", id="不是 JSON"),
        pytest.param(json.dumps({"online_limit": 0}), id="零"),
        pytest.param(json.dumps({"online_limit": "400"}), id="字符串"),
        pytest.param(json.dumps({"online_limit": True}), id="布尔"),
        pytest.param(json.dumps({"online_limit": 400.5}), id="小数"),
        pytest.param(json.dumps([400]), id="不是对象"),
    ],
)
def test_bad_limit_file_keeps_the_previous_limit(tmp_path: Path, bad: str) -> None:
    """写坏配置不能让上限变成 0（全服进不去）或者悄悄失效。保留上一次的好值。"""
    path = tmp_path / "admission.json"
    path.write_text(json.dumps({"online_limit": 3}), encoding="utf-8")
    gate, clock, _ = _gate(1000, config_path=str(path))
    _rewrite(path, bad)
    clock.advance(admission.CONFIG_RELOAD_SEC)
    _tick(gate)
    assert gate.limit == 3


def test_removing_the_limit_file_falls_back_to_default(tmp_path: Path) -> None:
    path = tmp_path / "admission.json"
    path.write_text(json.dumps({"online_limit": 3}), encoding="utf-8")
    gate, clock, _ = _gate(7, config_path=str(path))
    path.unlink()
    clock.advance(admission.CONFIG_RELOAD_SEC)
    _tick(gate)
    assert gate.limit == 7
