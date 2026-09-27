"""Small App Store Connect client for team API keys; no third-party packages.

Credentials remain outside the project. Tokens live only in memory. Mutations
are never retried: the caller must read back state after an uncertain result.
"""

import base64
from dataclasses import dataclass, field
import http.client
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


API_BASE = "https://api.appstoreconnect.apple.com/v1"
PROJECT_ROOT = Path(__file__).resolve().parents[3]
MAX_GET_RETRIES = 3
TIMEOUT = 10
_TOKEN_CACHE = {}
_TOKEN_LOCK = threading.Lock()
# SubjectPublicKeyInfo for id-ecPublicKey / prime256v1, uncompressed point.
_P256_SPKI_PREFIX = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d03010703420004")
_ERROR_TITLES = {
    "NOT_AUTHORIZED": "Authentication failed",
    "AUTHENTICATION_ERROR": "Authentication failed",
    "UNAUTHORIZED": "Authentication failed",
    "FORBIDDEN_ERROR": "Access forbidden",
    "FORBIDDEN": "Access forbidden",
    "NOT_FOUND": "Resource not found",
    "NOT_FOUND_ERROR": "Resource not found",
    "PARAMETER_ERROR": "Invalid parameter",
    "ENTITY_ERROR": "Invalid resource",
    "ENTITY_UNPROCESSABLE": "Resource cannot be processed",
    "INVALID_REQUEST": "Invalid request",
    "STATE_ERROR": "Invalid resource state",
    "CONFLICT": "Resource conflict",
    "RATE_LIMIT_EXCEEDED": "Rate limit exceeded",
    "UNEXPECTED_ERROR": "Unexpected API error",
    "INTERNAL_ERROR": "Internal API error",
    "SERVICE_UNAVAILABLE": "Service unavailable",
    "NETWORK_ERROR": "Network request failed",
    "INVALID_RESPONSE": "Invalid API response",
    "PAGINATION_ERROR": "Invalid pagination response",
    "API_ERROR": "API request failed",
}


class ApiError(RuntimeError):
    """Only status and bounded, allowlisted labels are exposed to callers/logs."""

    def __init__(self, status=None, errors=None):
        self.status = status if isinstance(status, int) else None
        self.errors = []
        if isinstance(errors, list):
            for error in errors[:3]:
                code = error.get("code") if isinstance(error, dict) else None
                # ASC suffixes and arbitrary titles/details can echo submitted data.
                base = code.split(".", 1)[0] if isinstance(code, str) and len(code) <= 120 else ""
                if base not in _ERROR_TITLES:
                    base = "API_ERROR"
                label = {"code": base, "title": _ERROR_TITLES[base]}
                if label not in self.errors:
                    self.errors.append(label)
        if not self.errors:
            self.errors = [{"code": "API_ERROR", "title": _ERROR_TITLES["API_ERROR"]}]
        summary = "; ".join(f"{e['code']}: {e['title']}" for e in self.errors)
        super().__init__(f"ASC status={self.status if self.status is not None else 'unavailable'} {summary}")


def _local_error(code, status=None):
    return ApiError(status, [{"code": code}])


def _openssl(args, data=None):
    try:
        result = subprocess.run(
            ["openssl", *args], input=data, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=TIMEOUT, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        raise ValueError("OpenSSL could not process the API signing key") from None
    if result.returncode:
        raise ValueError("OpenSSL rejected the API signing key or signature")
    return result.stdout


@dataclass(frozen=True)
class Credentials:
    key_id: str
    issuer_id: str
    key_path: Path = field(repr=False)

    def validate(self):
        if not isinstance(self.key_id, str) or not re.fullmatch(r"[A-Z0-9]{10}", self.key_id):
            raise ValueError("Team API Key ID must contain 10 uppercase letters/digits")
        if not isinstance(self.issuer_id, str) or not re.fullmatch(
            r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", self.issuer_id
        ):
            raise ValueError("Team API issuer ID must be a UUID")
        uuid.UUID(self.issuer_id)
        if not isinstance(self.key_path, Path):
            raise ValueError("API key_path must be a pathlib.Path")
        try:
            resolved = self.key_path.resolve(strict=True)
            info = self.key_path.lstat()
        except OSError:
            raise ValueError("API signing key is unavailable") from None
        if resolved.is_relative_to(PROJECT_ROOT.resolve()):
            raise ValueError("Store the API signing key outside the project directory")
        if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600:
            raise ValueError("API signing key must be a regular, non-symlink file with mode 0600")
        if info.st_uid != os.getuid():
            raise ValueError("API signing key must belong to the current user")
        # An empty passphrase prevents a prompt. Never expose OpenSSL stderr.
        _openssl(["pkey", "-in", str(resolved), "-passin", "pass:", "-check", "-noout"])
        public = _openssl(["pkey", "-in", str(resolved), "-passin", "pass:", "-pubout", "-outform", "DER"])
        if len(public) != 91 or not public.startswith(_P256_SPKI_PREFIX):
            raise ValueError("Team API signing key must use the P-256 curve")


def _b64url(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _der_signature_to_raw(signature):
    """Convert the strict short DER SEQUENCE(INTEGER r, INTEGER s) to JOSE."""
    if len(signature) < 8 or signature[0] != 0x30 or signature[1] != len(signature) - 2:
        raise ValueError("Invalid ES256 signature encoding")
    offset = 2
    numbers = []
    for _ in range(2):
        if offset + 2 > len(signature) or signature[offset] != 0x02:
            raise ValueError("Invalid ES256 signature encoding")
        length = signature[offset + 1]
        offset += 2
        value = signature[offset:offset + length]
        offset += length
        if (not 1 <= length <= 33 or len(value) != length or value[0] & 0x80
                or (length > 1 and value[0] == 0 and not value[1] & 0x80)):
            raise ValueError("Invalid ES256 signature integer")
        number = int.from_bytes(value, "big")
        if not 0 < number < 2 ** 256:
            raise ValueError("Invalid ES256 signature integer")
        numbers.append(number.to_bytes(32, "big"))
    if offset != len(signature):
        raise ValueError("Invalid ES256 signature encoding")
    return b"".join(numbers)


def make_token(credentials):
    """Return a 10-minute ES256 team JWT; refresh 60 seconds before expiry."""
    credentials.validate()
    key = credentials.key_path.resolve()
    info = key.stat()
    cache_key = (credentials.key_id, credentials.issuer_id, str(key),
                 info.st_dev, info.st_ino, info.st_mtime_ns, info.st_size)
    with _TOKEN_LOCK:
        now = int(time.time())
        cached = _TOKEN_CACHE.get(cache_key)
        if cached and cached[0] <= now < cached[1] - 60:
            return cached[2]
        header = {"alg": "ES256", "kid": credentials.key_id, "typ": "JWT"}
        claims = {"iss": credentials.issuer_id, "aud": "appstoreconnect-v1", "iat": now, "exp": now + 600}
        message = ".".join(_b64url(json.dumps(x, separators=(",", ":")).encode()) for x in (header, claims))
        signed = _openssl(["dgst", "-sha256", "-sign", str(key), "-passin", "pass:"], message.encode("ascii"))
        token = message + "." + _b64url(_der_signature_to_raw(signed))
        # Normally one key; bound memory and avoid retaining obsolete tokens.
        _TOKEN_CACHE.clear()
        _TOKEN_CACHE[cache_key] = (now, now + 600, token)
        return token


def _safe_url(path, params=None):
    if not isinstance(path, str) or not path or "\\" in path or any(ord(c) < 32 or ord(c) == 127 for c in path):
        raise ValueError("ASC URL must be a valid API path")
    parts = urllib.parse.urlsplit(path)
    if parts.scheme or parts.netloc:
        url = path
    elif path.startswith("/v1/") or path == "/v1":
        url = "https://api.appstoreconnect.apple.com" + path
    elif path.startswith("/v1?"):
        url = "https://api.appstoreconnect.apple.com" + path
    else:
        url = API_BASE + "/" + path.lstrip("/")
    parts = urllib.parse.urlsplit(url)
    decoded = parts.path
    for _ in range(3):
        new = urllib.parse.unquote(decoded)
        if new == decoded:
            break
        decoded = new
    if (parts.scheme != "https" or parts.netloc.lower() != "api.appstoreconnect.apple.com"
            or parts.fragment or not (decoded == "/v1" or decoded.startswith("/v1/"))
            or "\\" in decoded or "%" in decoded or "//" in decoded
            or any(p in (".", "..") for p in decoded.split("/"))
            or any(ord(c) < 32 or ord(c) == 127 for c in decoded)):
        raise ValueError("ASC requests and pagination must stay on HTTPS api.appstoreconnect.apple.com/v1")
    if params:
        query = parts.query
        extra = urllib.parse.urlencode(params, doseq=True)
        url = urllib.parse.urlunsplit(parts._replace(query=query + ("&" if query else "") + extra))
    return url


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, credentials):
        credentials.validate()
        self.credentials = credentials
        self._opener = urllib.request.build_opener(_NoRedirect())

    def request(self, method, path, body=None, params=None):
        url = _safe_url(path, params)
        method = method.upper()
        if method not in {"GET", "POST", "PATCH", "DELETE"}:
            raise ValueError("Unsupported ASC HTTP method")
        payload = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
        for attempt in range(MAX_GET_RETRIES + 1):
            request = urllib.request.Request(url, data=payload, method=method, headers={
                "Authorization": "Bearer " + make_token(self.credentials),
                "Accept": "application/json", "Content-Type": "application/json",
            })
            retry_after = None
            try:
                with self._opener.open(request, timeout=TIMEOUT) as response:
                    if response.status == 204:
                        return {}
                    data = response.read(16 * 1024 * 1024 + 1)
                    if len(data) > 16 * 1024 * 1024:
                        raise _local_error("INVALID_RESPONSE", response.status)
                    try:
                        decoded = json.loads(data)
                    except (ValueError, UnicodeError):
                        raise _local_error("INVALID_RESPONSE", response.status) from None
                    if not isinstance(decoded, dict):
                        raise _local_error("INVALID_RESPONSE", response.status)
                    return decoded
            except urllib.error.HTTPError as error:
                status = error.code
                retry_after = error.headers.get("Retry-After") if error.headers else None
                try:
                    try:
                        decoded = json.loads(error.read(65536))
                    except (ValueError, OSError, http.client.HTTPException):
                        decoded = {}
                finally:
                    error.close()
                failure = ApiError(status, decoded.get("errors") if isinstance(decoded, dict) else None)
                retryable = status == 429 or 500 <= status <= 599
            except (urllib.error.URLError, OSError, http.client.HTTPException):
                failure = _local_error("NETWORK_ERROR")
                retryable = True
            if method != "GET" or not retryable or attempt >= MAX_GET_RETRIES:
                raise failure from None
            delay = min(10, 0.5 * 2 ** attempt)
            if retry_after:
                try:
                    delay = min(10, max(delay, float(retry_after)))
                except (ValueError, TypeError):
                    pass
            time.sleep(delay)
        raise AssertionError("Unreachable retry state")

    def items(self, path, params=None):
        result = []
        url = _safe_url(path, params)
        visited = set()
        while url:
            if url in visited:
                raise _local_error("PAGINATION_ERROR")
            visited.add(url)
            page = self.request("GET", url)
            data = page.get("data")
            links = page.get("links", {})
            if not isinstance(data, list) or not isinstance(links, dict):
                raise _local_error("PAGINATION_ERROR")
            result.extend(data)
            next_page = links.get("next")
            url = _safe_url(next_page) if next_page else None
        return result
