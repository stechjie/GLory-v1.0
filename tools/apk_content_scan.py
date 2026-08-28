#!/usr/bin/env python3
"""Reject an APK that ships things a release build has no business carrying.

Run it standalone against any APK on disk -- no device needed:

    python tools/apk_content_scan.py "../android V 3/GloryBetaV10.apk"

Exit codes: 0 clean; 1 violations found; 2 bad invocation.

WHAT THIS IS, AND WHAT IT IS NOT
--------------------------------
The V2 review asked for a scan that rejects `*_prechange_backup_*`, device
evidence directories, the server zip and raw FBX. Measured against the APK built
on 2026-08-21 (3690 entries), every one of those patterns has **zero** hits. The
reason is not `exclude_filter` -- it is that each of the ~19 backup/evidence
directories carries a `.gdignore`, so Godot never indexes them at all.

So this is a *regression* gate, not a repair. The pattern list stays because a
directory added tomorrow without a `.gdignore` would ship, and the allowed-roots
check below is the net that actually catches that case: it fails on any res://
top-level directory that is not on the known list, whether or not its name
happens to match a pattern.

HOW GODOT LAYS OUT AN ANDROID APK
---------------------------------
Resources land under `assets/`, keeping their res:// path
(`assets/scripts/...`, `assets/assets/models/...`), while imported artifacts are
flattened into `assets/.godot/imported/<name>-<hash>.<ext>`. Scripts ship as
`.gdc` + `.remap`; source `.fbx`/`.glb` are not exported at all, only the
imported `.scn`. That is why the root check strips one leading `assets/` segment
and skips `.godot`.
"""

import argparse
import json
import os
import re
import sys
import zipfile

# res:// top-level directories observed in the 2026-08-21 build. Anything outside
# this set is a finding: either something new is being shipped on purpose (add it
# here, with a reason) or a directory lost its .gdignore.
ALLOWED_ROOTS = {
    "assets",
    "data",
    "effects",
    "officetest",
    "scenes",
    "scripts",
    "shaders",
    "tools",
}

# Roots that ship today and arguably should not, recorded so the report says so
# out loud instead of quietly passing. Not failures: excluding tools/ outright
# would break the build, because two autoloads live there.
KNOWN_SHIPPING_NOTES = {
    "tools": (
        "QA tooling ships in the APK (~194 entries). Cannot simply be excluded: "
        "tools/PerfLog.gd and tools/DeviceHarness.gd are autoloads, so dropping "
        "the directory stops the game from booting. Needs the autoloads moved "
        "out first -- tracked as a later batch, not a scan failure."
    ),
    "officetest": (
        "Offline self-test screen ships in the APK (~8 entries). Reachable only "
        "from a debug path; harmless but unnecessary in a release build."
    ),
}

# Substring/regex patterns that must never appear in a shipped APK.
FORBIDDEN_PATTERNS = [
    ("prechange_backup", r"_prechange_backup_"),
    ("device_evidence", r"_device_battle_|_android_smoke_|device_evidence"),
    ("baseline_evidence", r"_battle_presentation_\w+_20\d{6}|E1_D0_|verified_[0-9a-f]{7}"),
    ("server_archive", r"glory_server[^/]*\.zip$"),
    ("signing_material", r"\.(keystore|jks|p12|pem)$"),
    ("raw_model_source", r"\.(fbx|glb|blend)$"),
    ("markdown_docs", r"\.md$"),
    ("report_output", r"(^|/)reports/"),
]


def res_root(entry_name):
    """The res:// top-level directory an APK entry belongs to, or None.

    Returns None for entries outside the Godot payload (lib/, classes.dex, ...)
    and for the flattened import cache, which has no res:// path left.
    """
    if not entry_name.startswith("assets/"):
        return None
    rest = entry_name[len("assets/"):]
    if rest.startswith(".godot/"):
        return None
    parts = rest.split("/")
    if len(parts) < 2:
        return None
    return parts[0]


def scan(apk_path):
    with zipfile.ZipFile(apk_path) as archive:
        names = archive.namelist()

    violations = []

    for label, pattern in FORBIDDEN_PATTERNS:
        regex = re.compile(pattern, re.IGNORECASE)
        hits = [n for n in names if regex.search(n)]
        if hits:
            violations.append({
                "kind": "forbidden_pattern",
                "label": label,
                "pattern": pattern,
                "count": len(hits),
                "examples": hits[:10],
            })

    roots = {}
    for name in names:
        root = res_root(name)
        if root is None:
            continue
        roots[root] = roots.get(root, 0) + 1

    unexpected = sorted(set(roots) - ALLOWED_ROOTS)
    for root in unexpected:
        violations.append({
            "kind": "unexpected_res_root",
            "label": root,
            "count": roots[root],
            "examples": [n for n in names if res_root(n) == root][:10],
            "hint": (
                "A res:// top-level directory that was not in the APK when the "
                "allowed list was measured. If it is a backup or evidence "
                "directory, give it a .gdignore; if it is intentional, add it to "
                "ALLOWED_ROOTS with a reason."
            ),
        })

    notes = []
    for root, reason in sorted(KNOWN_SHIPPING_NOTES.items()):
        if root in roots:
            notes.append({"root": root, "entries": roots[root], "reason": reason})

    return {
        "apk": os.path.basename(apk_path),
        "apk_bytes": os.path.getsize(apk_path),
        "entries": len(names),
        "res_roots": dict(sorted(roots.items())),
        "allowed_roots": sorted(ALLOWED_ROOTS),
        "violations": violations,
        "known_shipping_notes": notes,
        "passed": not violations,
    }


def main(argv):
    parser = argparse.ArgumentParser(description="Scan an APK for content that must not ship.")
    parser.add_argument("apk", help="path to the .apk to scan")
    parser.add_argument("--json", dest="json_out", default="",
                        help="write the full report here (default: reports/apk_content_scan.json)")
    parser.add_argument("--quiet", action="store_true", help="only print the result line")
    args = parser.parse_args(argv[1:])

    if not os.path.isfile(args.apk):
        sys.stderr.write("apk not found: %s\n" % args.apk)
        return 2
    try:
        report = scan(args.apk)
    except zipfile.BadZipFile as exc:
        sys.stderr.write("not a readable zip/apk: %s (%s)\n" % (args.apk, exc))
        return 2

    json_out = args.json_out
    if not json_out:
        here = os.path.dirname(os.path.abspath(__file__))
        json_out = os.path.join(os.path.dirname(here), "reports", "apk_content_scan.json")
    try:
        os.makedirs(os.path.dirname(json_out), exist_ok=True)
        # Explicit utf-8 + newline="": on Windows the default text pipe rewrites
        # newlines and picks the ANSI codepage, which mangles non-ASCII paths.
        with open(json_out, "w", encoding="utf-8", newline="") as handle:
            json.dump(report, handle, ensure_ascii=False, indent=2, sort_keys=True)
    except OSError as exc:
        sys.stderr.write("could not write report: %s (%s)\n" % (json_out, exc))
        json_out = ""

    if not args.quiet:
        lines = []
        lines.append("[apk_scan] %s  %d entries  %.1f MiB"
                     % (report["apk"], report["entries"], report["apk_bytes"] / 1048576.0))
        lines.append("[apk_scan] res:// roots: %s"
                     % ", ".join("%s=%d" % (k, v) for k, v in report["res_roots"].items()))
        for note in report["known_shipping_notes"]:
            lines.append("[apk_scan] note: '%s' ships (%d entries) -- %s"
                         % (note["root"], note["entries"], note["reason"]))
        for violation in report["violations"]:
            lines.append("[apk_scan] VIOLATION %s [%s] %d entries"
                         % (violation["kind"], violation["label"], violation["count"]))
            for example in violation["examples"][:5]:
                lines.append("[apk_scan]     %s" % example)
        sys.stdout.buffer.write(("\n".join(lines) + "\n").encode("utf-8"))

    status = "PASS" if report["passed"] else "FAIL"
    sys.stdout.buffer.write(
        ("APK_CONTENT_SCAN status=%s entries=%d violations=%d report=%s\n"
         % (status, report["entries"], len(report["violations"]), json_out or "<not written>")
         ).encode("utf-8"))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
