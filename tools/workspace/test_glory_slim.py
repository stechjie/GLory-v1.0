"""Resource reachability and lossless mobile packaging regressions."""
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile
from glory_slim import closure
from glory_package import compressed_native_manifest, rewrite_zip, verify_baseline


class ReachabilityTests(unittest.TestCase):
    def test_scene_texture_chain_and_unused_art(self):
        files = {'scenes/main.tscn', 'assets/unit.tscn', 'assets/body.png', 'assets/unused.png'}
        deps = {'scenes/main.tscn': ['uid://abc::PackedScene::res://assets/unit.tscn'],
                'assets/unit.tscn': ['res://assets/body.png']}
        seen, _ = closure(files, deps, {}, '')
        self.assertTrue({'assets/unit.tscn', 'assets/body.png'} <= seen)
        self.assertNotIn('assets/unused.png', seen)

    def test_dynamic_paths_keep_full_prefix_and_transitive_dependencies(self):
        files = {'scripts/catalog.gd', 'assets/units/a.tscn', 'assets/units/b.tscn', 'assets/texture.png', 'assets/old.png'}
        seen, _ = closure(files, {'assets/units/b.tscn': ['res://assets/texture.png']},
                          {'scripts/catalog.gd': 'load("res://assets/units/%s.tscn" % id)'}, '')
        self.assertIn('assets/texture.png', seen)
        self.assertIn('assets/units/a.tscn', seen)
        self.assertNotIn('assets/old.png', seen)

    def test_classifier_is_not_directory_load_but_real_root_is_retained(self):
        files = {'scripts/load.gd', 'assets/unused.png'}
        seen, _ = closure(files, {}, {'scripts/load.gd': 'p.begins_with("res://")'}, '')
        self.assertNotIn('assets/unused.png', seen)
        seen, _ = closure(files, {}, {'scripts/load.gd': 'DirAccess.open("res://")'}, '')
        self.assertIn('assets/unused.png', seen)

    def test_project_entrypoint_and_autoload_root(self):
        files = {'assets/boot.tscn', 'assets/boot.png'}
        seen, _ = closure(files, {'assets/boot.tscn': ['res://assets/boot.png']}, {},
                          'run/main_scene="res://assets/boot.tscn"')
        self.assertIn('assets/boot.png', seen)

    def test_unresolved_uid_stops_pruning(self):
        with self.assertRaises(RuntimeError):
            closure({'scenes/main.tscn'}, {'scenes/main.tscn': ['uid://missing']}, {}, '')

    def test_dynamic_manifest_keeps_non_ascii_files(self):
        files = {'data/__dynamic_assets__.json', 'assets/头像.png'}
        seen, _ = closure(files, {}, {'data/__dynamic_assets__.json': json.dumps(['assets/头像.png'], ensure_ascii=False)}, '')
        self.assertIn('assets/头像.png', seen)


class PackageTests(unittest.TestCase):
    def manifest(self, enabled):
        ids = struct.pack('<HHII', 0x180, 8, 12, 0x010104ea)
        # XML start element: 16-byte node + 20-byte extension + one attribute.
        attr = struct.pack('<IIIHBBI', 0xffffffff, 0, 0xffffffff, 8, 0, 0x12, enabled)
        element = struct.pack('<HHIII', 0x102, 16, 56, 1, 0xffffffff)
        element += struct.pack('<IIHHHHHH', 0xffffffff, 0, 20, 20, 1, 0, 0, 0) + attr
        return struct.pack('<HHI', 3, 8, 8+len(ids)+len(element)) + ids + element

    def test_manifest_conversion_is_idempotent(self):
        enabled = compressed_native_manifest(self.manifest(0))
        self.assertEqual(enabled, self.manifest(0xffffffff))
        self.assertEqual(compressed_native_manifest(enabled), enabled)

    def test_missing_extraction_attribute_fails(self):
        with self.assertRaises(ValueError):
            compressed_native_manifest(struct.pack('<HHI', 3, 8, 8))

    def test_baseline_content_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            base, apk = Path(tmp)/'base.zip', Path(tmp)/'app.apk'
            with zipfile.ZipFile(base, 'w') as z:
                z.writestr('resource.bin', b'correct')
            with zipfile.ZipFile(apk, 'w') as z:
                z.writestr('assets/resource.bin', b'correct')
            self.assertEqual(verify_baseline(apk, base, 'android')['identical_base_files'], 1)
            with zipfile.ZipFile(apk, 'w') as z:
                z.writestr('assets/resource.bin', b'changed')
            with self.assertRaisesRegex(RuntimeError, 'content mismatch'):
                verify_baseline(apk, base, 'android')

    def test_android_rewrite_keeps_arsc_stored_and_compresses_native(self):
        with tempfile.TemporaryDirectory() as tmp:
            src, dst = Path(tmp)/'old.apk', Path(tmp)/'new.apk'
            with zipfile.ZipFile(src, 'w') as z:
                z.writestr('AndroidManifest.xml', self.manifest(0))
                z.writestr('resources.arsc', b'arsc')
                z.writestr('lib/arm64-v8a/libgame.so', b'native'*100)
                z.writestr('META-INF/OLD.RSA', b'old signature')
            rewrite_zip(src, dst, android=True)
            with zipfile.ZipFile(dst) as z:
                self.assertEqual(z.getinfo('resources.arsc').compress_type, zipfile.ZIP_STORED)
                self.assertEqual(z.getinfo('lib/arm64-v8a/libgame.so').compress_type, zipfile.ZIP_DEFLATED)
                self.assertEqual(z.read('lib/arm64-v8a/libgame.so'), b'native'*100)
                self.assertNotIn('META-INF/OLD.RSA', z.namelist())
                self.assertEqual(z.read('AndroidManifest.xml'), self.manifest(0xffffffff))

    def test_ipa_zip_keeps_signature_bytes_and_symlink_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            src, dst = Path(tmp)/'old.ipa', Path(tmp)/'new.ipa'
            link = zipfile.ZipInfo('Payload/Game.app/link')
            link.create_system = 3
            link.external_attr = 0o120777 << 16
            with zipfile.ZipFile(src, 'w') as z:
                z.writestr('Payload/Game.app/_CodeSignature/CodeResources', b'signed bytes'*100)
                z.writestr('Payload/Game.app/中文.png', b'image'*100)
                z.writestr(link, b'target')
            rewrite_zip(src, dst)
            with zipfile.ZipFile(src) as a, zipfile.ZipFile(dst) as b:
                self.assertEqual(a.namelist(), b.namelist())
                for name in a.namelist():
                    self.assertEqual(a.read(name), b.read(name))
                    self.assertEqual(a.getinfo(name).external_attr, b.getinfo(name).external_attr)
            self.assertLess(dst.stat().st_size, src.stat().st_size)

if __name__ == '__main__':
    unittest.main()
