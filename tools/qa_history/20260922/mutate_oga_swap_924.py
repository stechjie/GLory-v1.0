"""9.24 订正 #2 变异测试：证明 oga_projectile_swap_check 真的会红（先用后绿不算证据）。

两个**互相隔离**的变异，各自只该触发一类判据：
  A. 把两把模型 path 换回去（= 对换被撤销）      -> 期望 model_not_swapped 红
  B. 把 god_priest 的 speed 5.6 改成 6.4         -> 期望 speed_changed   红

每个变异都要求：
  * 目标串在文件里**恰好出现 1 次**（改错位置 = 假证）；
  * 跑门禁拿到 rc=1 且失败码与预期一致；
  * try/finally 保证还原；
  * 还原后 sha256 与变异前**逐字节相同**。
"""
import hashlib, os, re, subprocess, sys

PROJ = r"C:\Users\WINDOWS\Desktop\GLory-work"
EXE = r"C:\Users\WINDOWS\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
ENV_PATH = r"C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem"
TARGET = os.path.join(PROJ, "tools", "oga_projectile_swap_check.tscn")
CATALOG = os.path.join(PROJ, "effects", "vfx3d", "units", "OgaChessVFXCatalog.gd")

AURORA = "god_aurora_light_spear.png"
PRIEST = "god_priest_star_lance.png"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run_gate():
    env = dict(os.environ)
    env["PATH"] = ENV_PATH
    p = subprocess.run([EXE, "--headless", "--path", PROJ, "tools/oga_projectile_swap_check.tscn"],
                       capture_output=True, timeout=300, env=env, cwd=PROJ)
    out = (p.stdout + p.stderr).decode("utf-8", "replace")
    fails = re.findall(r"FAIL \[([a-z_]+)\]", out)
    mismatch = re.search(r"CHECK_RESULT name=oga_projectile_swap status=(\w+) checked=(\d+) failures=(\d+)", out)
    return p.returncode, fails, (mismatch.group(0) if mismatch else "(no CHECK_RESULT)")


def mutate(label, apply_fn, expect_code):
    original = open(CATALOG, "rb").read()
    before = sha256(original)
    print("=" * 74)
    print("%s  (before sha256=%s)" % (label, before[:16]))
    try:
        text = original.decode("utf-8")
        mutated, count = apply_fn(text)
        if count != 1:
            print("  !! 目标串出现 %d 次（要求恰好 1 次）—— 变异位置不可信，终止" % count)
            return False
        open(CATALOG, "w", encoding="utf-8", newline="").write(mutated)
        if sha256(open(CATALOG, "rb").read()) == before:
            print("  !! 写入后 sha256 未变 —— 变异没有生效")
            return False
        rc, fails, line = run_gate()
        print("  rc=%s  %s" % (rc, line))
        print("  FAIL codes: %s" % (fails if fails else "(none)"))
        ok = (rc == 1 and expect_code in fails)
        print("  -> %s (期望 rc=1 且含 %s)" % ("RED as expected" if ok else "UNEXPECTED", expect_code))
        return ok
    finally:
        open(CATALOG, "wb").write(original)
        after = sha256(open(CATALOG, "rb").read())
        restored = (after == before)
        print("  restore: sha256=%s %s" % (after[:16], "IDENTICAL" if restored else "*** MISMATCH ***"))
        if not restored:
            print("  !!! 还原失败，文件已损坏，停止")
            sys.exit(2)


def apply_swap_back(text):
    """A: 撤销对换（两把 path 互换回去）。三个 png 名各自唯一。"""
    sentinel = "\x00SENTINEL\x00"
    a = text.count(AURORA)
    b = text.count(PRIEST)
    if a != 1 or b != 1:
        return text, -1
    text = text.replace(AURORA, sentinel).replace(PRIEST, AURORA).replace(sentinel, PRIEST)
    return text, 1


def apply_speed_bump(text):
    """B: 只改 god_priest 的 speed（它那一行有唯一的 size 0.78,0.34 上下文）。"""
    old = '"fps":18.0, "size":Vector2(0.78,0.34), "speed":5.6,'
    new = '"fps":18.0, "size":Vector2(0.78,0.34), "speed":6.4,'
    return text.replace(old, new), text.count(old)


def main():
    results = []
    results.append(("A swap reverted", mutate("MUTATION A — 撤销对换（两把 path 换回去）", apply_swap_back, "model_not_swapped")))
    results.append(("B speed bumped", mutate("MUTATION B — god_priest speed 5.6 -> 6.4", apply_speed_bump, "speed_changed")))

    print("=" * 74)
    print("baseline (restored) run:")
    rc, fails, line = run_gate()
    print("  rc=%s  %s  FAIL=%s" % (rc, line, fails or "(none)"))
    restored_green = (rc == 0)

    print("=" * 74)
    for name, ok in results:
        print("  %-18s %s" % (name, "RED as expected" if ok else "*** NOT CAUGHT ***"))
    print("  %-18s %s" % ("restored green", "YES" if restored_green else "NO"))
    all_ok = all(ok for _, ok in results) and restored_green
    print("\nMUTATION VERDICT:", "PASS — gate localises both mutation classes" if all_ok else "FAIL")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
