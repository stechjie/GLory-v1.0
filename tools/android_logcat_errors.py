#!/usr/bin/env python3
"""Classify Godot runtime errors in a device logcat and fail if any are real.

WHY THIS EXISTS
---------------
On 2026-08-30 the Android baseline reported PASS: the device manifest said
`passed=true` and all five replay digests matched the desktop run. Meanwhile the
logcat held 135 copies of

    ERROR: The object does not have any 'meta' values with the key 'lunge_tween'.

Digest equality says "both platforms computed the same result". It says nothing
about whether the run printed errors while doing it. Neither may stand in for the
other, so this check is deliberately independent of the digest comparison.

WHY NOT JUST GREP FOR "ERROR"
-----------------------------
Godot prints benign lines at shutdown that are not defects:

    ERROR: 1 resources still in use at exit
    ERROR: N RID allocations of type '...' were leaked at exit
    WARNING: N ObjectDB instances were leaked at exit

A blanket match turns those into red, and a gate that goes red for a known
harmless reason is one people learn to ignore -- which is how the real 135 got
missed in the first place. So teardown noise is classified separately and
reported, not failed on. Warnings are never failures.

USAGE
    LOGCAT=<path> [OUT_JSON=<path>] python tools/android_logcat_errors.py

    Prints a one-line human summary on stdout.
    Exit 0 = no real errors; 1 = real errors found; 2 = bad invocation.
"""

import io
import json
import os
import re
import sys

# Lines that are Godot shutdown bookkeeping rather than defects. Matched against
# the message body, case-sensitive, as substrings.
TEARDOWN_MARKERS = (
    "resources still in use at exit",
    "were leaked at exit",
    "ObjectDB instances were leaked",
    "RID allocations of type",
)

# Signals that the process died rather than merely complained.
FATAL_PATTERNS = (
    re.compile(r"\bFATAL EXCEPTION\b"),
    re.compile(r"\bsignal\s+\d+\s+\(SIG[A-Z]+\)"),
    re.compile(r"\bFatal signal\b"),
    re.compile(r"\bANR in\b"),
)

SCRIPT_ERROR = re.compile(r"SCRIPT ERROR:\s*(.*)")
PLAIN_ERROR = re.compile(r"(?<!SCRIPT )\bERROR:\s*(.*)")


def _is_teardown(message):
    return any(marker in message for marker in TEARDOWN_MARKERS)


def classify(text):
    result = {
        "script_errors": 0,
        "runtime_errors": 0,
        "fatal": 0,
        "teardown_noise": 0,
        "by_message": {},
        "fatal_lines": [],
    }
    for raw in text.splitlines():
        line = raw.rstrip()
        if any(pattern.search(line) for pattern in FATAL_PATTERNS):
            result["fatal"] += 1
            if len(result["fatal_lines"]) < 5:
                result["fatal_lines"].append(line.strip()[:200])
            continue
        match = SCRIPT_ERROR.search(line)
        kind = None
        if match:
            kind = "script_errors"
        else:
            match = PLAIN_ERROR.search(line)
            if match:
                kind = "runtime_errors"
        if kind is None:
            continue
        message = match.group(1).strip()
        if _is_teardown(message):
            result["teardown_noise"] += 1
            continue
        result[kind] += 1
        # Group by message so a report says "135 x one bug", not "135 problems".
        key = message[:160]
        result["by_message"][key] = result["by_message"].get(key, 0) + 1
    return result


def main():
    log_path = os.environ.get("LOGCAT", "")
    if not log_path:
        print("bad_invocation: 需要环境变量 LOGCAT=<logcat 文件路径>")
        return 2
    if not os.path.isfile(log_path):
        print("bad_invocation: 读不到 %s" % log_path)
        return 2

    with io.open(log_path, encoding="utf-8", errors="replace") as handle:
        result = classify(handle.read())

    result["log"] = os.path.abspath(log_path)
    real = result["script_errors"] + result["runtime_errors"] + result["fatal"]
    result["real_error_total"] = real
    result["passed"] = real == 0

    out_json = os.environ.get("OUT_JSON", "")
    if out_json:
        os.makedirs(os.path.dirname(os.path.abspath(out_json)), exist_ok=True)
        with io.open(out_json, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    if real == 0:
        print("0 Godot ERROR（退出期噪声 %d 条，不计）" % result["teardown_noise"])
        return 0

    top = sorted(result["by_message"].items(), key=lambda kv: -kv[1])[:3]
    detail = "; ".join("%d x %s" % (count, msg[:70]) for msg, count in top)
    print("script=%d runtime=%d fatal=%d -> %s" % (
        result["script_errors"], result["runtime_errors"], result["fatal"], detail))
    return 1


if __name__ == "__main__":
    sys.exit(main())
