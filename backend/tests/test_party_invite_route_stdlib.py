"""组队邀请路由检查（脱离可选后端环境，只用 stdlib + 桩）。

覆盖 10.07i 第 9(2) 条返工：
  「再次修复后，发现邀请后没有邀请消息，要改成和自定义房间一样，
   邀请后要在聊天里收到对方的邀请消息。」

真根因：`routes/party.invite()` 里 `chat.send(...)` **只落库**，推送是调用方的事
（见 `routes/chat.py` 的 send_message：它自己在 send 之后 `send_to_player` 一条
`{"t":"dm",...}`）。上一版把返回值丢掉了 ⇒ 消息进了库却从没推给收件人。

本机没装 fastapi / pydantic（`routes/party.py` 顶层 import 它们），所以这里
**用 AST 解析真源码**来做判据 —— 不是子串 contains，而是「这个函数体里必须
存在这样一条语句」，能识破改名、条件包裹、参数写错：

  1. `chat.send(...)` 的返回值必须被接住（赋给某个名字）；
  2. 必须存在 `send_to_player(<那个名字>.deliver_to, {... "t": "dm" ...})`；
  3. 那条 dm 的 message 里要带 kind 与 payload；
  4. `party_invite`（驱动气泡）那条推送仍在。

★ 判据构造的坑（本文件已踩过）：AST 里字典的键/标量值都是 `ast.Constant`
**节点**，`{"t": "dm"}` 取出来是 `Constant(value='dm')` 而不是 `'dm'`。
必须用 `_lit()` 拆成真值再比，否则 `kv.get("t") == "dm"` 恒假 ⇒ 三条断言
全部假红（不是假绿，但同样让人以为代码没改对）。

运行：python -m unittest tests.test_party_invite_route_stdlib
"""

import ast
import unittest
from pathlib import Path

ROUTE = Path(__file__).resolve().parents[1] / "app" / "routes" / "party.py"


def _invite_fn():
    tree = ast.parse(ROUTE.read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if isinstance(node, ast.AsyncFunctionDef) and node.name == "invite":
            return node
    raise AssertionError("找不到 async def invite")


def _callee_name(call: ast.Call) -> str:
    f = call.func
    if isinstance(f, ast.Attribute):
        base = f.value
        if isinstance(base, ast.Name):
            return base.id + "." + f.attr
        return f.attr
    if isinstance(f, ast.Name):
        return f.id
    return ""


def _is_callee(call: ast.Call, name: str) -> bool:
    """链式调用（`realtime.hub().send_to_player`）只能拿到末段名字，
    所以按末段相等判 —— 只要不是别的同名函数即可。"""
    got = _callee_name(call)
    return got == name or got.split(".")[-1] == name


def _lit(node):
    """把 AST 标量节点拆成真值；非字面量返回 `_NONLIT` 哨兵。"""
    if isinstance(node, ast.Constant):
        return node.value
    return _NONLIT


class _NonLit:
    def __repr__(self):
        return "<non-literal>"

    def __eq__(self, other):
        return isinstance(other, _NonLit)


_NONLIT = _NonLit()


def _dict_items(dnode: ast.Dict) -> dict:
    """键拆字面量、值保留 AST —— 既要按键取项，又要在后面判嵌套结构。"""
    out = {}
    for k, v in zip(dnode.keys, dnode.values):
        kv = _lit(k)
        if kv is _NONLIT:
            continue
        out[kv] = v
    return out


def _val(items: dict, key: str):
    """取「字面量值」—— `{"t": "dm"}` 里 `items["t"]` 是 Constant 节点，
    直接跟 `"dm"` 比会恒假（本文件一开始就栽在这）。"""
    if key not in items:
        return _NONLIT
    return _lit(items[key])


def _calls(node: ast.AST):
    return [n for n in ast.walk(node) if isinstance(n, ast.Call)]


class PartyInviteRouteTests(unittest.TestCase):
    def setUp(self):
        self.fn = _invite_fn()
        self.calls = _calls(self.fn)

    def test_send_to_player_calls_are_visible(self):
        """元判据：本函数里确实存在 send_to_player 调用（否则后面几条是空跑）。"""
        found = [c for c in self.calls if _is_callee(c, "send_to_player")]
        self.assertGreaterEqual(
            len(found), 2,
            "invite 里应至少有两条 send_to_player（dm 给收件人 + party_invite 气泡）")

    def test_chat_send_result_is_kept(self):
        """chat.send 的返回值必须被接住 —— 丢掉就没法按 deliver_to 推送。

        ★ 判据要能识破 `_ = await chat.send(...)` 这种「形式上赋值、实质丢弃」
        （变异 B1 实测：只查 `isinstance(t, ast.Name)` 会被 `_` 蒙过去 ⇒ 假绿）。
        所以：目标名不能是 `_` 这类占位符，且**必须真的被用来读 `.deliver_to`**。
        """
        kept = set()
        for node in ast.walk(self.fn):
            if isinstance(node, ast.Assign) and isinstance(node.value, ast.Await):
                inner = node.value.value
                if isinstance(inner, ast.Call) and _is_callee(inner, "send"):
                    for t in node.targets:
                        if isinstance(t, ast.Name) and t.id != "_":
                            kept.add(t.id)
        self.assertTrue(
            kept,
            "chat.send(...) 的返回值必须赋给一个**真名字**（`_` 算丢弃）")

        # 这个名字必须被读 `.deliver_to`，否则「接住」没有意义
        used = False
        for node in ast.walk(self.fn):
            if isinstance(node, ast.Attribute) and node.attr == "deliver_to":
                base = node.value
                if isinstance(base, ast.Name) and base.id in kept:
                    used = True
        self.assertTrue(
            used,
            "接住 chat.send 的返回值后必须读它的 .deliver_to（否则仍是死值）")

    def _push_dicts(self):
        """收齐本函数内所有 send_to_player 的字面量字典实参（键拆字面量，值留 AST）。"""
        out = []
        for call in self.calls:
            if not _is_callee(call, "send_to_player"):
                continue
            for arg in call.args:
                if isinstance(arg, ast.Dict):
                    out.append(_dict_items(arg))
        return out

    def test_dm_push_present(self):
        """必须真的推一条 dm 给收件人。"""
        wanted = [d for d in self._push_dicts() if _val(d, "t") == "dm"]
        self.assertTrue(wanted, "邀请必须推一条 {'t': 'dm', ...} 给收件人")
        d = wanted[0]
        self.assertIn("from", d, "dm 推送要带 from（发送人好友码）")
        self.assertIn("message", d, "dm 推送要带 message")

    def test_dm_message_carries_kind_and_payload(self):
        """dm 里的 message 必须带 kind 与 payload —— kind 决定收件人渲染成气泡。"""
        msg_dict = None
        for d in self._push_dicts():
            if _val(d, "t") == "dm" and isinstance(d.get("message"), ast.Dict):
                msg_dict = _dict_items(d["message"])
        self.assertIsNotNone(msg_dict, "找不到 dm 的 message 字典")
        self.assertIn("kind", msg_dict, "message 必须带 kind（否则渲染成普通文本）")
        self.assertIn("payload", msg_dict, "message 必须带 payload（收件人靠它加入队伍）")

    def test_deliver_guard_matches_chat_route(self):
        """推送要按 deliver_to 判 —— 与 routes/chat.py 同口径（None = 不推）。"""
        has_guard = False
        for node in ast.walk(self.fn):
            if not isinstance(node, ast.Compare):
                continue
            src = ast.unparse(node)
            if ".deliver_to" in src:
                has_guard = True
        self.assertTrue(has_guard, "必须按 deliver_to is not None 判是否推送")

    def test_party_invite_bubble_push_still_sent(self):
        """驱动气泡的 party_invite 推送不能被这次改动挤掉。"""
        found = [d for d in self._push_dicts() if _val(d, "t") == "party_invite"]
        self.assertTrue(found, "party_invite 推送必须保留（气泡靠它）")
        d = found[0]
        for key in ("party_id", "mode", "host_name", "host_code"):
            self.assertIn(key, d, "party_invite 气泡推送缺字段 %s" % key)

    def test_send_uses_party_invite_kind(self):
        """落库与推送都要用 PARTY_INVITE_KIND —— kind 对不上则收不到气泡。"""
        seen = False
        for call in self.calls:
            if _is_callee(call, "send") and "PARTY_INVITE_KIND" in ast.unparse(call):
                seen = True
        self.assertTrue(seen, "chat.send 必须传 chat.PARTY_INVITE_KIND")

    def test_party_invite_text_is_the_required_copy(self):
        """文案必须是「快来加入队伍，一起战斗吧」（需求逐字）。"""
        text = ROUTE.read_text(encoding="utf-8")
        self.assertIn("快来加入队伍，一起战斗吧", text)


if __name__ == "__main__":
    unittest.main()
