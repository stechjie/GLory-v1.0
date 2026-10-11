import gzip
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import httpx

from app.patch_firebase import FirebaseHosting, FirebasePublishError


class FirebaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.files = {}
        self.raw = {}
        for n in range(2):
            body = (f"patch-{n}-" * 200).encode()
            path = Path(self.tmp.name) / str(n)
            path.write_bytes(body)
            name = "/patches/" + hashlib.sha256(body).hexdigest() + "/android.pck"
            self.files[name] = path
            self.raw[name] = body
        self.calls = []
        self.uploads = {}
        self.corrupt = False
        self.fail_upload = False
        self.wrong_upload_host = False
        self.version = "sites/glory-test/versions/v1"

    def handler(self, request):
        self.calls.append(request)
        if request.url.host == "glory-test.web.app":
            self.assertNotIn("authorization", request.headers)
            return httpx.Response(200, content=b"corrupted" if self.corrupt else self.raw[request.url.path])
        self.assertEqual(request.headers["authorization"], "Bearer test-token")
        if request.url.path.endswith(":populateFiles"):
            payload = json.loads(request.content)
            self.assertEqual(set(payload["files"]), set(self.files))
            self.hashes = payload["files"]
            url = "https://upload-firebasehosting.googleapis.com/upload/" + self.version + "/files"
            if self.wrong_upload_host:
                url = "https://untrusted.invalid/upload"
            return httpx.Response(200, json={"uploadUrl": url, "uploadRequiredHashes": list(self.hashes.values())})
        if request.url.host == "upload-firebasehosting.googleapis.com":
            if self.fail_upload:
                return httpx.Response(500)
            body = request.read()
            digest = request.url.path.rsplit("/", 1)[-1]
            self.assertEqual(hashlib.sha256(body).hexdigest(), digest)
            self.uploads[digest] = gzip.decompress(body)
            return httpx.Response(200)
        if request.method == "PATCH":
            return httpx.Response(200, json={"status": "FINALIZED"})
        if request.url.path.endswith("/releases"):
            return httpx.Response(200, json={"version": {"name": self.version}})
        return httpx.Response(200, json={"name": self.version})

    def publish(self):
        with httpx.Client(transport=httpx.MockTransport(self.handler)) as client:
            return FirebaseHosting("glory-test", client=client).publish_inventory(self.files, "test-token")

    def test_complete_inventory_and_compressed_hashes_and_readback(self):
        result = self.publish()
        self.assertEqual(set(result["files"]), set(self.files))
        self.assertEqual(set(self.uploads.values()), set(self.raw.values()))
        self.assertEqual(sum(c.url.host == "glory-test.web.app" for c in self.calls), 2)

    def test_failed_upload_does_not_finalize_or_release(self):
        self.fail_upload = True
        with self.assertRaises(FirebasePublishError):
            self.publish()
        self.assertFalse(any(c.method == "PATCH" or c.url.path.endswith("/releases") for c in self.calls))

    def test_existing_content_needs_no_upload_destination(self):
        handler = self.handler
        def cached(request):
            if request.url.path.endswith(":populateFiles"):
                self.calls.append(request)
                return httpx.Response(200, json={})
            return handler(request)
        with httpx.Client(transport=httpx.MockTransport(cached)) as client:
            result = FirebaseHosting("glory-test", client=client).publish_inventory(self.files, "test-token")
        self.assertEqual(set(result["files"]), set(self.files))
        self.assertFalse(self.uploads)

    def test_wrong_cdn_bytes_never_confirm_verified_artifacts(self):
        self.corrupt = True
        with self.assertRaises(FirebasePublishError):
            self.publish()

    def test_never_send_credentials_to_provider_supplied_unknown_host(self):
        self.wrong_upload_host = True
        with self.assertRaises(FirebasePublishError):
            self.publish()
        self.assertFalse(any(c.url.host == "untrusted.invalid" for c in self.calls))

    def test_mutated_local_content_rejected_before_network(self):
        next(iter(self.files.values())).write_bytes(b"changed while staging")
        with self.assertRaises(ValueError):
            self.publish()
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
