#!/usr/bin/env python3
"""Run source-only server logic checks inside a caller-isolated network container.

Run the entire script in Docker --network=none. The temporary project omits only
the client font autoload; dedicated startup is tested separately on the unmodified
bundle. Never pass --server/--dedicated-server to these self-hosting test scenes.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("bundle", args.source / "tools/make_server_bundle.py")
    bundle = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bundle)
    args.out.mkdir(parents=True, exist_ok=True)
    cases = [("handshake_" + case, "handshake_check", ["--", "--hs-case=" + case])
             for case in ("ok", "bad", "contract", "silent")]
    cases += [(case, case + "_check", []) for case in (
        "reconnect", "reconnect_backoff", "reconnect_service", "room_service",
        "seat_identity", "client_log", "melee_navigation", "battle_reach_target",
        "bug0930", "determinism")]
    results = []
    with tempfile.TemporaryDirectory(prefix="glory-engine-game-checks-") as directory:
        root = Path(directory)
        project = root / "project"
        files = bundle.selected_files(args.source)
        # This upstream regression uses a pure simulation fixture intentionally
        # omitted from production server bundles. Include its class in tests only.
        files["officetest/OfficeTestSim.gd"] = (args.source / "officetest/OfficeTestSim.gd").read_bytes()
        cache, _ = bundle.fresh_class_cache(files)
        files[".godot/global_script_class_cache.cfg"] = cache
        settings = bundle.server_project(files["project.godot"]).decode()
        settings = re.sub(r"(?m)^UIFontFallback=.*\n", "", settings)
        settings = bundle.project_setting(settings, "application", "config/use_custom_user_dir", "true")
        settings = bundle.project_setting(settings, "application", "config/custom_user_dir_name", '"GloryEngineGameChecks"')
        files["project.godot"] = settings.encode()
        for name, data in files.items():
            target = project / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        environment = dict(os.environ, XDG_DATA_HOME=str(root / "userdata"))
        for name, scene, tail in cases:
            command = [str(args.godot.resolve()), "--headless", "--path", str(project),
                       "res://tools/" + scene + ".tscn"] + tail
            timed_out = False
            log_path = args.out / (name + ".log")
            try:
                with log_path.open("w") as output:
                    process = subprocess.run(command, env=environment, stdout=output,
                                             stderr=subprocess.STDOUT, timeout=900 if name == "determinism" else 90)
                code = process.returncode
            except subprocess.TimeoutExpired:
                code, timed_out = None, True
            log = log_path.read_text(errors="replace")
            errors = [line for line in log.splitlines() if "ERROR:" in line or "SCRIPT ERROR" in line]
            summaries = [line for line in log.splitlines()
                         if any(token in line for token in ("CHECK_RESULT", "[HS]", "PROBE RESULT"))]
            passed = code == 0 and not errors and bool(summaries) and all(
                "status=PASS" in line or " PASS " in line or "ALL PASS" in line for line in summaries)
            result = dict(case=name, exit_code=code, timeout=timed_out, passed=passed,
                          errors=errors, summaries=summaries)
            results.append(result)
            print(json.dumps(result), flush=True)
            (args.out / "results.json").write_text(json.dumps(results, indent=2))
    return 0 if len(results) == len(cases) and all(row["passed"] for row in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
