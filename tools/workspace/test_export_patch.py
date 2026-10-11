import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

from export_patch import export


class ActualPlatformExportTests(unittest.TestCase):
    def test_exported_bytecode_patch_overrides_original_base(self):
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
            (stage / "main.tscn").write_text('[gd_scene format=3]\n[node name="Main" type="Node"]\n')
            (stage / "service.gd").write_text('extends Node\nfunc value() -> int:\n return 1\n')
            (stage / "ui/fonts").mkdir(parents=True)
            source = Path(__file__).resolve().parents[2]
            for name in ("NotoSansSC-Regular.otf", "NotoSansSC-OFL.txt"):
                shutil.copy2(source / "ui/fonts" / name, stage / "ui/fonts" / name)
            (stage / "export_presets.cfg").write_text('''[preset.0]
name="Windows"
platform="Windows Desktop"
export_filter="all_resources"
include_filter=""
exclude_filter=""
script_export_mode=2
[preset.0.options]
binary_format/architecture="x86_64"
''')
            config = root / "config.json"
            config.write_text(json.dumps({"base_id": "test-base", "channel": "internal",
                "backend_url": "https://example.com", "firebase_host": "example.web.app"}))
            options = dict(stage=stage, engine=Path(engine), preset="Windows", platform="windows", config=config)
            export(**options, output=root / "original")
            (stage / "service.gd").write_text('extends Node\nfunc value() -> int:\n return 42\n')
            report = export(**options, output=root / "updated", base=root / "original/base.zip")
            self.assertIn("service.gdc", report["files"])
            with zipfile.ZipFile(root / "updated/windows.zip") as pack:
                self.assertNotIn("project.binary", pack.namelist())
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
''' % (root / "original/base.zip", root / "updated/windows.zip"))
            result = subprocess.run([engine, "--headless", "--path", str(stage), "--script", "res://probe.gd"],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("EXPORTED_PATCH_BYTECODE_PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
