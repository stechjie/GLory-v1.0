"""Sequential, resumable GLory build and internal-release orchestration."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys
import glory_build as b

TOOLS = Path(__file__).resolve().parent
RUNS = b.ROOT/'build/nightly'


def write(path, state):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2)+'\n')
    os.replace(tmp, path)


def step(state, path, name, command):
    if state['steps'].get(name, {}).get('ok'):
        return True
    logfile = path.parent/(name+'.log')
    state['steps'][name] = {'ok': False, 'started': True, 'log': str(logfile)}
    write(path, state)
    print(f'[nightly] {name}: {logfile}', flush=True)
    with logfile.open('a') as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, cwd=b.ROOT)
    state['steps'][name].update(ok=result.returncode == 0, returncode=result.returncode)
    write(path, state)
    return result.returncode == 0


def local_code():
    import re
    values = [int(re.search(r'^version/code=(\d+)', (b.ROOT/'GLory-v1.0/export_presets.cfg').read_text(), re.M)[1])]
    for p in (b.ROOT/'build/aab').glob('latest-*.json'):
        values.append(int(json.loads(p.read_text())['version_code']))
    for p in RUNS.glob('*/state.json'):
        d = json.loads(p.read_text())
        values.append(int(d.get('version_code', 0)))
    return max(values)+1


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--build-only', action='store_true', help='Build packages without store API calls or upload')
    p.add_argument('--unsigned-aab', action='store_true', help='Only with --build-only; no signing secret required')
    p.add_argument('--local', action='store_true', help='Skip Git/Drive update for an explicitly prepared local snapshot')
    p.add_argument('--resume', type=Path, help='Resume the exact saved run; completed stages are not repeated')
    args = p.parse_args()
    if args.unsigned_aab and not args.build_only:
        p.error('--unsigned-aab requires --build-only')
    RUNS.mkdir(parents=True, exist_ok=True)
    with b.file_lock(RUNS/'.run.lock', nonblocking=True):
        if args.resume:
            path = args.resume.resolve()
            state = json.loads(path.read_text())
            if state.get('schema') != 1 or path.parent.parent != RUNS:
                raise RuntimeError('Invalid nightly state path')
        else:
            latest = RUNS/'latest.json'
            if latest.exists():
                previous = json.loads(Path(json.loads(latest.read_text())['state']).read_text())
                if not previous['build_only'] and previous['status'] != 'complete':
                    raise RuntimeError('Previous release is unfinished; inspect latest.json and use --resume to avoid duplicate releases')
            folder = RUNS/dt.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
            folder.mkdir()
            path = folder/'state.json'
            state = {'schema': 1, 'status': 'running', 'steps': {}, 'build_only': args.build_only,
                     'unsigned_aab': args.unsigned_aab, 'local': args.local}
            write(path, state)
            write(latest, {'state': str(path)})
        py = sys.executable
        def run(name, script, *flags):
            return step(state, path, name, [py, str(TOOLS/script), *map(str, flags)])
        if not state['local'] and not run('sync', 'glory_update.py'):
            state['status'] = 'failed'; write(path, state); return 1
        sha = b.capture(['git', '-C', b.ROOT/'GLory-v1.0', 'rev-parse', 'HEAD'])
        if state.get('git_commit') and sha != state['git_commit']:
            raise RuntimeError('Source commit changed since this run; do not resume builds from mixed revisions')
        state['git_commit'] = sha
        write(path, state)
        run('apk', 'glory_build.py')
        play_ready = state['build_only'] or run('play_preflight', 'glory_play.py', '--check')
        try:
            if play_ready:
                if 'version_code' not in state:
                    code = local_code()
                    if not state['build_only']:
                        remote = subprocess.run([py, str(TOOLS/'glory_play.py'), '--next-code'], text=True, capture_output=True)
                        if remote.returncode:
                            (path.parent/'play-code.log').write_text(remote.stdout+remote.stderr)
                            raise RuntimeError('Google Play version query failed; see play-code.log')
                        code = max(code, int(remote.stdout.strip()))
                    state['version_code'] = code; write(path, state)
                flags = ['--version-code', str(state['version_code'])]
                if state['unsigned_aab']:
                    flags += ['--unsigned']
                if run('aab', 'glory_aab_build.py', *flags):
                    saved = path.parent/'aab.json'
                    if not saved.exists():
                        source = b.ROOT/'build/aab'/('latest-unsigned.json' if state['unsigned_aab'] else 'latest-release.json')
                        metadata = json.loads(source.read_text())
                        if int(metadata['version_code']) != state['version_code'] or metadata['git_commit'] != state['git_commit']:
                            raise RuntimeError('Another AAB build intervened; refuse to select the mutable latest artifact')
                        saved.write_bytes(source.read_bytes())
                    if not state['build_only']:
                        run('play_upload', 'glory_play.py', '--metadata', saved)
        except Exception as error:
            state['steps']['android_pipeline'] = {'ok': False, 'error_type': type(error).__name__}
            write(path, state)
            print('[nightly] Android pipeline failed; continuing independent iOS work', flush=True)
        if state['build_only']:
            run('ipa', 'glory_ios_build.py', '--method', 'app-store', '--result-file', path.parent/'ipa.json')
        elif run('ios_preflight', 'glory_testflight.py', '--check'):
            old = state['steps'].get('testflight', {})
            if old.get('started') and not old.get('ok'):
                # Use the known publisher state. Do not silently start a second build.
                latest = b.ROOT/'build/latest-testflight-release.json'
                if not latest.exists():
                    raise RuntimeError('No TestFlight resume state; inspect testflight.log before retrying')
                saved = Path(json.loads(latest.read_text())['state_file'])
                if not state.get('testflight_state'):
                    raise RuntimeError('Interrupted before TestFlight state was captured; inspect and reconcile publisher state manually')
                if str(saved) != state['testflight_state']:
                    raise RuntimeError('Another TestFlight release intervened; refusing to resume a different package')
                run('testflight', 'glory_testflight.py', '--resume', saved)
            else:
                ok = run('testflight', 'glory_testflight.py', '--local')
                latest = b.ROOT/'build/latest-testflight-release.json'
                if latest.exists():
                    state['testflight_state'] = json.loads(latest.read_text())['state_file']
                    write(path, state)
        required = ['apk', 'aab', 'ipa'] if state['build_only'] else ['apk', 'aab', 'play_upload', 'testflight']
        state['status'] = 'complete' if all(state['steps'].get(x, {}).get('ok') for x in required) else 'failed'
        state['distribution_scope'] = 'existing internal testers; email membership requires Console verification'
        write(path, state)
        print(f"[nightly] {state['status']}: {path}", flush=True)
        return 0 if state['status'] == 'complete' else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(f'[nightly] stopped: {error}', file=sys.stderr)
        sys.exit(1)
