"""并行跑 AI 对战台，汇总胜率（2026-11-07）。

一个 Godot 进程一次只能跑一局，一局约 25 秒（MSI 插电、单进程；用电池时 CPU 降频，慢 2~4 倍）。这里把种子切成几段、
同时开几个 headless 进程，最后合并 JSON、按「同一个种子两边各打一次」配对统计。

用法：
    python tools/ai_arena/run_arena.py --a L3 --b legacy --seeds 200 --jobs 12
    python tools/ai_arena/run_arena.py --a L3 --b L2 --seeds 400 --seed-base 50000

Godot 路径依次取：--godot、环境变量 GODOT、tools/godot_path.txt。
结果写在 reports/ai_arena/（已被 git 忽略）。
"""
from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCENE = "res://tools/ai_arena/ai_arena.tscn"


def godot_path(cli: str | None) -> str:
    if cli:
        return cli
    if os.environ.get("GODOT"):
        return os.environ["GODOT"]
    hint = ROOT / "tools" / "godot_path.txt"
    if hint.exists():
        return hint.read_text(encoding="utf-8").strip()
    sys.exit("找不到 Godot：传 --godot、设环境变量 GODOT，或写 tools/godot_path.txt")


def wilson(wins: float, n: int, z: float = 1.96) -> tuple[float, float]:
    if n == 0:
        return 0.0, 0.0
    p = wins / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    return centre - half, centre + half


def summarise(matches: list[dict], a: str, b: str) -> dict:
    per_policy: dict[str, dict] = {}
    score = {a: 0.0, b: 0.0}
    for m in matches:
        if m["winner"] == "draw":
            score[a] += 0.5
            score[b] += 0.5
        else:
            score[m["winner"]] = score.get(m["winner"], 0.0) + 1.0
        for seat in m["seats"]:
            p = per_policy.setdefault(seat["policy"], {
                "seats": 0, "stone_draws": 0, "four_star": 0, "three_star": 0, "unspent": 0,
                "top_race": 0, "carrot_spent": 0, "tech": 0, "treasures": 0})
            p["seats"] += 1
            p["stone_draws"] += seat["stone_draws"]
            p["four_star"] += int(seat["stars"].get("4", 0))
            p["three_star"] += int(seat["stars"].get("3", 0))
            p["unspent"] += seat["unspent_last_prep"]
            p["top_race"] += seat["top_race_on_board"]
            p["carrot_spent"] += seat["carrot_spent"]
            p["tech"] += seat["tech"]
            p["treasures"] += seat["treasures"]
    n = len(matches)
    out = {"matches": n, "score": score, "policies": {}}
    for name, p in per_policy.items():
        seats = max(1, p["seats"])
        out["policies"][name] = {k: round(v / seats, 3) for k, v in p.items() if k != "seats"}
    if a != b and n:
        lo, hi = wilson(score[a], n)
        out["a_win_rate"] = round(score[a] / n, 3)
        out["a_win_ci95"] = [round(lo, 3), round(hi, 3)]
    out["mean_rounds"] = round(sum(m["rounds_played"] for m in matches) / max(1, n), 2)
    out["mean_wall_ms"] = round(sum(m["wall_ms"] for m in matches) / max(1, n))
    return out


def main() -> None:
    # Windows 控制台默认 cp1252，路径里的「桌面」会让 print 直接抛错。
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--a", required=True)
    parser.add_argument("--b", required=True)
    parser.add_argument("--seeds", type=int, default=20, help="种子数；开 swap 时每个种子打两局")
    parser.add_argument("--seed-base", type=int, default=10000)
    parser.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    parser.add_argument("--no-swap", action="store_true")
    parser.add_argument("--godot")
    parser.add_argument("--override", help="档位参数覆盖文件（tune.py 用），形如 {\"5\": {...}}")
    parser.add_argument("--out-dir", default=str(ROOT / "reports" / "ai_arena"))
    args = parser.parse_args()

    exe = godot_path(args.godot)
    stamp = time.strftime("%Y%m%d_%H%M%S")
    run_dir = Path(args.out_dir) / f"{stamp}_{args.a}_vs_{args.b}"
    run_dir.mkdir(parents=True, exist_ok=True)
    jobs = max(1, min(args.jobs, args.seeds))
    per = math.ceil(args.seeds / jobs)
    procs = []
    started = time.time()
    for j in range(jobs):
        first = args.seed_base + j * per
        count = min(per, args.seed_base + args.seeds - first)
        if count <= 0:
            break
        out = run_dir / f"part_{j:02d}.json"
        cmd = [exe, "--headless", "--path", str(ROOT), SCENE, "--",
               f"--a={args.a}", f"--b={args.b}", f"--seed={first}", f"--count={count}",
               f"--swap={'0' if args.no_swap else '1'}", f"--out={out.as_posix()}"]
        if args.override:
            cmd.append(f"--override={Path(args.override).resolve().as_posix()}")
        log = open(run_dir / f"part_{j:02d}.log", "w", encoding="utf-8", errors="replace")
        procs.append((subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT), out, log))
    failed = 0
    matches: list[dict] = []
    for proc, out, log in procs:
        proc.wait()
        log.close()
        if proc.returncode != 0 or not out.exists():
            failed += 1
            print(f"[run_arena] 分段失败：{out.name}（退出码 {proc.returncode}），看同名 .log")
            continue
        matches.extend(json.loads(out.read_text(encoding="utf-8"))["matches"])
    summary = summarise(matches, args.a, args.b)
    summary["wall_sec"] = round(time.time() - started, 1)
    summary["failed_parts"] = failed
    (run_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"[run_arena] {run_dir}")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
