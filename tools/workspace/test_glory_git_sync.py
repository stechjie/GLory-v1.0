"""Offline Git sync regressions; repositories and assets live in temporary directories."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "glory_build_git_sync", Path(__file__).with_name("glory_build.py")
)
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)
SYNC_ERRORS = (RuntimeError, subprocess.CalledProcessError)


class GitSyncTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="glory-git-sync-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.environment = mock.patch.dict(os.environ, {
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.remote = self.root / "remote.git"
        self.seed = self.root / "seed"
        self.checkout = self.root / "checkout"
        self.git(self.root, "init", "--bare", "--initial-branch=main", self.remote)
        self.git(self.root, "init", "--initial-branch=main", self.seed)
        self.write(self.seed, "project.godot", '[application]\nconfig/name="Test"\n')
        self.write(self.seed, "game.gd", "# first version\n")
        self.write(self.seed, "assets/texture.txt", "first asset\n")
        self.write(self.seed, ".gitignore", "/.godot/\n")
        self.commit(self.seed, "initial project")
        self.git(self.seed, "remote", "add", "origin", self.remote)
        self.git(self.seed, "push", "--set-upstream", "origin", "main")
        self.git(self.root, "clone", self.remote, self.checkout)
        self.initial_head = self.git(self.checkout, "rev-parse", "HEAD")

    def git(self, folder, *arguments):
        return subprocess.check_output(
            ["git", "-c", "user.name=GLory Sync Test",
             "-c", "user.email=glory-sync-test@example.invalid",
             "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
             "-C", str(folder), *map(str, arguments)],
            text=True, stderr=subprocess.STDOUT,
        ).strip()

    def write(self, folder, relative, content):
        target = folder / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")

    def commit(self, folder, message):
        self.git(folder, "add", "--all")
        self.git(folder, "commit", "-m", message)
        return self.git(folder, "rev-parse", "HEAD")

    def advance_remote(self):
        self.write(self.seed, "game.gd", "# latest code\n")
        self.write(self.seed, "assets/texture.txt", "latest tracked asset\n")
        self.write(self.seed, "assets/new-resource.txt", "new tracked asset\n")
        head = self.commit(self.seed, "update code and resources")
        self.git(self.seed, "push", "origin", "main")
        return head

    def synchronize(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return build.sync_project(self.checkout)

    def assert_head(self, head):
        self.assertEqual(self.git(self.checkout, "rev-parse", "HEAD"), head)

    def test_fast_forward_downloads_code_and_tracked_assets(self):
        latest = self.advance_remote()
        self.synchronize()
        self.assert_head(latest)
        self.assertEqual((self.checkout / "game.gd").read_text(), "# latest code\n")
        self.assertEqual((self.checkout / "assets/texture.txt").read_text(), "latest tracked asset\n")
        self.assertEqual((self.checkout / "assets/new-resource.txt").read_text(), "new tracked asset\n")
        self.assertEqual(self.git(self.checkout, "status", "--porcelain"), "")

    def test_current_branch_is_successful_noop(self):
        self.synchronize()
        self.assert_head(self.initial_head)

    def test_modified_file_is_preserved_and_sync_refused(self):
        self.advance_remote()
        self.write(self.checkout, "game.gd", "# unfinished local work\n")
        with self.assertRaises(SYNC_ERRORS):
            self.synchronize()
        self.assert_head(self.initial_head)
        self.assertEqual((self.checkout / "game.gd").read_text(), "# unfinished local work\n")
        self.assertEqual((self.checkout / "assets/texture.txt").read_text(), "first asset\n")

    def test_staged_file_is_preserved_and_sync_refused(self):
        self.advance_remote()
        self.write(self.checkout, "game.gd", "# staged local work\n")
        self.git(self.checkout, "add", "game.gd")
        staged = self.git(self.checkout, "diff", "--cached")
        with self.assertRaises(SYNC_ERRORS):
            self.synchronize()
        self.assert_head(self.initial_head)
        self.assertEqual(self.git(self.checkout, "diff", "--cached"), staged)

    def test_untracked_file_is_preserved_and_sync_refused(self):
        self.advance_remote()
        self.write(self.checkout, "local-notes.txt", "uncommitted notes\n")
        with self.assertRaises(SYNC_ERRORS):
            self.synchronize()
        self.assert_head(self.initial_head)
        self.assertEqual((self.checkout / "local-notes.txt").read_text(), "uncommitted notes\n")

    def test_ignored_godot_cache_does_not_prevent_sync(self):
        latest = self.advance_remote()
        self.write(self.checkout, ".godot/cache.txt", "disposable cache\n")
        self.synchronize()
        self.assert_head(latest)
        self.assertEqual((self.checkout / ".godot/cache.txt").read_text(), "disposable cache\n")

    def assert_ignored_collision_stops_before_drive(self, incoming, local):
        self.write(self.checkout, local, "local ignored content must survive\n")
        self.assertEqual(self.git(self.checkout, "status", "--porcelain"), "")
        self.write(self.seed, incoming, "remote newly tracked content\n")
        self.git(self.seed, "add", "--force", incoming)
        remote_head = self.commit(self.seed, "track a formerly ignored path")
        self.git(self.seed, "push", "origin", "main")
        real_run = subprocess.run
        drive_calls = []

        def run(command, *args, **kwargs):
            if command == [str(Path(build.__file__).resolve().with_name("sync_res.sh"))]:
                drive_calls.append(command)
                raise AssertionError("Drive must not run after an ignored-file collision")
            return real_run(command, *args, **kwargs)

        with mock.patch.object(build, "ROOT", self.root), \
             mock.patch("sys.argv", ["glory_build.py", "--project", str(self.checkout), "--sync"]), \
             mock.patch.object(build.subprocess, "run", side_effect=run), \
             mock.patch.object(build, "environment") as environment, \
             mock.patch.object(build, "stage_project") as stage, \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SYNC_ERRORS):
                build.main()
        self.assert_head(self.initial_head)
        self.assertEqual(self.git(self.checkout, "rev-parse", "origin/main"), remote_head,
                         "The collision should be detected after fetching the new remote commit")
        self.assertEqual((self.checkout / local).read_text(), "local ignored content must survive\n")
        self.assertEqual(self.git(self.checkout, "status", "--porcelain"), "")
        self.assertEqual(drive_calls, [])
        environment.assert_not_called()
        stage.assert_not_called()

    def test_remote_new_file_cannot_overwrite_local_ignored_file(self):
        self.assert_ignored_collision_stops_before_drive(".godot/cache.txt", ".godot/cache.txt")

    def test_remote_file_cannot_replace_local_ignored_directory(self):
        self.assert_ignored_collision_stops_before_drive(".godot/collision", ".godot/collision/keep.txt")

    def test_missing_upstream_is_refused(self):
        self.git(self.checkout, "branch", "--unset-upstream")
        with self.assertRaises(SYNC_ERRORS):
            self.synchronize()
        self.assert_head(self.initial_head)

    def test_detached_head_is_refused(self):
        self.git(self.checkout, "checkout", "--detach")
        with self.assertRaises(SYNC_ERRORS):
            self.synchronize()
        self.assert_head(self.initial_head)

    def test_local_only_commit_is_refused_without_resetting(self):
        self.write(self.checkout, "local-feature.txt", "local commit\n")
        local_head = self.commit(self.checkout, "local-only commit")
        with self.assertRaises(SYNC_ERRORS):
            self.synchronize()
        self.assert_head(local_head)
        self.assertEqual((self.checkout / "local-feature.txt").read_text(), "local commit\n")

    def test_diverged_history_is_refused_without_merging(self):
        self.advance_remote()
        self.write(self.checkout, "local-feature.txt", "independent local commit\n")
        local_head = self.commit(self.checkout, "local-only commit")
        with self.assertRaises(SYNC_ERRORS):
            self.synchronize()
        self.assert_head(local_head)
        self.assertEqual((self.checkout / "game.gd").read_text(), "# first version\n")
        self.assertEqual(self.git(self.checkout, "status", "--porcelain"), "")

    def test_unavailable_remote_does_not_change_checkout(self):
        self.git(self.checkout, "remote", "set-url", "origin", self.root / "missing.git")
        with self.assertRaises(SYNC_ERRORS):
            self.synchronize()
        self.assert_head(self.initial_head)
        self.assertEqual(self.git(self.checkout, "status", "--porcelain"), "")

    def test_merge_failure_after_fetch_stops_drive_and_build(self):
        self.advance_remote()
        real_run = subprocess.run
        calls = []

        def run(command, *args, **kwargs):
            if command == [str(Path(build.__file__).resolve().with_name("sync_res.sh"))]:
                calls.append("drive")
                return subprocess.CompletedProcess(command, 0)
            if command[0] == "git" and "merge" in command:
                calls.append("merge")
                raise subprocess.CalledProcessError(1, command)
            return real_run(command, *args, **kwargs)

        with mock.patch.object(build, "ROOT", self.root), \
             mock.patch("sys.argv", ["glory_build.py", "--project", str(self.checkout), "--sync"]), \
             mock.patch.object(build.subprocess, "run", side_effect=run), \
             mock.patch.object(build, "environment") as environment, \
             mock.patch.object(build, "stage_project") as stage, \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SYNC_ERRORS):
                build.main()
        self.assertEqual(calls, ["merge"])
        environment.assert_not_called()
        stage.assert_not_called()
        self.assert_head(self.initial_head)


class StopBeforeBuild(RuntimeError):
    """Test sentinel used to stop immediately after synchronization."""


class MainSyncOrderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="glory-main-sync-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.project = self.root / "project"
        self.project.mkdir()
        (self.project / "project.godot").write_text('[application]\nconfig/name="Test"\n')

    def invoke(self, project=None, synchronize=True):
        arguments = ["glory_build.py", "--project", str(project or self.project)]
        if synchronize:
            arguments.append("--sync")
        with mock.patch.object(build, "ROOT", self.root), \
             mock.patch("sys.argv", arguments), \
             contextlib.redirect_stdout(io.StringIO()):
            build.main()

    def test_check_with_sync_is_read_only(self):
        env = dict(version="4.7", major_minor="4.7", java="jdk", sdk="sdk")
        with mock.patch.object(build, "ROOT", self.root), \
             mock.patch("sys.argv", ["glory_build.py", "--project", str(self.project), "--sync", "--check"]), \
             mock.patch.object(build, "sync_project") as git_sync, \
             mock.patch.object(build.subprocess, "run") as run, \
             mock.patch.object(build, "environment", return_value=env), \
             mock.patch.object(build, "asset_root", return_value=self.root / "assets"), \
             mock.patch.object(build, "stage_project") as stage, \
             contextlib.redirect_stdout(io.StringIO()):
            build.main()
        git_sync.assert_not_called()
        run.assert_not_called()
        stage.assert_not_called()

    def test_sync_sequence_git_then_drive_then_environment(self):
        calls = []

        def git_sync(project):
            self.assertEqual(project, self.project)
            calls.append("git")

        def drive_sync(command, **kwargs):
            self.assertEqual(command, [str(Path(build.__file__).resolve().with_name("sync_res.sh"))])
            self.assertTrue(kwargs.get("check"))
            calls.append("drive")

        def environment(args):
            calls.append("environment")
            raise StopBeforeBuild()

        with mock.patch.object(build, "sync_project", side_effect=git_sync), \
             mock.patch.object(build.subprocess, "run", side_effect=drive_sync), \
             mock.patch.object(build, "environment", side_effect=environment):
            with self.assertRaises(StopBeforeBuild):
                self.invoke()
        self.assertEqual(calls, ["git", "drive", "environment"])

    def test_invalid_project_is_refused_before_any_sync(self):
        with mock.patch.object(build, "sync_project") as git_sync, \
             mock.patch.object(build.subprocess, "run") as drive_sync, \
             mock.patch.object(build, "environment") as environment:
            with self.assertRaises(RuntimeError):
                self.invoke(self.root / "not-a-project")
        git_sync.assert_not_called()
        drive_sync.assert_not_called()
        environment.assert_not_called()

    def test_git_failure_stops_drive_sync_and_build(self):
        failure = subprocess.CalledProcessError(1, ["git", "merge", "--ff-only", "--no-overwrite-ignore", "@{upstream}"])
        with mock.patch.object(build, "sync_project", side_effect=failure) as git_sync, \
             mock.patch.object(build.subprocess, "run") as drive_sync, \
             mock.patch.object(build, "environment") as environment, \
             mock.patch.object(build, "stage_project") as stage:
            with self.assertRaises(subprocess.CalledProcessError):
                self.invoke()
        git_sync.assert_called_once_with(self.project)
        drive_sync.assert_not_called()
        environment.assert_not_called()
        stage.assert_not_called()

    def test_drive_failure_stops_build(self):
        failure = subprocess.CalledProcessError(1, [str(Path(build.__file__).resolve().with_name("sync_res.sh"))])
        with mock.patch.object(build, "sync_project") as git_sync, \
             mock.patch.object(build.subprocess, "run", side_effect=failure), \
             mock.patch.object(build, "environment") as environment, \
             mock.patch.object(build, "stage_project") as stage:
            with self.assertRaises(subprocess.CalledProcessError):
                self.invoke()
        git_sync.assert_called_once_with(self.project)
        environment.assert_not_called()
        stage.assert_not_called()

    def test_without_sync_does_not_update_git_or_drive(self):
        with mock.patch.object(build, "sync_project") as git_sync, \
             mock.patch.object(build.subprocess, "run") as drive_sync, \
             mock.patch.object(build, "environment", side_effect=StopBeforeBuild):
            with self.assertRaises(StopBeforeBuild):
                self.invoke(synchronize=False)
        git_sync.assert_not_called()
        drive_sync.assert_not_called()


if __name__ == "__main__":
    unittest.main()
