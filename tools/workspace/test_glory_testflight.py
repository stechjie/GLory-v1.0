"""Offline TestFlight workflow checks; all files live in temporary directories.

Apple clients, subprocesses, and network connections fail closed unless a test
explicitly supplies a mock. No signing key, build, or real release state is used.
"""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock
import zipfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("glory_testflight_tested", Path(__file__).with_name("glory_testflight.py"))
tf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tf)


class TestFlightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="glory-testflight-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        for name, value in {
            "ROOT": self.root,
            "RELEASE_DIR": self.root / "releases",
            "LATEST": self.root / "latest.json",
            "CONFIG_DIR": self.root / "config",
            "CONFIG_FILE": self.root / "config/api.json",
            "DEFAULT_NOTES": self.root / "notes.txt",
        }.items():
            self.stack.enter_context(mock.patch.object(tf, name, value))
        self.stack.enter_context(mock.patch.object(tf.ios, "ROOT", self.root))
        self.stack.enter_context(mock.patch.object(tf.ios.shared, "ROOT", self.root))
        self.stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
        self.process = self.stack.enter_context(mock.patch.object(
            tf.subprocess, "run", side_effect=AssertionError("Unexpected subprocess")))
        self.client_factory = self.stack.enter_context(mock.patch.object(
            tf, "Client", side_effect=AssertionError("Unexpected real Apple client")))
        self.stack.enter_context(mock.patch("socket.create_connection", side_effect=AssertionError("Network forbidden")))
        self.stack.enter_context(mock.patch("urllib.request.urlopen", side_effect=AssertionError("Network forbidden")))
        self.sleep = self.stack.enter_context(mock.patch.object(
            tf.time, "sleep", side_effect=AssertionError("Unexpected real wait")))
        real_atomic_json = tf.ios.atomic_json

        def temporary_json(path, value):
            self.assertTrue(Path(path).resolve().is_relative_to(self.root), str(path))
            return real_atomic_json(path, value)

        self.atomic_json = self.stack.enter_context(mock.patch.object(tf.ios, "atomic_json", side_effect=temporary_json))
        self.client = mock.Mock(spec=["request", "items"])
        self.client.request.side_effect = AssertionError("Unexpected API request")
        self.client.items.side_effect = AssertionError("Unexpected API list")
        self.credentials = types.SimpleNamespace(
            key_id="FIXTUREKEY1", issuer_id="11111111-2222-3333-4444-555555555555", key_path=self.root / "unused.p8")
        self.metadata = {"version": "0.0.4", "build_number": "12", "ipa": str(self.root / "fixture.ipa")}
        self.state = {"phase": "built", "build_number": "12"}
        self.state_path = tf.RELEASE_DIR / "fixture/state.json"

    def write_json(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data), encoding="utf-8")

    def app(self, **attributes):
        return {"data": {"id": tf.APP_ID, "attributes": {"bundleId": tf.ios.BUNDLE, "name": "Glory", **attributes}}}

    def group(self, **attributes):
        return {"id": tf.GROUP_ID, "attributes": {"isInternalGroup": True, "name": tf.GROUP_NAME, **attributes}}

    def build(self, processing="VALID", **attributes):
        return {"id": "build-fixture", "attributes": {"processingState": processing, "expired": False, **attributes}}

    def localization(self, notes):
        return {"id": "localization-fixture", "attributes": {"locale": "zh-Hans", "whatsNew": notes}}

    def configure_preflight(self, app=None, groups=None):
        self.client.request.side_effect = None
        self.client.request.return_value = app if app is not None else self.app()
        self.client.items.side_effect = None
        self.client.items.return_value = groups if groups is not None else [self.group()]

    def assert_no_local_writes(self):
        self.atomic_json.assert_not_called()
        self.process.assert_not_called()
        self.assertFalse(tf.LATEST.exists())
        self.assertFalse(tf.RELEASE_DIR.exists())

    def make_ipa(self, **overrides):
        info = {"CFBundleIdentifier": tf.ios.BUNDLE, "CFBundleShortVersionString": "0.0.4", "CFBundleVersion": "12"}
        info.update(overrides)
        ipa = self.root / "fixture.ipa"
        with zipfile.ZipFile(ipa, "w") as archive:
            archive.writestr("Payload/Fixture.app/Info.plist", plistlib.dumps(info))
        return {**self.metadata, "method": "app-store", "package_id": tf.ios.BUNDLE,
                "built": True, "signed": True,
                "validation": {key: True for key in ("zip_crc", "codesign", "arm64", "pck_identity")},
                "ipa_sha256": hashlib.sha256(ipa.read_bytes()).hexdigest()}

    def test_preflight_accepts_only_expected_app_and_internal_group_without_writes(self):
        self.configure_preflight()
        tf.preflight(self.client)
        self.client.request.assert_called_once_with("GET", f"/apps/{tf.APP_ID}")
        self.client.items.assert_called_once_with("/betaGroups", {
            "filter[app]": tf.APP_ID, "filter[isInternalGroup]": "true", "limit": 200})
        self.assert_no_local_writes()

    def test_preflight_rejects_wrong_app_id_or_bundle_before_group_lookup(self):
        for app in (self.app(bundleId="other.app"), {"data": {"id": "other-id", "attributes": {"bundleId": tf.ios.BUNDLE}}}):
            with self.subTest(app=app):
                self.configure_preflight(app=app)
                self.client.items.reset_mock()
                with self.assertRaisesRegex(RuntimeError, "应用不匹配"):
                    tf.preflight(self.client)
                self.client.items.assert_not_called()
        self.assert_no_local_writes()

    def test_preflight_rejects_missing_external_or_renamed_group(self):
        cases = [[], [{"id": "other", "attributes": self.group()["attributes"]}],
                 [self.group(isInternalGroup=False)], [self.group(isInternalGroup="true")],
                 [self.group(name="Unexpected name")]]
        for groups in cases:
            with self.subTest(groups=groups):
                self.configure_preflight(groups=groups)
                with self.assertRaises(RuntimeError):
                    tf.preflight(self.client)
        self.assert_no_local_writes()

    def test_next_number_uses_numeric_maximum_of_local_builds_and_pending_uploads(self):
        cases = [("9", ["10", "2"], ["11"], "12"),
                 ("20", ["9", "10"], ["11"], "21"),
                 ("2", ["99", "100"], ["9"], "101"),
                 ("9999.9.99", ["9999.10.1"], ["9999.10.9"], "9999.10.10")]
        local = self.root / "build/ios-auto-work/build-number.json"
        for local_number, builds, uploads, expected in cases:
            with self.subTest(local=local_number, builds=builds, uploads=uploads):
                self.write_json(local, {"last_build_number": local_number})
                before = local.read_bytes()
                self.client.items.side_effect = [
                    [{"attributes": {"version": value}} for value in builds],
                    [{"attributes": {"cfBundleVersion": value}} for value in uploads]]
                self.assertEqual(tf.next_number(self.client), expected)
                self.assertEqual(local.read_bytes(), before)
        self.assert_no_local_writes()
        for call in self.client.items.call_args_list:
            self.assertNotIn("filter[preReleaseVersion.version]", call.args[1])

    def test_next_number_defaults_to_two_and_rejects_invalid_or_exhausted_numbers(self):
        self.client.items.side_effect = [[], []]
        self.assertEqual(tf.next_number(self.client), "2")
        for value in ("not-a-number", "9999.99.99"):
            with self.subTest(value=value):
                self.client.items.side_effect = [[{"attributes": {"version": value}}], []]
                with self.assertRaisesRegex(RuntimeError, "自动递增"):
                    tf.next_number(self.client)
        self.assert_no_local_writes()

    def test_upload_attempt_marker_prevents_second_subprocess_or_remote_mutation(self):
        for phase in ("uploading", "processing", "distributing", "complete"):
            with self.subTest(phase=phase):
                state = {"phase": phase, "upload_attempted": True}
                before = copy.deepcopy(state)
                tf.upload(self.client, self.credentials, self.metadata, state, self.state_path)
                self.assertEqual(state, before)
        self.client.request.assert_not_called()
        self.client.items.assert_not_called()
        self.assert_no_local_writes()

    def test_upload_without_attempt_rejects_existing_build_or_pending_upload(self):
        for builds, uploads in [([self.build()], []), ([], [{"attributes": {"cfBundleVersion": "12"}}])]:
            with self.subTest(builds=builds, uploads=uploads):
                self.client.items.side_effect = [builds, uploads] if not builds else [builds]
                with self.assertRaisesRegex(RuntimeError, "已存在相同"):
                    tf.upload(self.client, self.credentials, self.metadata, self.state, self.state_path)
                self.assertNotIn("upload_attempted", self.state)
        self.client.request.assert_not_called()
        self.assert_no_local_writes()

    def test_upload_persists_attempt_before_subprocess_and_redacts_output(self):
        self.client.items.side_effect = [[], []]

        def upload_command(command, **kwargs):
            persisted = tf.read_json(self.state_path)
            self.assertTrue(persisted["upload_attempted"])
            self.assertEqual(persisted["phase"], "uploading")
            self.assertEqual(command, ["xcrun", "altool", "--upload-package", self.metadata["ipa"],
                "--api-key", self.credentials.key_id, "--api-issuer", self.credentials.issuer_id,
                "--p8-file-path", str(self.credentials.key_path), "--output-format", "json"])
            return subprocess.CompletedProcess(command, 0, b"Authorization: Bearer SECRET\nUploaded\n")

        self.process.side_effect = upload_command
        tf.upload(self.client, self.credentials, self.metadata, self.state, self.state_path)
        self.process.assert_called_once()
        self.assertEqual(tf.read_json(self.state_path)["phase"], "processing")
        log = self.state_path.parent / "upload.log"
        self.assertNotIn("SECRET", log.read_text())
        self.assertEqual(log.stat().st_mode & 0o777, 0o600)
        self.assertEqual(tf.read_json(tf.LATEST)["state_file"], str(self.state_path))
        tf.upload(self.client, self.credentials, self.metadata, self.state, self.state_path)
        self.process.assert_called_once()

    def test_upload_nonzero_exit_or_timeout_keeps_attempt_for_poll_only_resume(self):
        for outcome in (subprocess.CompletedProcess([], 1, b"Rejected"),
                        subprocess.TimeoutExpired(["mock-altool"], 3600, output=b"Timed out")):
            with self.subTest(outcome=outcome):
                self.client.items.side_effect = [[], []]
                self.process.reset_mock()
                self.process.side_effect = [outcome]
                state = {"phase": "built"}
                tf.upload(self.client, self.credentials, self.metadata, state, self.state_path)
                self.assertTrue(state["upload_attempted"])
                self.assertEqual(state["phase"], "processing")
                tf.upload(self.client, self.credentials, self.metadata, state, self.state_path)
                self.process.assert_called_once()

    def test_wait_ready_requires_valid_processing_and_ready_internal_state(self):
        for final_state in tf.READY:
            with self.subTest(final_state=final_state):
                self.client.items.side_effect = [[self.build("PROCESSING")], [self.build()], [self.build()]]
                self.client.request.side_effect = [
                    {"data": {"attributes": {"internalBuildState": "PROCESSING"}}},
                    {"data": {"attributes": {"internalBuildState": final_state}}}]
                with mock.patch.object(tf.time, "monotonic", side_effect=[0, 1, 2]), \
                     mock.patch.object(tf.time, "sleep") as sleep:
                    self.assertEqual(tf.wait_ready(self.client, self.metadata, 30, 10), "build-fixture")
                    self.assertEqual(sleep.call_args_list, [mock.call(10), mock.call(10)])
        self.assert_no_local_writes()

    def test_wait_ready_tolerates_detail_404_but_propagates_other_api_errors(self):
        self.client.items.side_effect = [[self.build()], [self.build()]]
        self.client.request.side_effect = [tf.ApiError(404),
            {"data": {"attributes": {"internalBuildState": "READY_FOR_BETA_TESTING"}}}]
        with mock.patch.object(tf.time, "monotonic", side_effect=[0, 1]), \
             mock.patch.object(tf.time, "sleep") as sleep:
            self.assertEqual(tf.wait_ready(self.client, self.metadata, 30, 10), "build-fixture")
            sleep.assert_called_once_with(10)
        self.client.items.side_effect = [[self.build()]]
        self.client.request.side_effect = tf.ApiError(403)
        with self.assertRaises(tf.ApiError) as error:
            tf.wait_ready(self.client, self.metadata, 30, 10)
        self.assertEqual(error.exception.status, 403)
        self.assert_no_local_writes()

    def test_wait_ready_rejects_failed_invalid_or_expired_build_before_details(self):
        for build in (self.build("FAILED"), self.build("INVALID"), self.build(expired=True)):
            with self.subTest(build=build):
                self.client.items.side_effect = [[build]]
                self.client.request.reset_mock()
                with self.assertRaisesRegex(RuntimeError, "失败或过期"):
                    tf.wait_ready(self.client, self.metadata, 30, 10)
                self.client.request.assert_not_called()
        self.sleep.assert_not_called()
        self.assert_no_local_writes()

    def test_wait_ready_stops_for_compliance_or_internal_exception(self):
        for internal in ("MISSING_EXPORT_COMPLIANCE", "IN_EXPORT_COMPLIANCE_REVIEW", "PROCESSING_EXCEPTION", "EXPIRED"):
            with self.subTest(internal=internal):
                self.client.items.side_effect = [[self.build()]]
                self.client.request.side_effect = None
                self.client.request.return_value = {"data": {"attributes": {"internalBuildState": internal}}}
                with self.assertRaisesRegex(RuntimeError, "合规|状态异常"):
                    tf.wait_ready(self.client, self.metadata, 30, 10)
        self.sleep.assert_not_called()
        self.assert_no_local_writes()

    def test_wait_ready_rejects_failed_upload_and_times_out_without_mutation(self):
        self.client.items.side_effect = [[], [{"attributes": {"cfBundleVersion": "12", "state": {"state": "FAILED"}}}]]
        with self.assertRaisesRegex(RuntimeError, "上传处理失败"):
            tf.wait_ready(self.client, self.metadata, 30, 10)
        self.client.items.side_effect = [[], []]
        with mock.patch.object(tf.time, "monotonic", side_effect=[0, 31]), self.assertRaisesRegex(RuntimeError, "超时"):
            tf.wait_ready(self.client, self.metadata, 30, 10)
        self.client.request.assert_not_called()
        self.assert_no_local_writes()

    def test_set_notes_unchanged_is_read_only(self):
        self.client.items.side_effect = [[self.localization("中文测试")]]
        tf.set_notes(self.client, "build-fixture", "中文测试")
        self.client.request.assert_not_called()
        self.assert_no_local_writes()

    def test_set_notes_patches_existing_and_posts_missing_then_confirms(self):
        for existing in (True, False):
            with self.subTest(existing=existing):
                self.client.request.reset_mock()
                self.client.request.side_effect = None
                self.client.items.side_effect = [
                    [self.localization("Old")] if existing else [], [self.localization("New")]]
                tf.set_notes(self.client, "build-fixture", "New")
                self.client.request.assert_called_once()
                method, path, body = self.client.request.call_args.args
                self.assertEqual((method, path), ("PATCH", "/betaBuildLocalizations/localization-fixture") if existing
                                 else ("POST", "/betaBuildLocalizations"))
                self.assertEqual(body["data"]["attributes"]["whatsNew"], "New")
                if not existing:
                    self.assertEqual(body["data"]["attributes"]["locale"], "zh-Hans")
                    self.assertEqual(body["data"]["relationships"]["build"]["data"], {"type": "builds", "id": "build-fixture"})
                self.client.request.reset_mock()
                self.client.items.side_effect = [[self.localization("New")]]
                tf.set_notes(self.client, "build-fixture", "New")
                self.client.request.assert_not_called()
        self.assert_no_local_writes()

    def test_set_notes_error_requires_matching_readback_without_retrying_write(self):
        for current in ([self.localization("Old")], []):
            for confirmed in (True, False):
                with self.subTest(existing=bool(current), confirmed=confirmed):
                    self.client.request.reset_mock()
                    self.client.request.side_effect = RuntimeError("Lost mutation response")
                    self.client.items.side_effect = [current, [self.localization("New")] if confirmed else current]
                    if confirmed:
                        tf.set_notes(self.client, "build-fixture", "New")
                    else:
                        with self.assertRaisesRegex(RuntimeError, "Lost mutation response"):
                            tf.set_notes(self.client, "build-fixture", "New")
                    self.client.request.assert_called_once()
        self.assert_no_local_writes()

    def test_set_notes_success_response_without_readback_is_not_success(self):
        self.client.request.side_effect = None
        self.client.items.side_effect = [[], []]
        with self.assertRaisesRegex(RuntimeError, "尚未被 Apple 确认"):
            tf.set_notes(self.client, "build-fixture", "New")
        self.client.request.assert_called_once()
        self.assert_no_local_writes()

    def test_set_notes_ambiguous_initial_localizations_never_writes(self):
        self.client.items.side_effect = [[self.localization("Old"), self.localization("New")]]
        with self.assertRaisesRegex(RuntimeError, "多个中文"):
            tf.set_notes(self.client, "build-fixture", "New")
        self.client.request.assert_not_called()
        self.assert_no_local_writes()

    def test_assign_group_existing_relation_is_read_only(self):
        self.client.items.side_effect = [[{"id": "build-fixture"}]]
        tf.assign_group(self.client, "build-fixture")
        self.client.request.assert_not_called()
        self.assert_no_local_writes()

    def test_assign_group_adds_only_target_build_and_confirms_then_is_idempotent(self):
        self.client.items.side_effect = [[{"id": "other-build"}], [{"id": "other-build"}, {"id": "build-fixture"}]]
        self.client.request.side_effect = None
        tf.assign_group(self.client, "build-fixture")
        self.client.request.assert_called_once_with("POST", f"/betaGroups/{tf.GROUP_ID}/relationships/builds",
            {"data": [{"type": "builds", "id": "build-fixture"}]})
        self.client.items.side_effect = [[{"id": "build-fixture"}]]
        tf.assign_group(self.client, "build-fixture")
        self.client.request.assert_called_once()
        self.assert_no_local_writes()

    def test_assign_group_error_requires_readback_confirmation_without_second_post(self):
        for confirmed in (True, False):
            with self.subTest(confirmed=confirmed):
                self.client.request.reset_mock()
                self.client.request.side_effect = RuntimeError("Lost relation response")
                self.client.items.side_effect = [[], [{"id": "build-fixture"}] if confirmed else [{"id": "other-build"}]]
                if confirmed:
                    tf.assign_group(self.client, "build-fixture")
                else:
                    with self.assertRaisesRegex(RuntimeError, "Lost relation response"):
                        tf.assign_group(self.client, "build-fixture")
                self.client.request.assert_called_once()
        self.assert_no_local_writes()

    def test_assign_group_success_response_without_relation_is_not_success(self):
        self.client.request.side_effect = None
        self.client.items.side_effect = [[], []]
        with self.assertRaisesRegex(RuntimeError, "尚未被 Apple 确认"):
            tf.assign_group(self.client, "build-fixture")
        self.client.request.assert_called_once()
        self.assert_no_local_writes()

    def test_validate_metadata_accepts_matching_actual_ipa_without_subprocess(self):
        metadata = self.make_ipa()
        self.assertEqual(tf.validate_metadata(metadata), self.root / "fixture.ipa")
        self.assert_no_local_writes()

    def test_validate_metadata_rejects_adhoc_wrong_bundle_or_incomplete_validation(self):
        metadata = self.make_ipa()
        changes = [{"method": "ad-hoc"}, {"package_id": "other.app"}, {"built": False}, {"signed": False}]
        changes.extend({"validation": {**metadata["validation"], key: False}} for key in metadata["validation"])
        for change in changes:
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                tf.validate_metadata({**metadata, **change})
        self.assert_no_local_writes()

    def test_validate_metadata_rejects_missing_ipa_or_changed_hash(self):
        metadata = self.make_ipa()
        for change in ({"ipa": str(self.root / "missing.ipa")}, {"ipa_sha256": "0" * 64}):
            with self.subTest(change=change), self.assertRaisesRegex(RuntimeError, "缺失或内容发生变化"):
                tf.validate_metadata({**metadata, **change})
        self.assert_no_local_writes()

    def test_validate_metadata_checks_actual_ipa_identity_after_hash_matches(self):
        for field, value in (("CFBundleIdentifier", "other.app"), ("CFBundleShortVersionString", "9.9.9"), ("CFBundleVersion", "99")):
            with self.subTest(field=field):
                metadata = self.make_ipa(**{field: value})
                with self.assertRaisesRegex(RuntimeError, "IPA 实际版本"):
                    tf.validate_metadata(metadata)
        self.assert_no_local_writes()

    def test_validate_metadata_rejects_ambiguous_main_app(self):
        metadata = self.make_ipa()
        with zipfile.ZipFile(metadata["ipa"], "a") as archive:
            archive.writestr("Payload/Other.app/Info.plist", plistlib.dumps({}))
        metadata["ipa_sha256"] = hashlib.sha256(Path(metadata["ipa"]).read_bytes()).hexdigest()
        with self.assertRaisesRegex(RuntimeError, "主应用数量异常"):
            tf.validate_metadata(metadata)
        self.assert_no_local_writes()

    def test_main_missing_credentials_cannot_preflight_update_build_or_create_state(self):
        for args in ([], ["--check"], ["--resume"]):
            with self.subTest(args=args), mock.patch.object(tf, "check_local") as check, \
                 mock.patch.object(tf, "preflight") as preflight, \
                 mock.patch.object(tf.ios.shared, "file_lock") as lock:
                with self.assertRaisesRegex(RuntimeError, "尚未配置"):
                    tf.main(args)
                check.assert_not_called()
                preflight.assert_not_called()
                lock.assert_not_called()
        self.client_factory.assert_not_called()
        self.assert_no_local_writes()

    def test_build_command_updates_by_default_and_honors_local_only(self):
        command = tf.build_command(tf.arguments([]), self.root / "result.json", "12")
        self.assertEqual(command, [str(self.root / "tools" / "build_ipa.sh"), "--method", "app-store", "--update",
                                  "--result-file", str(self.root / "result.json"), "--build-number", "12"])
        command = tf.build_command(tf.arguments(["--local", "--version", "0.0.5", "--profile", "/fixture/profile"]), check=True)
        self.assertNotIn("--update", command)
        self.assertIn("--check", command)
        self.assertEqual(command[-4:], ["--version", "0.0.5", "--profile", "/fixture/profile"])
        self.assert_no_local_writes()

    def configure_full_release(self, *, group_confirmed=True, upload_exit_code=0, upload_timeout=False):
        """Use real orchestration and temporary state with a stateful fake Apple API."""
        tf.DEFAULT_NOTES.write_text("中文测试说明\n", encoding="utf-8")
        self.write_json(self.root / "build/ios-auto-work/build-number.json", {"last_build_number": "11"})
        remote = {"uploaded": False, "notes": None, "members": []}
        self.stack.enter_context(mock.patch.object(tf, "load_credentials", return_value=self.credentials))
        check = self.stack.enter_context(mock.patch.object(tf, "check_local"))
        self.client_factory.side_effect = None
        self.client_factory.return_value = self.client

        def items(path, params):
            if path == "/betaGroups":
                return [self.group()]
            if path == "/builds":
                return [self.build(version="12")] if remote["uploaded"] else []
            if path == f"/apps/{tf.APP_ID}/buildUploads":
                return []
            if path == "/betaBuildLocalizations":
                return [self.localization(remote["notes"])] if remote["notes"] is not None else []
            if path == f"/betaGroups/{tf.GROUP_ID}/relationships/builds":
                return [{"id": member} for member in remote["members"]]
            raise AssertionError(f"Unexpected API list: {path}")

        def request(method, path, body=None):
            if (method, path) == ("GET", f"/apps/{tf.APP_ID}"):
                return self.app()
            if (method, path) == ("GET", "/builds/build-fixture/buildBetaDetail"):
                return {"data": {"attributes": {"internalBuildState": "READY_FOR_BETA_TESTING"}}}
            if (method, path) == ("POST", "/betaBuildLocalizations"):
                self.assertEqual(body["data"]["relationships"]["build"]["data"]["id"], "build-fixture")
                remote["notes"] = body["data"]["attributes"]["whatsNew"]
                return {"data": self.localization(remote["notes"])}
            if (method, path) == ("POST", f"/betaGroups/{tf.GROUP_ID}/relationships/builds"):
                if not group_confirmed:
                    raise RuntimeError("Relation write unconfirmed")
                remote["members"] += [item["id"] for item in body["data"]]
                return {}
            raise AssertionError(f"Unexpected API request: {method} {path}")

        def command(args, **kwargs):
            if args[0] == str(self.root / "tools" / "build_ipa.sh"):
                self.assertIn("--update", args)
                number = args[args.index("--build-number") + 1]
                self.assertEqual(number, "12")
                output = Path(args[args.index("--result-file") + 1])
                self.assertTrue(output.is_relative_to(self.root))
                self.write_json(output, self.make_ipa())
                return subprocess.CompletedProcess(args, 0)
            if args[:3] == ["xcrun", "altool", "--upload-package"]:
                remote["uploaded"] = True
                if upload_timeout:
                    raise subprocess.TimeoutExpired(args, 3600, output=b"Unknown upload outcome")
                return subprocess.CompletedProcess(args, upload_exit_code, b"Fixture upload response")
            raise AssertionError(f"Unexpected command: {args}")

        self.client.items.side_effect = items
        self.client.request.side_effect = request
        self.process.side_effect = command
        return remote, check

    def test_main_complete_release_and_resume_never_rebuilds_or_reuploads(self):
        remote, check = self.configure_full_release()
        tf.main([])
        check.assert_called_once()
        self.assertEqual(self.process.call_count, 2)
        self.assertEqual(remote["members"], ["build-fixture"])
        self.assertEqual(remote["notes"], "中文测试说明")
        path = Path(tf.read_json(tf.LATEST)["state_file"])
        state = tf.read_json(path)
        self.assertEqual(state["phase"], "complete")
        self.assertEqual(state["ipa_sha256"], hashlib.sha256(Path(state["ipa"]).read_bytes()).hexdigest())
        self.assertEqual(state["upload_exit_code"], 0)
        self.assertTrue(state["uploaded"])
        self.assertTrue(state["internal_testing_enabled"])
        mutations = [call for call in self.client.request.call_args_list if call.args[0] != "GET"]
        tf.main(["--resume"])
        self.assertEqual(self.process.call_count, 2)
        check.assert_called_once()
        self.assertEqual([call for call in self.client.request.call_args_list if call.args[0] != "GET"], mutations)
        self.assertEqual(remote["members"], ["build-fixture"])
        self.assertEqual(tf.read_json(path)["phase"], "complete")
        self.sleep.assert_not_called()

    def test_main_unconfirmed_assignment_retains_resumable_state_without_complete(self):
        remote, check = self.configure_full_release(group_confirmed=False)
        with self.assertRaisesRegex(RuntimeError, "Relation write unconfirmed"):
            tf.main([])
        path = Path(tf.read_json(tf.LATEST)["state_file"])
        state = tf.read_json(path)
        self.assertEqual(state["phase"], "distributing")
        self.assertEqual(state["apple_build_id"], "build-fixture")
        self.assertNotIn("internal_testing_enabled", state)
        self.assertNotIn("uploaded", state)
        self.assertEqual(remote["members"], [])
        with self.assertRaisesRegex(RuntimeError, "Relation write unconfirmed"):
            tf.main(["--resume"])
        self.assertEqual(self.process.call_count, 2)
        self.assertEqual(tf.read_json(tf.LATEST)["phase"], "distributing")
        check.assert_called_once()

    def test_main_unknown_upload_cannot_distribute_even_when_same_number_is_ready(self):
        for timeout in (False, True):
            with self.subTest(timeout=timeout):
                remote, _ = self.configure_full_release(upload_exit_code=1, upload_timeout=timeout)
                self.process.reset_mock()
                self.client.request.reset_mock()
                with self.assertRaisesRegex(RuntimeError, "本次上传没有成功回执"):
                    tf.main([])
                path = Path(tf.read_json(tf.LATEST)["state_file"])
                state = tf.read_json(path)
                self.assertEqual(state["phase"], "processing")
                self.assertTrue(state["upload_attempted"])
                self.assertNotIn("apple_build_id", state)
                self.assertNotIn("internal_testing_enabled", state)
                self.assertEqual(remote["members"], [])
                self.assertIsNone(remote["notes"])
                self.assertTrue(all(call.args[0] == "GET" for call in self.client.request.call_args_list))
                with self.assertRaisesRegex(RuntimeError, "本次上传没有成功回执"):
                    tf.main(["--resume"])
                self.assertEqual(self.process.call_count, 2)


if __name__ == "__main__":
    unittest.main()
