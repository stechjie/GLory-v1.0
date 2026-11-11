#!/usr/bin/env python3
"""测试服战斗服务器换成协议 46（提交 a415a9dd）—— 2026-11-11。

做法照 deploy/releases/20261029/promote.py（罗利静 10-29 在这台机器上用过），另外加了几道保险：
  - 先确认这台机器属于测试服的 GCP 项目；在正式服上跑会直接拒绝、什么都不动；
  - 切换前确认 99-glory-current.conf 就是 systemd 正在用的那份；
  - daemon-reload 之后确认生效的启动命令里确实换成了新目录，才 restart；
  - 新版起不来就自动换回旧目录并重启，删掉没用上的新目录，修好后可以直接重跑。

用法：把包和本脚本上传到同一个目录（SSH 网页的「上传文件」会放到登录用户的家目录），然后
    sudo python3 promote_test_p46.py
账号服务器上有人在线会拒绝；确认只是大厅里有人、可以打断时加 --lobby-ok。
战斗服务器上有连接（可能有人在对局）一律拒绝，等打完再跑。

包由 tools/make_server_bundle.py 在 a415a9dd（工作区干净）上打出；Windows 没有该工具要求的
网络隔离，冷启动检查用的是同一个 smoke()、不带隔离，结果 server started protocol=46、零报错。
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
import time
import zipfile
from pathlib import Path

COMMIT = "a415a9dd762ac39ef7f7706537bf1753da74a1c9"
PROTOCOL = 46
TEST_PROJECT = "project-60c72d94-b558-4e4f-992"
HERE = Path(__file__).resolve().parent
ARCHIVE = HERE / "glory_server_p46_a415a9dd.zip"
ARCHIVE_SHA256 = "195465707e74af4497d22d0f9c86d9377a1cc8989c7416b524098ef35f25fd03"
RELEASE_NAME = "p46-20261111-a415a9dd"
STAGE = Path("/var/backups/glory") / ("server-20261111-a415a9dd-" + time.strftime("%H%M%S"))
CONF = Path("/etc/systemd/system/glory-server.service.d/99-glory-current.conf")
HEALTH_URL = "https://test-api.gogoglory.com/health"
SERVICE = "glory-server"
ERROR_RE = re.compile(r"SCRIPT ERROR|Parse Error|^ERROR:|setup failed")
READY_ENTRY = "[SERVER] ServerMain ready"
READY_NET = f"server started protocol={PROTOCOL} port=8080"


class Stop(Exception):
    """拒绝继续：服务器上什么都还没改。"""


def say(text: str) -> None:
    print(text, flush=True)


def run(command: list[str], timeout: float | None = None) -> str:
    try:
        return subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              encoding="utf-8", errors="replace", timeout=timeout).stdout.strip()
    except subprocess.CalledProcessError as error:
        say(error.stdout or "")
        raise


def quiet(command: list[str]) -> str:
    """不在乎退出码的查询（pgrep 没找到、is-active 不是 active 都会返回非零）。"""
    return subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          encoding="utf-8", errors="replace").stdout.strip()


def sha(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def pid(service: str) -> str:
    return run(["systemctl", "show", service, "-p", "MainPID", "--value"])


def logs(service: str, process_id: str) -> str:
    return run(["journalctl", "-u", service, f"_PID={process_id}", "--no-pager", "-o", "cat"])


def effective_execstart() -> str:
    return run(["systemctl", "show", "-p", "ExecStart", "--value", SERVICE])


def current_connections() -> tuple[int, int]:
    account: set[str] = set()
    for line in logs("glory-backend", pid("glory-backend")).splitlines():
        match = re.search(r"WS (连接建立|断开) player=([0-9a-f-]+)", line)
        if not match:
            continue
        if match.group(1) == "连接建立":
            account.add(match.group(2))
        else:
            account.discard(match.group(2))
    battle: set[str] = set()
    for line in logs(SERVICE, pid(SERVICE)).splitlines():
        match = re.search(r"\[NET\] client (connected|disconnected) peer=(\d+)", line)
        if not match:
            continue
        if match.group(1) == "connected":
            battle.add(match.group(2))
        else:
            battle.discard(match.group(2))
    return len(account), len(battle)


def idle_gate(lobby_ok: bool) -> list[dict]:
    rows = []
    for attempt in range(2):
        account, battle = current_connections()
        rows.append({"account_online": account, "battle_connections": battle, "at": now()})
        if battle:
            raise Stop(f"战斗服务器上还有 {battle} 个连接（可能有人在对局里）。等打完再跑。")
        if account and not lobby_ok:
            raise Stop(f"账号服务器上还有 {account} 个人在线（在大厅，没连战斗服务器）。\n"
                       "   先关掉你自己电脑上的游戏再跑；如果是别人、并且可以打断，加 --lobby-ok 重跑。")
        if attempt == 0:
            time.sleep(3)
    return rows


def wait_started(skip_pid: str, needle: str, seconds: float = 60) -> tuple[str, str]:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        time.sleep(0.5)
        new_pid = pid(SERVICE)
        if new_pid in {"", "0", skip_pid}:
            continue
        startup = logs(SERVICE, new_pid)
        bad = [line for line in startup.splitlines() if ERROR_RE.search(line)]
        if bad:
            raise RuntimeError("启动日志里有报错：\n      " + "\n      ".join(bad[:10]))
        if READY_ENTRY in startup and needle in startup:
            return new_pid, startup
    raise RuntimeError(f"{seconds:.0f} 秒内没等到「{needle}」")


def main() -> int:
    parser = argparse.ArgumentParser(description="测试服战斗服务器换成协议 46")
    parser.add_argument("--lobby-ok", action="store_true",
                        help="只有大厅里有人（没人连着战斗服务器）时也继续")
    args = parser.parse_args()

    say("[1/7] 确认这台是测试服 ...")
    if os.geteuid() != 0:
        raise Stop("要加 sudo：sudo python3 " + Path(sys.argv[0]).name)
    try:
        project = run(["curl", "-fsS", "--max-time", "5", "-H", "Metadata-Flavor: Google",
                       "http://metadata.google.internal/computeMetadata/v1/project/project-id"])
    except Exception:
        raise Stop("读不到这台机器的 GCP 项目编号，没法确认是测试服。")
    if project != TEST_PROJECT:
        raise Stop(f"这台机器属于 {project}，不是测试服 {TEST_PROJECT}。这个脚本只给测试服用。")
    say(f"      是测试服（{project}）")

    say("[2/7] 校验上传的包 ...")
    if not ARCHIVE.is_file():
        raise Stop(f"找不到 {ARCHIVE}。包和脚本要传到同一个目录。")
    if sha(ARCHIVE) != ARCHIVE_SHA256:
        raise Stop("包的校验值不对（没传完，或者传错了文件）。重新上传再跑。")
    say("      校验值一致")

    say("[3/7] 读现在生效的版本 ...")
    if not CONF.is_file():
        raise Stop(f"没有 {CONF}，这台的部署方式和预期不同。把 systemctl cat glory-server 的输出发过来。")
    previous_conf = CONF.read_text(encoding="utf-8")
    found = re.search(r'--path\s+(?:"([^"]+)"|(\S+))', previous_conf)
    if not found:
        raise Stop(f"{CONF} 里找不到 --path。把 systemctl cat glory-server 的输出发过来。")
    old_path = found.group(1) or found.group(2)
    if old_path not in effective_execstart():
        raise Stop("99-glory-current.conf 不是 systemd 正在用的那份。把 systemctl cat glory-server 的输出发过来。")
    release = Path(old_path).parent / RELEASE_NAME
    if Path(old_path) == release:
        raise Stop("测试服已经在跑这个版本了，不用再部署。")
    if release.exists():
        raise Stop(f"{release} 已经存在（又不是正在跑的那个）。先看看是谁放的，确认没用再删。")
    say(f"      现在跑的：{old_path}")

    say("[4/7] 检查在线玩家 ...")
    old_pid = pid(SERVICE)
    idle_checks = idle_gate(args.lobby_ok)
    last = idle_checks[-1]
    say(f"      战斗服务器连接 {last['battle_connections']}，账号服务器在线 {last['account_online']}")

    say("[5/7] 解压并逐个文件核对 ...")
    owner = run(["systemctl", "show", "-p", "User", "--value", SERVICE]) or "root"
    group = run(["id", "-gn", owner])
    STAGE.mkdir(parents=True)
    release.mkdir(parents=True)
    try:
        with zipfile.ZipFile(ARCHIVE) as package:
            package.extractall(release)
        manifest = json.loads((release / "server_bundle_manifest.json").read_text(encoding="utf-8"))
        if manifest["git_sha"] != COMMIT or manifest["protocol"] != PROTOCOL or manifest.get("git_dirty"):
            raise RuntimeError("包里的提交号 / 协议号和预期不一致")
        for row in manifest["files"]:
            path = release / row["path"]
            if not path.is_file() or sha(path) != row["sha256"]:
                raise RuntimeError("包里的文件对不上：" + row["path"])
        run(["chown", "-R", f"{owner}:{group}", str(release)])
    except BaseException:
        shutil.rmtree(release, ignore_errors=True)
        raise
    say(f"      {len(manifest['files'])} 个文件全部一致，放在 {release}")

    say("[6/7] 切换并重启战斗服务器（几秒钟）...")
    (STAGE / "previous.conf").write_text(previous_conf, encoding="utf-8")
    candidate = previous_conf[:found.start()] + f"--path {release}" + previous_conf[found.end():]
    (STAGE / "candidate.conf").write_text(candidate, encoding="utf-8")
    switched = False
    try:
        CONF.write_text(candidate, encoding="utf-8")
        switched = True
        run(["systemctl", "daemon-reload"])
        if str(release) not in effective_execstart():
            raise RuntimeError("daemon-reload 之后，生效的启动命令里没有新目录")
        run(["systemctl", "restart", SERVICE], timeout=60)
        new_pid, startup = wait_started(old_pid, READY_NET)
    except BaseException as error:
        say(f"      ❌ {error}")
        (STAGE / "failure.txt").write_text(str(error), encoding="utf-8")
        if switched:
            say("      正在换回旧版本 ...")
            failed_pid = pid(SERVICE)
            CONF.write_text(previous_conf, encoding="utf-8")
            run(["systemctl", "daemon-reload"])
            run(["systemctl", "restart", SERVICE], timeout=60)
            try:
                wait_started(failed_pid, "server started protocol=")
                say(f"      已换回旧版本：{old_path}")
            except Exception as again:
                say(f"      🔴 换回旧版本后也没等到 server started：{again}")
                say("      🔴 把这整段输出发过来，再跑 journalctl -u glory-server -n 80 --no-pager 一起发")
        shutil.rmtree(release, ignore_errors=True)
        raise

    say("[7/7] 收尾检查 ...")
    statuses = {name: quiet(["systemctl", "is-active", name])
                for name in (SERVICE, "glory-backend", "livekit", "caddy")}
    try:
        health = json.loads(run(["curl", "-fsS", "--max-time", "10", HEALTH_URL]))
    except Exception as error:
        health = {"error": str(error)}
    started_line = next((line for line in startup.splitlines() if "server started protocol=" in line), "")
    servers = [line for line in quiet(["pgrep", "-af", "--", "--server"]).splitlines() if "Godot" in line]
    report = {
        "status": "deployed", "commit": COMMIT, "protocol": PROTOCOL, "project": project,
        "archive_sha256": ARCHIVE_SHA256, "release": str(release), "old_release": old_path,
        "old_pid": old_pid, "new_pid": new_pid, "idle_checks": idle_checks,
        "lobby_ok": args.lobby_ok, "services": statuses, "health": health,
        "started_line": started_line, "godot_server_processes": servers,
        "rollback_directory": str(STAGE), "verified_at": now(),
    }
    (STAGE / "deployment.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                                           encoding="utf-8")
    (STAGE / "startup.log").write_text(startup, encoding="utf-8")
    ARCHIVE.unlink()

    say("")
    say(f"✅ 测试服战斗服务器已换成协议 {PROTOCOL}（{COMMIT[:8]}）")
    say(f"   {started_line}")
    say(f"   新目录：{release}")
    say(f"   旧目录：{old_path}（留着，回滚用）")
    say("   服务状态：" + "，".join(f"{name} {state}" for name, state in statuses.items()))
    say(f"   账号服务器健康检查：{health.get('status', health)}")
    if any(state != "active" for state in statuses.values()) or health.get("status") != "ok":
        say("   ⚠️ 上面有不是 active / ok 的，把这段输出发过来")
    if len(servers) != 1:
        say(f"   ⚠️ 机器上有 {len(servers)} 个战斗服务器进程（应该只有 1 个）：")
        for line in servers:
            say("      " + line)
    say(f"   记录：{STAGE}/deployment.json")
    say(f"   要回滚就跑：sudo cp {STAGE}/previous.conf {CONF} && sudo systemctl daemon-reload"
        f" && sudo systemctl restart {SERVICE}")
    return 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(errors="replace")
    except AttributeError:
        pass
    try:
        sys.exit(main())
    except Stop as stop:
        say(f"\n⛔ 没有部署：{stop}\n   服务器上什么都没改。")
        sys.exit(2)
    except Exception as error:
        say(f"\n❌ 部署失败：{error}\n   详情在 {STAGE}")
        sys.exit(1)
