from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app import patch_gate, patch_service
from app.main import app


class VersionGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.service = patch_service.PatchService(Path(self.temp.name), "glory-test", "deployment")
        previous = patch_service.current()
        patch_service.install(self.service)
        self.addCleanup(patch_service.install, previous)
        config = SimpleNamespace(patch_enforce_versions=True, patch_gameplay_channel="stable")
        self.mock = patch("app.patch_gate.get_settings", return_value=config)
        self.mock.start()
        self.addCleanup(self.mock.stop)
        self.client = TestClient(app)
        self.addCleanup(self.client.close)
        self.headers = {"x-glory-patch-channel": "stable", "x-glory-patch-platform": "android",
                        "x-glory-patch-base": "base-1", "x-glory-patch-seq": "0"}

    def publish(self):
        store = self.service.store
        key = store.create_release("stable", "Update", ["android"], "admin")
        sha = "a" * 64
        store.record_verified_artifact(key, "android", "base-1", sha, 20,
            f"https://glory-test.web.app/patches/{sha}/android.zip", "admin")
        store.publish(key, "admin", expected_revision=store.catalogue()["revision"])

    def test_exact_version_required_and_alternate_channel_not_a_bypass(self):
        self.assertIsNone(patch_gate.problem(self.headers))
        self.publish()
        self.assertEqual(patch_gate.problem(self.headers)["status"], 426)
        self.headers["x-glory-patch-seq"] = "1"
        self.assertIsNone(patch_gate.problem(self.headers))
        for field, value in (("x-glory-patch-channel", "internal"), ("x-glory-patch-base", "other"),
                             ("x-glory-patch-seq", "2"), ("x-glory-patch-seq", "-1")):
            with self.subTest(field=field, value=value):
                self.assertEqual(patch_gate.problem({**self.headers, field: value})["status"], 426)

    def test_http_gameplay_blocked_but_manifest_and_health_accessible(self):
        for path in ("/v1/me", "/v1/match/queue", "/v1/battle/card", "/v1/party/start"):
            self.assertEqual(self.client.post(path).status_code, 426)
        self.assertEqual(self.client.get("/health").status_code, 200)
        self.assertEqual(self.client.get("/v1/patches/check", params={"channel": "stable",
            "platform": "android", "base_id": "base-1", "installed_seq": 0}).status_code, 200)

    def test_websocket_missing_version_rejected_before_admission(self):
        with self.assertRaises(WebSocketDisconnect) as caught:
            with self.client.websocket_connect("/v1/ws"):
                pass
        self.assertEqual(caught.exception.code, 1008)

    def test_missing_service_fails_closed_when_enforced(self):
        patch_service.install(None)
        self.assertEqual(patch_gate.problem(self.headers)["status"], 503)


if __name__ == "__main__":
    unittest.main()
