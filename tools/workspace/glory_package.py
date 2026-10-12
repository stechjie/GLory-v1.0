"""Lossless ZIP compression and release signing for generated mobile packages."""
from pathlib import Path
import copy
import os
import struct
import subprocess
import zipfile


def compressed_native_manifest(data):
    """Enable Android extraction when shipping deflated .so files (binary AXML)."""
    buf = bytearray(data)
    if len(buf) < 8 or struct.unpack_from('<HHI', buf)[0] != 3:
        raise ValueError('Expected Android binary XML')
    offset, resource_ids, found = 8, [], 0
    while offset < len(buf):
        kind, header, size = struct.unpack_from('<HHI', buf, offset)
        if size < header or header < 8 or offset + size > len(buf):
            raise ValueError('Invalid AXML chunk')
        if kind == 0x180:
            resource_ids = list(struct.unpack_from('<' + 'I' * ((size-header)//4), buf, offset+header))
        if kind == 0x102:
            start, stride, count = struct.unpack_from('<HHH', buf, offset+header+8)
            if stride < 20 or header+start+stride*count > size:
                raise ValueError('Invalid AXML attributes')
            for i in range(count):
                pos = offset+header+start+i*stride
                name = struct.unpack_from('<I', buf, pos+4)[0]
                if name < len(resource_ids) and resource_ids[name] == 0x010104ea:
                    if buf[pos+15] != 0x12:
                        raise ValueError('extractNativeLibs must be boolean')
                    struct.pack_into('<I', buf, pos+16, 0xffffffff)
                    found += 1
        offset += size
    if found != 1:
        raise ValueError('Expected one explicit extractNativeLibs attribute')
    return bytes(buf)


def rewrite_zip(source, target, android=False):
    """Preserve file bytes, permissions and symlinks; compression is ZIP-only."""
    with zipfile.ZipFile(source) as old, zipfile.ZipFile(target, 'w') as new:
        names = set()
        for original in old.infolist():
            info = copy.copy(original)
            if android and info.filename.startswith('META-INF/') and info.filename.upper().endswith(('.MF', '.SF', '.RSA', '.DSA', '.EC')):
                continue
            data = old.read(original)
            # Godot sometimes writes UTF-8 names without the ZIP UTF-8 flag.
            if not info.flag_bits & 0x800:
                try:
                    info.filename = info.filename.encode('cp437').decode('utf-8')
                except (UnicodeEncodeError, UnicodeDecodeError):
                    pass
            if info.filename in names:
                raise ValueError('Duplicate ZIP path: ' + info.filename)
            names.add(info.filename)
            if android and info.filename == 'AndroidManifest.xml':
                data = compressed_native_manifest(data)
            compression = info.compress_type
            if not android or info.filename.startswith(('assets/', 'lib/')):
                compression = zipfile.ZIP_DEFLATED
            # Android resources.arsc and other alignment-sensitive entries retain
            # their original stored mode. zipalign runs after this transformation.
            new.writestr(info, data, compress_type=compression, compresslevel=9)
    with zipfile.ZipFile(target) as check:
        if check.testzip():
            raise RuntimeError('Recompressed package failed CRC verification')


def compact_ipa(ipa):
    target = ipa.with_suffix('.compressed.ipa')
    before = ipa.stat().st_size
    rewrite_zip(ipa, target)
    if target.stat().st_size < before:
        os.replace(target, ipa)
    else:
        target.unlink()
    return {'before_bytes': before, 'after_bytes': ipa.stat().st_size, 'file_contents_changed': False}


def sign_apk(apk, build_tools, keystore, child_env, logdir):
    from glory_aab_build import signing_password
    password = signing_password()
    if not password or not Path(keystore).is_file():
        raise RuntimeError('Release signing key unavailable; no debug-key fallback')
    env = dict(child_env, GLORY_KEYSTORE_PASSWORD=password,
               GLORY_KEY_PASSWORD=os.environ.get('GLORY_KEY_PASSWORD', password))
    compact, aligned, signed = (logdir / n for n in ('compact.apk', 'aligned.apk', 'signed.apk'))
    before = apk.stat().st_size
    rewrite_zip(apk, compact, android=True)
    def run(args):
        subprocess.run([str(x) for x in args], env=env, check=True, capture_output=True)
    run([build_tools/'zipalign', '-P', '16', '-f', '4', compact, aligned])
    run([build_tools/'apksigner', 'sign', '--ks', keystore, '--ks-pass', 'env:GLORY_KEYSTORE_PASSWORD',
         '--key-pass', 'env:GLORY_KEY_PASSWORD', '--out', signed, aligned])
    run([build_tools/'apksigner', 'verify', '--verbose', signed])
    run([build_tools/'zipalign', '-c', '-P', '16', '4', signed])
    os.replace(signed, apk)
    compact.unlink()
    aligned.unlink()
    return {'before_bytes': before, 'after_bytes': apk.stat().st_size,
            'native_extraction': True, 'zip_alignment_kib': 16}


def verify_baseline(application, baseline, platform):
    """Compare every retained patch-base byte against the actual mobile payload."""
    import hashlib
    import shutil
    import tempfile
    def md5(stream, size=None):
        digest = hashlib.md5()
        remaining = size
        while remaining is None or remaining:
            blob = stream.read(1048576 if remaining is None else min(1048576, remaining))
            if not blob:
                if remaining:
                    raise RuntimeError('Truncated package payload')
                break
            digest.update(blob)
            if remaining is not None:
                remaining -= len(blob)
        return digest.digest()
    with zipfile.ZipFile(baseline) as base, zipfile.ZipFile(application) as app:
        expected = {}
        for info in base.infolist():
            if not info.is_dir():
                with base.open(info) as stream:
                    expected[info.filename] = (info.file_size, md5(stream))
        if platform == 'android':
            entries = {}
            for info in app.infolist():
                name = info.filename
                if not info.flag_bits & 0x800:
                    try:
                        name = name.encode('cp437').decode('utf-8')
                    except (UnicodeEncodeError, UnicodeDecodeError):
                        pass
                if name in entries:
                    raise RuntimeError('Duplicate APK resource path')
                entries[name] = info
            for name, (size, digest) in expected.items():
                path = 'assets/' + name
                if entries[path].file_size != size:
                    raise RuntimeError('APK/base size mismatch: ' + name)
                with app.open(entries[path]) as stream:
                    if md5(stream) != digest:
                        raise RuntimeError('APK/base content mismatch: ' + name)
        elif platform == 'ios':
            packs = [n for n in app.namelist() if n.startswith('Payload/') and n.endswith('.pck')]
            if len(packs) != 1:
                raise RuntimeError('Expected one iOS resource PCK')
            with tempfile.TemporaryFile() as stream:
                with app.open(packs[0]) as source:
                    shutil.copyfileobj(source, stream)
                stream.seek(0)
                magic, version, *_engine, flags = struct.unpack('<6I', stream.read(24))
                if magic != 0x43504447 or version not in (3, 4) or flags & 1:
                    raise RuntimeError('Unsupported/encrypted PCK')
                offset_base, directory = struct.unpack('<QQ', stream.read(16))
                stream.seek(directory)
                count = struct.unpack('<I', stream.read(4))[0]
                entries = {}
                for _ in range(count):
                    length = struct.unpack('<I', stream.read(4))[0]
                    name = stream.read(length).rstrip(b'\0').decode().removeprefix('res://')
                    offset, size = struct.unpack('<QQ', stream.read(16))
                    checksum = stream.read(16)
                    file_flags = struct.unpack('<I', stream.read(4))[0]
                    if name in entries or file_flags:
                        raise RuntimeError('Duplicate or encrypted/removed PCK entry')
                    entries[name] = (offset_base+offset, size, checksum)
                for name, (size, digest) in expected.items():
                    offset, actual_size, checksum = entries[name]
                    stream.seek(offset)
                    if actual_size != size or checksum != digest or md5(stream, size) != digest:
                        raise RuntimeError('IPA/base content mismatch: ' + name)
        else:
            raise ValueError('Unsupported mobile platform')
    return {'identical_base_files': len(expected), 'platform': platform, 'payload_matches_baseline': True}
