"""Offline regression tests for newest-version-wins Drive synchronization.

Only temporary directories are used; no Drive requests or project writes occur.
Run: .glory-tools/venv/bin/python -m unittest discover -s tools -p 'test_glory_recency.py'
"""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("glory_recency_under_test", Path(__file__).with_name("glory_sync.py"))
sync = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sync)

BASE_MS = 1_700_000_000_000


def sha(data):
    return hashlib.sha256(data).hexdigest()


class RecencyTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)
        self.dest = self.root / "res"
        self.state = self.root / ".glory-sync"
        self.dest.mkdir()
        (self.state / "partial").mkdir(parents=True)
        self.target = self.dest / "asset.bin"
        self.remote = b"cloud version"
        self.item = dict(id="file1", name="asset.bin", mime="application/octet-stream",
                         version=[BASE_MS - 10_000, BASE_MS], size=len(self.remote))

    def local(self, data=b"local version", modified_ms=BASE_MS - 1000):
        self.target.write_bytes(data)
        timestamp = int(modified_ms * 1_000_000)
        os.utime(self.target, ns=(timestamp, timestamp))
        return data

    def previous(self, data, modified_ms=BASE_MS - 2000):
        return dict(self.item, version=[BASE_MS - 10_000, modified_ms],
                    sha256=sha(data), size=len(data), downloaded_size=len(data))

    def download(self, item, temp):
        temp.write_bytes(self.remote)
        return dict(item, sha256=sha(self.remote), downloaded_size=len(self.remote))

    def run_sync(self, previous=None, item=None, force=False):
        with patch.object(sync, "download", side_effect=self.download):
            return sync.sync_one("asset.bin", self.item if item is None else item,
                                 previous, self.dest, self.state, "run1", force)

    def test_remote_newer_replaces_and_backs_up_local(self):
        original = self.local()
        kind, record = self.run_sync()
        self.assertEqual(kind, "downloaded")
        self.assertEqual(self.target.read_bytes(), self.remote)
        self.assertEqual((self.state / "backups/run1/asset.bin").read_bytes(), original)
        self.assertTrue(record["applied"])
        self.assertEqual(self.target.stat().st_mtime_ns, BASE_MS * 1_000_000)

    def test_newer_local_is_kept_without_claiming_cloud_content_applied(self):
        original = self.local(modified_ms=BASE_MS + 1000)
        kind, record = self.run_sync()
        self.assertEqual(kind, "local_preserved")
        self.assertEqual(self.target.read_bytes(), original)
        self.assertFalse(record["applied"])
        self.assertEqual(record["sha256"], sha(self.remote))
        self.assertEqual(record["local_copy"]["sha256"], sha(original))
        self.assertNotEqual(record["sha256"], record["local_copy"]["sha256"])
        self.assertEqual(record["version"], self.item["version"])

    def test_creation_time_is_not_used_as_modification_time(self):
        original = self.local(modified_ms=BASE_MS + 1000)
        item = dict(self.item, version=[BASE_MS + 10_000, BASE_MS])
        kind, _ = self.run_sync(item=item)
        self.assertEqual(kind, "local_preserved")
        self.assertEqual(self.target.read_bytes(), original)

    def test_equal_time_different_content_is_conflict_and_preserves_both(self):
        original = self.local(modified_ms=BASE_MS)
        kind, record = self.run_sync()
        self.assertEqual(kind, "local_preserved")
        self.assertFalse(record["applied"])
        self.assertEqual(self.target.read_bytes(), original)
        self.assertEqual((self.state / "conflicts/run1/asset.bin").read_bytes(), self.remote)

    def test_missing_remote_time_cannot_overwrite_existing_different_content(self):
        for version in (None, [BASE_MS, None], [0, 0]):
            with self.subTest(version=version):
                original = self.local()
                kind, record = self.run_sync(item=dict(self.item, version=version))
                self.assertEqual(kind, "local_preserved")
                self.assertFalse(record["applied"])
                self.assertEqual(self.target.read_bytes(), original)
                self.assertEqual((self.state / "conflicts/run1/asset.bin").read_bytes(), self.remote)

    def test_equal_content_with_unknown_time_is_safe_to_check(self):
        self.local(self.remote, modified_ms=BASE_MS + 1000)
        kind, record = self.run_sync(item=dict(self.item, version=None))
        self.assertEqual(kind, "checked")
        self.assertTrue(record["applied"])
        self.assertEqual(self.target.read_bytes(), self.remote)

    def test_missing_local_file_can_be_downloaded_without_remote_time(self):
        kind, record = self.run_sync(item=dict(self.item, version=None))
        self.assertEqual(kind, "downloaded")
        self.assertTrue(record["applied"])
        self.assertEqual(self.target.read_bytes(), self.remote)

    def test_legacy_record_uses_remote_version_not_recent_download_mtime(self):
        original = self.local(modified_ms=BASE_MS + 60_000)
        kind, _ = self.run_sync(self.previous(original))
        self.assertEqual(kind, "downloaded")
        self.assertEqual(self.target.read_bytes(), self.remote)

    def test_legacy_record_prevents_rollback_despite_old_filesystem_mtime(self):
        original = self.local(modified_ms=BASE_MS - 60_000)
        kind, record = self.run_sync(self.previous(original, modified_ms=BASE_MS + 1000))
        self.assertEqual(kind, "local_preserved")
        self.assertEqual(self.target.read_bytes(), original)
        self.assertEqual(record["local_copy"]["modified_time_ns"], (BASE_MS + 1000) * 1_000_000)

    def test_edited_local_content_uses_actual_mtime_instead_of_previous_version(self):
        original = self.local(modified_ms=BASE_MS + 1000)
        kind, _ = self.run_sync(self.previous(b"old downloaded content"))
        self.assertEqual(kind, "local_preserved")
        self.assertEqual(self.target.read_bytes(), original)

    def test_force_cannot_replace_newer_local_with_older_cloud(self):
        original = self.local(modified_ms=BASE_MS + 1000)
        kind, record = self.run_sync(force=True)
        self.assertEqual(kind, "local_preserved")
        self.assertFalse(record["applied"])
        self.assertEqual(self.target.read_bytes(), original)

    def test_force_cannot_resolve_unknown_time_by_overwriting(self):
        original = self.local()
        kind, _ = self.run_sync(item=dict(self.item, version=None), force=True)
        self.assertEqual(kind, "local_preserved")
        self.assertEqual(self.target.read_bytes(), original)

    def test_second_run_of_kept_local_still_reports_distinct_local_content(self):
        original = self.local(modified_ms=BASE_MS + 1000)
        _, previous = self.run_sync()
        kind, record = self.run_sync(previous)
        self.assertEqual(kind, "local_preserved")
        self.assertFalse(record["applied"])
        self.assertEqual(record["local_copy"]["sha256"], sha(original))
        self.assertEqual(record["sha256"], sha(self.remote))
        self.assertEqual(self.target.read_bytes(), original)

    def test_later_cloud_update_can_replace_previously_kept_local(self):
        original = self.local(modified_ms=BASE_MS + 1000)
        _, previous = self.run_sync()
        new_item = dict(self.item, version=[BASE_MS - 10_000, BASE_MS + 2000])
        kind, record = self.run_sync(previous, item=new_item)
        self.assertEqual(kind, "downloaded")
        self.assertTrue(record["applied"])
        self.assertEqual(self.target.read_bytes(), self.remote)
        self.assertEqual((self.state / "backups/run1/asset.bin").read_bytes(), original)

    def test_local_edit_during_download_is_preserved(self):
        self.local()
        edited = b"edit made while downloading"

        def download_with_local_edit(item, temp):
            result = self.download(item, temp)
            self.local(edited, modified_ms=BASE_MS + 1000)
            return result

        with patch.object(sync, "download", side_effect=download_with_local_edit):
            kind, record = sync.sync_one("asset.bin", self.item, None,
                                         self.dest, self.state, "run1", False)
        self.assertEqual(kind, "local_preserved")
        self.assertFalse(record["applied"])
        self.assertEqual(self.target.read_bytes(), edited)

    def test_new_local_file_appearing_during_download_is_preserved(self):
        created = b"created while downloading"

        def download_with_local_creation(item, temp):
            result = self.download(item, temp)
            self.local(created, modified_ms=BASE_MS + 1000)
            return result

        with patch.object(sync, "download", side_effect=download_with_local_creation):
            kind, record = sync.sync_one("asset.bin", self.item, None,
                                         self.dest, self.state, "run1", False)
        self.assertEqual(kind, "local_preserved")
        self.assertFalse(record["applied"])
        self.assertEqual(self.target.read_bytes(), created)

    def main_context(self, item):
        stack = contextlib.ExitStack()
        stack.enter_context(patch.object(sync, "ROOT", self.root))
        stack.enter_context(patch.object(sync, "scan", return_value=({"asset.bin": item}, [])))
        stack.enter_context(patch.object(sync, "download", side_effect=self.download))
        stack.enter_context(patch.object(sync.sys, "argv", ["glory_sync.py", "--workers", "1"]))
        stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
        stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
        return stack

    def test_main_conflict_reports_preserved_versions_and_truthful_state(self):
        original = self.local()
        with self.main_context(dict(self.item, version=None)):
            sync.main()
        result = json.loads((self.state / "last-run.json").read_text())
        saved = json.loads((self.state / "state.json").read_text())["files"]["asset.bin"]
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["counts"]["local_preserved"], 1)
        self.assertEqual(len(result["local_preserved"]), 1)
        self.assertFalse(saved["applied"])
        self.assertEqual(saved["local_copy"]["sha256"], sha(original))
        self.assertEqual(self.target.read_bytes(), original)
        conflict_files = list((self.state / "conflicts").glob("*/asset.bin"))
        self.assertEqual(len(conflict_files), 1)
        self.assertEqual(conflict_files[0].read_bytes(), self.remote)

    def test_main_kept_local_succeeds_but_does_not_mark_it_downloaded(self):
        original = self.local(modified_ms=BASE_MS + 1000)
        with self.main_context(self.item):
            sync.main()
        result = json.loads((self.state / "last-run.json").read_text())
        saved = json.loads((self.state / "state.json").read_text())["files"]["asset.bin"]
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["counts"]["local_preserved"], 1)
        self.assertEqual(result["counts"]["downloaded"], 0)
        self.assertFalse(saved["applied"])
        self.assertEqual(saved["sha256"], sha(self.remote))
        self.assertEqual(saved["local_copy"]["sha256"], sha(original))


if __name__ == "__main__":
    unittest.main()
