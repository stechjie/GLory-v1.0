#!/usr/bin/env python3
"""Check actual stdout from ClientLogService in a release engine, without game autoloads."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--godot', required=True)
parser.add_argument('--service', type=Path, required=True)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='glory-server-logging-') as directory:
    root = Path(directory)
    (root / ".godot").mkdir()
    (root / ".godot/global_script_class_cache.cfg").write_text("list=[]\n")
    (root / 'project.godot').write_text('config_version=5\n[application]\nrun/flush_stdout_on_print=true\n')
    (root / 'service.gd').write_bytes(args.service.read_bytes())
    (root / 'check.gd').write_text('''extends SceneTree
func _initialize():
	var service = load("res://service.gd").new()
	service.configure("res://disposable-client-log.txt")
	service.write("GLORY_SERVER_STDOUT_CHECK", true)
	service.write("GLORY_CLIENT_STDOUT_CHECK", false)
	print("LOGGING_CHECK_DEBUG=", OS.is_debug_build())
	quit(0)
''')
    result = subprocess.run([args.godot, '--headless', '--path', str(root), '--script', 'res://check.gd'],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=20)
print(result.stdout)
passed = (result.returncode == 0 and 'LOGGING_CHECK_DEBUG=false' in result.stdout
          and '[NET] GLORY_SERVER_STDOUT_CHECK' in result.stdout
          and 'GLORY_CLIENT_STDOUT_CHECK' not in result.stdout
          and 'ERROR:' not in result.stdout)
print('SERVER_RELEASE_LOGGING_PASS=' + str(passed))
raise SystemExit(0 if passed else 1)
