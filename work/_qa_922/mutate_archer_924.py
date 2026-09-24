"""9.24 订正 #6 变异测试：证明 oga_projectile_swap_check 对弓箭手金属箭真的会红。

两个**互相隔离**的变异，各自只该触发一类判据：
  C. 把弓箭手的 path 改回 human_archer_blue_wind_arrow.png（= 撤销 #6）
       -> 期望 archer_not_metal_arrow 红
  D. 把贴图换成一张**朝右(0°)** 的箭（= 换图时搞错朝向约定）
       -> 期望 archer_sheet_orientation 红
       ★ 这一条必须真的换像素 + 重导：门禁是从 .ctex 读像素的，
         只改 .gd 是证明不了朝向判据的。

每个变异都要求：
  * 目标串/目标文件在校验前先备份，try/finally 保证还原；
  * 跑门禁拿到 rc=1 且失败码与预期一致；
  * 还原后 sha256 与变异前**逐字节相同**（PNG 还要重导一遍把 .ctex 也还原）。
"""
import hashlib, os, re, subprocess, sys

PROJ = r"C:\Users\WINDOWS\Desktop\GLory-work"
EXE = r"C:\Users\WINDOWS\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
ENV_PATH = r"C:\Windows\System32;C:\Windows;C:\Windows\System32;C:\Windows\System32\Wbem"
CATALOG = os.path.join(PROJ, "effects", "vfx3d", "units", "OgaChessVFXCatalog.gd")
ARROW_PNG = os.path.join(PROJ, "assets", "vfx", "oga", "projectiles", "human_archer_metal_arrow.png")
LABEL = "archer_metal_arrow"


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def sha256_file(p: str) -> str:
    return sha256_bytes(open(p, "rb").read())


def _env():
    env = dict(os.environ)
    env["PATH"] = ENV_PATH
    return env


def run_gate():
    p = subprocess.run([EXE, "--headless", "--path", PROJ, "tools/oga_projectile_swap_check.tscn"],
                       capture_output=True, timeout=300, env=_env(), cwd=PROJ)
    out = (p.stdout + p.stderr).decode("utf-8", "replace")
    fails = re.findall(r"FAIL \[([a-z_]+)\]", out)
    m = re.search(r"CHECK_RESULT name=oga_projectile_swap status=(\w+) checked=(\d+) failures=(\d+)", out)
    notes = re.findall(r"\] note: (\S.*)", out)
    return p.returncode, fails, (m.group(0) if m else "(no CHECK_RESULT)"), notes


def reimport():
    subprocess.run([EXE, "--headless", "--path", PROJ, "--import"],
                   capture_output=True, timeout=900, env=_env(), cwd=PROJ)


# --------------------------------------------------------------------------
# C：把 path 改回风之箭（纯文本变异）
# --------------------------------------------------------------------------
def mutate_catalog():
    original = open(CATALOG, "rb").read()
    before = sha256_bytes(original)
    old = '"path":"res://assets/vfx/oga/projectiles/human_archer_metal_arrow.png"'
    new = '"path":"res://assets/vfx/oga/projectiles/human_archer_blue_wind_arrow.png"'
    print("=" * 74)
    print("MUTATION C — 弓箭手 path 改回 blue_wind_arrow  (before sha256=%s)" % before[:16])
    try:
        text = original.decode("utf-8")
        if text.count(old) != 1:
            print("  !! 目标串出现 %d 次（要求恰好 1 次）—— 变异位置不可信，终止" % text.count(old))
            return False
        open(CATALOG, "w", encoding="utf-8", newline="").write(text.replace(old, new))
        if sha256_file(CATALOG) == before:
            print("  !! 写入后 sha256 未变 —— 变异没有生效")
            return False
        rc, fails, line, _ = run_gate()
        print("  rc=%s  %s" % (rc, line))
        print("  FAIL codes: %s" % (fails if fails else "(none)"))
        ok = (rc == 1 and "archer_not_metal_arrow" in fails)
        print("  -> %s (期望 rc=1 且含 archer_not_metal_arrow)"
              % ("RED as expected" if ok else "UNEXPECTED"))
        return ok
    finally:
        open(CATALOG, "wb").write(original)
        after = sha256_file(CATALOG)
        print("  restore: sha256=%s %s" % (after[:16], "IDENTICAL" if after == before else "*** MISMATCH ***"))
        if after != before:
            print("  !!! 还原失败，停止")
            sys.exit(2)


# --------------------------------------------------------------------------
# D：把贴图换成朝右(0°)的箭（像素变异 + 重导）
# --------------------------------------------------------------------------
def make_right_arrow_sheet(path):
    from PIL import Image, ImageDraw
    W, H, cols = 960, 176, 6
    cw = W // cols
    sheet = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(sheet)
    for i in range(cols):
        ox = i * cw
        cy = H // 2
        # 与真图同尺寸/同分格，但箭**朝右**（0°）—— 正是"换图搞错朝向约定"的样子
        d.line([(ox + 26, cy), (ox + 116, cy)], fill=(150, 155, 165, 255), width=7)
        d.polygon([(ox + 132, cy), (ox + 104, cy - 15), (ox + 104, cy + 15)],
                  fill=(212, 220, 230, 255))
    sheet.save(path, "PNG")


def mutate_sheet():
    original = open(ARROW_PNG, "rb").read()
    before = sha256_bytes(original)
    ctex_dir = os.path.join(PROJ, ".godot", "imported")
    ctex_before = {f: sha256_file(os.path.join(ctex_dir, f))
                   for f in os.listdir(ctex_dir) if LABEL in f}
    print("=" * 74)
    print("MUTATION D — 贴图换成朝右(0°)的箭  (before sha256=%s)" % before[:16])
    try:
        make_right_arrow_sheet(ARROW_PNG)
        if sha256_file(ARROW_PNG) == before:
            print("  !! 替换后 sha256 未变 —— 变异没有生效")
            return False
        reimport()
        rc, fails, line, notes = run_gate()
        print("  rc=%s  %s" % (rc, line))
        for n in notes:
            print("  note: %s" % n)
        print("  FAIL codes: %s" % (fails if fails else "(none)"))
        ok = (rc == 1 and "archer_sheet_orientation" in fails)
        print("  -> %s (期望 rc=1 且含 archer_sheet_orientation)"
              % ("RED as expected" if ok else "UNEXPECTED"))
        return ok
    finally:
        open(ARROW_PNG, "wb").write(original)
        after = sha256_file(ARROW_PNG)
        reimport()
        ctex_after = {f: sha256_file(os.path.join(ctex_dir, f))
                      for f in os.listdir(ctex_dir) if LABEL in f}
        same_png = (after == before)
        same_ctex = (ctex_before == ctex_after)
        print("  restore: png sha256=%s %s" % (after[:16], "IDENTICAL" if same_png else "*** MISMATCH ***"))
        print("  restore: ctex %s" % ("IDENTICAL" if same_ctex else "*** MISMATCH ***"))
        if not (same_png and same_ctex):
            print("  !!! 还原失败，停止")
            sys.exit(2)


def main():
    results = []
    results.append(("C path reverted", mutate_catalog()))
    results.append(("D sheet rotated", mutate_sheet()))

    print("=" * 74)
    print("baseline (restored) run:")
    rc, fails, line, notes = run_gate()
    print("  rc=%s  %s  FAIL=%s" % (rc, line, fails or "(none)"))
    for n in notes:
        print("  note: %s" % n)
    restored_green = (rc == 0)

    print("=" * 74)
    for name, ok in results:
        print("  %-18s %s" % (name, "RED as expected" if ok else "*** NOT CAUGHT ***"))
    print("  %-18s %s" % ("restored green", "YES" if restored_green else "NO"))
    all_ok = all(ok for _, ok in results) and restored_green
    print("\nMUTATION VERDICT:", "PASS — gate localises both #6 mutation classes" if all_ok else "FAIL")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
