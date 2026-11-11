#!/usr/bin/env python3
"""Build the 2026-10-29 source-only dedicated-server release on the Mac."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import zipfile
from pathlib import Path


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--smoke-seconds", type=float, default=8.0)
    args = parser.parse_args()

    source = args.source.resolve()
    out_dir = args.out_dir.resolve()
    sys.path.insert(0, str(source / "tools"))
    import make_server_bundle as bundle

    commit = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "HEAD"], text=True
    ).strip()
    protocol_match = re.search(
        r"(?m)^const NETWORK_PROTOCOL_VERSION\s*:=\s*(\d+)",
        (source / "scripts/multiplayer/NetworkConfig.gd").read_text(),
    )
    if not protocol_match:
        raise RuntimeError("Network protocol declaration not found")
    protocol = int(protocol_match.group(1))
    if protocol != 45:
        raise RuntimeError(f"Unexpected protocol: {protocol}")

    files = bundle.selected_files(source)
    source_tree_sha256 = bundle.tree_hash(files)
    balance = json.loads(files["data/balance/final_status.json"])
    files["project.godot"] = bundle.server_project(files["project.godot"])
    cache, class_count = bundle.fresh_class_cache(files)
    files[".godot/global_script_class_cache.cfg"] = cache
    manifest = {
        "git_sha": commit,
        "protocol": protocol,
        "source_tree_sha256": source_tree_sha256,
        "balance_version": balance["balance_version"],
        "class_count": class_count,
        "workbook_gate": {
            "status": "known pre-existing source error retained",
            "error": "FINAL_STATUS_ERROR: 02_棋子技能 undead_bomb: skill descriptions must follow O30/P30",
            "runtime_json": "committed data/balance/final_status.json retained unchanged",
        },
        "files": [
            {"path": name, "sha256": digest(data), "bytes": len(data)}
            for name, data in sorted(files.items())
        ],
    }
    files["server_bundle_manifest.json"] = (
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    ).encode()

    out_dir.mkdir(parents=True, exist_ok=True)
    archive_path = out_dir / "server.zip"
    if archive_path.exists():
        raise RuntimeError(f"Refusing to overwrite {archive_path}")
    with zipfile.ZipFile(
        archive_path, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9
    ) as archive:
        for name, data in sorted(files.items()):
            archive.writestr(name, data)

    smoke = bundle.smoke(
        archive_path,
        args.godot.resolve(),
        protocol,
        out_dir,
        None,
        args.smoke_seconds,
    )
    report = {
        "status": "prepared",
        "archive": str(archive_path),
        "archive_bytes": archive_path.stat().st_size,
        "archive_sha256": digest(archive_path.read_bytes()),
        "manifest": manifest,
        "smoke": smoke,
    }
    (out_dir / "prepared.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    )
    print("PREPARED " + json.dumps(report, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
