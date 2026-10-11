"""Full HTTP upload→cloud verification→publish→launch manifest contract."""
import io
from pathlib import Path
import tempfile
import unittest
import uuid
import zipfile
import sys
import types
import os
from unittest.mock import AsyncMock, patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app import patch_service
from app.admin_auth import Admin, current_admin, writing_admin
from app.patch_firebase import FirebasePublishError, digest_file
from app.routes.patches import router


class Publisher:
    def __init__(self):
        self.calls = []
        self.fail = False

    def publish_inventory(self, files, access_token):
        if self.fail:
            raise FirebasePublishError("unavailable")
        self.calls.append(set(files))
        return {"files": {name: {"url": "https://glory-test.web.app" + name,
                                "size": path.stat().st_size, "sha256": digest_file(path)}
                          for name, path in files.items()}}


class PatchHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.publisher = Publisher()
        self.service = patch_service.PatchService(Path(self.temp.name), "glory-test", "deploy-1",
            publisher=self.publisher, credentials=lambda: "test-only")
        self.previous = patch_service.current()
        patch_service.install(self.service)
        self.addCleanup(patch_service.install, self.previous)
        self.app = FastAPI()
        self.app.include_router(router)
        self.client = TestClient(self.app)
        self.addCleanup(self.client.close)

    def authorize(self):
        admin = Admin(uuid.uuid4(), "operator")
        self.app.dependency_overrides[current_admin] = lambda: admin
        self.app.dependency_overrides[writing_admin] = lambda: admin

    @staticmethod
    def pack(name="scripts/update.gdc", content=b"new content"):
        result = io.BytesIO()
        with zipfile.ZipFile(result, "w") as archive:
            archive.writestr(name, content)
        return result.getvalue()

    def draft(self):
        response = self.client.post("/admin/api/patches", json={
            "channel": "stable", "title": "Update", "platforms": ["android"]})
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()["release_id"]

    def upload(self, release, data=None):
        return self.client.put(f"/admin/api/patches/{release}/artifacts/android?base_id=base-1",
                               content=self.pack() if data is None else data)

    def snapshot(self, seq):
        return self.client.get("/v1/patches/check", params={"channel": "stable", "platform": "android",
                                                         "base_id": "base-1", "installed_seq": seq})

    def publish(self, release, revision=None):
        if revision is None:
            revision = self.service.store.catalogue()["revision"]
        return self.client.post(f"/admin/api/patches/{release}/publish", json={"expected_revision": revision})

    def test_anonymous_and_missing_csrf_rejected(self):
        self.assertEqual(self.client.get("/admin/api/patches").status_code, 401)
        self.assertEqual(self.client.post("/admin/api/patches", json={}).status_code, 403)
        self.assertEqual(self.client.post("/admin/api/patches", headers={"X-Glory-Admin": "1"}, json={}).status_code, 401)

    def test_verified_upload_publish_and_exact_match_no_download(self):
        self.authorize()
        release = self.draft()
        self.assertEqual(self.publish(release).status_code, 409)
        self.assertEqual(self.upload(release).status_code, 200)
        self.assertEqual(self.snapshot(0).json()["action"], "none")
        self.assertEqual(self.publish(release).status_code, 200)
        self.assertEqual(self.snapshot(0).json()["action"], "download")
        response = self.snapshot(1)
        self.assertEqual(response.json()["action"], "none")
        self.assertIsNone(response.json()["artifact"])
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertEqual(self.upload(release).status_code, 400)

    def test_failed_cloud_upload_never_records_artifact_or_activates(self):
        self.authorize()
        release = self.draft()
        self.publisher.fail = True
        self.assertEqual(self.upload(release).status_code, 502)
        catalogue = self.service.catalogue()
        self.assertEqual(catalogue["releases"][0]["artifacts"], [])
        self.assertEqual(catalogue["uploads"][0]["status"], "failed")
        self.assertEqual(self.publish(release).status_code, 409)
        self.assertEqual(self.snapshot(0).json()["required_patch_seq"], 0)

    def test_new_upload_preserves_previous_downloads_and_rejects_stale_publish(self):
        self.authorize()
        first = self.draft()
        self.assertEqual(self.upload(first).status_code, 200)
        old_revision = self.service.catalogue()["revision"]
        self.assertEqual(self.publish(first).status_code, 200)
        second = self.draft()
        self.assertEqual(self.upload(second, self.pack(content=b"next")).status_code, 200)
        self.assertEqual(len(self.publisher.calls[-1]), 2)
        self.assertTrue(self.publisher.calls[0] <= self.publisher.calls[-1])
        self.assertEqual(self.publish(second, old_revision).status_code, 409)

    def test_reject_native_and_traversal_before_cloud(self):
        self.authorize()
        release = self.draft()
        for name in ("../escape", "engine.dll", "patcher/boot.json", "override.cfg", "backend/.env"):
            with self.subTest(name=name):
                self.assertEqual(self.upload(release, self.pack(name)).status_code, 400)
        self.assertEqual(self.publisher.calls, [])

    def test_account_hotfix_live_effect_reverted_by_patch_publish(self):
        self.authorize()
        fixture = types.ModuleType("patch_route_fixture")
        fixture.enabled = True
        sys.modules[fixture.__name__] = fixture
        self.addCleanup(sys.modules.pop, fixture.__name__)
        self.addCleanup(self.service.runtime.clear)
        source = 'def apply(ctx):\n import patch_route_fixture\n ctx.replace_attr(patch_route_fixture, "enabled", False)\n'
        response = self.client.post("/admin/api/patches/hotfix/account-server", json={
            "channel": "stable", "source": source, "expected_revision": self.service.catalogue()["revision"]})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertFalse(fixture.enabled)
        self.assertNotIn("source", self.client.get("/admin/api/patches").text)
        release = self.draft()
        self.assertEqual(self.upload(release).status_code, 200)
        # Failed publication must restore the currently effective runtime code.
        self.assertEqual(self.publish(release, 0).status_code, 409)
        self.assertFalse(fixture.enabled)
        self.assertEqual(self.publish(release).status_code, 200)
        self.assertTrue(fixture.enabled)
        self.assertEqual(self.service.catalogue()["hotfixes"], [])

    def test_client_gdscript_validated_pushed_and_reconnect_snapshot_revoked(self):
        godot = os.environ.get("GODOT_BIN")
        if not godot:
            self.skipTest("GODOT_BIN required for real GDScript validation")
        self.service.godot_binary = godot
        self.authorize()
        source = 'extends RefCounted\nfunc apply(ctx) -> bool:\n return ctx.set_node_property("/root/Main/Test", "visible", false)\n'
        with patch("app.routes.patches.realtime.hub") as hub:
            hub.return_value.broadcast = AsyncMock(return_value=1)
            response = self.client.post("/admin/api/patches/hotfix/client", json={
                "channel": "stable", "source": source, "expected_revision": self.service.catalogue()["revision"]})
            self.assertEqual(response.status_code, 200, response.text)
            pushed = hub.return_value.broadcast.call_args.args[0]
            self.assertEqual(pushed["t"], "patch_hotfix_snapshot")
            self.assertEqual(pushed["hotfixes"][0]["source"], source)
            self.assertEqual(self.snapshot(0).json()["hotfixes"], pushed["hotfixes"])
            key = response.json()["hotfix_id"]
            self.assertEqual(self.client.post(f"/admin/api/patches/hotfix/{key}/revoke").status_code, 200)
            self.assertEqual(hub.return_value.broadcast.call_args.args[0]["hotfixes"], [])
            self.assertEqual(self.snapshot(0).json()["hotfixes"], [])
        bad = source.replace("extends RefCounted", "extends Node")
        response = self.client.post("/admin/api/patches/hotfix/client", json={
            "channel": "stable", "source": bad, "expected_revision": self.service.catalogue()["revision"]})
        self.assertEqual(response.status_code, 400, response.text)


if __name__ == "__main__":
    unittest.main()
