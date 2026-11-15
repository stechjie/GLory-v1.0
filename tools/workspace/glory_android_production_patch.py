#!/usr/bin/env python3
"""Build a local cumulative Android production patch from the selected slim base.

No synchronization, upload, server change, or publication is performed.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
import re
import shutil
import subprocess
import uuid

import glory_build as build
from export_patch import digest, export, native_inventory, preset_policy_digest
from prepare_patch_base import from_config

ROOT = build.ROOT
DEFAULT_POINTER = ROOT / "build/patch-baselines/current-android-production.json"


def write(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def load_baseline(pointer_path: Path) -> tuple[dict, dict, Path]:
    pointer = json.loads(pointer_path.read_text())
    expected = {"schema_version": 1, "platform": "android", "environment": "prod",
                "channel": "production"}
    if any(pointer.get(key) != value for key, value in expected.items()):
        raise ValueError("Pointer must select an Android production baseline")
    folder = Path(pointer["baseline_directory"]).resolve()
    if folder.name != pointer["base_id"]:
        raise ValueError("Pointer directory and base_id differ")
    lock_path = folder / "baseline-lock.json"
    if digest(lock_path) != pointer["lock_sha256"]:
        raise ValueError("Baseline lock changed; inspect the selection record")
    lock = json.loads(lock_path.read_text())
    for key in (*expected, "base_id", "version_name", "version_code"):
        if lock.get(key) != pointer.get(key):
            raise ValueError("Pointer and retained baseline identity differ: " + key)
    for relative, row in lock["retained_files"].items():
        path = (folder / relative).resolve()
        if not path.is_relative_to(folder) or digest(path) != row["sha256"]:
            raise ValueError("Retained baseline file changed: " + relative)
    config = json.loads((folder / "patch-config.json").read_text())
    if (config.get("base_id") != pointer["base_id"] or
            config.get("channel") != "production" or
            config.get("backend_url") != "https://api.gogoglory.com"):
        raise ValueError("Retained config does not match the production baseline")
    manifest = json.loads((folder / "base.export.json").read_text())
    if (manifest.get("platform") != "android" or manifest.get("debug") is not False or
            manifest.get("base_id") != pointer["base_id"] or
            manifest.get("sha256") != digest(folder / "base.zip")):
        raise ValueError("Retained archive and export manifest differ")
    engine = Path(lock["engine"])
    if digest(engine) != lock["engine_sha256"]:
        raise ValueError("Retained Godot executable changed")
    if build.capture([engine, "--version"]) != manifest["engine_version"]:
        raise ValueError("Godot version differs from the installed baseline")
    return pointer, lock, folder


def configure_aab_preset(stage: Path, lock: dict) -> None:
    """Reproduce build_aab.sh's generated preset; a policy hash guards drift.

    Regenerate from current source rather than replacing it with an old preset:
    incompatible source/native/bootstrap inputs must fail the checks below.
    """
    preset, _ = build.export_preset(stage, None)
    path = stage / "export_presets.cfg"
    text = path.read_text().replace(f'name="{preset}"', 'name="Google Play Release"')
    text = re.sub(r"^custom_features=.*$", 'custom_features=""', text, flags=re.M)
    values = {"package/unique_name": '"com.glory.game.google"',
              "gradle_build/export_format": "1", "gradle_build/target_sdk": "36",
              "package/signed": "false", "architectures/armeabi-v7a": "true",
              "architectures/arm64-v8a": "true", "architectures/x86": "false",
              "architectures/x86_64": "false"}
    for key, value in values.items():
        text = re.sub(r"^" + re.escape(key) + r"=.*\n?", "", text, flags=re.M)
        text += f"{key}={value}\n"
    text = re.sub(r"^version/code=\d+", "version/code=" + str(lock["version_code"]),
                  text, flags=re.M)
    text = re.sub(r'^version/name="[^"]*"',
                  lambda _: "version/name=" + json.dumps(lock["version_name"]), text, flags=re.M)
    path.write_text(text)
    path.chmod(0o600)


def seed_import_cache(stage: Path, folder: Path) -> dict:
    """Reuse proven unchanged imports without replacing changed source inputs."""
    inputs_path = folder / "import-cache-inputs.json"
    if not inputs_path.is_file():
        raise ValueError("Missing retained full-package import cache input manifest")
    cache = folder / "import-cache"
    if (stage / ".godot").exists():
        raise ValueError("Import cache must seed a fresh stage")
    # Independent bytes: never hardlink mutable stage caches to the fixed base.
    shutil.copytree(cache, stage / ".godot", copy_function=shutil.copy2)
    reused, changed = 0, 0
    for relative, row in json.loads(inputs_path.read_text()).items():
        current = stage / relative
        primary = stage / row["source_file"]
        if (current.is_file() and primary.is_file() and
                digest(current) == row["raw_input_sha256"] and
                digest(primary) == row["source_sha256"]):
            shutil.copy2(folder / "import-sidecars" / relative, current)
            reused += 1
        else:
            changed += 1
    return {"qualified_sidecars_reused": reused, "changed_or_absent_inputs": changed,
            "mutable_cache_storage": "independent_copy"}


def reuse_generated_import_metadata(stage: Path, folder: Path) -> int:
    """Restore UID metadata only for unchanged inputs that had no raw sidecar."""
    reused = 0
    for relative, row in json.loads((folder / "import-generated-inputs.json").read_text()).items():
        current = stage / relative
        primary = stage / row["source_file"]
        if not current.exists() and primary.is_file() and digest(primary) == row["source_sha256"]:
            shutil.copy2(folder / "import-sidecars" / relative, current)
            reused += 1
    return reused


def verify_stage(stage: Path, folder: Path) -> None:
    snapshot = folder / "source-snapshot"
    if digest(stage / "project.godot") != digest(snapshot / "project.godot"):
        raise ValueError("project.godot changed; a new full application is required")
    record = json.loads((folder / "base.export.json").read_text())
    if preset_policy_digest(stage, record.get("slim_generated_exclusions", ())) != record["preset_policy_sha256"]:
        raise ValueError("Export preset policy changed; a new full application is required")
    native = {name: value for name, value in record["native_files"].items()
              if not name.startswith("android/build/")}
    if native_inventory(stage) != native:
        raise ValueError("Native inputs changed; a new full application is required")
    generated = folder / "import-generated-inputs.json"
    if generated.is_file():
        for relative, row in json.loads(generated.read_text()).items():
            if not relative.startswith("patcher/"):
                continue
            if digest(stage / row["source_file"]) != row["source_sha256"]:
                raise ValueError("Immutable launcher input changed: " + row["source_file"])
            current = stage / relative
            if current.is_file() and digest(current) != digest(folder / "import-sidecars" / relative):
                raise ValueError("Immutable launcher import settings changed: " + relative)
    # The generated immutable launcher must also be identical before export.
    import zipfile
    with zipfile.ZipFile(folder / "base.zip") as archive:
        for name in archive.namelist():
            if name.startswith("patcher/") and not name.endswith("/"):
                # Godot strips importer parameters in packaged remap metadata;
                # compare that serialization through export_patch, not raw inputs.
                if name.endswith((".import", ".remap")):
                    continue
                candidate = stage / name
                # Imported font payloads are generated during the import below.
                if candidate.is_file() and candidate.read_bytes() != archive.read(name):
                    raise ValueError("Immutable launcher changed: " + name)


def run(args) -> int:
    pointer, lock, folder = load_baseline(args.pointer.resolve())
    if args.check:
        print(json.dumps({"status": "baseline_verified", "base_id": pointer["base_id"],
                          "version_code": pointer["version_code"], "directory": str(folder),
                          "publication": "none"}, indent=2))
        return 0
    with build.file_lock(ROOT / "build/.android-production-patch.lock", nonblocking=True):
        project = ROOT / "GLory-v1.0"
        commit = build.capture(["git", "-C", project, "rev-parse", "HEAD"])
        run_dir = ROOT / "build/patch-android-production" / (
            dt.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8])
        run_dir.mkdir(parents=True)
        state = {"status": "preparing", "base_id": pointer["base_id"],
                 "channel": "production", "source_commit": commit,
                 "dirty_files": build.capture(["git", "-C", project, "status", "--porcelain"]).splitlines(),
                 "publication": "none", "baseline_directory": str(folder)}
        state_path = run_dir / "result.json"
        write(state_path, state)
        try:
            stage, logs = run_dir / "project", run_dir / "stage-log"
            logs.mkdir()
            with build.file_lock(ROOT / ".glory-sync/sync.lock", shared=True):
                sync_path = ROOT / ".glory-sync/last-run.json"
                if sync_path.exists() and json.loads(sync_path.read_text()).get("status") in ("running", "failed"):
                    raise ValueError("Resource sync is not complete; no patch staged")
                staged = build.stage_project(project, build.asset_root(ROOT / "res"), stage, logs)
            state["import_cache"] = seed_import_cache(stage, folder)
            build.configure_server_environment(stage, "prod")
            configure_aab_preset(stage, lock)
            from_config(stage, folder / "patch-config.json", "android")
            state["import_cache"]["generated_sidecars_reused"] = reuse_generated_import_metadata(stage, folder)
            # Build identity describes the installed executable, not a new resource patch.
            shutil.copy2(folder / "source-snapshot/build_info.json", stage / "build_info.json")
            verify_stage(stage, folder)
            state.update(status="exporting", assets_sha256=staged["actual_assets_sha256"])
            write(state_path, state)
            try:
                result = export(stage=stage, engine=Path(lock["engine"]), preset="Google Play Release",
                                platform="android", config=folder / "patch-config.json",
                                output=run_dir / "android", base=folder / "base.zip")
            except ValueError as error:
                if str(error) != "No changed resources; there is no patch to publish":
                    raise
                state.update(status="no_changes", message=str(error))
            else:
                state.update(status="built", patch=result, artifact=str(run_dir / "android/android.zip"))
            write(state_path, state)
            print(json.dumps({"status": state["status"], "base_id": pointer["base_id"],
                              "result": str(state_path), "publication": "none"}, indent=2))
            return 0
        except Exception as error:
            state.update(status="failed", error=str(error))
            write(state_path, state)
            raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pointer", type=Path, default=DEFAULT_POINTER)
    parser.add_argument("--check", action="store_true", help="Verify retained hashes without staging or export")
    args = parser.parse_args()
    try:
        raise SystemExit(run(args))
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Android production patch stopped: {error}\n")


if __name__ == "__main__":
    main()
