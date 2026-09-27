#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""跑单个门禁并把**失败明细**打出来。

run_gates.py 只捞 CHECK_RESULT / PROBE_DONE 那两行（防 false-green 的既定口径），
所以「这条红的到底是哪几个键」得另跑一次并读 `FAIL [key]` 行 —— 本仓规矩：
报 FAIL 必须能说出失败项，不能只说「它红了」。

用法: python show_fails.py <门禁名> [<门禁名> ...]
"""
import os
import re
import subprocess
import sys

PROJ = r"C:\Users\WINDOWS\Desktop\GLory-work"
EXE = r"C:\Users\WINDOWS\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
ENV_PATH = r"C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem"


def scene_for(name):
    local = os.path.join(PROJ, "work", "_qa_922", "%s.tscn" % name)
    if os.path.isfile(local):
        return "work/_qa_922/%s.tscn" % name
    return "tools/%s.tscn" % name


def run(name):
    env = dict(os.environ)
    env["PATH"] = ENV_PATH
    p = subprocess.run([EXE, "--headless", "--path", PROJ, scene_for(name)],
                       capture_output=True, timeout=300, env=env, cwd=PROJ)
    raw = (p.stdout + p.stderr).decode("utf-8", "replace")
    fails = re.findall(r"FAIL \[([^\]]+)\]", raw)
    print("== %s rc=%s fails=%d" % (name, p.returncode, len(fails)))
    seen = set()
    for line in raw.splitlines():
        if "FAIL [" not in line:
            continue
        text = line.strip()
        if text not in seen:
            seen.add(text)
            print("   " + text[:1200])


if __name__ == "__main__":
    for g in (sys.argv[1:] or ["procedural_ui_ratchet_check"]):
        run(g)
