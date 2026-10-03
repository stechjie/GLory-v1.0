#!/usr/bin/env python3
"""Run the isolated real-BattleScreen Android capture, preserving official data.

--check reads only. Normal runs install only com.glory.modelbattlepilot, write a
fresh one-shot run_id in its own sandbox, and pull engine screenshots/evidence.
This is offline real battle presentation validation, not a release, multiplayer,
or whole-game performance certification. Never uninstall or clear app data.
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
import build_model_battle_pilot as battle
builder = battle.common
PACKAGE = battle.PACKAGE
OFFICIAL = "com.glory.game"
ACTIVITY = PACKAGE + "/com.godot.game.GodotAppLauncher"
REQUEST = "files/model_battle_request.json"
RESULT = "files/model_battle_evidence/not-started/evidence.json"
LOG = "files/logs/model_battle_pilot.log"
LOG_PROBLEM = re.compile(r"(?im)^\s*(?:SCRIPT ERROR:|ERROR:)|Parse Error:|MODEL_BATTLE_REQUEST_ERROR|FATAL EXCEPTION")
SCOPE = "isolated offline Android package through actual FixedBattleFixture -> BattleSimulator -> BattleScreen -> actor model resolution"

class PilotError(RuntimeError):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code


def require(condition: bool, code: int, message: str) -> None:
    if not condition:
        raise PilotError(code, message)


def note(message: str) -> None:
    print(f"[MODEL-BATTLE-RUN] {message}", flush=True)


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
        require(relative in {REQUEST, RESULT, LOG} or (relative.startswith(RESULT.rsplit("/", 1)[0] + "/")
                and re.fullmatch(r"[A-Za-z0-9_-]+\.png", relative.rsplit("/", 1)[-1]) is not None),
                6, "Unexpected private pilot path.")
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
            "screen_size": self.shell("wm", "size"), "battery": values,
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


def install_if_needed(device: Device, artifact: dict, out: Path, timeout: float) -> bool:
    identity = device.package_identity(PACKAGE)
    expected = [{"name": "base.apk", "sha256": artifact["sha256"]}]
    if identity.get("apks") == expected:
        note("Installed pilot APK already matches; installation skipped.")
        return False
    note("Installing the verified independent pilot APK. If the phone asks, confirm Model Battle Pilot only.")
    try:
        result = device.call("install", "-r", artifact["apk"], timeout=timeout, check=False)
    except PilotError as exc:
        raise PilotError(5, "Installation timed out. Inspect the phone's Model Battle Pilot confirmation; "
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


def prepare_output(source: Path, build_dir: Path, out: Path) -> None:
    require(out != source and not out.is_relative_to(source) and not source.is_relative_to(out), 2,
            "--out must be outside and not a parent of the source project.")
    require(out != build_dir and not build_dir.is_relative_to(out) and not out.is_relative_to(build_dir), 2,
            "Use a separate --out directory next to the build output, not inside or above it.")
    require(not out.exists() or (out.is_dir() and not any(out.iterdir())), 2,
            "--out must be new or empty; previous evidence is never overwritten.")
    out.mkdir(parents=True, exist_ok=True)


def verify_sources(source: Path, manifest: dict) -> list[str]:
    rows = manifest.get("files")
    require(isinstance(rows, list) and 0 < len(rows) < 100000, 4, "Invalid runtime source inventory.")
    calculated = hashlib.sha256(json.dumps({"files": rows, "generated": manifest.get("generated"),
        "expected_model": manifest.get("expected_model")}, sort_keys=True).encode()).hexdigest()
    require(calculated == manifest.get("source_fingerprint"), 4, "Source inventory fingerprint is invalid.")
    changed = []
    seen = set()
    for row in rows:
        relative = row["path"]
        require(relative not in seen, 4, "Duplicate source inventory path.")
        seen.add(relative)
        try:
            path = builder.checked_resource(source, relative)
        except RuntimeError:
            changed.append(relative)
            continue
        if builder.sha256(path) != row.get("sha256") or path.stat().st_size != row.get("bytes"):
            changed.append(relative)
    changed.extend("unmanifested:" + name for name in sorted(set(battle.inventory(source)) - seen))
    return changed


def verify_artifact(source: Path, folder: Path, aapt: Path) -> dict:
    marker = read_json(folder / battle.MARKER)
    require(marker.get("package") == PACKAGE, 4, "This is not a model battle pilot output.")
    manifest = read_json(folder / "source-manifest.json")
    report = read_json(folder / "apk-report.json")
    apk = folder / battle.APK
    require(manifest.get("package") == PACKAGE and manifest.get("scene") == "res://" + battle.MAIN,
            4, "Wrong battle pilot identity/main scene.")
    require(manifest.get("expected_model") and manifest["expected_model"].startswith("res://"), 4, "Expected model identity is missing.")
    require(report.get("export_verified") is True and report.get("package") == PACKAGE and apk.is_file(), 4, "A verified battle APK is required.")
    digest = builder.sha256(apk)
    require(report.get("sha256") == digest and report.get("bytes") == apk.stat().st_size, 4, "APK changed since export.")
    require(report.get("source_fingerprint") == manifest.get("source_fingerprint"), 4, "APK/source report fingerprint mismatch.")
    with zipfile.ZipFile(apk) as archive:
        embedded = json.loads(archive.read("assets/" + battle.METADATA))
    require(embedded == manifest, 4, "Embedded build metadata differs from the source manifest.")
    badge = command([str(aapt), "dump", "badging", str(apk)])
    badge_text = badge.stdout.decode(errors="replace")
    require(badge.returncode == 0 and f"package: name='{PACKAGE}'" in badge_text
            and "application-debuggable" in badge_text, 4, "APK is not the isolated debuggable package.")
    permissions = command([str(aapt), "dump", "permissions", str(apk)])
    perm_text = permissions.stdout.decode(errors="replace")
    require(permissions.returncode == 0 and "android.permission.INTERNET" not in perm_text
            and "android.permission.RECORD_AUDIO" not in perm_text, 4, "Offline/microphone permission isolation failed.")
    changed = verify_sources(source, manifest)
    require(not changed, 4, "APK is stale against source: " + ", ".join(changed[:20]))
    return {"apk": str(apk), "sha256": digest, "bytes": apk.stat().st_size,
            "source_fingerprint": manifest["source_fingerprint"], "expected_model": manifest["expected_model"],
            "manifest": manifest, "current_source_matches": True}


def validate_result(result: dict, run_id: str, artifact: dict) -> None:
    require(result.get("schema_version") == 1 and result.get("run_id") == run_id, 7, "Stale/wrong capture result.")
    require(result.get("source_fingerprint") == artifact["source_fingerprint"], 7, "Runtime source fingerprint mismatch.")
    require(result.get("status") == "PASS" and result.get("failures") == []
            and result.get("playback_completed") is True, 7, "The actual BattleScreen replay did not fully pass.")
    require(result.get("os") == "Android" and result.get("renderer") == "gl_compatibility", 7, "Capture is not Android Compatibility.")
    require(result.get("expected_model") == artifact["expected_model"]
            and result.get("observed_model_paths") == [artifact["expected_model"]], 7, "Real actor model differs from the candidate mapping.")
    require(bool(result.get("model_actors")) and bool(result.get("guardians")) and bool(result.get("playing_animations_seen")) and result.get("animation_advanced") is True,
            7, "Real model/animation evidence is missing.")
    shots = result.get("screenshots")
    require(isinstance(shots, list) and len(shots) >= 3 and all(s.get("save_error") == 0 for s in shots),
            7, "Missing/failed engine screenshots.")
    require(any(s.get("file") == "05-timeline-end.png" for s in shots), 7, "No final replay-frame screenshot.")
    require(len(result.get("samples", [])) >= 2 and result.get("replay_frames", 0) > 0, 7, "Missing replay timeline evidence.")


def collect(device: Device, out: Path, run_id: str, artifact: dict, timeout: float) -> dict:
    started = time.monotonic(); next_note = 0.0; missing = 0
    while time.monotonic() - started < timeout:
        elapsed = time.monotonic() - started
        raw_log = device.private_read(LOG)
        log = raw_log.decode(errors="replace") if raw_log else ""
        if raw_log: (out / "device-battle.log").write_bytes(raw_log)
        problems = [line for line in log.splitlines() if LOG_PROBLEM.search(line)]
        require(not problems, 6, "Battle runtime error: " + " | ".join(problems[:4]))
        raw = device.private_read(RESULT)
        if raw:
            try: result = json.loads(raw)
            except ValueError: result = None
            if isinstance(result, dict):
                (out / "evidence.json").write_bytes(raw)
                validate_result(result, run_id, artifact)
                # The capture closes its JSON before printing the completion
                # line. Two separate ADB reads can straddle that instant.
                if "MODEL_BATTLE_RESULT status=PASS" not in log:
                    time.sleep(0.25)
                    continue
                for shot in result["screenshots"]:
                    filename = shot.get("file", "")
                    require(isinstance(filename, str) and re.fullmatch(r"[A-Za-z0-9_-]+\.png", filename) is not None,
                            7, "Invalid screenshot filename.")
                    data = device.private_read(RESULT.rsplit("/", 1)[0] + "/" + filename)
                    require(data is not None and data.startswith(b"\x89PNG\r\n\x1a\n"), 7, "Screenshot bytes are missing.")
                    (out / filename).write_bytes(data)
                return result
        if elapsed >= next_note:
            note(f"Waiting for actual BattleScreen capture: {elapsed:.0f}s elapsed")
            next_note = elapsed + 20
        if elapsed > 15:
            alive = bool(device.shell("pidof", PACKAGE, check=False))
            missing = 0 if alive else missing + 1
            require(missing < 2, 6, "Battle pilot exited without valid evidence.")
            if alive:
                require(device.foreground(), 6, "Battle pilot lost foreground; visual evidence rejected.")
        time.sleep(2)
    raise PilotError(6, "Actual BattleScreen capture timed out; partial evidence retained.")


def run(args: argparse.Namespace) -> int:
    global RESULT
    source = args.project.expanduser().resolve(); folder = args.build_dir.expanduser().resolve(); out = args.out.expanduser().resolve()
    report = {"schema_version":1, "status":"running", "scope":SCOPE, "package":PACKAGE, "started_utc":utc_now(),
              "operations_policy":{"only_mutated_package":PACKAGE,"uninstall":False,"clear_app_data":False,"official_app_data_read":False}}
    device = None; before = None; artifact = None; output_ready = False; code = 0
    try:
        if not args.check: prepare_output(source,folder,out); output_ready = True
        device = Device(find_tool(args.adb,["adb","/opt/homebrew/bin/adb"],"adb"),args.serial); device.authorize()
        artifact = verify_artifact(source,folder,find_aapt(args.aapt))
        report["artifact"] = {key:value for key,value in artifact.items() if key != "manifest"}
        before = device.package_identity(OFFICIAL); report["official_before"] = before; report["device_before"] = device.metadata()
        if args.check:
            report["status"] = "preflight_passed"; report["device_mutated"] = False
        else:
            builder.json_write(out / "run-report.json",report)
            report["installed_this_run"] = install_if_needed(device,artifact,out,args.install_timeout)
            run_id = str(uuid.uuid4()); report["run_id"] = run_id
            RESULT = "files/model_battle_evidence/" + run_id + "/evidence.json"
            write_request(device,{"run_id":run_id},out)
            device.launch(out)
            result = collect(device,out,run_id,artifact,args.timeout)
            report["capture"] = {key:result.get(key) for key in ("status","playback_completed","observed_model_paths","playing_animations_seen","replay_frames","gpu","viewport")}
            report["screenshots"] = [s["file"] for s in result["screenshots"]]
            report["status"] = "offline_battle_presentation_verified"
    except KeyboardInterrupt:
        code = 130; report.update(status="interrupted",error="Interrupted; evidence retained.")
    except (PilotError,OSError,ValueError,KeyError,RuntimeError,subprocess.SubprocessError,zipfile.BadZipFile) as exc:
        code = exc.code if isinstance(exc,PilotError) else 4
        report.update(status="failed",error=device.redact(str(exc)) if device else str(exc))
    finally:
        if device is not None and before is not None:
            try:
                after = device.package_identity(OFFICIAL); report["official_after"] = after
                report["official_package_unchanged"] = after == before
                require(after == before,7,"Official package changed during the capture.")
                report["device_after"] = device.metadata()
                if not args.check and artifact is not None:
                    installed = device.package_identity(PACKAGE)
                    require(installed.get("apks") == [{"name":"base.apk","sha256":artifact["sha256"]}],7,"Installed pilot APK changed.")
                    changed = verify_sources(source,artifact["manifest"]); report["source_changed_since_build"] = changed
                    require(not changed,7,"Source changed during capture; rebuild and rerun.")
                    raw_log = device.private_read(LOG)
                    if raw_log:
                        (out / "device-battle.log").write_bytes(raw_log)
                        problems = [line for line in raw_log.decode(errors="replace").splitlines() if LOG_PROBLEM.search(line)]
                        report["final_runtime_errors"] = problems
                        require(not problems,6,"Final battle log contains runtime errors.")
            except (PilotError,OSError,ValueError,KeyError,RuntimeError) as exc:
                code = code or (exc.code if isinstance(exc,PilotError) else 6)
                report.update(status="failed",final_verification_error=device.redact(str(exc)))
        report["finished_utc"] = utc_now(); report["exit_code"] = code
        if output_ready: builder.json_write(out / "run-report.json",report)
        else: print(json.dumps(report,ensure_ascii=False,indent=2))
    note(("PASS: " if code == 0 else "FAIL: ") + report["status"])
    return code


def positive(value: str) -> float:
    n=float(value)
    if not math.isfinite(n) or n <= 0: raise argparse.ArgumentTypeError("must be positive and finite")
    return n


def main() -> int:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--serial",required=True); p.add_argument("--build-dir",required=True,type=Path); p.add_argument("--out",required=True,type=Path)
    p.add_argument("--project",type=Path,default=Path(__file__).resolve().parents[1]); p.add_argument("--adb"); p.add_argument("--aapt")
    p.add_argument("--check",action="store_true"); p.add_argument("--timeout",type=positive,default=270); p.add_argument("--install-timeout",type=positive,default=180)
    args=p.parse_args()
    if not args.serial.strip(): p.error("--serial cannot be empty")
    return run(args)

if __name__ == "__main__": sys.exit(main())
