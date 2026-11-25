#!/usr/bin/env python3
"""Build a local-only arm64 Simulator QA app from a canonical IPA Xcode export.

Copies the export and substitutes actual Simulator libraries in a unique run
directory. The production export, frameworks, signing configuration and PCK
remain untouched. This is not an IPA distribution entry point.
"""
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
import subprocess
import sys

sys.dont_write_bytecode = True
import ios_toolchain

ROOT = Path(os.environ["GLORY_WORKSPACE"]).resolve() if os.environ.get("GLORY_WORKSPACE") else Path(__file__).resolve().parents[3]
SCHEME = "GloryIOS"
QA_BUNDLE = "com.superforge.glory.duoqa"
FRAMEWORKS = ("GloryVoice", "LiveKitWebRTC", "RustLiveKitUniFFI")


def sha(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(data)
    return value.hexdigest()


def read(command, env):
    result = subprocess.run([str(v) for v in command], env=env, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{command[0]} failed: {result.stderr.strip()[-1200:]}")
    return result.stdout.strip()


def simulator_binary(binary, env, *, require_current_sdk=False):
    archs = read(["xcrun", "lipo", "-archs", binary], env).split()
    if "arm64" not in archs:
        raise RuntimeError(f"Simulator QA requires an arm64 slice: {binary}")
    output = read(["xcrun", "vtool", "-arch", "arm64", "-show-build", binary], env)
    platforms = re.findall(r"(?m)^\s*platform\s+(\S+)\s*$", output)
    if platforms != ["IOSSIMULATOR"]:
        raise RuntimeError(f"Binary is not an arm64 iOS Simulator build: {binary}")
    sdk = re.search(r"(?m)^\s*sdk\s+(\S+)\s*$", output)
    if not sdk:
        raise RuntimeError(f"Simulator binary SDK is unknown: {binary}")
    if require_current_sdk and ios_toolchain.version_tuple(sdk[1]) < ios_toolchain.version_tuple(ios_toolchain.MINIMUM_IOS_SDK):
        raise RuntimeError(f"Simulator application uses an older SDK: {binary}")
    return {"architectures": archs, "platform": platforms[0], "sdk": sdk[1]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xcode-export", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--engine-library", type=Path, required=True)
    parser.add_argument("--native-frameworks", type=Path, required=True)
    parser.add_argument("--pck", type=Path, help="Optional isolated QA PCK; record its provenance separately")
    parser.add_argument("--developer-dir", type=Path)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args(argv)
    if sys.platform != "darwin":
        parser.error("This local Simulator build requires macOS and Xcode")
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    source, work, library, native = [p.expanduser().resolve() for p in
                                   (args.xcode_export, args.work_dir, args.engine_library, args.native_frameworks)]
    if not work.is_relative_to(ROOT / "build"):
        parser.error("--work-dir must remain inside the GLory workspace build directory")
    if work == source or work.is_relative_to(source) or source.is_relative_to(work):
        parser.error("source export and output directory must not overlap")
    if not (source / f"{SCHEME}.xcodeproj/project.pbxproj").is_file():
        parser.error("--xcode-export must contain the canonical GloryIOS.xcodeproj")
    if not library.is_file():
        parser.error("--engine-library does not exist")
    pck = args.pck.expanduser().resolve() if args.pck else source / f"{SCHEME}.pck"
    if not pck.is_file():
        parser.error("PCK does not exist")
    child = dict(os.environ)
    if args.developer_dir:
        child["DEVELOPER_DIR"] = str(args.developer_dir.expanduser().resolve())
    elif not child.get("DEVELOPER_DIR"):
        child["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    toolchain = ios_toolchain.inspect_toolchain(child)
    simulator_sdk = read(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], child)
    if ios_toolchain.version_tuple(simulator_sdk) < ios_toolchain.version_tuple(ios_toolchain.MINIMUM_IOS_SDK):
        parser.error("Simulator SDK must be >= 27.1")
    if read(["xcrun", "lipo", "-archs", library], child).split() != ["arm64"]:
        parser.error("The dedicated QA engine library must be arm64 only")
    native_proof = {}
    for name in FRAMEWORKS:
        binary = native / f"{name}.framework" / name
        if not binary.is_file():
            parser.error(f"Missing Simulator framework: {binary}")
        native_proof[name] = simulator_binary(binary, child)
        native_proof[name]["sha256"] = sha(binary)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    run = work / "runs" / stamp
    run.mkdir(parents=True, exist_ok=False)
    export = run / "xcode"
    # APFS clone preserves the immutable original and avoids copying large PCKs.
    subprocess.run(["/bin/cp", "-cR", str(source), str(export)], check=True)
    xcframework = export / f"{SCHEME}.xcframework"
    metadata_path = xcframework / "Info.plist"
    metadata = plistlib.loads(metadata_path.read_bytes())
    entries = [v for v in metadata["AvailableLibraries"]
               if v.get("SupportedPlatform") == "ios" and v.get("SupportedPlatformVariant") == "simulator"]
    if len(entries) != 1:
        raise RuntimeError("Expected exactly one iOS Simulator engine XCFramework entry")
    entry = entries[0]
    entry["SupportedArchitectures"] = ["arm64"]
    shutil.copy2(library, xcframework / entry["LibraryIdentifier"] / entry["LibraryPath"])
    metadata_path.write_bytes(plistlib.dumps(metadata))
    framework_root = export / f"{SCHEME}/dylibs/addons/glory_voice/bin/ios"
    for name in FRAMEWORKS:
        target = framework_root / f"{name}.framework"
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(native / f"{name}.framework", target, symlinks=True)
    if args.pck:
        shutil.copy2(pck, export / f"{SCHEME}.pck")
    info_path = export / f"{SCHEME}/{SCHEME}-Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.update(CFBundleIdentifier=QA_BUNDLE, CFBundleDisplayName="GLory Duo QA",
                UIRequiresFullScreen=True, UIRequiresFullScreenIgnoredStartingWithVersion="27")
    info_path.write_bytes(plistlib.dumps(info))
    command = [
        "xcrun", "xcodebuild", "-project", export / f"{SCHEME}.xcodeproj", "-scheme", SCHEME,
        "-configuration", "Release", "-sdk", "iphonesimulator",
        "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", run / "DerivedData",
        "-jobs", str(args.jobs), "-hideShellScriptEnvironment",
        "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "SUPPORTED_PLATFORMS=iphonesimulator",
        "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=",
        "CODE_SIGN_ENTITLEMENTS=", "DEVELOPMENT_TEAM=", "PROVISIONING_PROFILE_SPECIFIER=",
        f"PRODUCT_BUNDLE_IDENTIFIER={QA_BUNDLE}", "build",
    ]
    receipt = {
        "qa_only": True, "uploaded": False, "installed": False,
        "source_xcode_export": str(source), "source_project_sha256": sha(source / f"{SCHEME}.xcodeproj/project.pbxproj"),
        "engine_library": str(library), "engine_sha256": sha(library),
        "native_frameworks": str(native), "native_proof": native_proof,
        "pck": str(pck), "pck_sha256": sha(pck), "pck_override": bool(args.pck),
        "toolchain": toolchain, "simulator_sdk": simulator_sdk,
        "bundle_identifier": QA_BUNDLE, "run_dir": str(run),
        "command": [str(v) for v in command],
    }
    (run / "inputs.json").write_text(json.dumps(receipt, indent=2) + "\n")
    log = run / "xcodebuild.log"
    print(f"[Simulator QA] Building; log: {log}", flush=True)
    with log.open("w") as stream:
        result = subprocess.run([str(v) for v in command], env=child,
                                stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"Simulator build failed ({result.returncode}); see {log}")
    app = run / f"DerivedData/Build/Products/Release-iphonesimulator/{SCHEME}.app"
    actual = plistlib.loads((app / "Info.plist").read_bytes())
    if actual.get("CFBundleIdentifier") != QA_BUNDLE or actual.get("UIRequiresFullScreenIgnoredStartingWithVersion") != "27":
        raise RuntimeError("Simulator app has incorrect QA bundle/window configuration")
    if "iPhoneSimulator" not in actual.get("CFBundleSupportedPlatforms", []):
        raise RuntimeError("Output is not a Simulator application")
    executable = app / actual["CFBundleExecutable"]
    receipt["binary"] = simulator_binary(executable, child, require_current_sdk=True)
    if receipt["binary"]["sdk"] != simulator_sdk:
        raise RuntimeError("Simulator app SDK does not match the selected SDK")
    if b"[GLORY_DUO] geometry=" not in executable.read_bytes():
        raise RuntimeError("Simulator app did not link the Duo engine implementation")
    # Local ad-hoc signing only; never uses the user's distribution identity.
    read(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", app], child)
    read(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], child)
    receipt.update(built=True, app=str(app), codesign="local-ad-hoc",
                   app_executable_sha256=sha(executable), xcodebuild_log=str(log),
                   sdk_name=actual.get("DTSDKName"), xcode_build=actual.get("DTXcodeBuild"))
    (run / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")
    (work / "latest-result.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"built": True, "app": str(app), "result": str(run / "result.json")}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f"[Simulator QA] Failed: {error}", file=sys.stderr)
        sys.exit(1)
