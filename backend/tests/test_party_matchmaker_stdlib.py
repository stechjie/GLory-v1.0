"""Matchmaker integration checks without the optional backend test environment."""

import asyncio
import sys
import types
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

ranked = types.ModuleType("app.ranked")
ranked.window_state = lambda *_a: {"accepting": True}
# tick() 认的是 accepting_now（时间表 or 测试开关），不是 window_state。
# 这个桩模块必须跟着那条缝走，否则 tick 会 AttributeError。
ranked.accepting_now = lambda *_a: True


async def _no_penalty(_players):
    return None


ranked.punish_no_accept = _no_penalty
sys.modules["app.ranked"] = ranked

party = types.ModuleType("app.party")
finished = []
idled = []


class PartyStub:
    # 10.10 bug 第 6 条：确认弹窗要画两队头像，匹配服务会从组队房读公开身份
    # （matchmaking._public_profiles → party.Room.profiles）。测试按需塞。
    profiles_by_player = {}

    # 10.10 bug 第 9 条：排位房间不关，matchmaking 会把这一局的 match_uid 一起传下来。
    def finish_for_match(self, players, match_uid=""):
        finished.append(players)

    def of(self, _player):
        profile = self.profiles_by_player.get(_player)
        if profile is None:
            return None
        return types.SimpleNamespace(profiles={_player: profile})

    def mark_idle(self, room):
        idled.append(room)

    async def broadcast(self, _room):
        return None


party.current = lambda: PartyStub()

import app as app_package  # noqa: E402
from app import matchmaking  # noqa: E402


def player(index):
    return uuid.UUID(int=index)


TRIO = [player(1), player(2), player(3)]


class PartyMatchTests(unittest.TestCase):
    def setUp(self):
        # matchmaking 里是 `from app import party`（函数内现取）。整套 pytest 一起跑时，
        # 别的测试先导入过真的 app.party，包上的 `party` 属性已经指向它 —— 只换 sys.modules 不够，
        # 两处都换成桩，测完换回去（这一条原来在整套跑时必红）。
        self._saved = (sys.modules.get("app.party"), getattr(app_package, "party", None))
        sys.modules["app.party"] = party
        app_package.party = party
        finished.clear()
        idled.clear()
        self.sent = []

        async def send(pid, payload):
            self.sent.append((pid, payload))
            return 1

        self.maker = matchmaking.Matchmaker(send, now=lambda: 100.0)

    def tearDown(self):
        module, attribute = self._saved
        if module is None:
            sys.modules.pop("app.party", None)
        else:
            sys.modules["app.party"] = module
        if attribute is None:
            if hasattr(app_package, "party"):
                delattr(app_package, "party")
        else:
            app_package.party = attribute

    def _match_trio_with_three_solos(self):
        self.maker.join_group(TRIO.copy(), matchmaking.CASUAL)
        for i in range(4, 7):
            self.maker.join(player(i), matchmaking.CASUAL)
        asyncio.run(self.maker.tick())
        self.assertEqual(len(self.sent), 6)
        self.sent.clear()

    # ---- 10.10 bug 第 6 条：found 消息带「两队座位 + 公开身份 + 谁确认了」------
    def test_found_message_carries_public_seat_roster(self):
        PartyStub.profiles_by_player = {
            player(1): {"player_name": "阿甲", "friend_code": "AAA00001",
                        "avatar": "avatar_a", "avatar_frame": "frame_a"},
            player(4): {"player_name": "阿丁", "friend_code": "AAA00004",
                        "avatar": "avatar_d", "avatar_frame": "frame_d"},
        }
        try:
            self._match_trio_with_three_solos()
            # _match_trio_with_three_solos 把 sent 清空了 ⇒ 重新从 state_of 取一份
            # （推送与 /v1/match/state 走的是同一个 found_for，形状一致）。
            state = self.maker.state_of(player(1))
            seats = state["seats"]
            self.assertEqual(len(seats), 6, "六个座位都要下发")
            self.assertEqual([s["team"] for s in seats], [0, 0, 0, 1, 1, 1],
                             "按 team 排序：三红三蓝")
            me = [s for s in seats if s["me"]]
            self.assertEqual(len(me), 1, "只有自己那一个是 me")
            self.assertEqual(me[0]["name"], "阿甲", "自己的公开昵称从组队房带出来")
            self.assertEqual(me[0]["avatar"], "avatar_a")
            self.assertFalse(me[0]["accepted"], "还没确认")
            # 🔴 名片里的 friend_code 绝不能进这条消息（10.04 第 5 条同口径）。
            for seat in seats:
                self.assertNotIn("friend_code", seat)
                self.assertNotIn("player_id", seat)
                self.assertNotIn("AAA", str(seat))
            # 组队房里没有名片的人（2/3/5/6）留空，客户端画占位，不是崩。
            self.assertEqual(next(s for s in seats if s["name"] == "")["avatar"], "")
            # 确认之后 accepted 翻转，且**每个人看到的都是同一份**。
            self.maker.accept(player(1))
            self.maker.accept(player(4))
            later = {s["name"]: s["accepted"] for s in self.maker.state_of(player(2))["seats"]}
            self.assertTrue(later["阿甲"], "队友确认后，别人也该看到 √")
            self.assertTrue(later["阿丁"])
        finally:
            PartyStub.profiles_by_player = {}

    def test_existing_solo_path(self):
        for i in range(1, 7):
            self.maker.join(player(i), matchmaking.CASUAL)
        asyncio.run(self.maker.tick())
        self.assertEqual(len(self.sent), 6)
        self.assertEqual({msg["state"] for _, msg in self.sent}, {"found"})
        self.assertFalse(finished)

    def test_two_person_party_is_rejected(self):
        # 只能单排或满 3 人（docs/排位系统设计.md；10-08 休闲也一样）。
        with self.assertRaises(ValueError):
            self.maker.join_group([player(1), player(2)], matchmaking.CASUAL)
        self.assertEqual(self.maker.state_of(player(1))["state"], "idle")

    def test_trio_stays_together_and_room_closes_only_after_all_accept(self):
        self._match_trio_with_three_solos()
        teams = {self.maker._pending[self.maker._pending_of[pid]].member(pid).team for pid in TRIO}
        self.assertEqual(len(teams), 1)
        # 成桌时不关队伍房间：确认阶段有人拒绝，队伍还要能整队放回去。
        self.assertFalse(finished)
        for i in range(1, 7):
            self.maker.accept(player(i))
        self.assertEqual(len(finished), 1)

    def test_solo_decline_puts_trio_back_as_a_trio(self):
        self._match_trio_with_three_solos()
        self.maker.leave(player(4))
        queue = self.maker._party_queues[matchmaking.CASUAL]
        self.assertEqual(list(queue), [player(1)])
        self.assertEqual(queue[player(1)].party, TRIO)
        for pid in TRIO:
            self.assertEqual(self.maker.state_of(pid)["state"], "queued")
            self.assertNotIn(pid, self.maker._queues[matchmaking.CASUAL])
        self.assertEqual(self.maker._pending_penalties, [player(4)])
        self.assertFalse(finished)

    def test_decline_inside_trio_sends_trio_back_to_room(self):
        self._match_trio_with_three_solos()
        self.maker.leave(player(2))
        for pid in TRIO:
            self.assertEqual(self.maker.state_of(pid)["state"], "idle")
        self.assertFalse(self.maker._party_queues[matchmaking.CASUAL])
        # 只罚拒绝的那一个，队友不罚；另外三个单人回队列最前面。
        self.assertEqual(self.maker._pending_penalties, [player(2)])
        for i in range(4, 7):
            self.assertEqual(self.maker.state_of(player(i))["state"], "queued")

    def test_timeout_messages_keep_trio_together(self):
        self._match_trio_with_three_solos()
        self.maker.accept(player(1))
        self.maker._now = lambda: 100.0 + matchmaking.ACCEPT_TIMEOUT_SEC + 1.0
        asyncio.run(self.maker.tick())
        states = {pid: msg for pid, msg in self.sent}
        self.assertEqual(states[player(1)]["state"], "idle")
        self.assertEqual(states[player(1)].get("reason"), "party_declined")
        self.assertEqual(states[player(2)].get("reason"), "declined")

    def test_trio_seats_carry_into_the_match(self):
        # 10-08：组队房里选的位置带进对局。三人队独占一队，一定按他们选的坐。
        wanted = {player(1): 2, player(2): 0, player(3): 1}
        self.maker.join_group(TRIO.copy(), matchmaking.CASUAL, None, wanted)
        for i in range(4, 7):
            self.maker.join(player(i), matchmaking.CASUAL)
        asyncio.run(self.maker.tick())
        for i in range(1, 7):
            self.maker.accept(player(i))
        for pid, seat in wanted.items():
            self.assertEqual(self.maker.assignment_for(pid).seat, seat)
        solo_seats = sorted(self.maker.assignment_for(player(i)).seat for i in range(4, 7))
        self.assertEqual(solo_seats, [0, 1, 2], "另一队的三个单人也要各占一个位置")

    def test_solo_seat_collision_first_come_first_served(self):
        a, b, c = player(1), player(2), player(3)
        parties = [matchmaking._Waiter(mode=matchmaking.CASUAL, joined_at=0.0, party=[a], seats={a: 0}),
                   matchmaking._Waiter(mode=matchmaking.CASUAL, joined_at=0.0, party=[b], seats={b: 0})]
        seats = matchmaking.allocate_seats([a, b, c], [0, 0, 0], parties)
        self.assertEqual(seats, [0, 1, 2], "两个单人都想坐 0 号：先到的坐，后到的坐剩下的空位")

    def test_cancelling_party_clears_all_members(self):
        self.maker.join_group(TRIO.copy(), matchmaking.CASUAL)
        self.assertEqual(self.maker.leave_group(player(2)), TRIO)
        for pid in TRIO:
            self.assertEqual(self.maker.state_of(pid)["state"], "idle")

    def test_party_only_resumes_after_all_disconnected_members_return(self):
        self.maker.join_group(TRIO.copy(), matchmaking.CASUAL)
        self.maker.on_disconnect(player(1))
        self.maker.on_disconnect(player(2))
        self.maker.state_of(player(1))
        self.assertGreater(self.maker._party_queues[matchmaking.CASUAL][player(1)].dropped_at, 0)
        self.maker.state_of(player(2))
        self.assertEqual(self.maker._party_queues[matchmaking.CASUAL][player(1)].dropped_at, 0)


if __name__ == "__main__":
    unittest.main()
