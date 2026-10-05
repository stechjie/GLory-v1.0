#!/usr/bin/env python3
"""Stage/export the offline model refinement preview under a separate Android package.

Default: copy only the preview's explicit resource closure and write a manifest.
--build additionally imports and exports; this tool never installs or launches.
No source project settings, installed game, release keystore, or user saves are
changed. Performance in this isolated scene is not whole-game performance.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import struct
import sys
import zipfile
from urllib.parse import unquote, urlsplit


PACKAGE = "com.glory.modelpilot"
PREVIEW = "scenes/debug/ModelRefinementPreview.tscn"
DEFAULT_OLD_MODEL = "res://assets/models/units/god_guard_crystalbound/god_guard_crystalbound_animated.tscn"
DEFAULT_NEW_MODEL = "res://assets/models/units/god_guard_refined/god_guard_refined.tscn"
IDENTITY_KEYS = ("unit_id", "old_model_path", "new_model_path")
CORE: tuple[str, ...] = ()
MAX_RESOURCES = 2048
MAX_SOURCE_BYTES = 2 * 1024 * 1024 * 1024
TEXT_TYPES = {".gd", ".tscn", ".tres", ".gdshader", ".gdshaderinc", ".shader", ".import"}
RESOURCE_LITERAL = re.compile(r'''["'](res://[^"'\r\n]+)["']''')
GENERATED_MARKER = ".model-refinement-pilot-generated.json"
ERROR_LINE = re.compile(r"(?m)^(?:SCRIPT ERROR:|ERROR:)|Parse Error:|Failed to (?:load|import)")


def sha256(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def json_write(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def note(message: str) -> None:
    print(f"[MODEL-PILOT] {message}", flush=True)


def checked_resource(source: Path, relative: str) -> Path:
    source = source.resolve()
    relative = relative.removeprefix("res://")
    parts = PurePosixPath(relative).parts
    if not parts or ".." in parts or PurePosixPath(relative).is_absolute() or "\\" in relative:
        raise RuntimeError(f"Unsafe resource path: {relative}")
    path = source / relative
    if not path.resolve().is_relative_to(source) or not path.is_file():
        raise RuntimeError(f"Missing/out-of-project resource: res://{relative}")
    return path


def resource_closure(source: Path, seeds: list[str]) -> list[str]:
    """Follow literal file references only, never copy a resource directory.

    Dynamically constructed paths must be supplied with --resource or made into
    full res:// literals in the preview. Import sidecars preserve texture options
    but their old .godot cache references are deliberately not followed.
    """
    pending = [item.removeprefix("res://") for item in seeds]
    seen: set[str] = set()
    while pending:
        relative = pending.pop()
        if relative in seen:
            continue
        path = checked_resource(source, relative)
        seen.add(relative)
        if len(seen) > MAX_RESOURCES:
            raise RuntimeError(f"Preview closure exceeds {MAX_RESOURCES} files; inspect unexpected dependencies.")
        for suffix in (".uid", ".import"):
            sidecar = source / (relative + suffix)
            if sidecar.is_file():
                pending.append(relative + suffix)
        if path.suffix.lower() == ".blend":
            raise RuntimeError("Export Blender authoring files to self-contained GLB before packaging the pilot.")
        if path.suffix.lower() in {".gltf", ".glb"}:
            if path.suffix.lower() == ".gltf":
                gltf = json.loads(path.read_text(encoding="utf-8-sig"))
            else:
                with path.open("rb") as stream:
                    header = stream.read(20)
                    if len(header) != 20:
                        raise RuntimeError(f"Invalid GLB header: {relative}")
                    magic, version, total, json_bytes, chunk_type = struct.unpack("<5I", header)
                    if (magic != 0x46546C67 or version != 2 or total != path.stat().st_size
                            or chunk_type != 0x4E4F534A or not 0 < json_bytes <= total - 20):
                        raise RuntimeError(f"Invalid GLB JSON chunk: {relative}")
                    gltf = json.loads(stream.read(json_bytes).decode("utf-8"))
            for entry in [*gltf.get("buffers", []), *gltf.get("images", [])]:
                uri = entry.get("uri", "")
                if not uri or uri.startswith("data:"):
                    continue
                parsed = urlsplit(uri)
                if parsed.scheme or parsed.netloc or parsed.query or parsed.fragment:
                    raise RuntimeError(f"Only local glTF dependencies are permitted: {uri}")
                decoded = unquote(parsed.path)
                if Path(decoded).is_absolute() or "\\" in decoded:
                    raise RuntimeError(f"Unsafe glTF URI: {uri}")
                target = (path.parent / decoded).resolve()
                if not target.is_relative_to(source.resolve()) or not target.is_file():
                    raise RuntimeError(f"Missing/out-of-project glTF dependency: {uri}")
                pending.append(target.relative_to(source.resolve()).as_posix())
        if path.suffix not in TEXT_TYPES:
            continue
        text = path.read_text(encoding="utf-8-sig")
        for ref in RESOURCE_LITERAL.findall(text):
            # Directory constants do not authorize copying a whole library.
            if ref.endswith("/"):
                continue
            # Neither do format templates; the paths they build reach the pilot
            # only through --old-model/--new-model/--resource.
            if "%" in ref:
                continue
            # Import remaps point to generated cache files. External override
            # materials/animation libraries in the same sidecar are real inputs.
            if path.suffix == ".import" and ref.startswith("res://.godot/"):
                continue
            pending.append(ref.removeprefix("res://"))
    if sum((source / item).stat().st_size for item in seen) > MAX_SOURCE_BYTES:
        raise RuntimeError("Preview source closure exceeds 2 GiB; inspect dependencies first.")
    return sorted(seen)


def discover_executable(choices: list[object]) -> Path | None:
    for choice in choices:
        if not choice:
            continue
        path = Path(shutil.which(str(choice)) or str(choice)).expanduser()
        if path.suffix == ".app":
            path /= "Contents/MacOS/Godot"
        if path.is_file() and os.access(path, os.X_OK):
            return path.resolve()
    return None


def discover_directory(choices: list[object], required: str) -> Path:
    for choice in choices:
        if choice:
            path = Path(str(choice)).expanduser()
            if (path / required).exists():
                return path.resolve()
    raise RuntimeError(f"No directory containing {required}; pass the corresponding tool-path option.")


def tool_environment(args: argparse.Namespace) -> dict:
    engine = discover_executable([
        args.godot, os.environ.get("GODOT_BIN"), "godot", "godot4",
        "/Applications/Godot.app", Path.home() / "Applications/Godot.app",
        "/Volumes/repository/glory-ios-dev/tools/godot/Godot.app",
    ])
    if engine is None:
        raise RuntimeError("Godot 4.7 not found; pass --godot.")
    version = subprocess.check_output([str(engine), "--version"], text=True).strip().splitlines()[-1]
    match = re.fullmatch(r"(4\.7)(?:\.(\d+))?\.([^.]+)\..+", version)
    if not match:
        raise RuntimeError(f"Expected project-compatible Godot 4.7; found {version}.")
    template_version = match[1] + (f".{match[2]}" if match[2] else "") + f".{match[3]}"
    templates = discover_directory([
        args.templates, os.environ.get("GODOT_TEMPLATES"),
        Path.home() / "Library/Application Support/Godot/export_templates" / template_version,
        Path.home() / ".local/share/godot/export_templates" / template_version,
        Path(os.environ.get("APPDATA", "")) / "Godot/export_templates" / template_version,
    ], "android_debug.apk")
    sdk = discover_directory([
        args.android_sdk, os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"),
        Path.home() / "Library/Android/sdk", "/opt/homebrew/share/android-commandlinetools",
        Path.home() / "Android/Sdk", Path(os.environ.get("LOCALAPPDATA", "")) / "Android/Sdk",
    ], "build-tools")
    java = discover_directory([
        args.java_home, os.environ.get("JAVA_HOME"),
        "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home",
        "/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home",
        "/usr/lib/jvm/java-17-openjdk-amd64",
    ], "bin/java.exe" if os.name == "nt" else "bin/java")
    suffix = ".exe" if os.name == "nt" else ""
    versions = sorted((sdk / "build-tools").iterdir(),
                      key=lambda p: tuple(int(v) for v in re.findall(r"\d+", p.name)), reverse=True)
    build_tools = next((p for p in versions if (p / f"aapt{suffix}").is_file()), None)
    if build_tools is None:
        raise RuntimeError("Android build-tools must include aapt for package verification.")
    pilot_key = args.debug_keystore.expanduser().resolve() if args.debug_keystore else None
    if pilot_key is not None and not pilot_key.is_file():
        raise RuntimeError(f"Pilot debug keystore does not exist: {pilot_key}")
    return {"engine": engine, "version": version, "template_version": template_version,
            "templates": templates, "sdk": sdk, "java": java, "build_tools": build_tools,
            "debug_keystore": pilot_key}


def validate_output(source: Path, output: Path) -> None:
    if output == source or output.is_relative_to(source) or source.is_relative_to(output):
        raise RuntimeError("Output must be outside, and not a parent of, the source project.")
    if os.name == "nt" and not str(output).isascii():
        raise RuntimeError("On Windows the output path must be ASCII-only; Java keytool rejects it otherwise.")
    if output.exists() and any(output.iterdir()) and not (output / GENERATED_MARKER).is_file():
        raise RuntimeError(f"Refusing to reuse unmarked nonempty output directory: {output}")
    marker = output / GENERATED_MARKER
    if marker.is_file() and json.loads(marker.read_text(encoding="utf-8")).get("package") != PACKAGE:
        raise RuntimeError("Output marker belongs to a different package.")


def source_fingerprint(rows: list[dict], identity: dict) -> str:
    return hashlib.sha256(json.dumps({"files": rows, "identity": {key: identity[key] for key in IDENTITY_KEYS}}, sort_keys=True).encode()).hexdigest()


def resolve_identity(args: argparse.Namespace, source: Path) -> tuple[str, dict]:
    # Exact race_units.json id; some are capitalised (crimson "Icey").
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,63}", args.unit_id):
        raise RuntimeError("--unit-id must be an exact unit identifier (letters, digits, underscore).")
    if args.unit_id != "god_guard" and (not args.preview or args.preview.removeprefix("res://") == PREVIEW or not args.old_model or not args.new_model):
        raise RuntimeError("A non-god_guard target requires its own explicit --preview, --old-model and --new-model; the default guardian preview cannot prove another character.")
    preview = (args.preview or PREVIEW).removeprefix("res://")
    if not preview.endswith(".tscn"):
        raise RuntimeError("--preview must be an explicit .tscn scene.")
    identity = {"unit_id": args.unit_id,
                "old_model_path": "res://" + (args.old_model or DEFAULT_OLD_MODEL).removeprefix("res://"),
                "new_model_path": "res://" + (args.new_model or DEFAULT_NEW_MODEL).removeprefix("res://")}
    if identity["old_model_path"] == identity["new_model_path"]:
        raise RuntimeError("Old and new model paths must be distinct for an A/B refinement test.")
    checked_resource(source, preview)
    for key in ("old_model_path", "new_model_path"):
        checked_resource(source, identity[key])
    return preview, identity


def stage_project(source: Path, output: Path, resources: list[str], env: dict,
                  preview: str, extra_resources: list[str], identity: dict) -> Path:
    validate_output(source, output)
    output.mkdir(parents=True, exist_ok=True)
    json_write(output / GENERATED_MARKER, {"package": PACKAGE, "source": str(source)})
    stage = output / "project"
    if stage.is_symlink():
        raise RuntimeError("Generated project directory must not be a symlink.")
    stage.mkdir(exist_ok=True)
    # This tiny standalone project may receive .gd.uid files after an earlier
    # preview import. Godot can otherwise retain the earlier generated UID in
    # its export cache, producing mismatched resource IDs in a fresh APK.
    # Only this marked, generated project's cache is disposable.
    if (stage / ".godot").exists():
        shutil.rmtree(stage / ".godot")
    previous = output / "source-manifest.json"
    if previous.is_file():
        for item in json.loads(previous.read_text(encoding="utf-8")).get("files", []):
            relative = item["path"]
            if relative not in resources:
                stale = stage / relative
                if stale.resolve().is_relative_to(stage.resolve()) and stale.is_file():
                    stale.unlink()
    rows = []
    for relative in resources:
        original = checked_resource(source, relative)
        target = stage / relative
        if not target.resolve().is_relative_to(stage.resolve()):
            raise RuntimeError(f"Staged resource escapes generated project: {relative}")
        target.parent.mkdir(parents=True, exist_ok=True)
        digest = sha256(original)
        if not target.is_file() or sha256(target) != digest:
            shutil.copy2(original, target)
        rows.append({"path": relative, "bytes": original.stat().st_size, "sha256": digest})
    fingerprint = source_fingerprint(rows, identity)
    manifest = {
        "package": PACKAGE, "godot": env["version"], "scene": f"res://{preview}", **identity,
        "resource_seeds": [preview, identity["old_model_path"], identity["new_model_path"], *extra_resources],
        "renderer": "gl_compatibility", "source_fingerprint": fingerprint,
        "created_utc": dt.datetime.now(dt.timezone.utc).isoformat(), "files": rows,
        "scope": "offline real-model A/B preview; not a full-game performance test",
    }
    json_write(previous, manifest)
    json_write(stage / "model_build_info.json", manifest)
    (stage / "pilot_icon.svg").write_text('''<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128"><rect width="128" height="128" rx="24" fill="#172822"/><path d="M64 17 104 34v29c0 25-19 41-40 50-21-9-40-25-40-50V34Z" fill="#e6efeb" stroke="#c4b77c" stroke-width="5"/><path d="m64 38 7 20 21 7-21 7-7 20-7-20-21-7 21-7Z" fill="#516e61"/></svg>''', encoding="utf-8")
    (stage / "project.godot").write_text(f'''config_version=5

[application]
config/name="GLory Model Refinement Pilot"
config/icon="res://pilot_icon.svg"
run/main_scene="res://{preview}"
config/features=PackedStringArray("4.7", "GL Compatibility")
config/use_custom_user_dir=true
config/custom_user_dir_name="GLoryModelRefinementPilot"

[display]
window/size/viewport_width=1600
window/size/viewport_height=720
window/size/window_width_override=1280
window/size/window_height_override=576
window/stretch/mode="canvas_items"
window/handheld/orientation=0
window/vsync/vsync_mode=1

[debug]
file_logging/enable_file_logging=true
file_logging/log_path="user://logs/model_pilot.log"
file_logging/max_log_files=3

[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
textures/vram_compression/import_etc2_astc=true
textures/default_filters/use_nearest_mipmap_filter=false
''', encoding="utf-8")
    # Export only the preview closure. No networking, microphone or release key.
    preset = f'''[preset.0]
name="Model Refinement Pilot"
platform="Android"
runnable=true
export_filter="all_resources"
include_filter="model_build_info.json"
exclude_filter="tools/_pilot_material_audit.*,tools/CheckHarness.gd*,reports/**"
export_path="../ModelRefinementPilot.apk"

[preset.0.options]
custom_template/debug={json.dumps(str(env["templates"] / "android_debug.apk"))}
gradle_build/use_gradle_build=false
architectures/armeabi-v7a=false
architectures/arm64-v8a=true
architectures/x86=false
architectures/x86_64=false
version/code=1
version/name="0.1-pilot"
package/unique_name="{PACKAGE}"
package/name="Model Refinement Pilot"
package/signed=true
permissions/internet=false
permissions/record_audio=false
screen/immersive_mode=true
'''
    (stage / "export_presets.cfg").write_text(preset, encoding="utf-8")
    note(f"Staged {len(rows)} files / {sum(r['bytes'] for r in rows) / 1048576:.1f} MiB; "
         f"package={PACKAGE}; fingerprint={fingerprint}")
    return stage


def portable_engine(env: dict, output: Path) -> Path:
    folder = output / "runtime"
    folder.mkdir(exist_ok=True)
    original = env["engine"]
    if sys.platform == "darwin" and original.parent.name == "MacOS" and original.parents[2].suffix == ".app":
        app = folder / "Godot.app"
        shutil.copytree(original.parents[2], app, dirs_exist_ok=True, symlinks=True)
        engine = app / "Contents/MacOS" / original.name
    else:
        engine = folder / original.name
        shutil.copy2(original, engine)
        # Windows *_console.exe only launches the sibling GUI executable.
        if original.name.endswith("_console.exe"):
            main = original.with_name(original.name.removesuffix("_console.exe") + ".exe")
            shutil.copy2(main, folder / main.name)
    (folder / "_sc_").touch()
    editor_data = folder / "editor_data"
    editor_data.mkdir(exist_ok=True)
    keystore = folder / "pilot-debug.keystore"
    supplied_key = env.get("debug_keystore")
    if supplied_key is not None and supplied_key != keystore.resolve():
        if keystore.exists() and sha256(keystore) != sha256(supplied_key):
            raise RuntimeError("Generated output already has a different pilot key; use a new output directory.")
        shutil.copy2(supplied_key, keystore)
        keystore.chmod(0o600)
    if not keystore.is_file():
        keytool = env["java"] / "bin" / ("keytool.exe" if os.name == "nt" else "keytool")
        subprocess.run([str(keytool), "-genkeypair", "-keystore", str(keystore),
                        "-storepass", "android", "-alias", "androiddebugkey", "-keypass", "android",
                        "-dname", "CN=Model Refinement Pilot,O=Local Development,C=US",
                        "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        keystore.chmod(0o600)
    values = {
        "export/android/java_sdk_path": str(env["java"]),
        "export/android/android_sdk_path": str(env["sdk"]),
        "export/android/debug_keystore": str(keystore),
        "export/android/debug_keystore_user": "androiddebugkey",
        "export/android/debug_keystore_pass": "android",
    }
    settings = '[gd_resource type="EditorSettings" format=3]\n\n[resource]\n'
    settings += "\n".join(f"{k} = {json.dumps(v)}" for k, v in values.items()) + "\n"
    (editor_data / "editor_settings-4.7.tres").write_text(settings, encoding="utf-8")
    return engine


def run_logged(command: list[str], path: Path, env: dict[str, str]) -> str:
    note(f"Running {path.stem}; log={path}")
    with path.open("w", encoding="utf-8") as stream:
        result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, env=env)
    content = path.read_text(encoding="utf-8", errors="replace")
    # Godot progress headings contain terminal colors even when redirected.
    content = re.sub(r"\x1b\[[0-9;]*m", "", content)
    if result.returncode or ERROR_LINE.search(content):
        raise RuntimeError(f"{path.stem} failed (rc={result.returncode}); inspect {path}")
    return content


def audit_import_diagnostics(content: str, source: Path, stage: Path, output: Path,
                             engine: Path, child_env: dict[str, str]) -> None:
    """Apply the production material audit to every model wrapper in this closure.

    Only exact unused FBX source-image diagnostics may be accepted, and only
    after all final materials/textures and every resident action model pass.
    The generated audit helpers are excluded from the Android package.
    """
    from workspace import glory_build as production
    checker = source / "tools/model_material_integrity_check.gd"
    harness = source / "tools/CheckHarness.gd"
    whitelist = source / "data/qa/intentional_untextured_materials.json"
    manifest = json.loads((output / "source-manifest.json").read_text(encoding="utf-8"))
    model_paths = ["res://" + row["path"] for row in manifest["files"]
                   if row["path"].startswith("assets/models/") and row["path"].endswith(".tscn")]
    if not model_paths or not all(path.is_file() for path in (checker, harness, whitelist)):
        raise RuntimeError("FBX source diagnostics require the production material audit and real model wrappers.")
    code = checker.read_text(encoding="utf-8-sig")
    code = re.sub(r'^const UnitVisualResolverScript :=.*\n', '', code, flags=re.M)
    start = code.find('\tvar entries := UnitVisualResolverScript.all_combat_entries()')
    end = code.find('\t_check_stale_whitelist_entries()', start)
    if start < 0 or end < 0:
        raise RuntimeError("Production material audit structure changed; review the subset adapter.")
    # The original stale-whitelist check concerns the entire roster. This
    # explicitly scoped subset may legitimately leave other entries unused.
    code = code[:start] + '\tfor model_path in ' + json.dumps(model_paths) + ':\n\t\tawait _audit_model("pilot", "unit", model_path)\n\n' + code[end + len('\t_check_stale_whitelist_entries()\n'):]
    (stage / "tools").mkdir(exist_ok=True)
    shutil.copy2(harness, stage / "tools/CheckHarness.gd")
    target_whitelist = stage / "data/qa/intentional_untextured_materials.json"
    target_whitelist.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(whitelist, target_whitelist)
    (stage / "tools/_pilot_material_audit.gd").write_text(code, encoding="utf-8")
    (stage / "tools/_pilot_material_audit.tscn").write_text('[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://tools/_pilot_material_audit.gd" id="1"]\n[node name="PilotMaterialAudit" type="Node"]\nscript = ExtResource("1")\n')
    run_logged([str(engine), "--headless", "--path", str(stage), "res://tools/_pilot_material_audit.tscn"],
               output / "model-materials.log", child_env)
    report = json.loads((stage / "reports/model_material_integrity.json").read_text(encoding="utf-8"))
    summary = report["summary"]
    if summary.get("models") != len(model_paths) or any(summary.get(key) for key in
            ("scene_load_failed", "material_missing", "missing_texture", "white_material_suspect")):
        raise RuntimeError("Pilot final model material audit failed; inspect model-materials.log.")
    audit_log = (output / "model-materials.log").read_text(encoding="utf-8", errors="replace")
    if "CHECK_RESULT name=model_material_integrity status=PASS" not in audit_log:
        raise RuntimeError("Pilot material audit has no successful completion marker.")
    shutil.copy2(stage / "reports/model_material_integrity.json", output / "model-materials.json")
    production.verify_import_diagnostics(content, stage, output, report)
    json_write(output / "material-audit-provenance.json", {"scope":"every model wrapper in the isolated dependency closure", "model_paths":model_paths,
        "production_checker_sha256":sha256(checker), "harness_sha256":sha256(harness), "whitelist_sha256":sha256(whitelist),
        "generated_audit_sha256":sha256(stage / "tools/_pilot_material_audit.gd"), "summary":summary})


def build(stage: Path, output: Path, env: dict) -> None:
    engine = portable_engine(env, output)
    child_env = os.environ.copy()
    child_env["JAVA_HOME"] = str(env["java"])
    child_env["ANDROID_HOME"] = str(env["sdk"])
    command = [str(engine), "--headless", "--path", str(stage)]
    import_log = output / "import.log"
    if import_log.exists():
        shutil.copy2(import_log, output / ("import-before-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S") + ".log"))
    with import_log.open("w", encoding="utf-8") as stream:
        imported = subprocess.run(command + ["--editor", "--import"], stdout=stream, stderr=subprocess.STDOUT, env=child_env)
    content = re.sub(r"\x1b\[[0-9;]*m", "", import_log.read_text(encoding="utf-8", errors="replace"))
    if imported.returncode:
        raise RuntimeError(f"Import process failed (rc={imported.returncode}); inspect {import_log}")
    if ERROR_LINE.search(content):
        source = Path(json.loads((output / GENERATED_MARKER).read_text(encoding="utf-8"))["source"])
        audit_import_diagnostics(content, source, stage, output, engine, child_env)
    # Always export to a new temporary name; a stale APK cannot pass this build.
    apk = output / "ModelRefinementPilot.pending.apk"
    if apk.exists():
        apk.unlink()
    log = run_logged(command + ["--export-debug", "Model Refinement Pilot", str(apk)],
                     output / "export.log", child_env)
    if not apk.is_file() or "[ DONE ] export" not in log:
        raise RuntimeError("Export did not confirm completion with a new APK.")
    aapt = env["build_tools"] / ("aapt.exe" if os.name == "nt" else "aapt")
    badging = subprocess.check_output([str(aapt), "dump", "badging", str(apk)], text=True)
    if f"package: name='{PACKAGE}'" not in badging:
        raise RuntimeError("Unexpected Android package identity; APK must not be installed.")
    with zipfile.ZipFile(apk) as archive:
        embedded = json.loads(archive.read("assets/model_build_info.json"))
    expected = json.loads((stage / "model_build_info.json").read_text(encoding="utf-8"))
    if embedded != expected:
        raise RuntimeError("APK embedded identity does not match the staged sources.")
    final = output / "ModelRefinementPilot.apk"
    apk.replace(final)
    json_write(output / "apk-report.json", {
        "apk": str(final), "package": PACKAGE, "sha256": sha256(final),
        "bytes": final.stat().st_size, "source_fingerprint": expected["source_fingerprint"],
        "export_verified": True, "installed": False, "device_tested": False,
        "scope": expected["scope"],
    })
    note(f"Verified APK: {final}; not installed or launched.")


def main() -> None:
    # Windows consoles/pipes default to cp1252; paths (…/桌面/…) and audit notes are Chinese.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--out", type=Path, help="Generated directory outside source (must be empty/marked)")
    parser.add_argument("--preview", help="Preview scene path; default is the god_guard-specific preview")
    parser.add_argument("--unit-id", default="god_guard", help="Exact intended unit; custom units require their own preview and model paths")
    parser.add_argument("--old-model", help="Original res:// model path; defaults to the original guardian")
    parser.add_argument("--new-model", help="Candidate res:// model path; defaults to the refined guardian")
    parser.add_argument("--resource", action="append", default=[], help="Additional explicit res:// file")
    parser.add_argument("--godot", help="Godot 4.7 executable or app bundle")
    parser.add_argument("--templates", help="Matching Godot export template directory")
    parser.add_argument("--android-sdk", help="Android SDK directory")
    parser.add_argument("--java-home", help="JDK directory")
    parser.add_argument("--debug-keystore", type=Path,
                        help="Reuse a previous pilot's runtime/pilot-debug.keystore so adb install -r preserves pilot data; never use a release key")
    parser.add_argument("--check", action="store_true", help="Read-only environment and dependency check")
    parser.add_argument("--build", action="store_true", help="Import/export after staging; never installs")
    args = parser.parse_args()
    source = args.project.expanduser().resolve()
    if not (source / "project.godot").is_file():
        raise RuntimeError(f"Not a Godot source project: {source}")
    output = (args.out or source.parent / "delivery/model-refinement-pilot/android").expanduser().resolve()
    validate_output(source, output)
    env = tool_environment(args)
    preview, identity = resolve_identity(args, source)
    resources = resource_closure(source, [preview, identity["old_model_path"], identity["new_model_path"], *CORE, *args.resource])
    note(f"Godot={env['version']}; closure={len(resources)} files; renderer=gl_compatibility")
    if args.check:
        note("Read-only check passed; no staging/import/export/install performed.")
        return
    stage = stage_project(source, output, resources, env, preview, args.resource, identity)
    if args.build:
        build(stage, output, env)
    else:
        note("Prepared only. Use --build for import/export once the preview is reviewed.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError, zipfile.BadZipFile) as exc:
        print(f"[MODEL-PILOT] FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
