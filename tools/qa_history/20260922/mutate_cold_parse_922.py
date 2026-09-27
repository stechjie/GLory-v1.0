"""cold_parse_chain_check 变异测试：确认它**真能**判红「elif 无语句体」这类解析错误。

背景（本批事故）：9.22 我把 BattleVfx.gd `_play_skill_cast_vfx` 里 `elif _owned:`
的语句体整段抬出缩进，只剩注释 → **解析期错误**。本批 19 条门禁里恰好**没有**这条
`cold_parse_chain_check`，所以整批跑出「12 PASS / 5 预存红」把它漏过去了；是
`voice_check`（它 load 了 BattleScreen.gd）顺手把它抓出来的。

★★ 行尾陷阱（本脚本第一版踩过，务必别再犯）：
   本仓 `scenes/**` 的 .gd 在磁盘上是 **CRLF**，而 git HEAD 里是 LF。
   用 Python **文本模式**读写（`open(p)` / `open(p, "w", newline="\\n")`）会把 CRLF
   **静默归一化成 LF**，于是 `finally` 里贴回去的文件 sha256 与 known-good 不一致 ——
   变异「还原成功」的假象下工作树已被损坏。
   → 本脚本所有文件 I/O 一律走**二进制**，匹配串自带 `\\r\\n`。

用法: python mutate_cold_parse_922.py
"""
import hashlib
import os
import subprocess
import sys

EXE = r"C:\Users\WINDOWS\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
PROJ = r"C:\Users\WINDOWS\Desktop\GLory-work"
ENV_PATH = r"C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem"

TARGET = os.path.join(PROJ, "scenes", "battle", "BattleVfx.gd")
BAK = TARGET + ".mutbak"
GATE = "cold_parse_chain_check"

GOOD_BLOCK = (
    "\t\t# 9.20 起门控与上面同一口径：自身 + 友军（敌方天然被排除）。\r\n"
    "\t\tvar merc_cue := SfxService.merc_skill_cue_for(uid)\r\n"
    "\t\tif not merc_cue.is_empty():\r\n"
    "\t\t\tSfxService.play(merc_cue)\r\n"
).encode("utf-8")

BAD_BLOCK = (
    "\t\t# 9.20 起门控与上面同一口径：自身 + 友军（敌方天然被排除）。\r\n"
    "\tvar merc_cue := SfxService.merc_skill_cue_for(uid)\r\n"
    "\tif not merc_cue.is_empty():\r\n"
    "\t\tSfxService.play(merc_cue)\r\n"
).encode("utf-8")


def sha256(path: str) -> str:
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def run_gate() -> tuple:
    env = dict(os.environ)
    env["PATH"] = ENV_PATH
    cmd = [EXE, "--headless", "--path", PROJ, "tools/%s.tscn" % GATE]
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=300, env=env, cwd=PROJ)
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
    # ---- 启动自愈：上一次被硬杀留下的 .mutbak / 变异态 ----
    if os.path.exists(BAK):
        print("[heal] 发现残留 .mutbak，先还原")
        restore()
    known_good = sha256(TARGET)
    print("[info] known-good sha256 =", known_good[:16])

    with open(TARGET, "rb") as fh:
        src = fh.read()
    if GOOD_BLOCK not in src:
        print("[abort] 工作树不是 known-good 形态（找不到 GOOD_BLOCK）")
        return 3
    if src.count(GOOD_BLOCK) != 1:
        print("[abort] GOOD_BLOCK 不唯一:", src.count(GOOD_BLOCK))
        return 3

    baseline, base_lines = run_gate()
    print("[base] 门禁基线 =", baseline, base_lines)
    if baseline == "TIMEOUT":
        print("[abort] 基线超时，无法判定")
        return 3

    rc = 1
    try:
        with open(BAK, "wb") as fh:
            fh.write(src)
        with open(TARGET, "wb") as fh:
            fh.write(src.replace(GOOD_BLOCK, BAD_BLOCK))
        print("[mut ] 已注入「elif 无语句体」解析错误")

        verdict, lines = run_gate()
        print("[mut ] 变异后门禁 =", verdict, lines)
        if verdict == "FAIL":
            print("[ok  ] 门禁有效：解析错误被判红")
            rc = 0
        else:
            print("[HOLE] 门禁无效：解析错误仍判绿 —— 判据或覆盖面必须加强")
            rc = 2
    finally:
        restore()
        now = sha256(TARGET)
        print("[restore] sha256 =", now[:16], "match =", now == known_good)
        if now != known_good:
            print("[FATAL] 还原失败！工作树停在变异态")
            return 4
        verdict2, lines2 = run_gate()
        print("[after] 还原后门禁 =", verdict2, lines2)
        if verdict2 != baseline:
            print("[FATAL] 还原后门禁与基线不一致")
            return 4
    return rc


if __name__ == "__main__":
    sys.exit(main())
