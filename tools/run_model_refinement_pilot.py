#!/usr/bin/env python3
"""Reproduce the isolated Model Refinement Android benchmark and retain evidence.

Requires an explicit authorized --serial, a verified --build-dir, and a new
--out directory outside the source project. --check is read-only. Normal runs
install only com.glory.modelpilot when its APK differs, never uninstall or
clear app data, and leave the preview looping NEW / 1 unit afterward.
The official com.glory.game is only queried, never started/stopped/modified.
No whole-game performance claim follows from this isolated benchmark.

Exit codes: 0 verified measurement (or successful --check); 2 CLI/output error;
3 device/authorization failure; 4 artifact/source failure; 5 install failure;
6 runtime/timeout failure; 7 invalid measurement or optional budget failure;
130 interrupted. A normal run writes run-report.json even when it fails.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import subprocess
import sys
import time
import uuid
import zipfile

import build_model_refinement_pilot as builder


PACKAGE = "com.glory.modelpilot"
OFFICIAL = "com.glory.game"
ACTIVITY = PACKAGE + "/com.godot.game.GodotAppLauncher"
REQUEST = "files/model_pilot_request.json"
RESULT = "files/model_pilot_perf.json"
LOG = "files/logs/model_pilot.log"
CASES = [
    {"variant": "old", "count": 6, "seconds": 30},
    {"variant": "new", "count": 6, "seconds": 30},
    {"variant": "old", "count": 12, "seconds": 30},
    {"variant": "new", "count": 12, "seconds": 180},
]
WARMUP_SECONDS = 2
MEASUREMENT_SECONDS = sum(c["seconds"] + WARMUP_SECONDS for c in CASES)
SCOPE = "isolated original/candidate real-model preview; not whole-game performance"
LOG_PROBLEM = re.compile(r"(?im)^\s*(?:SCRIPT ERROR:|ERROR:|WARNING:)|"
                         r"Parse Error:|MODEL_PREVIEW_REQUEST_ERROR|FATAL EXCEPTION")
# The Android emulator's GLES translator cannot reload Godot's cached program binaries,
# so every launch there logs this warning; tolerated on emulators only, real devices stay strict.
EMULATOR_ONLY_WARNING = "WARNING: Failed to load cached shader, recompiling."


def log_problems(text: str, emulator: bool) -> list[str]:
    return [line for line in text.splitlines() if LOG_PROBLEM.search(line)
            and not (emulator and line.strip() == EMULATOR_ONLY_WARNING)]


class PilotError(RuntimeError):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code


def require(condition: bool, code: int, message: str) -> None:
    if not condition:
        raise PilotError(code, message)


def note(message: str) -> None:
    print(f"[MODEL-RUN] {message}", flush=True)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    require(isinstance(value, dict), 4, f"Expected JSON object: {path}")
    return value


def command(args: list[str], timeout: float = 30, data: bytes | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)


class Device:
    def __init__(self, adb: Path, serial: str):
        self.adb = str(adb)
        self.serial = serial

    def redact(self, value: str) -> str:
        return value.replace(self.serial, "<selected-device>")

    def call(self, *args: str, timeout: float = 30, data: bytes | None = None,
             check: bool = True) -> subprocess.CompletedProcess:
        try:
            result = command([self.adb, "-s", self.serial, *args], timeout, data)
        except subprocess.TimeoutExpired as exc:
            raise PilotError(6, f"ADB command timed out after {timeout:g}s: {args[0]}") from exc
        if check and result.returncode:
            detail = self.redact((result.stdout + result.stderr).decode(errors="replace").strip())
            raise PilotError(6, f"ADB {args[0]} failed: {detail[:2000]}")
        return result

    def shell(self, *args: str, check: bool = True) -> str:
        # adb joins shell arguments itself: explicitly quote each remote token.
        result = self.call("shell", shlex.join(args), check=check)
        return self.redact(result.stdout.decode(errors="replace")).strip()

    def is_emulator(self) -> bool:
        return self.shell("getprop", "ro.kernel.qemu") == "1" or self.shell("getprop", "ro.boot.qemu") == "1"

    def authorize(self) -> None:
        result = command([self.adb, "devices"], timeout=20)
        require(result.returncode == 0, 3, "adb devices failed; check the Android platform-tools installation.")
        states = {}
        for line in result.stdout.decode(errors="replace").splitlines():
            fields = line.split()
            if len(fields) >= 2:
                states[fields[0]] = fields[1]
        state = states.get(self.serial, "not connected")
        require(state == "device", 3,
                "Selected device is " + state + ". Connect/unlock that device, enable USB debugging, "
                "accept its RSA authorization dialog, then rerun with its exact --serial. "
                "No package was installed or launched.")

    def private_read(self, relative: str) -> bytes | None:
        require(relative in {REQUEST, RESULT, LOG}, 6, "Unexpected private pilot path.")
        # Test existence first: some Android builds make exec-out return 0 even
        # when cat reports 'No such file'. Missing/partial JSON is never success.
        exists = self.call("shell", shlex.join(["run-as", PACKAGE, "test", "-f", relative]), check=False)
        if exists.returncode:
            return None
        result = self.call("exec-out", shlex.join(["run-as", PACKAGE, "cat", relative]))
        return result.stdout

    def package_identity(self, package: str) -> dict:
        require(package in {PACKAGE, OFFICIAL}, 6, "Unexpected Android package.")
        paths = self.shell("pm", "path", package, check=False)
        apks = [line.removeprefix("package:").strip() for line in paths.splitlines()
                if line.startswith("package:")]
        if not apks:
            # Android 16 returns status 1 with empty output for an uninstalled
            # package. Confirm absence using a successful package-list query;
            # transport/permission failures must not become "not installed".
            listing = self.shell("pm", "list", "packages", package)
            require("package:" + package not in listing.splitlines(), 6,
                    "Package exists but its APK path could not be read.")
            return {"installed": False, "package": package}
        dump = self.shell("dumpsys", "package", package)
        keys = ("versionCode=", "versionName=", "firstInstallTime=", "lastUpdateTime=", "userId=")
        metadata = sorted({line.strip() for line in dump.splitlines() if line.strip().startswith(keys)})
        hashes = []
        for apk in sorted(apks):
            require(apk.startswith("/data/app/") and apk.endswith(".apk"), 6,
                    "Unexpected installed APK path from package manager.")
            digest = self.shell("sha256sum", apk).split()[0]
            require(bool(re.fullmatch(r"[0-9a-f]{64}", digest)), 6, "Cannot hash installed APK.")
            hashes.append({"name": PurePosixPath(apk).name, "sha256": digest})
        return {"installed": True, "package": package, "metadata": metadata, "apks": hashes}

    def metadata(self) -> dict:
        battery = self.shell("dumpsys", "battery")
        values = {}
        for key in ("level", "temperature", "status", "plugged"):
            match = re.search(rf"(?m)^\s*{key}:\s*(-?\d+)", battery)
            if match:
                values[key] = int(match[1])
        if "temperature" in values:
            values["temperature_celsius"] = values["temperature"] / 10
        return {
            "manufacturer": self.shell("getprop", "ro.product.manufacturer"),
            "model": self.shell("getprop", "ro.product.model"),
            "android": self.shell("getprop", "ro.build.version.release"),
            "abi": self.shell("getprop", "ro.product.cpu.abi"),
            "screen_size": self.shell("wm", "size"), "battery": values, "emulator": self.is_emulator(),
        }

    def launch(self, out: Path) -> None:
        result = self.shell("am", "start", "-W", "-n", ACTIVITY)
        (out / "launch.log").write_text(result + "\n", encoding="utf-8")
        require("Error:" not in result and "Status: ok" in result, 6, "Pilot launch failed; see launch.log.")

    def foreground(self) -> bool:
        # Android 16 can omit per-display focus from the `windows` subset.
        windows = self.shell("dumpsys", "window")
        return any(PACKAGE in line for line in windows.splitlines()
                   if "mCurrentFocus=" in line or "mFocusedApp=" in line)


def find_tool(explicit: str | None, candidates: list[str], label: str) -> Path:
    choices = [explicit] if explicit else candidates
    result = builder.discover_executable(choices)
    require(result is not None, 4, f"{label} not found; pass its explicit tool-path option.")
    return result


def find_aapt(explicit: str | None) -> Path:
    suffix = ".exe" if os.name == "nt" else ""
    candidates = ["aapt"]
    for root in [os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"),
                 str(Path.home() / "Library/Android/sdk"), str(Path.home() / "Android/Sdk"),
                 "/opt/homebrew/share/android-commandlinetools",
                 str(Path(os.environ.get("LOCALAPPDATA", "")) / "Android/Sdk")]:
        if not root:
            continue
        folder = Path(root) / "build-tools"
        if folder.is_dir():
            versions = sorted(folder.iterdir(),
                              key=lambda p: tuple(int(v) for v in re.findall(r"\d+", p.name)), reverse=True)
            candidates.extend(str(p / f"aapt{suffix}") for p in versions)
    return find_tool(explicit, candidates, "Android aapt")


def verify_sources(source: Path, manifest: dict) -> list[str]:
    rows = manifest.get("files")
    require(isinstance(rows, list) and 0 < len(rows) <= builder.MAX_RESOURCES, 4, "Missing or invalid source resource manifest.")
    require(all(isinstance(manifest.get(key), str) and manifest[key] for key in builder.IDENTITY_KEYS), 4,
            "Manifest is missing the exact unit/model identity; rebuild with the current builder.")
    fingerprint = builder.source_fingerprint(rows, manifest)
    require(fingerprint == manifest.get("source_fingerprint"), 4, "Manifest fingerprint is invalid.")
    changed = []
    seen = set()
    for row in rows:
        require(isinstance(row, dict) and isinstance(row.get("path"), str), 4, "Invalid manifest entry.")
        relative = row["path"]
        require(relative not in seen, 4, f"Duplicate manifest resource: {relative}")
        seen.add(relative)
        try:
            path = builder.checked_resource(source, relative)
        except RuntimeError:
            changed.append(relative)
            continue
        if builder.sha256(path) != row.get("sha256") or path.stat().st_size != row.get("bytes"):
            changed.append(relative)
    # A newly added literal dependency must be represented too. Existing extra
    # --resource seeds are allowed, but stale/missing manifest entries are not.
    seeds = manifest.get("resource_seeds")
    require(isinstance(seeds, list) and bool(seeds) and all(isinstance(x, str) for x in seeds),
            4, "Missing explicit resource seeds in manifest.")
    closure = set(builder.resource_closure(source, seeds))
    changed.extend("unmanifested:" + path for path in sorted(closure - seen))
    return changed


def verify_artifact(source: Path, folder: Path, aapt: Path) -> dict:
    marker = read_json(folder / builder.GENERATED_MARKER)
    require(marker.get("package") == PACKAGE, 4, "Build directory is not a Model Refinement pilot output.")
    manifest = read_json(folder / "source-manifest.json")
    report = read_json(folder / "apk-report.json")
    apk = folder / "ModelRefinementPilot.apk"
    require(apk.is_file(), 4, "Missing ModelRefinementPilot.apk; run build_model_refinement_pilot.py --build first.")
    digest = builder.sha256(apk)
    require(report.get("package") == PACKAGE and report.get("export_verified") is True,
            4, "APK report is not a verified independent pilot export.")
    require(report.get("sha256") == digest and report.get("bytes") == apk.stat().st_size,
            4, "APK has changed since export verification.")
    scene = manifest.get("scene", "")
    require(manifest.get("package") == PACKAGE and isinstance(scene, str)
            and scene.startswith("res://") and scene.endswith(".tscn"),
            4, "Unexpected embedded preview identity.")
    require(scene.removeprefix("res://") in manifest.get("resource_seeds", []),
            4, "Preview scene is missing from the explicit resource seeds.")
    require(manifest.get("renderer") == "gl_compatibility", 4, "Unexpected pilot renderer.")
    require(bool(re.fullmatch(r"[a-z][a-z0-9_]{0,63}", str(manifest.get("unit_id", "")))), 4,
            "Manifest unit_id is invalid.")
    for key in ("old_model_path", "new_model_path"):
        require(isinstance(manifest.get(key), str) and manifest[key].startswith("res://"), 4,
                "Manifest model identity is invalid: " + key)
        require(manifest[key] in manifest.get("resource_seeds", []), 4,
                "Model identity is not an explicit resource seed: " + key)
    require(manifest["old_model_path"] != manifest["new_model_path"], 4, "A/B model paths are identical.")
    require(report.get("source_fingerprint") == manifest.get("source_fingerprint"),
            4, "APK and source report fingerprints differ.")
    with zipfile.ZipFile(apk) as archive:
        embedded = json.loads(archive.read("assets/model_build_info.json"))
    require(embedded == manifest, 4, "APK embedded source manifest differs from the build output.")
    badging = command([str(aapt), "dump", "badging", str(apk)])
    require(badging.returncode == 0, 4, "Cannot inspect Android package identity using aapt.")
    text = badging.stdout.decode(errors="replace")
    package_match = re.search(r"^package: name='([^']+)'", text, re.MULTILINE)
    require(package_match is not None and package_match[1] == PACKAGE, 4,
            "APK AndroidManifest package is not the independent pilot; refusing installation.")
    # Godot 4.7 exports an activity-alias. Some aapt versions omit aliases in
    # `dump badging`, so inspect the actual manifest tree as well.
    tree = command([str(aapt), "dump", "xmltree", str(apk), "AndroidManifest.xml"])
    xml = tree.stdout.decode(errors="replace")
    require(tree.returncode == 0 and all(token in xml for token in (
        '="com.godot.game.GodotAppLauncher"', '="com.godot.game.GodotApp"',
        '="android.intent.action.MAIN"', '="android.intent.category.LAUNCHER"')),
        4, "Unexpected pilot launch activity.")
    require("application-debuggable" in text, 4, "Pilot must be a debug APK for scoped run-as evidence capture.")
    changed = verify_sources(source, manifest)
    require(not changed, 4, "APK sources are stale; rebuild from current source. Changed: " + ", ".join(changed))
    return {"apk": str(apk), "sha256": digest, "bytes": apk.stat().st_size,
            "source_fingerprint": manifest["source_fingerprint"], "manifest": manifest,
            "current_source_matches": True, **{key: manifest[key] for key in builder.IDENTITY_KEYS}}


def install_if_needed(device: Device, artifact: dict, out: Path, timeout: float) -> bool:
    identity = device.package_identity(PACKAGE)
    expected = [{"name": "base.apk", "sha256": artifact["sha256"]}]
    if identity.get("apks") == expected:
        note("Installed pilot APK already matches; installation skipped.")
        return False
    note("Installing the verified independent pilot APK. If the phone asks, confirm Model Refinement Pilot only.")
    try:
        result = device.call("install", "-r", artifact["apk"], timeout=timeout, check=False)
    except PilotError as exc:
        raise PilotError(5, "Installation timed out. Inspect the phone's Model Refinement Pilot confirmation; "
                         "rerun after resolving it. No uninstall or data-clear will be attempted.") from exc
    text = device.redact((result.stdout + result.stderr).decode(errors="replace"))
    (out / "install.log").write_text(text, encoding="utf-8")
    require(result.returncode == 0 and re.search(r"(?m)^Success\s*$", text) is not None, 5,
            "Pilot installation failed; see install.log. For INSTALL_FAILED_UPDATE_INCOMPATIBLE, "
            "rebuild with --debug-keystore pointing to the previous pilot's runtime/pilot-debug.keystore. "
            "Do not uninstall the official game or clear either app's data.")
    require(device.package_identity(PACKAGE).get("apks") == expected, 5,
            "Installed APK hash does not match the verified artifact.")
    return True


def write_request(device: Device, request: dict, out: Path) -> None:
    device.shell("am", "force-stop", PACKAGE)
    require(device.shell("run-as", PACKAGE, "id").startswith("uid="), 6,
            "Pilot run-as unavailable; use the verified debug APK.")
    # A first install has not run Godot yet, so files/ may not exist. Create
    # only this independent pilot's standard evidence directory before writing.
    device.shell("run-as", PACKAGE, "mkdir", "-p", "files/logs")
    # Only runner-owned evidence files in the independent pilot sandbox.
    device.shell("run-as", PACKAGE, "rm", "-f", REQUEST, RESULT, LOG)
    require(device.private_read(RESULT) is None and device.private_read(LOG) is None, 6,
            "Could not remove stale pilot evidence.")
    payload = (json.dumps(request, ensure_ascii=False) + "\n").encode()
    remote = shlex.join(["run-as", PACKAGE, "sh", "-c", "cat > " + shlex.quote(REQUEST)])
    device.call("shell", remote, data=payload)
    raw = device.private_read(REQUEST)
    require(raw is not None and json.loads(raw) == request, 6, "Pilot request write/readback mismatch.")
    (out / "perf-request.json").write_bytes(payload)


def validate_result(result: dict, request: dict, fingerprint: str) -> dict:
    require(result.get("schema_version") == 1, 7, "Unsupported benchmark schema; rebuild the current preview.")
    require(result.get("run_id") == request["run_id"], 7, "Result run_id is not this request; stale result rejected.")
    require(result.get("source_fingerprint") == fingerprint, 7, "Runtime source fingerprint differs from the APK.")
    require(all(request.get(key) and result.get(key) == request[key] for key in builder.IDENTITY_KEYS), 7,
            "Runtime unit_id/old_model_path/new_model_path differs from this request.")
    require(result.get("completed") is True, 7, "Result is incomplete.")
    require(result.get("animation_mode") == ("animated" if request["animate"] else "frozen"),
            7, "Model animation mode differs from the request.")
    require(result.get("renderer") == "gl_compatibility" and result.get("os") == "Android", 7,
            "Unexpected rendering backend or execution platform.")
    require(bool(result.get("viewport")) and bool(result.get("gpu")), 7,
            "Runtime render size/GPU evidence is missing.")
    rows = result.get("results")
    require(isinstance(rows, list) and len(rows) == len(CASES), 7, "Expected all four benchmark cases.")
    for index, (row, expected) in enumerate(zip(rows, CASES), 1):
        require(isinstance(row, dict) and all(row.get(k) == v for k, v in expected.items()), 7,
                f"Case {index} does not match the requested matrix.")
        require(isinstance(row.get("frames"), (int, float)) and row["frames"] > 0, 7,
                f"Case {index} has no measured frames.")
        numbers = [row.get(k) for k in ("p50_ms", "p95_ms", "p99_ms")]
        require(all(isinstance(n, (int, float)) and math.isfinite(n) and n > 0 for n in numbers)
                and numbers == sorted(numbers), 7, f"Case {index} has invalid frame percentiles.")
        require(row.get("warmup_seconds") == WARMUP_SECONDS, 7, f"Case {index} warmup is unverified.")
        sampled = row.get("sampled_seconds")
        require(isinstance(sampled, (int, float)) and math.isfinite(sampled)
                and expected["seconds"] - 0.25 <= sampled <= expected["seconds"] + 2, 7,
                f"Case {index} wall-clock sample duration is invalid.")
        nodes = row.get("loop_end_node_counts")
        require(isinstance(nodes, list) and len(nodes) >= 2
                and all(isinstance(n, (int, float)) and n > 0 for n in nodes), 7,
                f"Case {index} lacks repeated lifecycle node samples.")
        require(len(set(nodes)) == 1, 7, f"Case {index} has changing loop-end node counts; inspect lifecycle cleanup.")
        for key in ("over_100ms", "peak_draw_calls", "peak_static_bytes"):
            require(isinstance(row.get(key), (int, float)) and row[key] >= 0, 7,
                    f"Case {index} lacks {key} evidence.")
    return {"four_cases_complete": True, "sample_durations_verified": True,
            "loop_end_nodes_stable": True, "actual_render_viewport": result["viewport"],
            "gpu": result["gpu"], "renderer": result["renderer"],
            "animation_mode": result["animation_mode"],
            "over_100ms_total": sum(row["over_100ms"] for row in rows)}


def collect_measurement(device: Device, out: Path, request: dict, fingerprint: str, timeout: float) -> dict:
    start = time.monotonic()
    next_progress = 0.0
    last_count = -1
    missing_process = 0
    emulator = device.is_emulator()
    while time.monotonic() - start < timeout:
        elapsed = time.monotonic() - start
        raw_log = device.private_read(LOG)
        log = raw_log.decode(errors="replace") if raw_log else ""
        if raw_log is not None:
            (out / "device-perf.log").write_bytes(raw_log)
        problems = log_problems(log, emulator)
        require(not problems, 6, "Pilot log has runtime errors/warnings: " + " | ".join(problems[:5]))
        raw = device.private_read(RESULT)
        result = None
        if raw:
            try:
                candidate = json.loads(raw)
                if isinstance(candidate, dict):
                    result = candidate
                    (out / "model_pilot_perf.json").write_bytes(raw)
            except (ValueError, UnicodeDecodeError):
                pass  # A write may be in progress; no partial JSON is success.
        count = len(result.get("results", [])) if result and isinstance(result.get("results"), list) else 0
        if elapsed >= next_progress or count != last_count:
            note(f"Measurement elapsed {elapsed:.0f}s; completed cases {count}/{len(CASES)}.")
            next_progress = elapsed + 20
            last_count = count
        if result and result.get("completed") is True and "MODEL_PERF_COMPLETE" in log:
            require(device.private_read(REQUEST) is None, 7, "One-shot request was not consumed.")
            validate_result(result, request, fingerprint)
            return result
        if elapsed > 15:
            alive = bool(device.shell("pidof", PACKAGE, check=False))
            missing_process = 0 if alive else missing_process + 1
            require(missing_process < 2, 6, "Pilot exited before completing the matrix; inspect device-perf.log.")
            require(device.foreground(), 6,
                    "Pilot lost foreground (screen lock/dialog/app switch); sample rejected. Unlock and rerun.")
        time.sleep(2)
    raise PilotError(6, f"Benchmark timed out after {timeout:g}s; partial evidence retained, no success claimed.")


def prepare_output(source: Path, build_dir: Path, out: Path) -> None:
    require(out != source and not out.is_relative_to(source) and not source.is_relative_to(out), 2,
            "--out must be outside and not a parent of the source project.")
    require(out != build_dir and not build_dir.is_relative_to(out) and not out.is_relative_to(build_dir), 2,
            "Use a separate --out directory next to the build output, not inside or above it.")
    require(not out.exists() or (out.is_dir() and not any(out.iterdir())), 2,
            "--out must be new or empty; previous evidence is never overwritten.")
    out.mkdir(parents=True, exist_ok=True)


def run(args: argparse.Namespace) -> int:
    source = args.project.expanduser().resolve()
    build_dir = args.build_dir.expanduser().resolve()
    out = args.out.expanduser().resolve()
    report = {"schema_version": 1, "status": "running", "scope": SCOPE,
              "started_utc": utc_now(), "package": PACKAGE, "official_package": OFFICIAL,
              "source_project": str(source), "build_dir": str(build_dir),
              "runner_sha256": builder.sha256(Path(__file__)),
              "operations_policy": {"only_mutated_package": PACKAGE, "uninstall": False,
                                    "clear_app_data": False, "official_data_read": False},
              "performance_budget": {"status": "not_evaluated", "max_p95_ms": args.max_p95_ms}}
    device = None
    artifact = None
    before = None
    out_ready = False
    exit_code = 0
    pilot_started = False
    try:
        require((source / "project.godot").is_file(), 4, "--project is not a Godot source project.")
        if not args.check:
            prepare_output(source, build_dir, out)
            out_ready = True
        adb = find_tool(args.adb, ["adb", "/opt/homebrew/bin/adb"], "adb")
        device = Device(adb, args.serial)
        device.authorize()
        aapt = find_aapt(args.aapt)
        artifact = verify_artifact(source, build_dir, aapt)
        require(args.unit_id == artifact["unit_id"], 4,
                "--unit-id differs from the APK manifest; refusing to test a different character.")
        report["artifact"] = {k: v for k, v in artifact.items() if k != "manifest"}
        report["device_before"] = device.metadata()
        before = device.package_identity(OFFICIAL)
        report["official_before"] = before
        report["pilot_before"] = device.package_identity(PACKAGE)
        git = command(["git", "-C", str(source), "rev-parse", "HEAD"])
        if git.returncode == 0:
            report["source_git_head"] = git.stdout.decode().strip()
        if args.check:
            report["status"] = "preflight_passed"
            report["device_mutated"] = False
            note("Read-only preflight passed: authorized device, package identity, APK and current source hashes verified.")
        else:
            builder.json_write(out / "source-manifest.json", artifact["manifest"])
            builder.json_write(out / "run-report.json", report)
            report["installed_this_run"] = install_if_needed(device, artifact, out, args.install_timeout)
            request = {"perf": True, "run_id": str(uuid.uuid4()), "animate": not args.freeze_model,
                       "cases": CASES, **{key: artifact[key] for key in builder.IDENTITY_KEYS}}
            report["run_id"] = request["run_id"]
            write_request(device, request, out)
            device.launch(out)
            pilot_started = True
            result = collect_measurement(device, out, request, artifact["source_fingerprint"], args.timeout)
            report["measurement"] = validate_result(result, request, artifact["source_fingerprint"])
            if args.max_p95_ms is not None:
                failed = [i + 1 for i, row in enumerate(result["results"]) if row["p95_ms"] > args.max_p95_ms]
                report["performance_budget"] = {"status": "failed" if failed else "passed",
                                                "max_p95_ms": args.max_p95_ms, "failed_cases": failed}
                require(not failed, 7, f"Configured P95 budget exceeded in cases {failed}.")
            # A completion record plus the verified preview source establishes
            # the reset to NEW / 1; capture current screen as evidence.
            require(device.foreground(), 6, "Pilot is no longer foreground at completion.")
            screenshot = device.call("exec-out", "screencap", "-p").stdout
            require(screenshot.startswith(b"\x89PNG\r\n\x1a\n"), 6, "Device screenshot capture failed.")
            (out / "device-final-loop.png").write_bytes(screenshot)
            report["left_running"] = {"variant": "new", "count": 1,
                                      "foreground": True, "screenshot": "device-final-loop.png"}
            report["status"] = "measurement_verified"
    except KeyboardInterrupt:
        exit_code = 130
        report.update(status="interrupted", error="Interrupted; partial evidence retained.")
    except (PilotError, OSError, ValueError, KeyError, zipfile.BadZipFile,
            subprocess.SubprocessError, RuntimeError) as exc:
        exit_code = exc.code if isinstance(exc, PilotError) else 4
        report.update(status="failed", error=device.redact(str(exc)) if device else str(exc))
    finally:
        if device is not None and before is not None:
            try:
                after = device.package_identity(OFFICIAL)
                report["official_after"] = after
                report["official_package_unchanged"] = before == after
                report["official_data_protection"] = "No commands access official app data; package metadata and all APK hashes compared."
                report["device_after"] = device.metadata()
                report["pilot_after"] = device.package_identity(PACKAGE)
                if before != after:
                    raise PilotError(7, "Official package changed during measurement; investigate external activity.")
                if artifact is not None and not args.check:
                    expected = [{"name": "base.apk", "sha256": artifact["sha256"]}]
                    report["apk_matches_installed"] = report["pilot_after"].get("apks") == expected
                    require(report["apk_matches_installed"], 7, "Installed pilot APK differs at completion.")
                    changed = verify_sources(source, artifact["manifest"])
                    report["source_changed_since_build"] = changed
                    require(not changed, 7, "Source changed during the run; rebuild and rerun.")
                if pilot_started and out_ready:
                    raw = device.private_read(LOG)
                    if raw is not None:
                        (out / "device-perf.log").write_bytes(raw)
                        problems = log_problems(raw.decode(errors="replace"), device.is_emulator())
                        report["godot_log_errors_or_warnings"] = problems
                        require(not problems, 6, "Final Godot log contains errors/warnings.")
            except (PilotError, OSError, ValueError, KeyError, RuntimeError) as exc:
                report["final_verification_error"] = device.redact(str(exc))
                report["status"] = "failed"
                exit_code = exit_code or (exc.code if isinstance(exc, PilotError) else 6)
        report["finished_utc"] = utc_now()
        report["exit_code"] = exit_code
        if out_ready:
            builder.json_write(out / "run-report.json", report)
        elif args.check:
            print(json.dumps(report, ensure_ascii=False, indent=2))
    if exit_code:
        note("FAIL: " + str(report.get("error") or report.get("final_verification_error")))
    else:
        note("PASS: " + report["status"] + "; scope is the isolated pilot only.")
    return exit_code


def positive_number(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be a finite positive number")
    return parsed


def main() -> int:
    # Windows consoles/pipes default to cp1252; paths (…/桌面/…) and audit notes are Chinese.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--serial", required=True, help="Exact adb device serial; never auto-selects a device")
    parser.add_argument("--build-dir", required=True, type=Path, help="Verified build_model_refinement_pilot.py output")
    parser.add_argument("--out", required=True, type=Path, help="New/empty evidence directory outside the source/build")
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--unit-id", default="god_guard", help="Must exactly match the APK unit identity")
    parser.add_argument("--adb", help="Android adb executable")
    parser.add_argument("--aapt", help="Android build-tools aapt executable")
    parser.add_argument("--check", action="store_true", help="Only read device/artifact/source state; write nothing")
    parser.add_argument("--freeze-model", action="store_true", help="Explicit static-model control; default is animated")
    parser.add_argument("--timeout", type=positive_number, default=MEASUREMENT_SECONDS + 90,
                        help="Whole benchmark timeout in seconds (default: %(default)s)")
    parser.add_argument("--install-timeout", type=positive_number, default=180,
                        help="Time allowed for OS installation/phone confirmation (default: %(default)s)")
    parser.add_argument("--max-p95-ms", type=positive_number,
                        help="Optional explicit P95 budget for every case; omitted means no performance budget claim")
    args = parser.parse_args()
    if not args.serial.strip():
        parser.error("--serial must not be empty")
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
