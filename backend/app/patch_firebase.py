"""Firebase Hosting REST publisher, with bounded-memory upload and CDN readback.

Use a dedicated patch Hosting site. Each deployment supplies the COMPLETE retained
file inventory: Hosting replaces a release, it does not append files to a bucket.
Credentials are provided by the calling service, never stored in release metadata.
"""
from __future__ import annotations

import gzip
import hashlib
from pathlib import Path, PurePosixPath
import re
import tempfile

import httpx


class FirebasePublishError(RuntimeError):
    pass


def digest_file(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


class FirebaseHosting:
    API = "https://firebasehosting.googleapis.com/v1beta1/"

    def __init__(self, site_id: str, *, client: httpx.Client | None = None):
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,28}[a-z0-9]", site_id):
            raise ValueError("invalid Firebase site ID")
        self.site_id = site_id
        self.client = client

    def publish_inventory(self, files: dict[str, Path], access_token: str) -> dict:
        if not files:
            raise ValueError("refuse an empty deployment")
        if not access_token or "\n" in access_token or "\r" in access_token:
            raise ValueError("invalid access token")
        for name, path in files.items():
            parts = PurePosixPath(name).parts
            if (not name.startswith("/patches/") or ".." in parts or "\\" in name
                    or "?" in name or "#" in name or "%" in name
                    or any(ord(c) < 32 for c in name) or not Path(path).is_file()
                    or Path(path).is_symlink()):
                raise ValueError("invalid patch inventory entry")
            if not 0 < Path(path).stat().st_size <= 2_000_000_000:
                raise ValueError("Firebase individual file size exceeded")
        # Hard guard for the requested free trial; no automatic plan upgrade.
        if sum(Path(p).stat().st_size for p in files.values()) > 9_000_000_000:
            raise ValueError("inventory exceeds 9 GB safety limit; prune retained patches first")
        if self.client is not None:
            return self._publish(files, access_token, self.client)
        with httpx.Client(timeout=httpx.Timeout(180, connect=20), follow_redirects=False) as client:
            return self._publish(files, access_token, client)

    def _publish(self, files, access_token, client):
        authorization = {"Authorization": "Bearer " + access_token}

        def api(method, suffix, **kwargs):
            response = client.request(method, self.API + suffix, headers=authorization, **kwargs)
            if not response.is_success:
                # Avoid propagating credentials, provider request bodies or upload URLs.
                raise FirebasePublishError(f"Firebase {method} failed: HTTP {response.status_code}")
            return response.json()

        with tempfile.TemporaryDirectory(prefix="glory-firebase-") as directory:
            compressed, file_hashes, original = {}, {}, {}
            for index, (name, path) in enumerate(sorted(files.items())):
                dest = Path(directory) / str(index)
                raw_hash = hashlib.sha256()
                size = 0
                with Path(path).open("rb") as src, dest.open("wb") as raw:
                    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
                        for chunk in iter(lambda: src.read(1024 * 1024), b""):
                            size += len(chunk)
                            raw_hash.update(chunk)
                            gz.write(chunk)
                checksum = raw_hash.hexdigest()
                if checksum not in PurePosixPath(name).parts:
                    raise ValueError("immutable path does not match file bytes")
                compressed_hash = digest_file(dest)
                compressed[compressed_hash] = dest
                file_hashes[name] = compressed_hash
                original[name] = {"sha256": checksum, "size": size,
                                  "url": f"https://{self.site_id}.web.app{name}"}

            version = api("POST", f"sites/{self.site_id}/versions", json={"config": {
                "headers": [{"glob": "/patches/**", "headers": {
                    "Cache-Control": "public,max-age=31536000,immutable",
                    "X-Content-Type-Options": "nosniff"}}]}})
            version_name = version.get("name", "")
            if not re.fullmatch(r"sites/" + re.escape(self.site_id) + r"/versions/[A-Za-z0-9_-]+", version_name):
                raise FirebasePublishError("unexpected Firebase version identity")
            names = list(file_hashes)
            for offset in range(0, len(names), 1000):
                populated = api("POST", version_name + ":populateFiles", json={"files": {
                    name: file_hashes[name] for name in names[offset:offset + 1000]}})
                upload_url = populated.get("uploadUrl", "")
                required_hashes = populated.get("uploadRequiredHashes") or []
                expected = "https://upload-firebasehosting.googleapis.com/upload/" + version_name + "/files"
                if required_hashes and upload_url != expected:
                    raise FirebasePublishError("unexpected Firebase upload destination")
                for checksum in required_hashes:
                    if checksum not in compressed:
                        raise FirebasePublishError("Firebase requested an unknown content hash")
                    with compressed[checksum].open("rb") as stream:
                        response = client.post(upload_url + "/" + checksum,
                            headers={**authorization, "Content-Type": "application/octet-stream"},
                            content=iter(lambda: stream.read(1024 * 1024), b""))
                    if not response.is_success:
                        raise FirebasePublishError(f"Firebase upload failed: HTTP {response.status_code}")
            final = api("PATCH", version_name, params={"update_mask": "status"}, json={"status": "FINALIZED"})
            if final.get("status") != "FINALIZED":
                raise FirebasePublishError("Firebase did not finalize the version")
            released = api("POST", f"sites/{self.site_id}/releases", params={"versionName": version_name}, json={})
            if released.get("version", {}).get("name") != version_name:
                raise FirebasePublishError("Firebase release not confirmed; inspect remote state before retry")
            # Verify EVERY retained URL. A successful upload alone does not prove
            # the currently served release still contains old base/rollback packs.
            for name, item in original.items():
                checksum = hashlib.sha256()
                size = 0
                with client.stream("GET", item["url"], headers={"Accept-Encoding": "identity"}) as response:
                    if response.status_code != 200:
                        raise FirebasePublishError("CDN readback failed; catalogue must remain unpublished")
                    for chunk in response.iter_bytes():
                        size += len(chunk)
                        if size > item["size"]:
                            raise FirebasePublishError("CDN readback exceeds expected size")
                        checksum.update(chunk)
                if size != item["size"] or checksum.hexdigest() != item["sha256"]:
                    raise FirebasePublishError("CDN checksum mismatch; catalogue must remain unpublished")
            return {"version": version_name, "files": original}
