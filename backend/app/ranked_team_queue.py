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
            # An incomplete opponent must reach its own deadline first.
            b = next((team for team in self.teams if team is not a and team.size == 3), None)
            if b is None:
                b = next((team for team in due if team is not a), None)
            self.teams.remove(a)
            if b is not None:
                self.teams.remove(b)
            out.append((a, b))
        return out

    def restore(self, sides: list[list[QueuedEntry]]) -> None:
        # refresh() will discard declined entries and retain the others' clocks.
        self.teams.extend(QueuedTeam(list(side)) for side in sides if side)
