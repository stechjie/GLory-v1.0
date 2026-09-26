#!/usr/bin/env python3
"""Build the arm64 iOS LiveKit GDExtension using Xcode and pinned godot-cpp.

Requires scons in the invoking Python environment. Never accesses signing keys.
The generated framework and dependency frameworks are export inputs, not sources.
"""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).resolve().parent
CPP_COMMIT = "e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77"
SDK_VERSION = "2.17.0"


def run(args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)


def make_project(work, cpp, library):
    objects = {}

    def put(key, isa, **fields):
        uid = hashlib.sha256(key.encode()).hexdigest()[:24].upper()
        objects[uid] = dict(isa=isa, **fields)
        return uid

    files = []
    compile_files = []
    for name, kind in [("GloryVoiceNative.swift", "sourcecode.swift"), ("GloryVoiceBridge.mm", "sourcecode.cpp.objcpp")]:
        ref = put(name, "PBXFileReference", path=str(SOURCE / name), sourceTree="<absolute>", lastKnownFileType=kind)
        files.append(ref)
        compile_files.append(put(name+"-build", "PBXBuildFile", fileRef=ref))
    lib = put("cpp-library", "PBXFileReference", path=str(library), sourceTree="<absolute>", lastKnownFileType="archive.ar")
    files.append(lib)
    product = put("product", "PBXFileReference", path="GloryVoice.framework", sourceTree="BUILT_PRODUCTS_DIR", explicitFileType="wrapper.framework")
    products = put("products", "PBXGroup", children=[product], name="Products", sourceTree="<group>")
    group = put("group", "PBXGroup", children=files+[products], sourceTree="<group>")
    package = put("LiveKit-package", "XCRemoteSwiftPackageReference", repositoryURL="https://github.com/livekit/client-sdk-swift.git",
                  requirement={"kind":"exactVersion", "version":SDK_VERSION})
    dependency = put("LiveKit-product", "XCSwiftPackageProductDependency", package=package, productName="LiveKit")
    linked = [put("cpp-link", "PBXBuildFile", fileRef=lib), put("LiveKit-link", "PBXBuildFile", productRef=dependency)]
    phases = [put("sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=compile_files, runOnlyForDeploymentPostprocessing=0),
              put("frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=linked, runOnlyForDeploymentPostprocessing=0),
              put("resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)]
    settings = {
        "PRODUCT_NAME":"GloryVoice", "PRODUCT_BUNDLE_IDENTIFIER":"com.superforge.glory.voice",
        "SDKROOT":"iphoneos", "SUPPORTED_PLATFORMS":"iphoneos", "IPHONEOS_DEPLOYMENT_TARGET":"15.0",
        "TARGETED_DEVICE_FAMILY":"1,2", "ARCHS":"arm64", "ONLY_ACTIVE_ARCH":"NO",
        "MACH_O_TYPE":"mh_dylib", "DEFINES_MODULE":"YES", "SKIP_INSTALL":"NO",
        "DYLIB_INSTALL_NAME_BASE":"@rpath",
        "CODE_SIGNING_ALLOWED":"NO", "GENERATE_INFOPLIST_FILE":"YES",
        "CURRENT_PROJECT_VERSION":"1", "MARKETING_VERSION":"1.0",
        "SWIFT_VERSION":"5.0", "SWIFT_INSTALL_OBJC_HEADER":"YES",
        "CLANG_CXX_LANGUAGE_STANDARD":"c++17", "CLANG_ENABLE_MODULES":"YES", "CLANG_ENABLE_OBJC_ARC":"YES",
        "GCC_SYMBOLS_PRIVATE_EXTERN":"YES", "GCC_INLINES_ARE_PRIVATE_EXTERN":"YES",
        "HEADER_SEARCH_PATHS":[str(cpp/"include"),str(cpp/"gen/include"),str(cpp/"gdextension")],
        "LIBRARY_SEARCH_PATHS":["$(inherited)",str(library.parent)],
        "GCC_PREPROCESSOR_DEFINITIONS":["$(inherited)","NDEBUG", "TYPED_METHOD_BIND"],
        "LD_RUNPATH_SEARCH_PATHS":["$(inherited)","@executable_path/Frameworks", "@loader_path/Frameworks"],
    }
    configs = []
    root_configs = []
    for name in ["Debug","Release"]:
        configs.append(put("target-"+name, "XCBuildConfiguration", name=name, buildSettings=settings))
        root_configs.append(put("project-"+name, "XCBuildConfiguration", name=name, buildSettings={}))
    config_list = put("target-configs", "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    root_list = put("project-configs", "XCConfigurationList", buildConfigurations=root_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    target = put("target", "PBXNativeTarget", name="GloryVoice", productName="GloryVoice", productType="com.apple.product-type.framework",
                 productReference=product, buildConfigurationList=config_list, buildPhases=phases, buildRules=[], dependencies=[], packageProductDependencies=[dependency])
    project = put("project", "PBXProject", attributes={"LastUpgradeCheck":"2660"}, buildConfigurationList=root_list,
                  compatibilityVersion="Xcode 14.0", developmentRegion="en", knownRegions=["en","Base"], mainGroup=group,
                  productRefGroup=products, projectDirPath="", projectRoot="", targets=[target], packageReferences=[package])
    bundle = work/"GloryVoice.xcodeproj"
    bundle.mkdir(exist_ok=True)
    (bundle/"project.pbxproj").write_bytes(plistlib.dumps({"archiveVersion":"1","classes":{},"objectVersion":"56", "objects":objects,"rootObject":project}))
    return bundle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, required=True)
    args = parser.parse_args()
    work = args.work_dir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    cpp = work/"godot-cpp"
    if not cpp.exists():
        run(["git","clone","--depth","1","--branch","godot-4.5-stable","https://github.com/godotengine/godot-cpp.git",cpp])
    revision = subprocess.check_output(["git","-C",str(cpp),"rev-parse","HEAD"],text=True).strip()
    if revision != CPP_COMMIT:
        raise RuntimeError("godot-cpp source revision mismatch")
    (cpp/"voice_profile.json").write_text(json.dumps({"enabled_classes":["Object","Engine","OS"]}))
    run([sys.executable,"-m","SCons","platform=ios","arch=arm64","target=template_release",
         "ios_min_version=15.0","build_profile=voice_profile.json","-j6"],cwd=cpp)
    libraries = list((cpp/"bin").glob("*.a"))
    if len(libraries) != 1:
        raise RuntimeError("Expected one arm64 godot-cpp static library")
    project = make_project(work, cpp, libraries[0])
    run(["xcodebuild","-project",project,"-scheme","GloryVoice","-configuration","Release",
         "-sdk","iphoneos","-destination","generic/platform=iOS","-derivedDataPath",work/"DerivedData",
         "CODE_SIGNING_ALLOWED=NO","build"])
    products = work/"DerivedData/Build/Products/Release-iphoneos"
    out = ROOT/"addons/glory_voice/bin/ios"
    out.mkdir(parents=True,exist_ok=True)
    # Replace only generated framework inputs after a successful build.
    frameworks = [products/"GloryVoice.framework"]
    for dependency in ["LiveKitWebRTC.framework", "RustLiveKitUniFFI.framework"]:
        device = []
        for bundle in (work/"DerivedData/SourcePackages/artifacts").rglob(dependency.replace(".framework", ".xcframework")):
            info = plistlib.loads((bundle/"Info.plist").read_bytes())
            for entry in info["AvailableLibraries"]:
                if entry["SupportedPlatform"] == "ios" and not entry.get("SupportedPlatformVariant"):
                    device.append(bundle/entry["LibraryIdentifier"]/entry["LibraryPath"])
        if len(device) != 1:
            raise RuntimeError("Cannot identify device framework: "+dependency)
        frameworks.append(device[0])
    for framework in frameworks:
        target = out/framework.name
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(framework,target)
    for resource in products.glob("LiveKit*.bundle"):
        shutil.copytree(resource,out/"GloryVoice.framework"/resource.name,dirs_exist_ok=True)
    manifest = {"godot_cpp":revision,"livekit":SDK_VERSION,"architecture":"arm64", "files":{}}
    for file in sorted(out.rglob("*")):
        if file.is_file() and file != out/"build-manifest.json":
            manifest["files"][str(file.relative_to(out))]=hashlib.sha256(file.read_bytes()).hexdigest()
    for file in [SOURCE/"GloryVoiceNative.swift",SOURCE/"GloryVoiceNative.h",SOURCE/"GloryVoiceBridge.mm",Path(__file__)]:
        manifest.setdefault("source",{})[file.name]=hashlib.sha256(file.read_bytes()).hexdigest()
    (out/"build-manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
    print("iOS voice framework ready:",out)

if __name__ == "__main__":
    main()
