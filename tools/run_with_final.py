"""Sync final status Excel-owned numbers, validate, then start Godot.

Examples:
  python tools/run_with_final.py --godot C:/Tools/Godot.exe
  python tools/run_with_final.py --editor --godot C:/Tools/Godot.exe
GODOT_BIN or a godot executable on PATH can also select the engine.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
EXPORTER = ROOT / "tools/export_final_status.py"


def godot_executable(requested):
    candidate = requested or os.environ.get("GODOT_BIN") or shutil.which("godot") or shutil.which("godot4")
    if not candidate:
        raise ValueError("Godot not found. Pass --godot PATH or set GODOT_BIN.")
    resolved = shutil.which(candidate) or candidate
    path = Path(resolved)
    if not path.is_file():
        raise ValueError(f"Godot executable does not exist: {candidate}")
    return str(path)


def main():
    parser = argparse.ArgumentParser(description="Sync final status and start Godot")
    parser.add_argument("--godot", help="Path to Godot executable; otherwise use GODOT_BIN or PATH")
    parser.add_argument("--editor", action="store_true", help="Open the editor after synchronization")
    parser.add_argument("godot_args", nargs=argparse.REMAINDER, help="Additional Godot arguments after --")
    args = parser.parse_args()
    try:
        godot = godot_executable(args.godot)
    except ValueError as exc:
        parser.exit(2, str(exc) + "\n")
    for mode in ("--apply-runtime", "--check"):
        result = subprocess.run([sys.executable, str(EXPORTER), mode], cwd=ROOT)
        if result.returncode:
            raise SystemExit(result.returncode)
    extra = args.godot_args[1:] if args.godot_args[:1] == ["--"] else args.godot_args
    command = [godot, "--path", str(ROOT)]
    if args.editor:
        command.append("--editor")
    command.extend(extra)
    print("Starting Godot with validated final status", flush=True)
    raise SystemExit(subprocess.run(command, cwd=ROOT).returncode)


if __name__ == "__main__":
    main()
