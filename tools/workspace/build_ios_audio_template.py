#!/usr/bin/env python3
"""Build the project's iPhone arm64 GL Compatibility engine and wrap stock templates.

Run with a Python containing SCons. The source must be Godot commit
5b4e0cb0fd279832bbdd69fed5354d4e5ad26f88, matching the 4.7 editor/templates.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zipfile

PROJECT = Path(__file__).resolve().parents[2]
ROOT = PROJECT.parent
PATCH = PROJECT / "deploy/engine/godot-4.7-ios-audio-recovery.patch"
OPTIONS = ["platform=ios", "target=template_release", "arch=arm64", "vulkan=no",
           "metal=no", "opengl3=yes", "module_mono_enabled=no"]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--stock-templates", type=Path, default=Path.home() / "Library/Application Support/Godot/export_templates/4.7.stable")
    parser.add_argument("--output", type=Path, default=ROOT / "build/ios-audio-templates/4.7.stable")
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args()
    source = args.source.resolve()
    if not (source / "SConstruct").is_file():
        parser.error("--source must point to the matching Godot source checkout")
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    stock = args.stock_templates.resolve()
    out = args.output.resolve()
    if stock == out:
        parser.error("output must differ from the stock templates")
    if (stock / "version.txt").read_text().strip() != "4.7.stable":
        parser.error("stock templates must be 4.7.stable")
    reverse = subprocess.run(["git", "apply", "--reverse", "--check", str(PATCH)], cwd=source, capture_output=True)
    if reverse.returncode:
        subprocess.run(["git", "apply", "--check", str(PATCH)], cwd=source, check=True)
        subprocess.run(["git", "apply", str(PATCH)], cwd=source, check=True)
    subprocess.run([sys.executable, "-m", "SCons", *OPTIONS, f"-j{args.jobs}"], cwd=source, check=True)
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
    manifest = {"source_commit": "5b4e0cb0fd279832bbdd69fed5354d4e5ad26f88",
                "engine_patch": str(PATCH.relative_to(PROJECT)), "patch_sha256": sha(PATCH),
                "library_sha256": sha(library), "ios_zip_sha256": sha(out / "ios.zip"),
                "scons_options": " ".join(OPTIONS), "renderer": "GL Compatibility (project mobile renderer)"}
    (out / "glory-engine.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(out)


if __name__ == "__main__":
    main()
