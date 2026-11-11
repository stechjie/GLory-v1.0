#!/usr/bin/env python3
"""正式服更新到 a415a9dd（协议 46），同时让正式服战斗服务器改用自己的证书 —— 2026-11-11。

一条命令按固定顺序做完：检查 → 账号服务器（update.sh）→ 战斗服务器。
任何一项对不上就停下；最后会列出「已经改了的」，没列出的都没动。

前提：已经在 Supabase 的 glory-prod 项目里跑过 prod_migrations_042_045.sql。
更新完账号服务器后脚本会看它启动日志里的「SCHEMA ok」；迁移没跑会停在这里，不碰战斗服务器。

## 🔴 证书（11-11 在正式服上实测出来的）

正式服战斗服务器从 11-02 起出示的一直是**测试服证书**（F7:73…）：启动命令没有 --tls-cert=，
版本目录里的 NetTLSCert.gd 是测试服那张，--tls-key=/opt/glory/battle_tls_key.pem 和它配对。
当时的 iOS 81 / 安卓 56 打包还不换证书、固定的也是测试服那张，所以一直连得上。
11-03 ce89606d 起 glory_build.py 给正式包固定**正式服证书**（DE:B1…，10-31 生成，在
/home/nins17121/Glory/keys/），服务器却从没换过去 —— 下一个正式包会卡在连接中。

所以这次一起换：找到和正式服证书配对的私钥（用公钥比对，不看文件名），复制到 --tls-key 所在
目录（battle_tls_prod_cert.pem / battle_tls_prod_key.pem，属主和权限照旧私钥），启动命令改成
--tls-key=<新私钥> --tls-cert=<新证书>。81 / 56 本来就因为协议 46 连不上，不额外弄坏谁；
正式服和测试服也不再共用同一把私钥。

判断依据两层，必须一致：照 NetTLS.pinned_cert() 的顺序（--tls-cert= > 存档目录
local_test_override.cfg 的 [battle] tls_cert > 包里的 NetTLSCert.gd）推出来的，和对正在跑的
战斗服务器做 DTLS 握手**实际出示**的。换完再握手，必须是正式服那张，否则自动换回旧版。
要换证书却没法握手验证、或者找不到配对私钥，就停下并打印诊断（只有路径、键名和指纹）。

## 其他

  - 认正式服的 GCP 项目；核对 backend.env 连的是正式库（jiqctertgtxoabvyhbid），不是测试库；
  - 账号服务器一起更新：跑 update.sh（它拉到新代码后会自动换成新版接着跑，一次就够）；
  - 正式服目录结构是 /opt/glory/releases/<名字>/battle，新目录位置从生效的启动命令推出来；
  - 正在跑的进程必须和 systemd 配置一致（防「改了配置没重启」）；
  - 只改启动命令实际所在的那个 systemd 文件里的 --path / --tls-key / --tls-cert 三项；
  - update.sh 会重启账号服务器，大厅里的人会断几秒再自动连回 —— 所以账号服务器上有人在线
    也默认停下，确认可以打断再加 --lobby-ok。战斗服务器上有人（可能在对局）一律停。

用法：包和本脚本上传到同一个目录（SSH 网页的「上传文件」会放到家目录），然后
    sudo python3 <本文件名>
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
import zipfile
from pathlib import Path

COMMIT = "a415a9dd762ac39ef7f7706537bf1753da74a1c9"
PROTOCOL = 46
PROD_PROJECT = "project-60d2cb8c-3b40-4f95-a67"
PROD_DB_REF = "jiqctertgtxoabvyhbid"
TEST_DB_REF = "tzkysvnpjmgzfbvazugi"
PROD_CERT_SHA256 = "deb19b3e25862e2008e1e7c00211c41b39f92a5bcf428f990230cb260eca5354"
TEST_CERT_SHA256 = "f773c1a5e917e3fe7c0c938ee19ed2ecfc0b16ed3ecf8fb8f3fa6987a49c250d"
HERE = Path(__file__).resolve().parent
ARCHIVE = HERE / "glory_server_p46_a415a9dd.zip"
ARCHIVE_SHA256 = "195465707e74af4497d22d0f9c86d9377a1cc8989c7416b524098ef35f25fd03"
RELEASE_NAME = "p46-20261111-a415a9dd"
STAGE = Path("/var/backups/glory") / ("prod-20261111-a415a9dd-" + time.strftime("%H%M%S"))
SRC = Path("/opt/glory/src")
UPDATE_SH = SRC / "deploy/update.sh"
BACKEND_ENV = Path("/opt/glory/backend.env")
HEALTH_URL = "https://api.gogoglory.com/health"
SERVICE = "glory-server"
CERT_IN_BUNDLE = "scripts/multiplayer/NetTLSCert.gd"
PROD_CERT_COPY = "battle_tls_prod_cert.pem"
PROD_KEY_COPY = "battle_tls_prod_key.pem"
ERROR_RE = re.compile(r"SCRIPT ERROR|Parse Error|^ERROR:|setup failed")
READY_ENTRY = "[SERVER] ServerMain ready"
USERDIR_KEYS = ("config/name", "config/use_custom_user_dir", "config/custom_user_dir_name")
DONE: list[str] = []
PREPARED: list[Path] = []  # 这次新建、还没用上的东西：停下或回滚时删掉，旧的一样不碰


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


def quiet(command: list[str]) -> str:
    """不在乎退出码的查询（pgrep 没找到、is-active 不是 active 都会返回非零）。"""
    return subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          encoding="utf-8", errors="replace").stdout.strip()


def ok(command: list[str]) -> bool:
    return subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


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


def execstart_argv() -> list[str]:
    value = run(["systemctl", "show", "-p", "ExecStart", "--value", SERVICE])
    blocks = re.findall(r"argv\[\]=(.*?) ;", value)
    if len(blocks) != 1:
        raise Stop(f"glory-server 的启动命令有 {len(blocks)} 条（预期 1 条）。把 systemctl cat glory-server 的输出发过来。")
    return blocks[0].split()


def unit_file_with(old_path: str) -> Path:
    """写着当前目录的 ExecStart 在哪个 systemd 文件里（多个就取最后生效的那个）。"""
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
        if any(line.strip().startswith("ExecStart=") and old_path in line for line in text.splitlines()):
            hits.append(Path(name))
    if not hits:
        raise Stop("systemd 文件里找不到写着当前目录的 ExecStart。把 systemctl cat glory-server 的输出发过来。")
    return hits[-1]


def option(argv: list[str], name: str) -> str:
    """取 --name=value 或 --name value 的值，没有返回空串。"""
    for index, arg in enumerate(argv):
        if arg.startswith(name + "="):
            return arg[len(name) + 1:]
        if arg == name and index + 1 < len(argv):
            return argv[index + 1]
    return ""


def set_option(tokens: list[str], name: str, value: str) -> list[str]:
    """改已有的 --name=…/--name … 的值，原来的写法不变；没有就在末尾加 --name=value。"""
    result = list(tokens)
    for index, token in enumerate(result):
        if token.startswith(name + "="):
            result[index] = f"{name}={value}"
            return result
        if token == name and index + 1 < len(result):
            result[index + 1] = value
            return result
    result.append(f"{name}={value}")
    return result


def rewrite_execstart(text: str, old_path: str, changes: dict) -> tuple[str, int]:
    """只改写着旧目录的那条 ExecStart，其他行、其他参数（引擎、端口、别的钥匙…）原样保留。"""
    count = 0
    lines = []
    for line in text.splitlines(keepends=True):
        body = line.rstrip("\r\n")
        if body.strip().startswith("ExecStart=") and old_path in body:
            prefix, command = body.split("ExecStart=", 1)
            tokens = command.split()
            if option(tokens, "--path") == old_path:
                for name, value in changes.items():
                    tokens = set_option(tokens, name, value)
                line = prefix + "ExecStart=" + " ".join(tokens) + line[len(body):]
                count += 1
        lines.append(line)
    return "".join(lines), count


def cert_sha256(text: str) -> str:
    """PEM（或 NetTLSCert.gd 里换行被转义的 PEM）→ 证书 DER 的 SHA-256；拿不到返回空串。"""
    text = text.replace("\\n", "\n")
    found = re.findall(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", text, re.S)
    if len(found) != 1:
        return ""
    try:
        der = base64.b64decode("".join(found[0].split()), validate=True)
    except ValueError:
        return ""
    return hashlib.sha256(der).hexdigest()


def pubkey_of(path: Path, kind: str) -> str:
    """证书或私钥对应的公钥（PEM 文本）。两边一样 = 是一对。私钥内容不出这个函数，也不打印。"""
    # -passin pass: + 不给输入：带密码的私钥直接判读不出，不会停下来等人敲密码把脚本卡死。
    command = (["openssl", "x509", "-in", str(path), "-noout", "-pubkey"] if kind == "cert"
               else ["openssl", "pkey", "-in", str(path), "-pubout", "-passin", "pass:"])
    try:
        result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, encoding="utf-8", errors="replace", timeout=20)
    except Exception:  # noqa: BLE001
        return ""
    return result.stdout.strip() if result.returncode == 0 and "PUBLIC KEY" in result.stdout else ""


def pem_files() -> list[Path]:
    found = set(Path("/home").glob("*/Glory/keys/*.pem")) | set(Path("/opt/glory").glob("*.pem")) \
        | set(Path("/opt/glory").glob("keys/*.pem")) | set(Path("/root").glob("Glory/keys/*.pem"))
    return sorted(found)


def is_private_key(path: Path) -> bool:
    try:
        return "PRIVATE KEY" in path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False


def find_prod_keypair() -> tuple[Path | None, Path | None]:
    """找正式服证书和配对的私钥。"""
    for cert in pem_files():
        if is_private_key(cert):
            continue
        try:
            if cert_sha256(cert.read_text(encoding="utf-8", errors="replace")) != PROD_CERT_SHA256:
                continue
        except OSError:
            continue
        want = pubkey_of(cert, "cert")
        if not want:
            continue
        for key in sorted(set(cert.parent.glob("*.pem")) | set(Path("/opt/glory").glob("*.pem"))):
            if is_private_key(key) and pubkey_of(key, "key") == want:
                return cert, key
    return None, None


def userdir_settings(project_file: Path) -> dict:
    text = project_file.read_text(encoding="utf-8-sig")
    section = re.search(r"(?ms)^\[application\]\s*\n(.*?)(?=^\[|\Z)", text)
    body = section.group(1) if section else ""
    result = {}
    for key in USERDIR_KEYS:
        found = re.search(r"(?m)^" + re.escape(key) + r"=(.*)$", body)
        result[key] = found.group(1).strip() if found else ""
    return result


def proc_argv(process_id: str) -> list[str]:
    try:
        raw = Path(f"/proc/{process_id}/cmdline").read_bytes()
    except OSError:
        return []
    return [part.decode("utf-8", "replace") for part in raw.split(b"\0") if part]


def godot_user_dir(project_file: Path, owner: str) -> Path:
    """战斗服务器的 user:// 在哪（存档、local_test_override.cfg 都在这里）。"""
    settings = userdir_settings(project_file)
    home = Path(run(["getent", "passwd", owner]).split(":")[5])
    custom = settings["config/custom_user_dir_name"].strip('"')
    if settings["config/use_custom_user_dir"] == "true" and custom:
        return home / ".local/share" / custom
    return home / ".local/share/godot/app_userdata" / settings["config/name"].strip('"')


def cfg_value(text: str, section: str, key: str) -> str:
    """Godot ConfigFile 里 [section] 下 key 的值（去掉引号），没有返回空串。"""
    body = re.search(r"(?ms)^\[" + re.escape(section) + r"\]\s*\n(.*?)(?=^\[|\Z)", text)
    if not body:
        return ""
    found = re.search(r"(?m)^" + re.escape(key) + r"\s*=\s*(.*)$", body.group(1))
    if not found:
        return ""
    value = found.group(1).strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        value = value[1:-1]
    return value.strip()


def cert_from_setting(value: str) -> tuple[str, str]:
    """--tls-cert / cfg 里的值 → (指纹, 说明)。可以是 PEM 本身，也可以是文件路径（同 NetTLS.pinned_cert）。"""
    if value.startswith("-----"):
        return cert_sha256(value), "直接写在里面的 PEM"
    try:
        return cert_sha256(Path(value).read_text(encoding="utf-8")), value
    except OSError:
        return "", f"{value}（读不到）"


def probe_cert(port: str) -> str:
    """对本机战斗服务器做一次 DTLS 握手，拿它**实际出示**的证书指纹；拿不到返回空串。

    引擎的准入补丁只放行首包是 DTLS ClientHello 的端点，openssl 的首包正是。握手停在 DTLS 层，
    ENet 层不会出现玩家连接。11-11 本机对 Godot 4.7.1 实测 1.6 秒拿到、指纹一致；同日在正式服上也拿到了。
    """
    if not shutil.which("openssl"):
        return ""
    try:
        result = subprocess.run(["timeout", "12", "openssl", "s_client", "-dtls1_2", "-connect", f"127.0.0.1:{port}"],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                encoding="utf-8", errors="replace", timeout=20)
    except Exception:  # noqa: BLE001 - 探测是加分项，失败就退回静态判断
        return ""
    return cert_sha256(result.stdout)


def label(fingerprint: str) -> str:
    if not fingerprint:
        return "（没拿到）"
    if fingerprint == PROD_CERT_SHA256:
        return "正式服那张 ✓"
    if fingerprint == TEST_CERT_SHA256:
        return "测试服那张"
    return f"不认识的证书 {fingerprint[:16]}… ✗"


def cert_diagnostics(old: Path, user_dir: Path, cfg_text: str, argv: list[str], running: list[str]) -> None:
    """判断不出证书时打印现场。只打文件名、路径、键名和证书指纹，**不打任何私钥和配置值**。"""
    say("      —— 诊断信息（不含私钥）——")
    say("      systemd 启动命令：" + " ".join(argv))
    say("      正在跑的进程：" + (" ".join(running) if running else "（读不到）"))
    say(f"      存档目录：{user_dir}（{'存在' if user_dir.is_dir() else '不存在'}）")
    if user_dir.is_dir():
        say("      存档目录里的文件：" + ", ".join(sorted(p.name for p in user_dir.iterdir())[:40]))
    if cfg_text:
        names = re.findall(r"(?m)^\s*(\[[^\]\n]+\]|[A-Za-z_][\w/]*)\s*(?==|$)", cfg_text)
        say("      local_test_override.cfg 的段落和键名：" + ", ".join(names))
    else:
        say("      local_test_override.cfg：没有")
    folder = old / "scripts/multiplayer"
    say("      旧目录里跟证书有关的文件：" + ", ".join(sorted(p.name for p in folder.glob("NetTLS*"))))
    if (old / CERT_IN_BUNDLE).is_file():
        text = (old / CERT_IN_BUNDLE).read_text(encoding="utf-8", errors="replace")
        say(f"      旧目录 NetTLSCert.gd：{text.count('BEGIN CERTIFICATE')} 张证书，{label(cert_sha256(text))}")
    prod_pub = ""
    for candidate in pem_files():
        if is_private_key(candidate):
            continue
        try:
            fingerprint = cert_sha256(candidate.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue
        if fingerprint:
            say(f"      证书文件 {candidate}：{label(fingerprint)}")
            if fingerprint == PROD_CERT_SHA256 and not prod_pub:
                prod_pub = pubkey_of(candidate, "cert")
    for candidate in pem_files():
        if is_private_key(candidate):
            pair = pubkey_of(candidate, "key")
            verdict = "读不出" if not pair else ("和正式服证书配对 ✓" if prod_pub and pair == prod_pub else "和正式服证书不配对")
            say(f"      私钥文件 {candidate}（只列名字）：{verdict}")


def discard_prepared() -> None:
    for path in reversed(PREPARED):
        if path.is_dir():
            shutil.rmtree(path, ignore_errors=True)
        else:
            try:
                path.unlink()
            except OSError:
                pass
    PREPARED.clear()


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
            raise Stop(f"账号服务器上还有 {account} 个人在线（在大厅）。更新会让他们断开几秒再自动连回。\n"
                       "   先关掉你自己的游戏；剩下的如果可以打断，加 --lobby-ok 重跑。")
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


def schema_verdict(skip_pid: str, seconds: float = 20) -> tuple[bool, list[str]]:
    """看新账号服务器启动日志里的结构自检结果（app/schema_check.py）。

    「SCHEMA ok」单独不算数：自检本身没跑起来时它也会打 ok，同时留一行「结构自检没能跑起来」。
    """
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
        time.sleep(1)  # 「不一致」后面还跟着逐条说明，等它们落进日志
        text = logs("glory-backend", backend_pid)
        lines = [line for line in text.splitlines() if "SCHEMA" in line or "结构自检没能跑起来" in line]
        broken = any("SCHEMA 不一致" in line or "结构自检没能跑起来" in line for line in lines)
        return (not broken and any("SCHEMA ok" in line for line in lines)), lines
    return False, lines or [f"{seconds:.0f} 秒内账号服务器日志里没出现结构自检（SCHEMA）那一行"]


def run_update_sh() -> tuple[int, str]:
    process = subprocess.Popen(["bash", str(UPDATE_SH)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               encoding="utf-8", errors="replace")
    collected = []
    assert process.stdout is not None
    for line in process.stdout:
        say("      | " + line.rstrip("\n"))
        collected.append(line)
    return process.wait(), "".join(collected)


def main() -> int:
    parser = argparse.ArgumentParser(description="正式服更新到协议 46")
    parser.add_argument("--lobby-ok", action="store_true",
                        help="账号服务器上有人在线（都在大厅）也继续：他们会断开几秒再自动连回")
    args = parser.parse_args()

    say("[1/8] 确认这台是正式服、连的是正式库 ...")
    if os.geteuid() != 0:
        raise Stop("要加 sudo：sudo python3 " + Path(sys.argv[0]).name)
    try:
        project = run(["curl", "-fsS", "--max-time", "5", "-H", "Metadata-Flavor: Google",
                       "http://metadata.google.internal/computeMetadata/v1/project/project-id"])
    except Exception:
        raise Stop("读不到这台机器的 GCP 项目编号，没法确认是正式服。")
    if project != PROD_PROJECT:
        raise Stop(f"这台机器属于 {project}，不是正式服 {PROD_PROJECT}。这个脚本只给正式服用。")
    try:
        env_text = BACKEND_ENV.read_text(encoding="utf-8")
    except OSError:
        raise Stop(f"读不到 {BACKEND_ENV}，没法确认账号服务器连的是哪个数据库。")
    db_line = next((line for line in env_text.splitlines() if line.startswith("GLORY_DATABASE_URL=")), "")
    if PROD_DB_REF not in db_line or TEST_DB_REF in db_line:
        raise Stop("backend.env 里的数据库不是正式库 glory-prod（jiqctertgtxoabvyhbid）。先别动，把这句话发过来。")
    say(f"      是正式服（{project}），数据库是正式库 glory-prod")

    say("[2/8] 校验上传的包 ...")
    if not ARCHIVE.is_file():
        raise Stop(f"找不到 {ARCHIVE}。包和脚本要传到同一个目录。")
    if sha(ARCHIVE) != ARCHIVE_SHA256:
        raise Stop("包的校验值不对（没传完，或者传错了文件）。重新上传再跑。")
    say("      校验值一致")

    say("[3/8] 读现在的战斗服务器配置 ...")
    argv = execstart_argv()
    old_path = option(argv, "--path")
    old = Path(old_path) if old_path else Path("/nonexistent")
    if not (old / "project.godot").is_file():
        raise Stop(f"从启动命令读出的目录不对：{old_path or '（没有 --path）'}。把 systemctl cat glory-server 的输出发过来。")
    nested = old.name == "battle"
    release = (old.parent.parent / RELEASE_NAME / "battle") if nested else (old.parent / RELEASE_NAME)
    created_root = release.parent if nested else release
    if release == old:
        raise Stop("正式服已经在跑这个版本了，不用再部署。")
    if created_root.exists():
        raise Stop(f"{created_root} 已经存在（又不是正在跑的那个）。先看看是谁放的，确认没用再删。")
    port = option(argv, "--port") or "8080"
    unit_file = unit_file_with(old_path)
    exec_lines = [line for line in unit_file.read_text(encoding="utf-8").splitlines()
                  if line.strip().startswith("ExecStart=") and old_path in line]
    if any('"' in line or "'" in line for line in exec_lines):
        raise Stop(f"{unit_file} 的启动命令里有引号，脚本不敢自动改。把 systemctl cat glory-server 的输出发过来。")
    owner = run(["systemctl", "show", "-p", "User", "--value", SERVICE]) or "root"
    running = proc_argv(pid(SERVICE))
    user_dir = godot_user_dir(old / "project.godot", owner)
    cfg_path = user_dir / "local_test_override.cfg"
    cfg_text = cfg_path.read_text(encoding="utf-8", errors="replace") if cfg_path.is_file() else ""
    for name in ("--path", "--tls-cert", "--tls-key", "--port"):
        if running and option(running, name) != option(argv, name):
            cert_diagnostics(old, user_dir, cfg_text, argv, running)
            raise Stop(f"正在跑的战斗服务器和 systemd 配置不一致（{name}：进程里是「{option(running, name)}」，"
                       f"配置里是「{option(argv, name)}」）—— 配置改过但没重启。先别动，把这段输出发过来。")
    # 和 NetTLS.pinned_cert() 同一个顺序：命令行 > 存档目录里的 local_test_override.cfg > 包里的 NetTLSCert.gd
    flag_cert = option(argv, "--tls-cert")
    cfg_cert = cfg_value(cfg_text, "battle", "tls_cert")
    if flag_cert:
        source = "flag"
        static_fp, where = cert_from_setting(flag_cert)
        where = "启动命令 --tls-cert= → " + where
    elif cfg_cert:
        source = "cfg"
        static_fp, where = cert_from_setting(cfg_cert)
        where = f"{cfg_path} 的 tls_cert → {where}"
    else:
        source = "bundle"
        try:
            static_fp = cert_sha256((old / CERT_IN_BUNDLE).read_text(encoding="utf-8"))
        except OSError:
            static_fp = ""
        where = f"旧目录的 {CERT_IN_BUNDLE}"
    presented_before = probe_cert(port)
    say(f"      证书来源：{where} —— {label(static_fp)}")
    say("      正在跑的战斗服务器实际出示：" + (label(presented_before) if presented_before
                                       else "（握手探测不到，只能靠上面的判断）"))
    if presented_before and static_fp and presented_before != static_fp:
        cert_diagnostics(old, user_dir, cfg_text, argv, running)
        raise Stop("实际出示的证书和从配置推出来的不一样，说明证书另有来源。先别动，把这段输出发过来。")
    current_cert = presented_before or static_fp
    switch: dict = {}
    if current_cert == PROD_CERT_SHA256:
        if static_fp != PROD_CERT_SHA256:
            cert_diagnostics(old, user_dir, cfg_text, argv, running)
            raise Stop("握手看到的是正式服证书，可从配置里推不出它从哪来。先别动，把这段输出发过来。")
        cert_mode = {"flag": "flag", "cfg": "cfg", "bundle": "carry"}[source]
        say("      → 已经是正式服证书；" + ("新目录会换上旧目录那份证书文件" if cert_mode == "carry"
                                     else "证书不在版本目录里，换版本不影响它"))
    elif current_cert == TEST_CERT_SHA256:
        if not presented_before:
            cert_diagnostics(old, user_dir, cfg_text, argv, running)
            raise Stop("战斗服务器用的是测试服证书、要换成正式服那张，但握手探测不到，没法验证换完的结果，不敢换。"
                       "把这段输出发过来。")
        cert_src, key_src = find_prod_keypair()
        if not cert_src or not key_src:
            cert_diagnostics(old, user_dir, cfg_text, argv, running)
            raise Stop("战斗服务器用的是测试服证书；机器上有正式服证书，但找不到和它配对的私钥，不敢换。"
                       "先别动，把这段输出发过来。")
        current_key = option(argv, "--tls-key")
        key_dir = Path(current_key).parent if current_key else Path("/opt/glory")
        switch = {"cert_src": cert_src, "key_src": key_src,
                  "cert": key_dir / PROD_CERT_COPY, "key": key_dir / PROD_KEY_COPY,
                  "reference": Path(current_key) if current_key and Path(current_key).is_file() else None}
        cert_mode = "switch"
        say(f"      → 这次换成正式服证书：{cert_src}（配对私钥 {key_src}，公钥已核对）")
        say(f"        会复制成 {switch['cert']} 和 {switch['key']}，启动命令加 --tls-cert=、换 --tls-key=")
    else:
        cert_diagnostics(old, user_dir, cfg_text, argv, running)
        raise Stop("搞不清正式服战斗服务器现在用哪张证书，不敢换。先别动，把这段输出发过来。")
    old_manifest = old / "server_bundle_manifest.json"
    if old_manifest.is_file():
        info = json.loads(old_manifest.read_text(encoding="utf-8"))
        say(f"      现在跑的：{old_path}（{str(info.get('git_sha', '?'))[:8]}，协议 {info.get('protocol', '?')}）")
    else:
        say(f"      现在跑的：{old_path}")
    say(f"      新版放在：{release}")
    say(f"      启动命令在：{unit_file}（端口 {port}）")

    say("[4/8] 检查账号服务器的代码来源 ...")
    if not (SRC / ".git").is_dir():
        raise Stop(f"{SRC} 不是 git 仓库，update.sh 拉不到新代码。把这句话发过来。")
    if not UPDATE_SH.is_file():
        raise Stop(f"没有 {UPDATE_SH}。把这句话发过来。")
    backend_before = run(["git", "-C", str(SRC), "rev-parse", "HEAD"])
    say(f"      账号服务器现在是 {backend_before[:8]}")

    say("[5/8] 检查在线玩家 ...")
    old_pid = pid(SERVICE)
    idle_checks = idle_gate(args.lobby_ok)
    last = idle_checks[-1]
    say(f"      战斗服务器连接 {last['battle_connections']}，账号服务器在线 {last['account_online']}")

    say("[6/8] 准备新版本（解压、逐个文件核对" + ("、复制正式服证书" if switch else "") + "）...")
    STAGE.mkdir(parents=True)
    carried = []
    try:
        release.mkdir(parents=True)
        PREPARED.append(created_root)
        with zipfile.ZipFile(ARCHIVE) as package:
            package.extractall(release)
        manifest = json.loads((release / "server_bundle_manifest.json").read_text(encoding="utf-8"))
        if manifest["git_sha"] != COMMIT or manifest["protocol"] != PROTOCOL or manifest.get("git_dirty"):
            raise RuntimeError("包里的提交号 / 协议号和预期不一致")
        for row in manifest["files"]:
            path = release / row["path"]
            if not path.is_file() or sha(path) != row["sha256"]:
                raise RuntimeError("包里的文件对不上：" + row["path"])
        before, after = userdir_settings(old / "project.godot"), userdir_settings(release / "project.godot")
        if before != after:
            raise RuntimeError(f"新旧版本的存档目录设置不一样（旧 {before}，新 {after}），换过去会找不到钥匙")
        if cert_mode == "carry":
            shutil.copy2(old / CERT_IN_BUNDLE, release / CERT_IN_BUNDLE)
            if cert_sha256((release / CERT_IN_BUNDLE).read_text(encoding="utf-8")) != PROD_CERT_SHA256:
                raise RuntimeError("复制过来的证书文件核对不上")
            carried.append(CERT_IN_BUNDLE)
        if (old / "override.cfg").is_file():
            shutil.copy2(old / "override.cfg", release / "override.cfg")
            carried.append("override.cfg")
        if nested:
            run(["chown", f"--reference={old.parent}", str(created_root)])
        run(["chown", "-R", f"--reference={old}", str(release)])
        if switch:
            for source_file, target in ((switch["cert_src"], switch["cert"]), (switch["key_src"], switch["key"])):
                if target.exists():
                    if sha(target) != sha(source_file):
                        raise RuntimeError(f"{target} 已经存在、内容和 {source_file} 不同，不覆盖")
                else:
                    shutil.copyfile(source_file, target)
                    PREPARED.append(target)
                if switch["reference"]:
                    run(["chown", f"--reference={switch['reference']}", str(target)])
                    run(["chmod", f"--reference={switch['reference']}", str(target)])
                else:
                    os.chmod(target, 0o600)
            if cert_sha256(switch["cert"].read_text(encoding="utf-8")) != PROD_CERT_SHA256 \
                    or not pubkey_of(switch["cert"], "cert") \
                    or pubkey_of(switch["cert"], "cert") != pubkey_of(switch["key"], "key"):
                raise RuntimeError("复制过去的正式服证书和私钥核对不上")
    except BaseException:
        discard_prepared()
        raise
    say(f"      {len(manifest['files'])} 个文件全部一致" + (f"；从旧目录带过来：{', '.join(carried)}" if carried else ""))
    if switch:
        say(f"      正式服证书和私钥已就位：{switch['cert']}、{switch['key']}")

    say("[7/8] 更新账号服务器（update.sh，大约一两分钟）...")
    backend_pid_before = pid("glory-backend")
    code, output = run_update_sh()
    if code != 0 or "OK（重启后" not in output:
        discard_prepared()
        raise Stop("update.sh 没跑成功（上面是它的输出），账号服务器可能停在半路。把整段输出发过来。")
    backend_after = run(["git", "-C", str(SRC), "rev-parse", "HEAD"])
    DONE.append(f"账号服务器 {backend_before[:8]} → {backend_after[:8]}")
    if not ok(["git", "-C", str(SRC), "merge-base", "--is-ancestor", COMMIT, backend_after]):
        discard_prepared()
        raise Stop(f"账号服务器拉到的代码（{backend_after[:8]}）里没有 a415a9dd，和战斗服务器包对不上。把这句话发过来。")
    if not ok(["git", "-C", str(SRC), "diff", "--quiet", COMMIT, backend_after, "--", "scripts", "scenes", "data"]):
        say("      ⚠️ GitHub 上 a415a9dd 之后又有战斗代码 / 数值改动。战斗服务器包是 a415a9dd 打的：")
        say("         正式包要从 a415a9dd 打，或者重打战斗服务器包再换一次。")
    healthy, schema_lines = schema_verdict(backend_pid_before)
    for line in schema_lines[-8:]:
        say("      " + line)
    if not healthy:
        discard_prepared()
        raise Stop("账号服务器更新了，但数据库结构对不上（多半是迁移没跑）。先在 Supabase 的 glory-prod 跑\n"
                   "   prod_migrations_042_045.sql，再重跑本脚本（会再重启一次账号服务器）。")
    if current_connections()[1]:
        discard_prepared()
        raise Stop("刚才这一两分钟里有人连上了战斗服务器（可能开了对局），先不切换。等打完重跑本脚本。")

    say("[8/8] 切换并重启战斗服务器（几秒钟）...")
    changes = {"--path": str(release)}
    if switch:
        changes["--tls-key"] = str(switch["key"])
        changes["--tls-cert"] = str(switch["cert"])
    unit_before = unit_file.read_text(encoding="utf-8")
    unit_after, replaced = rewrite_execstart(unit_before, old_path, changes)
    if replaced != 1:
        discard_prepared()
        raise Stop(f"{unit_file} 里写着旧目录的启动命令有 {replaced} 条（预期 1 条），改不了。"
                   "把 systemctl cat glory-server 的输出发过来。")
    (STAGE / "unit.before").write_text(unit_before, encoding="utf-8")
    (STAGE / "unit.after").write_text(unit_after, encoding="utf-8")
    expected_cert = PROD_CERT_SHA256 if switch else presented_before
    presented_after = ""
    switched = False
    try:
        unit_file.write_text(unit_after, encoding="utf-8")
        switched = True
        run(["systemctl", "daemon-reload"])
        effective = execstart_argv()
        for name, value in changes.items():
            if option(effective, name) != value:
                raise RuntimeError(f"daemon-reload 之后，生效的 {name} 不是 {value}")
        run(["systemctl", "restart", SERVICE], timeout=60)
        new_pid, startup = wait_started(old_pid, f"server started protocol={PROTOCOL} port={port}")
        if expected_cert:
            for _ in range(3):
                presented_after = probe_cert(port)
                if presented_after:
                    break
                time.sleep(2)
            if presented_after != expected_cert:
                raise RuntimeError(f"新版出示的证书是 {label(presented_after)}，应该是 {label(expected_cert)}")
            say(f"      新版出示的证书：{label(presented_after)}")
    except BaseException as error:
        say(f"      ❌ {error}")
        (STAGE / "failure.txt").write_text(str(error), encoding="utf-8")
        if switched:
            say("      正在把战斗服务器换回旧版本 ...")
            failed_pid = pid(SERVICE)
            unit_file.write_text(unit_before, encoding="utf-8")
            run(["systemctl", "daemon-reload"])
            run(["systemctl", "restart", SERVICE], timeout=60)
            try:
                wait_started(failed_pid, "server started protocol=")
                say(f"      战斗服务器已换回旧版本：{old_path}（出示 {label(probe_cert(port))}）")
            except Exception as again:
                say(f"      🔴 换回旧版本后也没等到 server started：{again}")
                say("      🔴 把这整段输出发过来，再跑 journalctl -u glory-server -n 80 --no-pager 一起发")
        discard_prepared()
        raise
    PREPARED.clear()
    DONE.append(f"战斗服务器 → 协议 {PROTOCOL}（{release}）")
    if switch:
        DONE.append("战斗服务器证书 → 正式服那张")

    statuses = {name: quiet(["systemctl", "is-active", name])
                for name in (SERVICE, "glory-backend", "livekit", "caddy")}
    try:
        health = json.loads(run(["curl", "-fsS", "--max-time", "10", HEALTH_URL]))
    except Exception as error:
        health = {"error": str(error)}
    started_line = next((line for line in startup.splitlines() if "server started protocol=" in line), "")
    servers = [line for line in quiet(["pgrep", "-af", "--", "--server"]).splitlines() if "Godot" in line
               or "godot" in line]
    report = {
        "status": "deployed", "commit": COMMIT, "protocol": PROTOCOL, "project": project,
        "archive_sha256": ARCHIVE_SHA256, "release": str(release), "old_release": old_path,
        "unit_file": str(unit_file), "cert_mode": cert_mode, "cert_source_before": where,
        "cert_presented_before": presented_before, "cert_presented_after": presented_after,
        "cert_files": {k: str(v) for k, v in switch.items()} if switch else {},
        "carried_from_old": carried, "backend_before": backend_before, "backend_after": backend_after,
        "schema": schema_lines, "old_pid": old_pid, "new_pid": new_pid, "idle_checks": idle_checks,
        "lobby_ok": args.lobby_ok, "services": statuses, "health": health, "started_line": started_line,
        "godot_server_processes": servers, "rollback_directory": str(STAGE), "verified_at": now(),
    }
    (STAGE / "deployment.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                                           encoding="utf-8")
    (STAGE / "startup.log").write_text(startup, encoding="utf-8")
    ARCHIVE.unlink()

    say("")
    say(f"✅ 正式服已更新到协议 {PROTOCOL}（{COMMIT[:8]}）")
    say(f"   账号服务器：{backend_before[:8]} → {backend_after[:8]}，数据库结构自检 OK")
    say(f"   战斗服务器：{started_line}")
    say(f"   战斗服务器证书：{label(presented_before) if presented_before else '（之前没测到）'} → "
        f"{label(presented_after) if presented_after else '（没测）'}")
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
    say("   要回滚战斗服务器（连证书一起回到原样）：")
    say(f"     sudo cp {STAGE}/unit.before {unit_file} && sudo systemctl daemon-reload && sudo systemctl restart {SERVICE}")
    say("   要回滚账号服务器：")
    say(f"     sudo git -C {SRC} reset --hard {backend_before} && sudo bash {UPDATE_SH} --after-pull")
    return 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(errors="replace")
    except AttributeError:
        pass
    try:
        sys.exit(main())
    except Stop as stop:
        discard_prepared()
        say(f"\n⛔ 停下了：{stop}")
        say("   已经改了的：" + ("；".join(DONE) if DONE else "没有，服务器上什么都没改"))
        sys.exit(2)
    except Exception as error:
        discard_prepared()
        say(f"\n❌ 出错停下了：{error}")
        say("   已经改了的：" + ("；".join(DONE) if DONE else "没有，服务器上什么都没改"))
        if STAGE.exists():
            say(f"   详情在 {STAGE}")
        sys.exit(1)
