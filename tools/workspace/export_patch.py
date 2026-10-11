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


def run(engine, stage, args, log):
    with log.open("w", encoding="utf-8") as output:
        result = subprocess.run([str(engine), "--headless", "--path", str(stage), *map(str, args)],
                                stdout=output, stderr=subprocess.STDOUT)
    text = log.read_text(encoding="utf-8", errors="replace")
    if result.returncode or re.search(r"(?m)^(?:SCRIPT ERROR:|ERROR:)", text):
        raise RuntimeError(f"Godot export/import failed; inspect {log}")


def export(stage: Path, engine: Path, preset: str, platform: str, config: Path,
           output: Path, base: Path | None = None, executable: str | None = None):
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
    native = {str(path.relative_to(stage)): digest(path) for path in sorted(stage.rglob("*"))
              if path.is_file() and path.suffix.lower() in NATIVE_SUFFIXES}
    identity = {"engine_version": version, "platform": platform, "base_id": boot["base_id"],
                "preset_sha256": digest(stage / "export_presets.cfg"), "native_files": native}
    if base:
        record = json.loads(base.with_suffix(".export.json").read_text())
        if any(record.get(k) != v for k, v in identity.items()) or record.get("sha256") != digest(base):
            raise ValueError("Engine, native libraries, preset or original base changed; create a new base build")
    output.mkdir(parents=True)
    run(engine, stage, ["--editor", "--import"], output / "import.log")
    archive = output / ("current.zip" if base else "base.zip")
    run(engine, stage, ["--export-pack", preset, archive], output / "export.log")
    if not archive.is_file():
        raise RuntimeError("Godot did not produce the resource ZIP")
    identity.update(sha256=digest(archive), size=archive.stat().st_size)
    archive.with_suffix(".export.json").write_text(json.dumps(identity, indent=2) + "\n")
    if executable:
        # Filename only: keep all application output inside the new build directory.
        if Path(executable).name != executable:
            raise ValueError("--executable takes a filename, not a path")
        run(engine, stage, ["--export-release", preset, output / executable], output / "application.log")
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
    args = vars(parser.parse_args())
    args["engine"] = args.pop("godot")
    try:
        print(json.dumps(export(**args), ensure_ascii=False, indent=2))
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Export failed: {error}\n")


if __name__ == "__main__":
    main()
