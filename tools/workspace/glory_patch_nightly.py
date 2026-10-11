#!/usr/bin/env python3
"""Build cumulative Android/iOS patches; optionally publish verified internal releases."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import time
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

TOOLS = Path(__file__).resolve().parent
# workspace -> tools -> GLory-v1.0 -> repository root
ROOT = TOOLS.parents[2]
sys.path.insert(0, str(TOOLS))
import glory_build as build  # noqa: E402
from export_patch import export as export_patch  # noqa: E402

RECORD = ROOT / "delivery/patch-release-20261011/release-record.json"
API = "https://glorytd-api.duckdns.org"
FIREBASE = "glory-patches.web.app"
CHANNEL = "internal"
KEYCHAIN_SERVICE = "com.glory.patch-uploader"
KEYCHAIN_ACCOUNT = "automated-upload"
NIGHTLY_PROJECT = ROOT / "build/patch-nightly-source"
NIGHTLY_BRANCH = "codex/nightly-patch"


def write(path: Path, value: dict) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    os.replace(temporary, path)


def token_from_keychain() -> str:
    result = subprocess.run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE,
                             "-a", KEYCHAIN_ACCOUNT, "-w"], capture_output=True, text=True)
    if result.returncode or not result.stdout.strip():
        raise RuntimeError(f"Missing scoped patch upload token in Keychain ({KEYCHAIN_SERVICE})")
    return result.stdout.strip()


def api(method: str, path: str, token: str, body: dict | None = None,
        content: bytes | None = None):
    headers = {"Authorization": f"Bearer {token}"}
    data = content
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    if content is not None:
        headers["Content-Type"] = "application/zip"
    request = urllib.request.Request(API + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=1800) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        detail = error.read(4096).decode("utf-8", "replace")
        raise RuntimeError(f"Patch API {method} failed ({error.code}): {detail}") from None
    if not raw:
        return {}
    return json.loads(raw)


def publish_release(release_id: str, token: str) -> dict:
    path = f"/admin/api/patches/automation/{release_id}"
    status = api("GET", path, token)
    if not status["active"]:
        api("POST", path + "/publish", token, {"expected_revision": status["revision"]})
    confirmed = api("GET", path, token)
    if not confirmed["active"] or confirmed["release"]["status"] != "published":
        raise RuntimeError("Server did not confirm internal patch publication")
    return confirmed


def prepare_nightly_project() -> Path:
    repository = ROOT / "GLory-v1.0"
    remote_ref = build.capture(["git", "-C", repository, "rev-parse", "--abbrev-ref",
                                "--symbolic-full-name", "@{upstream}"])
    build.capture(["git", "-C", repository, "fetch", "--no-tags", "origin"])
    if not NIGHTLY_PROJECT.exists():
        branch = subprocess.run(["git", "-C", repository, "show-ref", "--verify", "--quiet",
                                 f"refs/heads/{NIGHTLY_BRANCH}"])
        command = (["git", "-C", repository, "worktree", "add", str(NIGHTLY_PROJECT), NIGHTLY_BRANCH]
                   if branch.returncode == 0 else
                   ["git", "-C", repository, "worktree", "add", "-b", NIGHTLY_BRANCH,
                    str(NIGHTLY_PROJECT), remote_ref])
        subprocess.run(command, check=True)
        subprocess.run(["git", "-C", NIGHTLY_PROJECT, "branch", "--set-upstream-to", "origin/main"],
                       check=True, stdout=subprocess.DEVNULL)
    if build.capture(["git", "-C", NIGHTLY_PROJECT, "rev-parse", "--show-toplevel"]) != str(NIGHTLY_PROJECT):
        raise RuntimeError("Nightly source path is not the expected isolated Git worktree")
    if build.capture(["git", "-C", NIGHTLY_PROJECT, "status", "--porcelain"]):
        raise RuntimeError("Nightly worktree contains local changes; inspect it before continuing")
    return NIGHTLY_PROJECT


def check_sources(project: Path) -> str:
    for attempt in range(30):
        result = subprocess.run([sys.executable, str(TOOLS / "glory_update.py"), "--project", str(project)],
                                cwd=ROOT, check=False, capture_output=True, text=True)
        if result.returncode == 0:
            print(result.stdout, end="")
            break
        detail = result.stdout + result.stderr
        if "已有 APK 构建在运行" not in detail or attempt == 29:
            raise RuntimeError("GitHub/Drive sync failed; no patch was built or uploaded. "
                               "See build/patch-nightly logs for the source update result.")
        time.sleep(30)
    return build.capture(["git", "-C", project, "rev-parse", "HEAD"])


def run(args) -> int:
    with build.file_lock(ROOT / "build/.patch-nightly.lock", nonblocking=True):
        if args.sync:
            project = prepare_nightly_project()
            commit = check_sources(project)
        else:
            project = ROOT / "GLory-v1.0"
            commit = build.capture(["git", "-C", project, "rev-parse", "HEAD"])
        if build.capture(["git", "-C", project, "status", "--porcelain"]):
            raise RuntimeError("Git tree is not clean after source sync; refusing to export a mixed revision")
        record_path = args.record or RECORD
        record = json.loads(record_path.read_text())
        base_id = record.get("base_id", "")
        if record.get("channel") != CHANNEL or not base_id:
            raise RuntimeError("Base record must identify the current internal client builds")
        run_id = dt.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
        run_dir = ROOT / "build/patch-nightly" / run_id
        run_dir.mkdir(parents=True)
        state_path = run_dir / "state.json"
        state = {"status": "running", "source_commit": commit, "base_id": base_id,
                 "channel": CHANNEL, "run_id": run_id, "patches": {}}
        write(state_path, state)
        asset_root = build.asset_root(ROOT / "res")
        config = run_dir / "patch-config.json"
        config.write_text(json.dumps({"base_id": base_id, "channel": CHANNEL,
            "backend_url": API, "firebase_host": FIREBASE}, indent=2) + "\n")
        inventories = {}
        for platform in ("android", "ios"):
            target = record["platforms"][platform]
            base_zip = Path(target["baseline"])
            base_manifest = Path(target["baseline_manifest"])
            engine = Path(target["engine"])
            if not base_zip.is_file() or not base_manifest.is_file() or not engine.is_file():
                raise RuntimeError(f"Missing immutable {platform} baseline or export engine")
            stage = run_dir / f"{platform}-stage"
            logdir = run_dir / f"{platform}-stage-log"
            logdir.mkdir()
            report = build.stage_project(project, asset_root, stage, logdir)
            preset_source = Path(target["source_snapshot"]) / "export_presets.cfg"
            if not preset_source.is_file():
                raise RuntimeError(f"Missing retained {platform} export preset: {preset_source}")
            (stage / "export_presets.cfg").write_bytes(preset_source.read_bytes())
            build_info_source = Path(target["source_snapshot"]) / "build_info.json"
            if not build_info_source.is_file():
                raise RuntimeError(f"Missing retained {platform} client build metadata: {build_info_source}")
            (stage / "build_info.json").write_bytes(build_info_source.read_bytes())
            # These engine recording flags cannot change inside an installed baseline.
            # Preserve their installed values; all other immutable differences still fail export.
            import re
            settings = stage / "project.godot"
            retained = (Path(target["source_snapshot"]) / "project.godot").read_text()
            current = settings.read_text()
            for name in ("windows", "android", "ios"):
                pattern = rf"^driver/enable_input\.{name}=.*\n"
                before = re.findall(pattern, retained, flags=re.M)
                after = re.findall(pattern, current, flags=re.M)
                if before != after:
                    if before or after != [f"driver/enable_input.{name}=true\n"]:
                        raise RuntimeError("Unrecognized baseline recording setting change")
                    current = re.sub(pattern, "", current, flags=re.M)
                    state.setdefault("retained_base_settings", []).append(name)
            settings.write_text(current)
            inventories[platform] = report["actual_assets_sha256"]
            state["patches"][platform] = {"assets_sha256": report["actual_assets_sha256"]}
            write(state_path, state)
        signature = hashlib.sha256((commit + "\n" + json.dumps(inventories, sort_keys=True)
                                    + "\n" + base_id).encode()).hexdigest()
        state["source_signature"] = signature
        latest_path = ROOT / "build/patch-nightly/latest.json"
        latest = json.loads(latest_path.read_text()) if latest_path.is_file() else {}
        if latest.get("status") == "complete" and latest.get("source_signature") == signature:
            if args.publish and not args.build_only:
                state["publication"] = publish_release(latest["release_id"], token_from_keychain())
            state.update(status="no_changes", message="This source/base combination was already uploaded")
            write(state_path, state)
            print(f"[patch-nightly] No new source changes: {state_path}")
            return 0
        write(state_path, state)
        for platform in ("android", "ios"):
            target = record["platforms"][platform]
            base_zip = Path(target["baseline"])
            engine = Path(target["engine"])
            stage = run_dir / f"{platform}-stage"
            output = run_dir / platform
            try:
                result = export_patch(stage=stage, engine=engine,
                    preset=target["preset"], platform=platform, config=config,
                    output=output, base=base_zip)
            except ValueError as error:
                if str(error) == "No changed resources; there is no patch to publish":
                    state.update(status="no_changes", message="No client-exported resources changed")
                    write(state_path, state)
                    print(f"[patch-nightly] No resource changes: {state_path}")
                    return 0
                raise
            state["patches"][platform].update({**result, "zip": str(output / f"{platform}.zip")})
            write(state_path, state)
        if args.build_only:
            state.update(status="built", message="Patch ZIPs built locally; nothing uploaded")
            write(state_path, state)
            print(f"[patch-nightly] Build complete: {state_path}")
            return 0
        title = f"自动资源补丁 {dt.datetime.now().strftime('%Y-%m-%d')} · {signature[:12]}"
        token = token_from_keychain()
        created = api("POST", "/admin/api/patches/automation/drafts", token,
                      {"channel": CHANNEL, "title": title, "platforms": ["android", "ios"]})
        release_id = created["release_id"]
        state["release_id"] = release_id
        write(state_path, state)
        for platform in ("android", "ios"):
            patch_path = Path(state["patches"][platform]["zip"])
            query = urllib.parse.urlencode({"base_id": base_id})
            result = api("PUT", f"/admin/api/patches/automation/{release_id}/artifacts/{platform}?{query}",
                         token, content=patch_path.read_bytes())
            if result.get("status") != "complete":
                raise RuntimeError(f"Server did not confirm {platform} upload")
            state["patches"][platform]["uploaded"] = True
            write(state_path, state)
        if args.publish:
            state["publication"] = publish_release(release_id, token)
        state.update(status="complete", title=title,
                     message="Both artifacts verified; internal release published" if args.publish else "Both artifacts verified; draft is ready for operator review")
        write(state_path, state)
        write(latest_path, {"status": "complete", "source_signature": signature,
                            "state": str(state_path), "release_id": release_id})
        print(f"[patch-nightly] {'Published' if args.publish else 'Draft ready'}: {title} ({release_id})")
        return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sync", action="store_true", help="fast-forward Git and sync canonical Drive assets first")
    parser.add_argument("--build-only", action="store_true", help="build verified local ZIPs without backend credentials or upload")
    parser.add_argument("--publish", action="store_true", help="publish verified internal Android/iOS release using scoped machine credentials")
    parser.add_argument("--record", type=Path, help="current-client base record (default: retained 2026-10-11 build)")
    args = parser.parse_args()
    try:
        return run(args)
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"[patch-nightly] Stopped: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
