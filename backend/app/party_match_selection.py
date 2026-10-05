"""Pure, bounded 3v3 seat selection for pre-match rooms.

Each entry is (kind, leader, members). ``kind`` is ``room`` or ``solo``.
The oldest room is anchored on the first side; groups are never split.
"""

from __future__ import annotations

import itertools
from typing import TypeVar

Key = TypeVar("Key")
Entry = tuple[str, Key, tuple[Key, ...]]


def select(rooms: list[Entry], solos: list[Entry]) -> tuple[list[Entry], list[Entry]] | None:
    if not rooms:
        return None
    first = rooms[0]
    candidates = rooms[1:9] + solos[:8]
    for a_count in range(3):
        for a_extra in itertools.combinations(candidates, a_count):
            side_a = [first, *a_extra]
            if sum(len(entry[2]) for entry in side_a) != 3:
                continue
            used = {entry[1] for entry in side_a}
            remaining = [entry for entry in candidates if entry[1] not in used]
            for b_count in range(1, 4):
                for side_b in itertools.combinations(remaining, b_count):
                    if sum(len(entry[2]) for entry in side_b) == 3:
                        return side_a, list(side_b)
    return None
