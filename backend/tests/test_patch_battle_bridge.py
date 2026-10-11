import asyncio
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

from app.patch_service import PatchService


class BattleBridgeTests(unittest.TestCase):
    def test_real_battle_admission_rechecks_rules_without_waiting_for_tick(self):
        engine = os.environ.get("GODOT_BIN")
        if not engine:
            self.skipTest("GODOT_BIN required")
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "scripts/multiplayer").mkdir(parents=True)
            (root / "patcher").mkdir()
            (root / "data").mkdir()
            source = Path(__file__).resolve().parents[2]
            for name in ("HotfixRuntime.gd", "HotfixContext.gd"):
                shutil.copy2(source / "patcher" / name, root / "patcher" / name)
            for name in ("BattleHotfixAgent.gd", "BattleHotfixContext.gd"):
                shutil.copy2(source / "scripts/multiplayer" / name, root / "scripts/multiplayer" / name)
            (root / "project.godot").write_text('config_version=5\n')
            service = PatchService(root / "backend", "glory-test", "account")
            service.configure_battle(root / "desired.json", root / "status.json", "main", "stable")
            bridge = service.battle_bridge
            bridge.latest = {"deployment_id": "a" * 64}
            bridge.write_admission(service)
            (root / "runner.gd").write_text('''extends SceneTree
var agent
var failed := false
func check(value, expected, label):
 if value != expected:
  failed = true
  print("FAIL: ", label)
func save_rules(rules):
 var file = FileAccess.open("res://desired.json.admission", FileAccess.WRITE)
 file.store_string(JSON.stringify(rules))
 file.close()
func _initialize():
 agent = load("res://scripts/multiplayer/BattleHotfixAgent.gd").new()
 var original_identity = agent._deployment_identity()
 check(agent._deployment_identity(), original_identity, "stable deployment identity")
 var changed_data = FileAccess.open("res://data/bosses.json", FileAccess.WRITE)
 changed_data.store_string('{"hp":40}')
 changed_data.close()
 check(agent._deployment_identity() == original_identity, false, "data-only deployment invalidates identity")
 DirAccess.remove_absolute(ProjectSettings.globalize_path("res://data/bosses.json"))
 check(agent._deployment_identity(), original_identity, "identical content keeps identity")
 agent.desired_path = "res://desired.json"
 agent._deployment = "a".repeat(64)
 var card = {"patch":{"channel":"stable","platform":"android","base_id":"base-1","seq":0}}
 check(agent.accepts_card(card), true, "base admission")
 check(agent.accepts_card({}), false, "legacy card")
 var rules = JSON.parse_string(FileAccess.get_file_as_string("res://desired.json.admission"))
 rules.seq = 1
 rules.bases = {"android":"base-1"}
 save_rules(rules)
 check(agent.accepts_card(card), false, "old card after publication without tick")
 card.patch.seq = 1
 check(agent.accepts_card(card), true, "new card")
 for key in ["channel", "platform", "base_id"]:
  var bad = card.duplicate(true)
  bad.patch[key] = "wrong"
  check(agent.accepts_card(bad), false, key)
 rules.generated_at = 0
 save_rules(rules)
 check(agent.accepts_card(card), false, "expired control plane")
 rules.generated_at = Time.get_unix_time_from_system()
 rules.battle_deployment_id = "b".repeat(64)
 save_rules(rules)
 check(agent.accepts_card(card), false, "other battle deployment")
 DirAccess.remove_absolute(ProjectSettings.globalize_path("res://desired.json.admission"))
 check(agent.accepts_card(card), false, "missing rules")
 agent.free()
 print("ADMISSION_CHECK_DONE")
 quit(1 if failed else 0)
''')
            result = subprocess.run([engine, "--headless", "--path", str(root), "--script", "res://runner.gd"],
                env={**os.environ, "GLORY_BATTLE_PATCH_ENFORCE": "true"}, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("ADMISSION_CHECK_DONE", result.stdout)
            self.assertNotIn("SCRIPT ERROR", result.stderr)

    def test_battle_build_change_expires_all_targets_once(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            service = PatchService(root / "backend", "glory-test", "account")
            status = root / "status.json"
            service.configure_battle(root / "desired.json", status, "main", "stable")
            def report(deployment):
                status.write_text(json.dumps({"protocol": 1, "instance_id": "main", "deployment_id": deployment,
                    "heartbeat": time.time(), "applied_revision": -1, "error": ""}))
            report("a" * 64)
            self.assertTrue(service.battle_bridge.tick(service))
            for target in ("client", "account_server", "battle_server"):
                service.store.add_hotfix("stable", target, "test fixture source", "admin",
                    expected_revision=service.store.catalogue()["revision"])
            before = service.store.catalogue()["hotfix_epoch"]
            report("b" * 64)
            self.assertTrue(service.battle_bridge.tick(service))
            self.assertEqual(service.store.catalogue()["hotfixes"], [])
            self.assertEqual(service.store.catalogue()["hotfix_epoch"], before + 1)
            self.assertFalse(service.battle_bridge.tick(service))
            self.assertEqual(service.store.catalogue()["hotfix_epoch"], before + 1)
            self.assertEqual(service.store.client_pushes()[0]["hotfixes"], [])

    def test_real_battle_process_applies_acknowledges_and_expires_on_deploy(self):
        engine = os.environ.get("GODOT_BIN")
        if not engine:
            self.skipTest("GODOT_BIN required for live battle process test")
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            project = root / "project"
            (project / "scripts/multiplayer").mkdir(parents=True)
            (project / "patcher").mkdir()
            source_root = Path(__file__).resolve().parents[2]
            for name in ("HotfixRuntime.gd", "HotfixContext.gd"):
                shutil.copy2(source_root / "patcher" / name, project / "patcher" / name)
            for name in ("BattleHotfixAgent.gd", "BattleHotfixContext.gd"):
                shutil.copy2(source_root / "scripts/multiplayer" / name, project / "scripts/multiplayer" / name)
            (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Battle bridge test"\n[autoload]\nDataRegistry="*res://registry.gd"\n')
            (project / "registry.gd").write_text('extends Node\nvar data={"hp":100}\nfunc get_table(_key):\n return data\n')
            (project / "build_info.txt").write_text("battle-build-1")
            desired, status, observed = root / "desired.json", root / "status.json", root / "observed.json"
            (project / "runner.gd").write_text('''extends SceneTree
func _initialize():
 call_deferred("start_agent")
func start_agent():
 var agent = load("res://scripts/multiplayer/BattleHotfixAgent.gd").new()
 root.add_child(agent)
 var timer = Timer.new()
 timer.wait_time = 0.1
 timer.autostart = true
 timer.timeout.connect(func():
  var file = FileAccess.open("%s", FileAccess.WRITE)
  file.store_string(JSON.stringify(root.get_node("DataRegistry").data))
  file.close())
 root.add_child(timer)
''' % observed)
            env = {**os.environ, "GLORY_BATTLE_HOTFIX_DESIRED": str(desired), "GLORY_BATTLE_HOTFIX_STATUS": str(status)}
            logs = (root / "godot.log").open("w+")
            process = subprocess.Popen([engine, "--headless", "--path", str(project), "--script", "res://runner.gd"],
                                       env=env, stdout=logs, stderr=subprocess.STDOUT)
            def wait_for(predicate):
                deadline = time.monotonic() + 12
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        logs.seek(0)
                        self.fail(logs.read())
                    try:
                        if predicate():
                            return
                    except (OSError, ValueError, KeyError):
                        pass
                    time.sleep(0.05)
                logs.seek(0)
                self.fail("Timed out waiting for battle state: " + logs.read())
            try:
                service = PatchService(root / "backend", "glory-test", "account-1", godot_binary=engine)
                service.configure_battle(desired, status, "main", "stable")
                wait_for(lambda: status.exists())
                self.assertTrue(service.battle_bridge.tick(service))
                code = 'extends RefCounted\nfunc apply(ctx) -> bool:\n return ctx.replace_item(ctx.table("bosses"), "hp", 40)\n'
                asyncio.run(service.add_battle_hotfix("stable", code, "admin", service.store.catalogue()["revision"]))
                service.battle_bridge.tick(service)
                revision = service.store.catalogue()["revision"]
                wait_for(lambda: json.loads(status.read_text())["applied_revision"] == revision
                         and json.loads(observed.read_text())["hp"] == 40)
                service.battle_bridge.tick(service)
                self.assertEqual(service.battle_bridge.latest["applied_revision"], revision)
                # Account-server update invalidates the old effect in a running Godot process.
                service.store.activate_deployment("account-2")
                service.battle_bridge.tick(service)
                wait_for(lambda: json.loads(observed.read_text())["hp"] == 100)
                self.assertEqual(service.store.effective_sources("battle_server"), [])
                # A stale/abandoned producer cannot keep code live indefinitely.
                asyncio.run(service.add_battle_hotfix("stable", code, "admin", service.store.catalogue()["revision"]))
                service.battle_bridge.tick(service)
                wait_for(lambda: json.loads(observed.read_text())["hp"] == 40)
                data = json.loads(desired.read_text())
                data["generated_at"] = 0
                desired.write_text(json.dumps(data))
                wait_for(lambda: json.loads(observed.read_text())["hp"] == 100)
            finally:
                process.terminate()
                process.wait(timeout=5)
                logs.close()


if __name__ == "__main__":
    unittest.main()
