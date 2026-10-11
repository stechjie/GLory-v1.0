"""Exercise delayed HTTP snapshots against newer live deployment/publication events."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class SnapshotOrderTests(unittest.TestCase):
    def test_failed_new_epoch_and_patch_block_never_restore_old_effects(self):
        engine = os.environ.get("GODOT_BIN") or shutil.which("godot")
        if not engine:
            self.skipTest("GODOT_BIN required")
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "patcher").mkdir()
            source = Path(__file__).resolve().parents[2]
            for name in ("HotfixAgent.gd", "HotfixRuntime.gd", "HotfixContext.gd"):
                shutil.copy2(source / "patcher" / name, root / "patcher" / name)
            (root / "project.godot").write_text('config_version=5\n')
            (root / "agent.gd").write_text('''extends "res://patcher/HotfixAgent.gd"
func _ready():
 _boot = {"channel":"stable", "platform":"android", "base_id":"base"}
 _runtime = Runtime.new()
 add_child(_runtime)
''')
            (root / "probe.gd").write_text('''extends SceneTree
var failed := false
func _initialize():
 call_deferred("verify")
func check(value, label):
 if not value:
  failed = true
  print("FAIL: ", label)
func snapshot(revision, epoch, items, seq=0):
 return {"protocol":1, "channel":"stable", "platform":"android", "base_id":"base",
  "deployment_id":"account", "revision":revision, "hotfix_epoch":epoch,
  "required_patch_seq":seq, "action":"none", "hotfixes":items}
func verify():
 var button = Button.new()
 button.name = "TestButton"
 root.add_child(button)
 var agent = load("res://agent.gd").new()
 root.add_child(agent)
 var source = "extends RefCounted\\nfunc apply(ctx) -> bool:\\n return ctx.set_node_property(\\"/root/TestButton\\", \\"visible\\", false)\\n"
 var hide = {"hotfix_id":"hide", "source":source, "sha256":source.sha256_text()}
 agent._apply(snapshot(1, 1, [hide]))
 check(not button.visible, "initial hotfix")
 var bad = hide.duplicate()
 bad.sha256 = "invalid"
 agent._apply(snapshot(10, 2, [bad]))
 check(button.visible, "new epoch clears even on failed apply")
 agent._apply(snapshot(9, 1, [hide]))
 check(button.visible, "delayed old HTTP response stays rejected")
 agent._apply(snapshot(10, 2, [hide]))
 check(not button.visible, "same revision can retry successfully")
 agent._apply(snapshot(11, 3, [], 1))
 check(button.visible and paused and agent._blocked, "new patch blocks and clears")
 var count = agent.get_child_count()
 agent._apply(snapshot(12, 3, [hide]))
 agent._block_for_patch()
 check(button.visible and agent.get_child_count() == count, "blocked client never reinstalls code or duplicates overlay")
 paused = false
 print("HOTFIX_SNAPSHOT_ORDER_PASS" if not failed else "HOTFIX_SNAPSHOT_ORDER_FAIL")
 quit(1 if failed else 0)
''')
            result = subprocess.run([engine, "--headless", "--path", folder, "--script", "res://probe.gd"],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("HOTFIX_SNAPSHOT_ORDER_PASS", result.stdout)
            self.assertNotIn("SCRIPT ERROR", result.stderr)


if __name__ == "__main__":
    unittest.main()
