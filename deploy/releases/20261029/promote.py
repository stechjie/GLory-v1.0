#!/usr/bin/env python3
"""Promote the verified 2026-10-29 source bundle to glory-server-3."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import time
import zipfile
from pathlib import Path


COMMIT = "80b46b8611f4f4b5171e6003e55f52f8732be3ca"
PROTOCOL = 45
SOURCE = Path("/opt/glory/src")
RUNTIME = Path("/opt/glory/repo")
ARCHIVE = Path("/home/bytegame2025/glory-server-3/server.zip")
ARCHIVE_SHA256 = "5c89aa66aa2c101172e029bd36f30e329c857e06e23a512d4fe4bfef66aadf01"
STAGE = Path("/var/backups/glory/server-20261029-80b46b86")
RELEASE = Path("/home/nins17121/Glory/releases/1.0.2-20261029-80b46b86")
CONF = Path("/etc/systemd/system/glory-server.service.d/99-glory-current.conf")
DATA_FILES = (
    "avatars.json",
    "blocked_words.txt",
    "shop.json",
    "seven_day_login.json",
    "pets/pets.json",
    "balance/final_status.json",
    "iap_products.json",
)


def run(command: list[str], **kwargs) -> str:
    try:
        return subprocess.check_output(
            command, text=True, stderr=subprocess.STDOUT, **kwargs
        ).strip()
    except subprocess.CalledProcessError as error:
        print(error.output, flush=True)
        raise


def sha(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def pid(service: str) -> str:
    return run(["systemctl", "show", service, "-p", "MainPID", "--value"])


def service_log(service: str, process_id: str) -> str:
    return run(
        [
            "journalctl",
            "-u",
            service,
            f"_PID={process_id}",
            "--no-pager",
            "-o",
            "cat",
        ]
    )


def active_connections() -> tuple[int, int]:
    battle_log = service_log("glory-server", pid("glory-server"))
    battle_peers: set[str] = set()
    for line in battle_log.splitlines():
        match = re.search(r"\[NET\] client (connected|disconnected) peer=(\d+)", line)
        if match:
            if match.group(1) == "connected":
                battle_peers.add(match.group(2))
            else:
                battle_peers.discard(match.group(2))

    account_log = service_log("glory-backend", pid("glory-backend"))
    account_players: set[str] = set()
    for line in account_log.splitlines():
        connected = re.search(r"WS 连接建立 player=([0-9a-f-]+)", line)
        disconnected = re.search(r"WS 断开 player=([0-9a-f-]+)", line)
        if connected:
            account_players.add(connected.group(1))
        if disconnected:
            account_players.discard(disconnected.group(1))
    return len(account_players), len(battle_peers)


def assert_idle() -> dict:
    checks = []
    for _ in range(2):
        account, battle = active_connections()
        if account or battle:
            raise RuntimeError(
                f"Players became active; account={account}, battle={battle}"
            )
        checks.append(
            {
                "account_online": account,
                "battle_connections": battle,
                "checked_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            }
        )
        time.sleep(3)
    return {"checks": checks}


def main() -> int:
    if os.geteuid() != 0:
        raise RuntimeError("Run as root")
    if sha(ARCHIVE) != ARCHIVE_SHA256:
        raise RuntimeError("Uploaded server.zip hash mismatch")
    if STAGE.exists() or RELEASE.exists():
        raise RuntimeError("Release or backup directory already exists")

    STAGE.mkdir(parents=True)
    release_source = STAGE / "source"
    release_source.mkdir()
    previous_conf = CONF.read_text()
    old_pid = pid("glory-server")
    idle = assert_idle()

    run(["git", "-C", str(SOURCE), "fetch", "origin", "codex/release-20261013-sync"])
    archive = subprocess.check_output(
        [
            "git",
            "-C",
            str(SOURCE),
            "archive",
            "--format=tar",
            COMMIT,
            "backend",
            "database",
            *[f"data/{name}" for name in DATA_FILES],
        ]
    )
    subprocess.run(
        ["tar", "-x", "-C", str(release_source)],
        input=archive,
        check=True,
    )

    RELEASE.mkdir(parents=True)
    with zipfile.ZipFile(ARCHIVE) as package:
        package.extractall(RELEASE)
    manifest = json.loads((RELEASE / "server_bundle_manifest.json").read_text())
    if manifest["git_sha"] != COMMIT or manifest["protocol"] != PROTOCOL:
        raise RuntimeError("Server manifest identity mismatch")
    for row in manifest["files"]:
        target = RELEASE / row["path"]
        if not target.is_file() or sha(target) != row["sha256"]:
            raise RuntimeError(f"Bundle file mismatch: {row['path']}")

    backend_before = STAGE / "backend-before"
    backend_before.mkdir()
    backend_changes = {}
    live_backend = RUNTIME / "backend"
    for source_file in (release_source / "backend").rglob("*"):
        if not source_file.is_file() or "__pycache__" in source_file.parts:
            continue
        relative = source_file.relative_to(release_source / "backend")
        live_file = live_backend / relative
        new_hash = sha(source_file)
        old_hash = sha(live_file) if live_file.is_file() else None
        if new_hash == old_hash:
            continue
        backup = backend_before / relative
        if live_file.is_file():
            backup.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(live_file, backup)
        backend_changes[str(relative)] = {
            "old_sha256": old_hash,
            "new_sha256": new_hash,
        }

    data_before = STAGE / "data-before"
    data_before.mkdir()
    for relative in DATA_FILES:
        live_file = RUNTIME / "data" / relative
        if live_file.is_file():
            backup = data_before / relative
            backup.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(live_file, backup)

    run(["chown", "-R", "nins17121:nins17121", str(RELEASE)])
    (STAGE / "previous.conf").write_text(previous_conf)

    backend_switched = False
    battle_switched = False
    try:
        for relative, change in backend_changes.items():
            target = live_backend / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(release_source / "backend" / relative, target)
            target.chmod(0o644)
            if sha(target) != change["new_sha256"]:
                raise RuntimeError(f"Backend update mismatch: {relative}")
        for relative in DATA_FILES:
            source_file = release_source / "data" / relative
            target = RUNTIME / "data" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_file, target)
            target.chmod(0o644)
        run(["chown", "-R", "root:root", str(RUNTIME)])
        run(["chmod", "-R", "a+rX", str(RUNTIME)])
        backend_switched = True
        run(["systemctl", "restart", "glory-backend"], timeout=45)
        for _ in range(30):
            time.sleep(0.5)
            try:
                health = json.loads(
                    run(
                        [
                            "curl",
                            "-fsS",
                            "--max-time",
                            "3",
                            "http://127.0.0.1:8099/health",
                        ]
                    )
                )
                if health.get("status") == "ok" and health.get("configured"):
                    break
            except subprocess.CalledProcessError:
                pass
        else:
            raise RuntimeError("Backend did not become healthy")

        candidate = previous_conf.replace(
            next(
                line.split("--path ", 1)[1].split()[0]
                for line in previous_conf.splitlines()
                if line.startswith("ExecStart=") and "--path " in line
            ),
            str(RELEASE),
            1,
        )
        CONF.write_text(candidate)
        battle_switched = True
        run(["systemctl", "daemon-reload"])
        run(["systemctl", "restart", "glory-server"], timeout=45)

        new_pid = ""
        startup = ""
        for _ in range(60):
            time.sleep(0.5)
            new_pid = pid("glory-server")
            if new_pid in {"", "0", old_pid}:
                continue
            startup = service_log("glory-server", new_pid)
            if re.search(r"SCRIPT ERROR|Parse Error|^ERROR:|setup failed", startup, re.M):
                raise RuntimeError("New battle server has startup errors")
            if (
                "[SERVER] ServerMain ready" in startup
                and f"server started protocol={PROTOCOL} port=8080" in startup
            ):
                break
        else:
            raise RuntimeError("New battle server did not become ready")

        statuses = {
            name: run(["systemctl", "is-active", name])
            for name in ("glory-server", "glory-backend", "livekit", "caddy")
        }
        if any(value != "active" for value in statuses.values()):
            raise RuntimeError(f"Service failure: {statuses}")
        public_health = json.loads(
            run(
                [
                    "curl",
                    "-fsS",
                    "--max-time",
                    "10",
                    "https://glorytd-api.duckdns.org/health",
                ]
            )
        )
        if public_health.get("status") != "ok":
            raise RuntimeError("Public health check failed")
        report = {
            "status": "deployed",
            "commit": COMMIT,
            "protocol": PROTOCOL,
            "release": str(RELEASE),
            "old_pid": old_pid,
            "new_pid": new_pid,
            "backend_pid": pid("glory-backend"),
            "idle": idle,
            "backend_changes": backend_changes,
            "services": statuses,
            "health": public_health,
            "rollback_directory": str(STAGE),
            "verified_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        }
        (STAGE / "deployment.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n"
        )
        (STAGE / "startup.log").write_text(startup)
        print("DEPLOYED " + json.dumps(report, ensure_ascii=False))
        return 0
    except BaseException:
        if battle_switched:
            CONF.write_text(previous_conf)
            run(["systemctl", "daemon-reload"])
            run(["systemctl", "restart", "glory-server"], timeout=45)
        if backend_switched:
            for relative in backend_changes:
                backup = backend_before / relative
                target = live_backend / relative
                if backup.is_file():
                    shutil.copy2(backup, target)
                elif target.exists():
                    target.unlink()
            for relative in DATA_FILES:
                backup = data_before / relative
                target = RUNTIME / "data" / relative
                if backup.is_file():
                    shutil.copy2(backup, target)
            run(["systemctl", "restart", "glory-backend"], timeout=45)
        raise


if __name__ == "__main__":
    raise SystemExit(main())
