"""Offline ASC tests: generated temporary keys, mocked HTTP, no Apple account."""

import base64
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import urllib.error
import urllib.request
from unittest import mock

import glory_asc as asc


def decode64(value):
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


class Response:
    def __init__(self, body=None, status=200, raw=None):
        self.status = status
        self.data = raw if raw is not None else json.dumps(body or {}).encode()

    def read(self, count=-1):
        return self.data if count < 0 else self.data[:count]

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def http_error(status, body=None, headers=None):
    return urllib.error.HTTPError(
        asc.API_BASE + "/apps", status, "SERVER-SECRET",
        headers or {}, io.BytesIO(json.dumps(body or {}).encode()),
    )


class ASCTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.key = cls.root / "AuthKey_TESTKEY123.p8"
        subprocess.run([
            "openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256",
            "-out", str(cls.key),
        ], check=True, capture_output=True)
        cls.key.chmod(0o600)
        cls.credentials = asc.Credentials("TESTKEY123", "12345678-1234-1234-1234-123456789abc", cls.key)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        asc._TOKEN_CACHE.clear()

    def client(self):
        client = asc.Client(self.credentials)
        client._opener = mock.Mock()
        return client

    def test_actual_es256_jwt_claims_and_openssl_signature_verification(self):
        with mock.patch.object(asc.time, "time", return_value=1_800_000_000):
            token = asc.make_token(self.credentials)
        header, claims, signature = token.split(".")
        self.assertEqual(json.loads(decode64(header)), {"alg": "ES256", "kid": "TESTKEY123", "typ": "JWT"})
        self.assertEqual(json.loads(decode64(claims)), {
            "iss": self.credentials.issuer_id, "aud": "appstoreconnect-v1",
            "iat": 1_800_000_000, "exp": 1_800_000_600,
        })
        raw = decode64(signature)
        self.assertEqual(len(raw), 64)
        # Independent JOSE -> DER encoding, then real OpenSSL public-key verification.
        encoded = b""
        for part in (raw[:32], raw[32:]):
            number = part.lstrip(b"\0") or b"\0"
            if number[0] & 0x80:
                number = b"\0" + number
            encoded += bytes([2, len(number)]) + number
        sig = self.root / "signature.der"
        sig.write_bytes(bytes([0x30, len(encoded)]) + encoded)
        public = self.root / "public.pem"
        subprocess.run(["openssl", "pkey", "-in", str(self.key), "-pubout", "-out", str(public)],
                       check=True, capture_output=True)
        result = subprocess.run([
            "openssl", "dgst", "-sha256", "-verify", str(public), "-signature", str(sig),
        ], input=f"{header}.{claims}".encode(), capture_output=True)
        self.assertEqual(result.returncode, 0)

    def test_token_cache_refresh_and_clock_rollback(self):
        with mock.patch.object(asc.time, "time", return_value=1000):
            token = asc.make_token(self.credentials)
        with mock.patch.object(asc.time, "time", return_value=1539):
            self.assertEqual(asc.make_token(self.credentials), token)
        with mock.patch.object(asc.time, "time", return_value=1540):
            refreshed = asc.make_token(self.credentials)
            self.assertNotEqual(refreshed, token)
        with mock.patch.object(asc.time, "time", return_value=900):
            self.assertEqual(json.loads(decode64(asc.make_token(self.credentials).split('.')[1]))['iat'], 900)

    def test_credentials_reject_bad_ids_permissions_and_project_location(self):
        for key_id, issuer in [("short", self.credentials.issuer_id), ("testkey123", self.credentials.issuer_id),
                               ("TESTKEY123", "not-a-uuid"), ("TESTKEY123", "1" * 32)]:
            with self.subTest(key_id=key_id, issuer=issuer), self.assertRaises(ValueError):
                asc.Credentials(key_id, issuer, self.key).validate()
        other = self.root / "permissions.p8"
        other.write_bytes(self.key.read_bytes())
        other.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "0600"):
            asc.Credentials(self.credentials.key_id, self.credentials.issuer_id, other).validate()
        with mock.patch.object(asc, "PROJECT_ROOT", self.root), self.assertRaisesRegex(ValueError, "outside"):
            self.credentials.validate()
        link = self.root / "linked.p8"
        link.symlink_to(self.key)
        with self.assertRaisesRegex(ValueError, "non-symlink"):
            asc.Credentials(self.credentials.key_id, self.credentials.issuer_id, link).validate()

    def test_wrong_curve_and_openssl_errors_do_not_expose_private_key(self):
        other = self.root / "p384.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-384",
                        "-out", str(other)], check=True, capture_output=True)
        other.chmod(0o600)
        with self.assertRaisesRegex(ValueError, "P-256"):
            asc.Credentials(self.credentials.key_id, self.credentials.issuer_id, other).validate()
        with mock.patch.object(asc.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, b"SECRET", b"SECRET")):
            with self.assertRaises(ValueError) as caught:
                self.credentials.validate()
        self.assertNotIn("SECRET", str(caught.exception))

    def test_public_key_is_rejected_and_cached_token_rechecks_file_permissions(self):
        public = self.root / "public-only.pem"
        subprocess.run(["openssl", "pkey", "-in", str(self.key), "-pubout", "-out", str(public)],
                       check=True, capture_output=True)
        public.chmod(0o600)
        with self.assertRaises(ValueError):
            asc.Credentials(self.credentials.key_id, self.credentials.issuer_id, public).validate()
        private = self.root / "cache-permissions.p8"
        private.write_bytes(self.key.read_bytes())
        private.chmod(0o600)
        credentials = asc.Credentials(self.credentials.key_id, self.credentials.issuer_id, private)
        asc.make_token(credentials)
        private.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "0600"):
            asc.make_token(credentials)

    def test_der_signature_conversion_handles_sign_padding_and_rejects_malformed(self):
        number = b"\x80" + b"\x11" * 31
        body = b"\x02\x21\0" + number + b"\x02\x01\x01"
        self.assertEqual(asc._der_signature_to_raw(bytes([0x30, len(body)]) + body), number + b"\0" * 31 + b"\x01")
        for bad in [b"", b"\x30\x00", b"\x30\x06\x02\x01\x80\x02\x01\x01",
                    b"\x30\x07\x02\x02\0\x01\x02\x01\x01",
                    b"\x30\x06\x02\x01\0\x02\x01\x01"]:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                asc._der_signature_to_raw(bad)

    def test_get_retries_network_429_503_then_succeeds_with_bounded_waits(self):
        client = self.client()
        client._opener.open.side_effect = [
            urllib.error.URLError("SECRET"), http_error(429, headers={"Retry-After": "999"}),
            http_error(503), Response({"data": []}),
        ]
        with mock.patch.object(asc.time, "sleep") as sleep:
            self.assertEqual(client.request("GET", "/apps", params={"filter[bundleId]": "com.example.game"}), {"data": []})
        self.assertEqual(client._opener.open.call_count, 4)
        self.assertEqual(len(sleep.call_args_list), 3)
        self.assertTrue(all(0 <= call.args[0] <= 10 for call in sleep.call_args_list))
        request = client._opener.open.call_args.args[0]
        self.assertEqual(request.full_url, asc.API_BASE + "/apps?filter%5BbundleId%5D=com.example.game")
        self.assertTrue(request.get_header("Authorization").startswith("Bearer "))
        self.assertEqual(client._opener.open.call_args.kwargs["timeout"], 10)

    def test_get_stops_after_three_retries_and_does_not_retry_403(self):
        client = self.client()
        client._opener.open.side_effect = lambda *args, **kwargs: http_raise(503)
        with mock.patch.object(asc.time, "sleep"), self.assertRaises(asc.ApiError) as caught:
            client.request("GET", "/apps")
        self.assertEqual(caught.exception.status, 503)
        self.assertEqual(client._opener.open.call_count, 4)
        client._opener.open.reset_mock()
        client._opener.open.side_effect = http_error(403)
        with mock.patch.object(asc.time, "sleep") as sleep, self.assertRaises(asc.ApiError):
            client.request("GET", "/apps")
        self.assertEqual(client._opener.open.call_count, 1)
        sleep.assert_not_called()

    def test_mutations_never_retry_and_204_is_empty_dict(self):
        for method in ("POST", "PATCH", "DELETE"):
            for error in (http_error(503), urllib.error.URLError("SECRET")):
                client = self.client()
                client._opener.open.side_effect = error
                with mock.patch.object(asc.time, "sleep") as sleep, self.assertRaises(asc.ApiError):
                    client.request(method, "/apps", {"data": {"type": "apps"}})
                self.assertEqual(client._opener.open.call_count, 1)
                sleep.assert_not_called()
        client = self.client()
        client._opener.open.return_value = Response(status=204, raw=b"")
        self.assertEqual(client.request("DELETE", "/apps/123"), {})

    def test_pagination_preserves_next_query_and_rejects_external_links_before_auth(self):
        client = self.client()
        client._opener.open.side_effect = [
            Response({"data": [{"id": "1"}], "links": {"next": asc.API_BASE + "/apps?cursor=next"}}),
            Response({"data": [{"id": "2"}], "links": {"next": None}}),
        ]
        self.assertEqual(client.items("/apps", {"limit": 1}), [{"id": "1"}, {"id": "2"}])
        self.assertEqual(client._opener.open.call_args.args[0].full_url, asc.API_BASE + "/apps?cursor=next")
        client = self.client()
        client._opener.open.return_value = Response({"data": [], "links": {"next": "https://example.com/v1/apps"}})
        with self.assertRaises(ValueError):
            client.items("/apps")
        self.assertEqual(client._opener.open.call_count, 1)

    def test_url_rejection_and_redirect_handler_never_forward_auth(self):
        client = self.client()
        for url in ["http://api.appstoreconnect.apple.com/v1/apps", "https://example.com/v1/apps",
                    "//example.com/v1/apps", "https://user@api.appstoreconnect.apple.com/v1/apps",
                    "https://api.appstoreconnect.apple.com:443/v1/apps",
                    "https://api.appstoreconnect.apple.com/v2/apps", "https://api.appstoreconnect.apple.com/v1/../v2/apps",
                    "https://api.appstoreconnect.apple.com/v1/%252e%252e/v2/apps",
                    "https://api.appstoreconnect.apple.com/v1/apps#fragment", "/apps\n"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                client.request("GET", url)
        client._opener.open.assert_not_called()
        request = urllib.request.Request(asc.API_BASE + "/apps", headers={"Authorization": "Bearer SECRET"})
        self.assertIsNone(asc._NoRedirect().redirect_request(request, None, 302, "", {}, "https://example.com"))
        # Default redirect handlers are replaced, not left enabled alongside ours.
        real_client = asc.Client(self.credentials)
        redirect_handlers = [h for h in real_client._opener.handlers if isinstance(h, urllib.request.HTTPRedirectHandler)]
        self.assertEqual([type(h) for h in redirect_handlers], [asc._NoRedirect])

    def test_errors_never_include_server_echoed_tokens_or_private_key(self):
        secret = "-----BEGIN PRIVATE KEY----- SECRET eyJhbGciOiJFUzI1NiJ9.PAYLOAD.SIGNATURE"
        client = self.client()
        client._opener.open.side_effect = http_error(401, {"errors": [
            {"code": "NOT_AUTHORIZED." + secret, "title": secret, "detail": secret},
            {"code": secret, "title": secret},
        ]})
        with self.assertRaises(asc.ApiError) as caught:
            client.request("POST", "/apps", {"secret": secret})
        rendered = str(caught.exception) + repr(caught.exception.errors)
        for marker in ("SECRET", "PRIVATE KEY", "eyJ", "PAYLOAD", "SIGNATURE"):
            self.assertNotIn(marker, rendered)
        self.assertEqual(caught.exception.status, 401)
        self.assertLess(len(str(caught.exception)), 350)

    def test_invalid_json_and_pagination_loop_fail_without_retries(self):
        client = self.client()
        client._opener.open.return_value = Response(raw=b"SERVER-SECRET")
        with self.assertRaises(asc.ApiError) as caught:
            client.request("GET", "/apps")
        self.assertNotIn("SERVER-SECRET", str(caught.exception))
        self.assertEqual(client._opener.open.call_count, 1)
        client = self.client()
        client._opener.open.return_value = Response({"data": [], "links": {"next": asc.API_BASE + "/apps"}})
        with self.assertRaises(asc.ApiError):
            client.items("/apps")
        self.assertEqual(client._opener.open.call_count, 1)


def http_raise(status):
    raise http_error(status)


if __name__ == "__main__":
    unittest.main()
