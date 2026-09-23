# -*- coding: utf-8 -*-
"""变异测试：证明 `audio_0922_check` 的两条关键断言真的会红（不是假绿）。

同时施加两处变异（失败码可分辨，所以一次跑就能分别归因）：
  A. BattleSimulator 里把 `poison_attack` 分支的 `_emit_sfx_proc` 调用换成 `pass`
     → 期望 [sfx_proc_not_emitted_poison_attack]
  B. SfxService.play() 里的音量改回 `voice.volume_db = volume_db`
     → 期望 [volume_override_not_applied]

★★ 本文件从「两阶段」重写为**单次调用跑完**（原因见 `mutate_swap_fix.py` 头注释）：
   两阶段脚本 + 无脑重跑 `backup` 会把 `.mutbak` 覆盖成**变异后**的内容，
   备份失效、变异留在工作树上；且文本模式读写会把 CRLF 归一化成 LF。
   现在：二进制读写 + `try/finally` 自还原 + 探针硬超时 + 启动自愈残留 + sha256 验收。

用法: python mutate_audio_fix.py
"""
import hashlib
import os
import subprocess
import sys

EXE = r"C:\Users\WINDOWS\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
ROOT = r"C:\Users\WINDOWS\Desktop\GLory-work"
ENV_PATH = r"C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem"
GATE = "audio_0922_check"

MUTS = [
    (
        os.path.join(ROOT, "scripts", "battle", "BattleSimulator.gd"),
        "\t\t# 9.22：四星毒灵 / 四星飞灵共用这一条（两只棋子的 skill_id 都是 `poison_attack`）。\r\n"
        "\t\t_emit_sfx_proc(state, sid, attacker, target)\r\n",
        "\t\t# MUTATED\r\n"
        "\t\tpass\r\n",
    ),
    (
        os.path.join(ROOT, "ui", "services", "SfxService.gd"),
        "\tvoice.volume_db = volume_db + cue_volume_db(cue)\r\n",
        "\tvoice.volume_db = volume_db\r\n",
    ),
]


def sha(path: str) -> str:
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def run_gate() -> tuple:
    env = dict(os.environ)
    env["PATH"] = ENV_PATH
    try:
        p = subprocess.run([EXE, "--headless", "--path", ROOT, "tools/%s.tscn" % GATE],
                           capture_output=True, timeout=300, env=env, cwd=ROOT)
    except subprocess.TimeoutExpired:
        return "TIMEOUT", []
    raw = p.stdout.decode("utf-8", "replace") + p.stderr.decode("utf-8", "replace")
    lines = [l.strip() for l in raw.splitlines() if "CHECK_RESULT" in l or "FAIL" in l]
    return ("PASS" if p.returncode == 0 else "FAIL"), lines


def restore_all() -> None:
    for path, _fixed, _mut in MUTS:
        bak = path + ".mutbak"
        if os.path.exists(bak):
            with open(bak, "rb") as src:
                data = src.read()
            with open(path, "wb") as dst:
                dst.write(data)
            os.remove(bak)


def main() -> int:
    if any(os.path.exists(p + ".mutbak") for p, _, _ in MUTS):
        print("[heal] 发现残留 .mutbak，先还原")
        restore_all()

    known = {p: sha(p) for p, _, _ in MUTS}
    for p, fixed, _mut in MUTS:
        with open(p, "rb") as fh:
            raw = fh.read()
        if raw.count(fixed.encode("utf-8")) != 1:
            print("[abort] %s 里待变异片段出现 %d 次（应为 1），不是 known-good 形态"
                  % (os.path.basename(p), raw.count(fixed.encode("utf-8"))))
            return 3
    print("[info] known-good:", {os.path.basename(p): h[:16] for p, h in known.items()})

    baseline, base_lines = run_gate()
    print("[base] 门禁基线 =", baseline, base_lines)
    if baseline != "PASS":
        print("[abort] 基线不是 PASS，变异无意义")
        return 3

    rc = 1
    try:
        for p, fixed, mut in MUTS:
            bak = p + ".mutbak"
            with open(p, "rb") as fh:
                raw = fh.read()
            with open(bak, "wb") as fh:
                fh.write(raw)
            with open(p, "wb") as fh:
                fh.write(raw.replace(fixed.encode("utf-8"), mut.encode("utf-8"), 1))
            print("[mut ] %s 已变异" % os.path.basename(p))

        verdict, lines = run_gate()
        print("[mut ] 变异后门禁 =", verdict)
        for l in lines:
            print("        " + l[:200])
        if verdict == "FAIL":
            print("[ok  ] 门禁有效：两处变异被判红")
            rc = 0
        else:
            print("[HOLE] 门禁无效：变异后仍然判绿")
            rc = 2
    finally:
        restore_all()
        bad = [p for p, h in known.items() if sha(p) != h]
        print("[restore] sha256 全部一致 =", not bad, " 残留 .mutbak =",
              any(os.path.exists(p + ".mutbak") for p, _, _ in MUTS))
        if bad:
            print("[FATAL] 还原失败：", bad)
            return 4
        verdict2, lines2 = run_gate()
        print("[after] 还原后门禁 =", verdict2, lines2)
        if verdict2 != baseline:
            print("[FATAL] 还原后门禁与基线不一致")
            return 4
    return rc


if __name__ == "__main__":
    sys.exit(main())
