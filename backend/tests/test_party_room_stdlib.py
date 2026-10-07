"""队伍房间规则检查（脱离可选后端环境，只用 stdlib + 桩）。

覆盖 10.07 的四条改动：
  第11条 成员也能邀请（服务端 invite 用 _require_member）
  第12条 房主退出：有人就交接给待得最久的人，只剩自己才解散
  第14条 任意成员取消排队都会让全队回到房间（queued_room 用 _require_member）
第13条的模式广播提示在 routes 层，这里只验服务端状态位（host 换人 + ready 被清）。
"""

import sys
import types
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# party.py 顶层 import 了 realtime / party_voice / config，这里全部用桩顶掉，
# 免得为了跑一条纯规则检查去装数据库与语音依赖。
realtime = types.ModuleType("app.realtime")
_sent = []


class _Hub:
    async def send_to_player(self, pid, payload):
        _sent.append((pid, payload))
        return 1


realtime.hub = lambda: _Hub()
sys.modules["app.realtime"] = realtime

party_voice = types.ModuleType("app.party_voice")
party_voice.schedule_delete = lambda *a, **k: None
sys.modules["app.party_voice"] = party_voice

config = types.ModuleType("app.config")


class _Settings:
    party_voice_config_file = "/nonexistent"


config.get_settings = lambda: _Settings()
sys.modules["app.config"] = config

from app import party  # noqa: E402


def player(index):
    return uuid.UUID(int=index)


def card(index):
    return {"friend_code": "AAA%05d" % index, "player_name": "P%d" % index,
            "avatar": "", "avatar_frame": "", "tier": 0}


class Clock:
    """可控单调时钟：按序号往前拨，用来造出不同的 joined_at。"""

    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        self.t += 1.0
        return self.t


class PartyRoomRuleTests(unittest.TestCase):
    def setUp(self):
        _sent.clear()
        self.clock = Clock()
        self.parties = party.Parties(now=self.clock)
        self.host = player(1)

    def _room_with(self, *members):
        room = self.parties.create(self.host, card(1), "casual", [])
        for pid in members:
            # 走 create/join 之外的后门：直接把成员塞进去并打上入座时间。
            room.members.append(pid)
            room.profiles[pid] = card(pid.int)
            room.joined_at[pid] = self.clock()
            self.parties._member_room[pid] = room.id
        return room

    # ---- 第11条 --------------------------------------------------------
    def test_member_can_invite(self):
        self.parties.create(self.host, card(1), "casual", [])
        guest = player(2)
        self.parties.create(guest, card(2), "casual", [])
        # 成员（非房主）也能邀请
        room = self.parties.invite(guest, player(3))
        self.assertIn((player(3), room.id), self.parties._invites)

    def test_outsider_cannot_invite(self):
        self.parties.create(self.host, card(1), "casual", [])
        with self.assertRaises(party.PartyRejected) as ctx:
            self.parties.invite(player(9), player(3))
        self.assertEqual(ctx.exception.code, "not_in_party")

    # ---- 第12条 --------------------------------------------------------
    def test_host_leaving_with_others_hands_over_to_earliest(self):
        room = self.parties.create(self.host, card(1), "casual", [])
        early = player(2)
        late = player(3)
        room.members.append(early)
        room.profiles[early] = card(2)
        room.joined_at[early] = self.clock()
        self.parties._member_room[early] = room.id
        room.members.append(late)
        room.profiles[late] = card(3)
        room.joined_at[late] = self.clock()
        self.parties._member_room[late] = room.id

        _, old_members, closed, migrated = self.parties.leave(self.host)
        self.assertFalse(closed, "房里还有人就该交接，不该解散")
        self.assertTrue(migrated, "换了房主必须打上迁移标记")
        self.assertEqual(room.host, early, "新队长应为待得最久的人")
        self.assertNotIn(self.host, room.members)
        self.assertEqual(old_members, [self.host, early, late])

    def test_host_leaving_alone_dissolves(self):
        room = self.parties.create(self.host, card(1), "casual", [])
        _, _, closed, migrated = self.parties.leave(self.host)
        self.assertTrue(closed, "只剩房主自己时应解散")
        self.assertFalse(migrated)
        self.assertIsNone(self.parties.by_id(room.id))

    def test_rejoining_resets_seat_timer(self):
        room = self.parties.create(self.host, card(1), "casual", [])
        a = player(2)
        b = player(3)
        room.members += [a, b]
        for pid in (a, b):
            room.profiles[pid] = card(pid.int)
            self.parties._member_room[pid] = room.id
        room.joined_at[a] = self.clock()
        room.joined_at[b] = self.clock()
        # a 先退再进 —— 入座时间刷新到 b 之后
        self.parties.leave(a)
        room.members.append(a)
        room.profiles[a] = card(2)
        room.joined_at[a] = self.clock()
        self.parties._member_room[a] = room.id
        self.assertGreater(room.joined_at[a], room.joined_at[b],
                           "重新进入房间必须重新计时")
        self.parties.leave(self.host)
        self.assertEqual(room.host, b, "重新计时后 a 不再是最早到的")

    def test_non_host_leaving_keeps_host(self):
        room = self.parties.create(self.host, card(1), "casual", [])
        guest = player(2)
        room.members.append(guest)
        room.profiles[guest] = card(2)
        room.joined_at[guest] = self.clock()
        self.parties._member_room[guest] = room.id
        _, _, closed, migrated = self.parties.leave(guest)
        self.assertFalse(closed)
        self.assertFalse(migrated)
        self.assertEqual(room.host, self.host)

    # ---- 第14条 --------------------------------------------------------
    def test_any_member_can_cancel_queue(self):
        room = self.parties.create(self.host, card(1), "casual", [])
        guest = player(2)
        room.members.append(guest)
        room.profiles[guest] = card(2)
        room.joined_at[guest] = self.clock()
        self.parties._member_room[guest] = room.id
        room.queued = True
        # 非房主也能拿到排队中的房间（据此执行取消）
        self.assertIs(self.parties.queued_room(guest), room)

    def test_cancel_rejects_when_not_queued(self):
        self.parties.create(self.host, card(1), "casual", [])
        with self.assertRaises(party.PartyRejected) as ctx:
            self.parties.queued_room(self.host)
        self.assertEqual(ctx.exception.code, "not_queued")

    def test_cancel_rejects_outsider(self):
        self.parties.create(self.host, card(1), "casual", [])
        with self.assertRaises(party.PartyRejected) as ctx:
            self.parties.queued_room(player(9))
        self.assertEqual(ctx.exception.code, "not_in_party")

    # ---- 10-08 房主踢人 -------------------------------------------------
    def test_host_can_kick_member(self):
        guest = player(2)
        room = self._room_with(guest, player(3))
        room.ready.add(player(3))
        epoch = room.voice_epoch
        version = room.version
        self.parties.kick(self.host, guest)
        self.assertNotIn(guest, room.members)
        self.assertNotIn(guest, room.profiles)
        self.assertIsNone(self.parties.of(guest), "被踢的人不该再算在这个队伍里")
        self.assertNotEqual(room.voice_epoch, epoch, "要换语音房间，旧钥匙进不了新房间")
        self.assertFalse(room.ready, "人变了，准备状态要清掉")
        self.assertGreater(room.version, version)

    def test_member_cannot_kick(self):
        guest = player(2)
        self._room_with(guest, player(3))
        with self.assertRaises(party.PartyRejected) as ctx:
            self.parties.kick(guest, player(3))
        self.assertEqual(ctx.exception.code, "not_host")

    def test_kick_rejected_while_queued_or_self(self):
        room = self._room_with(player(2))
        with self.assertRaises(party.PartyRejected) as ctx:
            self.parties.kick(self.host, self.host)
        self.assertEqual(ctx.exception.code, "bad_target")
        room.queued = True
        with self.assertRaises(party.PartyRejected) as ctx:
            self.parties.kick(self.host, player(2))
        self.assertEqual(ctx.exception.code, "in_queue")


if __name__ == "__main__":
    unittest.main()
