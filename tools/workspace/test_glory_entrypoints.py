"""Exercise launchers from unrelated directories without the outer tools symlink."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parent


class EntryPointTests(unittest.TestCase):
    def test_commands_forward_arguments_and_exit_status_without_waiting(self):
        commands = {
            '同步资源.command': ('sync_res.sh', []),
            '同步并打包APK.command': ('build_apk.sh', ['--sync']),
            '同步并打包IPA.command': ('build_ipa.sh', ['--update']),
            '同步并打包TestFlight.command': ('release_testflight.sh', []),
        }
        with tempfile.TemporaryDirectory(prefix='glory entrypoints ') as tmp:
            root = Path(tmp)
            tools = root / 'GLory-v1.0/tools/workspace'
            tools.mkdir(parents=True)
            for name, (child, defaults) in commands.items():
                with self.subTest(name=name):
                    shutil.copy2(TOOLS / name, tools / name)
                    stub = tools / child
                    stub.write_text('#!/bin/bash\nprintf "%s\\n" "$@"\nexit 7\n')
                    stub.chmod(0o755)
                    result = subprocess.run(['bash', str(tools / name), '--check', '--project', 'path with spaces'],
                                            input='', text=True, capture_output=True, cwd='/', timeout=5)
                    self.assertEqual(result.returncode, 7, result.stderr)
                    self.assertEqual(result.stdout.splitlines(), defaults + ['--check', '--project', 'path with spaces'])

    def test_shell_launchers_find_sibling_python_without_outer_symlink(self):
        with tempfile.TemporaryDirectory(prefix='glory launchers ') as tmp:
            tools = Path(tmp) / 'GLory-v1.0/tools/workspace'
            tools.mkdir(parents=True)
            for script, entry in [('build_apk.sh', 'glory_build.py'), ('build_ipa.sh', 'glory_ios_build.py'),
                                  ('release_testflight.sh', 'glory_testflight.py')]:
                with self.subTest(script=script):
                    shutil.copy2(TOOLS / script, tools / script)
                    (tools / entry).write_text('import sys,json; print(json.dumps(sys.argv[1:]))\n')
                    result = subprocess.run(['bash', str(tools / script), '--help'], cwd='/', text=True,
                                            capture_output=True, env=dict(os.environ, PYTHON3=sys.executable), timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout), ['--help'])


if __name__ == '__main__':
    unittest.main()
