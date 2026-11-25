#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""UTF-8 BOM 门卫。

背景：project.godot 里曾出现一行 `"ï»¿config_version"=5` —— 某个脚本带着 UTF-8 BOM 改写了它。
Godot 把 BOM 当成键名的一部分，这次只是多了个没人读的坏键；下次落在 .tscn / .tres / .cfg 上
就是「第 1 行解析失败」。PowerShell 5.1 的 `-Encoding utf8` 默认带 BOM，是最常见的来源。

规则：
    以下类型的文件不许带 BOM：.godot .tscn .tres .cfg .gd .gdshader .json .import .md .py .sh
    例外：.ps1 不检查 —— PowerShell 5.1 反而需要 BOM 才能正确读出含中文的脚本
         （tools/run_check.ps1 顶部有说明）。

用法：
    python tools/bom_lint.py --staged        只检查 git 暂存区（pre-commit 用）
    python tools/bom_lint.py a.tscn b.gd     检查指定文件
    python tools/bom_lint.py --fix <files>   顺手把 BOM 去掉

退出码：0 通过；1 有文件带 BOM；2 调用错误。
"""

from __future__ import annotations

import argparse
import os
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
CHECK_EXT = {".godot", ".tscn", ".tres", ".cfg", ".gd", ".gdshader", ".json", ".import", ".md", ".py", ".sh"}
BOM = b"\xef\xbb\xbf"


def staged_files() -> list[Path]:
    out = subprocess.run(
        ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"],
        cwd=ROOT, check=True, capture_output=True,
    ).stdout
    return [ROOT / n for n in out.decode("utf-8", "surrogateescape").split("\0") if n]


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("files", nargs="*")
    ap.add_argument("--staged", action="store_true")
    ap.add_argument("--fix", action="store_true", help="去掉命中文件的 BOM")
    args = ap.parse_args(argv)

    if args.files:
        targets = [Path(f) if os.path.isabs(f) else ROOT / f for f in args.files]
    elif args.staged:
        try:
            targets = staged_files()
        except (subprocess.CalledProcessError, FileNotFoundError) as exc:
            print(f"bom_lint: 读不到 git 暂存区：{exc}", file=sys.stderr)
            return 2
    else:
        ap.print_usage()
        return 2

    hits: list[Path] = []
    for t in targets:
        if not t.is_file() or t.suffix.lower() not in CHECK_EXT:
            continue
        with t.open("rb") as fh:
            if fh.read(3) == BOM:
                hits.append(t)

    if not hits:
        print("bom_lint: [OK] 没有带 BOM 的文件。")
        return 0

    for h in hits:
        rel = h.relative_to(ROOT).as_posix() if h.is_relative_to(ROOT) else str(h)
        if args.fix:
            h.write_bytes(h.read_bytes()[3:])
            print(f"bom_lint: 已去掉 BOM  {rel}")
        else:
            print(f"bom_lint: [FAIL] 带 UTF-8 BOM  {rel}")
    if args.fix:
        return 0
    print("\n去掉它：python tools/bom_lint.py --fix <文件>。"
          "PowerShell 写文件请用 [IO.File]::WriteAllText($p, $s, (New-Object Text.UTF8Encoding($false)))。")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
