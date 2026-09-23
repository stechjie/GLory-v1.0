"""归因 `ui_feedback_check` 的唯一一条失败 `shake_did_not_start`。

假设：这不是代码回归，而是**环境态**——持久化的 `user://profile.json` 里
`reduced_motion_enabled=true`，而 `UiFeedback.shake()` 在 `Tokens.reduced_motion()`
为真时**按设计**返回 false。门禁只置了 `screen_shake` 开关，没动 reduced_motion。

做法：把磁盘上的 `reduced_motion_enabled` 改成 false（**字节级备份**），再跑门禁。
  * 若转绿 → 确认是环境态，与本批代码无关；
  * 若仍红 → 假设不成立，另有原因。
最后**逐字节还原** profile.json 并校验 sha256。

用法: python attribute_ui_feedback_922.py
"""
import hashlib
import os
import pathlib
import re
import subprocess
import sys

EXE = r"C:\Users\WINDOWS\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
PROJ = r"C:\Users\WINDOWS\Desktop\GLory-work"
ENV_PATH = r"C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem"

PROFILE = pathlib.Path(os.environ["APPDATA"]) / "Godot" / "app_userdata" / "Glory Beta 0.04" / "profile.json"
BACKUP = pathlib.Path(PROJ) / "work" / "_qa_922" / "profile_json_before.bin"
GATE = "ui_feedback_check"

PAT = rb'"reduced_motion_enabled"\s*:\s*true'


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def run_gate() -> tuple:
    env = dict(os.environ)
    env["PATH"] = ENV_PATH
    try:
        p = subprocess.run([EXE, "--headless", "--path", PROJ, "tools/%s.tscn" % GATE],
                           capture_output=True, timeout=300, env=env, cwd=PROJ)
    except subprocess.TimeoutExpired:
        return "TIMEOUT", []
    raw = p.stdout.decode("utf-8", "replace") + p.stderr.decode("utf-8", "replace")
    lines = [l.strip() for l in raw.splitlines() if "CHECK_RESULT" in l or "FAIL" in l]
    return ("PASS" if p.returncode == 0 else "FAIL"), lines


def main() -> int:
    original = PROFILE.read_bytes()
    before = sha(original)
    print("[disk] profile.json sha =", before[:16])
    print("[disk] reduced_motion_enabled =", bool(re.search(PAT, original)))

    verdict_red, lines_red = run_gate()
    print("[base] 现状门禁 =", verdict_red, lines_red)

    rc = 1
    try:
        if not re.search(PAT, original):
            print("[skip] 磁盘上本来就不是 true，无法做对照")
            return 3
        BACKUP.write_bytes(original)
        flipped = re.sub(PAT, b'"reduced_motion_enabled":false', original, count=1)
        PROFILE.write_bytes(flipped)
        print("[mut ] 已置 reduced_motion_enabled=false")

        verdict_green, lines_green = run_gate()
        print("[mut ] 改后门禁 =", verdict_green, lines_green)
        if verdict_green == "PASS" and verdict_red == "FAIL":
            print("[ok  ] 归因成立：这条红完全由持久化的 reduced_motion_enabled 引起，与本批代码无关")
            rc = 0
        else:
            print("[!!  ] 归因不成立 —— 要另找原因")
            rc = 2
    finally:
        PROFILE.write_bytes(original)
        now = sha(PROFILE.read_bytes())
        print("[restore] sha =", now[:16], "match =", now == before)
        if now != before:
            print("[FATAL] 还原失败")
            return 4
    return rc


if __name__ == "__main__":
    sys.exit(main())
