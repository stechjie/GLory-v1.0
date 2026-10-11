import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from glory_patch import build


class CumulativePatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.files = {"patcher/boot.json": json.dumps({"platform": "android", "base_id": "base-1"}),
                      "project.binary": "immutable project", "ui.gdc": "original",
                      ".godot/imported/image.ctex": "original texture"}

    def archive(self, name, files):
        path = self.root / name
        with zipfile.ZipFile(path, "w") as archive:
            for key, value in files.items():
                archive.writestr(key, value)
        return path

    def run_build(self, changes, **kwargs):
        return build(self.archive("base.zip", self.files), self.archive("current.zip", changes),
                     self.root / "patch.zip", platform=kwargs.get("platform", "android"), base_id="base-1")

    def test_cumulative_resources_load_without_unchanged_base(self):
        changed = {**self.files, "ui.gdc": "new code", "audio.ogg": "new audio"}
        report = self.run_build(changed)
        self.assertEqual(report["files"], ["audio.ogg", "ui.gdc"])
        with zipfile.ZipFile(self.root / "patch.zip") as archive:
            self.assertEqual(archive.read("ui.gdc"), b"new code")
            self.assertNotIn("project.binary", archive.namelist())

    def test_native_bootstrap_and_global_class_changes_need_full_build(self):
        for name in ("plugin.dll", "patcher/UpdateGate.gd", "project.binary",
                     ".godot/global_script_class_cache.cfg"):
            with self.subTest(name=name):
                with self.assertRaisesRegex(ValueError, "full build"):
                    self.run_build({**self.files, name: "changed"})

    def test_deletion_cannot_be_emulated_by_overlay(self):
        with self.assertRaisesRegex(ValueError, "Deletion"):
            self.run_build({key: value for key, value in self.files.items() if key != "ui.gdc"})

    def test_wrong_platform_and_no_changes_rejected(self):
        with self.assertRaisesRegex(ValueError, "identity"):
            self.run_build(self.files, platform="ios")
        with self.assertRaisesRegex(ValueError, "No changed"):
            self.run_build(self.files)

    def test_zip_traversal_rejected(self):
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            self.run_build({**self.files, "../ui.gdc": "escape"})


if __name__ == "__main__":
    unittest.main()
