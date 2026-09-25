"""9.25 回归定位：9.24 行为探针 probe_doom_thunder_924 从 PASS 变 FAIL。

本脚本只回答一个问题：**是不是本轮改的 BattleSimulator.gd 那几处造成的。**

做法：把本轮的 3 处代码改动逐条反向撤销（R1/R2/R3），每撤销一条跑一次 9.24 探针，
记录 rc；全部跑完后从备份**按字节还原**并校验 sha256。

为什么不用 git：本机没有可用的 git.exe（见 DETAILS §8），改动清单只能靠手工 patch。
所以这里把「还原」做成 sha256 断言，宁可脚本报错也不留下半改状态。
"""
import hashlib
import io
import os
import shutil
import subprocess
import sys

PROJ = r"C:\Users\WINDOWS\Desktop\GLory-work"
EXE = r"C:\Users\WINDOWS\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
TARGET = os.path.join(PROJ, "scripts", "battle", "BattleSimulator.gd")
BAK = os.path.join(PROJ, "work", "_qa_922", "_bisect_925_backup.gd")
PROBE = "work/_qa_922/probe_doom_thunder_924.tscn"

# 本轮加的 → 旧写法（反向）
PATCHES = [
    ("R1 relink 守卫",
     'if _is_boss_fighter(current) or _is_formation_ally_fighter(current):',
     'if _is_boss_fighter(current):'),
    ("R2 _nearest_non_boss 跳过条件",
     'or _is_formation_ally_fighter(o) or not _can_target(f, o, opponents):',
     'or not _can_target(f, o, opponents):'),
    ("R3 _link_targets_without_doom 过滤",
     '_is_unique_fighter(o) or _is_boss_fighter(o) or _is_formation_ally_fighter(o):',
     '_is_unique_fighter(o):'),
]


def sha(path: str) -> str:
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def run_probe(tag: str):
    out = os.path.join(PROJ, "work", "_qa_922", "bisect_%s.txt" % tag)
    with open(out, "w", encoding="utf-8", errors="replace") as fh:
        p = subprocess.run([EXE, "--headless", "--path", PROJ, PROBE],
                           capture_output=True, cwd=PROJ)
        fh.write(p.stdout.decode("utf-8", "replace"))
        fh.write(p.stderr.decode("utf-8", "replace"))
    txt = io.open(out, encoding="utf-8", errors="replace").read()
    done = [l.strip() for l in txt.splitlines() if "PROBE_DONE" in l]
    fails = [l.strip() for l in txt.splitlines() if "FAIL" in l]
    return p.returncode, (done[0] if done else "<no PROBE_DONE>"), fails


def main():
    base_sha = sha(TARGET)
    shutil.copy2(TARGET, BAK)
    print("[backup] %s -> %s" % (base_sha[:16], BAK))
    if sha(BAK) != base_sha:
        print("!! 备份校验失败，中止"); return 2

    src0 = io.open(TARGET, encoding="utf-8", newline="").read()
    results = []
    try:
        # 基线（未撤销任何东西）先跑一次
        rc, done, fails = run_probe("baseline")
        print("\n=== baseline（本轮全部改动在位）rc=%d %s" % (rc, done))
        for f in fails:
            print("     ", f)
        results.append(("baseline", rc, done, fails))

        cur = src0
        for i, (tag, new, old) in enumerate(PATCHES, 1):
            if new not in cur:
                print("\n!! 找不到锚点（%s）—— 说明仓里状态与预期不符，中止" % tag)
                return 3
            cur = cur.replace(new, old, 1)
            io.open(TARGET, "w", encoding="utf-8", newline="").write(cur)
            rc, done, fails = run_probe("rev%d" % i)
            print("\n=== 撤销 %s 之后 rc=%d %s" % (tag, rc, done))
            for f in fails:
                print("     ", f)
            results.append((tag, rc, done, fails))
    finally:
        shutil.copy2(BAK, TARGET)
        ok = sha(TARGET) == base_sha
        print("\n[restore] sha256 一致 = %s（%s）" % (ok, sha(TARGET)[:16]))
        try:
            os.remove(BAK)
            print("[restore] 已删除临时备份")
        except OSError:
            pass

    print("\n==== 汇总 ====")
    for tag, rc, done, fails in results:
        print("%-40s rc=%d %s" % (tag, rc, done))
    return 0 if sha(TARGET) == base_sha else 4


if __name__ == "__main__":
    sys.exit(main())
