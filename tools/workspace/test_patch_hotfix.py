"""Real Godot runtime test: reversible live UI code, including future scenes."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class HotfixEngineTests(unittest.TestCase):
    def test_battle_boss_data_changes_live_and_reverts(self):
        godot = os.environ.get("GODOT_BIN") or shutil.which("godot")
        if not godot:
            self.skipTest("GODOT_BIN required")
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "patcher").mkdir()
            source = Path(__file__).resolve().parents[2]
            for name in ("HotfixRuntime.gd", "HotfixContext.gd"):
                shutil.copy2(source / "patcher" / name, root / "patcher" / name)
            shutil.copy2(source / "scripts/multiplayer/BattleHotfixContext.gd", root / "BattleContext.gd")
            shutil.copy2(source / "data/boss/bosses.json", root / "bosses.json")
            (root / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Battle hotfix test"\n[autoload]\nDataRegistry="*res://registry.gd"\n')
            (root / "registry.gd").write_text('extends Node\nvar data=JSON.parse_string(FileAccess.get_file_as_string("res://bosses.json"))\nfunc get_table(_key):\n return data\n')
            (root / "probe.gd").write_text('''extends SceneTree
func _initialize():
 call_deferred("verify")
func verify():
 var runtime = load("res://patcher/HotfixRuntime.gd").new()
 runtime.context_script = load("res://BattleContext.gd")
 root.add_child(runtime)
 var boss = root.get_node("DataRegistry").get_table("bosses").bosses[0]
 var original = int(boss.hp)
 var source = "extends RefCounted\\nfunc apply(ctx) -> bool:\\n var boss=ctx.table(\\"bosses\\").bosses[0]\\n return ctx.replace_item(boss, \\"hp\\", int(boss.hp / 2))\\n"
 if not runtime.replace([{"hotfix_id":"boss", "source":source, "sha256":source.sha256_text()}]):
  quit(2)
  return
 if int(boss.hp) != original / 2:
  quit(3)
  return
 runtime.clear()
 if int(boss.hp) != original:
  quit(4)
  return
 print("BATTLE_BOSS_HOTFIX_REVERT_PASS")
 quit()
''')
            result = subprocess.run([godot, "--headless", "--path", folder, "--script", "res://probe.gd"],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("BATTLE_BOSS_HOTFIX_REVERT_PASS", result.stdout)
            self.assertNotIn("SCRIPT ERROR", result.stderr)

    def test_existing_future_nodes_and_failed_apply_rollback(self):
        godot = os.environ.get("GODOT_BIN") or shutil.which("godot")
        if not godot:
            self.skipTest("GODOT_BIN required")
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "patcher").mkdir()
            source_root = Path(__file__).resolve().parents[2]
            for name in ("HotfixContext.gd", "HotfixRuntime.gd"):
                shutil.copy2(source_root / "patcher" / name, root / "patcher" / name)
            (root / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Hotfix test"\n')
            (root / "probe.gd").write_text('''extends SceneTree
func _initialize():
 call_deferred("verify")
func item(id, source):
 return {"hotfix_id": id, "source": source, "sha256": source.sha256_text()}
func verify():
 var runtime = load("res://patcher/HotfixRuntime.gd").new()
 root.add_child(runtime)
 var first = Button.new()
 first.name = "TestFirst"
 root.add_child(first)
 var code = "extends RefCounted\\nfunc apply(ctx) -> bool:\\n return ctx.set_node_property(\\"/root/Test*\\", \\"visible\\", false)\\n"
 if not runtime.replace([item("hide", code)]) or first.visible:
  quit(2)
  return
 var second = Button.new()
 second.name = "TestSecond"
 root.add_child(second)
 await process_frame
 await process_frame
 if second.visible:
  quit(3)
  return
 var bad = "extends RefCounted\\nfunc apply(ctx) -> bool:\\n ctx.set_node_property(\\"/root/Test*\\", \\"visible\\", true)\\n return false\\n"
 if runtime.replace([item("bad", bad)]) or first.visible or second.visible:
  quit(4)
  return
 if not runtime.replace([]) or not first.visible or not second.visible:
  quit(5)
  return
 print("HOTFIX_LIVE_AND_REVERT_PASS")
 quit(0)
''')
            result = subprocess.run([godot, "--headless", "--path", folder, "--script", "res://probe.gd"],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("HOTFIX_LIVE_AND_REVERT_PASS", result.stdout)
            self.assertNotIn("SCRIPT ERROR", result.stderr)


if __name__ == "__main__":
    unittest.main()
