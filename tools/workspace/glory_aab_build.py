#!/usr/bin/env python3
"""Build, sign, and validate an isolated Google Play release AAB."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid
import zipfile
import glory_build as b


def signing_password():
    value = os.environ.get('GLORY_KEYSTORE_PASSWORD')
    if value:
        return value
    if sys.platform == 'darwin':
        result = subprocess.run(['security', 'find-generic-password', '-a', 'GLory',
                                 '-s', 'com.glory.android.release', '-w'],
                                capture_output=True, text=True, timeout=15)
        if result.returncode == 0:
            return result.stdout.rstrip('\r\n')
    return None


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sign', type=Path, help='Sign an existing unsigned AAB without rebuilding')
    p.add_argument('--unsigned', action='store_true', help='Build only; defer signing until the password is available')
    p.add_argument('--check', action='store_true', help='Check local dependencies without building or signing')
    p.add_argument('--sync', action='store_true', help='Update GitHub and Drive before building')
    p.add_argument('--version-code', type=int, help='Override Android versionCode in the isolated build only')
    p.add_argument('--alias', help='Private-key alias in the release keystore')
    p.add_argument('--keystore', type=Path, default=b.ROOT/'build/aab/.signing/glory-release.keystore')
    a = p.parse_args()
    if a.version_code is not None and not 1 <= a.version_code <= 2100000000:
        p.error('--version-code must be between 1 and 2100000000')
    if a.sign:
        a.sign = a.sign.expanduser().resolve()
    if not a.unsigned and not a.keystore.is_file():
        p.error('Release keystore missing; supply --keystore or use --unsigned')
    env = b.environment(argparse.Namespace(godot=None, java_home=None, android_sdk=None, templates=None))
    if not list((b.ROOT/'build/aab/tools').glob('bundletool-all-*.jar')):
        raise RuntimeError('Missing official bundletool-all JAR in build/aab/tools')
    if a.check:
        print('AAB environment and keystore path checked; no upload authentication checked.')
        return
    if a.sync:
        if a.sign:
            p.error('--sync cannot be used with --sign')
        subprocess.run([sys.executable, str(Path(__file__).with_name('glory_update.py'))], check=True)
    password = None if a.unsigned else signing_password()
    if not a.unsigned and not password and not sys.stdin.isatty():
        raise RuntimeError('Set GLORY_KEYSTORE_PASSWORD from a local secret store for unattended signing')
    out = b.ROOT/'build/aab'
    out.mkdir(parents=True, exist_ok=True)
    if a.sign:
        result = json.loads((out/'latest-unsigned.json').read_text())
        if Path(result['aab']).resolve() != a.sign.resolve() or b.digest(a.sign) != result['sha256']:
            raise RuntimeError('Build metadata or SHA-256 does not match the supplied AAB')
        import getpass
        password = password or getpass.getpass('Keystore password: ')
        child = dict(os.environ, GLORY_KEYSTORE_PASSWORD=password)
        if not a.alias:
            listed = subprocess.run([str(env['java']/'bin/keytool'), '-list', '-v', '-J-Duser.language=en', '-keystore', str(a.keystore), '-storepass:env', 'GLORY_KEYSTORE_PASSWORD'], env=child, text=True, capture_output=True)
            if listed.returncode:
                raise RuntimeError('Unable to unlock keystore; verify keystore password.')
            entries = [re.search(r'Alias name: ([^\r\n]+)', entry)[1]
                       for entry in re.split(r'(?=Alias name: )', listed.stdout)
                       if 'Entry type: PrivateKeyEntry' in entry and re.search(r'Alias name: ([^\r\n]+)', entry)]
            if len(entries) != 1:
                raise RuntimeError('Specify --alias; keystore does not contain exactly one private key.')
            a.alias = entries[0].strip()
        target = a.sign.with_name(a.sign.name.replace('-unsigned.aab', '-release.aab'))
        if target == a.sign or target.exists():
            raise RuntimeError('Expected a new output filename ending in -unsigned.aab')
        key_password = os.environ.get('GLORY_KEY_PASSWORD', password)
        child['GLORY_KEY_PASSWORD'] = key_password
        subprocess.run([str(env['java']/'bin/jarsigner'), '-keystore', str(a.keystore), '-storepass:env', 'GLORY_KEYSTORE_PASSWORD', '-keypass:env', 'GLORY_KEY_PASSWORD', '-signedjar', str(target), str(a.sign), a.alias], env=child, check=True)
        verified = b.capture([env['java']/'bin/jarsigner', '-verify', '-J-Duser.language=en', target])
        if 'jar verified.' not in verified:
            raise RuntimeError('AAB signature verification failed')
        (out/'signature-verification.txt').write_text(verified+'\n')
        subprocess.run([str(env['java']/'bin/keytool'), '-exportcert', '-rfc', '-keystore', str(a.keystore), '-storepass:env', 'GLORY_KEYSTORE_PASSWORD', '-alias', a.alias, '-file', str(out/'upload-certificate.pem')], env=child, check=True)
        subprocess.run([sys.executable, str(Path(__file__).with_name('glory_aab_verify.py')), str(target)], check=True)
        result.update(aab=str(target), signed=True, sha256=b.digest(target), bytes=target.stat().st_size,
                      verification=str(out/'verification'/target.stem/'result.json'))
        b.json_write(out/'latest-release.json', result)
        print('SIGNED AAB:', target, flush=True)
        return
    stamp = dt.datetime.now().strftime('%Y%m%d-%H%M%S')
    work = out/'work'
    log = out/'logs'/stamp
    log.mkdir(parents=True)
    stage = work/'project'
    project = b.ROOT/'GLory-v1.0'
    with b.file_lock(out/'.build.lock', nonblocking=True):
        # Reuse import artifacts only as a seed; reimport the newly staged sources.
        cache = b.ROOT/'build/android-work/project/.godot'
        if cache.exists() and not (stage/'.godot').exists():
            stage.mkdir(parents=True, exist_ok=True)
            subprocess.run(['rsync','-a',str(cache),str(stage)+'/'],check=True)
        with b.file_lock(b.ROOT/'.glory-sync/sync.lock', shared=True):
            state_path = b.ROOT/'.glory-sync/last-run.json'
            if state_path.exists() and json.loads(state_path.read_text()).get('status') in ('running', 'failed'):
                raise RuntimeError('Resource sync is running or failed; resolve it before building')
            report = b.stage_project(project,b.asset_root(b.ROOT/'res'),stage,log)
        engine = b.prepare_engine(env,work)
        preset,package = b.export_preset(stage,None)
        # This Play listing uses a distinct, user-selected application ID.
        package = 'com.glory.game.google'
        cfg = stage/'export_presets.cfg'
        text = cfg.read_text().replace(f'name="{preset}"','name="Google Play Release"')
        text = re.sub(r'^custom_features=.*$', 'custom_features=""', text, flags=re.M)
        values = {'package/unique_name':f'"{package}"','gradle_build/export_format':'1','gradle_build/target_sdk':'36','package/signed':'false',
                  'architectures/armeabi-v7a':'true','architectures/arm64-v8a':'true',
                  'architectures/x86':'false','architectures/x86_64':'false'}
        for key,value in values.items():
            text = re.sub(r'^'+re.escape(key)+r'=.*\n?', '', text, flags=re.M)
            text += f'{key}={value}\n'
        if a.version_code is not None:
            text = re.sub(r'^version/code=\d+', f'version/code={a.version_code}', text, flags=re.M)
        cfg.write_text(text)
        cfg.chmod(0o600)
        commit = b.capture(['git','-C',project,'rev-parse','HEAD'])
        status = b.capture(['git','-C',project,'status','--porcelain'])
        version = re.search(r'^version/name="([^"]+)"',text,re.M)[1]
        code = int(re.search(r'^version/code=(\d+)',text,re.M)[1])
        identity = dict(build_id=str(uuid.uuid4()),git_commit=commit,dirty_files=len(status.splitlines()),
                        build_utc=dt.datetime.now(dt.timezone.utc).isoformat(),godot_version=env['version'],
                        package_id=package,version_name=version,version_code=code,export_preset='Google Play Release',
                        asset_inventory_sha256=report['actual_assets_sha256'])
        b.json_write(stage/'build_info.json',identity)
        b.json_write(log/'build_info.json',identity)
        child = dict(os.environ,JAVA_HOME=str(env['java']),ANDROID_HOME=str(env['sdk']),ANDROID_SDK_ROOT=str(env['sdk']))
        child['PATH']=str(env['java']/'bin')+os.pathsep+child.get('PATH','')
        imported=b.logged_process([engine,'--headless','--path',stage,'--import'],log/'import.log',child,strict=False)
        materials=b.verify_model_materials(engine,stage,log,child)
        b.verify_import_diagnostics(imported,stage,log,materials)
        aab=out/f'Glory-{version}-{code}-{stamp}-unsigned.aab'
        command=[engine,'--headless','--path',stage]
        if not (stage/'android/build/config.gradle').exists():
            command.append('--install-android-build-template')
        command += ['--export-release','Google Play Release',aab]
        exported=b.logged_process(command,log/'export.log',child,strict=False)
        b.verify_export_diagnostics(exported,log)
        with zipfile.ZipFile(aab) as z:
            if z.testzip(): raise RuntimeError('AAB ZIP integrity failure')
            names=z.namelist()
            if not any(n.endswith('/build_info.json') and json.loads(z.read(n))==identity for n in names):
                raise RuntimeError('Build identity missing from AAB')
            dex=[z.read(n) for n in names if n.endswith('.dex')]
            for required in (b'com/glory/voice/GloryVoicePlugin',b'io/livekit/android/room/Room'):
                if not any(required in data for data in dex):raise RuntimeError('Missing voice dependency')
        result=dict(identity,aab=str(aab),signed=False,sha256=b.digest(aab),bytes=aab.stat().st_size,logs=str(log),device_tested=False,play_uploaded=False)
        b.json_write(out/'latest-unsigned.json',result)
        print('UNSIGNED AAB:',aab,flush=True)
        if not a.unsigned:
            command = [sys.executable, str(Path(__file__).resolve()), '--sign', str(aab), '--keystore', str(a.keystore)]
            if a.alias:
                command += ['--alias', a.alias]
            subprocess.run(command, check=True)

if __name__=='__main__':main()
