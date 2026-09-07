#!/usr/bin/env python3
"""Create and verify Glory's build identity without trusting the APK filename.

The generated build_info.json is embedded by Godot.  After export, ``verify``
reads it back, compares every field, checks the packaged asset descriptors, reads
AndroidManifest through aapt, and records source-to-imported artifact mappings.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
import zipfile
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


BUILD_SCHEMA = 2
BUILD_INFO_NAMES = ("assets/build_info.json", "build_info.json")
ASSET_MANIFEST_NAMES = ("assets/assets.manifest.json", "assets.manifest.json")
ASSET_BUNDLE_NAMES = ("assets/assets.bundle.json", "assets.bundle.json")
SECRET_PRESET_KEYS = {
    "keystore/release_password",
    "keystore/release_user",
    "keystore/debug_password",
    "keystore/debug_user",
}
PRESET_CONTRACT_KEYS = (
    "package/unique_name",
    "package/name",
    "version/code",
    "version/name",
    "architectures/arm64-v8a",
    "architectures/armeabi-v7a",
    "architectures/x86",
    "architectures/x86_64",
    "graphics/opengl_debug",
)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_zip_member(archive: zipfile.ZipFile, name: str) -> str:
    digest = hashlib.sha256()
    with archive.open(name) as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_sha(value: Any) -> str:
    data = json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")
    return sha256_bytes(data)


def read_json(path: Path) -> Dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON root must be an object: {path}")
    return value


def git(project: Path, *args: str, binary: bool = False) -> bytes:
    process = subprocess.run(
        ["git", "-C", str(project), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        message = process.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(f"git {' '.join(args)} failed: {message}")
    return process.stdout if binary else process.stdout.rstrip(b"\r\n")


def workspace_fingerprint(project: Path, status_lines: List[str]) -> Tuple[str, int, int]:
    """Hash tracked diffs plus every non-ignored untracked file used by a build."""
    tracked = [line for line in status_lines if not line.startswith("??")]
    untracked: List[Dict[str, Any]] = []
    for line in status_lines:
        if not line.startswith("??"):
            continue
        relative = line[3:]
        path = project / relative
        if path.is_file():
            data = path.read_bytes()
            untracked.append({"path": relative.replace("\\", "/"),
                              "bytes": len(data), "sha256": sha256_bytes(data)})
    tracked_diff = git(project, "diff", "HEAD", "--binary", "--no-ext-diff", binary=True)
    payload = tracked_diff + b"\n--GLORY-UNTRACKED--\n" + json.dumps(
        sorted(untracked, key=lambda row: row["path"]),
        ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return sha256_bytes(payload), len(tracked), len(tracked) + len(untracked)


def parse_presets(path: Path, wanted_name: str) -> Dict[str, Any]:
    text = path.read_text(encoding="utf-8-sig")
    sections: Dict[str, Dict[str, str]] = {}
    section = ""
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            sections.setdefault(section, {})
            continue
        if "=" not in line or not section:
            continue
        key, value = line.split("=", 1)
        sections[section][key.strip()] = value.strip().strip('"')

    selected = ""
    for name, values in sections.items():
        if re.fullmatch(r"preset\.\d+", name) and values.get("name") == wanted_name:
            selected = name
            break
    if not selected:
        raise ValueError(f"preset not found: {wanted_name!r} in {path}")
    options = sections.get(f"{selected}.options", {})
    contract: Dict[str, Any] = {
        "name": wanted_name,
        "platform": sections[selected].get("platform", ""),
        "runnable": sections[selected].get("runnable", ""),
        "export_filter": sections[selected].get("export_filter", ""),
        "include_filter": sections[selected].get("include_filter", ""),
        "exclude_filter": sections[selected].get("exclude_filter", ""),
    }
    for key in PRESET_CONTRACT_KEYS:
        if key in options and key not in SECRET_PRESET_KEYS:
            contract[key] = options[key]
    return contract


def create_build_info(project: Path, preset_path: Path, preset: str,
                      godot_version: str) -> Dict[str, Any]:
    manifest_path = project / "assets.manifest.json"
    bundle_path = project / "assets.bundle.json"
    manifest_bytes = manifest_path.read_bytes()
    bundle_bytes = bundle_path.read_bytes()
    manifest = json.loads(manifest_bytes.decode("utf-8-sig"))
    bundle = json.loads(bundle_bytes.decode("utf-8-sig"))
    contract = parse_presets(preset_path, preset)

    commit = git(project, "rev-parse", "HEAD").decode("ascii")
    short = git(project, "rev-parse", "--short", "HEAD").decode("ascii")
    status_lines = git(project, "status", "--porcelain").decode("utf-8", "replace").splitlines()
    diff_sha, tracked_dirty_count, dirty_count = workspace_fingerprint(project, status_lines)
    archive = bundle.get("archive", {})
    identity = {
        "git_commit": commit,
        "dirty_diff_sha256": diff_sha,
        "asset_inventory_sha256": str(manifest.get("inventory_sha256", "")),
        "asset_manifest_file_sha256": sha256_bytes(manifest_bytes),
        "asset_bundle_file_sha256": sha256_bytes(bundle_bytes),
        "asset_bundle_archive_sha256": str(archive.get("sha256", "")),
        "preset_contract_sha256": canonical_sha(contract),
    }
    version_code = int(contract.get("version/code", "0") or 0)
    result: Dict[str, Any] = {
        "schema_version": BUILD_SCHEMA,
        "build_id": str(uuid.uuid4()),
        "git_commit": commit,
        "git_commit_short": short,
        "dirty_tracked_files": tracked_dirty_count,
        "dirty_files": dirty_count,
        "dirty_diff_sha256": identity["dirty_diff_sha256"],
        "build_utc": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "asset_inventory_sha256": identity["asset_inventory_sha256"],
        "asset_manifest_file_sha256": identity["asset_manifest_file_sha256"],
        "asset_bundle_file_sha256": identity["asset_bundle_file_sha256"],
        "asset_bundle_archive_sha256": identity["asset_bundle_archive_sha256"],
        "asset_bundle_archive_bytes": int(archive.get("bytes", 0) or 0),
        "preset_template_sha256": sha256_bytes((project / "export_presets.template.cfg").read_bytes()),
        "preset_contract_sha256": identity["preset_contract_sha256"],
        "preset_contract": contract,
        "preset": preset,
        "package_id": str(contract.get("package/unique_name", "")),
        "version_code": version_code,
        "version_name": str(contract.get("version/name", "")),
        "godot_version": godot_version,
        "source_identity_sha256": canonical_sha(identity),
    }
    return result


def zip_member(archive: zipfile.ZipFile, candidates: Iterable[str]) -> Tuple[str, bytes]:
    names = set(archive.namelist())
    for candidate in candidates:
        if candidate in names:
            return candidate, archive.read(candidate)
    return "", b""


def artifact_mappings(archive: zipfile.ZipFile) -> List[Dict[str, Any]]:
    names = set(archive.namelist())
    mappings: List[Dict[str, Any]] = []
    path_pattern = re.compile(r'^path(?:\.[^=]+)?="(res://[^"]+)"', re.MULTILINE)
    for remap_name in sorted(name for name in names if name.startswith("assets/") and name.endswith(".remap")):
        text = archive.read(remap_name).decode("utf-8", "replace")
        targets = sorted(set(path_pattern.findall(text)))
        source = "res://" + remap_name[len("assets/"):-len(".remap")]
        for target in targets:
            packaged = "assets/" + target[len("res://"):]
            if packaged not in names:
                continue
            info = archive.getinfo(packaged)
            mappings.append({
                "source": source,
                "artifact": target,
                "bytes": info.file_size,
                "sha256": sha256_zip_member(archive, packaged),
            })
    return mappings


def find_aapt(requested: str = "") -> str:
    if requested:
        return requested if Path(requested).is_file() else ""
    for name in ("aapt2", "aapt"):
        found = shutil.which(name)
        if found:
            return found
    roots = [os.environ.get("ANDROID_HOME", ""), os.environ.get("ANDROID_SDK_ROOT", "")]
    local = os.environ.get("LOCALAPPDATA", "")
    if local:
        roots.append(str(Path(local) / "Android" / "Sdk"))
    candidates: List[Path] = []
    for root in roots:
        build_tools = Path(root) / "build-tools" if root else Path()
        if build_tools.is_dir():
            candidates.extend(build_tools.glob("*/aapt2.exe"))
            candidates.extend(build_tools.glob("*/aapt.exe"))
    return str(sorted(candidates, reverse=True)[0]) if candidates else ""


def android_manifest_identity(apk: Path, aapt: str) -> Dict[str, Any]:
    process = subprocess.run([aapt, "dump", "badging", str(apk)],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    text = process.stdout.decode("utf-8", "replace")
    if process.returncode != 0:
        raise RuntimeError(process.stderr.decode("utf-8", "replace").strip() or "aapt failed")
    match = re.search(r"^package: name='([^']*)' versionCode='([^']*)' versionName='([^']*)'", text, re.MULTILINE)
    if not match:
        raise ValueError("aapt output has no package identity")
    return {"package_id": match.group(1), "version_code": int(match.group(2)), "version_name": match.group(3)}


def inspect_apk(apk: Path, aapt_request: str = "") -> Dict[str, Any]:
    with zipfile.ZipFile(apk) as archive:
        build_name, build_bytes = zip_member(archive, BUILD_INFO_NAMES)
        manifest_name, manifest_bytes = zip_member(archive, ASSET_MANIFEST_NAMES)
        bundle_name, bundle_bytes = zip_member(archive, ASSET_BUNDLE_NAMES)
        mappings = artifact_mappings(archive)
        entry_rows = [
            {"path": item.filename, "bytes": item.file_size, "crc32": f"{item.CRC:08x}"}
            for item in sorted(archive.infolist(), key=lambda value: value.filename)
        ]
    build_info = json.loads(build_bytes.decode("utf-8-sig")) if build_bytes else {}
    manifest = json.loads(manifest_bytes.decode("utf-8-sig")) if manifest_bytes else {}
    bundle = json.loads(bundle_bytes.decode("utf-8-sig")) if bundle_bytes else {}
    aapt = find_aapt(aapt_request)
    android_identity: Dict[str, Any] = {}
    manifest_error = ""
    if not aapt:
        manifest_error = "aapt_not_found"
    else:
        try:
            android_identity = android_manifest_identity(apk, aapt)
        except (OSError, RuntimeError, ValueError) as exc:
            manifest_error = str(exc)
    return {
        "apk": str(apk.resolve()),
        "apk_bytes": apk.stat().st_size,
        "apk_sha256": sha256_file(apk),
        "build_info_member": build_name,
        "build_info": build_info,
        "asset_manifest_member": manifest_name,
        "asset_manifest_file_sha256": sha256_bytes(manifest_bytes) if manifest_bytes else "",
        "asset_manifest_inventory_sha256": str(manifest.get("inventory_sha256", "")),
        "asset_bundle_member": bundle_name,
        "asset_bundle_file_sha256": sha256_bytes(bundle_bytes) if bundle_bytes else "",
        "asset_bundle_inventory_sha256": str(bundle.get("inventory_sha256", "")),
        "android_manifest": android_identity,
        "android_manifest_error": manifest_error,
        "artifact_mapping_count": len(mappings),
        "artifact_mappings": mappings,
        "apk_entry_inventory_sha256": canonical_sha(entry_rows),
        "apk_entries": entry_rows,
    }


def verify_report(report: Dict[str, Any], expected: Optional[Dict[str, Any]]) -> List[str]:
    failures: List[str] = []
    embedded = report.get("build_info", {})
    if not embedded:
        failures.append("build_info_absent")
    elif expected is not None and embedded != expected:
        failures.append("build_info_not_byte_equivalent_to_expected_json")
    if not report.get("asset_manifest_member"):
        failures.append("asset_manifest_absent")
    if not report.get("asset_bundle_member"):
        failures.append("asset_bundle_absent")
    if embedded:
        comparisons = (
            ("asset_manifest_file_sha256", report.get("asset_manifest_file_sha256", "")),
            ("asset_inventory_sha256", report.get("asset_manifest_inventory_sha256", "")),
            ("asset_bundle_file_sha256", report.get("asset_bundle_file_sha256", "")),
        )
        for key, actual in comparisons:
            if str(embedded.get(key, "")) != str(actual):
                failures.append(f"{key}_mismatch")
        bundle_inventory = str(report.get("asset_bundle_inventory_sha256", ""))
        if bundle_inventory != str(embedded.get("asset_inventory_sha256", "")):
            failures.append("asset_bundle_inventory_mismatch")
    if report.get("android_manifest_error"):
        failures.append(str(report["android_manifest_error"]))
    elif embedded:
        android = report.get("android_manifest", {})
        for key in ("package_id", "version_code", "version_name"):
            if str(android.get(key, "")) != str(embedded.get(key, "")):
                failures.append(f"android_manifest_{key}_mismatch")
    return failures


def write_json(path: Path, value: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("create")
    create.add_argument("--project-root", required=True)
    create.add_argument("--preset-config", required=True)
    create.add_argument("--preset", required=True)
    create.add_argument("--godot-version", required=True)
    create.add_argument("--output", required=True)
    inspect = sub.add_parser("inspect")
    inspect.add_argument("--apk", required=True)
    inspect.add_argument("--expected")
    inspect.add_argument("--aapt", default="")
    inspect.add_argument("--report", required=True)
    inspect.add_argument("--extracted-build-info")
    args = parser.parse_args(argv[1:])

    try:
        if args.command == "create":
            value = create_build_info(Path(args.project_root).resolve(),
                                      Path(args.preset_config).resolve(),
                                      args.preset, args.godot_version)
            write_json(Path(args.output), value)
            print("BUILD_IDENTITY_CREATE status=PASS build_id=%s source=%s" %
                  (value["build_id"], value["source_identity_sha256"]))
            return 0
        report = inspect_apk(Path(args.apk), args.aapt)
        expected = read_json(Path(args.expected)) if args.expected else None
        failures = verify_report(report, expected)
        report["failures"] = failures
        report["passed"] = not failures
        write_json(Path(args.report), report)
        if args.extracted_build_info and report.get("build_info"):
            write_json(Path(args.extracted_build_info), report["build_info"])
        status = "PASS" if not failures else "FAIL"
        print("APK_IDENTITY_VERIFY status=%s mappings=%d failures=%d report=%s" %
              (status, report["artifact_mapping_count"], len(failures), args.report))
        for failure in failures:
            print("APK_IDENTITY_FAILURE %s" % failure)
        return 0 if not failures else 1
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile, json.JSONDecodeError) as exc:
        print("APK_IDENTITY_ERROR %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
