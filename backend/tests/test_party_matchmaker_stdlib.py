"""Matchmaker integration checks without the optional backend test environment."""

import asyncio
import sys
import types
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

ranked = types.ModuleType("app.ranked")
ranked.window_state = lambda: {"accepting": True}


async def _no_penalty(_players):
    return None


ranked.punish_no_accept = _no_penalty
sys.modules["app.ranked"] = ranked

party = types.ModuleType("app.party")
finished = []


class PartyStub:
    def finish_for_match(self, players):
        finished.append(players)


party.current = lambda: PartyStub()
sys.modules["app.party"] = party

from app import matchmaking  # noqa: E402


def player(index):
    return uuid.UUID(int=index)


class PartyMatchTests(unittest.TestCase):
    def setUp(self):
        finished.clear()
        self.sent = []

        async def send(pid, payload):
            self.sent.append((pid, payload))
            return 1

        self.maker = matchmaking.Matchmaker(send, now=lambda: 100.0)

    def test_existing_solo_path(self):
        for i in range(1, 7):
            self.maker.join(player(i), matchmaking.CASUAL)
        asyncio.run(self.maker.tick())
        self.assertEqual(len(self.sent), 6)
        self.assertEqual({msg["state"] for _, msg in self.sent}, {"found"})
        self.assertFalse(finished)

    def test_two_person_party_stays_together_with_four_solos(self):
        self.maker.join_group([player(1), player(2)], matchmaking.CASUAL)
        for i in range(3, 7):
            self.maker.join(player(i), matchmaking.CASUAL)
        asyncio.run(self.maker.tick())
        self.assertEqual(len(self.sent), 6)
        self.assertEqual(len(finished), 1)
        self.assertEqual({self.maker._pending[self.maker._pending_of[player(i)]].member(player(i)).team
                          for i in (1, 2)}, {0})

    def test_cancelling_party_clears_all_members(self):
        self.maker.join_group([player(1), player(2)], matchmaking.CASUAL)
        self.assertEqual(self.maker.leave_group(player(2)), [player(1), player(2)])
        self.assertEqual(self.maker.state_of(player(1))["state"], "idle")
        self.assertEqual(self.maker.state_of(player(2))["state"], "idle")

    def test_party_only_resumes_after_all_disconnected_members_return(self):
        self.maker.join_group([player(1), player(2)], matchmaking.CASUAL)
        self.maker.on_disconnect(player(1))
        self.maker.on_disconnect(player(2))
        self.maker.state_of(player(1))
        self.assertGreater(self.maker._party_queues[matchmaking.CASUAL][player(1)].dropped_at, 0)
        self.maker.state_of(player(2))
        self.assertEqual(self.maker._party_queues[matchmaking.CASUAL][player(1)].dropped_at, 0)


if __name__ == "__main__":
    unittest.main()
