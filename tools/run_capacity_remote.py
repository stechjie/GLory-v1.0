#!/usr/bin/env python3
"""Cross-host battle load: isolated Linux server and four macOS bot processes.

Requires an already prepared QA project (verified server bundle, font imports,
current capacity harness) and a temporary UDP firewall restricted to --client-ip.
Does not deploy or connect to the production game service. SSH host keys must
already be pinned in --ssh-config. Reports and server logs are retained.
"""
import argparse
import hashlib
import ipaddress
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tarfile
import time
import uuid
from types import SimpleNamespace


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--project', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--ssh-config', required=True)
    p.add_argument('--ssh-host', default='glory-capacity20')
    p.add_argument('--host', type=ipaddress.IPv4Address, required=True)
    p.add_argument('--client-ip', type=ipaddress.IPv4Address, required=True)
    p.add_argument('--godot', required=True)
    p.add_argument('--remote-godot', required=True)
    p.add_argument('--port', type=int, default=18080)
    p.add_argument('--rooms', type=int, default=20)
    p.add_argument('--waves', type=int, default=5)
    a = p.parse_args()
    if a.out.exists() or not 1 <= a.rooms <= 128 or not 1 <= a.waves <= 100 or a.port == 8080 or not 1024 <= a.port < 65536:
        p.error('Fresh output directory, valid room/wave counts and a non-production port required')
    a.out.mkdir(parents=True)
    a.out = a.out.resolve()
    tag = 'glory-capacity-' + uuid.uuid4().hex[:12]
    remote = '/tmp/' + tag
    ssh = ['ssh', '-F', a.ssh_config, a.ssh_host]
    scp = ['scp', '-F', a.ssh_config]
    q = shlex.quote

    def remote_run(command, check=True):
        return subprocess.run(ssh + [command], capture_output=True, text=True, timeout=30, check=check)

    def setting(project, name):
        f = project / 'project.godot'
        s = f.read_text()
        for key in ['config/use_custom_user_dir', 'config/custom_user_dir_name']:
            s = re.sub(r'^' + re.escape(key) + r'=.*\n', '', s, flags=re.M)
        s = s.replace('[application]', '[application]\nconfig/use_custom_user_dir=true\nconfig/custom_user_dir_name=' + json.dumps(name), 1)
        f.write_text(s)
        return name

    processes, logs, user_dirs = [], [], []
    cleanup_errors = []

    def cleanup_remote(command):
        try:
            return remote_run(command, check=False)
        except Exception as error:
            cleanup_errors.append(str(error))
            return SimpleNamespace(stdout="", stderr=str(error), returncode=255)
    report = {'rooms': a.rooms, 'peers': a.rooms * 4, 'waves': a.waves, 'remote_directory': remote,
              'unit': tag, 'host': str(a.host), 'port': a.port, 'client_ip': str(a.client_ip),
              'passed': False, 'network': 'public pinned DTLS; four separate macOS client processes',
              'source_sha256': {str(x.relative_to(a.project)): hashlib.sha256(x.read_bytes()).hexdigest()
                                for x in a.project.rglob('*') if x.is_file() and '.godot' not in x.parts}}
    (a.out / 'run-metadata.json').write_text(json.dumps({'unit': tag, 'remote_directory': remote, 'port': a.port, 'host': str(a.host)}, indent=2) + '\n')
    started = time.monotonic()
    try:
        server = a.out / 'server-project'
        shutil.copytree(a.project, server)
        setting(server, tag + '-server')
        (server / '_measure.py').write_text('import subprocess,resource,json,sys\nr=subprocess.run(sys.argv[1:])\nu=resource.getrusage(resource.RUSAGE_CHILDREN)\nprint("CAPACITY_RESOURCE "+json.dumps({"user_cpu_seconds":u.ru_utime,"system_cpu_seconds":u.ru_stime,"rss_kib":u.ru_maxrss}),flush=True)\nsys.exit(r.returncode)\n')
        archive = a.out / 'project.tgz'
        with tarfile.open(archive, 'w:gz') as tar:
            tar.add(server, arcname='project')
        remote_run('mkdir -m 700 ' + q(remote))
        subprocess.run(scp + [str(archive), a.ssh_host + ':' + remote + '/project.tgz'], check=True, timeout=60)
        remote_run('tar -xzf ' + q(remote + '/project.tgz') + ' -C ' + q(remote))
        username = remote_run('id -un').stdout.strip()
        remote_run('sudo install -m 755 ' + q(a.remote_godot) + ' ' + q(remote + '/godot'))
        common = ['--peers=' + str(a.rooms * 4), '--rooms=' + str(a.rooms), '--waves=' + str(a.waves), '--mode=cooperative']
        scene = 'res://tools/server_capacity_split_check.tscn'
        command = ['sudo', 'systemd-run', '--quiet', '--unit=' + tag, '--property=User=' + username,
                   '--property=RuntimeMaxSec=' + str(150 + 190 * a.waves), '--property=ProtectSystem=strict',
                   '--property=ProtectHome=read-only', '--property=NoNewPrivileges=true',
                   '--property=ReadWritePaths=' + remote, '--property=IPAddressDeny=any',
                   '--property=IPAddressAllow=' + str(a.client_ip) + '/32',
                   '--property=StandardOutput=file:' + remote + '/server.log',
                   '--property=StandardError=inherit', '--property=RemainAfterExit=yes', '--property=CPUAccounting=true', '--property=MemoryAccounting=true', '--setenv=XDG_DATA_HOME=' + remote + '/userdata',
                   '/usr/bin/python3', remote + '/project/_measure.py', remote + '/godot', '--headless', '--path', remote + '/project', scene, '--',
                   '--role=server', '--bind-host=0.0.0.0', '--bind-port=' + str(a.port),
                   '--rendezvous=' + remote + '/rendezvous.json', '--qa-user-dir-tag=' + tag + '-server'] + common
        remote_run(shlex.join(command))
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            read = remote_run('cat ' + q(remote + '/rendezvous.json'), check=False)
            if read.returncode == 0:
                settings = json.loads(read.stdout)
                break
            time.sleep(1)
        else:
            raise RuntimeError('Test server did not publish rendezvous')
        rendezvous = a.out / 'rendezvous.json'
        rendezvous.write_text(json.dumps(settings))
        for group in range(4):
            project = a.out / ('client-' + str(group))
            shutil.copytree(a.project, project)
            name = setting(project, tag + '-client-' + str(group))
            user_dirs.append(Path.home() / 'Library/Application Support' / name)
            profile = '(version 1)(allow default)(deny network*)(allow network-bind)(allow network-inbound)(allow network-outbound (remote udp "*:' + str(a.port) + '"))'
            cmd = ['/usr/bin/sandbox-exec', '-p', profile, a.godot, '--headless', '--path', str(project), scene, '--',
                   '--role=clients', '--rendezvous=' + str(rendezvous), '--host=' + str(a.host),
                   '--qa-user-dir-tag=' + name, '--client-start=' + str(group * a.rooms), '--client-count=' + str(a.rooms)] + common
            log = (a.out / ('client-' + str(group) + '.log')).open('w')
            logs.append(log)
            processes.append(subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT))
        deadline = time.monotonic() + 120 + 190 * a.waves
        while time.monotonic() < deadline and any(x.poll() is None for x in processes):
            time.sleep(1)
        if any(x.poll() is None for x in processes):
            raise TimeoutError('Remote capacity test exceeded deadline')
        report['client_exit_codes'] = [x.returncode for x in processes]
        time.sleep(1)  # Server flushes its final report after notifying clients.
    except (Exception, KeyboardInterrupt) as error:
        report['error'] = str(error) + ('\n' + str(error.stderr) if isinstance(error, subprocess.CalledProcessError) else '')
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for log in logs:
            log.close()
        report['server_state'] = cleanup_remote('sudo systemctl show ' + q(tag) + ' -p ActiveState -p Result -p ExecMainStatus -p CPUUsageNSec -p MemoryPeak').stdout
        report['server_log'] = cleanup_remote('cat ' + q(remote + '/server.log')).stdout
        (a.out / 'server.log').write_text(report.pop('server_log'))
        stopped = cleanup_remote('sudo systemctl stop ' + q(tag))
        if stopped.returncode != 0:
            cleanup_errors.append('Could not confirm test unit stopped: ' + stopped.stderr)
        report['cleanup_errors'] = cleanup_errors
        for directory in user_dirs:
            if directory.is_dir() and directory.name.startswith(tag):
                shutil.rmtree(directory)
        texts = [(a.out / 'server.log').read_text()] + [x.read_text(errors='replace') for x in sorted(a.out.glob('client-*.log'))]
        report['checks'] = [line for text in texts for line in text.splitlines() if line.startswith('CHECK_RESULT ')]
        report['resources'] = [json.loads(line.split(' ', 1)[1]) for line in texts[0].splitlines() if line.startswith('CAPACITY_RESOURCE ')]
        report['measurements'] = [json.loads(line.split(' ', 1)[1]) for line in texts[0].splitlines() if line.startswith('CAPACITY_PHASE ')]
        report['runtime_errors'], report['teardown_diagnostics'] = [], []
        for text in texts:
            finished = False
            for line in text.splitlines():
                finished |= line.startswith('CHECK_RESULT name=server_capacity_split ')
                if re.search(r'^ERROR:|SCRIPT ERROR:|Parse Error:|Compile Error:', line):
                    bucket = 'teardown_diagnostics' if finished and line == 'ERROR: Parameter "p_mutex->mutex" is null.' else 'runtime_errors'
                    report[bucket].append(line)
        report['seconds'] = round(time.monotonic() - started, 3)
        report['passed'] = not cleanup_errors and not report.get('error') and report.get('client_exit_codes') == [0] * 4 and not report['runtime_errors'] and len(report['checks']) == 5 and all('status=PASS' in x for x in report['checks']) and len(report['measurements']) == a.waves + 1
        (a.out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({k: v for k, v in report.items() if k != 'source_sha256'}), flush=True)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
