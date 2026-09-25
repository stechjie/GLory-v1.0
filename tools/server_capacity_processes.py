"""Linux-only isolated two-process capacity launcher.

Run inside a fresh `unshare --net` namespace. Positional arguments:
Godot executable, server project, client project, peers, rooms, mode, client log.
Both projects must use distinct custom QA user directories. The server and
client test scenes bind loopback and generate a disposable certificate.
"""
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import time

godot, server_project, client_project, peers, rooms, mode, client_log = sys.argv[1:]
if os.readlink('/proc/self/ns/net') == os.readlink('/proc/1/ns/net'):
    raise RuntimeError('Run inside a separate network namespace, not the host network')
if Path(server_project).resolve() == Path(client_project).resolve():
    raise RuntimeError('Server and clients need distinct isolated project copies')
user_directory_names = []
for project in (server_project, client_project):
    config = (Path(project) / 'project.godot').read_text()
    if 'config/use_custom_user_dir=true' not in config or 'config/custom_user_dir_name="GloryLinuxStabilityQA-' not in config:
        raise RuntimeError('Project is not configured with a dedicated QA user directory')
    user_directory_names.append(re.search(r'^config/custom_user_dir_name=(.+)$', config, re.M)[1])
if len(set(user_directory_names)) != 2:
    raise RuntimeError('Server and clients must not share a QA user directory')
subprocess.run(['ip', 'link', 'set', 'lo', 'up'], check=True)
ready = Path(server_project).parent / 'rendezvous.json'
if ready.exists():
    raise RuntimeError('Stale rendezvous file; use a fresh scratch directory')
def args(project, role):
    return ['nice', '-n', '10', godot, '--headless', '--path', project,
            'res://tools/server_capacity_split_check.tscn', '--', '--role=' + role,
            '--peers=' + peers, '--rooms=' + rooms, '--mode=' + mode,
            '--idle-ms=' + os.environ.get('GLORY_CAPACITY_IDLE_MS', '10000'),
            '--rendezvous=' + str(ready)]
server = subprocess.Popen(args(server_project, 'server'))
client = None
peak = {'server_rss_kib': 0, 'client_rss_kib': 0}
try:
    until = time.monotonic() + 30
    while not ready.exists() and time.monotonic() < until and server.poll() is None:
        time.sleep(.1)
    if not ready.exists():
        raise RuntimeError('Server did not publish local handshake coordinates')
    with open(client_log, 'w') as output:
        client = subprocess.Popen(args(client_project, 'clients'), stdout=output, stderr=subprocess.STDOUT)
        until = time.monotonic() + 270
        server_finished_at = None
        while time.monotonic() < until and (server.poll() is None or client.poll() is None):
            if server.poll() is not None:
                if server_finished_at is None:
                    server_finished_at = time.monotonic()
                elif client.poll() is None and time.monotonic() - server_finished_at > 5:
                    client.terminate()
                    client.wait(timeout=5)
            for label, process in [('server', server), ('client', client)]:
                try:
                    lines = Path('/proc/' + str(process.pid) + '/status').read_text().splitlines()
                    rss = int(next(line for line in lines if line.startswith('VmRSS:')).split()[1])
                    peak[label + '_rss_kib'] = max(peak[label + '_rss_kib'], rss)
                except (OSError, StopIteration):
                    pass
            time.sleep(.25)
        if server.poll() is None or client.poll() is None:
            raise RuntimeError('Capacity process deadline exceeded')
        print('CAPACITY_PROCESSES ' + json.dumps({**peak, 'server_exit': server.returncode, 'client_exit': client.returncode}), flush=True)
        sys.exit(0 if server.returncode == 0 and client.returncode == 0 else 1)
finally:
    for process in (server, client):
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
