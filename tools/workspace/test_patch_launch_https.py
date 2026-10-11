"""Actual Godot launcher + trusted local HTTPS server; no TLS bypass in product code."""
import datetime
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, urlsplit
import uuid
import zipfile

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID


class LauncherHTTPSTests(unittest.TestCase):
    def test_download_mount_boot_then_relaunch_without_redownload(self):
        self.run_scenario("download")

    def test_corrupt_download_never_starts_business(self):
        self.run_scenario("corrupt")

    def test_publication_changes_during_download_never_mounts_stale_candidate(self):
        self.run_scenario("publication_changed")

    def test_base_without_a_new_patch_does_not_download(self):
        self.run_scenario("base_current")

    def test_channel_switch_with_equal_sequence_does_not_reuse_other_channel_pack(self):
        self.run_scenario("channel_switch")

    def run_scenario(self, scenario):
        engine = os.environ.get("GODOT_BIN")
        if not engine:
            self.skipTest("GODOT_BIN required")
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
            now = datetime.datetime.now(datetime.timezone.utc)
            cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
                .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(days=1))
                .not_valid_after(now + datetime.timedelta(days=1))
                .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
                .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost")]), critical=False)
                .sign(key, hashes.SHA256()))
            (root / "server.crt").write_bytes(cert.public_bytes(serialization.Encoding.PEM))
            (root / "server.key").write_bytes(key.private_bytes(serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, "w") as archive:
                archive.writestr("service.gd", "extends Node\nfunc value() -> int:\n return 42\n")
            pack = stream.getvalue()
            checksum = hashlib.sha256(pack).hexdigest()
            other = io.BytesIO()
            with zipfile.ZipFile(other, "w") as archive:
                archive.writestr("service.gd", "extends Node\nfunc value() -> int:\n return 84\n")
            stable_pack = other.getvalue()
            stable_checksum = hashlib.sha256(stable_pack).hexdigest()
            counters = {"downloads": 0, "checks": 0}
            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *_args):
                    pass
                def do_GET(self):
                    parsed = urlsplit(self.path)
                    if parsed.path == "/v1/patches/check":
                        counters["checks"] += 1
                        seq = int(parse_qs(parsed.query)["installed_seq"][0])
                        channel = parse_qs(parsed.query)["channel"][0]
                        selected, selected_sha = (stable_pack, stable_checksum) if channel == "stable" else (pack, checksum)
                        required = 0 if scenario == "base_current" else (2 if scenario == "publication_changed" and seq == 1 else 1)
                        artifact = {"sha256": selected_sha, "size": len(selected), "platform": "windows", "base_id": "test-base",
                            "url": f"https://localhost:{self.server.server_port}/patches/{selected_sha}/windows.zip"}
                        body = json.dumps({"protocol": 1, "channel": channel, "platform": "windows", "base_id": "test-base",
                            "deployment_id": "server-one", "revision": 1, "hotfix_epoch": 1, "required_patch_seq": required,
                            "action": "none" if seq == required else "download", "artifact": None if seq == required else artifact,
                            "hotfixes": []}).encode()
                    elif parsed.path == f"/patches/{checksum}/windows.zip":
                        counters["downloads"] += 1
                        body = bytes([pack[0] ^ 1]) + pack[1:] if scenario == "corrupt" else pack
                    elif parsed.path == f"/patches/{stable_checksum}/windows.zip":
                        counters["downloads"] += 1
                        body = stable_pack
                    else:
                        self.send_error(404)
                        return
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(root / "server.crt", root / "server.key")
            server.socket = context.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            project = root / "project"
            (project / "patcher").mkdir(parents=True)
            source = Path(__file__).resolve().parents[2]
            for path in (source / "patcher").glob("*"):
                if path.is_file():
                    shutil.copy2(path, project / "patcher" / path.name)
            shutil.copy2(source / "ui/fonts/NotoSansSC-Regular.otf", project / "patcher/LauncherFont.otf")
            shutil.copy2(root / "server.crt", project / "server.crt")
            app_name = "GloryHTTPSProbe-" + uuid.uuid4().hex
            (project / "project.godot").write_text(f'''config_version=5
[application]
config/name="{app_name}"
run/main_scene="res://patcher/UpdateGate.tscn"
[autoload]
ProbeSingleton="*res://patcher/AutoloadPlaceholder.tscn"
TestWatchdog="*res://watchdog.gd"
[network]
tls/certificate_bundle_override="res://server.crt"
''')
            (project / "watchdog.gd").write_text('''extends Node
func _ready():
 print("TEST_USER_DIR=" + OS.get_user_data_dir())
 get_tree().create_timer(4).timeout.connect(func():
  print("LAUNCH_TIMEOUT")
  var page=get_tree().current_scene
  if page != null and page.get("_detail") != null:
   print("FAILURE_DETAIL=" + page.get("_detail").text)
  get_tree().quit(9))
''')
            (project / "service.gd").write_text('extends Node\nfunc value() -> int:\n return 1\n')
            expected_value = 1 if scenario == "base_current" else 42
            (project / "game.gd").write_text('''extends Node
func _ready():
 var value := ProbeSingleton.value()
 print("GAME_STARTED_VALUE=" + str(value))
 get_tree().quit(0 if value == %d else 8)
''' % expected_value)
            (project / "game.tscn").write_text('[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://game.gd" id="1"]\n[node name="Game" type="Node"]\nscript=ExtResource("1")\n')
            (project / "patcher/boot.json").write_text(json.dumps({"protocol": 1, "base_id": "test-base", "platform": "windows",
                "channel": "internal", "backend_url": f"https://localhost:{server.server_port}",
                "firebase_host": f"localhost:{server.server_port}", "main_scene": "res://game.tscn",
                "autoloads": [{"name": "ProbeSingleton", "path": "res://service.gd"}]}))
            imported = subprocess.run([engine, "--headless", "--editor", "--path", str(project), "--import"],
                                      capture_output=True, text=True, timeout=30)
            self.assertEqual(imported.returncode, 0, imported.stderr)
            successful = scenario in ("download", "base_current", "channel_switch")
            for attempt in range(2 if successful else 1):
                if scenario == "channel_switch" and attempt == 1:
                    boot_path = project / "patcher/boot.json"
                    boot = json.loads(boot_path.read_text())
                    boot["channel"] = "stable"
                    boot_path.write_text(json.dumps(boot))
                    game = project / "game.gd"
                    game.write_text(game.read_text().replace("value == 42", "value == 84"))
                    expected_value = 84
                result = subprocess.run([engine, "--headless", "--path", str(project)],
                                        capture_output=True, text=True, timeout=20)
                for line in result.stdout.splitlines():
                    if line.startswith("TEST_USER_DIR="):
                        user_dir = Path(line.split("=", 1)[1])
                        if user_dir.name == app_name:
                            self.addCleanup(shutil.rmtree, user_dir, True)
                self.assertEqual(result.returncode, 0 if successful else 9, result.stdout + result.stderr)
                if successful:
                    self.assertIn(f"GAME_STARTED_VALUE={expected_value}", result.stdout)
                else:
                    self.assertNotIn("GAME_STARTED_VALUE=", result.stdout)
                    expected = "校验失败" if scenario == "corrupt" else "版本刚刚更新"
                    self.assertIn(expected, result.stdout)
                self.assertNotIn("SCRIPT ERROR", result.stderr)
                expected_downloads = attempt + 1 if scenario == "channel_switch" else (0 if scenario == "base_current" else 1)
                self.assertEqual(counters["downloads"], expected_downloads, f"attempt {attempt}")
            if scenario == "download":
                self.assertGreaterEqual(counters["checks"], 3)


if __name__ == "__main__":
    unittest.main()
