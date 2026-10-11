"""Real-engine proof: patched autoloads compile only after the update gate.

GODOT_BIN=/path/to/Godot python -m unittest discover -s tools/workspace
    -p test_patch_bootstrap.py
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


class DeferredAutoloadTest(unittest.TestCase):
    def test_patch_precedes_typed_singleton_dependency_and_ready(self):
        godot = os.environ.get("GODOT_BIN") or shutil.which("godot")
        if not godot:
            self.skipTest("GODOT_BIN is required for real engine verification")
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "project.godot").write_text('''config_version=5
[application]
config/name="Patch bootstrap contract"
[autoload]
ProbeSingleton="*res://placeholder.tscn"
ConsumerSingleton="*res://placeholder.tscn"
''')
            (root / "placeholder.tscn").write_text('[gd_scene format=3]\n[node name="Placeholder" type="Node"]\n')
            (root / "service.gd").write_text('extends Node\nfunc get_value() -> int:\n return 1\n')
            (root / "consumer.gd").write_text('''extends Node
var observed := 0
func _ready():
 var answer := ProbeSingleton.get_value()
 observed = answer
''')
            with zipfile.ZipFile(root / "patch.zip", "w") as pack:
                pack.writestr("service.gd", 'extends Node\nfunc get_value() -> int:\n return 42\n')
            (root / "probe.gd").write_text('''extends SceneTree
func _initialize():
 call_deferred("verify")
func verify():
 var first = root.get_node("ProbeSingleton")
 var second = root.get_node("ConsumerSingleton")
 if first.get_script() != null or second.get_script() != null:
  quit(2)
  return
 if not ProjectSettings.load_resource_pack("res://patch.zip"):
  quit(3)
  return
 root.remove_child(first)
 root.remove_child(second)
 ProjectSettings.set_setting("autoload/ProbeSingleton", "*res://service.gd")
 ProjectSettings.set_setting("autoload/ConsumerSingleton", "*res://consumer.gd")
 first.set_script(load("res://service.gd"))
 second.set_script(load("res://consumer.gd"))
 first.request_ready()
 second.request_ready()
 root.add_child(first)
 root.add_child(second)
 if second.get("observed") != 42:
  quit(4)
  return
 print("PATCH_BEFORE_AUTOLOAD_PASS")
 quit(0)
''')
            result = subprocess.run([godot, "--headless", "--path", folder, "--script", "res://probe.gd"],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PATCH_BEFORE_AUTOLOAD_PASS", result.stdout)
            self.assertNotIn("SCRIPT ERROR", result.stderr)


if __name__ == "__main__":
    unittest.main()
