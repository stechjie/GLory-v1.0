#!/usr/bin/env python3
"""Install the immutable update gate in an isolated export staging directory.

Run BEFORE Godot import/export, never against the source checkout. Retain the
resulting platform ZIP as the immutable baseline for glory_patch.py.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shutil
from urllib.parse import urlsplit


def from_config(stage: Path, config_file: Path, platform: str):
    settings = json.loads(config_file.read_text(encoding="utf-8"))
    required = {"base_id", "channel", "backend_url", "firebase_host"}
    if not isinstance(settings, dict) or set(settings) != required:
        raise ValueError("Patch config must contain only base_id, channel, backend_url and firebase_host")
    return prepare(stage, platform=platform, **settings)


def prepare(stage: Path, *, base_id: str, platform: str, channel: str,
            backend_url: str, firebase_host: str) -> dict:
    stage = stage.resolve()
    source = Path(__file__).resolve().parents[2]
    if stage == source or (stage / ".git").exists():
        raise ValueError("Use an isolated staging copy, never a Git checkout")
    if platform not in {"android", "ios", "windows"}:
        raise ValueError("Unsupported platform")
    if not all(re.fullmatch(r"[A-Za-z0-9_-]{1,96}", item) for item in (base_id, channel)):
        raise ValueError("Invalid base/channel identifier")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*\.(web\.app|firebaseapp\.com)", firebase_host):
        raise ValueError("Use an exact Firebase Hosting hostname")
    url = urlsplit(backend_url)
    if (url.scheme != "https" or not url.hostname or url.username or url.password
            or url.query or url.fragment or url.path not in ("", "/")):
        raise ValueError("Backend must be an HTTPS origin")
    project = stage / "project.godot"
    text = project.read_text(encoding="utf-8-sig")
    section = re.search(r"(?ms)^\[autoload\]\s*\n(.*?)(?=^\[|\Z)", text)
    main = re.search(r'^run/main_scene="(res://[^"\n]+)"$', text, re.M)
    if not section or not main:
        raise ValueError("Missing autoloads or explicit resource main_scene")
    if main[1] == "res://patcher/UpdateGate.tscn":
        raise ValueError("Stage is already prepared; start from a fresh staging copy")
    entries, lines = [], []
    for line in section[1].splitlines():
        if not line.strip() or line.lstrip().startswith(";"):
            lines.append(line)
            continue
        entry = re.fullmatch(r'([A-Za-z_][A-Za-z0-9_]*)="\*(res://[^"\n]+\.gd)"', line)
        if not entry:
            raise ValueError("Only globally named script autoloads are supported")
        path = (stage / entry[2].removeprefix("res://")).resolve()
        if not path.is_relative_to(stage) or not path.is_file():
            raise ValueError(f"Missing staged autoload: {entry[1]}")
        if not re.search(r"(?m)^extends\s+Node\s*(?:#.*)?$", path.read_text(encoding="utf-8-sig")):
            raise ValueError(f"Autoload must extend Node: {entry[1]}")
        entries.append({"name": entry[1], "path": entry[2]})
        lines.append(f'{entry[1]}="*res://patcher/AutoloadPlaceholder.tscn"')
    boot = {"protocol": 1, "base_id": base_id, "platform": platform, "channel": channel,
            "backend_url": backend_url.rstrip("/"), "firebase_host": firebase_host,
            "main_scene": main[1], "autoloads": entries}
    text = text[:section.start(1)] + "\n".join(lines) + "\n\n" + text[section.end(1):]
    text = re.sub(r'^run/main_scene="[^"\n]+"$', 'run/main_scene="res://patcher/UpdateGate.tscn"', text, flags=re.M)
    patcher = stage / "patcher"
    patcher.mkdir(exist_ok=True)
    for name in ("UpdateGate.gd", "UpdateGate.tscn", "AutoloadPlaceholder.tscn",
                 "HotfixContext.gd", "HotfixRuntime.gd", "HotfixAgent.gd"):
        shutil.copy2(source / "patcher" / name, patcher / name)
    # The launcher must render before the normal font singleton starts.
    shutil.copy2(stage / "ui/fonts/NotoSansSC-Regular.otf", patcher / "LauncherFont.otf")
    shutil.copy2(stage / "ui/fonts/NotoSansSC-OFL.txt", patcher / "LauncherFont-LICENSE.txt")
    (patcher / "boot.json").write_text(json.dumps(boot, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    presets = stage / "export_presets.cfg"
    preset_text = presets.read_text(encoding="utf-8-sig")
    # boot.json is non-resource data; each platform preset must include it.
    def include(match):
        values = list(dict.fromkeys(filter(None, match[1].split(",") + ["patcher/boot.json", "patcher/*LICENSE.txt"])))
        return 'include_filter="' + ",".join(values) + '"'
    preset_text, count = re.subn(r'^include_filter="([^"\n]*)"$', include, preset_text, flags=re.M)
    if not count:
        raise ValueError("Export presets must have explicit include_filter entries")
    presets.write_text(preset_text, encoding="utf-8")
    project.write_text(text, encoding="utf-8")
    return boot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", type=Path, required=True)
    for key in ("base-id", "platform", "channel", "backend-url", "firebase-host"):
        parser.add_argument("--" + key, required=True)
    args = vars(parser.parse_args())
    try:
        result = prepare(**args)
    except (ValueError, OSError) as error:
        parser.exit(1, f"Base preparation failed: {error}\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
