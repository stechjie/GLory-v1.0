"""Single-worker patch publication coordinator; filesystem bytes never trust client hashes."""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
import logging
from pathlib import Path, PurePosixPath
import stat
import subprocess
import tempfile
import uuid
import zipfile

import httpx
from starlette.concurrency import run_in_threadpool

from app.patch_firebase import FirebaseHosting, FirebasePublishError
from app.patch_store import PatchConflict, PatchStore, token
from app.patch_runtime import PythonHotfixRuntime
from app.patch_battle_bridge import BattleBridge


def deployment_identity(root: Path, release_tag: str = "") -> str:
    """Hash deployed account-server code/data, so invalidation needs no manual version bump."""
    digest = hashlib.sha256(release_tag.encode())
    files = sorted((root / "backend/app").rglob("*.py"))
    files += sorted(path for path in (root / "data").rglob("*") if path.is_file())
    if not files:
        raise ValueError("Cannot determine the deployed server identity")
    for path in files:
        digest.update(str(path.relative_to(root)).encode())
        digest.update(b"\0")
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        digest.update(b"\0")
    return digest.hexdigest()


def validate_pack(path: Path):
    """Validate overlays without extracting or executing uploaded code."""
    blocked = {".dll", ".exe", ".so", ".dylib", ".a", ".lib", ".gdextension",
               ".aar", ".jar", ".dex", ".wasm", ".p12", ".jks", ".keystore"}
    with zipfile.ZipFile(path) as pack:
        total, seen = 0, set()
        for item in pack.infolist():
            name = item.filename
            parts = name.rstrip("/").split("/")
            if (not name or name.startswith("/") or "\\" in name or ":" in name
                    or any(part in ("", ".", "..") for part in parts)
                    or name in seen or stat.S_ISLNK(item.external_attr >> 16) or item.flag_bits & 1):
                raise ValueError("ZIP contains unsafe, duplicate, linked or encrypted entries")
            seen.add(name)
            if (name in {"project.binary", "project.godot", "override.cfg", ".godot/global_script_class_cache.cfg"}
                    or parts[0] in {"patcher", "backend", ".git"}
                    or any(part.startswith(".env") for part in parts)
                    or PurePosixPath(name).suffix.lower() in blocked
                    or any(part.endswith((".framework", ".xcframework")) for part in parts)):
                raise ValueError("Native libraries, bootstrap and private files require a full build")
            total += item.file_size
            if total > 8_000_000_000 or len(seen) > 100_000:
                raise ValueError("ZIP exceeds resource limits")
        if not seen or not total:
            raise ValueError("Empty patch")
        if pack.testzip() is not None:
            raise ValueError("ZIP integrity check failed")


def metadata_token() -> str:
    # Fixed destination; tokens never enter catalogue, logs or admin responses.
    with httpx.Client(timeout=5, trust_env=False, follow_redirects=False) as client:
        response = client.get(
            "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token",
            headers={"Metadata-Flavor": "Google"})
    if response.status_code != 200 or response.headers.get("Metadata-Flavor") != "Google":
        raise FirebasePublishError("Google VM credentials unavailable")
    value = response.json().get("access_token")
    if not isinstance(value, str) or not value:
        raise FirebasePublishError("Google VM token unavailable")
    return value


class PatchService:
    def __init__(self, directory: Path, site: str, deployment_id: str, *, publisher=None, credentials=None,
                 godot_binary: str = ""):
        self.directory = Path(directory)
        self.blobs = self.directory / "blobs"
        self.blobs.mkdir(parents=True, exist_ok=True)
        self.jobs = self.directory / "jobs"
        self.jobs.mkdir(exist_ok=True)
        self.store = PatchStore(self.directory / "catalogue.sqlite3", firebase_host=site + ".web.app")
        self.store.activate_deployment(deployment_id)
        self.publisher = publisher or FirebaseHosting(site)
        self.credentials = credentials or metadata_token
        self.lock = asyncio.Lock()
        self.runtime = PythonHotfixRuntime()
        self.godot_binary = godot_binary
        self.battle_bridge = None
        self.battle_channel = "stable"
        # A crash can interrupt cloud deployment. Never infer success on restart.
        for file in self.jobs.glob("*.json"):
            data = json.loads(file.read_text())
            if data["status"] == "running":
                data.update(status="interrupted", message="服务器重启；版本尚未确认，请重新上传校验")
                self._job(file.stem, data)

    def _job(self, job_id, data):
        temporary = self.jobs / (job_id + ".tmp")
        temporary.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        os.replace(temporary, self.jobs / (job_id + ".json"))

    def catalogue(self):
        result = self.store.catalogue()
        result["uploads"] = [json.loads(file.read_text()) for file in sorted(self.jobs.glob("*.json"))][-30:]
        result["firebase_host"] = self.store.firebase_host
        result["battle_status"] = self.battle_bridge.latest if self.battle_bridge else None
        return result

    def configure_battle(self, desired, status, instance_id, channel):
        if bool(desired) != bool(status):
            raise ValueError("Both battle desired and status paths are required")
        if desired:
            self.battle_bridge = BattleBridge(Path(desired), Path(status), instance_id)
            self.battle_channel = channel

    async def upload(self, release_id: str, platform: str, base_id: str, stream, actor: str):
        token(base_id)
        release = next((r for r in self.store.catalogue()["releases"] if r["release_id"] == release_id), None)
        if not release or release["status"] != "draft" or platform not in release["platforms"]:
            raise ValueError("Choose a declared platform of an unpublished release")
        if self.lock.locked():
            raise PatchConflict("Another upload or publication is in progress")
        async with self.lock:
            job_id = uuid.uuid4().hex
            job = {"job_id": job_id, "release_id": release_id, "platform": platform,
                   "base_id": base_id, "status": "running", "message": "接收与校验文件"}
            self._job(job_id, job)
            temporary = self.blobs / (job_id + ".part")
            try:
                digest, size = hashlib.sha256(), 0
                with temporary.open("xb") as target:
                    async for chunk in stream:
                        size += len(chunk)
                        if size > 2_000_000_000:
                            raise ValueError("Patch exceeds 2 GB")
                        digest.update(chunk)
                        await run_in_threadpool(target.write, chunk)
                    target.flush()
                    os.fsync(target.fileno())
                await run_in_threadpool(validate_pack, temporary)
                checksum = digest.hexdigest()
                dest = self.blobs / (checksum + ".zip")
                os.replace(temporary, dest)
                inventory = {}
                for old in self.store.catalogue()["releases"]:
                    for artifact in old["artifacts"]:
                        inventory[f'/patches/{artifact["sha256"]}/{artifact["platform"]}.zip'] = self.blobs / (artifact["sha256"] + ".zip")
                remote_path = f"/patches/{checksum}/{platform}.zip"
                inventory[remote_path] = dest
                job["message"] = "上传 Firebase 并校验下载内容"
                self._job(job_id, job)
                # Entire inventory stays serialized through CDN verification and catalogue commit.
                result = await run_in_threadpool(self._upload_inventory, inventory)
                item = result["files"][remote_path]
                self.store.record_verified_artifact(release_id, platform, base_id,
                    checksum, size, item["url"], actor)
                job.update(status="complete", message="Firebase 回读校验通过", sha256=checksum, size=size)
                self._job(job_id, job)
                return job
            except BaseException:
                job.update(status="failed", message="上传未确认成功，未发布；请检查配置或重试")
                self._job(job_id, job)
                raise
            finally:
                temporary.unlink(missing_ok=True)

    def _upload_inventory(self, inventory):
        return self.publisher.publish_inventory(inventory, self.credentials())

    async def publish(self, release_id, actor, revision):
        if self.lock.locked():
            raise PatchConflict("Another upload or publication is in progress")
        async with self.lock:
            catalogue = self.store.catalogue()
            if catalogue["revision"] != revision:
                raise PatchConflict("Catalogue changed; refresh before publishing")
            release = next((r for r in catalogue["releases"] if r["release_id"] == release_id), None)
            if not release:
                raise ValueError("Release not found")
            if {a["platform"] for a in release["artifacts"]} != set(release["platforms"]):
                raise PatchConflict("All declared platforms must be uploaded and verified")
            if release and catalogue["active"].get(release["channel"]) == release_id:
                if self.battle_bridge:
                    self.battle_bridge.write_admission(self)
                return self.store.publish(release_id, actor, expected_revision=revision)
            previous = self.store.effective_sources("account_server")
            self.runtime.clear()
            try:
                changed = self.store.publish(release_id, actor, expected_revision=revision)
            except BaseException:
                self.runtime.replace(previous)
                raise
            # Flush the compact battle admission requirements before returning
            # publish success; Godot reads this on EVERY seat-card admission.
            if self.battle_bridge:
                self.battle_bridge.write_admission(self)
            return changed

    def restore_runtime(self):
        self.runtime.replace(self.store.effective_sources("account_server"))

    async def add_account_hotfix(self, channel, source, actor, revision):
        if self.lock.locked():
            raise PatchConflict("Another update operation is in progress")
        async with self.lock:
            if self.store.catalogue()["revision"] != revision:
                raise PatchConflict("Catalogue changed; refresh before applying hotfix")
            previous = self.store.effective_sources("account_server")
            self.runtime.replace(previous + [("pending", source)])
            try:
                key = self.store.add_hotfix(channel, "account_server", source, actor, expected_revision=revision)
            except BaseException:
                self.runtime.replace(previous)
                raise
            _, prepared, context = self.runtime.active[-1]
            self.runtime.active[-1] = (key, prepared, context)
            return key

    async def revoke_hotfix(self, key, actor):
        if self.lock.locked():
            raise PatchConflict("Another update operation is in progress")
        async with self.lock:
            previous = self.store.effective_sources("account_server")
            self.runtime.replace([(ident, src) for ident, src in previous if ident != key])
            try:
                return self.store.revoke_hotfix(key, actor)
            except BaseException:
                self.runtime.replace(previous)
                raise

    def validate_gdscript(self, source: str):
        if not self.godot_binary or not Path(self.godot_binary).is_file():
            raise ValueError("GDScript validator is not configured on the server")
        if not 0 < len(source.encode()) <= 131072:
            raise ValueError("GDScript hotfix exceeds 128 KB")
        with tempfile.TemporaryDirectory(prefix="glory-hotfix-check-") as folder:
            root = Path(folder)
            (root / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Hotfix validation"\n')
            (root / "hotfix.gd").write_text(source, encoding="utf-8")
            (root / "check.gd").write_text('''extends SceneTree
func _initialize():
 var script = load("res://hotfix.gd")
 if script == null or script.get_instance_base_type() != "RefCounted":
  quit(2)
  return
 for method in script.get_script_method_list():
  if method.name == "apply" and method.args.size() == 1 and method["return"].type == TYPE_BOOL:
   print("GLORY_HOTFIX_VALID")
   quit(0)
   return
 quit(3)
''')
            result = subprocess.run([self.godot_binary, "--headless", "--path", folder,
                "--script", "res://check.gd"], capture_output=True, timeout=15)
            if (result.returncode != 0 or b"GLORY_HOTFIX_VALID" not in result.stdout
                    or b"SCRIPT ERROR" in result.stderr or b"Parse Error" in result.stderr):
                raise ValueError("GDScript must extend RefCounted and define apply(ctx) -> bool; check syntax")

    async def add_client_hotfix(self, channel, source, actor, revision):
        if self.lock.locked():
            raise PatchConflict("Another update operation is in progress")
        async with self.lock:
            catalogue = self.store.catalogue()
            if catalogue["revision"] != revision:
                raise PatchConflict("Catalogue changed; refresh before applying hotfix")
            if sum(h["target"] == "client" and h["channel"] == channel for h in catalogue["hotfixes"]) >= 12:
                raise ValueError("At most 12 client hotfixes can be active per channel")
            try:
                await run_in_threadpool(self.validate_gdscript, source)
            except subprocess.TimeoutExpired:
                raise ValueError("GDScript validation timed out") from None
            return self.store.add_hotfix(channel, "client", source, actor, expected_revision=revision)

    async def add_battle_hotfix(self, channel, source, actor, revision):
        if self.battle_bridge is None or self.battle_bridge.latest is None:
            raise PatchConflict("Battle hotfix agent is not connected")
        if channel != self.battle_channel:
            raise ValueError("Channel differs from this battle server's gameplay channel")
        if self.lock.locked():
            raise PatchConflict("Another update operation is in progress")
        async with self.lock:
            if len(self.store.effective_sources("battle_server")) >= 12:
                raise ValueError("At most 12 battle hotfixes can be active")
            try:
                await run_in_threadpool(self.validate_gdscript, source)
            except subprocess.TimeoutExpired:
                raise ValueError("GDScript validation timed out") from None
            return self.store.add_hotfix(channel, "battle_server", source, actor, expected_revision=revision)


async def battle_loop(service):
    from app import realtime
    log = logging.getLogger("glory.patches")
    failed = False
    while True:
        try:
            if service.battle_bridge and service.battle_bridge.tick(service):
                for payload in service.store.client_pushes():
                    await realtime.hub().broadcast(payload)
            failed = False
        except Exception:
            if not failed:
                log.warning("Battle hotfix bridge unavailable; check configured file ownership and paths")
            failed = True
        await asyncio.sleep(2)


_service: PatchService | None = None


def install(service: PatchService | None):
    global _service
    _service = service


def current() -> PatchService | None:
    return _service
