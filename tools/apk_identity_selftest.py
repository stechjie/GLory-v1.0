#!/usr/bin/env python3
"""Hermetic regression checks for tools/apk_identity.py."""

import json
import tempfile
import zipfile
from pathlib import Path

import apk_identity as identity


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True).encode("utf-8")


def main():
    manifest = {"schema_version": 2, "inventory_sha256": "a" * 64, "entries": []}
    bundle = {"schema_version": 1, "inventory_sha256": "a" * 64,
              "archive": {"sha256": "b" * 64, "bytes": 123}}
    manifest_bytes = encoded(manifest)
    bundle_bytes = encoded(bundle)
    build = {
        "schema_version": 2,
        "package_id": "glory.beta001",
        "version_code": 5,
        "version_name": "",
        "asset_inventory_sha256": "a" * 64,
        "asset_manifest_file_sha256": identity.sha256_bytes(manifest_bytes),
        "asset_bundle_file_sha256": identity.sha256_bytes(bundle_bytes),
    }
    with tempfile.TemporaryDirectory(prefix="glory_apk_identity_") as temp:
        apk = Path(temp) / "fixture.apk"
        report_path = Path(temp) / "report.json"
        with zipfile.ZipFile(apk, "w") as archive:
            archive.writestr("assets/build_info.json", encoded(build))
            archive.writestr("assets/assets.manifest.json", manifest_bytes)
            archive.writestr("assets/assets.bundle.json", bundle_bytes)
            archive.writestr("assets/example.png.remap",
                             '[remap]\npath="res://.godot/imported/example.ctex"\n')
            archive.writestr("assets/.godot/imported/example.ctex", b"compiled")
            # A dex that carries the voice plugin class, the way a Gradle export with
            # glory_voice/enabled produces it.
            archive.writestr("classes.dex", b"dex\n035\x00...Lcom/glory/voice/GloryVoicePlugin;...")

        report = identity.inspect_apk(apk)
        assert report["artifact_mapping_count"] == 1
        assert report["artifact_mappings"][0]["source"] == "res://example.png"
        assert report["voice_plugin_present"] is True
        report["android_manifest_error"] = ""
        report["android_manifest"] = {
            "package_id": "glory.beta001", "version_code": 5, "version_name": "",
            "permissions": ["android.permission.INTERNET", identity.VOICE_PERMISSION]}
        assert identity.verify_report(report, build) == []

        # An APK exported without the voice plugin must not verify (the p27-p30 case):
        # it installs and runs, and the only symptom is a voice button that refuses.
        silent = Path(temp) / "no_voice.apk"
        with zipfile.ZipFile(silent, "w") as archive:
            archive.writestr("assets/build_info.json", encoded(build))
            archive.writestr("classes.dex", b"dex\n035\x00...Lorg/godotengine/godot/Godot;...")
        assert identity.inspect_apk(silent)["voice_plugin_present"] is False
        no_voice = dict(report, voice_plugin_present=False)
        assert "voice_plugin_absent" in identity.verify_report(no_voice, build)

        no_mic = dict(report, android_manifest=dict(report["android_manifest"],
                                                    permissions=["android.permission.INTERNET"]))
        assert "voice_record_audio_permission_absent" in identity.verify_report(no_mic, build)

        changed = dict(build)
        changed["version_code"] = 6
        failures = identity.verify_report(report, changed)
        assert "build_info_not_byte_equivalent_to_expected_json" in failures

        report["android_manifest"]["version_code"] = 6
        failures = identity.verify_report(report, build)
        assert "android_manifest_version_code_mismatch" in failures
        identity.write_json(report_path, report)
        assert report_path.is_file()
    print("APK_IDENTITY_SELFTEST status=PASS checked=11")


if __name__ == "__main__":
    main()
