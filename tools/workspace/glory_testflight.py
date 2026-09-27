#!/usr/bin/env python3
"""Update, build and publish Glory to its existing internal TestFlight group."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import glory_ios_build as ios
from glory_asc import ApiError, Client, Credentials

ROOT = Path(__file__).resolve().parents[3]
APP_ID = "6811578280"
GROUP_ID = "90dd8f53-b157-49c4-b899-8da72091b76a"
GROUP_NAME = "GLory 内部验证"
CONFIG_DIR = Path.home() / "Library/Application Support/Glory-iOS/testflight"
CONFIG_FILE = CONFIG_DIR / "api.json"
RELEASE_DIR = ROOT / "build/testflight-releases"
LATEST = ROOT / "build/latest-testflight-release.json"
URL = f"https://appstoreconnect.apple.com/apps/{APP_ID}/testflight"
DEFAULT_NOTES = ROOT / "docs" / "TestFlight测试内容.txt"
READY = {"READY_FOR_BETA_TESTING", "IN_BETA_TESTING"}


def note(message):
    print(f"[TestFlight] {message}", flush=True)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def safe_text(text):
    text = re.sub(r"-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----", "[私钥已隐藏]", text, flags=re.S)
    text = re.sub(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b", "[JWT 已隐藏]", text)
    return re.sub(r"(?i)(authorization\s*[:=]\s*)(?:bearer\s+)?[^\r\n]+", r"\1[已隐藏]", text)


def load_credentials():
    if not CONFIG_FILE.is_file():
        raise RuntimeError("尚未配置自动上传 API 密钥。先运行 ./release_testflight.sh --setup；操作说明见 TestFlight一键发布.md。")
    config = read_json(CONFIG_FILE)
    credentials = Credentials(config["key_id"], config["issuer_id"], Path(config["key_path"]).expanduser())
    credentials.validate()
    return credentials


def preflight(client):
    app = client.request("GET", f"/apps/{APP_ID}")["data"]
    if app.get("id") != APP_ID or app.get("attributes", {}).get("bundleId") != ios.BUNDLE:
        raise RuntimeError("API 密钥对应的应用不匹配，已停止。")
    groups = client.items("/betaGroups", {"filter[app]": APP_ID, "filter[isInternalGroup]": "true", "limit": 200})
    group = next((g for g in groups if g["id"] == GROUP_ID), None)
    if not group or group.get("attributes", {}).get("isInternalGroup") is not True:
        raise RuntimeError("API 密钥无法访问 GLory 的既有内部测试组，或该组已被更改。")
    if group["attributes"].get("name") != GROUP_NAME:
        raise RuntimeError("内部测试组名称已变化，请先核对脚本中的固定组 ID 和名称。")
    note(f"Apple 访问验证通过：{app['attributes'].get('name')} → {GROUP_NAME}。")


def setup(args):
    if not sys.stdin.isatty() and not all((args.key_file, args.key_id, args.issuer_id)):
        raise RuntimeError("请在终端运行 --setup，或同时指定 --key-file、--key-id、--issuer-id。")
    source = (args.key_file or Path(input("下载的 AuthKey_XXXXXXXXXX.p8 文件完整路径（无需加引号）：").strip())).expanduser().resolve()
    key_id = args.key_id or input("Key ID：").strip()
    issuer_id = args.issuer_id or input("Issuer ID（不是 Team ID）：").strip()
    if not source.is_file() or source.stat().st_size > 16384:
        raise RuntimeError("找不到有效的 .p8 密钥文件。")
    CONFIG_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    CONFIG_DIR.chmod(0o700)
    # Validate a private copy; original Downloads permissions need not be changed.
    with tempfile.TemporaryDirectory(prefix="setup-", dir=CONFIG_DIR) as folder:
        candidate = Path(folder) / "key.p8"
        shutil.copyfile(source, candidate)
        candidate.chmod(0o600)
        credentials = Credentials(key_id, issuer_id, candidate)
        credentials.validate()
        client = Client(credentials)
        preflight(client)
        next_number(client)  # Check remote build/upload-list access before saving configuration.
        destination = CONFIG_DIR / f"AuthKey_{key_id}.p8"
        if destination.exists() and destination.read_bytes() != candidate.read_bytes():
            raise RuntimeError("相同 Key ID 已保存不同私钥，拒绝覆盖；请核对 Apple 的 Key ID。")
        os.replace(candidate, destination)
        ios.atomic_json(CONFIG_FILE, {"key_id": key_id, "issuer_id": issuer_id, "key_path": str(destination)})
        CONFIG_FILE.chmod(0o600)
    note("API 密钥已保存到本机专用目录。以后直接运行 ./release_testflight.sh。")


def next_number(client):
    local_file = ROOT / "build/ios-auto-work/build-number.json"
    values = [str(read_json(local_file).get("last_build_number", "1")) if local_file.is_file() else "1"]
    # Across all marketing versions, including uploads not yet visible under /builds.
    for item in client.items("/builds", {"filter[app]": APP_ID, "filter[preReleaseVersion.platform]": "IOS", "limit": 200}):
        values.append(str(item["attributes"]["version"]))
    for item in client.items(f"/apps/{APP_ID}/buildUploads", {"filter[platform]": "IOS", "limit": 200}):
        values.append(str(item["attributes"]["cfBundleVersion"]))
    try:
        return ios.next_build_number(max(values, key=ios.build_tuple))
    except RuntimeError:
        raise RuntimeError("远端或本地存在无法自动递增的构建号，请先检查版本记录。") from None


def find_build(client, metadata):
    builds = client.items("/builds", {"filter[app]": APP_ID,
        "filter[preReleaseVersion.platform]": "IOS", "filter[preReleaseVersion.version]": metadata["version"],
        "filter[version]": metadata["build_number"], "limit": 200})
    if len(builds) > 1:
        raise RuntimeError("Apple 返回了多个同版本构建，已停止以避免分配错包。")
    return builds[0] if builds else None


def upload_records(client, metadata):
    return [u for u in client.items(f"/apps/{APP_ID}/buildUploads", {
        "filter[platform]": "IOS", "filter[cfBundleShortVersionString]": metadata["version"], "limit": 200})
        if str(u.get("attributes", {}).get("cfBundleVersion")) == metadata["build_number"]]


def validate_metadata(metadata):
    if metadata.get("method") != "app-store" or metadata.get("package_id") != ios.BUNDLE:
        raise RuntimeError("需要本项目构建的 App Store IPA，Ad Hoc 包不能发布到 TestFlight。")
    if not metadata.get("built") or not metadata.get("signed") or not all(metadata.get("validation", {}).get(k) for k in ("zip_crc", "codesign", "arm64", "pck_identity")):
        raise RuntimeError("构建记录缺少已通过的签名和包校验。")
    ios.build_tuple(metadata["build_number"])
    ipa = Path(metadata["ipa"]).resolve()
    if not ipa.is_file() or ios.shared.digest(ipa) != metadata["ipa_sha256"]:
        raise RuntimeError("IPA 已缺失或内容发生变化，不能继续上传此构建。")
    with zipfile.ZipFile(ipa) as archive:
        plists = [p for p in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", p)]
        if len(plists) != 1:
            raise RuntimeError("IPA 主应用数量异常。")
        info = plistlib.loads(archive.read(plists[0]))
        if (info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != (ios.BUNDLE, metadata["version"], metadata["build_number"]):
            raise RuntimeError("IPA 实际版本与构建记录不匹配。")
    return ipa


def save(state, path, **changes):
    state.update(changes, updated_at_utc=dt.datetime.now(dt.timezone.utc).isoformat())
    ios.atomic_json(path, state)
    ios.atomic_json(LATEST, {"state_file": str(path), "phase": state["phase"], "updated_at_utc": state["updated_at_utc"]})


def upload(client, credentials, metadata, state, path):
    # A begun upload may have succeeded even if its process was interrupted. Resume only polls it.
    if state.get("upload_attempted"):
        note("继续查询此前的上传；不会重复提交相同构建号。")
        return
    if find_build(client, metadata) or upload_records(client, metadata):
        raise RuntimeError("Apple 已存在相同版本/构建号，本次尚无上传记录；请重新运行发布以分配新号。")
    save(state, path, phase="uploading", upload_attempted=True)
    command = ["xcrun", "altool", "--upload-package", metadata["ipa"],
        "--api-key", credentials.key_id, "--api-issuer", credentials.issuer_id,
        "--p8-file-path", str(credentials.key_path), "--output-format", "json"]
    note("上传 IPA 到 Apple，耗时取决于网络；上传日志将在结束后写入本次发布目录。")
    log = path.parent / "upload.log"
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=3600)
        output = safe_text(result.stdout.decode(errors="replace"))
        log.write_text(output, encoding="utf-8")
        log.chmod(0o600)
        save(state, path, phase="processing", upload_exit_code=result.returncode, upload_log=str(log))
        if result.returncode:
            note(f"上传命令返回 {result.returncode}，先查询 Apple 是否已收包；详情：{log}")
        else:
            note(f"Apple 上传命令完成；日志：{log}")
    except subprocess.TimeoutExpired as error:
        output = error.output or b""
        log.write_text(safe_text(output.decode(errors="replace") if isinstance(output, bytes) else output), encoding="utf-8")
        log.chmod(0o600)
        save(state, path, phase="processing", upload_outcome="unknown", upload_log=str(log))
        note("上传命令超时，先查询 Apple 是否已收到；不重复上传同一编号。")


def wait_ready(client, metadata, timeout, interval):
    deadline = time.monotonic() + timeout
    while True:
        build = find_build(client, metadata)
        if build:
            attributes = build.get("attributes", {})
            processing = attributes.get("processingState")
            if processing in {"FAILED", "INVALID"} or attributes.get("expired"):
                raise RuntimeError(f"Apple 构建处理失败或过期：{processing}。请查看后台并用新构建号发布。")
            internal = "PROCESSING"
            if processing == "VALID":
                try:
                    detail = client.request("GET", f"/builds/{build['id']}/buildBetaDetail")["data"]["attributes"]
                    internal = detail.get("internalBuildState")
                except ApiError as error:
                    if error.status != 404:
                        raise
                    internal = "PROCESSING"
            if internal in {"MISSING_EXPORT_COMPLIANCE", "IN_EXPORT_COMPLIANCE_REVIEW"}:
                raise RuntimeError(f"Apple 需要处理出口合规信息（{internal}）；在后台完成后执行 --resume。")
            if internal in {"PROCESSING_EXCEPTION", "EXPIRED"}:
                raise RuntimeError(f"Apple 内部测试状态异常：{internal}。")
            note(f"Apple：{metadata['version']} ({metadata['build_number']})，处理={processing}，内部测试={internal}。")
            if processing == "VALID" and internal in READY:
                return build["id"]
        else:
            records = upload_records(client, metadata)
            states = [r.get("attributes", {}).get("state", {}).get("state") for r in records]
            if states and all(s == "FAILED" for s in states):
                raise RuntimeError("Apple 上传处理失败，请查看 upload.log / Apple 后台，修正后重新发布新构建。")
            note("等待 Apple 生成可测试构建" + (f"（上传状态：{', '.join(str(s) for s in states)}）" if states else "（暂未出现）") + "…")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("等待 Apple 超时；本次构建已保留。稍后执行 --resume 继续查询和分配。")
        time.sleep(min(interval, remaining))


def localizations(client, build_id):
    return client.items("/betaBuildLocalizations", {"filter[build]": build_id, "filter[locale]": "zh-Hans", "limit": 200})


def set_notes(client, build_id, notes):
    current = localizations(client, build_id)
    if len(current) > 1:
        raise RuntimeError("Apple 返回多个中文测试说明记录，请先在后台核对。")
    if current and current[0]["attributes"].get("whatsNew") == notes:
        return
    try:
        if current:
            identifier = current[0]["id"]
            client.request("PATCH", f"/betaBuildLocalizations/{identifier}", {"data": {
                "type": "betaBuildLocalizations", "id": identifier, "attributes": {"whatsNew": notes}}})
        else:
            client.request("POST", "/betaBuildLocalizations", {"data": {"type": "betaBuildLocalizations",
                "attributes": {"locale": "zh-Hans", "whatsNew": notes},
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
    except RuntimeError:
        if any(item["attributes"].get("whatsNew") == notes for item in localizations(client, build_id)):
            return
        raise
    if not any(item["attributes"].get("whatsNew") == notes for item in localizations(client, build_id)):
        raise RuntimeError("测试说明写入尚未被 Apple 确认，请用 --resume 重试。")


def assign_group(client, build_id):
    path = f"/betaGroups/{GROUP_ID}/relationships/builds"
    contains = lambda: any(item["id"] == build_id for item in client.items(path, {"limit": 200}))
    if contains():
        return
    try:
        client.request("POST", path, {"data": [{"type": "builds", "id": build_id}]})
    except RuntimeError:
        if contains():
            return
        raise
    if not contains():
        raise RuntimeError("测试组关系写入尚未被 Apple 确认，请用 --resume 重试。")


def build_command(args, result_file=None, number=None, check=False):
    command = [str(ROOT / "tools" / "build_ipa.sh"), "--method", "app-store"]
    if not args.local:
        command.append("--update")
    if check:
        command.append("--check")
    if result_file:
        command += ["--result-file", str(result_file), "--build-number", number]
    for option in ("version", "profile"):
        if getattr(args, option):
            command += ["--" + option, str(getattr(args, option))]
    return command


def check_local(args):
    if subprocess.run(build_command(args, check=True)).returncode:
        raise RuntimeError("本机 iOS 构建预检失败，尚未开始上传。")
    help_result = subprocess.run(["xcrun", "altool", "--help"], capture_output=True)
    help_text = (help_result.stdout + help_result.stderr).decode(errors="replace")
    if help_result.returncode or not all(flag in help_text for flag in ("--upload-package", "--p8-file-path", "--api-issuer")):
        raise RuntimeError("本机 altool 不支持脚本需要的上传参数，请更新 Xcode。")


def arguments(argv=None):
    parser = argparse.ArgumentParser(description="GitHub/Drive 更新 → IPA → TestFlight 内部测试。首次需 --setup。")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--setup", action="store_true", help="一次性配置团队 API Key，并在线验证应用/测试组访问")
    mode.add_argument("--check", action="store_true", help="只读预检签名、代码/资源目录和 Apple API；不更新或上传")
    mode.add_argument("--resume", nargs="?", const="latest", help="从最近一次发布或指定 state.json 继续，不重打包/重复上传")
    parser.add_argument("--local", action="store_true", help="使用现有本地代码/资源；默认从 GitHub/Drive 更新")
    parser.add_argument("--version", help="覆盖营销版本，例如 0.0.5")
    parser.add_argument("--profile", type=Path, help="更新后的 App Store 描述文件")
    parser.add_argument("--notes", type=Path, default=DEFAULT_NOTES, help="UTF-8 测试内容文本；开始发布时保存快照")
    parser.add_argument("--wait-minutes", type=int, default=30, help="每次等待 Apple 的最长分钟数，默认 30")
    parser.add_argument("--poll-seconds", type=int, default=30, help="查询间隔 10–60 秒，默认 30")
    parser.add_argument("--key-file", type=Path, help="--setup：团队 AuthKey_*.p8 文件路径")
    parser.add_argument("--key-id", help="--setup：Key ID（不是 Team ID）")
    parser.add_argument("--issuer-id", help="--setup：Issuer ID（不是 Team ID）")
    args = parser.parse_args(argv)
    if not 1 <= args.wait_minutes <= 180 or not 10 <= args.poll_seconds <= 60:
        parser.error("等待分钟数须为 1–180，查询间隔须为 10–60 秒。")
    if not args.setup and any((args.key_file, args.key_id, args.issuer_id)):
        parser.error("密钥配置参数仅用于 --setup。")
    if args.resume and (args.local or args.version or args.profile or args.notes != DEFAULT_NOTES):
        parser.error("--resume 使用原构建和测试内容快照，不能同时修改源码/版本/描述文件/测试内容。")
    return args


def main(argv=None):
    args = arguments(argv)
    if args.setup:
        setup(args)
        return
    # No source updates or expensive build until upload credentials pass preflight.
    credentials = load_credentials()
    client = Client(credentials)
    preflight(client)
    if args.check:
        check_local(args)
        number = next_number(client)
        note(f"只读预检完成，当前建议下一构建号：{number}。未同步、构建或上传。")
        return
    with ios.shared.file_lock(RELEASE_DIR / ".release.lock", nonblocking=True):
        if args.resume:
            path = Path(read_json(LATEST)["state_file"]) if args.resume == "latest" else Path(args.resume).expanduser().resolve()
            state = read_json(path)
            if state.get("app_id") != APP_ID or state.get("group_id") != GROUP_ID:
                raise RuntimeError("恢复文件不属于 GLory 的目标应用和内部测试组。")
        else:
            check_local(args)
            notes = args.notes.expanduser().read_text(encoding="utf-8").strip()
            if not notes or len(notes) > 4000:
                raise RuntimeError("测试内容须为 1–4000 字符的 UTF-8 文本。")
            number = next_number(client)
            stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
            path = RELEASE_DIR / stamp / "state.json"
            result_file = path.parent / "ipa-result.json"
            state = {"schema": 1, "app_id": APP_ID, "group_id": GROUP_ID, "notes": notes,
                     "phase": "building", "build_result_file": str(result_file), "build_number": number}
            save(state, path)
            note(f"更新并打包：本机与 Apple 已有构建号的下一号为 {number}。")
            if subprocess.run(build_command(args, result_file, number)).returncode:
                save(state, path, phase="build_failed")
                raise RuntimeError("代码更新、资源同步或打包未完成。请按上方错误修正后重新运行；没有上传。")
        try:
            result_file = Path(state["build_result_file"])
            if not result_file.is_file():
                raise RuntimeError("这次发布尚未生成 IPA，请重新运行 ./release_testflight.sh 开始构建。")
            metadata = read_json(result_file)
            if metadata.get("build_number") != state["build_number"]:
                raise RuntimeError("本次 IPA 的构建号不匹配，拒绝使用其他任务的包。")
            validate_metadata(metadata)
            # Store the exact immutable IPA identity; never use the mutable latest.ipa link for upload.
            save(state, path, ipa=metadata["ipa"], ipa_sha256=metadata["ipa_sha256"], version=metadata["version"])
            upload(client, credentials, metadata, state, path)
            build_id = wait_ready(client, metadata, args.wait_minutes * 60, args.poll_seconds)
            if state.get("upload_exit_code") != 0:
                raise RuntimeError("Apple 已出现同号构建，但本次上传没有成功回执，无法确认是否由其他电脑上传。请人工核对后台，或重新运行发布生成新号；脚本没有分配这个构建。")
            save(state, path, phase="distributing", apple_build_id=build_id)
            set_notes(client, build_id, state["notes"])
            preflight(client)  # Check internal-group scope again immediately before writing its relationship.
            assign_group(client, build_id)
            save(state, path, phase="complete", uploaded=True, internal_testing_enabled=True, testflight_url=URL)
            note(f"发布成功：{metadata['version']} ({metadata['build_number']}) 已加入「{GROUP_NAME}」。")
            note(f"现有组员可在 iPhone 的 TestFlight 安装/更新。IPA：{metadata['ipa']}")
            note(f"发布记录：{path}\n后台：{URL}")
        except (Exception, KeyboardInterrupt):
            note("本次发布记录已保留。继续执行：\n  ./release_testflight.sh --resume " + shlex.quote(str(path)))
            raise


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("[TestFlight] 已中止；如果上传已开始，请使用 --resume 查询结果。", file=sys.stderr)
        sys.exit(130)
    except ApiError as error:
        hint = ""
        if error.status == 401:
            hint = " 请检查 Key ID、Issuer ID、密钥是否有效，以及本机时间。"
        elif error.status == 403:
            hint = " 请检查团队密钥所属团队、角色及 App Store Connect API 访问权限。"
        print(f"[TestFlight] Apple API 未完成：{error}.{hint}", file=sys.stderr)
        sys.exit(1)
    except (RuntimeError, OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print(f"[TestFlight] 未完成：{safe_text(str(error))}", file=sys.stderr)
        sys.exit(1)
