#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 P0-01 / work package C-04: read-only startup cost accounting.

Parses GLORY_STARTUP marks out of the captured device and desktop logs and
attributes T0 -> T3 to named segments. It changes nothing: StartupTrace.gd,
project.godot, the autoloads and the main scene are all read-only here.

The point is to stop guessing. Before this, "startup is slow" had one popular
suspect (VFX warmup) and the numbers below show that suspect contributes
literally zero to T0 -> T3, while 72% of it happens before a single line of
game code runs.

Usage:  python tools/startup_cost_breakdown.py [--evidence DIR] [--json OUT]
"""

import argparse
import collections
import datetime
import glob
import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_EVIDENCE = r"C:\Users\Leno\Documents\Glory prep screen"
DEFAULT_JSON = os.path.join(ROOT, "reports", "startup_cost_breakdown.json")

LINE = re.compile(r"GLORY_STARTUP (\{.*?\})\s*$")

T0 = "t0_trace_ready"
T1 = "t1_first_frame"
T2 = "t2_godot_main_ready"
T3 = "t3_first_input_ready"

# Each segment is (from_mark, to_mark, id, what actually runs in it).
SEGMENTS = [
    ("__process_start__", T0, "engine_boot",
     "Godot 引擎自身启动：初始化、挂载 .pck、建立 import 与 UID 表。"
     "StartupTrace 是第一个 autoload，所以这一段里没有任何本工程代码运行。"),
    (T0, "data_registry_loaded", "early_autoloads",
     "StartupTrace -> LocaleManager -> GameState -> DataRegistry 四个 autoload 的构造与 _ready。"
     "DataRegistry 自己的解析耗时由它的 mark 直接报出来。"),
    ("data_registry_loaded", T2, "dark_region",
     "从 DataRegistry 读完到 Main._ready() 结束。这一段内部没有任何埋点 —— "
     "它同时包含剩余 12 个 autoload 的脚本编译与 _ready、Main.tscn 的加载，以及 Main._ready() 本身。"),
    (T2, T3, "main_ready_to_input",
     "Main._ready() 之后到语言页控件真正可点。_show_language_select() 是纯代码建 UI，不加载场景。"),
    (T3, T1, "input_to_first_frame",
     "可交互到第一帧真正呈现。没有 Bootstrap 场景时 T1 落在最后，这是预期的（见 StartupTrace.ORDERED_MARKS 注释）。"),
]

# Everything the dark region can plausibly contain, with a citable location.
# Sizes are a proxy for GDScript compile cost, which is paid at load time.
DARK_REGION_CANDIDATES = [
    ("scripts/autoload/PlayerProfile.gd", 28,
     "_ready() -> load_profile()：FileAccess + JSON.parse；首次运行还会 save_profile() 写盘"),
    ("scripts/autoload/NetworkService.gd", 281,
     "4273 行 / 206 KB / 13 个 preload。_ready() 里 configure 六个子服务。"
     "脚本编译与 preload 链解析都在这一段里付账，而不是在 _ready() 里"),
    ("effects/VFXManager.gd", 25,
     "_ready() -> _detect_quality_tier()：读画质偏好 + OS.get_memory_info()"),
    ("scripts/tutorial/TutorialMode.gd", 0,
     "926 行 / 37 KB，无 _ready，成本在脚本编译"),
    ("scripts/autoload/IssueReport.gd", 61,
     "_ready() -> _schedule_auto_capture()"),
    ("scripts/autoload/DeviceHarness.gd", 0,
     "_ready 读 user://device_harness.json 触发文件（无 --device-baseline 时直接返回）"),
    ("scenes/main/Main.gd", 15,
     "Main.tscn 加载 + Main._ready()：DataRegistry.ensure_loaded()（幂等）、"
     "7 个 NetworkService 信号连接、TutorialMode 连接、_start_vfx_warmup()、_show_language_select()"),
]


# A baseline/QA run is not a player launch. DeviceHarness says so in plain text,
# and the difference is not cosmetic: it inflates T2 -> T3 by roughly 35x, so
# mixing the two would send anyone optimising straight at the wrong segment.
HARNESS_ACTIVE = "[DEVICE_HARNESS] 已接管本次启动"
HARNESS_IDLE = "[DEVICE_HARNESS] 未接管"


def parse_log(path):
    marks = {}
    order = []
    dups = []
    harness = None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                if harness is None:
                    if HARNESS_ACTIVE in raw:
                        harness = True
                    elif HARNESS_IDLE in raw:
                        harness = False
                m = LINE.search(raw.rstrip("\n"))
                if not m:
                    continue
                try:
                    payload = json.loads(m.group(1))
                except ValueError:
                    continue
                name = str(payload.get("mark", ""))
                if not name:
                    continue
                if "duplicate_of_ms" in payload:
                    dups.append({"mark": name, "ms": int(payload.get("ms", 0)),
                                 "first_ms": int(payload["duplicate_of_ms"]),
                                 "meta": payload.get("meta", {})})
                    continue
                if name in marks:
                    continue
                marks[name] = {"ms": int(payload.get("ms", 0)),
                               "meta": payload.get("meta", {})}
                order.append(name)
    except OSError:
        return None
    if T0 not in marks:
        return None
    return {"marks": marks, "order": order, "duplicates": dups,
            "harness_took_over": harness}


def run_fingerprint(marks):
    """Identity of a launch, from its mark timestamps.

    android_smoke.sh saves the same capture twice — logcat_full.log and
    logcat_godot.log, the second being the first filtered — so a naive glob
    counts every smoke launch twice and reports a sample twice as strong as it
    is. Marks carry millisecond timestamps, so an identical set across two files
    means one launch written down twice, never two launches that happened to
    agree.
    """
    return hashlib.sha256(json.dumps(marks, sort_keys=True).encode()).hexdigest()


def dedupe(runs):
    """Collapse logs that describe the same launch. Returns (kept, dropped)."""
    seen = {}
    kept = []
    dropped = []
    for r in runs:
        fp = run_fingerprint(r["marks"])
        if fp in seen:
            first = seen[fp]
            dropped.append({
                "log": r["log"],
                "duplicate_of": first["log"],
                "fingerprint": fp[:16],
                # Same directory means the smoke script's two captures. Different
                # directories means an evidence folder was copied, which is worth
                # knowing about rather than silently merging.
                "same_directory": os.path.dirname(r["log"]) == os.path.dirname(first["log"]),
            })
            continue
        seen[fp] = r
        r["fingerprint"] = fp[:16]
        kept.append(r)
    return kept, dropped


def platform_of(path):
    low = path.replace("\\", "/").lower()
    if "desktop" in low:
        return "desktop"
    if "logcat" in low or "device" in low:
        return "device"
    return "unknown"


def breakdown(run):
    marks = run["marks"]
    out = []
    for src, dst, seg_id, what in SEGMENTS:
        if dst not in marks:
            continue
        start = 0 if src == "__process_start__" else marks.get(src, {}).get("ms")
        if start is None:
            continue
        end = marks[dst]["ms"]
        out.append({
            "id": seg_id, "from": src, "to": dst,
            "start_ms": start, "end_ms": end, "duration_ms": end - start,
            "what": what,
        })
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--evidence", default=DEFAULT_EVIDENCE)
    ap.add_argument("--json", default=DEFAULT_JSON)
    args = ap.parse_args()

    runs = []
    for path in sorted(glob.glob(os.path.join(args.evidence, "**", "*.log"), recursive=True)):
        parsed = parse_log(path)
        if parsed is None:
            continue
        marks = parsed["marks"]
        runs.append({
            "log": os.path.relpath(path, args.evidence).replace("\\", "/"),
            "platform": platform_of(path),
            "marks": {k: v["ms"] for k, v in marks.items()},
            "mark_meta": {k: v["meta"] for k, v in marks.items() if v["meta"]},
            "duplicates": parsed["duplicates"],
            "harness_took_over": parsed["harness_took_over"],
            "segments": breakdown(parsed),
            "reached_input_ready": T3 in marks,
        })

    all_logs = len(runs)
    runs, duplicate_logs = dedupe(runs)

    device = [r for r in runs if r["platform"] == "device" and r["reached_input_ready"]]
    # The only population that describes what a player experiences.
    player = [r for r in device if r["harness_took_over"] is False]
    harness = [r for r in device if r["harness_took_over"] is True]
    desktop = [r for r in runs if r["platform"] == "desktop"]

    def stat(rows, seg_id):
        vals = sorted(s["duration_ms"] for r in rows for s in r["segments"]
                      if s["id"] == seg_id)
        if not vals:
            return None
        n = len(vals)
        median = vals[n // 2] if n % 2 else (vals[n // 2 - 1] + vals[n // 2]) // 2
        out = {"n": n, "min_ms": vals[0], "max_ms": vals[-1], "median_ms": median}
        # With a handful of launches a median hides more than it shows, so carry
        # the raw values too and let the reader see the spread.
        if n <= 4:
            out["values_ms"] = vals
        return out

    summary = {}
    for _src, _dst, seg_id, what in SEGMENTS:
        summary[seg_id] = {"what": what, "device": stat(device, seg_id),
                           "player_launch": stat(player, seg_id),
                           "harness_run": stat(harness, seg_id),
                           "desktop": stat(desktop, seg_id)}

    # Share of T0->T3 that each segment owns, on the device runs.
    shares = []
    for r in (player or device):
        t3 = r["marks"].get(T3)
        if not t3:
            continue
        for s in r["segments"]:
            if s["id"] in ("engine_boot", "early_autoloads", "dark_region",
                           "main_ready_to_input"):
                shares.append((s["id"], 100.0 * s["duration_ms"] / t3))
    agg = collections.defaultdict(list)
    for seg_id, pct in shares:
        agg[seg_id].append(pct)
    share_of_t3 = {k: round(sum(v) / len(v), 1) for k, v in agg.items()}

    doc = {
        "schema": "glory.startup_cost_breakdown/1",
        "generated_at": datetime.datetime.now(datetime.timezone.utc)
            .replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "generator": "tools/startup_cost_breakdown.py",
        "read_only": True,
        "evidence_root": args.evidence,
        "logs_parsed": all_logs,
        "runs_parsed": len(runs),
        "duplicate_logs_dropped": duplicate_logs,
        "device_runs_with_input_ready": len(device),
        "player_launch_runs": len(player),
        "harness_runs": len(harness),
        "share_basis": "player_launch" if player else "all_device_runs",
        "segment_summary": summary,
        "share_of_t3_percent_device": share_of_t3,
        "dark_region_candidates": [
            {"file": f, "line": ln, "note": note} for f, ln, note in DARK_REGION_CANDIDATES
        ],
        "runs": runs,
    }

    os.makedirs(os.path.dirname(args.json), exist_ok=True)
    with open(args.json, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    print("STARTUP_BREAKDOWN logs=%d runs=%d (dropped %d duplicate log(s)) "
          "device_with_t3=%d player=%d harness=%d"
          % (all_logs, len(runs), len(duplicate_logs), len(device),
             len(player), len(harness)))
    for d in duplicate_logs:
        print("  dup: %s  == %s%s" % (d["log"], d["duplicate_of"],
              "" if d["same_directory"] else "   [!] 不同目录，可能是证据目录被复制过"))
    for _src, _dst, seg_id, _what in SEGMENTS:
        p = summary[seg_id]["player_launch"]
        h = summary[seg_id]["harness_run"]
        if p:
            shown = ("/".join(str(v) for v in p["values_ms"])
                     if "values_ms" in p else "%d" % p["median_ms"])
            print("  %-22s player n=%d %14s ms  share_of_T3=%5s%%   harness median=%s"
                  % (seg_id, p["n"], shown, share_of_t3.get(seg_id, "-"),
                     ("%d ms" % h["median_ms"]) if h else "n/a"))
    print("  player launches:")
    for r in player:
        print("    %s  T3=%d ms" % (r["log"], r["marks"].get(T3, -1)))
    print("  -> %s" % os.path.relpath(args.json, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
