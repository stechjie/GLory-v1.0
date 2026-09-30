#!/usr/bin/env python3
"""Exercise real encrypted ENet; fail on unexpected errors, not merely failed assertions."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile


def inspect_log(text):
    case = "startup"
    unexpected = []
    expected = []
    drops = []
    handshake_diagnostics = []
    for line in text.splitlines():
        if line.startswith("CASE_START "):
            case = line[len("CASE_START "):]
        if "DTLS_HANDSHAKE_FAILURE remote=" in line:
            handshake_diagnostics.append({"case": case, "line": line})
        if "DTLS_ADMISSION_DROP " in line:
            drops.append({"case": case, "line": line})
        if "ERROR:" in line or "SCRIPT ERROR" in line:
            entry = {"case": case, "line": line}
            # Only the deliberate wrong-pin case may raise crypto errors.
            if case == "wrong_cert_rejected" and "TLS handshake error:" in line:
                expected.append(entry)
            else:
                unexpected.append(entry)
        if line.startswith("CASE_END "):
            case = "between_cases"
    result = re.search(r"RESULT checks=(\d+) failures=(\d+)", text)
    return {"checks": int(result[1]) if result else 0,
            "failures": int(result[2]) if result else None,
            "unexpected_errors": unexpected, "expected_tls_errors": expected,
            "admission_drops": drops, "handshake_diagnostics": handshake_diagnostics,
            "passed": bool(result and int(result[1]) >= 78 and int(result[2]) == 0 and not unexpected
                           and expected and drops and handshake_diagnostics)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="glory-dtls-test-") as directory:
        project = Path(directory)
        (project / ".godot").mkdir()
        (project / ".godot/global_script_class_cache.cfg").write_text("list=[]\n")
        (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="GloryTlsRegression"\nrun/flush_stdout_on_print=true\n')
        (project / "check.gd").write_bytes(Path(__file__).with_name("dtls_lifecycle.gd").read_bytes())
        result = subprocess.run([args.godot, "--headless", "--path", str(project), "--script", "res://check.gd"],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
    (args.out / "lifecycle.log").write_text(result.stdout)
    report = inspect_log(result.stdout)
    report["exit_code"] = result.returncode
    report["passed"] = report["passed"] and result.returncode == 0
    (args.out / "result.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
