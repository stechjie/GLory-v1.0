"""组队邀请接口的**行为**用例：直接驱动 `routes/party.py` 的 `invite()`（不连数据库）。

## 为什么需要「行为」这一层

已有的两组判据都够不着这次的事故：

  · `test_party_invite_route_stdlib.py` —— **AST** 静态判据，只看代码_shape_；
  · `test_chat_kind_migration_stdlib.py` —— 约束取值集合 vs 代码常量的交叉校验。

2026-10-07 的线上 500（排位房间点「邀请好友」）**两组都没抓到**，因为它既不是
「代码长得不对」也不是「约束对不上」，而是**运行时名字解析**出错：
`routes/party.py` 底部有个路由函数 `async def chat(...)`，把顶部
`from app import chat` 那个**私聊模块**盖掉了 ⇒ `invite()` 里的
`chat.send(...)` 实际拿到的是那个路由函数 ⇒
`AttributeError: 'function' object has no attribute 'send'`。

这种「只有真跑一遍才现形」的问题，只能靠真跑一遍来钉。

## 做法

把外部依赖（db / players / friends / profile / chat.send / realtime.hub）换成桩，
**用真的 `Parties` 单例**驱动真的 `invite()`。三个场景各自钉一件事：

  1. `invite()` 真的走到了 `chat.send` —— ★ 这条就是**遮蔽的探针**：
     名字被盖住时 `chat.send` 根本不会被调用（AttributeError 被宽兜底吃掉），
     只有把「桩被调到过」写成断言，才看得见。
  2. 私聊落库抛 `CheckViolationError`（复刻 030 迁移没跑）时，
     邀请**不能**变 500，而且 `party_invite` 实时推送**照发** —— 「拉好友」得成立。
  3. 正常路径：一条 `kind='party_invite'` 的私聊消息要真的推给被邀请人
     （这就是 10.07 第 10 条、以及用户真机反复提的「邀请后聊天里要有邀请消息」）。

★ 每个用例在 `setUp` 里打桩、`tearDown` 里**逐个还原**。
  不还原的话，本文件会污染同一个进程里后面的用例（全量跑时这种串味最难查）。
"""

from __future__ import annotations

import asyncio
import datetime
import types
import unittest
import uuid

import asyncpg

from app import chat, db, friends, party as party_mod, players, profile, realtime
import app.routes.party as route

HOST = uuid.uuid4()
TARGET = uuid.uuid4()
FRIEND_CODE = "BBBBBBBB"


class _FakeConn:
    class _Ctx:
        async def __aenter__(self):
            return _FakeConn()

        async def __aexit__(self, *_exc):
            return False

    def acquire(self):
        return _FakeConn._Ctx()


class _FakeHub:
    def __init__(self) -> None:
        self.pushes: list[tuple[uuid.UUID, dict]] = []

    def is_online(self, _player_id) -> bool:
        return True

    async def send_to_player(self, player_id, payload) -> int:
        self.pushes.append((player_id, payload))
        return 1

    def of_type(self, kind: str) -> list[tuple[uuid.UUID, dict]]:
        return [(p, d) for p, d in self.pushes if d.get("t") == kind]


class PartyInviteBehaviorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.hub = _FakeHub()
        self.calls = {"chat_send": 0, "kind": None}
        self._saved = {}

        def patch(obj, name, value):
            self._saved.setdefault((obj, name), getattr(obj, name))
            setattr(obj, name, value)

        async def get_by_auth_uid(_auth_uid):
            return types.SimpleNamespace(player_id=HOST, friend_code="AAAAAAAA",
                                         player_name="房主")

        async def relation_to(*_a, **_k):
            return "friends"

        async def get_by_friend_code(code):
            return types.SimpleNamespace(player_id=TARGET, friend_code=code,
                                         player_name="队友")

        patch(db, "is_connected", lambda: True)
        patch(db, "pool", lambda: _FakeConn())
        patch(players, "get_by_auth_uid", get_by_auth_uid)
        patch(friends, "relation_to", relation_to)
        patch(profile, "get_by_friend_code", get_by_friend_code)
        patch(realtime, "hub", lambda: self.hub)

        # 队伍状态用**真的** Parties —— 复刻一份会随生产代码漂移，测了等于没测。
        self.parties = party_mod.Parties()
        self._saved[(party_mod, "_instance")] = party_mod._instance
        party_mod.install(self.parties)

    def tearDown(self) -> None:
        for (obj, name), value in self._saved.items():
            setattr(obj, name, value)

    # --- 辅助 ---------------------------------------------------------------

    def _new_room(self) -> party_mod.Room:
        return self.parties.create(
            HOST, {"friend_code": "AAAAAAAA", "player_name": "房主"}, "ranked", [])

    def _invite(self):
        """真调一次 invite()，返回 (异常 or None, 返回值 or None)。"""
        try:
            return None, asyncio.run(route.invite(
                route.InviteBody(friend_code=FRIEND_CODE),
                types.SimpleNamespace(auth_uid="uid-1")))
        except Exception as exc:  # noqa: BLE001 - 用例就是要看见它有没有冒出来
            return exc, None

    def _patch_chat_send(self, impl) -> None:
        self._saved.setdefault((chat, "send"), chat.send)
        chat.send = impl

    # --- 用例 ---------------------------------------------------------------

    def test_invite_actually_reaches_the_chat_module(self) -> None:
        """★ 遮蔽探针：`invite()` 必须真的调到 `app.chat.send`。

        名字被顶层路由函数盖住时，`chat.send` 一次都不会被调到
        （异常还会被宽兜底吃掉，接口看起来「正常」、只是永远没有邀请消息）。
        所以判据必须是**桩被调到过**，而不是「没报错」。
        """
        async def ok_send(_sender, _code, body, _cmid, kind, payload):
            self.calls["chat_send"] += 1
            self.calls["kind"] = kind
            return chat.SendResult(
                message=chat.Message(1, HOST, body,
                                     datetime.datetime(2026, 10, 7, tzinfo=datetime.timezone.utc),
                                     kind, payload),
                deliver_to=TARGET)

        self._patch_chat_send(ok_send)
        self._new_room()
        exc, _ = self._invite()

        self.assertIsNone(exc, "invite() 不该抛异常：%r" % (exc,))
        self.assertEqual(
            self.calls["chat_send"], 1,
            "invite() 没有调到 app.chat.send —— 最可能是 routes/party.py 里又出现了"
            "和 `from app import chat` 同名的顶层定义（路由函数 / 变量），"
            "把那个 import 盖掉了。见 tests/test_no_module_shadowing_stdlib.py。")

    def test_chat_failure_degrades_instead_of_500(self) -> None:
        """私聊落库失败（复刻 030 迁移没跑）时：邀请仍成立，实时推送照发。

        出事的瞬间 `party.current().invite()` 已经改完内存状态、
        `party_invite` 推送还没发 —— 所以异常一旦冒出来，两边都拿不到有用信息：
        邀请在服务端算数、房主看到 500、被邀请人完全不知情。
        """
        async def failing_send(*_a, **_k):
            self.calls["chat_send"] += 1
            raise asyncpg.exceptions.CheckViolationError(
                'new row for relation "chat_messages" violates check constraint '
                '"chat_message_kind_allowed"')

        self._patch_chat_send(failing_send)
        self._new_room()
        exc, result = self._invite()

        self.assertIsNone(exc, "私聊失败不该把邀请带崩（会变成 HTTP 500）：%r" % (exc,))
        self.assertEqual(getattr(result, "state", {}).get("state"), "room",
                         "接口应当照常返回房间快照")
        self.assertEqual(len(self.hub.of_type("party_invite")), 1,
                         "即使私聊没落上，party_invite 实时推送也必须发出去")

    def test_invite_delivers_the_dm_message(self) -> None:
        """正常路径：一条 `kind='party_invite'` 的私聊要真的推给被邀请人。

        这是 10.07 第 10 条（以及用户真机反复提的「邀请后聊天里要有邀请消息」）。
        `deliver_to is None` 时不该推（与 routes/chat.py 的判据一致）。
        """
        async def ok_send(_sender, _code, body, _cmid, kind, payload):
            self.calls["chat_send"] += 1
            self.calls["kind"] = kind
            return chat.SendResult(
                message=chat.Message(7, HOST, body,
                                     datetime.datetime(2026, 10, 7, tzinfo=datetime.timezone.utc),
                                     kind, payload),
                deliver_to=TARGET)

        self._patch_chat_send(ok_send)
        self._new_room()
        exc, _ = self._invite()

        self.assertIsNone(exc)
        self.assertEqual(self.calls["kind"], chat.PARTY_INVITE_KIND,
                         "落库的 kind 必须是 chat.PARTY_INVITE_KIND")
        dms = self.hub.of_type("dm")
        self.assertEqual(len(dms), 1, "被邀请人应当收到一条 dm 推送")
        self.assertEqual(dms[0][0], TARGET, "dm 要推给被邀请人，不是邀请人自己")
        self.assertEqual(dms[0][1]["message"]["kind"], chat.PARTY_INVITE_KIND,
                         "dm 推送里的 kind 丢了的话，气泡与聊天记录都会是普通文本")


if __name__ == "__main__":
    unittest.main()
