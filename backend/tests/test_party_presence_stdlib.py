"""队伍房「断线在场」规则检查（脱离可选后端环境，只用 stdlib + 桩）。

对应 10.08 反馈第 8 条：昵称「tin y」的玩家在别人房间界面里显示在房间里，
但他本人界面在主界面、也进不去那个房间（ghost 成员）。

成因：WS 断开时**没人通知 party**，room.members 里他那一项永久留着
（snapshot 直接遍历 members），所以他永远「在房里」，而他自己那条连接
早断了、重连后 _member_room 也是旧的。

这里钉三件事：
  ① on_disconnect 会记下断线时刻（不立刻摘 —— 手机切后台是常态）；
  ② 宽限期内他**仍然**是成员（别人看得见他、他重连回来还在原位）；
  ③ 宽限到期 prune_disconnected 真的把他摘掉，并像正常退房那样交接 / 解散。

以及反向对照：活人做一次动作（进来 / 准备 / 说话）必须清掉断线标记 ——
否则「一直连着但手没动」的人会被误当成 ghost 摘掉。
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
    """可控单调时钟：按需往前拨，用来跨过 LEFT_GRACE_SEC。"""

    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t

    def advance(self, seconds):
        self.t += seconds


class PartyPresenceTests(unittest.TestCase):
    def setUp(self):
        _sent.clear()
        self.clock = Clock()
        self.parties = party.Parties(now=self.clock)
        self.host = player(1)
        self.guest = player(2)

    def _room_with(self, *members):
        room = self.parties.create(self.host, card(1), "casual", [])
        for pid in members:
            room.members.append(pid)
            room.profiles[pid] = card(pid.int)
            room.joined_at[pid] = self.clock()
            self.parties._member_room[pid] = room.id
        return room

    # ---- ① 断线记账 ------------------------------------------------------
    def test_disconnect_marks_dropped(self):
        room = self._room_with(self.guest)
        self.parties.on_disconnect(self.guest)
        self.assertGreater(room.dropped_at.get(self.guest, 0.0), 0.0)

    def test_disconnect_is_idempotent(self):
        """断线两次（重连又断）不该把断线时刻往后推成「永不超时」。"""
        room = self._room_with(self.guest)
        self.parties.on_disconnect(self.guest)
        first = room.dropped_at[self.guest]
        self.clock.advance(10.0)
        self.parties.on_disconnect(self.guest)
        self.assertEqual(room.dropped_at[self.guest], first)

    def test_disconnect_outside_room_is_noop(self):
        """不在房里的人断线，不该凭空建出房间状态。"""
        self.parties.on_disconnect(player(99))
        self.assertEqual(self.parties.prune_disconnected(), [])

    # ---- ② 宽限期内仍在房 -------------------------------------------------
    def test_still_member_within_grace(self):
        room = self._room_with(self.guest)
        self.parties.on_disconnect(self.guest)
        self.clock.advance(party.LEFT_GRACE_SEC - 1.0)
        self.assertEqual(self.parties.prune_disconnected(), [])
        self.assertIn(self.guest, room.members)
        # 别人看到的快照里他还在。
        snapshot = self.parties.snapshot(room)
        self.assertEqual(len(snapshot["members"]), 2)

    # ---- ③ 宽限到期真摘 ---------------------------------------------------
    def test_prune_removes_expired_member(self):
        room = self._room_with(self.guest)
        self.parties.on_disconnect(self.guest)
        self.clock.advance(party.LEFT_GRACE_SEC + 1.0)
        touched = self.parties.prune_disconnected()
        self.assertEqual([r.id for r in touched], [room.id])
        self.assertNotIn(self.guest, room.members)
        self.assertNotIn(self.guest, room.profiles)
        self.assertIsNone(self.parties.of(self.guest))

    def test_prune_hands_over_host(self):
        """房主断了且到期：房里还有人 → 交接给他的下一位，房间不散。"""
        room = self._room_with(self.guest)
        self.parties.on_disconnect(self.host)
        self.clock.advance(party.LEFT_GRACE_SEC + 1.0)
        touched = self.parties.prune_disconnected()
        self.assertEqual([r.id for r in touched], [room.id])
        self.assertEqual(room.host, self.guest)
        self.assertIn(room.id, self.parties._rooms)

    def test_prune_dissolves_empty_room(self):
        """房主断了、房里没别人 → 到期后整个房间解散，不再广播。"""
        room = self.parties.create(self.host, card(1), "casual", [])
        self.parties.on_disconnect(self.host)
        self.clock.advance(party.LEFT_GRACE_SEC + 1.0)
        self.assertEqual(self.parties.prune_disconnected(), [])
        self.assertNotIn(room.id, self.parties._rooms)

    def test_prune_is_idempotent(self):
        room = self._room_with(self.guest)
        self.parties.on_disconnect(self.guest)
        self.clock.advance(party.LEFT_GRACE_SEC + 1.0)
        self.parties.prune_disconnected()
        self.assertEqual(self.parties.prune_disconnected(), [])

    # ---- 反向对照：活人不能被误摘 ----------------------------------------
    def test_mark_present_clears_mark(self):
        room = self._room_with(self.guest)
        self.parties.on_disconnect(self.guest)
        self.assertTrue(self.parties.mark_present(self.guest))
        self.assertEqual(room.dropped_at.get(self.guest, 0.0), 0.0)
        self.clock.advance(party.LEFT_GRACE_SEC + 1.0)
        self.parties.prune_disconnected()
        self.assertIn(self.guest, room.members)

    def test_activity_clears_mark(self):
        """没显式调 mark_present，但做了一次房间动作（改模式走 require_host，
        准备走 require_member）也该清掉断线标记。"""
        room = self._room_with(self.guest)
        self.parties.on_disconnect(self.guest)
        self.parties.set_ready(self.guest, True)
        self.assertEqual(room.dropped_at.get(self.guest, 0.0), 0.0)

    def test_rejoin_clears_mark(self):
        """被邀请重新进来 = 重新计时，断线标记不该跟着进新的一轮。"""
        room = self.parties.create(self.host, card(1), "casual", [])
        self.parties.on_disconnect(self.host)
        # 房主重新被邀请进来（这里直接走 join 的后门：塞邀请再 join）。
        self.parties._invites[(self.guest, room.id)] = self.clock() + 100.0
        self.parties.join(self.guest, room.id, card(2))
        self.assertEqual(room.dropped_at.get(self.guest, 0.0), 0.0)


if __name__ == "__main__":
    unittest.main()
