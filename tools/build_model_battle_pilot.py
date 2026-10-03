#!/usr/bin/env python3
"""Stage/import/export the real offline BattleScreen in its own Android package.

The production checkout is read-only. Runtime source/resource directories are
copied into a marked output, with a complete hash inventory. Only generated
project/export/main-scene settings differ. --import-only prepares the large
resource cache without exporting; --build exports after a fresh source snapshot.
No installation, networking, microphone access, or official app changes occur.
"""
from __future__ import annotations
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile
import build_model_refinement_pilot as common
from workspace import glory_build as production_build

PACKAGE = "com.glory.modelbattlepilot"
MARKER = ".model-battle-pilot-generated.json"
CAPTURE = "tools/model_battle_pilot_capture.gd"
MAIN = "tools/generated_model_battle_main.tscn"
METADATA = "model_battle_build_info.json"
PRESET = "Model Battle Pilot"
APK = "ModelBattlePilot.apk"
ROOTS = ("assets", "data", "database", "effects", "scenes", "scripts", "shaders", "ui",
         "addons", "android_plugins", "officetest", "tools")
ROOT_FILES = ("project.godot", "icon.svg", "icon.svg.import", "default_bus_layout.tres",
              "assets.bundle.json", "assets.manifest.json")
SKIP_DIRS = {".git", ".godot", "__pycache__", ".svn", "node_modules", ".venv", "venv"}
SKIP_FILES = {".DS_Store", "Thumbs.db", "desktop.ini"}
# These optional native bridges/experimental previews are not referenced by the
# production BattleScreen fixture. Keep their source copies, but do not import
# or package unsupported Android libraries in this offline visual-only build.
IMPORT_EXCLUSIONS = {
    "addons/effekseer": "Optional experimental VFX bridge has no Android native library",
    "addons/glory_voice": "Offline model validation disables voice and recording",
    "effects/vfx3d/experimental/undead_from_scratch_v3": "Experimental Effekseer preview only",
    "scenes/debug": "Debug preview scenes are not the real BattleScreen entry point",
}
EXPORT_EXCLUSIONS = {
    # Same exact vendor-demo exclusion as workspace/glory_build.py; all other
    # Binbun resources remain available to the actual BattleScreen effects.
    "effects/vfx3d/vfxv2/binbun_reference/assets/BinbunVFX_Vol2/BattleFX/battle_fx_scene_free.tscn":
        "Unreferenced vendor demo points to the undelivered shield_02 scene",
}


def note(message: str) -> None:
    print("[MODEL-BATTLE-BUILD] " + message, flush=True)


def inventory(source: Path) -> list[str]:
    paths = {name for name in ROOT_FILES if (source / name).is_file()}
    for name in ROOTS:
        folder = source / name
        if not folder.is_dir():
            continue
        for base, dirs, files in os.walk(folder, followlinks=False):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not (Path(base) / d).is_symlink())
            for filename in sorted(files):
                path = Path(base) / filename
                if filename in SKIP_FILES or filename.startswith(".env") or path.suffix in {".jks", ".keystore", ".p12", ".pem", ".key", ".pyc"}:
                    continue
                if path.is_symlink() and not path.resolve().is_relative_to(source):
                    raise RuntimeError(f"Runtime resource symlink escapes checkout: {path}")
                if path.is_file():
                    paths.add(path.relative_to(source).as_posix())
    if CAPTURE not in paths:
        raise RuntimeError("Missing model_battle_pilot_capture.gd")
    return sorted(paths)


def validate_output(source: Path, out: Path) -> None:
    if source == out or source.is_relative_to(out) or out.is_relative_to(source):
        raise RuntimeError("Output must be outside and not above the source checkout.")
    marker = out / MARKER
    if out.exists() and any(out.iterdir()) and not marker.is_file():
        raise RuntimeError("Refusing a nonempty, unmarked output directory.")
    if marker.is_file() and json.loads(marker.read_text()).get("package") != PACKAGE:
        raise RuntimeError("Output belongs to another package.")


def config_value(text: str, section: str, key: str, value: str) -> str:
    match = re.search(r"(?m)^\[" + re.escape(section) + r"\]\s*$", text)
    if not match:
        return text.rstrip() + f"\n\n[{section}]\n{key}={value}\n"
    end_match = re.search(r"(?m)^\[", text[match.end():])
    end = match.end() + end_match.start() if end_match else len(text)
    body = text[match.end():end]
    pattern = r"(?m)^" + re.escape(key) + r"\s*=.*$"
    line = key + "=" + value
    if re.search(pattern, body):
        body = re.sub(pattern, lambda _: line, body)
    else:
        body = body.rstrip() + "\n" + line + "\n\n"
    return text[:match.end()] + body + text[end:]


def stage(source: Path, out: Path, paths: list[str], env: dict, expected: str) -> Path:
    validate_output(source, out)
    out.mkdir(parents=True, exist_ok=True)
    common.json_write(out / MARKER, {"package": PACKAGE, "source": str(source)})
    target = out / "project"
    if target.is_symlink():
        raise RuntimeError("Generated project directory must not be a symlink.")
    target.mkdir(exist_ok=True)
    prior = out / "source-manifest.json"
    if prior.is_file():
        for row in json.loads(prior.read_text()).get("files", []):
            if row["path"] not in paths:
                stale = target / row["path"]
                if stale.is_file() and stale.resolve().is_relative_to(target.resolve()):
                    stale.unlink()
    rows = []
    for index, relative in enumerate(paths):
        original = common.checked_resource(source, relative)
        dest = target / relative
        if not dest.resolve().is_relative_to(target.resolve()):
            raise RuntimeError(f"Unsafe staged destination: {relative}")
        digest = common.sha256(original)
        dest.parent.mkdir(parents=True, exist_ok=True)
        if not dest.is_file() or dest.stat().st_size != original.stat().st_size or common.sha256(dest) != digest:
            shutil.copy2(original, dest)
        if common.sha256(dest) != digest:
            raise RuntimeError(f"Source changed while staging {relative}; rerun after locking inputs.")
        rows.append({"path": relative, "bytes": dest.stat().st_size, "sha256": digest})
        if index and index % 1000 == 0:
            note(f"Inventoried/copied {index}/{len(paths)} files")
    for relative in IMPORT_EXCLUSIONS:
        ignored = target / relative / ".gdignore"
        ignored.parent.mkdir(parents=True, exist_ok=True)
        ignored.write_text("# Generated for the isolated offline model battle pilot only.\n")
    # This generated cache may still list a now-ignored extension from a prior
    # import. Godot rebuilds it while scanning; source addon files stay intact.
    (target / ".godot/extension_list.cfg").unlink(missing_ok=True)
    config = (source / "project.godot").read_text(encoding="utf-8-sig")
    settings = [("application", "config/name", '"GLory Model Battle Pilot"'),
                ("application", "run/main_scene", json.dumps("res://" + MAIN)),
                ("application", "config/use_custom_user_dir", "true"),
                ("application", "config/custom_user_dir_name", '"GLoryModelBattlePilot"'),
                ("display", "window/handheld/orientation", "0"),
                ("rendering", "renderer/rendering_method", '"gl_compatibility"'),
                ("rendering", "renderer/rendering_method.mobile", '"gl_compatibility"'),
                ("debug", "file_logging/enable_file_logging", "true"),
                ("debug", "file_logging/log_path", '"user://logs/model_battle_pilot.log"'),
                ("debug", "file_logging/max_log_files", "3"),
                ("editor_plugins", "enabled", "PackedStringArray()")]
    for section, key, value in settings:
        config = config_value(config, section, key, value)
    (target / "project.godot").write_text(config, encoding="utf-8")
    (target / MAIN).write_text('[gd_scene load_steps=2 format=3]\n\n[ext_resource type="Script" path="res://' + CAPTURE + '" id="1"]\n\n[node name="ModelBattleCapture" type="Node"]\nscript = ExtResource("1")\n')
    preset = f'''[preset.0]
name="{PRESET}"
platform="Android"
runnable=true
export_filter="all_resources"
include_filter="*.json,*.csv,*.txt"
exclude_filter="tools/**/*.py,tools/**/*.sh,tools/**/__pycache__/**,tools/**/*.zip,tools/**/*.apk,addons/effekseer/**,addons/glory_voice/**,effects/vfx3d/experimental/undead_from_scratch_v3/**,scenes/debug/**,{','.join(EXPORT_EXCLUSIONS)}"
export_path="../{APK}"

[preset.0.options]
custom_template/debug={json.dumps(str(env['templates'] / 'android_debug.apk'))}
gradle_build/use_gradle_build=false
architectures/armeabi-v7a=false
architectures/arm64-v8a=true
architectures/x86=false
architectures/x86_64=false
version/code=1
version/name="0.1-model-battle-pilot"
package/unique_name="{PACKAGE}"
package/name="Model Battle Pilot"
package/signed=true
permissions/internet=false
permissions/record_audio=false
screen/immersive_mode=true
'''
    (target / "export_presets.cfg").write_text(preset)
    generated = [{"path": name, "sha256": common.sha256(target / name)}
                 for name in ("project.godot", "export_presets.cfg", MAIN, *(folder + "/.gdignore" for folder in IMPORT_EXCLUSIONS))]
    fingerprint = hashlib.sha256(json.dumps({"files": rows, "generated": generated,
                                             "expected_model": expected}, sort_keys=True).encode()).hexdigest()
    manifest = {"schema_version": 1, "package": PACKAGE, "scene": "res://" + MAIN,
                "godot": env["version"], "renderer": "gl_compatibility", "expected_model": expected,
                "source_fingerprint": fingerprint, "created_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
                "source_project": str(source), "files": rows, "generated": generated, "import_and_export_exclusions": IMPORT_EXCLUSIONS,
                "export_only_exclusions": EXPORT_EXCLUSIONS,
                "scope": "isolated offline Android package using actual FixedBattleFixture, BattleSimulator, BattleScreen, and production actor model resolution",
                "runtime_permissions": {"internet": False, "record_audio": False}}
    common.json_write(prior, manifest)
    common.json_write(target / METADATA, manifest)
    note(f"Staged {len(rows)} runtime source/resource files, {sum(r['bytes'] for r in rows)/1048576:.1f} MiB; expected={expected}")
    return target


def prepare_runtime(stage_path: Path, out: Path, env: dict) -> tuple[Path, dict]:
    engine = common.portable_engine(env, out)
    child_env = dict(os.environ, JAVA_HOME=str(env["java"]), ANDROID_HOME=str(env["sdk"]))
    log_path = out / "import.log"
    if log_path.exists():
        archived = out / ("import-before-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S") + ".log")
        shutil.copy2(log_path, archived)
    raw = production_build.logged_process([engine, "--headless", "--path", stage_path, "--editor", "--import"], log_path, child_env, strict=False)
    materials = production_build.verify_model_materials(engine, stage_path, out, child_env)
    diagnostics = production_build.verify_import_diagnostics(raw, stage_path, out, materials)
    common.json_write(out / "import-report.json", {"status": "passed", "source_fingerprint": json.loads((out / "source-manifest.json").read_text())["source_fingerprint"],
        "material_audit_summary": materials.get("summary", {}) if materials else {}, "import_diagnostics": diagnostics, "exported": False})
    return engine, child_env


def export(stage_path: Path, out: Path, env: dict, engine: Path, child_env: dict) -> None:
    pending = out / "ModelBattlePilot.pending.apk"
    pending.unlink(missing_ok=True)
    if (out / "export.log").exists():
        shutil.copy2(out / "export.log", out / ("export-before-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S") + ".log"))
    log = common.run_logged([str(engine), "--headless", "--path", str(stage_path), "--export-debug", PRESET, str(pending)], out / "export.log", child_env)
    if not pending.is_file() or "[ DONE ] export" not in log:
        raise RuntimeError("Fresh APK export did not complete.")
    badging = subprocess.check_output([str(env["build_tools"] / "aapt"), "dump", "badging", str(pending)], text=True)
    permissions = subprocess.check_output([str(env["build_tools"] / "aapt"), "dump", "permissions", str(pending)], text=True)
    if f"package: name='{PACKAGE}'" not in badging or "android.permission.INTERNET" in permissions or "android.permission.RECORD_AUDIO" in permissions:
        raise RuntimeError("APK identity/permission isolation failed.")
    expected = json.loads((stage_path / METADATA).read_text())
    with zipfile.ZipFile(pending) as archive:
        embedded = json.loads(archive.read("assets/" + METADATA))
    if embedded != expected:
        raise RuntimeError("Embedded source manifest differs from staged inputs.")
    final = out / APK
    pending.replace(final)
    common.json_write(out / "apk-report.json", {"package": PACKAGE, "apk": str(final), "sha256": common.sha256(final),
        "bytes": final.stat().st_size, "source_fingerprint": expected["source_fingerprint"], "export_verified": True,
        "permissions": permissions, "installed": False, "device_tested": False, "scope": expected["scope"]})
    note(f"Verified {final}; no installation performed.")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--expected-model", required=True, help="Exact production god_guard model res:// path to verify")
    p.add_argument("--godot"); p.add_argument("--templates"); p.add_argument("--android-sdk"); p.add_argument("--java-home")
    p.add_argument("--debug-keystore", type=Path, help="Reuse only this pilot's previous debug key")
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true"); mode.add_argument("--import-only", action="store_true"); mode.add_argument("--build", action="store_true")
    args = p.parse_args(); source=args.project.expanduser().resolve(); out=args.out.expanduser().resolve()
    if not (source / "project.godot").is_file(): raise RuntimeError("Source is not a Godot project.")
    common.checked_resource(source, args.expected_model)
    expected = "res://" + args.expected_model.removeprefix("res://")
    validate_output(source, out); env=common.tool_environment(args); paths=inventory(source)
    note(f"Read-only inventory: {len(paths)} files; {env['version']}; package={PACKAGE}")
    if args.check: return
    generated=stage(source,out,paths,env,expected)
    if args.import_only or args.build:
        engine,child_env=prepare_runtime(generated,out,env)
        if args.build: export(generated,out,env,engine,child_env)

if __name__ == "__main__":
    try: main()
    except (RuntimeError,OSError,ValueError,subprocess.CalledProcessError,zipfile.BadZipFile) as exc:
        print("[MODEL-BATTLE-BUILD] FAIL: "+str(exc),file=sys.stderr);sys.exit(1)
