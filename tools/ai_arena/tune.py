"""对战台调参：在某一档参数附近试几组，和对手档打，留下确实更强的（2026-11-07）。

    python tools/ai_arena/tune.py --level 5 --rival L4 --candidates 12 --seeds 20 --jobs 10
    python tools/ai_arena/tune.py --level 3 --rival L2 --try tools/ai_arena/tries_l3.json --confirm-seeds 40

每个候选写成一份覆盖文件（只改这一档），对战台用 --override 读进去，不动 data/ai/bot_profiles.json。
同一批种子打所有候选（共同随机数），候选之间才可比。

候选来源：先是原参数，再是 --try 文件里点名要试的（一个列表，每项是要改的字段），最后是随机改几项的。

复核（--confirm-seeds）：十几个候选里挑胜率最高的，本身就会挑中「运气好」的那组。所以选出前几名后，
换一批没用过的种子再打一遍（原参数一起打，作对照），以复核那一批的结果为准。

结果在 reports/ai_arena/tune_<时间>/：
    results.json   每个候选的参数和胜率（带 95% 区间），复核结果在 confirm 字段
    best.json      复核后胜率最高、且区间下限 > 50% 的那一组（没有就不写）
确认之后再手动并进 bot_profiles.json —— 这里不自动改线上配置。

10 个进程一组 20 个种子约 4–5 分钟（插电）。
"""
from __future__ import annotations

import argparse
import json
import random
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROFILES = ROOT / "data" / "ai" / "bot_profiles.json"

# 只搜「决策方式」，不碰任何战斗数值。每项是可选值列表。
SPACE = {
    "merge_weight": [0.8, 1.2, 1.6, 2.0, 2.5],
    "owned_bonus": [1.2, 1.6, 2.0, 2.6],
    "pivot_margin": [1.15, 1.3, 1.6, 99.0],
    "reserve": ["interest", "plan", "flat"],
    "flat_reserve": [0, 30, 80],
    "refresh_margin": [0, 20, 40, 80],
    "max_refresh": [4, 6, 8, 12],
    "tech_cap": [2, 3, 4, 5],
    "tech_margin": [40, 80, 160],
    "carrots": ["plan", "plan_rounds", "pack", "greedy"],
    "stone_draw": [True, False],
    "four_star": ["value", "greedy", "none"],
    "formation": ["role", "basic"],
    "buy_threshold": [0.0, 0.3, 0.8],
    "impulse": [0.0, 0.1, 0.25],
    "synergy_knowledge": [1, 2],
}


def mutate(base: dict, rng: random.Random, changes: int) -> dict:
    out = dict(base)
    for key in rng.sample(sorted(SPACE), changes):
        out[key] = rng.choice(SPACE[key])
    return out


def run_pair(level: int, rival: str, override: Path, seeds: int, seed_base: int, jobs: int, godot: str | None) -> dict:
    cmd = [sys.executable, str(ROOT / "tools" / "ai_arena" / "run_arena.py"), "--a", f"L{level}", "--b", rival,
           "--seeds", str(seeds), "--seed-base", str(seed_base), "--jobs", str(jobs), "--override", str(override)]
    if godot:
        cmd += ["--godot", godot]
    text = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace").stdout
    start, end = text.find("{"), text.rfind("}")
    return json.loads(text[start:end + 1]) if start >= 0 else {"error": text[-2000:]}


def brief(summary: dict, level: int) -> dict:
    """每个候选只留几项能看出「钱花到哪去了」的平均数。"""
    mine = summary.get("policies", {}).get(f"L{level}", {})
    return {k: mine.get(k) for k in ("three_star", "four_star", "stone_draws", "carrot_spent", "unspent", "tech")}


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--level", type=int, required=True)
    parser.add_argument("--rival", required=True, help="对手：L1..L5 或 legacy")
    parser.add_argument("--candidates", type=int, default=12, help="随机候选个数（不含原参数和 --try）")
    parser.add_argument("--changes", type=int, default=3, help="每个随机候选改几项")
    parser.add_argument("--try", dest="tries", help="点名要试的候选：JSON 列表，每项是要改的字段")
    parser.add_argument("--no-base", action="store_true", help="不打原参数（同一批种子已经打过，结果是确定的）")
    parser.add_argument("--seeds", type=int, default=20)
    parser.add_argument("--seed-base", type=int, default=70000)
    parser.add_argument("--confirm-seeds", type=int, default=0, help="复核用的种子数；0 = 不复核")
    parser.add_argument("--confirm-seed-base", type=int, default=90000)
    parser.add_argument("--confirm-top", type=int, default=2, help="复核前几名")
    parser.add_argument("--jobs", type=int, default=10)
    parser.add_argument("--rng", type=int, default=1107)
    parser.add_argument("--godot")
    args = parser.parse_args()

    profiles = json.loads(PROFILES.read_text(encoding="utf-8"))
    base = dict(profiles["levels"][str(args.level)])
    run_dir = ROOT / "reports" / "ai_arena" / time.strftime(f"tune_%Y%m%d_%H%M%S_L{args.level}_vs_{args.rival}")
    run_dir.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.rng)
    candidates = [] if args.no_base else [base]
    if args.tries:
        for change in json.loads(Path(args.tries).read_text(encoding="utf-8")):
            unknown = sorted(set(change) - set(base))
            if unknown:
                sys.exit(f"--try 里有这一档没有的字段：{unknown}")
            candidates.append({**base, **change})
    candidates += [mutate(base, rng, args.changes) for _ in range(args.candidates)]

    def override_for(index: int) -> Path:
        path = run_dir / f"candidate_{index:02d}.json"
        path.write_text(json.dumps({str(args.level): candidates[index]}, ensure_ascii=False, indent=2), encoding="utf-8")
        return path

    def save() -> None:
        (run_dir / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")

    results = []
    for index, params in enumerate(candidates):
        summary = run_pair(args.level, args.rival, override_for(index), args.seeds, args.seed_base, args.jobs, args.godot)
        diff = {k: v for k, v in params.items() if base.get(k) != v}
        row = {"index": index, "changes": diff, "win_rate": summary.get("a_win_rate"),
               "ci95": summary.get("a_win_ci95"), "matches": summary.get("matches"),
               "stats": brief(summary, args.level), "error": summary.get("error")}
        results.append(row)
        print(f"[tune] #{index:02d} win={row['win_rate']} ci={row['ci95']} changes={diff} stats={row['stats']}", flush=True)
        save()

    pool = [r for r in results if r["win_rate"] is not None]
    if args.confirm_seeds > 0:
        top = sorted((r for r in pool if r["changes"]), key=lambda r: r["win_rate"], reverse=True)[:args.confirm_top]
        for row in [r for r in results if not r["changes"]] + top:
            summary = run_pair(args.level, args.rival, override_for(row["index"]), args.confirm_seeds,
                               args.confirm_seed_base, args.jobs, args.godot)
            row["confirm"] = {"win_rate": summary.get("a_win_rate"), "ci95": summary.get("a_win_ci95"),
                              "matches": summary.get("matches"), "stats": brief(summary, args.level)}
            print(f"[tune] 复核 #{row['index']:02d} win={row['confirm']['win_rate']} ci={row['confirm']['ci95']}", flush=True)
            save()
        pool = [r for r in results if r.get("confirm", {}).get("win_rate") is not None]
        key = lambda r: r["confirm"]
    else:
        key = lambda r: r
    ok = [r for r in pool if key(r)["ci95"] and key(r)["ci95"][0] > 0.5]
    if ok:
        best = max(ok, key=lambda r: key(r)["win_rate"])
        (run_dir / "best.json").write_text(json.dumps({"level": args.level, "rival": args.rival, **best,
            "params": candidates[best["index"]]}, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"[tune] best #{best['index']:02d} win={key(best)['win_rate']} ci={key(best)['ci95']}")
    else:
        print("[tune] 没有候选的区间下限超过 50%：这一档在这组对手面前还没找到确实更强的参数")
    print(f"[tune] {run_dir}")


if __name__ == "__main__":
    main()
