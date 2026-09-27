"""Offline regression tests for Drive sync safety and interrupted downloads.

All filesystem writes use TemporaryDirectory and all HTTP calls are mocked.
Run: .glory-tools/venv/bin/python -m unittest discover -s tools -p 'test_glory_sync.py'
"""
from __future__ import annotations

import contextlib
import hashlib
import html
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import requests


SPEC = importlib.util.spec_from_file_location("glory_sync_under_test", Path(__file__).with_name("glory_sync.py"))
sync = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sync)


def metadata_html(rows):
    payload = json.dumps([rows], ensure_ascii=True)
    escaped = json.dumps(payload)[1:-1].replace("'", "\\'")
    return "<script>window['_DRIVE_ivd'] = '" + escaped + "';</script>"


def metadata_row(fid, name, version=(1000, 2000), size=3, mime="application/octet-stream"):
    row = [None] * 14
    row[0], row[2], row[3] = fid, name, mime
    row[9], row[10], row[13] = *version, size
    return row


def embedded_html(items):
    entries = []
    for fid, name in items:
        entries.append(
            '<div class="flip-entry"><div class="flip-entry-info">'
            f'<a href="https://drive.google.com/file/d/{fid}/view">file</a></div>'
            f'<div class="flip-entry-title">{html.escape(name)}</div></div>'
        )
    return '<html><title>Resources</title><div class="flip-entries">' + "".join(entries) + "</div></html>"


class Response:
    def __init__(self, body=b"new", *, text="", length=None, error=None):
        self.body, self.text, self.error = body, text, error
        self.headers = {"Content-Disposition": 'attachment; filename="file.bin"'}
        if length is not None:
            self.headers["Content-Length"] = str(length)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def iter_content(self, chunk_size):
        yield self.body
        if self.error:
            raise self.error


class ParsingTests(unittest.TestCase):
    def test_metadata_preserves_unicode_quotes_and_size(self):
        name = '木头\'s "材质".png'
        parsed = sync.parse_metadata(metadata_html([metadata_row("file_1", name, size=123)]))
        self.assertEqual(parsed["file_1"]["name"], name)
        self.assertEqual(parsed["file_1"]["size"], 123)
        self.assertEqual(parsed["file_1"]["version"], [1000, 2000])

    def test_absent_metadata_rejected_instead_of_empty_listing(self):
        with self.assertRaises(ValueError):
            sync.parse_metadata("<html><title>Sign in</title></html>")

    def test_unsafe_embedded_names_rejected(self):
        for name in ("../escape", "a/b", "a\\b", "..", "bad\x00name"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                sync.parse_embedded(embedded_html([("file1", name)]))

    def test_duplicate_embedded_ids_rejected(self):
        with self.assertRaises(ValueError):
            sync.parse_embedded(embedded_html([("same", "a"), ("same", "b")]))

    def test_listing_over_50_retains_all_embedded_files(self):
        items = [(f"file{i}", f"asset{i}.png") for i in range(67)]
        embedded = embedded_html(items)
        metadata = metadata_html([metadata_row(fid, name) for fid, name in items[:50]])
        with patch.object(sync, "get", side_effect=[Response(text=embedded), Response(text=metadata), Response(text=embedded)]) as get:
            result = sync.list_folder("root")
        self.assertEqual(len(result), 67)
        self.assertEqual(get.call_count, 3)
        self.assertEqual(sum(item["version"] is None for item in result), 17)

    def test_changed_second_listing_rejected(self):
        items = [(f"file{i}", f"asset{i}.png") for i in range(50)]
        with patch.object(sync, "get", side_effect=[
            Response(text=embedded_html(items)),
            Response(text=metadata_html([metadata_row(fid, name) for fid, name in items])),
            Response(text=embedded_html(items[:-1])),
        ]), self.assertRaises(ValueError):
            sync.list_folder("root")

    def test_metadata_missing_from_embedded_listing_rejected(self):
        with patch.object(sync, "get", side_effect=[
            Response(text=embedded_html([("one", "a")])),
            Response(text=metadata_html([metadata_row("one", "a"), metadata_row("two", "b")])),
        ]), self.assertRaises(ValueError):
            sync.list_folder("root")

    def test_case_and_unicode_name_collisions_rejected(self):
        for names in (("A.png", "a.png"), ("é.png", "e\u0301.png")):
            items = [("one", names[0]), ("two", names[1])]
            with self.subTest(names=names), patch.object(sync, "get", side_effect=[
                Response(text=embedded_html(items)), Response(text=metadata_html([])),
            ]), self.assertRaises(ValueError):
                sync.list_folder("root")


class SyncSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)
        self.dest, self.state = self.root / "res", self.root / ".glory-sync"
        self.dest.mkdir()
        (self.state / "partial").mkdir(parents=True)
        self.item = dict(id="file1", name="asset.bin", mime="application/octet-stream", version=[1000, 2000], size=3)

    def record(self, data=b"old", **changes):
        return dict(self.item, sha256=hashlib.sha256(data).hexdigest(), downloaded_size=len(data), **changes)

    def fake_download(self, item, target):
        target.write_bytes(b"new")
        return dict(item, sha256=hashlib.sha256(b"new").hexdigest(), downloaded_size=3)

    def call_sync(self, previous=None, item=None, force=False):
        return sync.sync_one("asset.bin", item or self.item, previous, self.dest, self.state, "run1", force)

    def test_unchanged_version_and_local_hash_skips_network(self):
        (self.dest / "asset.bin").write_bytes(b"old")
        with patch.object(sync, "download") as download:
            status, _ = self.call_sync(self.record())
        self.assertEqual(status, "skipped")
        download.assert_not_called()

    def test_newer_or_equal_local_is_preserved_even_with_force_and_matching_old_baseline(self):
        target = self.dest / "asset.bin"
        for force in (False, True):
            for local_ns, reason in [(3_000_000_000, "remote_older"), (2_000_000_000, "same_mtime")]:
                with self.subTest(force=force, local_ns=local_ns):
                    target.write_bytes(b"old")
                    os.utime(target, ns=(local_ns, local_ns))
                    # Previous cloud content still equals local, but metadata changed.
                    previous = dict(self.record(), version=[500, local_ns // 1_000_000])
                    with patch.object(sync, "download", side_effect=self.fake_download) as download:
                        kind, record = self.call_sync(previous, force=force)
                    self.assertEqual(kind, "local_preserved")
                    self.assertEqual(record["local_preserved"]["reason"], reason)
                    self.assertFalse(record["local_preserved"]["local_changed_since_sync"])
                    self.assertEqual(record["sha256"], hashlib.sha256(b"new").hexdigest())
                    self.assertEqual(record["local_preserved"]["local_sha256"], hashlib.sha256(b"old").hexdigest())
                    self.assertEqual(target.read_bytes(), b"old")
                    self.assertEqual(target.stat().st_mtime_ns, local_ns)
                    self.assertEqual(Path(record["local_preserved"]["cloud_copy"]).read_bytes(), b"new")
                    download.assert_called_once()

    def test_strictly_newer_cloud_uses_second_timestamp_and_replaces_older_local(self):
        target = self.dest / "asset.bin"
        target.write_bytes(b"old")
        os.utime(target, ns=(1_999_999_999, 1_999_999_999))
        with patch.object(sync, "download", side_effect=self.fake_download):
            kind, record = self.call_sync()
        self.assertEqual(kind, "downloaded")
        self.assertEqual(target.read_bytes(), b"new")
        self.assertEqual(target.stat().st_mtime_ns, 2_000_000_000)
        self.assertEqual(record["last_synced_sha256"], hashlib.sha256(b"new").hexdigest())
        target.write_bytes(b"old")
        os.utime(target, ns=(3_000_000_000, 3_000_000_000))
        with patch.object(sync, "download", side_effect=self.fake_download):
            kind, _ = self.call_sync(item=dict(self.item, version=[9_000_000, 2000]))
        self.assertEqual(kind, "local_preserved")
        self.assertEqual(target.read_bytes(), b"old")

    def test_unknown_invalid_remote_times_are_preserved_even_when_forced(self):
        target = self.dest / "asset.bin"
        versions = [None, [1000], [1000, None], [1000, 0], [1000, -1], [1000, True],
                    [1000, "2000"], [1000, float("nan")], [1000, float("inf")], [1000, 10 ** 100]]
        for version in versions:
            with self.subTest(version=version):
                target.write_bytes(b"old")
                os.utime(target, (1, 1))
                with patch.object(sync, "download", side_effect=self.fake_download):
                    kind, record = self.call_sync(item=dict(self.item, version=version), force=True)
                self.assertEqual(kind, "local_preserved")
                self.assertEqual(record["local_preserved"]["reason"], "remote_mtime_unknown")
                self.assertIsNone(record["local_preserved"]["remote_mtime_ns"])
                self.assertEqual(target.read_bytes(), b"old")

    def test_same_content_never_changes_local_mtime_and_clears_old_preservation(self):
        target = self.dest / "asset.bin"
        for version in ([1000, 2000], None):
            target.write_bytes(b"new")
            os.utime(target, ns=(10_000_000_001, 10_000_000_001))
            previous = dict(self.record(), sync_status="local_preserved", local_preserved={"reason": "remote_older"})
            with patch.object(sync, "download", side_effect=self.fake_download):
                kind, record = self.call_sync(previous, dict(self.item, version=version), force=True)
            self.assertEqual(kind, "checked")
            self.assertEqual(target.stat().st_mtime_ns, 10_000_000_001)
            self.assertNotIn("local_preserved", record)
            self.assertEqual(record["last_synced_sha256"], record["sha256"])

    def test_missing_target_downloads_even_with_unknown_time(self):
        with patch.object(sync, "download", side_effect=self.fake_download):
            kind, _ = self.call_sync(item=dict(self.item, version=None))
        self.assertEqual(kind, "downloaded")
        self.assertEqual((self.dest / "asset.bin").read_bytes(), b"new")

    def test_download_time_edits_creation_deletion_and_inode_change_are_preserved(self):
        target = self.dest / "asset.bin"
        for edit in ("content", "touch", "create", "delete", "inode"):
            with self.subTest(edit=edit):
                target.unlink(missing_ok=True)
                if edit != "create":
                    target.write_bytes(b"old")
                    os.utime(target, (1, 1))

                def during_download(item, partial):
                    record = self.fake_download(item, partial)
                    if edit == "delete":
                        target.unlink()
                    elif edit == "touch":
                        os.utime(target, (1.5, 1.5))
                    elif edit == "inode":
                        replacement = self.dest / "replacement"
                        replacement.write_bytes(b"old")
                        os.utime(replacement, (1, 1))
                        os.replace(replacement, target)
                    else:
                        target.write_bytes(b"mod")
                        # A same-size edit that restores mtime must still be noticed.
                        os.utime(target, (1, 1))
                    return record

                with patch.object(sync, "download", side_effect=during_download):
                    kind, record = self.call_sync(force=True)
                self.assertEqual(kind, "local_preserved")
                self.assertEqual(record["local_preserved"]["reason"], "local_changed_during_download")
                if edit == "delete":
                    self.assertFalse(target.exists())
                else:
                    self.assertEqual(target.read_bytes(), b"mod" if edit in ("content", "create") else b"old")

    def test_edit_during_backup_is_preserved_even_if_remote_is_still_newer(self):
        target = self.dest / "asset.bin"
        target.write_bytes(b"old")
        os.utime(target, (1, 1))
        copy = sync.shutil.copy2

        def during_backup(source, backup):
            copy(source, backup)
            target.write_bytes(b"mod")
            os.utime(target, (1, 1))

        with patch.object(sync, "download", side_effect=self.fake_download), patch.object(sync.shutil, "copy2", side_effect=during_backup):
            kind, record = self.call_sync()
        self.assertEqual(kind, "local_preserved")
        self.assertEqual(record["local_preserved"]["reason"], "local_changed_during_backup")
        self.assertEqual(target.read_bytes(), b"mod")
        self.assertEqual((self.state / "backups/run1/asset.bin").read_bytes(), b"old")

    def test_final_snapshot_catches_edit_after_backup(self):
        target = self.dest / "asset.bin"
        target.write_bytes(b"old")
        os.utime(target, (1, 1))
        utime = os.utime

        def during_temp_timestamp(path, *args, **kwargs):
            utime(path, *args, **kwargs)
            if str(path).endswith(".part"):
                target.write_bytes(b"mod")
                utime(target, (1, 1))

        with patch.object(sync, "download", side_effect=self.fake_download), patch.object(sync.os, "utime", side_effect=during_temp_timestamp):
            kind, record = self.call_sync()
        self.assertEqual(kind, "local_preserved")
        self.assertEqual(record["local_preserved"]["reason"], "local_changed_before_replace")
        self.assertEqual(target.read_bytes(), b"mod")

    def test_preserved_cloud_record_cannot_make_next_run_skip_local_edits(self):
        target = self.dest / "asset.bin"
        target.write_bytes(b"mod")
        os.utime(target, (3, 3))
        with patch.object(sync, "download", side_effect=self.fake_download):
            _, previous = self.call_sync(self.record())
        self.assertTrue(previous["local_preserved"]["local_changed_since_sync"])
        self.assertEqual(previous["last_synced_sha256"], hashlib.sha256(b"old").hexdigest())
        with patch.object(sync, "download", side_effect=self.fake_download) as download:
            kind, record = self.call_sync(previous)
        self.assertEqual(kind, "local_preserved")
        self.assertEqual(record["sha256"], hashlib.sha256(b"new").hexdigest())
        self.assertEqual(record["last_synced_sha256"], hashlib.sha256(b"old").hexdigest())
        download.assert_called_once()

    def test_unknown_historical_cloud_time_preserves_matching_local_baseline(self):
        target = self.dest / "asset.bin"
        target.write_bytes(b"old")
        os.utime(target, (1, 1))
        previous = dict(self.record(), version=None)
        with patch.object(sync, "download", side_effect=self.fake_download):
            kind, record = self.call_sync(previous)
        self.assertEqual(kind, "local_preserved")
        self.assertEqual(record["local_preserved"]["reason"], "local_mtime_unknown")
        self.assertIsNone(record["local_copy"]["modified_time_ns"])
        self.assertEqual(target.read_bytes(), b"old")

    def test_same_size_local_edits_are_backed_up_before_replacement(self):
        target = self.dest / "asset.bin"
        target.write_bytes(b"mod")
        os.utime(target, (1, 1))
        with patch.object(sync, "download", side_effect=self.fake_download):
            status, _ = self.call_sync(self.record())
        self.assertEqual(status, "downloaded")
        self.assertEqual(target.read_bytes(), b"new")
        self.assertEqual((self.state / "backups/run1/asset.bin").read_bytes(), b"mod")

    def test_unknown_remote_version_always_checks_content(self):
        item = dict(self.item, version=None)
        previous = dict(self.record(), version=None)
        (self.dest / "asset.bin").write_bytes(b"old")
        with patch.object(sync, "download", side_effect=self.fake_download) as download:
            status, _ = self.call_sync(previous, item)
        self.assertEqual(status, "local_preserved")
        self.assertEqual((self.dest / "asset.bin").read_bytes(), b"old")
        self.assertEqual((self.state / "conflicts/run1/asset.bin").read_bytes(), b"new")
        download.assert_called_once()

    def test_null_metadata_timestamps_must_not_allow_stale_skip(self):
        item = sync.parse_metadata(metadata_html([metadata_row("file1", "asset.bin", version=(None, None))]))["file1"]
        previous = dict(item, sha256=hashlib.sha256(b"old").hexdigest(), downloaded_size=3)
        (self.dest / "asset.bin").write_bytes(b"old")
        with patch.object(sync, "download", side_effect=self.fake_download) as download:
            self.call_sync(previous, item)
        download.assert_called_once()
        self.assertEqual((self.dest / "asset.bin").read_bytes(), b"old")
        self.assertEqual((self.state / "conflicts/run1/asset.bin").read_bytes(), b"new")

    def test_failed_download_preserves_target_and_successful_retry_replaces(self):
        target = self.dest / "asset.bin"
        target.write_bytes(b"old")
        os.utime(target, (1, 1))
        failed = Response(b"truncated", error=requests.ConnectionError("interrupted"))
        with patch.object(sync, "get", return_value=failed), patch.object(sync.time, "sleep"), self.assertRaises(requests.RequestException):
            self.call_sync()
        self.assertEqual(target.read_bytes(), b"old")
        with patch.object(sync, "get", return_value=Response(b"new", length=3)):
            status, _ = self.call_sync()
        self.assertEqual(status, "downloaded")
        self.assertEqual(target.read_bytes(), b"new")
        self.assertEqual((self.state / "backups/run1/asset.bin").read_bytes(), b"old")

    def test_wrong_download_length_does_not_replace_target(self):
        target = self.dest / "asset.bin"
        target.write_bytes(b"old")
        os.utime(target, (1, 1))
        with patch.object(sync, "get", return_value=Response(b"new", length=4)), patch.object(sync.time, "sleep"), self.assertRaises(ValueError):
            self.call_sync()
        self.assertEqual(target.read_bytes(), b"old")

    def test_target_symlink_is_rejected(self):
        outside = self.root / "outside.bin"
        outside.write_bytes(b"keep")
        (self.dest / "asset.bin").symlink_to(outside)
        with patch.object(sync, "download") as download, self.assertRaises(ValueError):
            self.call_sync()
        download.assert_not_called()
        self.assertEqual(outside.read_bytes(), b"keep")

    def test_partial_directory_symlink_cannot_write_outside_state(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.state / "partial").rmdir()
        (self.state / "partial").symlink_to(outside, target_is_directory=True)
        with patch.object(sync, "get", return_value=Response(b"new", length=3)), self.assertRaises(ValueError):
            self.call_sync()
        self.assertEqual(list(outside.iterdir()), [])

    def test_backup_ancestor_symlink_cannot_write_outside_state(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.state / "backups").symlink_to(outside, target_is_directory=True)
        (self.dest / "asset.bin").write_bytes(b"old")
        os.utime(self.dest / "asset.bin", (1, 1))
        with patch.object(sync, "download", side_effect=self.fake_download), self.assertRaises(ValueError):
            self.call_sync()
        self.assertEqual(list(outside.iterdir()), [])
        self.assertEqual((self.dest / "asset.bin").read_bytes(), b"old")

    def test_json_temporary_symlink_cannot_overwrite_unrelated_file(self):
        outside = self.root / "outside.json"
        outside.write_text("keep")
        (self.state / "state.json.tmp").symlink_to(outside)
        try:
            sync.write_json(self.state / "state.json", {"files": {}})
        except ValueError:
            pass
        self.assertEqual(outside.read_text(), "keep")
        self.assertFalse((self.state / "state.json").is_symlink())

    def test_failed_run_checkpoints_successes_and_keeps_local_only_files(self):
        local = self.dest / "notes.txt"
        local.write_text("local")
        files = {"assets/ok.bin": self.item, "assets/failed.bin": dict(self.item, id="file2")}

        def sync_result(relative, *args):
            if relative.endswith("failed.bin"):
                raise OSError("simulated disk error")
            return "downloaded", self.record()

        with patch.object(sync, "ROOT", self.root), patch.object(sync, "scan", return_value=(files, ["assets"])), patch.object(sync, "sync_one", side_effect=sync_result), patch.object(sync.sys, "argv", ["glory_sync.py"]), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(ValueError):
            sync.main()
        saved = json.loads((self.state / "state.json").read_text())
        result = json.loads((self.state / "last-run.json").read_text())
        self.assertIn("assets/ok.bin", saved["files"])
        self.assertNotIn("assets/failed.bin", saved["files"])
        self.assertEqual(result["status"], "failed")
        self.assertEqual(len(result["errors"]), 1)
        self.assertEqual(local.read_text(), "local")

    def test_all_scope_checkpoints_preservation_and_partial_failure_without_claiming_applied(self):
        relative = "scripts/local.gd"
        target = self.dest / relative
        target.parent.mkdir()
        target.write_bytes(b"mod")
        os.utime(target, (3, 3))
        local_only = self.dest / "local-only.txt"
        local_only.write_text("keep")
        removed = self.dest / "removed-from-cloud.bin"
        removed.write_bytes(b"old")
        sync.write_json(self.state / "state.json", {
            "folder_id": sync.FOLDER_ID, "files": {"removed-from-cloud.bin": self.record()},
        })
        files = {relative: self.item, "assets/good.bin": dict(self.item, id="good"),
                 "assets/failed.bin": dict(self.item, id="failed")}

        def downloading(item, partial):
            if item["id"] == "failed":
                partial.write_bytes(b"unfinished")
                raise requests.ConnectionError("interrupted")
            return self.fake_download(item, partial)

        output = io.StringIO()
        with patch.object(sync, "ROOT", self.root), patch.object(sync, "scan", return_value=(files, ["assets", "scripts"])) as scan, patch.object(sync, "download", side_effect=downloading), patch.object(sync.sys, "argv", ["glory_sync.py", "--all", "--force", "--workers", "1"]), contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(ValueError):
            sync.main()
        self.assertEqual(scan.call_args.args, (sync.FOLDER_ID, True, 1))
        saved = json.loads((self.state / "state.json").read_text())
        report = json.loads((self.state / "last-run.json").read_text())
        for document in (saved, report):
            self.assertEqual(document["counts"]["local_preserved"], 1)
            self.assertEqual(document["counts"]["downloaded"], 1)
            detail = document["local_preserved"][0]
            self.assertEqual(detail["path"], relative)
            self.assertEqual(detail["reason"], "remote_older")
            self.assertEqual(Path(detail["cloud_copy"]).read_bytes(), b"new")
        record = saved["files"][relative]
        self.assertFalse(record["applied"])
        self.assertEqual(record["sync_status"], "local_preserved")
        self.assertEqual(record["sha256"], hashlib.sha256(b"new").hexdigest())
        self.assertEqual(record["local_copy"], dict(sha256=hashlib.sha256(b"mod").hexdigest(), modified_time_ns=3_000_000_000))
        self.assertEqual(report["status"], "failed")
        self.assertIn("assets/good.bin", saved["files"])
        self.assertNotIn("assets/failed.bin", saved["files"])
        self.assertEqual(len(list((self.state / "partial").glob("*.part"))), 1)
        self.assertIn("local_preserved: scripts/local.gd（本地修改时间较新）", output.getvalue())
        self.assertEqual(target.read_bytes(), b"mod")
        self.assertEqual(local_only.read_text(), "keep")
        self.assertEqual(removed.read_bytes(), b"old")


if __name__ == "__main__":
    unittest.main()

class DuplicateResolutionTests(unittest.TestCase):
    def items(self, versions=(2000, 2000), names=('sound.wav', 'sound.wav')):
        return {str(i): dict(id=str(i), name=name, mime='audio/wav',
                            version=[1000, version] if version else None, size=3)
                for i, (name, version) in enumerate(zip(names, versions))}

    def resolve(self, items, hashes=('same', 'same'), second=None):
        def downloaded(item, path):
            return dict(item, sha256=hashes[int(item['id'])], downloaded_size=3)
        with patch.object(sync, 'read_folder', side_effect=[items, items if second is None else second]), \
             patch.object(sync, 'download', side_effect=downloaded), contextlib.redirect_stdout(io.StringIO()):
            return sync.list_folder('folder')

    def test_identical_duplicates_are_deduplicated_with_stable_selection(self):
        items = self.items()
        selected = self.resolve(items)
        reversed_selected = self.resolve(dict(reversed(list(items.items()))))
        self.assertEqual(len(selected), 1)
        self.assertEqual(selected, reversed_selected)
        self.assertEqual(selected[0]['expected_sha256'], 'same')
        self.assertEqual(selected[0]['duplicate_resolution']['reason'], 'identical_sha256')

    def test_different_contents_require_unique_newest(self):
        selected = self.resolve(self.items((2000, 3000)), ('old', 'new'))
        self.assertEqual(selected[0]['id'], '1')
        self.assertEqual(selected[0]['expected_sha256'], 'new')

    def test_ambiguous_different_contents_fail(self):
        for versions in [(2000, 2000), (None, 3000)]:
            with self.subTest(versions=versions), self.assertRaises(ValueError):
                self.resolve(self.items(versions), ('a', 'b'))

    def test_duplicate_folders_and_case_collisions_still_fail(self):
        items = self.items(); items['0']['mime'] = sync.FOLDER_MIME
        for values in [items, self.items(names=('Sound.wav', 'sound.wav'))]:
            with self.assertRaises(ValueError):
                self.resolve(values)

    def test_changed_listing_after_verification_fails(self):
        with self.assertRaises(ValueError):
            self.resolve(self.items(), second={})

    def test_pinned_content_change_during_download_fails(self):
        item = self.items()['0']; item['expected_sha256'] = 'not-the-actual-hash'
        with tempfile.TemporaryDirectory() as folder, \
             patch.object(sync, 'get', return_value=Response(body=b'new')), \
             patch.object(sync.time, 'sleep'), self.assertRaises(ValueError):
            sync.download(item, Path(folder) / 'candidate')
