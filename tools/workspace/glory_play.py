"""Publish a verified AAB to the existing Google Play internal track only.

Credentials: GLORY_PLAY_CREDENTIALS points to an external OAuth authorized-user
or service-account JSON with androidpublisher scope and Play Console app access.
Individual tester email lists must first be configured in Play Console.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys
import glory_build as b

PACKAGE = 'com.glory.game'
ROOT = b.ROOT / 'build/play-releases'
SCOPE = 'https://www.googleapis.com/auth/androidpublisher'


def client():
    path = os.environ.get('GLORY_PLAY_CREDENTIALS')
    if not path or not Path(path).expanduser().is_file():
        raise RuntimeError('Missing GLORY_PLAY_CREDENTIALS: configure a Play API credential outside the repository')
    try:
        import google.auth
        from google.auth.transport.requests import AuthorizedSession
    except ImportError:
        raise RuntimeError('Install tools/requirements-release.txt into .glory-tools/venv') from None
    credentials, _ = google.auth.load_credentials_from_file(str(Path(path).expanduser()), scopes=[SCOPE])
    return AuthorizedSession(credentials)


class PlayError(RuntimeError):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


class Play:
    def __init__(self, session):
        self.session = session
        self.base = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/' + PACKAGE

    def call(self, method, path, **kw):
        r = self.session.request(method, self.base + path, timeout=120, **kw)
        if not r.ok:
            # Never log headers, credential payloads, or resumable upload URLs.
            raise PlayError(r.status_code, f'Play API {method} {path}: HTTP {r.status_code}; inspect Play Console permissions/app setup')
        return r.json() if r.content else {}

    def edit(self):
        return self.call('POST', '/edits', json={})['id']

    def inventory(self, edit):
        return self.call('GET', f'/edits/{edit}/bundles').get('bundles', [])

    def track(self, edit):
        return self.call('GET', f'/edits/{edit}/tracks/internal')

    def upload(self, edit, path):
        url = 'https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/' + PACKAGE + f'/edits/{edit}/bundles'
        # Streaming avoids loading a 700+ MiB bundle into memory. No automatic
        # mutation retry: saved state and remote hashes are checked on resume.
        with path.open('rb') as stream:
            r = self.session.post(url, params={'uploadType': 'media'}, data=stream,
                                  headers={'Content-Type': 'application/octet-stream', 'Content-Length': str(path.stat().st_size)}, timeout=1800)
        if not r.ok:
            raise RuntimeError(f'Play bundle upload HTTP {r.status_code}; resume after checking Console')
        return r.json()


def save(path, state, **changes):
    state.update(changes, updated_at=dt.datetime.now(dt.timezone.utc).isoformat())
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2)+'\n')
    os.replace(tmp, path)


def matching_bundle(bundles, metadata):
    for item in bundles:
        if int(item['versionCode']) == int(metadata['version_code']):
            if item.get('sha256', '').lower() != metadata['sha256'].lower():
                raise RuntimeError('Remote versionCode exists with different bytes; use a new versionCode')
            return item
    return None


def track_contains(track, code):
    return any(str(code) in r.get('versionCodes', []) and r.get('status') == 'completed'
               for r in track.get('releases', []))


def release_body(metadata, notes):
    return {'track': 'internal', 'releases': [{'name': f"{metadata['version_name']} ({metadata['version_code']})",
        'versionCodes': [str(metadata['version_code'])], 'status': 'completed',
        'releaseNotes': [{'language': 'zh-CN', 'text': notes}]}]}


def validate(metadata):
    path = Path(metadata['aab']).resolve()
    if metadata.get('package_id') != PACKAGE or metadata.get('signed') is not True:
        raise RuntimeError('Only the signed GLory release AAB is accepted')
    if not path.is_file() or b.digest(path) != metadata['sha256']:
        raise RuntimeError('AAB missing or hash differs from build metadata')
    import argparse
    env = b.environment(argparse.Namespace(godot=None, java_home=None, android_sdk=None, templates=None))
    signature = b.capture([env['java']/'bin/jarsigner', '-verify', '-J-Duser.language=en', path])
    if 'jar verified.' not in signature:
        raise RuntimeError('AAB signature verification failed')
    subprocess.run([sys.executable, str(Path(__file__).with_name('glory_aab_verify.py')), str(path)], check=True)
    return path


def publish(api, metadata, artifact, state_path, notes):
    state = json.loads(state_path.read_text()) if state_path.exists() else {
        'package': PACKAGE, 'sha256': metadata['sha256'], 'version_code': metadata['version_code'],
        'notes': notes, 'phase': 'new', 'tester_membership_verified': False}
    if state['sha256'] != metadata['sha256'] or state['package'] != PACKAGE:
        raise RuntimeError('Release state identity mismatch')
    # Creating another edit can invalidate this account's existing edit. Reuse
    # the saved edit until it expires or has been committed.
    if state.get('edit') and state.get('phase') != 'complete':
        edit = state['edit']
        try:
            bundles = api.inventory(edit)
        except PlayError as error:
            if error.status not in (404, 409):
                raise
            probe = api.edit()
            try:
                if matching_bundle(api.inventory(probe), metadata) and track_contains(api.track(probe), metadata['version_code']):
                    save(state_path, state, phase='complete', internal_track_published=True)
                    return
            finally:
                api.call('DELETE', f'/edits/{probe}')
            raise RuntimeError('Saved edit expired or invalidated; remote release not verified. Inspect Console before creating another release')
    else:
        edit = api.edit()
        bundles = api.inventory(edit)
        found = matching_bundle(bundles, metadata)
        if found and track_contains(api.track(edit), metadata['version_code']):
            api.call('DELETE', f'/edits/{edit}')
            save(state_path, state, phase='complete', internal_track_published=True)
            return
        if state.get('phase') == 'complete':
            api.call('DELETE', f'/edits/{edit}')
            raise RuntimeError('Previously completed release is no longer on the internal track; refusing to downgrade')
        save(state_path, state, edit=edit, phase='prepared')
    found = matching_bundle(bundles, metadata)
    if not found:
        if state.get('upload_attempted'):
            raise RuntimeError('Previous upload outcome unknown; no duplicate upload attempted. Inspect saved edit in Play Console')
        max_code = max([0] + [int(x['versionCode']) for x in bundles])
        if int(metadata['version_code']) <= max_code:
            raise RuntimeError('versionCode must exceed all currently uploaded bundles')
        save(state_path, state, phase='uploading', upload_attempted=True)
        found = api.upload(edit, artifact)
        if not matching_bundle([found], metadata):
            raise RuntimeError('Uploaded bundle identity differs from build metadata')
    save(state_path, state, phase='uploaded')
    api.call('PUT', f'/edits/{edit}/tracks/internal', json=release_body(metadata, state['notes']))
    api.call('POST', f'/edits/{edit}:validate')
    save(state_path, state, phase='committing')
    api.call('POST', f'/edits/{edit}:commit', params={'changesInReviewBehavior': 'ERROR_IF_IN_REVIEW'})
    check = api.edit()
    try:
        if not matching_bundle(api.inventory(check), metadata) or not track_contains(api.track(check), metadata['version_code']):
            raise RuntimeError('Commit returned but internal track readback did not match')
    finally:
        api.call('DELETE', f'/edits/{check}')
    save(state_path, state, phase='complete', internal_track_published=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--check', action='store_true', help='Check credential file/dependencies without publishing')
    p.add_argument('--next-code', action='store_true', help='Read remote bundle/APK/track version codes using a disposable edit')
    p.add_argument('--metadata', type=Path, default=b.ROOT/'build/aab/latest-release.json')
    p.add_argument('--notes', type=Path)
    a = p.parse_args()
    api = Play(client())
    if a.check:
        print('Play credentials loaded; online app access is checked by --next-code. No upload.')
        return
    ROOT.mkdir(parents=True, exist_ok=True)
    with b.file_lock(ROOT/'.release.lock', nonblocking=True):
        if a.next_code:
            pending = [p for p in ROOT.glob('*.json') if json.loads(p.read_text()).get('phase') != 'complete']
            if pending:
                raise RuntimeError('Unfinished Play release exists; resume its exact metadata before opening another edit')
            edit = api.edit()
            try:
                codes = [0] + [int(x['versionCode']) for x in api.inventory(edit)]
                codes += [int(x['versionCode']) for x in api.call('GET', f'/edits/{edit}/apks').get('apks', [])]
                for track in api.call('GET', f'/edits/{edit}/tracks').get('tracks', []):
                    for release in track.get('releases', []):
                        codes += [int(x) for x in release.get('versionCodes', [])]
                print(max(codes)+1)
            finally:
                api.call('DELETE', f'/edits/{edit}')
            return
        metadata = json.loads(a.metadata.read_text())
        artifact = validate(metadata)
        notes = a.notes.read_text().strip() if a.notes else '同步最新代码与资源，修复已发现的问题。请验证登录、组队、连续对战和语音。'
        if not 1 <= len(notes) <= 500:
            raise RuntimeError('Release notes must contain 1–500 characters')
        state_path = ROOT / f"{metadata['version_code']}-{metadata['sha256'][:12]}.json"
        publish(api, metadata, artifact, state_path, notes)
        print('Internal track readback verified:', state_path)
        print('Tester email membership and download availability must be verified in Play Console; this API does not send individual email invitations.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Google auth exceptions may contain credential-bearing server responses.
        print(str(error) if isinstance(error, RuntimeError) else f'Play release stopped ({type(error).__name__}); see saved state', file=sys.stderr)
        sys.exit(1)
