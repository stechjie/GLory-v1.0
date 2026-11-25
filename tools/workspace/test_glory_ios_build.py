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
import sys
import tempfile
import unittest
import zipfile
from unittest import mock

spec = importlib.util.spec_from_file_location("glory_ios_build_tested", Path(__file__).with_name("glory_ios_build.py"))
ios = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ios)


class IOSBuildTests(unittest.TestCase):
    def test_apple_billing_rejects_stale_source_and_old_native_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            source = project / "native/glory_voice_ios"
            folder = project / "addons/glory_voice/bin/ios"
            source.mkdir(parents=True)
            binary = folder / "GloryVoice.framework/GloryVoice"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"GloryAppleBillingNative beginFinishTransaction: StoreKit")
            manifest = {"source": {}, "files": {"GloryVoice.framework/GloryVoice": ios.shared.digest(binary)}}
            for name in ("GloryAppleBilling.swift", "GloryAppleBillingNative.h", "GloryAppleBillingBridge.mm",
                         "GloryVoiceBridge.mm", "build.py"):
                (source / name).write_text("source " + name)
                manifest["source"][name] = ios.shared.digest(source / name)
            (folder / "build-manifest.json").write_text(json.dumps(manifest))
            ios.verify_apple_billing_source(project)
            (source / "GloryAppleBilling.swift").write_text("changed")
            with self.assertRaisesRegex(RuntimeError, "源码不一致"):
                ios.verify_apple_billing_source(project)
            binary.write_bytes(b"old voice-only binary")
            with self.assertRaisesRegex(RuntimeError, "StoreKit"):
                ios.verify_apple_billing_binary(binary)

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
        self.signin = {"ios_client_id": "123-ios.apps.googleusercontent.com", "web_client_id": "123-web.apps.googleusercontent.com",
                       "reversed_client_id": "com.googleusercontent.apps.123-ios"}
        self.toolchain = {"xcode_version": "27.2", "xcode_build": "27B52",
                          "iphoneos_sdk_version": "27.2", "iphoneos_sdk_build": "24B8118"}
        self.now = dt.datetime(2026, 9, 13, tzinfo=dt.timezone.utc)
        self.profile = {
            "Name": "Fixture", "UUID": "11111111-2222-3333-4444-555555555555", "TeamIdentifier": [ios.TEAM],
            "CreationDate": self.now - dt.timedelta(days=1), "ExpirationDate": self.now + dt.timedelta(days=30),
            "DeveloperCertificates": [b"public certificate fixture"], "ProvisionedDevices": ["TEST-DEVICE"],
            "Entitlements": {"application-identifier": f"{ios.TEAM}.{ios.BUNDLE}",
                             "com.apple.developer.team-identifier": ios.TEAM, "get-task-allow": False, ios.APPLE_SIGNIN_ENTITLEMENT: ["Default"]},
        }

    def test_toolchain_gate_rejects_an_older_sdk_and_an_older_xcode(self):
        sdk = ios.ios_toolchain
        sdk.validate_toolchain(self.toolchain)
        for key, value in (("iphoneos_sdk_version", "26.5"), ("iphoneos_sdk_version", "27.0"),
                           ("xcode_version", "26.5"), ("xcode_version", "27.0"),
                           ("xcode_version", "unknown"), ("iphoneos_sdk_build", None)):
            with self.subTest(key=key, value=value), self.assertRaises(RuntimeError):
                sdk.validate_toolchain(dict(self.toolchain, **{key: value}))

    def test_sdk_proof_compares_binary_plist_and_selected_toolchain(self):
        sdk = ios.ios_toolchain
        info = {"DTSDKName": "iphoneos27.2", "DTSDKBuild": "24B8118",
                "DTXcodeBuild": "27B52", "MinimumOSVersion": "15.0"}
        output = "\n".join(["Load command 11", " cmd LC_BUILD_VERSION", " platform IOS", " minos 15.0", " sdk 27.2", ""])
        build = sdk.parse_build_version(output)
        proof = sdk.validate_app_metadata(info, build, self.toolchain)
        self.assertEqual(proof["minimum_os_version"], "15.0")
        self.assertTrue(proof["mach_o_sdk_verified"])
        for key, value in (("DTSDKName", "iphoneos26.5"), ("DTSDKBuild", "OLD"),
                           ("DTXcodeBuild", "OLD"), ("MinimumOSVersion", "27.2")):
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                sdk.validate_app_metadata(dict(info, **{key: value}), build, self.toolchain)
        for text in ("", output.replace("IOS", "IOSSIMULATOR"), output + output):
            with self.subTest(text=text), self.assertRaises(RuntimeError):
                sdk.parse_build_version(text)
        for version in ("26.5", "27.0", "27.1"):
            with self.subTest(version=version), self.assertRaises(RuntimeError):
                sdk.validate_app_metadata(info, dict(build, sdk=version), self.toolchain)

    def test_duo_window_policy_requires_string_version_scene_and_launch_screen(self):
        valid = {"UIRequiresFullScreen": True, "UIRequiresFullScreenIgnoredStartingWithVersion": "27",
                 "UILaunchStoryboardName": "Launch Screen",
                 "UIApplicationSceneManifest": {"UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [{}]}}}
        ios.verify_duo_window_support(valid)
        for key, value in (("UIRequiresFullScreen", 1), ("UIRequiresFullScreen", False),
                           ("UIRequiresFullScreenIgnoredStartingWithVersion", 27),
                           ("UIRequiresFullScreenIgnoredStartingWithVersion", "28"),
                           ("UILaunchStoryboardName", ""),
                           ("UIApplicationSceneManifest", {})):
            with self.subTest(key=key, value=value), self.assertRaises(RuntimeError):
                ios.verify_duo_window_support(dict(valid, **{key: value}))

    def test_worktree_build_uses_explicit_workspace_for_assets_signing_and_outputs(self):
        workspace = (self.root / "isolated-workspace").resolve()
        script = ("import glory_ios_build as i; import json; "
                  "print(json.dumps([str(i.ROOT), str(i.shared.ROOT), str(i.DEFAULT_PROFILES['app-store'])]))")
        env = dict(os.environ, GLORY_WORKSPACE=str(workspace))
        output = subprocess.check_output([sys.executable, "-B", "-c", script],
                                         cwd=Path(ios.__file__).parent, env=env, text=True)
        roots = json.loads(output)
        self.assertEqual(roots[:2], [str(workspace)] * 2)
        self.assertTrue(Path(roots[2]).is_relative_to(workspace))

    def test_duo_template_requires_exact_patch_and_sdk_provenance(self):
        project = self.root / "duo-project"
        patch_dir = project / "deploy/engine"
        patch_dir.mkdir(parents=True)
        audio = patch_dir / "godot-4.7-ios-audio-recovery.patch"
        duo = patch_dir / "godot-4.7-ios-duo-layout.patch"
        audio.write_bytes(b"audio")
        duo.write_bytes(b"duo")
        template = self.root / "duo-template"
        template.mkdir()
        (template / "ios.zip").write_bytes(b"archive")
        manifest_path = template / "glory-engine.json"
        manifest = {"patch_sha256": ios.shared.digest(audio),
                    "ios_zip_sha256": ios.shared.digest(template / "ios.zip"),
                    "patches": {duo.relative_to(project).as_posix(): ios.shared.digest(duo)},
                    "toolchain": self.toolchain}
        manifest_path.write_text(json.dumps(manifest))
        ios.engine_template_info(project, template)
        broken = copy.deepcopy(manifest)
        broken["toolchain"]["iphoneos_sdk_version"] = "26.5"
        manifest_path.write_text(json.dumps(broken))
        with self.assertRaises(RuntimeError):
            ios.engine_template_info(project, template)
        manifest_path.write_text(json.dumps(manifest))
        duo.write_bytes(b"new layout")
        with self.assertRaisesRegex(RuntimeError, "Duo"):
            ios.engine_template_info(project, template)

    def test_default_template_prefers_duo_but_honors_explicit_override(self):
        project = self.root / "template-selection-project"
        project.mkdir()
        (project / "project.godot").write_text('config/features=PackedStringArray("4.7")\n')
        duo = self.root / "build/ios-duo-templates/4.7.stable"
        audio = self.root / "build/ios-audio-templates/4.7.stable"
        override = self.root / "explicit-templates"
        for directory in (duo, audio, override):
            directory.mkdir(parents=True)
            (directory / "version.txt").write_text("4.7.stable\n")
            with zipfile.ZipFile(directory / "ios.zip", "w") as archive:
                archive.writestr("godot_apple_embedded.xcodeproj/project.pbxproj", "fixture")
                archive.writestr("libgodot.ios.release.xcframework/ios-arm64/libgodot.a", b"fixture")
        args = ios.arguments(["--project", str(project)])
        def capture(command, **unused):
            return b"4.7.stable.fixture\n" if command[-1] == "--version" else b"Xcode 27.2\nBuild version 27B52\n"
        with mock.patch.object(ios, "ROOT", self.root), mock.patch.object(ios.sys, "platform", "darwin"), \
             mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(ios, "capture", side_effect=capture), \
             mock.patch.object(ios.ios_toolchain, "inspect_toolchain", return_value=self.toolchain), \
             mock.patch.object(ios.shared, "find_executable", return_value="fixture-godot"), \
             mock.patch.object(ios.shutil, "which", return_value="/usr/bin/rsync"):
            self.assertEqual(ios.environment(args)["templates"], duo.resolve())
            with mock.patch.dict(os.environ, {"GODOT_TEMPLATES": str(audio)}):
                self.assertEqual(ios.environment(args)["templates"], audio.resolve())
                args.templates = str(override)
                self.assertEqual(ios.environment(args)["templates"], override.resolve())

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

    def test_profile_requires_native_apple_signin_capability(self):
        for value in (None, [], ["Other"], "Default"):
            profile = copy.deepcopy(self.profile)
            profile["Entitlements"][ios.APPLE_SIGNIN_ENTITLEMENT] = value
            with self.subTest(value=value), self.assertRaisesRegex(RuntimeError, "Sign in with Apple"):
                ios.validate_profile_data(profile, "ad-hoc", self.now)

    def test_google_client_configuration_requires_distinct_same_project_ids(self):
        project = self.root / "source"
        account = project / "scripts/account/AccountConfig.gd"
        account.parent.mkdir(parents=True)
        account.write_text('const GOOGLE_WEB_CLIENT_ID := "123-web.apps.googleusercontent.com"\n'
                           'const GOOGLE_IOS_CLIENT_ID := "123-ios.apps.googleusercontent.com"\n')
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(ios.google_signin_config(project), self.signin)
            for invalid in ("", "123-web.apps.googleusercontent.com", "456-ios.apps.googleusercontent.com", '<bad>&'):
                account.write_text('const GOOGLE_WEB_CLIENT_ID := "123-web.apps.googleusercontent.com"\n')
                with self.subTest(client_id=invalid), self.assertRaisesRegex(RuntimeError, "Google"):
                    ios.google_signin_config(project, invalid)
            with mock.patch.dict(os.environ, {"GLORY_GOOGLE_IOS_CLIENT_ID": self.signin["ios_client_id"]}):
                self.assertEqual(ios.google_signin_config(project), self.signin)

    def test_signin_plist_and_entitlements_are_checked_against_build_identity(self):
        info = plistlib.loads(('<plist version="1.0"><dict>' + ios.signin_plist(self.signin) + '</dict></plist>').encode())
        ios.verify_signin_config(info, self.profile["Entitlements"], self.signin)
        for key in ("GIDClientID", "GIDServerClientID", "CFBundleURLTypes"):
            broken = dict(info)
            broken.pop(key)
            with self.subTest(key=key), self.assertRaisesRegex(RuntimeError, "Google"):
                ios.verify_signin_config(broken, self.profile["Entitlements"], self.signin)
        with self.assertRaisesRegex(RuntimeError, "Sign in with Apple"):
            ios.verify_signin_config(info, {}, self.signin)

    def test_native_signin_and_google_privacy_resources_are_required(self):
        binary = self.root / "GloryVoice"
        binary.write_bytes(b"GlorySignInNative beginGoogleSignIn beginAppleSignIn GIDSignIn ASAuthorizationAppleIDProvider")
        ios.verify_signin_binary(binary)
        binary.write_bytes(b"old voice billing framework")
        with self.assertRaisesRegex(RuntimeError, "Apple/Google"):
            ios.verify_signin_binary(binary)
        with self.assertRaisesRegex(RuntimeError, "隐私清单"):
            ios.verify_google_privacy_bundle(self.root)
        manifest = self.root / "GoogleSignIn_GoogleSignIn.bundle/PrivacyInfo.xcprivacy"
        manifest.parent.mkdir()
        manifest.write_bytes(plistlib.dumps({"NSPrivacyTracking": False}))
        ios.verify_google_privacy_bundle(self.root)

    def test_native_signin_rejects_source_or_binary_changed_since_build(self):
        project = self.root / "native-fixture"
        source = project / "native/glory_voice_ios"
        folder = project / "addons/glory_voice/bin/ios"
        source.mkdir(parents=True)
        binary = folder / "GloryVoice.framework/GloryVoice"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"GlorySignInNative beginGoogleSignIn beginAppleSignIn GIDSignIn ASAuthorizationAppleIDProvider")
        manifest = {"source": {}, "files": {"GloryVoice.framework/GloryVoice": ios.shared.digest(binary)}}
        for name in ("GlorySignIn.swift", "GlorySignInRequests.swift", "GlorySignInNative.h", "GlorySignInBridge.mm", "GloryVoiceBridge.mm", "build.py"):
            (source / name).write_text("source " + name)
            manifest["source"][name] = ios.shared.digest(source / name)
        (folder / "build-manifest.json").write_text(json.dumps(manifest))
        ios.verify_signin_source(project)
        swift = source / "GlorySignIn.swift"
        original = swift.read_text()
        swift.write_text("new source")
        with self.assertRaisesRegex(RuntimeError, "源码不一致"):
            ios.verify_signin_source(project)
        swift.write_text(original)
        binary.write_bytes(binary.read_bytes() + b"unexpected replacement")
        with self.assertRaisesRegex(RuntimeError, "指纹不一致"):
            ios.verify_signin_source(project)

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

    def test_ios_snapshot_replaces_legacy_and_localized_names_without_changing_other_settings(self):
        project = self.root / "project.godot"
        project.write_text(
            '[application]\nconfig/name="Glory Beta 0.04"\n'
            'config/name.ios="Another old name"\n'
            'config/name_localized={"zh_CN": "Old localized name"}\n'
            'config/version="1.0.2"\n[autoload]\nSaveManager="*res://save.gd"\n')
        ios.configure_display_name(self.root)
        expected = ('[application]\nconfig/name="GLory: Auto Chess & Team PvP"\n'
                    'config/version="1.0.2"\n[autoload]\nSaveManager="*res://save.gd"\n')
        self.assertEqual(project.read_text(), expected)
        ios.configure_display_name(self.root)
        self.assertEqual(project.read_text(), expected)

    def test_signed_payload_name_rejects_old_name_and_localization_override(self):
        app = self.root / "Fixture.app"
        app.mkdir()
        for wrong in (None, "Glory Beta 0.04", "GLory Auto Chess", "$(INFOPLIST_KEY_CFBundleDisplayName)"):
            with self.subTest(name=wrong), self.assertRaisesRegex(RuntimeError, "桌面名称"):
                ios.verify_display_name(app, {"CFBundleDisplayName": wrong})
        self.assertEqual(ios.verify_display_name(app, {"CFBundleDisplayName": ios.DISPLAY_NAME})["display_name"], ios.DISPLAY_NAME)
        localized = app / "zh-Hans.lproj/InfoPlist.strings"
        localized.parent.mkdir()
        for fmt in (plistlib.FMT_BINARY, plistlib.FMT_XML):
            localized.write_bytes(plistlib.dumps({"CFBundleDisplayName": "Glory Beta 0.04"}, fmt=fmt))
            with self.assertRaisesRegex(RuntimeError, "本地化桌面名称"):
                ios.verify_display_name(app, {"CFBundleDisplayName": ios.DISPLAY_NAME})
        localized.write_text('"CFBundleDisplayName" = "GLory: Auto Chess & Team PvP";\n')
        self.assertEqual(ios.verify_display_name(app, {"CFBundleDisplayName": ios.DISPLAY_NAME})["localized_display_name_checks"], ["zh-Hans.lproj"])

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
        ios.write_preset(stage, "ad-hoc", self.profile, cert, "0.0.4", "2", self.signin)
        text = preset.read_text()
        self.assertNotIn("addons/glory_voice/glory_voice.gdextension", text)
        self.assertIn('application/export_method_release=2', text)
        self.assertIn('application/provisioning_profile_specifier_release="' + self.profile["UUID"] + '"', text)
        self.assertIn('icons/icon_1024x1024="res://app_icon.png"', text)
        self.assertNotIn('provisioning_profile_specifier_release="Fixture"', text)

    def test_game_mode_settings_survive_export_preset_serialization(self):
        for method in ("ad-hoc", "app-store"):
            with self.subTest(method=method):
                stage = self.root / method
                stage.mkdir()
                (stage / "export_presets.cfg").write_text(
                    '[preset.0]\nname="Android"\nplatform="Android"\n'
                    'include_filter=""\nexclude_filter=""\n[preset.0.options]\n'
                    'package/unique_name="com.glory.game"\n')
                ios.write_preset(stage, method, self.profile,
                                 {"name": "iPhone Distribution: Fixture"}, "1.0.2", "89", self.signin)
                text = (stage / "export_presets.cfg").read_text()
                line = next(x for x in text.splitlines()
                            if x.startswith("application/additional_plist_content="))
                fragment = json.loads(line.split("=", 1)[1])
                info = plistlib.loads((
                    '<?xml version="1.0"?><plist version="1.0"><dict>'
                    + fragment + '</dict></plist>').encode())
                ios.verify_game_mode_support(info)
                self.assertIs(info["LSSupportsGameMode"], True)
                self.assertIs(info["GCSupportsGameMode"], True)
                self.assertEqual(info["UIRequiresFullScreenIgnoredStartingWithVersion"], "27")
                self.assertNotIn("UIRequiresFullScreen", info)  # Already emitted once by Godot.
                self.assertTrue(info["NSSpeechRecognitionUsageDescription"].strip())
                self.assertNotIn("UIBackgroundModes", info)

    def test_game_mode_validation_rejects_missing_disabled_or_string_flags(self):
        valid = {"LSSupportsGameMode": True, "GCSupportsGameMode": True}
        ios.verify_game_mode_support(valid)
        for key in valid:
            for value in (None, False, "YES", 1):
                with self.subTest(key=key, value=value), self.assertRaisesRegex(RuntimeError, "Game Mode"):
                    ios.verify_game_mode_support(dict(valid, **{key: value}))

    def test_certificate_extraction_prefix_is_one_option_even_with_spaces(self):
        ipa = self.root / "fixture.ipa"
        destination = self.root / "verify with spaces"
        leaf = b"public signing certificate fixture"
        cert = {"sha1": hashlib.sha1(leaf).hexdigest().upper()}
        identity = {"build_number": "2", "signin": self.signin, "toolchain": self.toolchain}
        info = {"CFBundleIdentifier": ios.BUNDLE, "CFBundleShortVersionString": "0.0.4", "CFBundleVersion": "2",
                "CFBundleDisplayName": ios.DISPLAY_NAME,
                "CFBundleExecutable": "Fixture", "CFBundleSupportedPlatforms": ["iPhoneOS"], "NSMicrophoneUsageDescription": "Voice", "NSCameraUsageDescription": "No camera capture", "NSPhotoLibraryUsageDescription": "No photo library access",
                "NSSpeechRecognitionUsageDescription": "Convert recorded chat speech into a draft.",
                "LSSupportsGameMode": True, "GCSupportsGameMode": True,
                "DTSDKName": "iphoneos27.2", "DTSDKBuild": "24B8118", "DTXcodeBuild": "27B52",
                "MinimumOSVersion": "15.0", "UIRequiresFullScreen": True,
                "UIRequiresFullScreenIgnoredStartingWithVersion": "27",
                "UILaunchStoryboardName": "Launch Screen",
                "UIApplicationSceneManifest": {"UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [{}]}}}
        info.update(plistlib.loads(('<plist version="1.0"><dict>' + ios.signin_plist(self.signin) + '</dict></plist>').encode()))
        with zipfile.ZipFile(ipa, "w") as archive:
            for name, data in {"Info.plist": plistlib.dumps(info), "Fixture": b"arm64 fixture",
                               "Fixture.pck": b"pck fixture", "embedded.mobileprovision": b"profile fixture",
                               "Frameworks/GloryVoice.framework/GloryVoice": b"voice fixture GloryAppleBillingNative beginFinishTransaction: StoreKit GlorySignInNative beginGoogleSignIn beginAppleSignIn GIDSignIn ASAuthorizationAppleIDProvider",
                               "Frameworks/GloryVoice.framework/GoogleSignIn_GoogleSignIn.bundle/PrivacyInfo.xcprivacy": plistlib.dumps({}),
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
            elif "vtool" in command:
                return b"Load command 11\n      cmd LC_BUILD_VERSION\n platform IOS\n minos 15.0\n sdk 27.2\n"
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
        self.assertTrue(result["apple_storekit"])
        self.assertTrue(result["game_mode_support"])
        self.assertFalse(result["duo_engine_layout"])  # Fixture above does not claim an engine patch.
        claimed = dict(identity, engine_info={"patches": {"deploy/engine/godot-4.7-ios-duo-layout.patch": "fixture"}})
        with mock.patch.object(ios, "capture", side_effect=tool), mock.patch.object(ios, "read_profile", return_value=self.profile):
            executable = destination / "Payload/Fixture.app/Fixture"
            original_data = executable.read_bytes()
            # Skip extraction so this test can vary the actual linked marker.
            def marker_tool(command, **kwargs):
                if command[0] != "/usr/bin/ditto":
                    return tool(command, **kwargs)
                return b""
            with mock.patch.object(ios, "capture", side_effect=marker_tool), mock.patch.object(ios, "pck_file", return_value=json.dumps(claimed).encode()):
                executable.write_bytes(original_data + b" [GLORY_AUDIO_DRIVER] recovery=")
                with self.assertRaisesRegex(RuntimeError, "Duo"):
                    ios.verify_ipa(ipa, destination, "ad-hoc", self.profile, cert, "0.0.4", "2", claimed, {})
                executable.write_bytes(executable.read_bytes() + b" [GLORY_DUO] geometry=")
                proof = ios.verify_ipa(ipa, destination, "ad-hoc", self.profile, cert, "0.0.4", "2", claimed, {})
                self.assertTrue(proof["duo_engine_layout"])
        self.assertTrue((destination / "signer-0").is_file())

        missing_speech = self.root / "missing-speech-purpose.ipa"
        with zipfile.ZipFile(ipa) as source, zipfile.ZipFile(missing_speech, "w") as target:
            for name in source.namelist():
                data = source.read(name)
                if name == "Payload/Fixture.app/Info.plist":
                    incomplete_info = plistlib.loads(data)
                    del incomplete_info["NSSpeechRecognitionUsageDescription"]
                    data = plistlib.dumps(incomplete_info)
                target.writestr(name, data)
        with mock.patch.object(ios, "capture", side_effect=tool):
            with self.assertRaisesRegex(RuntimeError, "NSSpeechRecognitionUsageDescription"):
                ios.verify_ipa(missing_speech, self.root / "missing-speech-verify", "ad-hoc",
                               self.profile, cert, "0.0.4", "2", identity, {})

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
            stack.enter_context(mock.patch.object(ios, "verify_apple_billing_source"))
            stack.enter_context(mock.patch.object(ios, "verify_signin_source"))
            stack.enter_context(mock.patch.object(ios, "google_signin_config", return_value=self.signin))
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
