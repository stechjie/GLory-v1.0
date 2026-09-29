#!/usr/bin/env python3
"""Build a manually signed Glory IPA; never upload or install it automatically."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import uuid
import zipfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import glory_build as shared

ROOT = Path(__file__).resolve().parents[3]
TEAM = "D5ANXXK2R2"
BUNDLE = "com.superforge.glory"
PRESET = "iOS Xcode"
SCHEME = "GloryIOS"
SIGNING = ROOT / "ios-signing-20260913/ios_distribution"
DEFAULT_PROFILES = {
    "ad-hoc": SIGNING / "Glory_AdHoc-8ecb8277-1628-489a-9a33-db30366d5338.mobileprovision",
    "app-store": SIGNING / "Glory_app_store.mobileprovision",
}
DEFAULT_KEYCHAIN = Path.home() / "Library/Keychains/glory-ios-D5ANXXK2R2.keychain-db"
PASSWORD_FILE = Path.home() / "Library/Application Support/Glory-iOS/signing/keychain-password"


def note(message):
    print(f"[IPA] {message}", flush=True)


def capture(command, *, env=None, input_data=None):
    """For public tool output only. Secret-bearing commands use unlock_keychain."""
    result = subprocess.run([str(v) for v in command], input=input_data, capture_output=True, env=env)
    if result.returncode:
        detail = result.stderr.decode(errors="replace").strip().splitlines()[-4:]
        raise RuntimeError(f"{Path(str(command[0])).name} 执行失败：" + "\n".join(detail))
    return result.stdout


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + f".tmp-{os.getpid()}")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    os.replace(temporary, path)


def as_utc(value):
    if not isinstance(value, dt.datetime):
        raise RuntimeError("描述文件缺少有效日期。")
    return value.replace(tzinfo=dt.timezone.utc) if value.tzinfo is None else value.astimezone(dt.timezone.utc)


def validate_profile_data(profile, method, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    if profile.get("TeamIdentifier") != [TEAM]:
        raise RuntimeError(f"描述文件 Team 不匹配，应为 {TEAM}。")
    entitlements = profile.get("Entitlements", {})
    if entitlements.get("application-identifier") != f"{TEAM}.{BUNDLE}":
        raise RuntimeError(f"描述文件 App ID 不匹配，应为 {TEAM}.{BUNDLE}。")
    if entitlements.get("com.apple.developer.team-identifier") != TEAM:
        raise RuntimeError("描述文件 entitlement 中的 Team 不匹配。")
    if not as_utc(profile.get("CreationDate")) <= now < as_utc(profile.get("ExpirationDate")):
        raise RuntimeError("描述文件尚未生效或已经过期，请提供有效版本。")
    if entitlements.get("get-task-allow", False) or profile.get("ProvisionsAllDevices", False):
        raise RuntimeError("需要 Ad Hoc/App Store 分发描述文件，不能使用 Development/Enterprise 文件。")
    devices = profile.get("ProvisionedDevices", [])
    if method == "ad-hoc" and not devices:
        raise RuntimeError("Ad Hoc 描述文件必须包含已登记测试设备。")
    if method == "app-store" and devices:
        raise RuntimeError("App Store 构建不能使用含设备列表的 Ad Hoc 描述文件。")
    if not profile.get("DeveloperCertificates") or not re.fullmatch(r"[0-9a-fA-F-]{36}", profile.get("UUID", "")):
        raise RuntimeError("描述文件缺少有效 UUID 或签名证书。")
    return profile


def read_profile(path, method):
    if not path.is_file():
        raise RuntimeError(f"找不到描述文件：{path}；可用 --profile 指定。")
    data = capture(["/usr/bin/security", "cms", "-D", "-i", path])
    return validate_profile_data(plistlib.loads(data), method)


def certificate_details(der):
    output = capture(["/usr/bin/openssl", "x509", "-inform", "DER", "-noout", "-subject", "-dates",
                      "-nameopt", "multiline"], input_data=der).decode()
    cn = re.search(r"^\s*commonName\s*=\s*(.+)$", output, re.M)
    dates = [re.search(r"^" + key + r"=(.+)$", output, re.M) for key in ("notBefore", "notAfter")]
    if not cn or not all(dates):
        raise RuntimeError("无法识别描述文件中的发布证书。")
    parse = lambda value: dt.datetime.strptime(value, "%b %d %H:%M:%S %Y GMT").replace(tzinfo=dt.timezone.utc)
    return {"sha1": hashlib.sha1(der).hexdigest().upper(), "name": cn[1].strip(),
            "not_before": parse(dates[0][1]), "not_after": parse(dates[1][1])}


def select_identity(profile, keychain):
    if not keychain.is_file():
        raise RuntimeError(f"找不到已配置的签名钥匙串：{keychain}")
    identities = capture(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning", keychain]).decode()
    available = set(re.findall(r"\b[0-9A-Fa-f]{40}\b", identities.upper()))
    now = dt.datetime.now(dt.timezone.utc)
    for der in profile["DeveloperCertificates"]:
        cert = certificate_details(der)
        if cert["sha1"] in available and cert["not_before"] <= now < cert["not_after"]:
            if "Distribution:" in cert["name"]:
                return cert
    raise RuntimeError("专用钥匙串中没有与此描述文件匹配的有效发布签名身份；请先配置证书及其私钥。")


def unlock_keychain(keychain, password_file=PASSWORD_FILE):
    if not password_file.is_file():
        raise RuntimeError(f"找不到专用钥匙串密码文件：{password_file}")
    password = password_file.read_text().rstrip("\r\n")
    if not password:
        raise RuntimeError("专用钥匙串密码文件为空。")
    # Never use check=True here: CalledProcessError includes argv (and the password).
    try:
        result = subprocess.run(["/usr/bin/security", "unlock-keychain", "-p", password, str(keychain)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        raise RuntimeError("无法调用 security 解锁专用签名钥匙串。") from None
    finally:
        password = ""
    if result.returncode:
        raise RuntimeError("无法解锁专用签名钥匙串，请检查本机签名配置。")


def project_version(project, override=None):
    text = (project / "project.godot").read_text(encoding="utf-8-sig")
    application = re.search(r"^\[application\]\s*$(.*?)(?=^\[|\Z)", text, re.M | re.S)
    match = re.search(r'^config/version="([^"]+)"', application[1], re.M) if application else None
    version = override or (match[1] if match else "0.0.4")
    if not override and not match:
        note("项目没有 config/version，采用此前已验证的营销版本 0.0.4；可用 --version 覆盖。")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise RuntimeError("iOS 营销版本须为三个数字段，例如 --version 0.0.4。")
    return version


def build_tuple(value):
    if not re.fullmatch(r"[1-9]\d{0,3}(?:\.(?:0|[1-9]\d?)){0,2}", str(value)):
        raise RuntimeError("build number 须符合 CFBundleVersion，例如 2、10.1 或 10.1.2。")
    parts = tuple(int(part) for part in str(value).split("."))
    return parts + (0,) * (3 - len(parts))


def next_build_number(previous):
    major, minor, patch = build_tuple(previous)
    if major < 9999:
        return str(major + 1)
    if patch < 99:
        return f"{major}.{minor}.{patch + 1}"
    if minor < 99:
        return f"{major}.{minor + 1}.0"
    raise RuntimeError("本机 build number 已达到 CFBundleVersion 上限。")


def reserve_build_number(state_file, requested=None):
    state = json.loads(state_file.read_text()) if state_file.is_file() else {}
    previous = str(state.get("last_build_number", "1"))
    number = str(requested) if requested is not None else next_build_number(previous)
    if build_tuple(number) < (2, 0, 0):
        raise RuntimeError("此项目已有 build 1，新构建的 build number 至少为 2。")
    if requested is not None and build_tuple(number) <= build_tuple(previous):
        raise RuntimeError(f"指定的 build number 必须大于本机已记录的 {previous}。")
    # Reserve before building. Failed builds may leave gaps, but never reuse an automatic number.
    high = max((previous, number), key=build_tuple)
    atomic_json(state_file, {"last_build_number": high, "reserved_utc": dt.datetime.now(dt.timezone.utc).isoformat()})
    return number


def git_output(project, *args):
    return capture(["git", "-C", project, *args]).decode().strip()


def git_update_ready(project):
    if git_output(project, "status", "--porcelain=v1"):
        raise RuntimeError("--update 要求 Git 工作区干净；请先处理修改、未跟踪文件或冲突。")
    for state in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"):
        path = Path(git_output(project, "rev-parse", "--git-path", state))
        if not path.is_absolute():
            path = project / path
        if path.exists():
            raise RuntimeError(f"Git 操作尚未结束（{state}），请先处理。")
    branch = git_output(project, "symbolic-ref", "--quiet", "--short", "HEAD")
    upstream = git_output(project, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
    if not branch or not upstream:
        raise RuntimeError("--update 需要当前本地分支及其已配置的 upstream。")
    return branch, upstream


def update_sources(project, logdir, env):
    branch, upstream = git_update_ready(project)
    before = git_output(project, "rev-parse", "HEAD")
    note(f"更新 Git 分支 {branch} ← {upstream}（仅 fast-forward）…")
    remote = git_output(project, "config", "--get", f"branch.{branch}.remote")
    if not remote or remote == ".":
        raise RuntimeError("当前分支需要远端仓库 upstream 才能更新 GitHub。")
    run(["git", "-C", project, "fetch", "--no-tags", remote], logdir / "git-fetch.log", env)
    # pull cannot forward this guard. Never overwrite ignored local resource paths.
    run(["git", "-C", project, "-c", "merge.autoStash=false", "-c", "rebase.autoStash=false",
         "merge", "--ff-only", "--no-autostash", "--no-overwrite-ignore", "@{upstream}"],
        logdir / "git-update.log", env)
    result = subprocess.run(["git", "-C", str(project), "merge-base", "--is-ancestor", before, "HEAD"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode:
        raise RuntimeError("更新后无法确认原提交仍保留，已停止构建。")
    note("同步 Google Drive 资源到 res（调用现有 sync_res.sh）…")
    run([Path(__file__).resolve().with_name("sync_res.sh")], logdir / "resource-sync.log", env)


def environment(args):
    if sys.platform != "darwin":
        raise RuntimeError("iOS IPA 构建需要 macOS 和完整 Xcode。")
    child = dict(os.environ)
    if not child.get("DEVELOPER_DIR") and Path("/Applications/Xcode.app/Contents/Developer").is_dir():
        child["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    xcode = capture(["xcrun", "xcodebuild", "-version"], env=child).decode().strip()
    sdk = capture(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], env=child).decode().strip()
    if not Path(sdk).is_dir():
        raise RuntimeError("Xcode 缺少 iPhoneOS SDK。")
    godot = shared.find_executable([args.godot, os.environ.get("GODOT_BIN"),
        "/Volumes/repository/glory-ios-dev/tools/godot/Godot.app", ROOT / "tools/godot/Godot.app",
        "/Applications/Godot.app", "godot", "godot4"])
    if not godot:
        raise RuntimeError("找不到匹配项目的 Godot；可用 --godot 指定 .app 或二进制。")
    version = capture([godot, "--version"]).decode().strip().splitlines()[-1]
    match = re.match(r"(\d+\.\d+)(?:\.(\d+))?\.([^.]+)", version)
    if not match:
        raise RuntimeError(f"无法识别 Godot 版本：{version}")
    template_version = f"{match[1]}{'.' + match[2] if match[2] else ''}.{match[3]}"
    templates = shared.first_dir([args.templates, os.environ.get("GODOT_TEMPLATES"),
        Path.home() / "Library/Application Support/Godot/export_templates" / template_version], "ios.zip")
    if not templates:
        raise RuntimeError(f"缺少 {template_version} iOS 导出模板。")
    text = (args.project / "project.godot").read_text(encoding="utf-8-sig")
    feature = re.search(r'config/features=.*?"(\d+\.\d+)"', text)
    if feature and feature[1] != match[1]:
        raise RuntimeError(f"项目要求 Godot {feature[1]}，当前为 {version}。")
    if (templates / "version.txt").read_text().strip() != template_version:
        raise RuntimeError("导出模板版本文件与 Godot 不匹配。")
    with zipfile.ZipFile(templates / "ios.zip") as archive:
        required = {"godot_apple_embedded.xcodeproj/project.pbxproj", "libgodot.ios.release.xcframework/ios-arm64/libgodot.a"}
        if not required.issubset(archive.namelist()):
            raise RuntimeError("iOS 模板缺少 Xcode 工程或 arm64 Release 库。")
    if not shutil.which("rsync"):
        raise RuntimeError("缺少 rsync。")
    return {"child": child, "godot": godot, "version": version, "templates": templates,
            "template_version": template_version, "xcode": xcode}


def run(command, log, env):
    note(f"运行中，完整日志：{log}")
    with log.open("w") as output:
        process = subprocess.Popen([str(v) for v in command], stdout=output, stderr=subprocess.STDOUT, env=env)
        try:
            while True:
                try:
                    code = process.wait(timeout=30)
                    break
                except subprocess.TimeoutExpired:
                    tail = log.read_text(errors="replace").splitlines()[-1:]
                    note("仍在处理：" + (tail[0][:180] if tail else "等待工具输出"))
        except BaseException:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise
    content = re.sub(r"\x1b\[[0-9;]*m", "", log.read_text(errors="replace"))
    if code:
        raise RuntimeError(f"步骤失败（退出码 {code}），详见 {log}\n" + "\n".join(content.splitlines()[-8:]))
    return content


def prepare_engine(env, work):
    folder = work / "engine"
    folder.mkdir(parents=True, exist_ok=True)
    godot = env["godot"]
    if godot.parent.name != "MacOS" or godot.parents[2].suffix != ".app":
        raise RuntimeError("请使用保留签名与资源的 Godot.app，不要只复制其内部可执行文件。")
    app = folder / "Godot.app"
    subprocess.run(["rsync", "-ac", "--delete", str(godot.parents[2]) + "/", str(app) + "/"], check=True)
    capture(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    (folder / "_sc_").touch()
    template_root = folder / "editor_data/export_templates"
    template_root.mkdir(parents=True, exist_ok=True)
    target = template_root / env["template_version"]
    if target.is_symlink() and target.resolve() != env["templates"]:
        target.unlink()
    if not target.exists():
        target.symlink_to(env["templates"], target_is_directory=True)
    return app / "Contents/MacOS/Godot"


def write_preset(stage, method, profile, cert, version, number):
    # Reuse Android's proven packaging filters; then replace all platform/signing options.
    shared.export_preset(stage, None)
    text = (stage / "export_presets.cfg").read_text()
    filters = {key: re.search(r'^' + key + r'="([^"]*)"', text, re.M)[1]
               for key in ("include_filter", "exclude_filter")}
    filters["exclude_filter"] += ",*.p12,*.pfx,*.keystore,*.jks,*.mobileprovision,*.csr,*.cer"
    header = {"name": PRESET, "platform": "iOS", "runnable": True, "dedicated_server": False,
              "custom_features": "", "export_filter": "all_resources", **filters,
              "export_path": "", "encrypt_pck": False, "encrypt_directory": False}
    options = {"architectures/arm64": True, "application/app_store_team_id": TEAM,
               "application/bundle_identifier": BUNDLE, "application/export_project_only": True,
               "application/export_method_release": 2 if method == "ad-hoc" else 0,
               "application/code_sign_identity_release": cert["name"],
               "application/provisioning_profile_specifier_release": profile["UUID"],
               "application/short_version": version, "application/version": number,
               "privacy/microphone_usage_description": "用于队伍语音聊天，仅在您主动开启麦克风时录音。",
               "application/targeted_device_family": 2, "application/min_ios_version": "15.0"}
    render = lambda values: "\n".join(f"{key}={json.dumps(value, ensure_ascii=False)}" for key, value in values.items())
    (stage / "export_presets.cfg").write_text("[preset.0]\n\n" + render(header) + "\n\n[preset.0.options]\n\n" + render(options) + "\n")
    (stage / "export_presets.cfg").chmod(0o600)
    (stage / "export_credentials.cfg").unlink(missing_ok=True)


def install_profile(source, profile):
    destination = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles" / f"{profile['UUID']}.mobileprovision"
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.is_file() or shared.digest(destination) != shared.digest(source):
        temporary = destination.with_suffix(".temporary")
        shutil.copy2(source, temporary)
        temporary.chmod(0o600)
        os.replace(temporary, destination)


def pck_file(pack, wanted):
    with pack.open("rb") as stream:
        magic, version, *_engine, flags = struct.unpack("<6I", stream.read(24))
        if magic != 0x43504447 or version not in (3, 4) or flags & 1:
            raise RuntimeError("无法验证此 PCK 格式或加密目录。")
        base, directory = struct.unpack("<QQ", stream.read(16))
        stream.seek(directory)
        count = struct.unpack("<I", stream.read(4))[0]
        for _ in range(count):
            length = struct.unpack("<I", stream.read(4))[0]
            name = stream.read(length).rstrip(b"\0").decode().removeprefix("res://")
            offset, size = struct.unpack("<QQ", stream.read(16))
            expected_md5 = stream.read(16)
            file_flags = struct.unpack("<I", stream.read(4))[0]
            if name == wanted:
                if file_flags:
                    raise RuntimeError("构建身份不能来自加密或差量 PCK 条目。")
                stream.seek(base + offset)
                data = stream.read(size)
                if len(data) != size or hashlib.md5(data).digest() != expected_md5:
                    raise RuntimeError("PCK 构建身份条目损坏。")
                return data
    raise RuntimeError(f"PCK 缺少 {wanted}。")


def verify_ipa(ipa, directory, method, profile, cert, version, number, identity, env):
    with zipfile.ZipFile(ipa) as archive:
        for member in archive.namelist():
            if member.startswith("/") or ".." in Path(member).parts:
                raise RuntimeError("IPA 含无效 ZIP 路径。")
        bad = archive.testzip()
        if bad:
            raise RuntimeError(f"IPA ZIP CRC 失败：{bad}")
    capture(["/usr/bin/ditto", "-x", "-k", ipa, directory])
    apps = list((directory / "Payload").glob("*.app"))
    if len(apps) != 1:
        raise RuntimeError("IPA 中应有且只有一个主应用。")
    app = apps[0]
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if (info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != (BUNDLE, version, number):
        raise RuntimeError("IPA 的 Bundle ID、营销版本或 build number 与本次配置不一致。")
    voice = app / "Frameworks/GloryVoice.framework/GloryVoice"
    if voice.exists():
        if not str(info.get("NSMicrophoneUsageDescription", "")).strip():
            raise RuntimeError("IPA 包含 iOS 语音组件，但麦克风用途声明为空。")
        for dependency in ("LiveKitWebRTC", "RustLiveKitUniFFI"):
            if not (app / f"Frameworks/{dependency}.framework/{dependency}").is_file():
                raise RuntimeError(f"IPA 缺少 iOS 语音依赖：{dependency}")
    actual = read_profile(app / "embedded.mobileprovision", method)
    if actual["UUID"] != profile["UUID"]:
        raise RuntimeError("IPA 内描述文件与本次所选文件不一致。")
    capture(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    entitlement_data = capture(["/usr/bin/codesign", "-d", "--entitlements", ":-", app])
    entitlements = plistlib.loads(entitlement_data)
    if entitlements.get("application-identifier") != f"{TEAM}.{BUNDLE}" or entitlements.get("com.apple.developer.team-identifier") != TEAM or entitlements.get("get-task-allow", False):
        raise RuntimeError("IPA 实际签名 entitlement 与分发配置不一致。")
    prefix = directory / "signer-"
    # codesign's optional prefix must be attached with '='; a separate token is treated as another input.
    capture(["/usr/bin/codesign", "-d", f"--extract-certificates={prefix}", app])
    if hashlib.sha1(Path(str(prefix) + "0").read_bytes()).hexdigest().upper() != cert["sha1"]:
        raise RuntimeError("IPA 实际签名证书与选定发布证书不一致。")
    executable = app / info["CFBundleExecutable"]
    arch = capture(["xcrun", "lipo", "-archs", executable], env=env).decode().split()
    if arch != ["arm64"] or "iPhoneOS" not in info.get("CFBundleSupportedPlatforms", []):
        raise RuntimeError("IPA 主程序不是 iPhoneOS arm64 真机程序。")
    packs = list(app.glob("*.pck"))
    if len(packs) != 1 or json.loads(pck_file(packs[0], "build_info.json")) != identity:
        raise RuntimeError("IPA 中的 Godot PCK 构建身份与本次代码/资源快照不一致。")
    return {"zip_crc": True, "codesign": True, "arm64": True, "embedded_profile_uuid": actual["UUID"],
            "allowed_device_udids": actual.get("ProvisionedDevices", []), "pck_identity": True}


def publish(ipa, outdir, summary):
    outdir.mkdir(parents=True, exist_ok=True)
    final = outdir / f"Glory-{summary['method']}-{summary['timestamp']}-{summary['git_commit_short']}.ipa"
    if final.exists():
        raise RuntimeError(f"拒绝覆盖已有 IPA：{final}")
    temporary = final.with_suffix(".ipa.partial")
    shutil.copy2(ipa, temporary)
    os.replace(temporary, final)
    summary.update(ipa=str(final), ipa_bytes=final.stat().st_size, ipa_sha256=shared.digest(final))
    atomic_json(Path(summary["logs"]) / "result.json", summary)
    metadata = outdir.parent / f"latest-ipa-{summary['method']}.json"
    latest = outdir / f"Glory-{summary['method']}-latest.ipa"
    link = outdir / f".latest-{os.getpid()}"
    link.symlink_to(final.name)
    # This point is reached only after every build and package verification passed.
    atomic_json(metadata, summary)
    os.replace(link, latest)
    note(f"构建完成：{final}（{final.stat().st_size / 1048576:.1f} MiB）")
    note(f"固定入口：{latest}；SHA-256：{summary['ipa_sha256']}")


def arguments(argv=None):
    parser = argparse.ArgumentParser(description="本地 Glory 代码 + res 生成 IPA，不上传、不安装。")
    parser.add_argument("--update", action="store_true", help="先 ff-only 更新当前 Git 分支，再同步 Drive 资源")
    parser.add_argument("--check", action="store_true", help="仅只读预检；即使带 --update 也不拉取/同步/解锁/导入")
    parser.add_argument("--method", choices=DEFAULT_PROFILES, default="ad-hoc")
    parser.add_argument("--profile", type=Path, help="覆盖当前方法的 .mobileprovision")
    parser.add_argument("--version", help="覆盖 project.godot 中的营销版本；缺省回退 0.0.4")
    parser.add_argument("--build-number", help="有效 CFBundleVersion；缺省自动递增，失败构建可跳号")
    parser.add_argument("--result-file", type=Path, help="将本次成功构建元数据另存到指定文件，供发布流程准确取包")
    parser.add_argument("--project", type=Path, default=ROOT / "GLory-v1.0")
    parser.add_argument("--assets", type=Path, default=ROOT / "res")
    parser.add_argument("--godot", help="Godot.app 或它的可执行文件")
    parser.add_argument("--templates", help="与 Godot 匹配的 iOS 模板目录")
    parser.add_argument("--keychain", type=Path, default=DEFAULT_KEYCHAIN)
    return parser.parse_args(argv)


def main(argv=None):
    args = arguments(argv)
    args.project = args.project.expanduser().resolve()
    args.keychain = args.keychain.expanduser().resolve()
    profile_path = (args.profile or DEFAULT_PROFILES[args.method]).expanduser().resolve()
    if not (args.project / "project.godot").is_file():
        raise RuntimeError(f"不是 Godot 工程：{args.project}")
    if args.build_number is not None:
        build_tuple(args.build_number)
        if build_tuple(args.build_number) < (2, 0, 0):
            raise RuntimeError("新构建的 build number 至少为 2。")
    if args.update and not args.check:
        git_update_ready(args.project)
    env = environment(args)
    version = project_version(args.project, args.version)
    profile = read_profile(profile_path, args.method)
    note(f"{env['version']}；{env['xcode'].replace(chr(10), ' / ')}；{args.method}；营销版本 {version}")
    note(f"描述文件 {profile['Name']}，到期 {as_utc(profile['ExpirationDate']).date()}，授权设备 {len(profile.get('ProvisionedDevices', []))} 台。")
    if args.check:
        assets = shared.asset_root(args.assets)
        sync_status = ROOT / ".glory-sync/last-run.json"
        if sync_status.is_file() and json.loads(sync_status.read_text()).get("status") in ("running", "failed"):
            raise RuntimeError("最近资源同步尚未成功完成。")
        cert = select_identity(profile, args.keychain)
        if not PASSWORD_FILE.is_file():
            raise RuntimeError("未找到本机专用钥匙串密码文件。")
        note(f"只读预检通过：资源 {assets}；发布身份 {cert['name']}。未同步、导入或构建。")
        return
    work = ROOT / "build/ios-auto-work"
    for source in (args.project, args.assets.expanduser().resolve()):
        if source.is_relative_to(work) or work.is_relative_to(source):
            raise RuntimeError("源目录与隔离 iOS 构建目录不能重叠。")
    with shared.file_lock(work / ".build.lock", nonblocking=True):
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        logdir = ROOT / "build/logs" / f"ipa-{args.method}-{stamp}"
        logdir.mkdir(parents=True)
        shared.note = note
        try:
            unlock_keychain(args.keychain)
            cert = select_identity(profile, args.keychain)
            if args.update:
                update_sources(args.project, logdir, env["child"])
                env = environment(args)
                version = project_version(args.project, args.version)
            assets = shared.asset_root(args.assets)
            stage = work / "project"
            with shared.file_lock(ROOT / ".glory-sync/sync.lock", shared=True):
                sync_status = ROOT / ".glory-sync/last-run.json"
                if sync_status.is_file() and json.loads(sync_status.read_text()).get("status") in ("running", "failed"):
                    raise RuntimeError("资源同步尚未成功完成，请先同步。")
                report = shared.stage_project(args.project, assets, stage, logdir)
            number = reserve_build_number(work / "build-number.json", args.build_number)
            note(f"本次 build number：{number}；快照：{stage}")
            install_profile(profile_path, profile)
            write_preset(stage, args.method, profile, cert, version, number)
            engine = prepare_engine(env, work)
            commit = git_output(args.project, "rev-parse", "HEAD")
            dirty = git_output(args.project, "status", "--porcelain=v1")
            identity = {"build_id": str(uuid.uuid4()), "git_commit": commit, "git_commit_short": commit[:8],
                        "dirty_files": len(dirty.splitlines()) if dirty else 0,
                        "build_utc": dt.datetime.now(dt.timezone.utc).isoformat(), "godot_version": env["version"],
                        "package_id": BUNDLE, "export_preset": PRESET, "version": version, "build_number": number,
                        "asset_inventory_sha256": report["actual_assets_sha256"],
                        "asset_inventory_kind": "merged_source_files_sha256"}
            atomic_json(stage / "build_info.json", identity)
            atomic_json(logdir / "build_info.json", identity)
            imported = shared.logged_process([engine, "--headless", "--editor", "--path", stage, "--import"],
                                             logdir / "import.log", env["child"], strict=False)
            materials = shared.verify_model_materials(engine, stage, logdir, env["child"])
            diagnostics = shared.verify_import_diagnostics(imported, stage, logdir, materials)
            run_dir = work / "runs" / stamp
            xcode_dir = run_dir / "xcode"
            xcode_dir.mkdir(parents=True)
            exported = shared.logged_process([engine, "--headless", "--path", stage, "--export-release", PRESET,
                                              xcode_dir / f"{SCHEME}.ipa"], logdir / "godot-export.log", env["child"], strict=False)
            shared.verify_export_diagnostics(exported, logdir)
            archive = run_dir / f"{SCHEME}.xcarchive"
            note("用当前描述文件和发布证书执行 Xcode Release Archive…")
            archive_log = run(["xcrun", "xcodebuild", "-project", xcode_dir / f"{SCHEME}.xcodeproj",
                "-scheme", SCHEME, "-configuration", "Release", "-sdk", "iphoneos",
                "-destination", "generic/platform=iOS", "-archivePath", archive, "-derivedDataPath", work / "DerivedData",
                "-hideShellScriptEnvironment", "CODE_SIGN_STYLE=Manual", f"DEVELOPMENT_TEAM={TEAM}",
                f"PROVISIONING_PROFILE_SPECIFIER={profile['UUID']}", f"CODE_SIGN_IDENTITY={cert['sha1']}",
                f'OTHER_CODE_SIGN_FLAGS=--keychain "{args.keychain}"', "archive"], logdir / "archive.log", env["child"])
            if "** ARCHIVE SUCCEEDED **" not in archive_log:
                raise RuntimeError("Xcode 未确认 Archive 成功。")
            options = {"destination": "export", "method": "release-testing" if args.method == "ad-hoc" else "app-store-connect",
                       "manageAppVersionAndBuildNumber": False, "teamID": TEAM, "signingStyle": "manual",
                       "signingCertificate": cert["sha1"], "provisioningProfiles": {BUNDLE: profile["UUID"]},
                       "stripSwiftSymbols": True, "uploadSymbols": False}
            options_path = run_dir / "ExportOptions.plist"
            options_path.write_bytes(plistlib.dumps(options))
            output = run_dir / "export"
            note(f"导出 {args.method} IPA 到本机，不上传…")
            run(["xcrun", "xcodebuild", "-exportArchive", "-archivePath", archive,
                 "-exportOptionsPlist", options_path, "-exportPath", output], logdir / "xcode-export.log", env["child"])
            ipas = list(output.glob("*.ipa"))
            if len(ipas) != 1:
                raise RuntimeError("Xcode 未生成唯一 IPA。")
            note("验证 ZIP、实际签名、描述文件、版本号、arm64 和包内构建身份…")
            checks = verify_ipa(ipas[0], run_dir / "verify", args.method, profile, cert, version, number, identity, env["child"])
            summary = dict(identity, method=args.method, timestamp=stamp, logs=str(logdir), profile=str(profile_path),
                           profile_uuid=profile["UUID"], signing_certificate_sha1=cert["sha1"], validation=checks,
                           model_materials=materials["summary"] if materials else None,
                           accepted_fbx_source_texture_errors=diagnostics["accepted_fbx_source_texture_errors"],
                           archive=str(archive), source_project=str(args.project), asset_source=str(assets),
                           signed=True, built=True, uploaded=False, device_installed=False)
            publish(ipas[0], ROOT / "build/ipa", summary)
            if args.result_file:
                atomic_json(args.result_file.expanduser().resolve(), summary)
        except BaseException as error:
            atomic_json(logdir / "failure.json", {"built": False, "error": str(error), "logs": str(logdir)})
            raise


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print(f"[IPA] 失败：{error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("[IPA] 已中止；没有更新 latest IPA。", file=sys.stderr)
        sys.exit(130)
