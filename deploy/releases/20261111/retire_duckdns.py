#!/usr/bin/env python3
"""撤掉 duckdns：服务器从此只认 gogoglory.com —— 2026-11-11。

用户 11-11 定：「两步现在一起做」—— 知道做完以后，所有手机上现有的包（写死 duckdns）立刻连登录
都进不去，要等 Mac 打出新包才能再玩。

两台各跑一次，脚本按 GCP 项目编号自己认是测试服还是正式服。先跑测试服，没问题再跑正式服：
    sudo python3 retire_duckdns.py
有人在线会停。先关掉自己的游戏；剩下的确认可以断开（他们是旧包，断了就连不回来），加 --lobby-ok。

按顺序做，任何一步不对就停，最后列出「已经改了的」：
  1. 认机器；核对新的账号、语音域名都指到这台机器，新账号域名能访问；
  2. 查在线；
  3. 备份 Caddy 配置、backend.env、战斗服务器启动命令文件、两份语音配置，写一份 rollback.sh；
  4. 语音：跑仓库里的 deploy/livekit/install_livekit.sh <新语音域名>。密钥不换；语音的 Caddy 站点
     整个换成新域名，旧语音域名同时停掉；
  5. 账号：Caddy 站点那一行去掉旧域名，校验过了才重载；Caddy 实际加载的配置里不许再有 duckdns；
  6. backend.env 里写着旧域名的值换成新域名（Google 到账通知的受众就在这里）；
  7. 跑 update.sh：Steam 签发方会跟着变成新域名，组队语音拿到新地址，重启账号服务器；必须 SCHEMA ok；
  8. 战斗服务器：启动命令里 --backend-url 的旧域名换成新的，重启（顺带用上新语音地址）。
     等 server started，确认还是出示同一张证书、语音日志是新地址；这一步失败就把它换回去；
  9. 从这台机器访问一遍：新域名通、旧域名不通。

DuckDNS 上的名字**不删**：删了以后谁都能注册同名、申请正规证书，旧包就会把登录凭证发给他。
留着、继续指着我们的机器，服务器不认，旧包只会连不上。

做完要在外部控制台改的（脚本最后把要填的值印出来）：Supabase 的 custom:steam Issuer；
Google Cloud Pub/Sub 推送订阅的地址和受众（backend.env 里有那一项的那台）；App Store Connect /
Google Play 的支持、隐私链接。
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ENVS = {
    "project-60c72d94-b558-4e4f-992": {
        "name": "测试服", "ip": "34.124.141.90",
        "old_api": "glorytd-api.duckdns.org", "new_api": "test-api.gogoglory.com",
        "old_voice": "glorytd-voice.duckdns.org", "new_voice": "test-voice.gogoglory.com",
        "supabase": "tzkysvnpjmgzfbvazugi",
    },
    "project-60d2cb8c-3b40-4f95-a67": {
        "name": "正式服", "ip": "35.247.132.13",
        "old_api": "glorytd-prod-api.duckdns.org", "new_api": "api.gogoglory.com",
        "old_voice": "glorytd-prod-voice.duckdns.org", "new_voice": "voice.gogoglory.com",
        "supabase": "jiqctertgtxoabvyhbid",
    },
}
SERVICE = "glory-server"
CADDYFILE = Path("/etc/caddy/Caddyfile")
VOICE_CADDY = Path("/etc/caddy/glory-voice.caddy")
BACKEND_ENV = Path("/opt/glory/backend.env")
PARTY_VOICE = Path("/opt/glory/party_voice.json")
SRC = Path("/opt/glory/src")
UPDATE_SH = SRC / "deploy/update.sh"
INSTALL_LIVEKIT = SRC / "deploy/livekit/install_livekit.sh"
APP_DIR_NAME = "Glory Beta 0.04"
STAGE = Path("/var/backups/glory") / ("retire-duckdns-" + time.strftime("%Y%m%d-%H%M%S"))
ERROR_RE = re.compile(r"SCRIPT ERROR|Parse Error|^ERROR:|setup failed")
READY_ENTRY = "[SERVER] ServerMain ready"
DONE: list[str] = []


class Stop(Exception):
    """拒绝继续（消息里说清停在哪）。"""


def say(text: str) -> None:
    print(text, flush=True)


def run(command: list[str], timeout: float | None = None) -> str:
    try:
        return subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              encoding="utf-8", errors="replace", timeout=timeout).stdout.strip()
    except subprocess.CalledProcessError as error:
        say(error.stdout or "")
        raise


def quiet(command: list[str]) -> tuple[int, str]:
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            encoding="utf-8", errors="replace")
    return result.returncode, result.stdout.strip()


def stream(command: list[str]) -> tuple[int, str]:
    """跑命令并把输出原样显示出来（前面加 |），同时收集起来判断结果。"""
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               encoding="utf-8", errors="replace")
    collected = []
    assert process.stdout is not None
    for line in process.stdout:
        say("      | " + line.rstrip("\n"))
        collected.append(line)
    return process.wait(), "".join(collected)


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def pid(service: str) -> str:
    return run(["systemctl", "show", service, "-p", "MainPID", "--value"])


def logs(service: str, process_id: str) -> str:
    return run(["journalctl", "-u", service, f"_PID={process_id}", "--no-pager", "-o", "cat"])


def execstart_argv() -> list[str]:
    value = run(["systemctl", "show", "-p", "ExecStart", "--value", SERVICE])
    blocks = re.findall(r"argv\[\]=(.*?) ;", value)
    if len(blocks) != 1:
        raise Stop(f"glory-server 的启动命令有 {len(blocks)} 条（预期 1 条）。把 systemctl cat glory-server 的输出发过来。")
    return blocks[0].split()


def option(argv: list[str], name: str) -> str:
    for index, arg in enumerate(argv):
        if arg.startswith(name + "="):
            return arg[len(name) + 1:]
        if arg == name and index + 1 < len(argv):
            return argv[index + 1]
    return ""


def unit_file_with(marker: str) -> Path:
    """写着 marker（当前 --path）的 ExecStart 在哪个 systemd 文件里（多个取最后生效的）。"""
    fragment = run(["systemctl", "show", "-p", "FragmentPath", "--value", SERVICE])
    dropins = run(["systemctl", "show", "-p", "DropInPaths", "--value", SERVICE]).split()
    hits = []
    for name in [fragment, *dropins]:
        if not name:
            continue
        try:
            text = Path(name).read_text(encoding="utf-8")
        except OSError:
            continue
        if any(line.strip().startswith("ExecStart=") and marker in line for line in text.splitlines()):
            hits.append(Path(name))
    if not hits:
        raise Stop("systemd 文件里找不到战斗服务器的 ExecStart。把 systemctl cat glory-server 的输出发过来。")
    return hits[-1]


def cert_sha256(text: str) -> str:
    text = text.replace("\\n", "\n")
    found = re.findall(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", text, re.S)
    if len(found) != 1:
        return ""
    try:
        return hashlib.sha256(base64.b64decode("".join(found[0].split()), validate=True)).hexdigest()
    except ValueError:
        return ""


def probe_cert(port: str) -> str:
    """对本机战斗服务器做一次 DTLS 握手，拿它实际出示的证书指纹（11-11 在两台上都验证过可用）。"""
    if not shutil.which("openssl"):
        return ""
    try:
        result = subprocess.run(["timeout", "12", "openssl", "s_client", "-dtls1_2", "-connect", f"127.0.0.1:{port}"],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                encoding="utf-8", errors="replace", timeout=20)
    except Exception:  # noqa: BLE001
        return ""
    return cert_sha256(result.stdout)


def resolves_to(host: str) -> str:
    code, out = quiet(["getent", "ahostsv4", host])
    return out.split()[0] if code == 0 and out else ""


def http_status(url: str) -> str:
    code, out = quiet(["curl", "-sS", "-o", "/dev/null", "-m", "10", "-w", "%{http_code}", url])
    return out if code == 0 else f"连不上（curl 退出码 {code}）"


def current_connections() -> tuple[int, int]:
    account: set[str] = set()
    for line in logs("glory-backend", pid("glory-backend")).splitlines():
        match = re.search(r"WS (连接建立|断开) player=([0-9a-f-]+)", line)
        if match:
            (account.add if match.group(1) == "连接建立" else account.discard)(match.group(2))
    battle: set[str] = set()
    for line in logs(SERVICE, pid(SERVICE)).splitlines():
        match = re.search(r"\[NET\] client (connected|disconnected) peer=(\d+)", line)
        if match:
            (battle.add if match.group(1) == "connected" else battle.discard)(match.group(2))
    return len(account), len(battle)


def idle_gate(lobby_ok: bool) -> dict:
    row = {}
    for attempt in range(2):
        account, battle = current_connections()
        row = {"account_online": account, "battle_connections": battle, "at": now()}
        if battle:
            raise Stop(f"战斗服务器上还有 {battle} 个连接（可能有人在对局里）。等打完再跑。")
        if account and not lobby_ok:
            raise Stop(f"账号服务器上还有 {account} 个人在线。他们是旧包，撤完就连不回来了。\n"
                       "   先关掉你自己的游戏；剩下的如果确认可以断开，加 --lobby-ok 重跑。")
        if attempt == 0:
            time.sleep(3)
    return row


def wait_started(skip_pid: str, seconds: float = 60) -> tuple[str, str]:
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
        if READY_ENTRY in startup and "server started protocol=" in startup:
            return new_pid, startup
    raise RuntimeError(f"{seconds:.0f} 秒内没等到 server started")


def schema_verdict(skip_pid: str, seconds: float = 20) -> tuple[bool, list[str]]:
    deadline = time.monotonic() + seconds
    lines: list[str] = []
    while time.monotonic() < deadline:
        time.sleep(1)
        backend_pid = pid("glory-backend")
        if backend_pid in {"", "0", skip_pid}:
            continue
        text = logs("glory-backend", backend_pid)
        if "SCHEMA" not in text:
            continue
        time.sleep(1)
        text = logs("glory-backend", backend_pid)
        lines = [line for line in text.splitlines() if "SCHEMA" in line or "结构自检没能跑起来" in line]
        broken = any("SCHEMA 不一致" in line or "结构自检没能跑起来" in line for line in lines)
        return (not broken and any("SCHEMA ok" in line for line in lines)), lines
    return False, lines or [f"{seconds:.0f} 秒内账号服务器日志里没出现结构自检（SCHEMA）那一行"]


def drop_duckdns_from_site_line(text: str, new_api: str) -> tuple[str, int]:
    """把「旧域名, 新域名 {」这种站点地址行里的 duckdns 地址去掉。新域名必须在同一行里。"""
    count = 0
    lines = []
    for line in text.splitlines(keepends=True):
        body = line.rstrip("\r\n")
        match = re.match(r"^(\s*)(.+?)\s*\{\s*$", body)
        if match and "duckdns.org" in match.group(2) and not match.group(2).lstrip().startswith("#"):
            addresses = [a.strip() for a in match.group(2).split(",") if a.strip()]
            if new_api not in addresses:
                raise Stop(f"Caddy 里「{body.strip()}」这一行没有 {new_api}，去掉旧域名就没地址了。把这句话发过来。")
            kept = [a for a in addresses if "duckdns.org" not in a]
            line = f"{match.group(1)}{', '.join(kept)} {{" + line[len(body):]
            count += 1
        lines.append(line)
    return "".join(lines), count


def caddy_loaded_config() -> str:
    """Caddy 真正会加载的配置（展开所有 import 之后的 JSON）。"""
    return run(["caddy", "adapt", "--config", str(CADDYFILE), "--adapter", "caddyfile"])


def write_like(path: Path, text: str, original: Path) -> None:
    """按原文件的属主和权限写回。"""
    info = original.stat()
    path.write_text(text, encoding="utf-8")
    os.chown(path, info.st_uid, info.st_gid)
    os.chmod(path, info.st_mode & 0o7777)


def main() -> int:
    parser = argparse.ArgumentParser(description="撤掉 duckdns，服务器只认 gogoglory.com")
    parser.add_argument("--lobby-ok", action="store_true", help="账号服务器上有人在线也继续（他们是旧包，会被断开）")
    args = parser.parse_args()

    say("[1/9] 认机器、核对新域名 ...")
    if os.geteuid() != 0:
        raise Stop("要加 sudo：sudo python3 " + Path(sys.argv[0]).name)
    try:
        project = run(["curl", "-fsS", "--max-time", "5", "-H", "Metadata-Flavor: Google",
                       "http://metadata.google.internal/computeMetadata/v1/project/project-id"])
    except Exception:
        raise Stop("读不到这台机器的 GCP 项目编号。")
    env = ENVS.get(project)
    if not env:
        raise Stop(f"这台机器属于 {project}，既不是测试服也不是正式服。")
    for host in (env["new_api"], env["new_voice"]):
        got = resolves_to(host)
        if got != env["ip"]:
            raise Stop(f"{host} 现在解析到「{got or '查不到'}」，应该是 {env['ip']}。DNS 没就绪，先别撤。")
    health = http_status(f"https://{env['new_api']}/health")
    if health != "200":
        raise Stop(f"https://{env['new_api']}/health 现在是 {health}，新域名还不能用，先别撤。")
    for needed in (CADDYFILE, BACKEND_ENV, UPDATE_SH, INSTALL_LIVEKIT):
        if not needed.is_file():
            raise Stop(f"没有 {needed}。把这句话发过来。")
    caddy_text = CADDYFILE.read_text(encoding="utf-8")
    new_caddy, site_lines = drop_duckdns_from_site_line(caddy_text, env["new_api"])
    if site_lines != 1:
        raise Stop(f"Caddyfile 里带 duckdns 的站点地址行有 {site_lines} 行（预期 1 行：账号服务器那块）。"
                   "把 sudo cat /etc/caddy/Caddyfile 的输出发过来。")
    say(f"      这台是{env['name']}（{project}）")
    say(f"      账号 {env['old_api']} → {env['new_api']}；语音 {env['old_voice']} → {env['new_voice']}")

    say("[2/9] 检查在线玩家 ...")
    argv = execstart_argv()
    current_path = option(argv, "--path")
    port = option(argv, "--port") or "8080"
    unit_file = unit_file_with(current_path)
    owner = run(["systemctl", "show", "-p", "User", "--value", SERVICE]) or "root"
    battle_home = Path(run(["getent", "passwd", owner]).split(":")[5])
    battle_voice = battle_home / ".local/share/godot/app_userdata" / APP_DIR_NAME / "livekit_voice.json"
    old_battle_pid = pid(SERVICE)
    cert_before = probe_cert(port)
    idle = idle_gate(args.lobby_ok)
    say(f"      战斗服务器连接 {idle['battle_connections']}，账号服务器在线 {idle['account_online']}")

    say("[3/9] 备份 ...")
    STAGE.mkdir(parents=True)
    backups = [(CADDYFILE, STAGE / "Caddyfile"), (VOICE_CADDY, STAGE / "glory-voice.caddy"),
               (BACKEND_ENV, STAGE / "backend.env"), (unit_file, STAGE / "unit.before"),
               (battle_voice, STAGE / "livekit_voice.json"), (PARTY_VOICE, STAGE / "party_voice.json")]
    restore = ["#!/usr/bin/env bash", "# 撤 duckdns 之前的样子。sudo bash 这个文件就换回去。", "set -e"]
    for original, copy in backups:
        if original.is_file():
            shutil.copy2(original, copy)
            restore.append(f'cp -p "{copy}" "{original}"')
    restore += ["caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile", "systemctl reload caddy",
                "systemctl daemon-reload", "systemctl restart glory-backend", "systemctl restart glory-server",
                'echo "已换回撤 duckdns 之前的样子。Supabase 的 Steam Issuer、Pub/Sub 订阅也要改回旧域名。"']
    (STAGE / "rollback.sh").write_text("\n".join(restore) + "\n", encoding="utf-8")
    os.chmod(STAGE / "rollback.sh", 0o700)
    say(f"      备份和一键回滚脚本在 {STAGE}")

    say(f"[4/9] 语音换成 {env['new_voice']}（install_livekit.sh，密钥不换）...")
    code, output = stream(["bash", str(INSTALL_LIVEKIT), env["new_voice"], owner])
    if code != 0:
        raise Stop("install_livekit.sh 没跑成功（上面是它的输出）。它校验不过不会动 Caddy；livekit 可能已经重启过。")
    try:
        voice = json.loads(battle_voice.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        voice = {}
    if voice.get("client_url") != f"wss://{env['new_voice']}":
        raise Stop(f"语音配置里的地址是「{voice.get('client_url')}」，不是 wss://{env['new_voice']}。")
    DONE.append(f"语音 → {env['new_voice']}（旧语音域名已停）")

    say(f"[5/9] 账号：Caddy 去掉 {env['old_api']} ...")
    # 第 4 步可能改过主配置（加 import 行），所以基于现在的内容重新算一遍
    caddy_text = CADDYFILE.read_text(encoding="utf-8")
    new_caddy, site_lines = drop_duckdns_from_site_line(caddy_text, env["new_api"])
    if site_lines != 1:
        raise Stop("Caddyfile 在第 4 步之后变了样，没敢改。把 sudo cat /etc/caddy/Caddyfile 的输出发过来。")
    write_like(CADDYFILE, new_caddy, CADDYFILE)
    code, output = quiet(["caddy", "validate", "--config", str(CADDYFILE), "--adapter", "caddyfile"])
    leftover = "duckdns" in caddy_loaded_config() if code == 0 else True
    if code != 0 or leftover:
        write_like(CADDYFILE, caddy_text, CADDYFILE)
        say(output[-1500:])
        raise Stop("改完的 Caddy 配置校验没过，或者加载的配置里还有 duckdns。已把 Caddyfile 换回去，没有重载。")
    run(["systemctl", "reload", "caddy"])
    time.sleep(2)
    if http_status(f"https://{env['new_api']}/health") != "200":
        write_like(CADDYFILE, caddy_text, CADDYFILE)
        run(["systemctl", "reload", "caddy"])
        raise Stop(f"重载以后 https://{env['new_api']}/health 不通了，已把 Caddyfile 换回去并重载。")
    DONE.append(f"Caddy 不再认 {env['old_api']}")

    say("[6/9] backend.env 里的旧域名换成新域名 ...")
    env_text = BACKEND_ENV.read_text(encoding="utf-8")
    changed_keys = [line.split("=", 1)[0] for line in env_text.splitlines()
                    if "=" in line and (env["old_api"] in line or env["old_voice"] in line)]
    rtdn_configured = any(key == "GLORY_GOOGLE_RTDN_AUDIENCE" for key in changed_keys)
    if changed_keys:
        write_like(BACKEND_ENV, env_text.replace(env["old_api"], env["new_api"]).replace(env["old_voice"], env["new_voice"]),
                   BACKEND_ENV)
        say("      改了：" + "、".join(changed_keys))
        DONE.append("backend.env：" + "、".join(changed_keys))
    else:
        say("      没有写着旧域名的项")

    say("[7/9] 更新账号服务器（update.sh：Steam 签发方、组队语音跟着换，重启账号服务器）...")
    backend_pid_before = pid("glory-backend")
    code, output = stream(["bash", str(UPDATE_SH)])
    if code != 0 or "OK（重启后" not in output:
        raise Stop("update.sh 没跑成功（上面是它的输出）。把整段发过来；要换回去就跑 rollback.sh。")
    issuer = (re.findall(r"Steam 签发方：(\S+)", output) or [""])[-1]
    DONE.append("账号服务器已重启，Steam 签发方 = " + (issuer or "（没打印）"))
    healthy, schema_lines = schema_verdict(backend_pid_before)
    for line in schema_lines[-4:]:
        say("      " + line)
    if not healthy:
        raise Stop("账号服务器重启后结构自检不 OK。把整段输出发过来。")

    say("[8/9] 战斗服务器：--backend-url 换新域名、用上新语音地址 ...")
    unit_before = unit_file.read_text(encoding="utf-8")
    unit_after = unit_before.replace(env["old_api"], env["new_api"])
    try:
        if unit_after != unit_before:
            write_like(unit_file, unit_after, unit_file)
        run(["systemctl", "daemon-reload"])
        effective = execstart_argv()
        backend_url = option(effective, "--backend-url")
        if "duckdns" in " ".join(effective):
            raise RuntimeError("daemon-reload 之后启动命令里还有 duckdns：" + " ".join(effective))
        run(["systemctl", "restart", SERVICE], timeout=60)
        new_pid, startup = wait_started(old_battle_pid)
        voice_line = next((line for line in startup.splitlines() if "voice configured" in line
                           or "voice not configured" in line), "")
        if f"url=wss://{env['new_voice']}" not in voice_line:
            raise RuntimeError(f"战斗服务器的语音日志不对：{voice_line or '（没有语音那一行）'}")
        cert_after = probe_cert(port)
        if cert_before and cert_after != cert_before:
            raise RuntimeError("重启以后出示的证书变了（之前 %s…，现在 %s…）" % (cert_before[:12], cert_after[:12] or "没拿到"))
    except BaseException as error:
        say(f"      ❌ {error}")
        say("      把战斗服务器的启动命令换回去 ...")
        failed_pid = pid(SERVICE)
        write_like(unit_file, unit_before, unit_file)
        run(["systemctl", "daemon-reload"])
        run(["systemctl", "restart", SERVICE], timeout=60)
        try:
            wait_started(failed_pid)
            say("      战斗服务器已用原来的启动命令重新起来")
        except Exception as again:
            say(f"      🔴 换回去以后也没等到 server started：{again}；跑 journalctl -u glory-server -n 80 --no-pager 发过来")
        raise
    started_line = next((line for line in startup.splitlines() if "server started protocol=" in line), "")
    DONE.append("战斗服务器已重启：" + (f"--backend-url={backend_url}" if backend_url else "没有 --backend-url")
                + f"，语音 wss://{env['new_voice']}")

    say("[9/9] 从这台机器访问一遍 ...")
    checks = {
        f"https://{env['new_api']}/health": http_status(f"https://{env['new_api']}/health"),
        f"https://{env['old_api']}/health": http_status(f"https://{env['old_api']}/health"),
        f"https://{env['new_voice']}": http_status(f"https://{env['new_voice']}"),
        f"https://{env['old_voice']}": http_status(f"https://{env['old_voice']}"),
    }
    for url, status in checks.items():
        say(f"      {url} → {status}")
    report = {"env": env["name"], "project": project, "done": DONE, "steam_issuer": issuer,
              "rtdn_audience_changed": rtdn_configured, "backend_env_keys_changed": changed_keys,
              "battle_started": started_line, "voice_line": voice_line, "cert_unchanged": cert_before == cert_after,
              "checks": checks, "idle": idle, "rollback": str(STAGE / "rollback.sh"), "finished_at": now()}
    (STAGE / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    old_dead = all(not checks[u].startswith("2") for u in (f"https://{env['old_api']}/health", f"https://{env['old_voice']}"))
    new_ok = checks[f"https://{env['new_api']}/health"] == "200"
    say("")
    say(f"✅ {env['name']}已撤掉 duckdns" + ("" if (old_dead and new_ok) else "（⚠️ 上面的访问结果不对，把整段输出发过来）"))
    say(f"   {started_line}")
    say(f"   一键换回去：sudo bash {STAGE}/rollback.sh")
    say("")
    say("   接下来在外部控制台改（越快越好，改之前这一项登录 / 通知不通）：")
    say(f"   ① Supabase 项目 {env['supabase']} → Authentication → Sign In / Providers → 自定义提供方 steam")
    say(f"      Issuer 改成：{issuer or 'https://' + env['new_api'] + '/oidc/steam'}")
    say("      Discovery URL 清空（留空就自动用 Issuer 加 /.well-known/openid-configuration；原来填的是旧域名）")
    say("      其他格子不动，点 Update provider。保存时 Supabase 会当场去新域名取一次，所以要在这个脚本跑完之后改。")
    if rtdn_configured:
        say("   ② Google Cloud → Pub/Sub → 订阅 play-billing-rtdn-push → 修改：")
        say(f"      端点网址 和 受众（audience）都改成：https://{env['new_api']}/iap/google/rtdn")
        say("      保存后到 Play 管理中心 → 创收设置 → 实时开发者通知 → 发送测试通知，再在这里跑：")
        say('      sudo journalctl -u glory-backend --since "10 min ago" --no-pager | grep 实时通知')
        say("      看到「推送通道是通的」就对了；看到「身份不对」是受众没改对。")
    else:
        say("   ② 这台的 backend.env 里没有 Google 到账通知的受众，Pub/Sub 不用为它改。")
    return 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(errors="replace")
    except AttributeError:
        pass
    try:
        sys.exit(main())
    except Stop as stop:
        say(f"\n⛔ 停下了：{stop}")
        say("   已经改了的：" + ("；".join(DONE) if DONE else "没有，服务器上什么都没改"))
        if STAGE.exists():
            say(f"   要全部换回去：sudo bash {STAGE}/rollback.sh")
        sys.exit(2)
    except Exception as error:
        say(f"\n❌ 出错停下了：{error}")
        say("   已经改了的：" + ("；".join(DONE) if DONE else "没有，服务器上什么都没改"))
        if STAGE.exists():
            say(f"   要全部换回去：sudo bash {STAGE}/rollback.sh")
        sys.exit(1)
