"""Reject installed-client changes before a production resource patch export."""
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from export_patch import digest, native_inventory, preset_policy_digest
from glory_android_production_patch import (
    load_baseline, reuse_generated_import_metadata, seed_import_cache, verify_stage,
)


class ProductionBaselineGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.stage = self.root / "project"
        self.folder = self.root / "baseline"
        for p in (self.stage, self.folder / "source-snapshot"):
            p.mkdir(parents=True)
        (self.stage / "project.godot").write_text("config_version=5\n")
        (self.stage / "export_presets.cfg").write_text('exclude_filter=""\n')
        (self.folder / "source-snapshot/project.godot").write_bytes(
            (self.stage / "project.godot").read_bytes())
        (self.stage / "patcher").mkdir()
        (self.stage / "patcher/boot.json").write_text('{"base_id":"installed"}')
        (self.stage / "plugin.aar").write_bytes(b"installed native plugin")
        record = {"preset_policy_sha256": preset_policy_digest(self.stage),
                  "native_files": native_inventory(self.stage),
                  "slim_generated_exclusions": []}
        (self.folder / "base.export.json").write_text(json.dumps(record))
        with zipfile.ZipFile(self.folder / "base.zip", "w") as archive:
            archive.write(self.stage / "patcher/boot.json", "patcher/boot.json")

    def test_resource_changes_remain_patchable(self):
        (self.stage / "balance.json").write_text('{"damage":42}')
        verify_stage(self.stage, self.folder)

    def test_project_settings_change_cannot_be_hidden(self):
        (self.stage / "project.godot").write_text('config_version=5\nnew_setting=true\n')
        with self.assertRaisesRegex(ValueError, "project.godot changed"):
            verify_stage(self.stage, self.folder)

    def test_preset_change_cannot_be_hidden(self):
        (self.stage / "export_presets.cfg").write_text('exclude_filter="required/*"\n')
        with self.assertRaisesRegex(ValueError, "preset policy changed"):
            verify_stage(self.stage, self.folder)

    def test_native_change_cannot_be_hidden(self):
        (self.stage / "plugin.aar").write_bytes(b"changed native plugin")
        with self.assertRaisesRegex(ValueError, "Native inputs changed"):
            verify_stage(self.stage, self.folder)

    def test_launcher_change_cannot_be_hidden(self):
        (self.stage / "patcher/boot.json").write_text('{"base_id":"different"}')
        with self.assertRaisesRegex(ValueError, "Immutable launcher changed"):
            verify_stage(self.stage, self.folder)

    def test_ios_pointer_is_rejected_before_export(self):
        pointer = self.root / "pointer.json"
        pointer.write_text(json.dumps({"schema_version": 1, "platform": "ios",
                                       "environment": "prod", "channel": "production"}))
        with self.assertRaisesRegex(ValueError, "Android production baseline"):
            load_baseline(pointer)

    def cache_fixture(self):
        (self.folder / "import-cache").mkdir()
        (self.folder / "import-cache/data.bin").write_bytes(b"retained cache")
        (self.folder / "import-sidecars").mkdir()
        (self.folder / "import-sidecars/model.glb.import").write_text("enriched import metadata")
        (self.stage / "model.glb.import").write_text("raw import settings")
        (self.stage / "model.glb").write_bytes(b"original model")
        row = {"raw_input_sha256": digest(self.stage / "model.glb.import"),
               "source_file": "model.glb", "source_sha256": digest(self.stage / "model.glb")}
        (self.folder / "import-cache-inputs.json").write_text(json.dumps({"model.glb.import": row}))

    def test_cache_does_not_override_changed_model(self):
        self.cache_fixture()
        (self.stage / "model.glb").write_bytes(b"updated model")
        result = seed_import_cache(self.stage, self.folder)
        self.assertEqual(result["qualified_sidecars_reused"], 0)
        self.assertEqual((self.stage / "model.glb.import").read_text(), "raw import settings")
        self.assertEqual((self.stage / "model.glb").read_bytes(), b"updated model")

    def test_cache_does_not_override_changed_import_settings(self):
        self.cache_fixture()
        (self.stage / "model.glb.import").write_text("updated import settings")
        result = seed_import_cache(self.stage, self.folder)
        self.assertEqual(result["qualified_sidecars_reused"], 0)
        self.assertEqual((self.stage / "model.glb.import").read_text(), "updated import settings")

    def test_unchanged_input_reuses_metadata_with_independent_cache(self):
        self.cache_fixture()
        result = seed_import_cache(self.stage, self.folder)
        self.assertEqual(result["qualified_sidecars_reused"], 1)
        self.assertEqual((self.stage / "model.glb.import").read_text(), "enriched import metadata")
        (self.stage / ".godot/data.bin").write_bytes(b"cache changed by importer")
        self.assertEqual((self.folder / "import-cache/data.bin").read_bytes(), b"retained cache")

    def generated_fixture(self):
        self.cache_fixture()
        row = {"source_file": "model.glb", "source_sha256": digest(self.stage / "model.glb"),
               "original_raw_sidecar_absent": True}
        (self.folder / "import-generated-inputs.json").write_text(json.dumps({"model.glb.import": row}))

    def test_generated_metadata_cannot_override_new_explicit_settings(self):
        self.generated_fixture()
        self.assertEqual(reuse_generated_import_metadata(self.stage, self.folder), 0)
        self.assertEqual((self.stage / "model.glb.import").read_text(), "raw import settings")

    def test_generated_metadata_only_reused_for_unchanged_source(self):
        self.generated_fixture()
        (self.stage / "model.glb.import").unlink()
        (self.stage / "model.glb").write_bytes(b"new source")
        self.assertEqual(reuse_generated_import_metadata(self.stage, self.folder), 0)
        self.assertFalse((self.stage / "model.glb.import").exists())
        (self.stage / "model.glb").write_bytes(b"original model")
        self.assertEqual(reuse_generated_import_metadata(self.stage, self.folder), 1)
        self.assertEqual((self.stage / "model.glb.import").read_text(), "enriched import metadata")


if __name__ == "__main__":
    unittest.main()
