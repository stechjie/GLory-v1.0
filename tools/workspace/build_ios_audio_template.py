#!/usr/bin/env python3
"""Build Glory's iPhone arm64 GL Compatibility engine and wrap stock templates.

Run with a Python containing SCons. Use the matching Godot 4.7 source archive;
an isolated source copy keeps existing engine builds available for rollback.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import zipfile

import ios_toolchain

PROJECT = Path(__file__).resolve().parents[2]
ROOT = Path(os.environ["GLORY_WORKSPACE"]).resolve() if os.environ.get("GLORY_WORKSPACE") else PROJECT.parent
PATCH = PROJECT / "deploy/engine/godot-4.7-ios-audio-recovery.patch"
DUO_PATCH = PROJECT / "deploy/engine/godot-4.7-ios-duo-layout.patch"
EXPECTED_SOURCE_COMMIT = "5b4e0cb0fd279832bbdd69fed5354d4e5ad26f88"
OPTIONS = ["platform=ios", "target=template_release", "arch=arm64", "vulkan=no",
           "metal=no", "opengl3=yes", "module_mono_enabled=no", "ios_min_version=15.0"]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def apply_patch(source, patch):
    if not patch.is_file():
        raise RuntimeError(f"Required engine patch is missing: {patch}")
    reverse = subprocess.run(["git", "apply", "--reverse", "--check", str(patch)],
                             cwd=source, capture_output=True)
    if reverse.returncode:
        subprocess.run(["git", "apply", "--check", str(patch)], cwd=source, check=True)
        subprocess.run(["git", "apply", str(patch)], cwd=source, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--stock-templates", type=Path, default=Path.home() / "Library/Application Support/Godot/export_templates/4.7.stable")
    parser.add_argument("--output", type=Path, default=ROOT / "build/ios-duo-templates/4.7.stable")
    parser.add_argument("--developer-dir", type=Path, help="Select Xcode explicitly; requires iOS SDK >= 27.1")
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args()
    source = args.source.resolve()
    if not (source / "SConstruct").is_file():
        parser.error("--source must point to the matching Godot source")
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    child = dict(os.environ)
    if args.developer_dir:
        child["DEVELOPER_DIR"] = str(args.developer_dir.expanduser().resolve())
    elif not child.get("DEVELOPER_DIR") and Path("/Applications/Xcode.app/Contents/Developer").is_dir():
        child["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    toolchain = ios_toolchain.inspect_toolchain(child)
    stock = args.stock_templates.resolve()
    out = args.output.resolve()
    if stock == out:
        parser.error("output must differ from the stock templates")
    if not out.is_relative_to(ROOT):
        parser.error("output must remain inside the GLory workspace")
    if (stock / "version.txt").read_text().strip() != "4.7.stable":
        parser.error("stock templates must be 4.7.stable")
    source_revision = None
    if (source / ".git").exists():
        source_revision = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
        if source_revision != EXPECTED_SOURCE_COMMIT:
            parser.error("source checkout does not match the required Godot 4.7 commit")
    patches = [PATCH, DUO_PATCH]
    for patch in patches:
        apply_patch(source, patch)
    # Explicit real SDK path changes SCons command signatures after Xcode upgrades.
    # This also prevents a stale APPLE_SDK_PATH from selecting a different SDK.
    options = OPTIONS + [f"APPLE_SDK_PATH={toolchain['iphoneos_sdk_path']}"]
    subprocess.run([sys.executable, "-m", "SCons", *options, f"-j{args.jobs}"],
                   cwd=source, check=True, env=child)
    library = source / "bin/libgodot.ios.template_release.arm64.a"
    key = "libgodot.ios.release.xcframework/ios-arm64/libgodot.a"
    out.mkdir(parents=True, exist_ok=True)
    temporary = out / "ios.zip.tmp"
    with zipfile.ZipFile(stock / "ios.zip") as original, zipfile.ZipFile(temporary, "w") as target:
        if key not in original.namelist():
            raise RuntimeError("Stock template does not contain the expected arm64 library")
        for info in original.infolist():
            target.writestr(info, library.read_bytes() if info.filename == key else original.read(info.filename))
    temporary.replace(out / "ios.zip")
    (out / "version.txt").write_text("4.7.stable\n")
    manifest = {
        "expected_source_commit": EXPECTED_SOURCE_COMMIT,
        "source_commit": source_revision,
        "source_commit_verification": "git_head" if source_revision else "source_archive_no_git_head",
        "source": str(source),
        "engine_patch": str(PATCH.relative_to(PROJECT)), "patch_sha256": sha(PATCH),
        "patches": {patch.relative_to(PROJECT).as_posix(): sha(patch) for patch in patches},
        "library_sha256": sha(library), "ios_zip_sha256": sha(out / "ios.zip"),
        "scons_options": options, "toolchain": toolchain,
        "renderer": "GL Compatibility (project mobile renderer)",
    }
    (out / "glory-engine.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(out)


if __name__ == "__main__":
    main()
