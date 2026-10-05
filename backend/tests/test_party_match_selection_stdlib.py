"""Run with Python's standard library, independent of backend dependencies."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.party_match_selection import select  # noqa: E402


def room(*players: int):
    return ("room", players[0], players)


def solo(player: int):
    return ("solo", player, (player,))


class PartySeatTests(unittest.TestCase):
    def check(self, rooms, solos):
        result = select(rooms, solos)
        self.assertIsNotNone(result)
        a, b = result
        self.assertEqual([sum(len(e[2]) for e in side) for side in (a, b)], [3, 3])
        self.assertEqual(a[0], rooms[0])
        self.assertEqual(len({p for side in (a, b) for e in side for p in e[2]}), 6)

    def test_one_person_room_with_solo_players(self):
        self.check([room(1)], [solo(i) for i in range(2, 7)])

    def test_two_person_room_with_solo_players(self):
        self.check([room(1, 2)], [solo(i) for i in range(3, 7)])

    def test_full_room_with_solo_players(self):
        self.check([room(1, 2, 3)], [solo(i) for i in range(4, 7)])

    def test_two_rooms_of_two_with_singles(self):
        self.check([room(1, 2), room(3, 4)], [solo(5), solo(6)])

    def test_three_pairs_cannot_be_split(self):
        self.assertIsNone(select([room(1, 2), room(3, 4), room(5, 6)], []))

    def test_no_party_keeps_solo_path(self):
        self.assertIsNone(select([], [solo(i) for i in range(1, 7)]))


if __name__ == "__main__":
    unittest.main()
