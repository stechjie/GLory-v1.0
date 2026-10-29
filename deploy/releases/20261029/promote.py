#!/usr/bin/env python3
"""Promote the verified 2026-10-29 server bundle with rollback and idle gates."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import time
import zipfile
from pathlib import Path


COMMIT = "80b46b8611f4f4b5171e6003e55f52f8732be3ca"
PROTOCOL = 45
ARCHIVE = Path("/home/bytegame2025/glory-server-3/server.zip")
ARCHIVE_SHA256 = "5c89aa66aa2c101172e029bd36f30e329c857e06e23a512d4fe4bfef66aadf01"
STAGE = Path("/var/backups/glory/server-20261029-80b46b86")
RELEASE = Path("/home/nins17121/Glory/releases/1.0.2-20261029-80b46b86")
CONF = Path("/etc/systemd/system/glory-server.service.d/99-glory-current.conf")
SOURCE = Path("/opt/glory/src")


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


def logs(service: str, process_id: str) -> str:
    return run(
        ["journalctl", "-u", service, f"_PID={process_id}", "--no-pager", "-o", "cat"]
    )


def current_connections() -> tuple[int, int]:
    account = set()
    for line in logs("glory-backend", pid("glory-backend")).splitlines():
        match = re.search(r"WS (连接建立|断开) player=([0-9a-f-]+)", line)
        if not match:
            continue
        if match.group(1) == "连接建立":
            account.add(match.group(2))
        else:
            account.discard(match.group(2))

    battle = set()
    for line in logs("glory-server", pid("glory-server")).splitlines():
        match = re.search(r"\[NET\] client (connected|disconnected) peer=(\d+)", line)
        if not match:
            continue
        if match.group(1) == "connected":
            battle.add(match.group(2))
        else:
            battle.discard(match.group(2))
    return len(account), len(battle)


def idle_gate() -> list[dict]:
    rows = []
    for _ in range(2):
        account, battle = current_connections()
        if account or battle:
            raise RuntimeError(f"Players are active; account={account}, battle={battle}")
        rows.append(
            {
                "account_online": account,
                "battle_connections": battle,
                "checked_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            }
        )
        time.sleep(3)
    return rows


def main() -> int:
    if os.geteuid() != 0:
        raise RuntimeError("Run as root")
    if sha(ARCHIVE) != ARCHIVE_SHA256:
        raise RuntimeError("Uploaded server bundle hash mismatch")
    if STAGE.exists() or RELEASE.exists():
        raise RuntimeError("Release or rollback directory already exists")

    previous_conf = CONF.read_text()
    old_path = re.search(r"--path\s+(\S+)", previous_conf)
    if not old_path:
        raise RuntimeError("Current server release path not found")
    old_pid = pid("glory-server")
    idle_checks = idle_gate()
    STAGE.mkdir(parents=True)
    RELEASE.mkdir(parents=True)
    with zipfile.ZipFile(ARCHIVE) as package:
        package.extractall(RELEASE)

    manifest = json.loads((RELEASE / "server_bundle_manifest.json").read_text())
    if manifest["git_sha"] != COMMIT or manifest["protocol"] != PROTOCOL:
        raise RuntimeError("Server bundle identity mismatch")
    for row in manifest["files"]:
        path = RELEASE / row["path"]
        if not path.is_file() or sha(path) != row["sha256"]:
            raise RuntimeError(f"Server bundle file mismatch: {row['path']}")

    run(["chown", "-R", "nins17121:nins17121", str(RELEASE)])
    (STAGE / "previous.conf").write_text(previous_conf)
    candidate_conf = previous_conf.replace(old_path.group(1), str(RELEASE), 1)
    (STAGE / "candidate.conf").write_text(candidate_conf)
    switched = False
    try:
        CONF.write_text(candidate_conf)
        switched = True
        run(["systemctl", "daemon-reload"])
        run(["systemctl", "restart", "glory-server"], timeout=45)
        new_pid = ""
        startup = ""
        for _ in range(60):
            time.sleep(0.5)
            new_pid = pid("glory-server")
            if new_pid in {"", "0", old_pid}:
                continue
            startup = logs("glory-server", new_pid)
            if re.search(r"SCRIPT ERROR|Parse Error|^ERROR:|setup failed", startup, re.M):
                raise RuntimeError("New battle server reported startup errors")
            if (
                "[SERVER] ServerMain ready" in startup
                and f"server started protocol={PROTOCOL} port=8080" in startup
            ):
                break
        else:
            raise RuntimeError("New battle server did not become ready")

        statuses = {
            service: run(["systemctl", "is-active", service])
            for service in ("glory-server", "glory-backend", "livekit", "caddy")
        }
        if any(value != "active" for value in statuses.values()):
            raise RuntimeError(f"Service failure: {statuses}")
        health = json.loads(
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
        if health.get("status") != "ok" or not health.get("configured"):
            raise RuntimeError("Public health check failed")
        report = {
            "status": "deployed",
            "commit": COMMIT,
            "protocol": PROTOCOL,
            "backend_source_commit": run(
                ["git", "-C", str(SOURCE), "rev-parse", "HEAD"]
            ),
            "release": str(RELEASE),
            "old_release": old_path.group(1),
            "old_pid": old_pid,
            "new_pid": new_pid,
            "backend_pid": pid("glory-backend"),
            "idle_checks": idle_checks,
            "services": statuses,
            "health": health,
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
        if switched:
            CONF.write_text(previous_conf)
            run(["systemctl", "daemon-reload"])
            run(["systemctl", "restart", "glory-server"], timeout=45)
        raise


if __name__ == "__main__":
    raise SystemExit(main())
