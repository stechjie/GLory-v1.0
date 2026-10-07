"""chat_messages.kind 的取值集合，和 database/ 里的迁移是否对得上（Python stdlib，不连数据库）。

## 为什么要有这一条

`020_room_invite.sql` 给 `chat_messages` 加了一条 check 约束，把 `kind` 钉死在
`'text'` / `'room_invite'` 两态上。理由写在那份文件里：**「客户端不认识的新类型」
只能靠「先发迁移、再加客户端」引入**，免得服务端悄悄开始发一种老客户端渲染不了的记录。

约束的另一面是：**服务端每加一种新 kind，就必须同时补一个放宽约束的迁移。**
2026-10-07 就漏了这一次 —— 第 10 条给组队邀请加了 `kind='party_invite'`
（`app/chat.py` 的 `PARTY_INVITE_KIND`），迁移没跟上：

    insert ... kind='party_invite'  →  asyncpg CheckViolationError
                                    →  不在 `except chat.ChatRejected` 范围内
                                    →  冒到接口层  →  HTTP 500

真机表现（排位房间点「邀请好友」）：**「服务器出错了（HTTP 500），稍后再试」**。

## 这条用例能证明什么、不能证明什么

本机没有 PostgreSQL（线上库更不能碰），所以它是**静态**判据：把 `database/` 里的
迁移按编号在内存里跑一遍、算出 `chat_messages.kind` 最终允许哪些值，再和代码里
真正会写进 `kind` 的那些常量对比。

- ✅ 能保证：「代码加了新 kind，迁移忘了跟上」这类**整批失效**不会再静默通过。
- ❌ 证明不了：迁移 SQL 在真库上跑得通（那要靠 `pg_harness.py` + `GLORY_TEST_PG`）。

抓的就是这次的成因，不越界承诺。
"""

from __future__ import annotations

import ast
import pathlib
import re
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
BACKEND = REPO / "backend"
MIGRATIONS_DIR = REPO / "database"

# 「在 chat_messages 上给 kind 加一条 check」的两种写法。都只认语句级的语句，
# 不扫注释 —— 020 的文件头就在讲 kind，注释里的 `kind in (...)` 不能被当代码（踩过）。
_ADD_KIND_CHECK = re.compile(
    r"add\s+constraint\s+(\w+)\s+check\s*\(\s*kind\s+in\s*\(([^)]*)\)\s*\)",
    re.IGNORECASE | re.DOTALL,
)
_DROP_CONSTRAINT = re.compile(
    r"drop\s+constraint\s+(?:if\s+exists\s+)?(\w+)", re.IGNORECASE
)
_STRING_LITERAL = re.compile(r"'((?:[^']|'')*)'")


def _migration_paths() -> list[pathlib.Path]:
    return sorted(MIGRATIONS_DIR.glob("[0-9][0-9][0-9]_*.sql"))


def _statements(path: pathlib.Path) -> list[str]:
    """按 `;` 粗切语句。

    够用：这些文件里没有函数体里带分号的字符串，也没有 dollar-quoting 之外的花样，
    而且下面每一条都要求语句里出现 `chat_messages` 才会被看。
    """
    text = path.read_text(encoding="utf-8")
    # 去掉行注释，避免「注释里写了 kind in (...)」被当成真约束。
    text = re.sub(r"--[^\n]*", "", text)
    return text.split(";")


def _literals(group: str) -> set[str]:
    return {m.group(1).replace("''", "'") for m in _STRING_LITERAL.finditer(group)}


def _allowed_kinds_after_all_migrations() -> dict[str, set[str]]:
    """把迁移按编号跑一遍，返回「还活着的 kind 约束 → 它允许的取值」。

    多条约束同时存在时，PostgreSQL 的语义是**交集**（每一条都得满足）。
    这里如实保留成字典，让用例自己决定怎么合并；空字典 = 根本没有约束。
    """
    active: dict[str, set[str]] = {}
    for path in _migration_paths():
        for stmt in _statements(path):
            if "chat_messages" not in stmt:
                continue
            added = _ADD_KIND_CHECK.search(stmt)
            if added:
                active[added.group(1)] = _literals(added.group(2))
                continue
            dropped = _DROP_CONSTRAINT.search(stmt)
            if dropped:
                active.pop(dropped.group(1), None)
    return active


def _effective_allowed_kinds() -> set[str] | None:
    """跑完所有迁移之后，一个合法 kind 必须同时落在几条约束里 ⇒ 取交集。

    没有任何约束时返回 None（= 什么 kind 都允许）。
    """
    active = _allowed_kinds_after_all_migrations()
    if not active:
        return None
    sets = list(active.values())
    allowed = sets[0].copy()
    for s in sets[1:]:
        allowed &= s
    return allowed


def _chat_module_constants() -> dict[str, str]:
    """`app/chat.py` 里所有 `X_KIND = "..."` 模块级常量。

    这是私聊类型词的**唯一登记处**：其余模块一律 `chat.XXX_KIND` 引用，
    所以扫这一份就够，不必去各调用点刨字面量。
    """
    src = (BACKEND / "app" / "chat.py").read_text(encoding="utf-8")
    out: dict[str, str] = {}
    for node in ast.parse(src).body:
        if not isinstance(node, ast.Assign):
            continue
        value = node.value
        if not (isinstance(value, ast.Constant) and isinstance(value.value, str)):
            continue
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id.endswith("_KIND"):
                out[target.id] = value.value
    return out


def _send_default_kind() -> str | None:
    """`chat.send()` 的 `kind` 形参默认值 —— 不传 kind 时真正写进库的那个值。"""
    src = (BACKEND / "app" / "chat.py").read_text(encoding="utf-8")
    for node in ast.parse(src).body:
        if isinstance(node, ast.AsyncFunctionDef) and node.name == "send":
            positional = node.args.args
            defaults = node.args.defaults
            paired = zip(positional[len(positional) - len(defaults):], defaults)
            for arg, default in paired:
                if arg.arg == "kind" and isinstance(default, ast.Constant):
                    return str(default.value)
    return None


def _name_of(node: ast.expr) -> str | None:
    """取 `X` / `mod.X` 的末段名 —— 用来把 `chat.PARTY_INVITE_KIND` 看成
    `PARTY_INVITE_KIND`。其余形态返回 None（不猜）。"""
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return node.attr
    return None


def _resolve(node: ast.expr, consts: dict[str, str]) -> str | None:
    """把一个表达式还原成字符串字面量；还原不出来返回 None。"""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    name = _name_of(node)
    return consts.get(name) if name else None


def _allowed_kinds_whitelist() -> tuple[str, set[str], set[str]]:
    """`app/routes/chat.py` 里那份 `_ALLOWED_KINDS`（客户端能送进来的 kind）。

    返回 `(常量名, 解析出的取值, 解析不出来的元素名)` —— 第二个是判据，
    第三个是为了「解析不出来」时能报出**是哪一个**，而不是安静地少收一条。
    """
    src = (BACKEND / "app" / "routes" / "chat.py").read_text(encoding="utf-8")
    consts = _chat_module_constants()
    for node in ast.parse(src).body:
        if not isinstance(node, ast.Assign):
            continue
        names = [t.id for t in node.targets if isinstance(t, ast.Name)]
        if not any(n.endswith("_ALLOWED_KINDS") for n in names):
            continue
        if not isinstance(node.value, (ast.Tuple, ast.List, ast.Set)):
            continue
        ok, unresolved = set(), set()
        for element in node.value.elts:
            value = _resolve(element, consts)
            if value is None:
                unresolved.add(ast.unparse(element))
            else:
                ok.add(value)
        return names[0], ok, unresolved
    return "", set(), set()


def _kinds_that_can_reach_chat_messages() -> set[str]:
    """服务端真会写进 `chat_messages.kind` 的那一组值。

    三个来源合起来才是完整的：
      1. `app/chat.py` 的 `X_KIND` 常量（room_invite / party_invite）；
      2. `chat.send()` 的 `kind` 默认值（不传就是 text）；
      3. `routes/chat.py` 的 `_ALLOWED_KINDS`（外部能请求的类型，含 "text"）。
    """
    kinds = set(_chat_module_constants().values())
    default = _send_default_kind()
    if default is not None:
        kinds.add(default)
    kinds |= _allowed_kinds_whitelist()[1]
    return kinds


class ChatKindSchemaTest(unittest.TestCase):
    def test_kind_check_constraint_still_exists(self) -> None:
        """约束必须还在。

        判据本身也要有判别力：把约束整个删掉，「所有 kind 都被允许」会让主判据
        变成永真 —— 那是把问题抹掉，不是修好。所以先钉住它还在。
        """
        active = _allowed_kinds_after_all_migrations()
        self.assertTrue(
            active,
            "database/ 里已经没有 chat_messages.kind 的 check 约束了。"
            "删约束不等于修好：它会让 test_every_kind_… 永远通过。",
        )

    def test_020_still_allows_only_the_two_original_kinds(self) -> None:
        """`020_room_invite.sql` 是本约束的**出处**，编号只增不改 ⇒ 只该有原来那两态。

        这条防的是「绕过迁移规范、回头改老文件」：那样改了不报错，
        只是别的机器与你的库结构悄悄不一致（见 database/README.md）。
        """
        allowed = _effective_allowed_kinds()
        self.assertIsNotNone(allowed)
        # 只看 020 自己那一版：临时把 021 之后的都排除掉重算一次。
        # ★ 只比编号前三位 —— 拿整个文件名跟 "020" 比，因为是前缀关系必然为真，
        #   会把 020 自己也滤掉（本用例第一版就栽在这，报出 None != {text, room_invite}）。
        only_020 = {}
        for path in _migration_paths():
            if path.name[:3] > "020":
                continue
            for stmt in _statements(path):
                if "chat_messages" not in stmt:
                    continue
                added = _ADD_KIND_CHECK.search(stmt)
                if added:
                    only_020[added.group(1)] = _literals(added.group(2))
                else:
                    dropped = _DROP_CONSTRAINT.search(stmt)
                    if dropped:
                        only_020.pop(dropped.group(1), None)
        merged: set[str] | None = None
        for values in only_020.values():
            merged = values.copy() if merged is None else merged & values
        self.assertEqual(
            merged, {"text", "room_invite"},
            "020_room_invite.sql 应当只允许 text / room_invite —— "
            "要加新 kind 请开新编号文件，别回去改它。",
        )

    def test_every_kind_reaching_chat_messages_is_allowed_by_schema(self) -> None:
        """★ 主判据：代码会写的每个 kind，迁移跑完之后都必须被允许。

        这条红了 = 服务端一发这种消息就会被数据库拒绝（500），
        和 2026-10-07 的「排位邀请好友 500」是同一回事。
        """
        allowed = _effective_allowed_kinds()
        self.assertIsNotNone(
            allowed, "找不到约束 ⇒ 本用例失去意义，先修好上面那条。")
        used = _kinds_that_can_reach_chat_messages()
        missing = sorted(used - allowed)
        self.assertEqual(
            missing, [],
            "这些 kind 会被写进 chat_messages，但 database/ 跑完之后并不允许：%s\n"
            "  允许的是：%s\n"
            "  ⇒ 请加一个新编号的迁移（照 database/030_chat_party_invite.sql 的样子）"
            "放宽 chat_message_kind_allowed，再把服务端一起发上去。" % (
                missing, sorted(allowed)),
        )

    def test_party_invite_kind_is_really_passed_to_chat_send(self) -> None:
        """自检：`PARTY_INVITE_KIND` 必须真的被传进某个 `chat.send(...)`。

        上面那条主判据是从**常量表**反推的。万一哪天 `PARTY_INVITE_KIND` 变成了
        没人用的死常量，主判据就退化成一条空转 —— 这条把它钉回来：
        常量存在**且**真的出现在调用实参里，才算数。
        """
        hits = []
        for path in sorted((BACKEND / "app").rglob("*.py")):
            for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
                if not isinstance(node, ast.Call):
                    continue
                if _name_of(node.func) != "send":
                    continue
                if "PARTY_INVITE_KIND" in ast.unparse(node):
                    hits.append("%s:%d" % (path.relative_to(BACKEND), node.lineno))
        self.assertTrue(
            hits,
            "没有任何 chat.send(...) 调用带上 chat.PARTY_INVITE_KIND —— "
            "组队邀请的第 10 条落库链路断了（或者主判据变成了空转）。",
        )

    def test_allowed_kinds_whitelist_is_fully_resolvable(self) -> None:
        """`_ALLOWED_KINDS` 里不许有解析不出来的元素。

        解析不出来就会在本用例里**安静地少收一条**，主判据跟着漏判。
        宁可红在这里，也不要让判据有个看不见的缺口。
        """
        name, resolved, unresolved = _allowed_kinds_whitelist()
        self.assertTrue(name, "routes/chat.py 里找不到 _ALLOWED_KINDS")
        self.assertEqual(unresolved, set(),
                         "%s 里有解析不出的元素：%s" % (name, sorted(unresolved)))
        self.assertTrue(resolved, "%s 解析出来是空的" % name)


    def test_widening_migration_is_rerunnable(self) -> None:
        """**改动**已有 kind 约束的那个迁移必须自己先把旧约束摘掉（= 可重复执行）。

        `database/README.md` 的跑法是「Supabase Dashboard → SQL Editor 手工执行」。
        手工执行就可能**贴两遍**。只写 `add constraint` 的话，第二遍会报
        `constraint "chat_message_kind_allowed" already exists` 而**整段中断** ——
        后面那条 `create index` 一起不执行，而人往往只看到一行红字就以为全挂了。

        判据（★ 只盯「改」，不盯「出处」）：
          · 020 是这条约束的**出处** —— 它那时没有旧约束可摘，不受本判据约束
            （而且它已经发出去、编号只增不改，不该回头要求它幂等）；
          · 后续任何一次**改**同一条约束的迁移，drop 必须排在 add **之前**。

        一次「改」都不存在时也判红 —— 代码用了新 kind 却从没动过约束，
        本身就是要出事（上一个用例的主判据也在说同一件事，两条互为佐证）。
        """
        active: set[str] = set()
        widening: tuple[str, str, list[int], list[int]] | None = None
        for path in _migration_paths():
            adds: dict[str, list[int]] = {}
            drops: dict[str, list[int]] = {}
            for index, stmt in enumerate(_statements(path)):
                if "chat_messages" not in stmt:
                    continue
                added = _ADD_KIND_CHECK.search(stmt)
                if added:
                    adds.setdefault(added.group(1), []).append(index)
                    continue
                dropped = _DROP_CONSTRAINT.search(stmt)
                if dropped:
                    drops.setdefault(dropped.group(1), []).append(index)
            # 「改」= 本次 add 的约束名在**更早的迁移**里就已经装上过。
            for conname in adds:
                if conname in active:
                    widening = (path.name, conname, adds[conname], drops.get(conname, []))
            # ★ 两遍扫描：本文件全部语句收完再判顺序。030 里 drop 在第 0 句、
            #   add 在第 1 句 —— 一边扫一边判的话，处理 drop 时 add 还没收进来，
            #   会误报「没摘旧约束」。
            for conname in drops:
                active.discard(conname)
            for conname in adds:
                active.add(conname)

        self.assertIsNotNone(
            widening,
            "没有任何迁移**改**过 chat_messages.kind 的约束。\n"
            "  ⇒ 代码里用的 kind 已经在约束之外了（见上一个用例），"
            "请加一个新编号文件，写成 `drop constraint if exists …;` + `add constraint …;`。",
        )
        name, conname, add_at, drop_at = widening
        first_add = min(add_at)
        self.assertTrue(
            any(d < first_add for d in drop_at),
            "%s 里 `add constraint %s` 之前没有 `drop constraint %s`。\n"
            "  ⇒ 这个文件手工跑第二遍会报 already exists 并整段中断。"
            "请写成 `drop constraint if exists …;` 再 `add constraint …;`（幂等）。" % (
                name, conname, conname),
        )


    def test_chat_failure_cannot_take_the_invite_down(self) -> None:
        """`routes/party.py` 的 `invite()` 里，`chat.send` 外面必须有一层**宽于 ChatRejected** 的兜底。

        上一个用例管的是「约束和代码对不上」，这条管事故的**另一半**：
        就算将来又冒出一种没预料到的写库错误，也不该把「邀请」这件事整条打挂。

        为什么非要有这条：出事的瞬间 `party.current().invite()` **已经改完内存状态**、
        而下面那条 `party_invite` 实时推送**还没发**。于是异常一冒出来，状态最坏 ——
        邀请在服务端算数、房主看到 500、被邀请人什么都没收到，两边都拿不到有用的信息。

        判定用 AST 而不是字符串：在 `invite()` 里找所有 try，凡 body 里调了 `chat.send`
        的，它的 handlers 中必须有一条类型**不是** ChatRejected（`except Exception` /
        `except BaseException` / 裸 `except`）。
        """
        src = (BACKEND / "app" / "routes" / "party.py").read_text(encoding="utf-8")
        fn = None
        for node in ast.walk(ast.parse(src)):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == "invite":
                fn = node
                break
        self.assertIsNotNone(fn, "routes/party.py 里找不到 invite()")

        guarded, tries = 0, 0
        for node in ast.walk(fn):
            if not isinstance(node, ast.Try):
                continue
            calls_send = any(
                isinstance(inner, ast.Call) and _name_of(inner.func) == "send"
                for inner in ast.walk(ast.Module(body=node.body, type_ignores=[]))
            )
            if not calls_send:
                continue
            tries += 1
            for handler in node.handlers:
                if handler.type is None:  # 裸 except —— 更宽，算数
                    guarded += 1
                    break
                name = _name_of(handler.type)
                if name in ("Exception", "BaseException"):
                    guarded += 1
                    break
        self.assertGreaterEqual(
            tries, 1, "invite() 里找不到包住 chat.send 的 try —— 结构变了，请复核这条判据。")
        self.assertGreaterEqual(
            guarded, 1,
            "包住 chat.send 的那个 try 只有 except chat.ChatRejected。\n"
            "  ⇒ 任何一种没预料到的写库错误（CheckViolationError、连接断、约束变更）都会冒成 "
            "HTTP 500，而且此时邀请已生效、实时推送还没发 —— 房主报错、被邀请人收不到，"
            "看起来就是「拉不了好友」。请保留一层宽兜底（记日志 + 继续走实时推送）。",
        )


if __name__ == "__main__":
    unittest.main()
