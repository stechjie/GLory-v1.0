#!/usr/bin/env python3
"""Install a stable app identity for the GLory removable-volume LaunchAgent.

Run once, open the app and approve its removable-volume prompt, then run with
--configure-schedule after its preflight passes. Does not edit TCC databases.
"""
import argparse
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import datetime

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--configure-schedule', action='store_true')
args = p.parse_args()
source = Path(__file__).with_name('patch_runner.m')
app = Path.home() / 'Applications/GLory Patch Runner.app'
contents = app / 'Contents'
exe = contents / 'MacOS/GloryPatchRunner'
info = {'CFBundleIdentifier': 'com.glory.patch.runner', 'CFBundleName': 'GLory Patch Runner',
        'CFBundleDisplayName': 'GLory Patch Runner', 'CFBundleExecutable': 'GloryPatchRunner',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
        'LSUIElement': True, 'NSRemovableVolumesUsageDescription':
        '读取 GLory 项目和资源，并写入每日 Android/iOS 补丁构建结果。'}
identity = hashlib.sha256(source.read_bytes() + plistlib.dumps(info)).hexdigest()
marker = contents / 'Resources/build-source.sha256'
if not exe.exists() or not marker.exists() or marker.read_text().strip() != identity:
    exe.parent.mkdir(parents=True, exist_ok=True)
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'AppKit', '-framework',
                    'Foundation', str(source), '-o', str(exe)], check=True)
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(identity + '\n')
    subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', 'com.glory.patch.runner',
                    str(app)], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
if args.configure_schedule:
    target = Path.home() / 'Library/LaunchAgents/com.glory.patch.nightly.plist'
    settings = plistlib.loads(target.read_bytes())
    backup_dir = Path.home() / 'Library/Application Support/Glory-Patch/backups'
    backup_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(target, backup_dir / (datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '.plist'))
    settings['ProgramArguments'] = [str(exe), '--run']
    settings['WorkingDirectory'] = str(Path.home())
    target.write_bytes(plistlib.dumps(settings))
    print('Schedule saved; reload the existing LaunchAgent after checking no job is running.')
print(app)
