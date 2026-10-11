from pathlib import Path
import tempfile
import unittest

from prepare_patch_base import prepare


class PrepareBaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.stage = Path(self.temp.name)
        (self.stage / "project.godot").write_text('''config_version=5
[application]
run/main_scene="res://main.tscn"
[autoload]
First="*res://first.gd"
Second="*res://second.gd"
[rendering]
renderer/rendering_method="gl_compatibility"
''')
        (self.stage / "first.gd").write_text("extends Node\n")
        (self.stage / "second.gd").write_text("extends Node\n")
        (self.stage / "ui/fonts").mkdir(parents=True)
        for name in ("NotoSansSC-Regular.otf", "NotoSansSC-OFL.txt"):
            (self.stage / "ui/fonts" / name).write_text("fixture")
        (self.stage / "export_presets.cfg").write_text('[preset.0]\ninclude_filter="data.json"\n')
        self.options = dict(base_id="base-1", platform="android", channel="internal",
                            backend_url="https://example.com", firebase_host="test.web.app")

    def test_prepare_preserves_autoload_order_and_pins_bootstrap(self):
        boot = prepare(self.stage, **self.options)
        self.assertEqual([entry["name"] for entry in boot["autoloads"]], ["First", "Second"])
        text = (self.stage / "project.godot").read_text()
        self.assertEqual(text.count("*res://patcher/AutoloadPlaceholder.tscn"), 2)
        self.assertIn('run/main_scene="res://patcher/UpdateGate.tscn"', text)
        self.assertIn("patcher/boot.json", (self.stage / "export_presets.cfg").read_text())
        self.assertEqual(boot["main_scene"], "res://main.tscn")
        with self.assertRaisesRegex(ValueError, "already prepared"):
            prepare(self.stage, **self.options)

    def test_non_node_autoload_rejected_before_configuration_mutates(self):
        (self.stage / "second.gd").write_text("extends Control\n")
        before = (self.stage / "project.godot").read_bytes()
        with self.assertRaisesRegex(ValueError, "must extend Node"):
            prepare(self.stage, **self.options)
        self.assertEqual(before, (self.stage / "project.godot").read_bytes())

    def test_source_checkout_and_non_tls_backend_rejected(self):
        with self.assertRaisesRegex(ValueError, "HTTPS"):
            prepare(self.stage, **{**self.options, "backend_url": "http://example.com"})
        (self.stage / ".git").write_text("gitdir: /elsewhere")
        with self.assertRaisesRegex(ValueError, "checkout"):
            prepare(self.stage, **self.options)


if __name__ == "__main__":
    unittest.main()
