# -*- coding: utf-8 -*-
"""变异测试：把 PrepBoardController 的「合不成就交换」改回旧写法，
证明 `prep_swap_check` 真的会红（不是假绿）。

覆盖**两条**被修的路，因为用户真正踩到的是第二条：

  ① `_move_or_merge_board_to_bench`（场 ↔ 待命区）
  ② `_move_or_merge_bench`        （待命区 ↔ 待命区）← 用户报的现场

★★ 第一版的事故（本文件重写的原因，务必别再犯）：
   ① 它是**两阶段**脚本（`backup` 施加变异 / `restore` 还原），我把不带参数的调用
      当成「只打印基线」跑了一次 —— 等价于 `backup`，**变异留在了工作树上**；
   ② 再跑一次 `backup` 时 `.mutbak` 被**变异后的内容**覆盖 → 备份也失效，
      `restore` 只会把变异贴回来；
   ③ 它用**文本模式**读写（`io.open` / `newline=""`），把全文件 CRLF 静默归一化成 LF。
   → 救回来靠的是「从另外 3 个 handler 逐字节取 FIXED 片段 + sha256 验收」，
     见 `restore_prep_swap_922.py`。

   现在改成与 `mutate_cold_parse_922.py` 同一套纪律：
   单次调用内跑完、`try/finally` 自还原、**二进制读写**、探针硬超时、
   启动先自愈残留 `.mutbak`、还原后校验 sha256 并复跑门禁与基线比对。

用法: python mutate_swap_fix.py
"""
import hashlib
import os
import subprocess
import sys

EXE = r"C:\Users\WINDOWS\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
PROJ = r"C:\Users\WINDOWS\Desktop\GLory-work"
ENV_PATH = r"C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem"

TARGET = os.path.join(PROJ, "scenes", "prep", "PrepBoardController.gd")
BAK = TARGET + ".mutbak"
GATE = "prep_swap_check"

# --- ① 场 ↔ 待命区 -------------------------------------------------------------

FIXED_BTB = """	# 9.22：合不成就退回交换，理由与根因见 `_move_or_merge_board` 上方的长注释
	# （「两个同星级人王交换无效」的修复）。四个 handler 是同一个改法。
	elif PrepRules.can_merge_cells(to_cell, from_cell) \\
			and _merge_copies_into_cell(to_cell, from_cell, [from_index], [bench_index]):
		_shadow_report_merge()
		GameState.board_slots[from_index] = null
	else:
		if _would_exceed_board_limit(to_cell, from_index):"""

OLD_BTB = """	elif PrepRules.can_merge_cells(to_cell, from_cell):
		if not _merge_copies_into_cell(to_cell, from_cell, [from_index], [bench_index]):
			_board_hud._selected_board = -1
			_refresh_all()
			return
		_shadow_report_merge()
		GameState.board_slots[from_index] = null
	else:
		if _would_exceed_board_limit(to_cell, from_index):"""

# --- ② 待命区 ↔ 待命区（用户报的那条） ------------------------------------------

FIXED_BB = """	elif PrepRules.can_merge_cells(to_cell, from_cell) \\
			and _merge_copies_into_cell(to_cell, from_cell, [], [from_index, to_index]):
		_shadow_report_merge()
		GameState.bench_slots[from_index] = null
	else:
		GameState.bench_slots[to_index] = from_cell
		GameState.bench_slots[from_index] = to_cell"""

OLD_BB = """	elif PrepRules.can_merge_cells(to_cell, from_cell):
		if not _merge_copies_into_cell(to_cell, from_cell, [], [from_index, to_index]):
			_board_hud._selected_bench = -1
			_refresh_all()
			return
		_shadow_report_merge()
		GameState.bench_slots[from_index] = null
	else:
		GameState.bench_slots[to_index] = from_cell
		GameState.bench_slots[from_index] = to_cell"""

# 本仓 `scenes/**` 的 .gd 在磁盘上是 CRLF（已用 probe_bench_bytes.py 逐字节确认）。
FIXED_B = FIXED_BTB.replace("\n", "\r\n").encode("utf-8")
OLD_B = OLD_BTB.replace("\n", "\r\n").encode("utf-8")

# (标签, FIXED 字节, OLD 字节) —— FIXED 必须在工作树里**恰好出现 1 次**。
MUTATIONS = [
    ("board_to_bench", FIXED_BTB, OLD_BTB),
    ("bench_bench", FIXED_BB, OLD_BB),
]


def sha(path: str) -> str:
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def run_gate() -> tuple:
    env = dict(os.environ)
    env["PATH"] = ENV_PATH
    try:
        p = subprocess.run([EXE, "--headless", "--path", PROJ, "tools/%s.tscn" % GATE],
                           capture_output=True, timeout=300, env=env, cwd=PROJ)
    except subprocess.TimeoutExpired:
        return "TIMEOUT", []
    raw = p.stdout.decode("utf-8", "replace") + p.stderr.decode("utf-8", "replace")
    lines = [l.strip() for l in raw.splitlines() if "CHECK_RESULT" in l or "PROBE_DONE" in l]
    return ("PASS" if p.returncode == 0 else "FAIL"), lines


def restore() -> None:
    if os.path.exists(BAK):
        with open(BAK, "rb") as src:
            data = src.read()
        with open(TARGET, "wb") as dst:
            dst.write(data)
        os.remove(BAK)


def main() -> int:
    if os.path.exists(BAK):
        print("[heal] 发现残留 .mutbak，先还原（上一次被硬杀/中断留下的变异态）")
        restore()
    known_good = sha(TARGET)
    print("[info] known-good sha256 =", known_good)

    with open(TARGET, "rb") as fh:
        src = fh.read()

    encoded = []
    for label, fixed_text, old_text in MUTATIONS:
        fb = fixed_text.replace("\n", "\r\n").encode("utf-8")
        ob = old_text.replace("\n", "\r\n").encode("utf-8")
        n = src.count(fb)
        if n != 1:
            print("[abort] %s 的 FIXED 片段在工作树里出现 %d 次（应为 1）"
                  "—— 工作树不是 known-good 形态（或行尾不是 CRLF）" % (label, n))
            return 3
        encoded.append((label, fb, ob))
        print("[info] %-14s FIXED 片段命中 1 次，长度 %d 字节" % (label, len(fb)))

    baseline, base_lines = run_gate()
    print("[base] 门禁基线 =", baseline, base_lines)
    if baseline == "TIMEOUT":
        print("[abort] 基线超时，无法判定")
        return 3
    if baseline == "FAIL":
        print("[abort] 基线本来就是红的，变异无意义")
        return 3

    rc = 0
    try:
        for label, fb, ob in encoded:
            with open(BAK, "wb") as fh:
                fh.write(src)
            mutated = src.replace(fb, ob, 1)
            if mutated.count(ob) != 1 or mutated.count(fb) != 0:
                print("[abort] %s 变异后片段计数异常，放弃" % label)
                return 3
            with open(TARGET, "wb") as fh:
                fh.write(mutated)
            print("[mut ] %s：已改回旧写法（%d -> %d 字节）" % (label, len(fb), len(ob)))

            verdict, lines = run_gate()
            print("[mut ] %s 变异后门禁 = %s %s" % (label, verdict, lines))
            if verdict == "FAIL":
                print("[ok  ] %s：门禁有效，旧写法被判红" % label)
            elif verdict == "TIMEOUT":
                print("[HOLE] %s：变异后门禁超时（不能算判红）" % label)
                rc = 2
            else:
                print("[HOLE] %s：改回旧写法仍然判绿 —— 这条路的探针是假绿" % label)
                rc = 2

            restore()
            now = sha(TARGET)
            print("[restore] %s 还原 sha256 = %s match = %s" % (label, now, now == known_good))
            if now != known_good:
                print("[FATAL] 还原失败！工作树停在变异态")
                return 4
    finally:
        if os.path.exists(BAK):
            restore()
        now = sha(TARGET)
        if now != known_good:
            print("[FATAL] 收尾还原失败！工作树 sha256 =", now)
            return 4
        verdict2, lines2 = run_gate()
        print("[after] 收尾门禁 =", verdict2, lines2)
        if verdict2 != baseline:
            print("[FATAL] 还原后门禁与基线不一致")
            return 4
    return rc


if __name__ == "__main__":
    sys.exit(main())
