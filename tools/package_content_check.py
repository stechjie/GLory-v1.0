#!/usr/bin/env python3
"""Reject development artifacts in APKs or Godot 4.7 (PCK v4) IPAs/packs.

Native IPA signing files are not game resources and are deliberately not scanned.
QA scenes are reported, not rejected: DeviceHarness currently depends on them.
"""
import argparse
import json
import struct
import zipfile
from pathlib import Path

BLOCKED = {'Claude outputs', 'art_source', 'A4_device_battle_20260820',
           'tools', 'officetest', 'reports', 'docs', 'logs', 'backups', 'backend', 'work'}


def pck_paths(stream):
    header = stream.read(40)
    if len(header) != 40 or header[:4] != b'GDPC':
        raise ValueError('Not a Godot pack')
    version = struct.unpack_from('<I', header, 4)[0]
    flags = struct.unpack_from('<I', header, 20)[0]
    if version != 4 or flags & 1:
        raise ValueError('Only unencrypted PCK v4 is supported')
    stream.seek(struct.unpack_from('<Q', header, 32)[0])
    count, = struct.unpack('<I', stream.read(4))
    for _ in range(count):
        length, = struct.unpack('<I', stream.read(4))
        if length > 1048576:
            raise ValueError('Invalid pack path length')
        path = stream.read(length).rstrip(b'\0').decode('utf-8')
        if len(stream.read(36)) != 36:
            raise ValueError('Truncated pack index')
        yield path.removeprefix('res://')


def paths(package):
    if package.suffix.lower() == '.pck':
        with package.open('rb') as stream:
            return list(pck_paths(stream))
    with zipfile.ZipFile(package) as archive:
        if package.suffix.lower() == '.apk':
            return [n.removeprefix('assets/') for n in archive.namelist() if n.startswith('assets/')]
        packs = [n for n in archive.namelist() if n.endswith('.pck')]
        if not packs:
            raise ValueError('IPA contains no PCK; cannot verify game content')
        result = []
        for name in packs:
            with archive.open(name) as stream:
                result.extend(pck_paths(stream))
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    args = parser.parse_args()
    entries = paths(args.package)
    if not entries:
        raise ValueError('Empty game resource inventory')
    bad = [p for p in entries if p.split('/')[0] in BLOCKED or p.startswith('review_')]
    result = {'passed': not bad, 'entries': len(entries), 'rejected': bad,
              'qa_entries': [p for p in entries if p.startswith('scripts/qa/')]}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 1 if bad else 0


if __name__ == '__main__':
    raise SystemExit(main())
