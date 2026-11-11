import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

from export_patch import export, verify_pack_export, digest


class PackExportDiagnosticTests(unittest.TestCase):
    leak = "ERROR: 9 RID allocations of type 'N13RendererDummy15MaterialStorage11DummyShaderE' were leaked at exit."

    def test_known_shutdown_leak_after_completed_zip_is_recorded(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            verify_pack_export("[ DONE ] savezip\n" + self.leak, root)
            record = json.loads((root / "export-diagnostics.json").read_text())
            self.assertEqual(record["host_shutdown_diagnostics"], [self.leak])

    def test_host_cleanup_requires_completed_export(self):
        from glory_build import verify_export_diagnostics
        diagnostics = [
            "ERROR: 90 resources still in use at exit (run with --verbose for details).",
            "ERROR: Pages in use exist at exit in PagedAllocator: N12VariantPools11BucketSmallE",
            "ERROR: 1 RID allocations of type 'PN13RendererDummy14TextureStorage12DummyTextureE' were leaked at exit.",
        ]
        with tempfile.TemporaryDirectory() as folder:
            for verify, marker in [(verify_pack_export, "savezip"), (verify_export_diagnostics, "export")]:
                for line in diagnostics:
                    verify("[ DONE ] " + marker + "\n" + line, Path(folder))
                    with self.assertRaises(RuntimeError):
                        verify(line + "\n[ DONE ] " + marker, Path(folder))
                with self.assertRaises(RuntimeError):
                    verify("[ DONE ] " + marker + "\nERROR: Cannot save resource", Path(folder))

    def test_incomplete_or_early_leak_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            for text in (self.leak, self.leak + "\n[ DONE ] savezip"):
                with self.subTest(text=text), self.assertRaises(RuntimeError):
                    verify_pack_export(text, Path(folder))

    def test_other_error_after_completion_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(RuntimeError):
                verify_pack_export("[ DONE ] savezip\nERROR: Cannot save resource", Path(folder))


class ActualPlatformExportTests(unittest.TestCase):
    def test_exported_bytecode_patch_overrides_original_base(self):
        self.verify_platform("windows", "Windows Desktop")

    def test_android_exported_bytecode_patch(self):
        self.verify_platform("android", "Android")

    def test_ios_exported_bytecode_patch(self):
        self.verify_platform("ios", "iOS")

    def test_android_debug_base_and_retention(self):
        self.verify_platform("android", "Android", debug=True)

    def verify_platform(self, platform, platform_name, debug=False):
        engine = os.environ.get("GODOT_BIN")
        if not engine:
            self.skipTest("GODOT_BIN required")
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            stage = root / "stage"
            stage.mkdir()
            (stage / "project.godot").write_text('''config_version=5
[application]
config/name="Patch export probe"
run/main_scene="res://main.tscn"
[autoload]
ProbeSingleton="*res://service.gd"
[rendering]
renderer/rendering_method="gl_compatibility"
''')
            (stage / "main.tscn").write_text('[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://consumer.gd" id="1"]\n[node name="Main" type="Node"]\nscript=ExtResource("1")\n')
            (stage / "consumer.gd").write_text('extends Node\nfunc sample():\n var inferred := ProbeSingleton.value()\n return inferred\n')
            (stage / "service.gd").write_text('extends Node\nfunc value() -> int:\n return 1\n')
            (stage / "ui/fonts").mkdir(parents=True)
            source = Path(__file__).resolve().parents[2]
            for name in ("NotoSansSC-Regular.otf", "NotoSansSC-OFL.txt"):
                shutil.copy2(source / "ui/fonts" / name, stage / "ui/fonts" / name)
            (stage / "export_presets.cfg").write_text('''[preset.0]
name="PatchFixture"
platform="%s"
export_filter="all_resources"
include_filter=""
exclude_filter=""
script_export_mode=2
[preset.0.options]
binary_format/architecture="x86_64"
''' % platform_name)
            config = root / "config.json"
            config.write_text(json.dumps({"base_id": "test-base", "channel": "internal",
                "backend_url": "https://example.com", "firebase_host": "example.web.app"}))
            (stage / 'assets').mkdir()
            art = '<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"><rect width="2" height="2" fill="red"/></svg>'
            for name in ('old', 'reactivated', 'unused'):
                (stage / 'assets' / (name + '.svg')).write_text(art)
            (stage / 'scripts').mkdir()
            (stage / 'scripts/art.gd').write_text('extends Node\nconst ART = "res://assets/old.svg"\n')
            options = dict(stage=stage, engine=Path(engine), preset="PatchFixture", platform=platform, config=config, debug=debug)
            if debug:
                from glory_build import retain_patch_base
                application = root / "fixture.apk"
                application.write_bytes(b"native package fixture")
                retained = retain_patch_base(stage, Path(engine), "PatchFixture", platform, config,
                    root / "original", application, debug=True)
                record = json.loads(Path(retained["manifest"]).read_text())
                self.assertEqual(record["application_sha256"], digest(application))
                with self.assertRaisesRegex(ValueError, "original base changed"):
                    export(**{**options, "debug": False}, output=root / "wrong-mode", base=root / "original/base.zip")
            else:
                export(**options, output=root / "original")
            base_hash = digest(root / 'original/base.zip')
            with zipfile.ZipFile(root / "original/base.zip") as pack:
                self.assertIn('assets/old.svg.import', pack.namelist())
                self.assertNotIn('assets/unused.svg.import', pack.namelist())
                self.assertNotIn('assets/reactivated.svg.import', pack.namelist())
                self.assertIn(b'AutoloadPlaceholder.tscn', pack.read('override.cfg'))
                pack.extractall(root / "installed")
            (root / "runtime_probe.gd").write_text('''extends SceneTree
func _initialize():
 call_deferred("verify")
func verify():
 var singleton = root.get_node("ProbeSingleton")
 if singleton.get_script() != null:
  quit(8)
  return
 ProjectSettings.set_setting("autoload/ProbeSingleton", "*res://service.gd")
 singleton.set_script(load("res://service.gd"))
 var consumer = load("res://main.tscn").instantiate()
 if consumer.sample() != 1:
  quit(9)
  return
 consumer.free()
 print("EXPORTED_DEFERRED_AUTOLOAD_PASS")
 quit()
''')
            installed = subprocess.run([engine, "--headless", "--path", str(root / "installed"),
                "--script", str(root / "runtime_probe.gd")], capture_output=True, text=True, timeout=30)
            self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
            self.assertIn("EXPORTED_DEFERRED_AUTOLOAD_PASS", installed.stdout)
            self.assertNotIn("SCRIPT ERROR", installed.stderr)
            (stage / "service.gd").write_text('extends Node\nfunc value() -> int:\n return 42\n')
            (stage / 'scripts/art.gd').write_text('extends Node\nconst ART = "res://assets/reactivated.svg"\n')
            report = export(**options, output=root / "updated", base=root / "original/base.zip")
            self.assertEqual(digest(root / 'original/base.zip'), base_hash)
            slim = json.loads(Path(report['slim_report']).read_text())
            self.assertIn('assets/old.svg', slim['removed_source_paths'])
            self.assertIn('assets/unused.svg', slim['removed_source_paths'])
            self.assertNotIn('assets/reactivated.svg', slim['removed_source_paths'])
            self.assertIn("service.gdc", report["files"])
            with zipfile.ZipFile(root / "updated" / (platform + ".zip")) as pack:
                self.assertNotIn("project.binary", pack.namelist())
                self.assertIn('assets/reactivated.svg.import', pack.namelist())
                self.assertNotIn('assets/old.svg.import', pack.namelist())
                self.assertNotIn('assets/unused.svg.import', pack.namelist())
            (stage / "probe.gd").write_text('''extends SceneTree
func _initialize():
 call_deferred("verify")
func verify():
 if not ProjectSettings.load_resource_pack("%s"):
  quit(2)
  return
 if not ProjectSettings.load_resource_pack("%s"):
  quit(3)
  return
 var value = load("res://service.gd").new().value()
 if value != 42:
  quit(4)
  return
 print("EXPORTED_PATCH_BYTECODE_PASS")
 quit()
''' % (root / "original/base.zip", root / "updated" / (platform + ".zip")))
            result = subprocess.run([engine, "--headless", "--path", str(stage), "--script", "res://probe.gd"],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("EXPORTED_PATCH_BYTECODE_PASS", result.stdout)
            # Reusing the stage must compare preset policy, not stale generated
            # exclusions; real preset option changes must still require a full build.
            cfg = stage / 'export_presets.cfg'
            original_preset = cfg.read_text()
            cfg.write_text(original_preset + '\ntextures/vram_compression/import_etc2_astc=true\n')
            with self.assertRaisesRegex(ValueError, 'original base changed'):
                export(**options, output=root / 'wrong-preset', base=root / 'original/base.zip')
            cfg.write_text(original_preset)
            (stage / 'service.gd').write_text('extends Node\nfunc value() -> int:\n return 43\n')
            (stage / 'scripts/art.gd').write_text('extends Node\nconst ART = "res://assets/old.svg"\n')
            again = export(**options, output=root / 'updated-again', base=root / 'original/base.zip')
            self.assertIn('service.gdc', again['files'])
            self.assertEqual(digest(root / 'original/base.zip'), base_hash)


if __name__ == "__main__":
    unittest.main()
