"""Local structural checks; no claim of Play review or device acceptance."""
import argparse, json, pathlib, struct, subprocess, sys, zipfile, xml.etree.ElementTree as ET
import glory_build as b
root = b.ROOT / 'build/aab'
aab = pathlib.Path(sys.argv[1]).resolve()
env = b.environment(argparse.Namespace(godot=None, java_home=None, android_sdk=None, templates=None))
java = str(env['java'] / 'bin/java')
candidates = sorted((root / 'tools').glob('bundletool-all-*.jar'))
if not candidates:
    raise RuntimeError('Missing bundletool: place the official bundletool-all JAR in build/aab/tools')
jar = candidates[-1]
report = root / 'verification' / aab.stem
report.mkdir(parents=True, exist_ok=True)

def bt(*args):
    r = subprocess.run([java, '-jar', str(jar), *args, '--bundle=' + str(aab)], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stdout + r.stderr)
    return r.stdout
validation = bt('validate')
(report / 'bundletool-validate.txt').write_text(validation)
manifest = bt('dump', 'manifest', '--module=base')
(report / 'manifest.xml').write_text(manifest)
config = bt('dump', 'config')
(report / 'bundle-config.json').write_text(config)
if not json.loads(config)['optimizations']['uncompressNativeLibraries']['alignment'] == 'PAGE_ALIGNMENT_16K':
    raise RuntimeError("AAB validation failed: json.loads(config)['optimizations']['uncompressNativeLibraries']['alignment'] == 'PAGE_ALIGNMENT_16K'")
ns = '{http://schemas.android.com/apk/res/android}'
m = ET.fromstring(manifest)
sdk = m.find('uses-sdk')
app = m.find('application')
if not m.attrib['package'] == 'com.glory.game.google':
    raise RuntimeError("AAB validation failed: m.attrib['package'] == 'com.glory.game.google'")
if not int(sdk.attrib[ns + 'targetSdkVersion']) >= 36:
    raise RuntimeError("AAB validation failed: int(sdk.attrib[ns + 'targetSdkVersion']) >= 36")
if not app.attrib.get(ns + 'debuggable', 'false') == 'false':
    raise RuntimeError("AAB validation failed: app.attrib.get(ns + 'debuggable', 'false') == 'false'")
permissions = [n.attrib[ns + 'name'] for n in m.findall('uses-permission')]
if not 'android.permission.INTERNET' in permissions:
    raise RuntimeError("AAB validation failed: 'android.permission.INTERNET' in permissions")
if not 'android.permission.RECORD_AUDIO' in permissions:
    raise RuntimeError("AAB validation failed: 'android.permission.RECORD_AUDIO' in permissions")
if not not {'android.permission.CAMERA', 'android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION'} & set(permissions):
    raise RuntimeError("AAB validation failed: not {'android.permission.CAMERA', 'android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION'} & set(permissions)")
modules = {}
elf = []
with zipfile.ZipFile(aab) as z:
    for i in z.infolist():
        mod = i.filename.split('/')[0]
        totals = modules.setdefault(mod, {'zip_compressed_bytes': 0, 'uncompressed_bytes': 0})
        totals['zip_compressed_bytes'] += i.compress_size
        totals['uncompressed_bytes'] += i.file_size
        if i.filename.endswith('.so'):
            data = z.read(i)
            if not data[:4] == b'\x7fELF':
                raise RuntimeError("AAB validation failed: data[:4] == b'\\x7fELF'")
            bits = data[4]
            order = '<' if data[5] == 1 else '>'
            if bits == 2:
                off = struct.unpack_from(order + 'Q', data, 32)[0]
                (size, num) = struct.unpack_from(order + 'HH', data, 54)
            else:
                off = struct.unpack_from(order + 'I', data, 28)[0]
                (size, num) = struct.unpack_from(order + 'HH', data, 42)
            align = []
            for n in range(num):
                pos = off + n * size
                if struct.unpack_from(order + 'I', data, pos)[0] == 1:
                    align.append(struct.unpack_from(order + ('Q' if bits == 2 else 'I'), data, pos + (48 if bits == 2 else 28))[0])
            ok = bool(align) and min(align) >= 16384
            elf.append({'library': i.filename, 'load_segment_alignments': align, 'aligned_16kb': ok})
    if not all((x['aligned_16kb'] for x in elf if '/arm64-v8a/' in x['library'])):
        raise RuntimeError('64-bit ELF alignment failure')
summary = {'aab': str(aab), 'bundletool_valid': True, 'package': m.attrib['package'], 'version_code': m.attrib[ns + 'versionCode'], 'version_name': m.attrib[ns + 'versionName'], 'min_sdk': sdk.attrib[ns + 'minSdkVersion'], 'target_sdk': sdk.attrib[ns + 'targetSdkVersion'], 'debuggable': False, 'permissions': permissions, 'modules': modules, 'native_libraries': elf, 'play_uploaded': False, 'device_tested': False, 'note': 'ZIP compression sizes are not Play download size estimates.'}
(report / 'result.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
print('AAB structural, permission, Release-mode and ARM64 alignment checks passed:', report)
