"""9.25 追加订正（商店刷新「教学免费 = 无限次」）变异测试。

判据：tools/shop_refresh_free_source_check.gd
变异：把 PrepUI._on_refresh_shop_control_pressed 的 all_free 判定退回**旧写法**
      （只抄 TreasureService.has_set("money")，漏掉 GameState.tutorial_mode）。
      这正是用户 2026-09-25 报回来的 bug 原始形态。
期望：变异后门禁红（call_site_missing_same_source + call_site_stale_all_free）；
      还原后绿。

★ 二进制读写：仓库是 CRLF，文本模式会把 \\r\\n 归一成 \\n 再写回 LF，
  那样"还原"就不再是逐字节还原、sha256 对不上。
★ 不落 .mutbak：脚本自己 with-try-finally 还原，不给后续脚本留"启动自愈"的雷
  （9.25 已吃过陈旧 .mutbak 静默回退新改动的亏）。

用法：python mutate_shop_refresh_925.py
"""
import subprocess, os, hashlib, sys

EXE = r"C:\Users\WINDOWS\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
PROJ = r"C:\Users\WINDOWS\Desktop\GLory-work"
ENV_PATH = r"C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem"

TARGET = os.path.join(PROJ, "scenes", "prep", "PrepUI.gd")
SCENE = "tools/shop_refresh_free_source_check.tscn"

ORIG = b"var all_free := TutorialMode.shop_refresh_all_free()"
MUT = b'var all_free := TreasureService.has_set("money")'


def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def run_gate():
    env = dict(os.environ)
    env["PATH"] = ENV_PATH
    p = subprocess.run([EXE, "--headless", "--path", PROJ, SCENE],
                       capture_output=True, env=env, cwd=PROJ, timeout=300)
    raw = p.stdout.decode("utf-8", "replace") + p.stderr.decode("utf-8", "replace")
    lines = [l.strip()[:220] for l in raw.splitlines()
             if "CHECK_RESULT" in l or "FAIL [" in l]
    return p.returncode, lines


def main():
    before = sha(TARGET)
    with open(TARGET, "rb") as fh:
        data = fh.read()

    hits = data.count(ORIG)
    if hits != 1:
        print("REFUSE: 期望恰好 1 处目标锚点，实际 %d 处 —— 锚点已漂，变异无效" % hits)
        return 2

    red_ok = False
    try:
        with open(TARGET, "wb") as fh:
            fh.write(data.replace(ORIG, MUT))
        rc, lines = run_gate()
        print("=== 变异后（期望 FAIL）rc=%s ===" % rc)
        for l in lines:
            print("   ", l)
        red_ok = rc != 0
    finally:
        with open(TARGET, "wb") as fh:
            fh.write(data)

    after = sha(TARGET)
    print("=== 还原 sha256 一致: %s (%s -> %s) ===" % (before == after, before[:16], after[:16]))

    green_ok = False
    if before == after:
        rc2, lines2 = run_gate()
        print("=== 还原后（期望 PASS）rc=%s ===" % rc2)
        for l in lines2:
            print("   ", l)
        green_ok = rc2 == 0

    verdict = "OK" if (red_ok and green_ok and before == after) else "BROKEN"
    print("MUTATION_VERDICT %s red=%s green=%s restored=%s" % (
        verdict, red_ok, green_ok, before == after))
    return 0 if verdict == "OK" else 1


if __name__ == "__main__":
    sys.exit(main())
