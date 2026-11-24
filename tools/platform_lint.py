#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""跨平台陷阱门卫（AGENTS.md「跨平台改动规则」第 3、6 条的机械版）。

背景：同一份 GDScript 跑在 Android、iOS、Windows/Steam 和无界面战斗服务器上。
2026-11-18 给 iOS 加 Apple 登录时，SignInBridge.gd 把插件方法判断改成 bridge.has_method()，
安卓 JNISingleton 对它永远返回 false，Google 登录按钮消失；门禁替身和 iOS 真机都没发现。
这个脚本把那条规则变成提交前自动检查，人和 AI 代理都绕不过去。

规则 1（硬性，命中即失败）
    在「原生插件相关目录」里直接写 `.has_method(` ——
    一律改用 scripts/account/NativeBridge.gd 的 NativeBridge.supports(bridge, "方法名")。
    真需要直接用的（已确认只在 iOS/桌面分支执行），在同一行末尾加注释
        # platform-ok: <为什么其他平台不受影响>
    就放行。注释必须写原因，空的不算。

规则 2（提示，不失败）
    列出改动文件里所有平台分叉点：OS.get_name() / OS.has_feature( / Engine.has_singleton( /
    Engine.get_singleton( / DisplayServer.get_name()。
    这是提醒改动者（人或 AI）回去对照 AGENTS.md 开头的「平台影响表」逐个平台过一遍。

用法
    python tools/platform_lint.py                 检查整个受控目录
    python tools/platform_lint.py --staged        只检查 git 暂存区里的 .gd（pre-commit 用）
    python tools/platform_lint.py a.gd b.gd       检查指定文件

退出码：0 通过；1 规则 1 命中；2 调用错误。
不依赖第三方库，Python 3.8+。读写都显式 UTF-8，不碰 BOM。
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Windows 控制台默认 gbk，打印中文/符号会 UnicodeEncodeError；统一用 UTF-8 并对打不出的字符降级。
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

# 规则 1 生效范围：会被原生插件桥接的脚本。踩到新坑就往这里加。
WATCHED_DIRS = (
    "scripts/account",
)
WATCHED_FILES = (
    "scripts/autoload/AccountManager.gd",
    "scripts/autoload/VoiceService.gd",
    "scripts/autoload/VoiceClipService.gd",
)
# NativeBridge 自己必须调用 has_method()，是唯一的例外。
EXEMPT_FILES = (
    "scripts/account/NativeBridge.gd",
)

HAS_METHOD = re.compile(r"\.has_method\s*\(")
# 这一种写法是在探测「是不是安卓 JNISingleton」，本身就是正确做法。
HAS_JAVA_PROBE = re.compile(r"""\.has_method\s*\(\s*["']has_java_method["']\s*\)""")
PLATFORM_OK = re.compile(r"#\s*platform-ok\s*:\s*\S")
COMMENT_ONLY = re.compile(r"^\s*#")

BRANCH_POINTS = (
    ("OS.get_name(", "按平台分叉"),
    ("OS.has_feature(", "按导出特性分叉"),
    ("Engine.has_singleton(", "探测原生插件"),
    ("Engine.get_singleton(", "取原生插件"),
    ("DisplayServer.get_name(", "探测无界面/服务器"),
)


def rel(p: Path) -> str:
    try:
        return p.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return p.as_posix()


def is_watched(path: Path) -> bool:
    r = rel(path)
    if r in EXEMPT_FILES:
        return False
    if r in WATCHED_FILES:
        return True
    return any(r.startswith(d.rstrip("/") + "/") for d in WATCHED_DIRS)


def staged_gd_files() -> list[Path]:
    out = subprocess.run(
        ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"],
        cwd=ROOT, check=True, capture_output=True,
    ).stdout
    names = [n for n in out.decode("utf-8", "surrogateescape").split("\0") if n]
    return [ROOT / n for n in names if n.endswith(".gd")]


def all_watched_files() -> list[Path]:
    files: list[Path] = []
    for d in WATCHED_DIRS:
        files.extend(sorted((ROOT / d).rglob("*.gd")))
    for f in WATCHED_FILES:
        p = ROOT / f
        if p.exists():
            files.append(p)
    return [f for f in files if is_watched(f)]


def read_lines(path: Path) -> list[str]:
    data = path.read_bytes()
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    return data.decode("utf-8", "replace").splitlines()


def check_file(path: Path, *, enforce_rule1: bool) -> tuple[list[str], list[str]]:
    """返回 (规则1命中, 规则2提示)。"""
    errors: list[str] = []
    notes: list[str] = []
    r = rel(path)
    # 以反斜杠续行的多行语句当成一条看：platform-ok 注释只能写在最后一行。
    pending = ""
    pending_start = 0
    for lineno, raw in enumerate(read_lines(path), 1):
        if pending:
            line = pending + " " + raw.strip()
        else:
            line = raw
            pending_start = lineno
        if raw.rstrip().endswith("\\"):
            pending = line.rstrip()[:-1]
            continue
        pending = ""
        lineno = pending_start
        if COMMENT_ONLY.match(line):
            continue
        code = line.split("#", 1)[0]
        if enforce_rule1 and HAS_METHOD.search(code) and not HAS_JAVA_PROBE.search(code):
            if not PLATFORM_OK.search(line):
                errors.append(
                    f"{r}:{lineno}: 直接写了 .has_method()。安卓 JNISingleton 对它永远返回 false。\n"
                    f"    改成 NativeBridge.supports(bridge, \"方法名\")；"
                    f"确认只在 iOS/桌面分支执行的，行尾加  # platform-ok: 原因\n"
                    f"    > {line.strip()}"
                )
        for needle, why in BRANCH_POINTS:
            if needle in code:
                notes.append(f"{r}:{lineno}: {why}  > {line.strip()}")
                break
    return errors, notes


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("files", nargs="*", help="要检查的 .gd 文件；不给则看 --staged 或整个受控目录")
    ap.add_argument("--staged", action="store_true", help="只检查 git 暂存区里的 .gd 文件")
    ap.add_argument("--quiet-notes", action="store_true", help="不打印规则 2 的分叉点提示")
    args = ap.parse_args(argv)

    if args.files:
        targets = [Path(f) if os.path.isabs(f) else ROOT / f for f in args.files]
    elif args.staged:
        try:
            targets = staged_gd_files()
        except (subprocess.CalledProcessError, FileNotFoundError) as exc:
            print(f"platform_lint: 读不到 git 暂存区：{exc}", file=sys.stderr)
            return 2
    else:
        targets = all_watched_files()

    targets = [t for t in targets if t.exists() and t.suffix == ".gd"]
    if not targets:
        print("platform_lint: 没有要检查的 .gd 文件，通过。")
        return 0

    all_errors: list[str] = []
    all_notes: list[str] = []
    for t in targets:
        errs, notes = check_file(t, enforce_rule1=is_watched(t))
        all_errors.extend(errs)
        all_notes.extend(notes)

    if all_notes and not args.quiet_notes:
        print("platform_lint: 以下是本次涉及文件里的平台分叉点，请对照 AGENTS.md 开头的「平台影响表」"
              "逐个平台确认 Android / iOS / Windows / 服务器 各走哪条路：")
        for n in all_notes:
            print("  " + n)
        print()

    if all_errors:
        print("platform_lint: [FAIL] 跨平台陷阱（AGENTS.md 跨平台改动规则 第 3 条）：")
        for e in all_errors:
            print("  " + e)
        print(f"\n共 {len(all_errors)} 处。修掉或加 platform-ok 注释后再提交。")
        return 1

    print(f"platform_lint: [OK] {len(targets)} 个文件通过。")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
