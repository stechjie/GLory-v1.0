#!/usr/bin/env python3
"""Run reproducible encrypted battle-load tests in a Linux network namespace.

Example (root/CAP_SYS_ADMIN required):
  python3 tools/run_capacity_lab.py --archive server.zip --godot /opt/godot \
    --font-dir /opt/glory-qa-font --out /tmp/capacity20 --rooms 20 --waves 5

The font directory contains qa-font.otf, its original .import file and
qa-font.fontdata. Production services, network, credentials and user data are
never used. The immutable server archive and test harness hashes are recorded.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile

sys.dont_write_bytecode = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--godot', type=Path, required=True)
    parser.add_argument('--font-dir', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--rooms', type=int, default=20)
    parser.add_argument('--waves', type=int, default=5)
    parser.add_argument('--peers', type=int)
    args = parser.parse_args()
    peers = args.peers or args.rooms * 4
    if sys.platform != 'linux' or not 1 <= args.rooms <= 128 or not args.rooms * 4 <= peers <= 512 or not 1 <= args.waves <= 100:
        parser.error('Linux, 1..128 rooms, four peers per room, at most 512 peers, and 1..100 waves required')
    if args.out.exists():
        parser.error('Output directory already exists; preserve previous evidence by choosing a fresh path')
    args.out.mkdir(parents=True)
    args.out = args.out.resolve()
    harness = Path(__file__).resolve().parent
    names = ['run_capacity_lab.py', 'server_capacity_peer.gd', 'server_capacity_split_check.gd', 'server_capacity_split_check.tscn', 'server_capacity_processes.py']
    report = {'rooms': args.rooms, 'peers': peers, 'waves': args.waves,
              'archive_sha256': hashlib.sha256(args.archive.read_bytes()).hexdigest(),
              'harness_sha256': {name: hashlib.sha256((harness / name).read_bytes()).hexdigest() for name in names},
              'network': 'private Linux namespace; loopback only', 'passed': False}
    user_dirs = []
    started = time.monotonic()
    try:
        with tempfile.TemporaryDirectory(prefix='glory-capacity-lab-') as temporary:
            root = Path(temporary)
            project = root / 'server'
            with zipfile.ZipFile(args.archive) as archive:
                for name in archive.namelist():
                    path = Path(name)
                    if path.is_absolute() or '..' in path.parts:
                        raise ValueError('Unsafe archive path')
                manifest = json.loads(archive.read('server_bundle_manifest.json'))
                for row in manifest['files']:
                    if hashlib.sha256(archive.read(row['path'])).hexdigest() != row['sha256']:
                        raise ValueError('Archive manifest mismatch: ' + row['path'])
                archive.extractall(project)
            report['source_tree_sha256'] = manifest['source_tree_sha256']
            for name in names:
                shutil.copyfile(harness / name, project / 'tools' / name)
            module_spec = importlib.util.spec_from_file_location('bundle', project / 'tools/make_server_bundle.py')
            bundle = importlib.util.module_from_spec(module_spec)
            module_spec.loader.exec_module(bundle)
            font = project / 'ui/fonts/NotoSansSC-Regular.otf'
            font.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(args.font_dir / 'qa-font.otf', font)
            font_import = args.font_dir / 'NotoSansSC-Regular.otf.import'
            shutil.copyfile(font_import, str(font) + '.import')
            font_path = re.search(r'^path="res://(.+\.fontdata)"', font_import.read_text(), re.M)
            if not font_path:
                raise ValueError('Font import does not name its artifact')
            imported = project / font_path[1]
            imported.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(args.font_dir / 'qa-font.fontdata', imported)
            client = root / 'clients'
            shutil.copytree(project, client)
            for target in (project, client):
                tag = 'GloryLinuxStabilityQA-' + uuid.uuid4().hex
                settings = (target / 'project.godot').read_text()
                settings = bundle.project_setting(settings, 'application', 'config/use_custom_user_dir', 'true')
                settings = bundle.project_setting(settings, 'application', 'config/custom_user_dir_name', json.dumps(tag))
                (target / 'project.godot').write_text(settings)
                probe = root / ('probe-' + tag)
                probe.mkdir()
                (probe / 'project.godot').write_text('config_version=5\n[application]\nconfig/name="Glory Capacity QA"\nconfig/use_custom_user_dir=true\nconfig/custom_user_dir_name=' + json.dumps(tag) + '\n')
                (probe / 'probe.gd').write_text('extends SceneTree\nfunc _initialize():\n print("QA_USER_DIR=" + OS.get_user_data_dir())\n quit()\n')
                result = subprocess.run(['unshare', '--net', '--', str(args.godot), '--headless', '--path', str(probe), '--script', str(probe / 'probe.gd')], capture_output=True, text=True, timeout=20, check=True)
                match = re.search(r'^QA_USER_DIR=(.+)$', result.stdout, re.M)
                if not match or Path(match[1]).name != tag:
                    raise RuntimeError('Cannot verify isolated user directory: ' + result.stdout + result.stderr)
                user_dirs.append(Path(match[1]))
            report['user_directories'] = list(map(str, user_dirs))
            env = os.environ.copy()
            env['GLORY_CAPACITY_WAVES'] = str(args.waves)
            command = ['unshare', '--net', '--', sys.executable, str(project / 'tools/server_capacity_processes.py'),
                       str(args.godot), str(project), str(client), str(peers), str(args.rooms), 'cooperative', str(args.out / 'clients.log')]
            with (args.out / 'server.log').open('w') as log:
                process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    report['returncode'] = process.wait(timeout=130 + args.waves * 190)
                except BaseException:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                    raise
            server_text = (args.out / 'server.log').read_text(errors='replace')
            client_text = (args.out / 'clients.log').read_text(errors='replace') if (args.out / 'clients.log').exists() else ''
            report['engine_errors'] = [line for line in (server_text + '\n' + client_text).splitlines() if re.search(r'^ERROR:|SCRIPT ERROR:|Parse Error:|Compile Error:', line)]
            # Godot 4.7 emits a null-mutex diagnostic while destroying a DTLS
            # context, after the test has finished. Keep it visible and distinct
            # from runtime failures; any other diagnostic still fails the run.
            report['runtime_errors'] = []
            report['teardown_diagnostics'] = []
            for endpoint_text in (server_text, client_text):
                finished = False
                for line in endpoint_text.splitlines():
                    if line.startswith('CHECK_RESULT name=server_capacity_split '):
                        finished = True
                    if re.search(r'^ERROR:|SCRIPT ERROR:|Parse Error:|Compile Error:', line):
                        if finished and line == 'ERROR: Parameter "p_mutex->mutex" is null.':
                            report['teardown_diagnostics'].append(line)
                        else:
                            report['runtime_errors'].append(line)
            report['strict_engine_clean'] = not report['engine_errors']
            report['measurements'] = [json.loads(line.split(' ', 1)[1]) for line in server_text.splitlines() if line.startswith('CAPACITY_PHASE ')]
            report['processes'] = [json.loads(line.split(' ', 1)[1]) for line in server_text.splitlines() if line.startswith('CAPACITY_PROCESSES ')]
            report['checks'] = [line for line in (server_text + '\n' + client_text).splitlines() if 'CHECK_RESULT' in line]
            report['passed'] = report['returncode'] == 0 and not report['runtime_errors'] and len(report['measurements']) == args.waves + 1 and len(report['checks']) == 2 and all('status=PASS' in row for row in report['checks'])
    except Exception as error:
        report['error'] = str(error)
    finally:
        for path in user_dirs:
            if path.is_dir() and path.name.startswith('GloryLinuxStabilityQA-'):
                shutil.rmtree(path)
        report['seconds'] = round(time.monotonic() - started, 3)
        (args.out / 'summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(report, ensure_ascii=False), flush=True)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
