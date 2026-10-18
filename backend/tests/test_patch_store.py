"""Persistent publication invariants, independent of Supabase or Firebase accounts."""
import tempfile
from pathlib import Path
import unittest
from concurrent.futures import ThreadPoolExecutor

from app.patch_store import PatchStore, PatchConflict


class PatchStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "patches.sqlite"
        self.store = PatchStore(self.path, firebase_host="glory-test.web.app")
        self.store.activate_deployment("deploy-1")

    def revision(self):
        return self.store.catalogue()["revision"]

    def artifact(self, release, platform="android", base="base-1", **overrides):
        data = dict(release_id=release, platform=platform, base_id=base,
                    sha256="a" * 64, size=123,
                    url="https://glory-test.web.app/patches/" + "a" * 64 + "/android.pck", actor="tester")
        data.update(overrides)
        self.store.record_verified_artifact(**data)

    def release(self, platforms=("android",)):
        r = self.store.create_release("stable", "Test patch", platforms, "tester")
        for platform in platforms:
            self.artifact(r, platform)
        return r

    def publish(self, r):
        return self.store.publish(r, "tester", expected_revision=self.revision())

    def hotfix(self, target="client"):
        return self.store.add_hotfix("stable", target, "example source", "tester",
                                     expected_revision=self.revision())

    def snapshot(self, installed=0, base="base-1"):
        return self.store.snapshot("stable", "android", base, installed)

    def test_no_update_sends_no_artifact(self):
        self.assertEqual(self.snapshot()["action"], "none")
        self.assertIsNone(self.snapshot()["artifact"])
        r = self.release()
        self.publish(r)
        self.assertEqual(self.snapshot()["action"], "download")
        self.assertEqual(self.snapshot(1)["action"], "none")
        self.assertIsNone(self.snapshot(1)["artifact"])

    def test_wrong_base_requires_store_update_without_download(self):
        self.publish(self.release())
        result = self.snapshot(base="incompatible-base")
        self.assertEqual(result["action"], "store_update")
        self.assertIsNone(result["artifact"])

    def test_registered_full_client_does_not_receive_old_baseline_patch_or_hotfix(self):
        self.publish(self.release())
        self.hotfix()
        self.store.register_client_base("stable", "android", "base-2", 1, "release")
        result = self.snapshot(base="base-2")
        self.assertEqual((result["action"], result["required_patch_seq"], result["hotfixes"]),
                         ("none", 0, []))
        self.assertIsNone(result["artifact"])
        self.assertEqual(self.snapshot()["action"], "download")
        self.assertEqual(self.snapshot(1)["action"], "none")
        self.assertEqual(self.store.snapshot("stable", "ios", "base-2", 0)["action"], "store_update")
        self.assertEqual(self.snapshot(1, "base-2")["action"], "reset_to_base")

    def test_full_client_registration_cannot_skip_future_patches(self):
        self.publish(self.release())
        self.store.register_client_base("stable", "android", "base-2", 1, "release")
        self.publish(self.release())
        self.assertEqual(self.snapshot(base="base-2")["action"], "store_update")
        r = self.store.create_release("stable", "New base patch", ["android"], "tester")
        self.artifact(r, base="base-2")
        self.publish(r)
        self.assertEqual(self.snapshot(base="base-2")["action"], "download")
        self.assertEqual(self.snapshot(3, "base-2")["action"], "none")

    def test_full_client_registration_checks_active_sequence(self):
        self.publish(self.release())
        with self.assertRaises(PatchConflict):
            self.store.register_client_base("stable", "android", "base-2", 2, "release")

    def test_cannot_publish_partial_platform_set(self):
        r = self.store.create_release("stable", "three platforms", ["ios", "android", "windows"], "tester")
        self.artifact(r)
        before = self.revision()
        with self.assertRaises(PatchConflict):
            self.publish(r)
        self.assertEqual(self.revision(), before)
        self.assertEqual(self.snapshot()["action"], "none")

    def test_patch_publish_expires_all_targets_atomically(self):
        for target in ("client", "account_server", "battle_server"):
            self.hotfix(target)
        self.assertEqual(len(self.store.catalogue()["hotfixes"]), 3)
        self.publish(self.release())
        self.assertEqual(self.store.catalogue()["hotfixes"], [])
        self.assertEqual(self.snapshot(1)["hotfixes"], [])

    def test_reconnect_snapshot_and_idempotent_publish(self):
        r = self.release()
        self.publish(r)
        fix = self.hotfix()
        self.assertEqual(self.snapshot(1)["hotfixes"][0]["hotfix_id"], fix)
        revision = self.revision()
        self.assertFalse(self.publish(r))
        self.assertEqual(self.revision(), revision)
        self.assertEqual(len(self.snapshot(1)["hotfixes"]), 1)
        self.assertEqual(self.snapshot(0)["hotfixes"], [])

    def test_deployment_change_expires_but_restart_does_not(self):
        self.hotfix()
        reopened = PatchStore(self.path, firebase_host="glory-test.web.app")
        self.assertFalse(reopened.activate_deployment("deploy-1"))
        self.assertEqual(len(reopened.catalogue()["hotfixes"]), 1)
        self.assertTrue(reopened.activate_deployment("deploy-2"))
        self.assertEqual(reopened.catalogue()["hotfixes"], [])

    def test_revoke_has_monotonic_snapshot(self):
        fix = self.hotfix()
        before = self.revision()
        self.assertTrue(self.store.revoke_hotfix(fix, "tester"))
        self.assertGreater(self.revision(), before)
        self.assertEqual(self.snapshot()["hotfixes"], [])
        self.assertFalse(self.store.revoke_hotfix(fix, "tester"))

    def test_rollback_requires_exact_version_even_for_newer_client(self):
        a, b = self.release(), self.release()
        self.publish(a)
        self.publish(b)
        self.hotfix()
        self.publish(a)
        result = self.snapshot(2)
        self.assertEqual(result["action"], "download")
        self.assertEqual(result["required_patch_seq"], 1)
        self.assertEqual(self.store.catalogue()["hotfixes"], [])

    def test_stale_admin_cannot_override_newer_publication(self):
        a, b = self.release(), self.release()
        before = self.revision()
        self.publish(a)
        with self.assertRaises(PatchConflict):
            self.store.publish(b, "tester", expected_revision=before)
        with self.assertRaises(PatchConflict):
            self.store.add_hotfix("stable", "client", "stale", "tester", expected_revision=before)

    def test_published_artifact_is_immutable(self):
        r = self.release()
        self.publish(r)
        with self.assertRaises(PatchConflict):
            self.artifact(r)

    def test_rejects_other_tenant_http_query_and_non_content_addressed_url(self):
        r = self.release()
        for url in ("https://evil.web.app/patches/" + "a" * 64 + "/a.pck",
                    "http://glory-test.web.app/patches/a.pck",
                    "https://glory-test.web.app/patches/a.pck",
                    "https://glory-test.web.app/patches/" + "a" * 64 + "/a.pck?x=1"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.artifact(r, url=url)

    def test_parallel_drafts_have_unique_sequences(self):
        with ThreadPoolExecutor(max_workers=4) as pool:
            ids = list(pool.map(lambda _: self.release(), range(12)))
        self.assertEqual(len(set(ids)), 12)
        sequences = sorted(r["seq"] for r in self.store.catalogue()["releases"])
        self.assertEqual(sequences, list(range(1, 13)))

    def test_server_source_is_not_exposed_in_client_snapshot(self):
        self.hotfix("account_server")
        self.hotfix("battle_server")
        self.assertEqual(self.snapshot()["hotfixes"], [])


if __name__ == "__main__":
    unittest.main()
