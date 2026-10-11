"""Offline checks: temporary repositories/files only; no Apple account or device access."""
import contextlib
import copy
import datetime as dt
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest
import zipfile
from unittest import mock

spec = importlib.util.spec_from_file_location("glory_ios_build_tested", Path(__file__).with_name("glory_ios_build.py"))
ios = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ios)


class IOSBuildTests(unittest.TestCase):
    def test_audio_engine_template_rejects_missing_or_stale_proof(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "project"
            patch = project / "deploy/engine/godot-4.7-ios-audio-recovery.patch"
            patch.parent.mkdir(parents=True)
            patch.write_bytes(b"patch")
            templates = Path(directory) / "templates"
            templates.mkdir()
            archive = templates / "ios.zip"
            archive.write_bytes(b"template")
            with self.assertRaises(RuntimeError):
                ios.engine_template_info(project, templates)
            info = {"patch_sha256": ios.shared.digest(patch), "ios_zip_sha256": ios.shared.digest(archive)}
            (templates / "glory-engine.json").write_text(json.dumps(info))
            self.assertEqual(ios.engine_template_info(project, templates), info)
            archive.write_bytes(b"old engine substituted")
            with self.assertRaises(RuntimeError):
                ios.engine_template_info(project, templates)
            archive.write_bytes(b"template")
            patch.write_bytes(b"new patch")
            with self.assertRaises(RuntimeError):
                ios.engine_template_info(project, templates)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.now = dt.datetime(2026, 9, 13, tzinfo=dt.timezone.utc)
        self.profile = {
            "Name": "Fixture", "UUID": "11111111-2222-3333-4444-555555555555", "TeamIdentifier": [ios.TEAM],
            "CreationDate": self.now - dt.timedelta(days=1), "ExpirationDate": self.now + dt.timedelta(days=30),
            "DeveloperCertificates": [b"public certificate fixture"], "ProvisionedDevices": ["TEST-DEVICE"],
            "Entitlements": {"application-identifier": f"{ios.TEAM}.{ios.BUNDLE}",
                             "com.apple.developer.team-identifier": ios.TEAM, "get-task-allow": False},
        }

    def test_profile_requires_matching_team_app_and_distribution_method(self):
        ios.validate_profile_data(self.profile, "ad-hoc", self.now)
        changes = [
            {"TeamIdentifier": ["OTHERTEAM00"]},
            {"Entitlements": dict(self.profile["Entitlements"], **{"application-identifier": ios.TEAM + ".other"})},
            {"Entitlements": dict(self.profile["Entitlements"], **{"get-task-allow": True})},
            {"ProvisionsAllDevices": True}, {"ProvisionedDevices": []},
            {"ExpirationDate": self.now}, {"CreationDate": self.now + dt.timedelta(seconds=1)},
            {"DeveloperCertificates": []}, {"UUID": "not-a-uuid"},
        ]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                ios.validate_profile_data(dict(self.profile, **change), "ad-hoc", self.now)
        with self.assertRaises(RuntimeError):
            ios.validate_profile_data(self.profile, "app-store", self.now)
        store = dict(self.profile)
        store.pop("ProvisionedDevices")
        ios.validate_profile_data(store, "app-store", self.now)

    def test_naive_apple_plist_dates_are_treated_as_utc(self):
        profile = copy.deepcopy(self.profile)
        for key in ("CreationDate", "ExpirationDate"):
            profile[key] = profile[key].replace(tzinfo=None)
        ios.validate_profile_data(profile, "ad-hoc", self.now)

    def test_build_number_starts_at_two_and_persists_reservations(self):
        state = self.root / "state.json"
        self.assertEqual(ios.reserve_build_number(state), "2")
        self.assertEqual(ios.reserve_build_number(state), "3")
        self.assertEqual(ios.reserve_build_number(state, "10.2"), "10.2")
        self.assertEqual(ios.reserve_build_number(state), "11")
        # Reusing a number would fail an upload; explicit numbers only move forward.
        for requested in ("8", "11", "11.0", "11.0.0"):
            with self.subTest(requested=requested), self.assertRaises(RuntimeError):
                ios.reserve_build_number(state, requested)
        self.assertEqual(ios.reserve_build_number(state), "12")

    def test_invalid_build_numbers_do_not_change_persistent_state(self):
        state = self.root / "state.json"
        ios.reserve_build_number(state)
        before = state.read_bytes()
        for value in ("1", "0", "-1", "10000", "1.100", "1.2.100", "2beta", "2.3.4.5", "02"):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                ios.reserve_build_number(state, value)
            self.assertEqual(state.read_bytes(), before)
        self.assertEqual(ios.next_build_number("9999"), "9999.0.1")
        self.assertEqual(ios.next_build_number("9999.0.99"), "9999.1.0")

    def test_marketing_version_uses_only_explicit_config_or_override(self):
        config = self.root / "project.godot"
        config.write_text('[application]\nconfig/name="Glory Beta 99.99"\n')
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(ios.project_version(self.root), "0.0.4")
        self.assertIn("0.0.4", output.getvalue())
        config.write_text('[application]\nconfig/version="1.2.3"\n[rendering]\n')
        self.assertEqual(ios.project_version(self.root), "1.2.3")
        self.assertEqual(ios.project_version(self.root, "2.0.0"), "2.0.0")
        with self.assertRaises(RuntimeError):
            ios.project_version(self.root, "2.0.0-beta1")

    def test_unlock_failure_does_not_disclose_password(self):
        password = self.root / "password"
        password.write_text("DO-NOT-PRINT-THIS-TEST-SECRET\n")
        with mock.patch.object(ios.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)):
            with self.assertRaises(RuntimeError) as error:
                ios.unlock_keychain(self.root / "keychain", password)
        self.assertNotIn("DO-NOT-PRINT", str(error.exception))
        with mock.patch.object(ios.subprocess, "run", side_effect=OSError("DO-NOT-PRINT-THIS-TEST-SECRET")):
            with self.assertRaises(RuntimeError) as error:
                ios.unlock_keychain(self.root / "keychain", password)
        self.assertNotIn("DO-NOT-PRINT", str(error.exception))

    def test_profile_certificate_must_match_valid_keychain_identity(self):
        keychain = self.root / "keychain"
        keychain.touch()
        cert = {"sha1": "A" * 40, "name": "Apple Distribution: Fixture", "not_before": dt.datetime(2020, 1, 1, tzinfo=dt.timezone.utc),
                "not_after": dt.datetime(2099, 1, 1, tzinfo=dt.timezone.utc)}
        with mock.patch.object(ios, "certificate_details", return_value=cert), mock.patch.object(ios, "capture", return_value=("1) " + "B" * 40).encode()):
            with self.assertRaises(RuntimeError):
                ios.select_identity(self.profile, keychain)
        with mock.patch.object(ios, "certificate_details", return_value=cert), mock.patch.object(ios, "capture", return_value=("1) " + "A" * 40).encode()):
            self.assertEqual(ios.select_identity(self.profile, keychain)["sha1"], "A" * 40)

    def test_pck_build_identity_checks_content_digest(self):
        data = b'{"build_number":"2"}'
        name = b"res://build_info.json"
        pack = self.root / "test.pck"
        header = struct.pack("<6IQQ", 0x43504447, 4, 4, 7, 0, 2, 40, 40 + len(data))
        directory = struct.pack("<II", 1, len(name)) + name + struct.pack("<QQ", 0, len(data)) + hashlib.md5(data).digest() + struct.pack("<I", 0)
        pack.write_bytes(header + data + directory)
        self.assertEqual(json.loads(ios.pck_file(pack, "build_info.json"))["build_number"], "2")
        pack.write_bytes(header + b"X" + data[1:] + directory)
        with self.assertRaises(RuntimeError):
            ios.pck_file(pack, "build_info.json")

    def test_preset_selects_profile_uuid_instead_of_shared_display_name(self):
        stage = self.root / "project"
        stage.mkdir()
        preset = stage / "export_presets.cfg"
        preset.write_text('[preset.0]\nname="Android"\nplatform="Android"\ninclude_filter=""\nexclude_filter=""\n[preset.0.options]\npackage/unique_name="com.glory.game"\n')
        cert = {"name": "iPhone Distribution: Fixture"}
        ios.write_preset(stage, "ad-hoc", self.profile, cert, "0.0.4", "2")
        text = preset.read_text()
        self.assertNotIn("addons/glory_voice/glory_voice.gdextension", text)
        self.assertIn('application/export_method_release=2', text)
        self.assertIn('application/provisioning_profile_specifier_release="' + self.profile["UUID"] + '"', text)
        self.assertIn('icons/icon_1024x1024="res://app_icon.png"', text)
        self.assertNotIn('provisioning_profile_specifier_release="Fixture"', text)

    def test_certificate_extraction_prefix_is_one_option_even_with_spaces(self):
        ipa = self.root / "fixture.ipa"
        destination = self.root / "verify with spaces"
        leaf = b"public signing certificate fixture"
        cert = {"sha1": hashlib.sha1(leaf).hexdigest().upper()}
        identity = {"build_number": "2"}
        info = {"CFBundleIdentifier": ios.BUNDLE, "CFBundleShortVersionString": "0.0.4", "CFBundleVersion": "2",
                "CFBundleExecutable": "Fixture", "CFBundleSupportedPlatforms": ["iPhoneOS"], "NSMicrophoneUsageDescription": "Voice"}
        with zipfile.ZipFile(ipa, "w") as archive:
            for name, data in {"Info.plist": plistlib.dumps(info), "Fixture": b"arm64 fixture",
                               "Fixture.pck": b"pck fixture", "embedded.mobileprovision": b"profile fixture",
                               "Frameworks/GloryVoice.framework/GloryVoice": b"voice fixture",
                               "Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC": b"rtc fixture",
                               "Frameworks/RustLiveKitUniFFI.framework/RustLiveKitUniFFI": b"ffi fixture"}.items():
                archive.writestr("Payload/Fixture.app/" + name, data)

        def tool(command, **kwargs):
            if command[0] == "/usr/bin/ditto":
                with zipfile.ZipFile(command[3]) as archive:
                    archive.extractall(command[4])
            elif "--extract-certificates" in command:
                raise RuntimeError("Separate prefix was interpreted as another codesign input")
            elif any(str(arg).startswith("--extract-certificates=") for arg in command):
                self.assertEqual(len(command), 4)
                prefix = str(command[2]).split("=", 1)[1]
                Path(prefix + "0").write_bytes(leaf)
            elif "--entitlements" in command:
                return plistlib.dumps(self.profile["Entitlements"])
            elif "lipo" in command:
                return b"arm64\n"
            return b""

        with mock.patch.object(ios, "capture", side_effect=tool), mock.patch.object(ios, "read_profile", return_value=self.profile), \
                mock.patch.object(ios, "pck_file", return_value=json.dumps(identity).encode()):
            result = ios.verify_ipa(ipa, destination, "ad-hoc", self.profile, cert, "0.0.4", "2", identity, {})
            with self.assertRaisesRegex(RuntimeError, "音频驱动恢复补丁"):
                ios.verify_ipa(ipa, destination, "ad-hoc", self.profile, cert, "0.0.4", "2",
                               dict(identity, engine_info={"patched": True}), {})
        self.assertTrue(result["codesign"])
        self.assertTrue((destination / "signer-0").is_file())

        # A signed-looking package without the native bridge must never pass.
        missing_voice = self.root / "missing-voice.ipa"
        with zipfile.ZipFile(ipa) as source, zipfile.ZipFile(missing_voice, "w") as target:
            for name in source.namelist():
                if "GloryVoice.framework/GloryVoice" not in name:
                    target.writestr(name, source.read(name))
        with mock.patch.object(ios, "capture", side_effect=tool):
            with self.assertRaisesRegex(RuntimeError, "GloryVoice.framework"):
                ios.verify_ipa(missing_voice, self.root / "missing-verify", "ad-hoc",
                               self.profile, cert, "0.0.4", "2", identity, {})

    def test_check_path_does_not_unlock_sync_stage_reserve_or_publish(self):
        project = self.root / "project"
        project.mkdir()
        (project / "project.godot").write_text('[application]\nconfig/version="0.0.4"\n')
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(ios, "ROOT", self.root))
            password = self.root / "password"
            password.touch()
            stack.enter_context(mock.patch.object(ios, "PASSWORD_FILE", password))
            stack.enter_context(mock.patch.object(ios, "environment", return_value={"version": "4.7", "xcode": "Xcode", "child": {}}))
            stack.enter_context(mock.patch.object(ios, "read_profile", return_value=self.profile))
            stack.enter_context(mock.patch.object(ios, "select_identity", return_value={"name": "Fixture"}))
            stack.enter_context(mock.patch.object(ios.shared, "asset_root", return_value=self.root))
            git_ready = stack.enter_context(mock.patch.object(ios, "git_update_ready", side_effect=AssertionError("check must not require a clean Git tree")))
            forbidden = [stack.enter_context(mock.patch.object(ios, name, side_effect=AssertionError(name)))
                         for name in ("unlock_keychain", "update_sources", "reserve_build_number", "install_profile", "publish")]
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            ios.main(["--check", "--update", "--project", str(project)])
            git_ready.assert_not_called()
            self.assertFalse((self.root / "build").exists())
            for call in forbidden:
                call.assert_not_called()


class GitUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.environment = mock.patch.dict(os.environ, {
            "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.origin = self.root / "origin.git"
        self.seed = self.root / "seed"
        self.repo = self.root / "working"
        self.git(self.root, "init", "--bare", str(self.origin))
        self.git(self.root, "init", "-b", "main", str(self.seed))
        self.identity(self.seed)
        self.commit(self.seed, "base")
        self.git(self.seed, "remote", "add", "origin", str(self.origin))
        self.git(self.seed, "push", "-u", "origin", "main")
        self.git(self.root, "clone", "-b", "main", str(self.origin), str(self.repo))
        self.identity(self.repo)

    def git(self, folder, *args):
        return subprocess.check_output(["git", "-C", str(folder), *args], stderr=subprocess.STDOUT, text=True).strip()

    def identity(self, repo):
        self.git(repo, "config", "user.name", "Offline Test")
        self.git(repo, "config", "user.email", "offline@example.invalid")

    def commit(self, repo, name):
        (repo / (name + ".txt")).write_text(name)
        self.git(repo, "add", ".")
        self.git(repo, "commit", "-m", name)
        return self.git(repo, "rev-parse", "HEAD")

    def update(self):
        logs = self.root / "logs"
        logs.mkdir(exist_ok=True)
        self.update_calls = []
        def runner(command, log, env):
            self.update_calls.append([str(value) for value in command])
            if str(command[0]) == "git":
                return subprocess.check_output([str(v) for v in command], stderr=subprocess.STDOUT, text=True)
            self.assertEqual(command, [Path(ios.__file__).resolve().with_name("sync_res.sh")])
            return "sync fixture"
        with mock.patch.object(ios, "ROOT", self.root), mock.patch.object(ios, "run", side_effect=runner), \
             contextlib.redirect_stdout(io.StringIO()):
            ios.update_sources(self.repo, logs, {})

    def test_fast_forward_updates_current_upstream(self):
        commit = self.commit(self.seed, "remote")
        self.git(self.seed, "push")
        self.update()
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), commit)

    def test_dirty_and_no_upstream_are_rejected_without_changing_head(self):
        old = self.git(self.repo, "rev-parse", "HEAD")
        (self.repo / "untracked").touch()
        with self.assertRaises(RuntimeError):
            ios.git_update_ready(self.repo)
        (self.repo / "untracked").unlink()
        self.git(self.repo, "branch", "--unset-upstream")
        with self.assertRaises(RuntimeError):
            ios.git_update_ready(self.repo)
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), old)

    def test_divergence_is_rejected_and_local_commit_preserved(self):
        local = self.commit(self.repo, "local")
        self.commit(self.seed, "remote")
        self.git(self.seed, "push")
        with self.assertRaises(subprocess.CalledProcessError):
            self.update()
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), local)
        self.assertFalse(self.git(self.repo, "status", "--porcelain"))

    def test_local_ahead_commits_are_preserved(self):
        local = self.commit(self.repo, "local")
        self.update()
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), local)

    def assert_ignored_collision_stops_before_drive(self, incoming, local):
        # Ignore only in this checkout; the remote is allowed to begin tracking it.
        with (self.repo / ".git/info/exclude").open("a") as stream:
            stream.write("\n/local-cache/\n")
        local_path = self.repo / local
        local_path.parent.mkdir(parents=True, exist_ok=True)
        local_path.write_text("local ignored content must survive\n")
        self.assertEqual(self.git(self.repo, "status", "--porcelain"), "")
        before = self.git(self.repo, "rev-parse", "HEAD")
        remote_path = self.seed / incoming
        remote_path.parent.mkdir(parents=True, exist_ok=True)
        remote_path.write_text("remote newly tracked content\n")
        remote = self.commit(self.seed, "remote-collision")
        self.git(self.seed, "push")
        with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
            self.update()
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), before)
        self.assertEqual(self.git(self.repo, "rev-parse", "origin/main"), remote)
        self.assertEqual(local_path.read_text(), "local ignored content must survive\n")
        self.assertEqual(self.git(self.repo, "status", "--porcelain"), "")
        self.assertTrue(self.update_calls)
        self.assertTrue(all(command[0] == "git" for command in self.update_calls), "Drive must not run after Git refusal")

    def test_remote_new_file_cannot_overwrite_local_ignored_file(self):
        self.assert_ignored_collision_stops_before_drive("local-cache/asset.txt", "local-cache/asset.txt")

    def test_remote_file_cannot_replace_local_ignored_directory(self):
        self.assert_ignored_collision_stops_before_drive("local-cache/collision", "local-cache/collision/keep.txt")

    def test_unrelated_ignored_cache_allows_real_fast_forward_then_drive(self):
        with (self.repo / ".git/info/exclude").open("a") as stream:
            stream.write("\n/local-cache/\n")
        cache = self.repo / "local-cache/keep.txt"
        cache.parent.mkdir()
        cache.write_text("keep ignored cache\n")
        remote = self.commit(self.seed, "remote")
        self.git(self.seed, "push")
        self.update()
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), remote)
        self.assertEqual(cache.read_text(), "keep ignored cache\n")
        self.assertEqual(self.update_calls[-1], [str(Path(ios.__file__).resolve().with_name("sync_res.sh"))])
        self.assertEqual(self.git(self.repo, "status", "--porcelain"), "")


if __name__ == "__main__":
    unittest.main()
