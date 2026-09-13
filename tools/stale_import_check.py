"""Detect assets whose Godot import cache (.godot/imported/*.ctex) is stale vs the source file.

Why this exists
---------------
Godot only rebuilds a cached texture when an import is triggered. A plain
`--path <proj>` (non-editor) run and an already-exported build never reimport: they
keep serving whatever `.ctex` was baked last. So if you replace `assets/.../foo.png`
and forget to reimport, the *game* silently keeps the OLD picture while the file on
disk looks correct -- exactly the 9.13 #7 regression, where the `打断锁链` card still
showed "打断目标" after the art had been redrawn to "缴械目标".

Two problem classes, deliberately kept apart
--------------------------------------------
STALE (actionable, fails the run)
    The `.import` resolves to a real source whose md5 no longer matches the
    `source_md5` recorded in the cache sidecar. This is the "wrong pixels at runtime"
    class and is what you fix with `--import`.

ORPHAN (pre-existing drift, warning only)
    `.import` sidecars that point somewhere the image no longer lives (`source_file=`
    disagrees with the on-disk path) or whose `.ctex` was never written. The project
    already carries a batch of these from moved working files; they are reported so
    they stay visible, but they do not fail the run unless `--strict` is passed.

Usage
-----
    <python> tools/stale_import_check.py [-v] [--strict] [--import-cmd]

    -v / --verbose   also list every fresh entry
    --strict         treat ORPHAN findings as failures too
    --import-cmd     print only the Godot reimport command and exit

Exit code: 0 = clean (or orphans only), 1 = stale entries (or orphans under --strict).
"""

from __future__ import annotations

import hashlib
import os
import re
import sys

IMG_EXT = {".png", ".jpg", ".jpeg", ".webp", ".svg", ".bmp", ".tga", ".exr", ".hdr", ".ktx", ".dds"}

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GODOT_CONSOLE = "Godot_v4.7.2-stable_win64_console.exe"

# Dest files come as `name-hash.ctex` (plain) or `name-hash.s3tc.ctex` /
# `name-hash.etc2.ctex` (VRAM-compressed). The paired .md5 sidecar is always
# `name-hash.md5` -- the format suffix is NOT part of it.
_FMT_SUFFIX = re.compile(r"\.(?:s3tc|etc2|astc|bptc)\.ctex$", re.I)


def md5_file(path: str) -> str | None:
    try:
        with open(path, "rb") as fh:
            return hashlib.md5(fh.read()).hexdigest()
    except OSError:
        return None


def res_to_fs(res_path: str) -> str:
    return os.path.join(ROOT, res_path.replace("res://", "").replace("/", os.sep))


def iter_sources():
    """Yield (res_path, abs_source_path) for every importable image under assets/."""
    for base, _dirs, files in os.walk(os.path.join(ROOT, "assets")):
        for name in files:
            if os.path.splitext(name)[1].lower() not in IMG_EXT:
                continue
            src = os.path.join(base, name)
            if not os.path.exists(src + ".import"):
                continue
            rel = os.path.relpath(src, ROOT).replace(os.sep, "/")
            yield "res://" + rel, src


def ctex_dests(txt: str) -> list[str]:
    """All cached .ctex res paths declared by a .import file."""
    dests = re.findall(r'^path(?:\.\w+)?="?([^"\n]+\.ctex)"?', txt, re.M)
    if dests:
        return [d.strip() for d in dests]
    m = re.search(r"dest_files=(\[[^\]]*\])", txt)
    return [d for d in re.findall(r'"([^"]+)"', m.group(1))] if m else []


def sidecar_for(ctex_res: str) -> str:
    """Path of the .md5 sidecar that Godot pairs with a cached .ctex."""
    base = _FMT_SUFFIX.sub("", ctex_res)
    if base == ctex_res:
        base = re.sub(r"\.ctex$", "", ctex_res, flags=re.I)
    return res_to_fs(base + ".md5")


def check_one(res_path: str, src: str):
    """Return (stale_problems, orphan_problems) for this source."""
    stale: list[str] = []
    orphan: list[str] = []
    try:
        with open(src + ".import", encoding="utf-8", errors="replace") as fh:
            txt = fh.read()
    except OSError as exc:
        return stale, orphan + ["%s: ORPHAN -- cannot read .import (%s)" % (res_path, exc)]

    m = re.search(r'^source_file="?([^"\n]+)"?', txt, re.M)
    if not m:
        return stale, orphan + ["%s: ORPHAN -- .import has no source_file" % res_path]
    if m.group(1).strip() != res_path:
        orphan.append("%s: ORPHAN -- .import source_file=%r" % (res_path, m.group(1).strip()))

    dests = ctex_dests(txt)
    if not dests:
        return stale, orphan + ["%s: ORPHAN -- .import declares no cached .ctex" % res_path]

    for ctex_res in dests:
        if not os.path.exists(res_to_fs(ctex_res)):
            orphan.append("%s: ORPHAN -- cached .ctex missing -> %s" % (res_path, ctex_res))

    cached_src_md5 = None
    for ctex_res in dests:
        sidecar = sidecar_for(ctex_res)
        if not os.path.exists(sidecar):
            continue
        try:
            with open(sidecar, encoding="utf-8", errors="replace") as fh:
                sm = re.search(r'source_md5="([0-9a-f]{32})"', fh.read())
        except OSError:
            sm = None
        if sm:
            cached_src_md5 = sm.group(1)
            break

    if cached_src_md5 is None:
        orphan.append("%s: ORPHAN -- no usable .md5 sidecar (import incomplete)" % res_path)
    else:
        current = md5_file(src)
        if current is not None and current != cached_src_md5:
            stale.append(
                "%s: STALE -- on-disk md5=%s, cache imported from %s"
                % (res_path, current[:12], cached_src_md5[:12])
            )
    return stale, orphan


def import_command() -> str:
    return '%s --headless --path "%s" --import' % (GODOT_CONSOLE, ROOT.replace("\\", "/"))


def main(argv: list[str]) -> int:
    verbose = "-v" in argv or "--verbose" in argv
    strict = "--strict" in argv
    if "--import-cmd" in argv:
        print(import_command())
        return 0

    stale: list[str] = []
    orphan: list[str] = []
    total = 0
    for res_path, src in sorted(iter_sources()):
        total += 1
        s, o = check_one(res_path, src)
        stale.extend(s)
        orphan.extend(o)
        if verbose and not s and not o:
            print("ok   %s" % res_path)

    failed = bool(stale) or (strict and bool(orphan))
    verdict = "FAIL" if failed else "PASS"
    print(
        "stale_import_check: %s (%d images scanned; %d stale, %d orphan)"
        % (verdict, total, len(stale), len(orphan))
    )
    if failed:
        print("Reimport with:")
        print("  " + import_command())
    if stale:
        print("-" * 72 + "\n  STALE (runtime serves the old texture):")
        for line in stale:
            print("    " + line)
    if orphan:
        label = "ORPHAN" + (" (failing: --strict)" if strict else " (warning only)")
        print("-" * 72 + "\n  %s:" % label)
        for line in orphan:
            print("    " + line)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
