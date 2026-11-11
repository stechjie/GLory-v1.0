"""Shared FIFO team formation, separate from opponent selection.

Entries refer to the original queue waiter. Queue storage remains authoritative
for cancellation, reconnect and party membership; forming a team resets no clock.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any
import uuid

RANKED_WAIT_SEC = 30.0


@dataclass(eq=False)
class QueuedEntry:
    key: uuid.UUID
    waiter: Any
    grouped: bool

    @property
    def size(self) -> int:
        return len(self.waiter.party)

    @property
    def age_key(self) -> tuple[float, int]:
        return self.waiter.joined_at, self.waiter.queue_order


@dataclass(eq=False)
class QueuedTeam:
    entries: list[QueuedEntry] = field(default_factory=list)

    @property
    def size(self) -> int:
        return sum(entry.size for entry in self.entries)

    @property
    def age_key(self) -> tuple[float, int]:
        return min(entry.age_key for entry in self.entries)


class TeamQueue:
    def __init__(self, wait_sec: float = RANKED_WAIT_SEC) -> None:
        self.wait_sec = wait_sec
        self.teams: list[QueuedTeam] = []

    def refresh(self, entries: list[QueuedEntry]) -> None:
        active = {id(entry.waiter): entry for entry in entries}
        claimed: set[int] = set()
        for team in self.teams:
            # Cancellation removes only the original party/solo entry, not its
            # unrelated teammates. A new enqueue never revives an old waiter.
            team.entries = [active[id(e.waiter)] for e in team.entries
                            if id(e.waiter) in active and id(e.waiter) not in claimed]
            claimed.update(id(e.waiter) for e in team.entries)
        self.teams = [team for team in self.teams if team.entries]
        self.teams.sort(key=lambda team: team.age_key)
        available = sorted((e for e in entries if id(e.waiter) not in claimed),
                           key=lambda e: e.age_key)

        def fill(team: QueuedTeam) -> None:
            while team.size < 3:
                index = next((i for i, e in enumerate(available)
                              if e.size <= 3 - team.size), None)
                if index is None:
                    break
                team.entries.append(available.pop(index))

        # Full teams stay together while waiting for an opponent.
        for team in self.teams:
            fill(team)
        while available:
            team = QueuedTeam([available.pop(0)])
            fill(team)
            self.teams.append(team)
        self.teams.sort(key=lambda team: team.age_key)

    def take_pairs(self, now: float, ai_enabled: bool) -> list[tuple[QueuedTeam, QueuedTeam | None]]:
        out: list[tuple[QueuedTeam, QueuedTeam | None]] = []
        # Never spend a full human opponent on AI when two full teams can play.
        full = [team for team in self.teams if team.size == 3]
        while len(full) >= 2:
            a, b = full[:2]
            del full[:2]
            self.teams.remove(a)
            self.teams.remove(b)
            out.append((a, b))
        if not ai_enabled:
            return out
        while True:
            due = [team for team in self.teams if now - team.age_key[0] >= self.wait_sec]
            if not due:
                break
            a = due[0]
            # 11-07：到点的一队拉上人数最多的另一队（不论它自己到没到点），同数取等得最久的。
            # 以前要求「不满员的对手先等满它自己的时限」，结果五个单排只要不是同一秒进队，
            # 就被拆成「3 真人对 3 AI」和「2 真人带 1 AI 对 3 AI」两桌。被提前拉进来的人
            # 只会更早开局；代价是少了一点「等来第三个真人队友」的机会，用户选了前者。
            others = [team for team in self.teams if team is not a]
            b = max(others, key=lambda team: team.size) if others else None
            self.teams.remove(a)
            if b is not None:
                self.teams.remove(b)
            out.append((a, b))
        return out

    def restore(self, sides: list[list[QueuedEntry]]) -> None:
        # refresh() will discard declined entries and retain the others' clocks.
        self.teams.extend(QueuedTeam(list(side)) for side in sides if side)


def balance_sides(sides: list[list[QueuedEntry]], capacity: int = 3) -> list[list[QueuedEntry]]:
    """AI 补位的一桌开桌前，把真人尽量平均分到两边（11-07 用户定）。

    规则：组队整份不拆；两边真人数差最小（于是 AI 数最多差 1，整队三人这种拆不开的除外）；
    同样平均时尽量少挪人，非挪不可就挪最晚进队的那份。等得最久的那份固定在 0 号队。
    满 6 个真人的桌不经过这里 —— 满员真人队照旧整队对整队。
    """
    entries = sorted((e for side in sides for e in side), key=lambda e: e.age_key)
    if not entries or sum(e.size for e in entries) >= 2 * capacity:
        return [list(side) for side in sides]
    original = {id(e): index for index, side in enumerate(sides) for e in side}
    best: tuple | None = None
    best_mask = 0
    # 一桌最多 6 份，穷举 64 种分法。bit i = 1 表示第 i 份坐 1 号队；第 0 份（最老）固定 0 号队。
    for mask in range(0, 1 << len(entries), 2):
        right = sum(e.size for i, e in enumerate(entries) if mask >> i & 1)
        left = sum(e.size for e in entries) - right
        if left > capacity or right > capacity:
            continue
        moved = sum(len(entries) - i for i, e in enumerate(entries)
                    if (mask >> i & 1) != original[id(e)])
        key = (abs(left - right), moved, mask)
        if best is None or key < best:
            best, best_mask = key, mask
    return [[e for i, e in enumerate(entries) if not best_mask >> i & 1],
            [e for i, e in enumerate(entries) if best_mask >> i & 1]]
