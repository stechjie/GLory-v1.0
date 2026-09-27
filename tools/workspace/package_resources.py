#!/usr/bin/env python3
"""Create a verified resource delta against an explicitly supplied manifest."""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import zipfile

import glory_build as build


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, default=build.ROOT / 'GLory-v1.0')
    parser.add_argument('--assets', type=Path, default=build.ROOT / 'res/assets')
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--label', default=datetime.date.today().strftime('%Y%m%d'))
    args = parser.parse_args()
    sources, _, report = build.plan_asset_merge(args.project, args.assets)
    if report['selection_conflicts']:
        raise RuntimeError('Unresolved resource version conflicts')
    files = {'assets/' + p.as_posix(): s for p, s in sources.items()}
    for folder in ('effects', 'shaders', 'ui/fonts'):
        files.update({folder + '/' + p.as_posix(): s for p, s in build.files_under(args.project / folder)})
    # Match the export boundary: discarded vendor demos and backups are not payloads.
    files = {p: s for p, s in files.items() if not any(
        part in ('New folder', 'Demo_GodotVFX', 'backups', 'private', '.git', '.godot')
        or '.bak' in part or part.endswith(('.pem', '.key', '.p12', '.mobileprovision'))
        for part in Path(p).parts)}
    baseline = json.loads(args.baseline.read_text())
    previous = {entry['path']: entry['sha256'] for entry in baseline['entries']}
    entries = [{'path': p, 'bytes': s.stat().st_size, 'sha256': build.digest(s)}
               for p, s in sorted(files.items())]
    changed = [e for e in entries if previous.get(e['path']) != e['sha256']]
    removed = sorted(set(previous) - files.keys())
    commit = subprocess.check_output(['git', '-C', str(args.project), 'rev-parse', 'HEAD'], text=True).strip()
    args.out.mkdir(parents=True, exist_ok=True)
    manifest = {'commit': commit, 'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'baseline': args.baseline.name, 'baseline_sha256': build.digest(args.baseline),
                'entries': entries, 'removed_since_baseline': removed}
    manifest_path = args.out / ('Glory-resources-' + args.label + '.manifest.json')
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    archive_path = args.out / ('Glory-resources-incremental-' + args.label + '-' + commit[:8] + '.zip')
    with zipfile.ZipFile(archive_path, 'x', zipfile.ZIP_DEFLATED, compresslevel=3) as archive:
        for entry in changed:
            archive.write(files[entry['path']], entry['path'])
        archive.write(manifest_path, 'delivery/' + manifest_path.name)
        archive.writestr('delivery/README.txt',
            'Apply this delta after the baseline named in the manifest, over its paired GitHub commit.\n'
            'See removed_since_baseline in the included manifest; archive removed resources before deleting.\n'
            'Do not replace current source with the old Drive project tree.\n')
    with zipfile.ZipFile(archive_path) as archive:
        import hashlib
        for entry in changed:
            h = hashlib.sha256()
            with archive.open(entry['path']) as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''): h.update(block)
            if h.hexdigest() != entry['sha256']: raise RuntimeError('Archive verification failed: ' + entry['path'])
        if archive.testzip(): raise RuntimeError('Archive CRC verification failed')
    result = {'commit': commit, 'total_files': len(entries), 'changed_files': len(changed),
              'removed_files': removed, 'archive': archive_path.name,
              'bytes': archive_path.stat().st_size, 'sha256': build.digest(archive_path),
              'payload_sha256_verified': True, 'crc_verified': True}
    (args.out / 'resource-verification.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    (args.out / 'SHA256SUMS.txt').write_text(result['sha256'] + '  ' + archive_path.name + '\n' +
        build.digest(manifest_path) + '  ' + manifest_path.name + '\n')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
