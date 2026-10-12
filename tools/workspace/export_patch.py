#!/usr/bin/env python3
"""Export a platform base ZIP or cumulative patch from an isolated Godot stage.

Use the SAME staged source/preset as the Android, iOS or Windows base executable.
--executable additionally exports the full platform application with that preset.
An existing --base ZIP produces a cumulative patch; omit it to retain a new base.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

from glory_patch import build, NATIVE_SUFFIXES
from prepare_patch_base import from_config


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def native_inventory(stage: Path) -> dict[str, str]:
    """Hash shipped native inputs, excluding Godot's transient Android build tree.

    Retained Android export stages include Gradle dex/merged-library intermediates
    produced while building the APK. Fresh patch stages intentionally do not; those
    intermediates are not patchable client inputs and are reproducibly regenerated
    from the checked-in plugins/templates during a full application build.
    """
    return {str(path.relative_to(stage)): digest(path) for path in sorted(stage.rglob("*"))
            if path.is_file() and path.suffix.lower() in NATIVE_SUFFIXES
            and not path.relative_to(stage).as_posix().startswith("android/build/")}


def run(engine, stage, args, log, verify=None):
    with log.open("w", encoding="utf-8") as output:
        result = subprocess.run([str(engine), "--headless", "--path", str(stage), *map(str, args)],
                                stdout=output, stderr=subprocess.STDOUT)
    text = log.read_text(encoding="utf-8", errors="replace")
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    if result.returncode or re.search(r"(?m)^SCRIPT ERROR:", text):
        raise RuntimeError(f"Godot export/import failed; inspect {log}")
    if verify is not None:
        verify(text)
    elif re.search(r"(?m)^ERROR:", text):
        raise RuntimeError(f"Godot export/import failed; inspect {log}")


def verify_pack_export(text, output):
    """Accept only the known dummy-renderer shutdown leak after ZIP completion."""
    done = text.rfind("[ DONE ] savezip")
    if done < 0:
        raise RuntimeError(f"Godot did not confirm ZIP completion; inspect {output / 'export.log'}")
    accepted = []
    for match in re.finditer(r"(?m)^ERROR:.*$", text):
        if match.start() > done and re.fullmatch(
                r"ERROR: \d+ RID allocations of type 'N13RendererDummy15MaterialStorage11DummyShaderE' were leaked at exit\.", match[0]):
            accepted.append(match[0])
        else:
            raise RuntimeError(f"Godot ZIP export failed: {match[0]}")
    (output / "export-diagnostics.json").write_text(json.dumps({
        "export_completed": True, "host_shutdown_diagnostics": accepted}, indent=2) + "\n")


def export(stage: Path, engine: Path, preset: str, platform: str, config: Path,
           output: Path, base: Path | None = None, executable: str | None = None, debug: bool = False):
    stage, output = stage.resolve(), output.resolve()
    if (stage / ".git").exists() or output.is_relative_to(stage) or stage.is_relative_to(output):
        raise ValueError("Use isolated staging and an output directory outside the stage")
    if output.exists():
        raise ValueError("Output directory already exists; choose a new build destination")
    if base and executable:
        raise ValueError("--executable creates a new base; it cannot be combined with --base")
    presets = (stage / "export_presets.cfg").read_text(encoding="utf-8-sig")
    expected = {"android": "Android", "ios": "iOS", "windows": "Windows Desktop"}[platform]
    selected = None
    for body in re.findall(r"(?ms)^\[preset\.\d+\]\n(.*?)(?=^\[|\Z)", presets):
        if f'name="{preset}"' in body:
            selected = body
            break
    if selected is None or f'platform="{expected}"' not in selected:
        raise ValueError("Preset does not match the requested platform")
    boot_file = stage / "patcher/boot.json"
    if boot_file.exists():
        boot = json.loads(boot_file.read_text())
        settings = json.loads(config.read_text())
        if boot.get("platform") != platform or any(boot.get(k) != v for k, v in settings.items()):
            raise ValueError("Prepared stage differs from patch config")
    else:
        boot = from_config(stage, config, platform)
    version = subprocess.check_output([str(engine), "--version"], text=True).strip()
    native = native_inventory(stage)
    identity = {"engine_version": version, "platform": platform, "base_id": boot["base_id"], "debug": debug,
                "preset_sha256": digest(stage / "export_presets.cfg"), "native_files": native}
    if base:
        record = json.loads(base.with_suffix(".export.json").read_text())
        recorded = dict(record)
        # Older retained manifests were captured after Android application export,
        # so they include generated android/build intermediates. Normalize them to
        # the same shipped-input inventory used for current stages.
        recorded["native_files"] = {name: value for name, value in record.get("native_files", {}).items()
                                    if not name.startswith("android/build/")}
        if any(recorded.get(k) != v for k, v in identity.items()) or record.get("sha256") != digest(base):
            raise ValueError("Engine, native libraries, preset or original base changed; create a new base build")
    output.mkdir(parents=True)
    def verify_import(text):
        from glory_build import verify_model_materials, verify_import_diagnostics
        materials = verify_model_materials(engine, stage, output, dict(os.environ))
        diagnostics = verify_import_diagnostics(text, stage, output, materials)
        (output / "import-diagnostics.json").write_text(json.dumps(diagnostics, ensure_ascii=False, indent=2) + "\n")
    run(engine, stage, ["--editor", "--import"], output / "import.log", verify=verify_import)
    archive = output / ("current.zip" if base else "base.zip")
    # Godot 4.7 parses export-pack and export-debug as independent flags;
    # a single positional destination keeps pack-only output in debug mode.
    command = ["--export-pack", preset]
    if debug:
        command += ["--export-debug", preset]
    run(engine, stage, [*command, archive], output / "export.log",
        verify=lambda text: verify_pack_export(text, output))
    if not archive.is_file():
        raise RuntimeError("Godot did not produce the resource ZIP")
    identity.update(sha256=digest(archive), size=archive.stat().st_size)
    archive.with_suffix(".export.json").write_text(json.dumps(identity, indent=2) + "\n")
    if executable:
        # Filename only: keep all application output inside the new build directory.
        if Path(executable).name != executable:
            raise ValueError("--executable takes a filename, not a path")
        run(engine, stage, ["--export-debug" if debug else "--export-release", preset, output / executable], output / "application.log")
    if base:
        return build(base, archive, output / f"{platform}.zip", platform=platform, base_id=boot["base_id"])
    return identity


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("stage", "godot", "config", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--preset", required=True)
    parser.add_argument("--platform", choices=["android", "ios", "windows"], required=True)
    parser.add_argument("--base", type=Path)
    parser.add_argument("--executable", help="Also export full application, e.g. Glory.exe")
    parser.add_argument("--debug", action="store_true", help="Match a debug base application; cannot mix with release bases")
    args = vars(parser.parse_args())
    args["engine"] = args.pop("godot")
    try:
        print(json.dumps(export(**args), ensure_ascii=False, indent=2))
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Export failed: {error}\n")


if __name__ == "__main__":
    main()
