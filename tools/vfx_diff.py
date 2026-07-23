"""Compare two vfx_capture runs frame by frame and report per-skill drift.

    python tools/vfx_diff.py <baseline_dir> <current_dir> [--threshold 0.2]

Both directories are vfx_capture output: a flat frame00001.png sequence plus the
manifest.json that maps frame ranges back to skill ids.

Why a pixel diff rather than a vision model: the question this answers is "did my
refactor change the picture", not "does this look good". A numeric answer is
exact, instant and free; art judgement stays with a human.

Exit code is 1 when any skill drifts past the threshold, so this can gate a
commit or a build.
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image


def load_manifest(directory):
    path = os.path.join(directory, "manifest.json")
    if not os.path.exists(path):
        sys.exit("no manifest.json in %s - is that a vfx_capture output dir?" % directory)
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def frame_path(directory, index):
    """Godot's PNG movie writer pads the frame number to 8 digits."""
    for pattern in ("frame%08d.png", "frame%07d.png", "frame%05d.png"):
        candidate = os.path.join(directory, pattern % index)
        if os.path.exists(candidate):
            return candidate
    return None


def compare_frame(a_path, b_path):
    """Return (fraction of pixels differing, worst per-channel delta 0-1)."""
    a = np.asarray(Image.open(a_path).convert("RGB"), dtype=np.int16)
    b = np.asarray(Image.open(b_path).convert("RGB"), dtype=np.int16)
    if a.shape != b.shape:
        return 1.0, 1.0
    delta = np.abs(a - b)
    # A pixel counts as changed only past 2/255, so encoder dithering and
    # float rounding in the shaders do not read as a regression.
    changed = (delta.max(axis=2) > 2)
    return float(changed.mean()), float(delta.max()) / 255.0


def blank_check(directory, threshold):
    """Report skills that never change the picture - i.e. render nothing.

    Each skill's frames are compared against the last warmup frame, which shows
    the empty stage. A skill that stays at ~0% for every frame produced no
    visible output: usually a missing composer branch or a routing gap.
    """
    manifest = load_manifest(directory)
    fallback = manifest.get("empty_frame", manifest["warmup_frames"] - 1)

    blank = []
    rows = []
    for entry in manifest["skills"]:
        # 参照帧取本技能开播前的那一帧，而不是全局的空场景帧。舞台在长时间运行后
        # 会有极小的渲染漂移（实测约 0.09%，恒定），用全局参照会给每个技能垫一个
        # 底噪，把小特效误判成"没画面"。就近取参照可以完全消掉这个漂移。
        reference = frame_path(directory, entry["first_frame"] - 1) \
            or frame_path(directory, fallback)
        if reference is None:
            continue
        peak = 0.0
        for offset in range(entry["frame_count"]):
            path = frame_path(directory, entry["first_frame"] + offset)
            if path is None:
                continue
            fraction, _ = compare_frame(reference, path)
            peak = max(peak, fraction)
        rows.append((peak * 100.0, entry["skill_id"]))
        if peak * 100.0 <= threshold:
            blank.append(entry["skill_id"])

    rows.sort()
    print("%-30s %s" % ("skill", "peak coverage of frame"))
    print("-" * 56)
    for percent, skill_id in rows:
        mark = "  <-- RENDERS NOTHING" if percent <= threshold else ""
        print("%-30s %8.3f%%%s" % (skill_id, percent, mark))
    print()
    if blank:
        print("%d/%d skills render nothing: %s" % (len(blank), len(rows), ", ".join(sorted(blank))))
        return 1
    print("all %d skills produce visible output" % len(rows))
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline")
    parser.add_argument("current", nargs="?",
                        help="omit to run a blank-check on the baseline dir instead of a diff")
    parser.add_argument("--threshold", type=float, default=0.2,
                        help="percent of pixels allowed to differ before a skill is flagged")
    parser.add_argument("--quiet", action="store_true", help="only print flagged skills")
    args = parser.parse_args()

    if args.current is None:
        return blank_check(args.baseline, args.threshold)

    base_manifest = load_manifest(args.baseline)
    curr_manifest = load_manifest(args.current)

    base_skills = {s["skill_id"]: s for s in base_manifest["skills"]}
    curr_skills = {s["skill_id"]: s for s in curr_manifest["skills"]}

    added = sorted(set(curr_skills) - set(base_skills))
    removed = sorted(set(base_skills) - set(curr_skills))
    if added:
        print("new skills (no baseline yet): %s" % ", ".join(added))
    if removed:
        print("skills gone from current run: %s" % ", ".join(removed))

    if base_manifest.get("quality_tier") != curr_manifest.get("quality_tier"):
        print("WARNING: quality tier differs (%s vs %s) - effects are capped differently, "
              "so a diff here is expected." % (
                  base_manifest.get("quality_tier"), curr_manifest.get("quality_tier")))

    flagged = []
    missing = 0
    rows = []
    for skill_id in sorted(set(base_skills) & set(curr_skills)):
        base = base_skills[skill_id]
        curr = curr_skills[skill_id]
        worst_fraction = 0.0
        worst_delta = 0.0
        worst_frame = 0
        compared = 0
        for offset in range(min(base["frame_count"], curr["frame_count"])):
            a = frame_path(args.baseline, base["first_frame"] + offset)
            b = frame_path(args.current, curr["first_frame"] + offset)
            if a is None or b is None:
                missing += 1
                continue
            fraction, delta = compare_frame(a, b)
            compared += 1
            if fraction > worst_fraction:
                worst_fraction, worst_delta, worst_frame = fraction, delta, offset
        if compared == 0:
            continue
        percent = worst_fraction * 100.0
        rows.append((percent, skill_id, worst_frame, worst_delta))
        if percent > args.threshold:
            flagged.append(skill_id)

    rows.sort(reverse=True)
    print()
    print("%-30s %9s %7s %s" % ("skill", "changed", "frame", "max delta"))
    print("-" * 62)
    for percent, skill_id, worst_frame, worst_delta in rows:
        if args.quiet and percent <= args.threshold:
            continue
        mark = "  <-- CHANGED" if percent > args.threshold else ""
        print("%-30s %8.3f%% %7d %8.3f%s" % (skill_id, percent, worst_frame, worst_delta, mark))

    print()
    if missing:
        print("%d frame pairs could not be compared (file missing)" % missing)
    if flagged:
        print("%d/%d skills changed beyond %.2f%%: %s" % (
            len(flagged), len(rows), args.threshold, ", ".join(flagged)))
        return 1
    print("all %d skills within %.2f%% - no visual regression" % (len(rows), args.threshold))
    return 0


if __name__ == "__main__":
    sys.exit(main())
