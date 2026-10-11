#!/usr/bin/env python3
"""Build cumulative Godot patches from platform-exported ZIPs, never source ZIPs.

Export both archives with the same engine, platform preset and immutable launcher.
Each patch is relative to the original base, not to the previous patch: clients
can skip releases and rollback without retaining a chain of resource packs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import zipfile

NATIVE_SUFFIXES = {".dll", ".so", ".dylib", ".exe", ".a", ".lib", ".gdextension",
                   ".aar", ".jar", ".dex", ".wasm", ".p12", ".keystore", ".jks"}
IMMUTABLE_FILES = {"project.binary", "project.godot", ".godot/global_script_class_cache.cfg"}
PLATFORMS = {"android", "ios", "windows"}
MAX_UNCOMPRESSED = 8_000_000_000


def immutable(name: str) -> bool:
    path = PurePosixPath(name)
    return (name in IMMUTABLE_FILES or name.startswith("patcher/")
            or path.suffix.lower() in NATIVE_SUFFIXES
            or any(part.endswith((".framework", ".xcframework")) for part in path.parts))


def inventory(archive: zipfile.ZipFile) -> dict[str, str]:
    result = {}
    total = 0
    for info in archive.infolist():
        name = info.filename
        path = PurePosixPath(name)
        if (not name or name.startswith("/") or "\\" in name or ":" in name
                or any(part in ("", ".", "..") for part in name.rstrip("/").split("/"))):
            raise ValueError(f"Unsafe archive path: {name}")
        if stat.S_ISLNK(info.external_attr >> 16) or info.flag_bits & 1:
            raise ValueError(f"Encrypted files and links are unsupported: {name}")
        if info.is_dir():
            continue
        if name in result:
            raise ValueError(f"Duplicate archive path: {name}")
        if any(part.lower() in {".git", ".env", "backend"} for part in path.parts):
            raise ValueError(f"Private or server files in client export: {name}")
        total += info.file_size
        if total > MAX_UNCOMPRESSED:
            raise ValueError("Archive exceeds the 8 GB uncompressed limit")
        digest = hashlib.sha256()
        with archive.open(info) as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        result[name] = digest.hexdigest()
    return result


def build(base: Path, current: Path, output: Path, *, platform: str, base_id: str) -> dict:
    if platform not in PLATFORMS or not re.fullmatch(r"[A-Za-z0-9_-]{1,96}", base_id):
        raise ValueError("Invalid platform or base_id")
    if output.exists() or output.with_suffix(".json").exists():
        raise ValueError("Output already exists; use a new destination")
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(base) as original, zipfile.ZipFile(current) as updated:
        before, after = inventory(original), inventory(updated)
        if "patcher/boot.json" not in before:
            raise ValueError("Base does not contain the immutable update launcher")
        boot = json.loads(original.read("patcher/boot.json"))
        if boot.get("platform") != platform or boot.get("base_id") != base_id:
            raise ValueError("Base archive identity differs from requested platform/base_id")
        # Packs overlay files; they cannot remove files from an already mounted base.
        deleted = sorted(before.keys() - after.keys())
        if deleted:
            raise ValueError(f"Deletion requires a new full base build: {deleted[:8]}")
        changed = sorted(name for name in after if after[name] != before.get(name))
        blocked = [name for name in changed if immutable(name)]
        if blocked:
            raise ValueError(f"Engine/native/bootstrap/global-class change requires a full build: {blocked[:8]}")
        if not changed:
            raise ValueError("No changed resources; there is no patch to publish")
        # Exclusive creation protects previous output even if a concurrent build starts.
        with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as patch:
            for name in changed:
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                with updated.open(name) as source, patch.open(info, "w", force_zip64=True) as target:
                    while chunk := source.read(1024 * 1024):
                        target.write(chunk)
    size = output.stat().st_size
    if size > 2_000_000_000:
        output.unlink()
        raise ValueError("Patch exceeds Firebase Hosting's per-file size guard")
    digest = hashlib.sha256()
    with output.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    report = {"protocol": 1, "platform": platform, "base_id": base_id,
              "sha256": digest.hexdigest(), "size": size, "files": changed,
              "base_inventory_sha256": hashlib.sha256(json.dumps(before, sort_keys=True).encode()).hexdigest()}
    with output.with_suffix(".json").open("x", encoding="utf-8") as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True, help="Original platform-exported ZIP")
    parser.add_argument("--current", type=Path, required=True, help="New platform-exported ZIP")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--platform", choices=sorted(PLATFORMS), required=True)
    parser.add_argument("--base-id", required=True)
    args = parser.parse_args()
    try:
        report = build(args.base, args.current, args.output, platform=args.platform, base_id=args.base_id)
    except (ValueError, OSError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Patch build failed: {error}\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
