#!/usr/bin/env python3
"""Compile production iOS bridge sources for local Simulator QA (never an IPA)."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

PROJECT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--godot-cpp", type=Path, required=True)
    args = parser.parse_args()
    work = args.work_dir.resolve()
    cpp = args.godot_cpp.resolve()
    library = cpp / "bin/libgodot-cpp.ios.template_release.arm64.simulator.a"
    if not library.is_file():
        raise RuntimeError("Build godot-cpp for ios_simulator=yes, arm64 first.")
    work.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location("glory_native_builder", PROJECT / "native/glory_voice_ios/build.py")
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    revision = subprocess.check_output(["git", "-C", str(cpp), "rev-parse", "HEAD"], text=True).strip()
    if revision != native.CPP_COMMIT:
        raise RuntimeError("Pinned godot-cpp revision mismatch.")
    project = native.make_project(work, cpp, library)
    pbx = project / "project.pbxproj"
    data = plistlib.loads(pbx.read_bytes())
    for obj in data["objects"].values():
        settings = obj.get("buildSettings", {})
        if settings.get("PRODUCT_NAME") == "GloryVoice":
            settings["SDKROOT"] = "iphonesimulator"
            settings["SUPPORTED_PLATFORMS"] = "iphonesimulator"
    pbx.write_bytes(plistlib.dumps(data))
    subprocess.run([
        "xcodebuild", "-project", str(project), "-scheme", "GloryVoice",
        "-configuration", "Release", "-sdk", "iphonesimulator",
        "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", str(work / "DerivedData"),
        "CODE_SIGNING_ALLOWED=NO", "build",
    ], check=True)
    products = work / "DerivedData/Build/Products/Release-iphonesimulator"
    out = work / "frameworks"
    out.mkdir(exist_ok=True)
    frameworks = [products / "GloryVoice.framework"]
    for name in ["LiveKitWebRTC.framework", "RustLiveKitUniFFI.framework"]:
        found = []
        for bundle in (work / "DerivedData/SourcePackages/artifacts").rglob(name.replace(".framework", ".xcframework")):
            info = plistlib.loads((bundle / "Info.plist").read_bytes())
            for entry in info["AvailableLibraries"]:
                if entry.get("SupportedPlatform") == "ios" and entry.get("SupportedPlatformVariant") == "simulator" and "arm64" in entry["SupportedArchitectures"]:
                    found.append(bundle / entry["LibraryIdentifier"] / entry["LibraryPath"])
        if len(found) != 1:
            raise RuntimeError("Cannot uniquely identify simulator dependency: " + name)
        frameworks.append(found[0])
    for framework in frameworks:
        target = out / framework.name
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(framework, target)
    for bundle in products.glob("*.bundle"):
        shutil.copytree(bundle, out / "GloryVoice.framework" / bundle.name, dirs_exist_ok=True)
    source = PROJECT / "native/glory_voice_ios"
    manifest = {
        "purpose": "local Simulator QA; no production plugin replacement",
        "source_project": str(PROJECT),
        "godot_cpp": revision,
        "platform": "iphonesimulator",
        "sdk": subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True).strip(),
        "source_hashes": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(source.iterdir()) if p.suffix in (".swift", ".mm", ".h")},
        "frameworks": str(out),
    }
    (work / "native-simulator-result.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
