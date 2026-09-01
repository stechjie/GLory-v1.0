#!/usr/bin/env python3
"""Safely unpack the device baseline tar produced by `run-as ... tar cf -`.

Why this is a separate file instead of an inline `python -c` inside
tools/android_baseline.sh:

  * The path-traversal checks have to run per member, which is long enough that
    an inline heredoc becomes unreadable and impossible to lint.
  * As a standalone script it can be pointed straight at a saved tar
    (device_retry.tar) and at hand-built fixtures, so the extraction logic can be
    proven without a phone and without running the whole baseline pipeline.

WHAT WENT WRONG BEFORE
----------------------
The shell used `tar xf ... 2>/dev/null || fail "device_extract_failed"`. Three
separate defects came out of that on 2026-08-30:

  1. On Windows/Git Bash the extraction failed, but `fail()` only appends to an
     array -- it does not exit. Execution fell through to `rm -f` and **deleted
     the only copy of the evidence**.
  2. With the tar gone, the manifest check then reported `device_manifest_missing`,
     and the comparison step reported `digest_incomparable`. One root cause,
     three misleading classifications.
  3. Extraction wrote straight into the round's `device/` directory, so a partial
     failure could leave a mix of this run's and the previous run's files.

So this script: extracts to a staging directory, validates what landed there,
and only then hands the staging path back for the caller to swap in. It never
deletes the source tar.

USAGE
    python tools/android_baseline_extract.py --tar <path> --staging <dir> \
        --rounds 1,5,20,21 [--json <path>]

EXIT CODES
    0  extracted and validated
    1  extraction or validation failed (details on stdout as JSON)
    2  bad invocation
"""

import argparse
import json
import os
import posixpath
import shutil
import sys
import tarfile

# Everything the device recorder writes lives under this prefix inside the tar.
# `run-as ... tar cf - files/battle_presentation_baseline` produces members like
#   files/battle_presentation_baseline/manifest.json
ALLOWED_PREFIX = "files/battle_presentation_baseline/"
# Members are re-rooted by dropping this many leading path components, matching
# the `--strip-components=2` the shell used to pass.
STRIP_COMPONENTS = 2


def _reject(member, reason):
    return {"name": member.name, "reason": reason}


def _safe_members(tar):
    """Yield (member, relative_path) for members that are safe to extract.

    Returns a second list of rejections so the caller can report *why* something
    was skipped instead of silently producing a short extraction.
    """
    kept, rejected = [], []
    for member in tar.getmembers():
        name = member.name.replace("\\", "/")
        # Absolute paths and drive letters never belong in this archive.
        if name.startswith("/") or (len(name) > 1 and name[1] == ":"):
            rejected.append(_reject(member, "absolute_path"))
            continue
        # Reject traversal before normalising, so `a/../../b` cannot sneak past.
        if any(part == ".." for part in name.split("/")):
            rejected.append(_reject(member, "parent_traversal"))
            continue
        # Symlinks and hardlinks can point anywhere; the recorder never writes them.
        if member.issym() or member.islnk():
            rejected.append(_reject(member, "link_member"))
            continue
        if not (member.isfile() or member.isdir()):
            rejected.append(_reject(member, "special_member"))
            continue
        # The archive root itself (`files/battle_presentation_baseline`, no
        # trailing slash) is a directory member with nothing to write. Skip it
        # quietly rather than listing it as a rejection -- a rejection list with
        # a benign entry in it sends whoever reads the report chasing a phantom.
        if name.rstrip("/") == ALLOWED_PREFIX.rstrip("/"):
            continue
        if not name.startswith(ALLOWED_PREFIX):
            rejected.append(_reject(member, "outside_allowed_prefix"))
            continue
        parts = name.split("/")[STRIP_COMPONENTS:]
        if not parts or parts == [""]:
            # The prefix directory itself. Nothing to write.
            continue
        rel = posixpath.join(*parts)
        kept.append((member, rel))
    return kept, rejected


def extract(tar_path, staging, rounds):
    result = {
        "tar": os.path.abspath(tar_path),
        "staging": os.path.abspath(staging),
        "rounds_requested": rounds,
        "ok": False,
        "code": "",
        "detail": "",
        "extracted_files": 0,
        "rejected_members": [],
        "missing": [],
    }

    if not os.path.isfile(tar_path):
        result["code"] = "tar_missing"
        result["detail"] = "tar 不存在：%s" % tar_path
        return result
    if os.path.getsize(tar_path) == 0:
        result["code"] = "tar_empty"
        result["detail"] = "tar 是空的（0 字节），设备侧多半没产出"
        return result

    # Fresh staging every time: a leftover directory is exactly how last run's
    # files get mixed into this run's verdict.
    if os.path.isdir(staging):
        shutil.rmtree(staging)
    os.makedirs(staging, exist_ok=True)

    try:
        # 'r:' = no transparent decompression guessing, and tarfile always reads
        # the stream in binary. The old failure mode was a text-mode/newline
        # conversion somewhere in the Windows shell path, not in tar itself.
        with tarfile.open(tar_path, "r:") as tar:
            kept, rejected = _safe_members(tar)
            result["rejected_members"] = rejected
            for member, rel in kept:
                target = os.path.join(staging, *rel.split("/"))
                # Belt and braces: the resolved path must stay inside staging.
                if not os.path.abspath(target).startswith(os.path.abspath(staging) + os.sep):
                    result["rejected_members"].append(_reject(member, "escapes_staging"))
                    continue
                if member.isdir():
                    os.makedirs(target, exist_ok=True)
                    continue
                os.makedirs(os.path.dirname(target), exist_ok=True)
                src = tar.extractfile(member)
                if src is None:
                    result["rejected_members"].append(_reject(member, "unreadable_member"))
                    continue
                with open(target, "wb") as dst:
                    shutil.copyfileobj(src, dst)
                result["extracted_files"] += 1
    except (tarfile.TarError, OSError) as exc:
        result["code"] = "device_extract_failed"
        result["detail"] = "解 tar 失败：%s（原始 tar 已保留）" % exc
        return result

    if result["extracted_files"] == 0:
        result["code"] = "device_extract_failed"
        result["detail"] = "tar 可读，但没有任何成员落在 %s 之下" % ALLOWED_PREFIX
        return result

    # Validation: manifest plus every requested round's hashes.json must exist.
    # Doing this here -- before the caller swaps staging into place -- is what
    # keeps `device_extract_failed` and `device_manifest_missing` mutually
    # exclusive instead of cascading.
    if not os.path.isfile(os.path.join(staging, "manifest.json")):
        result["code"] = "device_manifest_missing"
        result["detail"] = "解出来了，但没有 manifest.json，无法判定设备侧结果"
        return result
    for rnd in rounds:
        rel = os.path.join("round_%02d" % rnd, "hashes.json")
        if not os.path.isfile(os.path.join(staging, rel)):
            result["missing"].append(rel)
    if result["missing"]:
        result["code"] = "device_round_missing"
        result["detail"] = "缺少回合产物：%s" % ", ".join(result["missing"])
        return result

    result["ok"] = True
    result["code"] = "ok"
    result["detail"] = "解出 %d 个文件，manifest 与 %d 个回合的 hashes.json 齐全" % (
        result["extracted_files"], len(rounds))
    return result


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tar", required=True)
    parser.add_argument("--staging", required=True)
    parser.add_argument("--rounds", default="1")
    parser.add_argument("--json", default="")
    try:
        args = parser.parse_args(argv)
    except SystemExit:
        return 2

    rounds = []
    for part in args.rounds.split(","):
        part = part.strip()
        if part.isdigit():
            rounds.append(int(part))
    if not rounds:
        print(json.dumps({"ok": False, "code": "bad_rounds",
                          "detail": "--rounds 解析不出任何回合：%s" % args.rounds},
                         ensure_ascii=False))
        return 2

    result = extract(args.tar, args.staging, rounds)
    text = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True)
    print(text)
    if args.json:
        os.makedirs(os.path.dirname(os.path.abspath(args.json)), exist_ok=True)
        with open(args.json, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text + "\n")
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
