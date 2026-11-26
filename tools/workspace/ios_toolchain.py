"""Read and verify the real Apple toolchain and the linked iOS SDK.

The deployment target remains independent of the build SDK. No metadata is
rewritten to make an older binary appear to use a newer toolchain.
"""
from pathlib import Path
import re
import subprocess

MINIMUM_IOS_SDK = "27.1"
MINIMUM_XCODE = "27.1"


def version_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise RuntimeError(f"无法识别 Apple 版本：{value!r}")
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def _read(command, env=None):
    result = subprocess.run(command, env=env, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{Path(command[0]).name} 工具链检查失败：" + result.stderr.strip()[-1200:])
    return result.stdout.strip()


def validate_toolchain(value):
    if not isinstance(value, dict):
        raise RuntimeError("Apple 工具链记录必须为对象。")
    for key, minimum in (("xcode_version", MINIMUM_XCODE), ("iphoneos_sdk_version", MINIMUM_IOS_SDK)):
        if version_tuple(value.get(key)) < version_tuple(minimum):
            raise RuntimeError(f"GLory iPhone Duo 构建要求 {key} >= {minimum}，当前为 {value.get(key)}。")
    if not value.get("xcode_build") or not value.get("iphoneos_sdk_build"):
        raise RuntimeError("Apple 工具链缺少 Xcode/SDK build 标识。")
    return value


def inspect_toolchain(env=None):
    xcode = _read(["xcrun", "xcodebuild", "-version"], env)
    version = re.search(r"^Xcode (\d+(?:\.\d+){0,2})$", xcode, re.M)
    build = re.search(r"^Build version (\S+)$", xcode, re.M)
    if not version or not build:
        raise RuntimeError("无法确认完整 Xcode 版本；不能用 Command Line Tools 构建 IPA。")
    sdk_path = _read(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], env)
    if not Path(sdk_path).is_dir():
        raise RuntimeError("Xcode 缺少 iPhoneOS SDK。")
    developer = (env or {}).get("DEVELOPER_DIR") or _read(["xcode-select", "-p"], env)
    return validate_toolchain({
        "developer_dir": str(Path(developer).resolve()),
        "xcode_version": version[1], "xcode_build": build[1],
        "iphoneos_sdk_version": _read(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], env),
        "iphoneos_sdk_build": _read(["xcrun", "--sdk", "iphoneos", "--show-sdk-build-version"], env),
        "iphoneos_sdk_path": sdk_path,
    })


def parse_build_version(output):
    """Require one iPhoneOS load command; a simulator or old min-version is not proof."""
    blocks = re.split(r"(?m)^Load command \d+\s*$", output)
    records = []
    for block in blocks:
        if not re.search(r"(?m)^\s*cmd LC_BUILD_VERSION\s*$", block):
            continue
        values = {}
        for key in ("platform", "minos", "sdk"):
            match = re.search(r"(?m)^\s*" + key + r"\s+(\S+)\s*$", block)
            if match:
                values[key] = match[1]
        records.append(values)
    if len(records) != 1 or records[0].get("platform") not in ("IOS", "2"):
        raise RuntimeError("IPA 主程序必须只有一个 iPhoneOS LC_BUILD_VERSION；不能以 plist 或模拟器程序替代。")
    return records[0]


def validate_app_metadata(info, build, expected):
    validate_toolchain(expected)
    sdk = build.get("sdk")
    if version_tuple(sdk) < version_tuple(MINIMUM_IOS_SDK):
        raise RuntimeError(f"IPA Mach-O 实际 SDK {sdk} 低于 {MINIMUM_IOS_SDK}。")
    match = re.fullmatch(r"iphoneos(\d+(?:\.\d+){0,2})", str(info.get("DTSDKName", "")))
    if not match or version_tuple(match[1]) != version_tuple(sdk):
        raise RuntimeError("IPA DTSDKName 与 Mach-O SDK 不一致。")
    if version_tuple(sdk) != version_tuple(expected["iphoneos_sdk_version"]):
        raise RuntimeError("IPA 实际 SDK 与本次选定工具链不一致。")
    if info.get("DTXcodeBuild") != expected["xcode_build"]:
        raise RuntimeError("IPA DTXcodeBuild 与本次选定 Xcode 不一致。")
    if info.get("DTSDKBuild") != expected["iphoneos_sdk_build"]:
        raise RuntimeError("IPA DTSDKBuild 与本次选定 SDK build 不一致。")
    if version_tuple(str(info.get("MinimumOSVersion", ""))) != version_tuple(build.get("minos")):
        raise RuntimeError("IPA 最低系统版本与 Mach-O 不一致。")
    return {
        "sdk_version": sdk, "sdk_build": info["DTSDKBuild"],
        "xcode_build": info["DTXcodeBuild"], "minimum_os_version": build["minos"],
        "mach_o_sdk_verified": True,
    }
