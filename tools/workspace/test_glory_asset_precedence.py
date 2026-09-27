"""Temporary-directory staging tests using real rsync; no build or sync runs."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("glory_build_asset_tested", Path(__file__).with_name("glory_build.py"))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


@unittest.skipUnless(shutil.which("rsync"), "These staging tests require rsync")
class AssetPrecedenceTests(unittest.TestCase):
    BASE = 1_700_000_000

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="glory-asset-precedence-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.project = self.root / "project"
        self.assets = self.root / "res/assets"
        self.stage = self.root / "work/project"
        self.logs = self.root / "logs"
        for folder in (self.project / "assets", self.assets, self.logs):
            folder.mkdir(parents=True)
        self.put(self.project / "project.godot", "[application]\nconfig/name=\"Fixture\"\n", 0)
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(mock.patch.object(build, "ROOT", self.root))
        self.stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
        self.real_run = subprocess.run

        def only_temporary_commands(command, **kwargs):
            if command[0] == "rsync":
                self.assertEqual(Path(command[-2]).resolve(), self.project)
                self.assertEqual(Path(command[-1]).resolve(), self.stage)
            else:
                self.assertEqual(command[:2], ["git", "-C"])
                self.assertEqual(Path(command[2]).resolve(), self.project)
                self.assertIn(command[3], ("rev-parse", "ls-files", "diff", "log"))
            return self.real_run(command, **kwargs)

        self.commands = self.stack.enter_context(mock.patch.object(build.subprocess, "run", side_effect=only_temporary_commands))
        self.stack.enter_context(mock.patch("socket.create_connection", side_effect=AssertionError("Network forbidden")))

    def put(self, path, content, seconds):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content.encode() if isinstance(content, str) else content)
        timestamp = int((self.BASE + seconds) * 1_000_000_000)
        os.utime(path, ns=(timestamp, timestamp))
        return path

    def pair(self, relative, project_content="project", resource_content="resource", project_time=20, resource_time=10):
        return (self.put(self.project / "assets" / relative, project_content, project_time),
                self.put(self.assets / relative, resource_content, resource_time))

    def record(self, file, *, version=None, content_hash=None):
        path = self.root / ".glory-sync/state.json"
        data = json.loads(path.read_text()) if path.is_file() else {"files": {}}
        data["files"][file.relative_to(self.root / "res").as_posix()] = {
            "sha256": content_hash or build.digest(file), "version": version}
        self.put(path, json.dumps(data), 1)

    def source_snapshot(self):
        return {str(path): (build.digest(path), path.stat().st_mtime_ns, path.stat().st_mode)
                for folder in (self.project, self.assets, self.root / "res", self.root / ".glory-sync")
                if folder.exists() for path in folder.rglob("*") if path.is_file()}

    def stage_once(self):
        before = self.source_snapshot()
        report = build.stage_project(self.project, self.assets, self.stage, self.logs)
        self.assertEqual(self.source_snapshot(), before, "Staging changed original inputs or sync provenance")
        self.assertEqual(json.loads((self.logs / "assets-check.json").read_text()), report)
        self.assertTrue(all(Path(call.args[0][-1]).resolve().is_relative_to(self.root)
                            for call in self.commands.call_args_list if call.args[0][0] == "rsync"))
        return report

    def assert_staged(self, relative, content):
        self.assertEqual((self.stage / "assets" / relative).read_text(), content)

    def assert_inventory(self, report):
        inventory = hashlib.sha256()
        for relative, path in sorted(build.files_under(self.stage / "assets")):
            inventory.update(f"{relative.as_posix()}\t{path.stat().st_size}\t{build.digest(path)}\n".encode())
        self.assertEqual(report["actual_assets_sha256"], inventory.hexdigest())

    def test_project_newer_or_equal_wins_and_strictly_newer_resource_wins(self):
        for project_time, resource_time, selected, reason in (
            (20, 10, "project", "project_newer"),
            (20, 20, "project", "project_same_time"),
            (20, 21, "resource", "resource_strictly_newer"),
        ):
            with self.subTest(project_time=project_time, resource_time=resource_time):
                self.pair("models/unit.tres", project_time=project_time, resource_time=resource_time)
                report = self.stage_once()
                self.assert_staged("models/unit.tres", selected)
                self.assertEqual(report["asset_choices"]["models/unit.tres"]["source_reason"], reason)
                self.assertEqual(report["protected_project_assets"], ["models/unit.tres"] if selected == "project" else [])
                self.assertEqual(report["overridden_by_cloud_assets"], ["models/unit.tres"] if selected == "resource" else [])
                self.assert_inventory(report)

    def test_source_unique_assets_and_first_download_with_unknown_time_are_included(self):
        self.put(self.project / "assets/models/project-only.tres", "project unique", 20)
        resource = self.put(self.assets / "models/new.tres", "new cloud asset", 1000)
        self.record(resource)
        report = self.stage_once()
        self.assert_staged("models/project-only.tres", "project unique")
        self.assert_staged("models/new.tres", "new cloud asset")
        self.assertEqual(report["asset_choices"]["models/new.tres"]["source_reason"], "resource_only")
        self.assertEqual(report["asset_choices"]["models/new.tres"]["resource_time_source"], "drive_modified_time_unknown")
        self.assertEqual(report["merged_file_count"], 2)

    def test_matching_drive_hash_uses_remote_time_instead_of_download_time(self):
        _, resource = self.pair("models/unit.tres", project_time=20, resource_time=1000)
        self.record(resource, version=[123, (self.BASE + 10) * 1000])
        report = self.stage_once()
        self.assert_staged("models/unit.tres", "project")
        choice = report["asset_choices"]["models/unit.tres"]
        self.assertEqual(choice["resource_mtime_ns"], (self.BASE + 10) * 1_000_000_000)
        self.assertEqual(choice["resource_time_source"], "drive_modified_time")
        self.assertEqual(choice["source_reason"], "project_newer")

    def test_remote_time_can_be_newer_even_when_local_resource_mtime_is_older(self):
        _, resource = self.pair("models/unit.tres", project_time=20, resource_time=10)
        self.record(resource, version=[123, (self.BASE + 30) * 1000])
        report = self.stage_once()
        self.assert_staged("models/unit.tres", "resource")
        self.assertEqual(report["asset_choices"]["models/unit.tres"]["source_reason"], "resource_strictly_newer")

    def test_unknown_or_invalid_remote_time_cannot_override_project(self):
        _, resource = self.pair("models/unit.tres", project_time=20, resource_time=1000)
        for version in (None, [], [1], [1, None], [1, 0], [1, -1], [1, True],
                        [1, "9999999999999"], [1, float("nan")], [1, float("inf")]):
            with self.subTest(version=version):
                self.record(resource, version=version)
                report = self.stage_once()
                self.assert_staged("models/unit.tres", "project")
                self.assertEqual(report["asset_choices"]["models/unit.tres"]["source_reason"], "resource_time_unknown")
                self.assertIsNone(report["asset_choices"]["models/unit.tres"]["resource_mtime_ns"])

    def test_locally_edited_resource_uses_local_time_and_preserves_cloud_baseline(self):
        _, resource = self.pair("models/unit.tres", project_time=20, resource_time=10)
        self.record(resource, version=[123, (self.BASE + 10) * 1000])
        state = self.root / ".glory-sync/state.json"
        baseline = state.read_bytes()
        self.put(resource, "local resource edit", 30)
        report = self.stage_once()
        self.assert_staged("models/unit.tres", "local resource edit")
        choice = report["asset_choices"]["models/unit.tres"]
        self.assertEqual(choice["resource_time_source"], "local_edit_mtime")
        self.assertEqual(choice["source_reason"], "resource_strictly_newer")
        self.assertEqual(state.read_bytes(), baseline)

    def test_preserved_local_record_uses_its_original_time_or_keeps_project_if_unknown(self):
        _, resource = self.pair("models/unit.tres", project_time=20, resource_time=1000)
        for original_time, expected in ((10, "project"), (30, "resource"), (None, "project")):
            with self.subTest(original_time=original_time):
                local_time = (self.BASE + original_time) * 1_000_000_000 if original_time is not None else None
                record = {"applied": False, "sha256": "old-cloud-baseline", "version": [123, (self.BASE + 2000) * 1000],
                          "local_copy": {"sha256": build.digest(resource), "modified_time_ns": local_time}}
                self.put(self.root / ".glory-sync/state.json", json.dumps({"files": {"assets/models/unit.tres": record}}), 1)
                report = self.stage_once()
                self.assert_staged("models/unit.tres", expected)
                choice = report["asset_choices"]["models/unit.tres"]
                self.assertEqual(choice["resource_mtime_ns"], local_time)
                self.assertEqual(choice["resource_time_source"], "preserved_local_time" if local_time else "preserved_local_time_unknown")

    def test_edit_after_preserved_local_record_uses_current_local_time(self):
        _, resource = self.pair("models/unit.tres", project_time=20, resource_time=10)
        record = {"applied": False, "sha256": "old-cloud-baseline", "version": None,
                  "local_copy": {"sha256": build.digest(resource), "modified_time_ns": (self.BASE + 10) * 1_000_000_000}}
        self.put(self.root / ".glory-sync/state.json", json.dumps({"files": {"assets/models/unit.tres": record}}), 1)
        self.put(resource, "later local edit", 30)
        report = self.stage_once()
        self.assert_staged("models/unit.tres", "later local edit")
        self.assertEqual(report["asset_choices"]["models/unit.tres"]["resource_time_source"], "local_edit_mtime")

    def test_identical_content_does_not_promote_unknown_download_time(self):
        _, resource = self.pair("models/unit.tres", project_content="same", resource_content="same", project_time=20, resource_time=1000)
        self.record(resource)
        report = self.stage_once()
        self.assert_staged("models/unit.tres", "same")
        self.assertEqual(report["asset_choices"]["models/unit.tres"]["source"], "project")
        self.assertEqual(report["asset_choices"]["models/unit.tres"]["source_reason"], "identical_content")
        self.assertIsNone(report["asset_choices"]["models/unit.tres"]["resource_mtime_ns"])

    def test_scripts_and_associated_uids_use_trusted_age_and_keep_project_on_ties(self):
        paths = ["scripts/unit.gd", "scripts/Unit.cs", "scripts/unit.gd.uid", "scripts/Unit.cs.uid"]
        for remote_time, expected in ((10, "project"), (20, "project"), (30, "resource"), (None, "project")):
            with self.subTest(remote_time=remote_time):
                for relative in paths:
                    _, resource = self.pair(relative, project_time=20, resource_time=1000)
                    self.record(resource, version=[123, (self.BASE + remote_time) * 1000] if remote_time is not None else None)
                self.put(self.assets / "scripts/only-resource.gd", "new resource script", 1000)
                report = self.stage_once()
                for relative in paths:
                    self.assert_staged(relative, expected)
                self.assertEqual(report["protected_project_code"], sorted(paths) if expected == "project" else [])
                self.assertEqual(report["protected_project_assets"], [])
                self.assert_staged("scripts/only-resource.gd", "new resource script")

    def test_descriptors_compare_original_inputs_for_both_choices(self):
        for name in ("assets.manifest.json", "assets.bundle.json"):
            project_doc = self.put(self.project / name, json.dumps({"inventory_sha256": "project", "entries": []}), 20)
            resource_doc = self.put(self.assets.parent / name, json.dumps({"inventory_sha256": "resource", "entries": []}), 10)
            for project_time, resource_time, expected in ((20, 10, "project"), (20, 20, "project"), (20, 21, "resource")):
                with self.subTest(name=name, project_time=project_time, resource_time=resource_time):
                    self.put(project_doc, json.dumps({"inventory_sha256": "project", "entries": []}), project_time)
                    self.put(resource_doc, json.dumps({"inventory_sha256": "resource", "entries": []}), resource_time)
                    report = self.stage_once()
                    self.assertEqual(json.loads((self.stage / name).read_text())["inventory_sha256"], expected)
                    self.assertEqual(report["descriptor_choices"][name]["source"], "project" if expected == "project" else "res")
                    self.assertEqual(report["descriptor_choices"][name]["project_mtime_ns"], project_doc.stat().st_mtime_ns)

    def test_descriptors_use_remote_provenance_and_allow_source_unique_files(self):
        name = "assets.manifest.json"
        self.put(self.project / name, json.dumps({"inventory_sha256": "project", "entries": []}), 20)
        resource_doc = self.put(self.assets.parent / name, json.dumps({"inventory_sha256": "resource", "entries": []}), 1000)
        self.record(resource_doc)
        self.put(self.assets.parent / "assets.bundle.json", '{"source":"resource-only"}', 1000)
        report = self.stage_once()
        self.assertEqual(report["expected_manifest"], "project")
        self.assertEqual(report["descriptor_choices"][name]["source_reason"], "resource_time_unknown")
        self.assertEqual(json.loads((self.stage / "assets.bundle.json").read_text())["source"], "resource-only")
        self.record(resource_doc, version=[123, (self.BASE + 30) * 1000])
        self.assertEqual(self.stage_once()["expected_manifest"], "resource")

    def test_repeated_stage_uses_original_times_and_updates_hashes_when_winner_changes(self):
        project, resource = self.pair("models/unit.tres", project_content="project-v1", resource_content="resource-v1", project_time=20, resource_time=10)
        first = self.stage_once()
        stage_file = self.stage / "assets/models/unit.tres"
        first_mtime = stage_file.stat().st_mtime_ns
        second = self.stage_once()
        self.assertEqual(first["actual_assets_sha256"], second["actual_assets_sha256"])
        self.assertEqual(stage_file.stat().st_mtime_ns, first_mtime)
        self.assert_staged("models/unit.tres", "project-v1")
        self.put(resource, "resource-v2", 30)
        third = self.stage_once()
        self.assert_staged("models/unit.tres", "resource-v2")
        self.assertNotEqual(second["actual_assets_sha256"], third["actual_assets_sha256"])
        inputs = json.loads((self.stage.parent / "asset-input-hashes.json").read_text())
        self.assertEqual(inputs["models/unit.tres"], build.digest(resource))
        self.assert_inventory(third)
        self.put(project, "project-v2", 40)
        fourth = self.stage_once()
        self.assert_staged("models/unit.tres", "project-v2")
        self.assertNotEqual(third["actual_assets_sha256"], fourth["actual_assets_sha256"])
        inputs = json.loads((self.stage.parent / "asset-input-hashes.json").read_text())
        self.assertEqual(inputs["models/unit.tres"], build.digest(project))
        self.assert_inventory(fourth)

    def test_import_cache_preserved_until_selected_source_content_changes(self):
        project, resource = self.pair("models/unit.glb.import", project_content="project-import", resource_content="resource-import", project_time=20, resource_time=10)
        self.stage_once()
        generated = self.stage / "assets/models/unit.glb.import"
        generated.write_text("Godot-generated-import")
        report = self.stage_once()
        self.assertEqual(generated.read_text(), "Godot-generated-import")
        inputs = json.loads((self.stage.parent / "asset-input-hashes.json").read_text())
        self.assertEqual(inputs["models/unit.glb.import"], build.digest(project))
        self.assert_inventory(report)
        self.put(resource, "new-resource-import", 30)
        report = self.stage_once()
        self.assertEqual(generated.read_text(), "new-resource-import")
        inputs = json.loads((self.stage.parent / "asset-input-hashes.json").read_text())
        self.assertEqual(inputs["models/unit.glb.import"], build.digest(resource))
        self.assert_inventory(report)

    def test_stage_deletes_stale_stage_asset_without_touching_sources(self):
        self.pair("models/unit.tres")
        self.stage_once()
        stale = self.stage / "assets/models/removed.tres"
        stale.write_text("stale generated copy")
        report = self.stage_once()
        self.assertFalse(stale.exists())
        self.assertEqual(report["merged_file_count"], 1)

    def test_other_resource_roots_ignore_managed_drive_records(self):
        self.assets = self.root / "external/assets"
        self.assets.mkdir(parents=True)
        self.pair("models/unit.tres", project_time=20, resource_time=30)
        self.put(self.root / ".glory-sync/state.json", "not valid JSON", 1)
        report = self.stage_once()
        self.assert_staged("models/unit.tres", "resource")
        self.assertEqual(report["asset_choices"]["models/unit.tres"]["resource_time_source"], "local_mtime")

    def git(self, *args, seconds=10):
        """Only this helper can create Git fixtures, always inside the temp root."""
        env = dict(os.environ, GIT_AUTHOR_DATE=f"{self.BASE + seconds} +0000",
                   GIT_COMMITTER_DATE=f"{self.BASE + seconds} +0000")
        command = ["git", "-C", str(self.project), "-c", "user.name=Offline Test", "-c", "user.email=offline@example.invalid",
                   "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *args]
        return self.real_run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True)

    def test_clean_tracked_project_uses_content_commit_time_not_checkout_mtime(self):
        project, resource = self.pair("models/unit.tres", project_time=1000, resource_time=20)
        self.git("init")
        self.git("add", ".")
        self.git("commit", "-m", "Initial fixture", seconds=10)
        self.put(self.project / "unrelated.txt", "unrelated later commit", 500)
        self.git("add", ".")
        self.git("commit", "-m", "Unrelated fixture", seconds=500)
        report = self.stage_once()
        self.assert_staged("models/unit.tres", "resource")
        choice = report["asset_choices"]["models/unit.tres"]
        self.assertEqual(choice["project_mtime_ns"], (self.BASE + 10) * 1_000_000_000)
        self.assertEqual(choice["project_time_source"], "git_commit_time")

    def test_dirty_tracked_project_uses_local_edit_time_for_staged_and_unstaged_edits(self):
        project, resource = self.pair("models/unit.tres", project_time=10, resource_time=20)
        self.git("init")
        self.git("add", ".")
        self.git("commit", "-m", "Initial fixture", seconds=10)
        self.put(project, "local uncommitted edit", 30)
        for staged in (False, True):
            with self.subTest(staged=staged):
                if staged:
                    self.git("add", "assets/models/unit.tres")
                report = self.stage_once()
                self.assert_staged("models/unit.tres", "local uncommitted edit")
                choice = report["asset_choices"]["models/unit.tres"]
                self.assertEqual(choice["project_mtime_ns"], project.stat().st_mtime_ns)
                self.assertEqual(choice["project_time_source"], "local_mtime")


if __name__ == "__main__":
    unittest.main()
