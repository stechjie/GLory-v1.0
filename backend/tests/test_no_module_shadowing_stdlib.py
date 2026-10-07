"""模块顶层的定义不许盖掉 `import` 进来的模块名（Python stdlib，不连数据库）。

## 为什么要有这一条

Python 的模块顶层只有**一个**命名空间。`from app import chat` 之后再写一个
`async def chat(...)`，那个 import **就被整个盖掉了** —— 不报错、不警告、
静态检查也未必看得见，只在**调用到的那一刻**炸：

    2026-10-07 真事（排位房间里点「邀请好友」→「服务器出错了（HTTP 500）」）：
    app/routes/party.py 顶部有 `from app import chat`（私聊模块，invite() 要拿它
    落一条邀请消息），文件底部又有一个 `@router.post("/chat")` 的路由函数
    也叫 `chat`。于是 invite() 里的 `chat.send(...)` 拿到的是**那个路由函数**：

        AttributeError: 'function' object has no attribute 'send'

    它不在 `except chat.ChatRejected` 里 ⇒ 冒到接口层 = 500。而 `except` 那行的
    `chat.ChatRejected` 同样是 AttributeError —— 连兜底都一起坏了。

这个坑足够隐蔽（两处相隔 400 多行、都在同一个文件里、彼此看起来都合理），
所以不再靠人眼，直接钉成判据。

## 判据范围

`backend/app/**` 与 `backend/tests/**` 的所有 .py：
**顶层**（含 `if` / `try` 里那种仍然绑定到模块命名空间的位置）定义的
函数 / 类 / 赋值目标，名字不得与**顶层 import 绑定出来的名字**相同。

★ 只比模块级绑定，不管函数内的局部变量 —— 局部名有自己的作用域，
  盖住外层名字是正常的（例如到处都在用的 `chat = some_local`）。
"""

from __future__ import annotations

import ast
import pathlib
import unittest

BACKEND = pathlib.Path(__file__).resolve().parents[1]
SCAN_ROOTS = ("app", "tests")


def _top_level_imports(tree: ast.Module) -> dict[str, int]:
    """顶层 `import x` / `from m import x` 绑定出来的名字 → 行号。

    会走进 `if` / `try` 的 body —— 那两种写法里的 import 一样绑定在模块命名空间上
    （`if TYPE_CHECKING:` 那种也一样，虽然运行时不绑定，但**语义上**依然是同名遮盖，
    一并算作问题）。
    """
    found: dict[str, int] = {}

    def walk(body: list[ast.stmt]) -> None:
        for node in body:
            if isinstance(node, ast.Import):
                for alias in node.names:
                    # `import a.b.c` 绑定的是顶层包名 a（没有 as 时）
                    found.setdefault(alias.asname or alias.name.split(".")[0], node.lineno)
            elif isinstance(node, ast.ImportFrom):
                for alias in node.names:
                    found.setdefault(alias.asname or alias.name, node.lineno)
            elif isinstance(node, (ast.If, ast.Try)):
                walk(node.body)
                walk(node.orelse)
                # `handlers` 只有 Try 有（If 上没有这个属性 —— 第一版就在这栽了）
                for handler in getattr(node, "handlers", []):
                    walk(handler.body)
                walk(getattr(node, "finalbody", []))

    walk(tree.body)
    return found


def _top_level_definitions(tree: ast.Module) -> list[tuple[str, int]]:
    out: list[tuple[str, int]] = []
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            out.append((node.name, node.lineno))
        elif isinstance(node, ast.Assign):
            out.extend((t.id, node.lineno) for t in node.targets if isinstance(t, ast.Name))
    return out


def shadowed_names(source: str) -> list[tuple[str, int, int]]:
    """返回 [(被盖的名字, import 行号, 定义行号)]。判断逻辑的唯一实现。"""
    tree = ast.parse(source)
    imported = _top_level_imports(tree)
    return [(name, imported[name], line)
            for name, line in _top_level_definitions(tree) if name in imported]


class NoModuleShadowingTest(unittest.TestCase):
    def test_scanner_catches_a_real_shadowing(self) -> None:
        """自检：拿这次事故的**最小复现**喂给扫描器，它必须报出来。

        没有这一条，主判据可能因为「路径写错 / 解析没生效」而恒绿 ——
        那正是它要防的那种假绿。
        """
        sample = (
            "from __future__ import annotations\n"
            "import uuid\n"
            "from app import chat, db\n"
            "\n"
            "async def send_chat(body):\n"
            "    return await chat.send(body)\n"
            "\n"
            "async def chat(body):\n"          # ← 这就是事故的形态
            "    return body\n"
        )
        self.assertEqual(shadowed_names(sample), [("chat", 3, 8)])

        # 反向对照：把函数改个名，同一个样本必须变干净。
        self.assertEqual(shadowed_names(sample.replace("async def chat(body)", "async def send2(body)")), [])

    def test_scanner_ignores_function_locals(self) -> None:
        """函数**内部**的同名局部变量不算 —— 那是正常作用域，不是遮盖。

        否则这条门禁会在全仓到处误报（`chat = ...` 这种局部写法很常见）。
        """
        sample = (
            "from app import chat\n"
            "\n"
            "def use():\n"
            "    chat = 1\n"
            "    return chat\n"
        )
        self.assertEqual(shadowed_names(sample), [])

    def test_scanned_enough_files(self) -> None:
        """扫描面得是真的（路径/glob 坏掉时不要安静通过）。"""
        files = [p for root in SCAN_ROOTS for p in (BACKEND / root).rglob("*.py")]
        self.assertGreater(len(files), 20,
                           "只扫到 %d 个 .py —— 扫描路径可能写错了" % len(files))

    def test_no_module_shadows_an_imported_name(self) -> None:
        """★ 主判据：backend/app 与 backend/tests 里一处都不许有。"""
        hits: list[str] = []
        for root in SCAN_ROOTS:
            for path in sorted((BACKEND / root).rglob("*.py")):
                for name, import_line, def_line in shadowed_names(
                        path.read_text(encoding="utf-8")):
                    hits.append("%s:%d 定义了 %r，把 L%d 的 import 盖掉了"
                                % (path.relative_to(BACKEND), def_line, name, import_line))
        self.assertEqual(
            hits, [],
            "顶层定义和 import 进来的模块同名 —— import 会被静默盖掉，"
            "直到有人调用它的属性才炸成 AttributeError（多半是 HTTP 500）：\n  "
            + "\n  ".join(hits)
            + "\n  ⇒ 给其中一个改名。路由函数改名不影响 HTTP 路径"
              "（路径由装饰器决定），先例：routes/party.py 的 send_chat、"
              "routes/chat.py 的 send_message。",
        )


if __name__ == "__main__":
    unittest.main()
