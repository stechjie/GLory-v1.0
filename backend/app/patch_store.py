"""Transactional patch catalogue; publishing and hotfix invalidation are one commit.

This module does not execute uploaded code or fetch administrator-supplied URLs.
Artifact upload/verification and runtime application belong to separate services.
SQLite lives outside the checkout, on the existing single-worker backend host.
"""
from __future__ import annotations

from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import time
from urllib.parse import urlsplit
import uuid

PLATFORMS = frozenset({"ios", "android", "windows"})
TOKEN = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,95}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")


class PatchConflict(ValueError):
    pass


def token(value: str) -> str:
    if not isinstance(value, str) or not TOKEN.fullmatch(value):
        raise ValueError("invalid version/channel identifier")
    return value


def encoded(value) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


class PatchStore:
    def __init__(self, path: Path, *, firebase_host: str):
        # Exact project hostname, never a wildcard allowing another Firebase tenant.
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*\.(web\.app|firebaseapp\.com)", firebase_host):
            raise ValueError("an exact Firebase Hosting hostname is required")
        self.path = Path(path)
        self.firebase_host = firebase_host
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self._transaction() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS patch_meta (
                    id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL,
                    deployment_id TEXT NOT NULL);
                INSERT OR IGNORE INTO patch_meta VALUES(1,0,'');
                CREATE TABLE IF NOT EXISTS patch_release (
                    release_id TEXT PRIMARY KEY, channel TEXT NOT NULL,
                    seq INTEGER NOT NULL CHECK(seq>0), title TEXT NOT NULL,
                    platforms TEXT NOT NULL, status TEXT NOT NULL,
                    created_at REAL NOT NULL, UNIQUE(channel,seq));
                CREATE TABLE IF NOT EXISTS patch_artifact (
                    release_id TEXT NOT NULL REFERENCES patch_release(release_id),
                    platform TEXT NOT NULL, base_id TEXT NOT NULL,
                    sha256 TEXT NOT NULL, size INTEGER NOT NULL CHECK(size>0),
                    url TEXT NOT NULL, PRIMARY KEY(release_id,platform));
                CREATE TABLE IF NOT EXISTS patch_active (
                    channel TEXT PRIMARY KEY,
                    release_id TEXT NOT NULL REFERENCES patch_release(release_id));
                CREATE TABLE IF NOT EXISTS patch_hotfix (
                    hotfix_id TEXT PRIMARY KEY, channel TEXT NOT NULL,
                    deployment_id TEXT NOT NULL, patch_seq INTEGER NOT NULL,
                    target TEXT NOT NULL, source TEXT NOT NULL, sha256 TEXT NOT NULL,
                    status TEXT NOT NULL, created_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS patch_audit (
                    audit_id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL,
                    actor TEXT NOT NULL, action TEXT NOT NULL, detail TEXT NOT NULL);
            """)

    @contextmanager
    def _transaction(self):
        db = sqlite3.connect(self.path, timeout=15)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        try:
            db.execute("BEGIN IMMEDIATE")
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    @staticmethod
    def _audit(db, actor, action, detail):
        db.execute("INSERT INTO patch_audit(at,actor,action,detail) VALUES(?,?,?,?)",
                   (time.time(), actor, action, encoded(detail)))

    @staticmethod
    def _advance(db):
        db.execute("UPDATE patch_meta SET revision=revision+1 WHERE id=1")

    @classmethod
    def _invalidate(cls, db):
        db.execute("UPDATE patch_hotfix SET status='expired' WHERE status='active'")
        cls._advance(db)

    def activate_deployment(self, deployment_id: str):
        token(deployment_id)
        with self._transaction() as db:
            current = db.execute("SELECT deployment_id FROM patch_meta WHERE id=1").fetchone()[0]
            if current == deployment_id:
                return False
            db.execute("UPDATE patch_meta SET deployment_id=? WHERE id=1", (deployment_id,))
            self._invalidate(db)
            self._audit(db, "deployment", "deploy", {"before": current, "after": deployment_id})
            return True

    def create_release(self, channel: str, title: str, platforms, actor: str) -> str:
        token(channel)
        platforms = sorted(set(platforms))
        if not platforms or not set(platforms) <= PLATFORMS:
            raise ValueError("unsupported platforms")
        if not isinstance(title, str) or not 1 <= len(title.strip()) <= 200:
            raise ValueError("title must contain 1–200 characters")
        release_id = uuid.uuid4().hex
        with self._transaction() as db:
            seq = db.execute("SELECT COALESCE(MAX(seq),0)+1 FROM patch_release WHERE channel=?",
                             (channel,)).fetchone()[0]
            db.execute("INSERT INTO patch_release VALUES(?,?,?,?,?,'draft',?)",
                       (release_id, channel, seq, title, encoded(platforms), time.time()))
            self._audit(db, actor, "create_release", {"release_id": release_id, "seq": seq})
        return release_id

    def record_verified_artifact(self, release_id: str, platform: str, base_id: str,
                                 sha256: str, size: int, url: str, actor: str):
        """Called only by the upload service after remote byte-for-byte verification.

        Never expose this as a 'trust my URL/hash' administrator endpoint.
        Each artifact is cumulative relative to its immutable base_id.
        """
        token(base_id)
        parsed = urlsplit(url)
        if (parsed.scheme != "https" or parsed.hostname != self.firebase_host
                or parsed.username or parsed.password or parsed.port not in (None, 443)
                or parsed.query or parsed.fragment or not parsed.path.startswith("/patches/")):
            raise ValueError("artifact must use the configured Firebase project")
        if not SHA256.fullmatch(sha256) or type(size) is not int or not 0 < size <= 2_000_000_000:
            raise ValueError("invalid artifact digest or size")
        # Content-addressed URLs cannot serve two different releases at one cached URL.
        if sha256 not in parsed.path.split("/"):
            raise ValueError("artifact path must contain its SHA-256 directory")
        with self._transaction() as db:
            release = self._release(db, release_id)
            if release["status"] != "draft":
                raise PatchConflict("published artifacts are immutable")
            if platform not in json.loads(release["platforms"]):
                raise ValueError("platform not declared by release")
            db.execute("INSERT OR REPLACE INTO patch_artifact VALUES(?,?,?,?,?,?)",
                       (release_id, platform, base_id, sha256, size, url))
            self._audit(db, actor, "verify_artifact", {"release_id": release_id,
                        "platform": platform, "sha256": sha256, "size": size})

    @staticmethod
    def _release(db, release_id):
        row = db.execute("SELECT * FROM patch_release WHERE release_id=?", (release_id,)).fetchone()
        if row is None:
            raise ValueError("release not found")
        return row

    def publish(self, release_id: str, actor: str, *, expected_revision: int):
        with self._transaction() as db:
            meta = db.execute("SELECT * FROM patch_meta WHERE id=1").fetchone()
            if not meta["deployment_id"]:
                raise PatchConflict("server deployment identity is not initialized")
            if meta["revision"] != expected_revision:
                raise PatchConflict("catalogue changed; refresh before publishing")
            release = self._release(db, release_id)
            active = db.execute("SELECT release_id FROM patch_active WHERE channel=?",
                                (release["channel"],)).fetchone()
            if active and active[0] == release_id:
                return False  # Retrying publish must not invalidate newer hotfixes.
            artifacts = db.execute("SELECT platform FROM patch_artifact WHERE release_id=?",
                                   (release_id,)).fetchall()
            if {a[0] for a in artifacts} != set(json.loads(release["platforms"])):
                raise PatchConflict("all declared platforms must be uploaded and verified")
            if release["status"] not in ("draft", "published"):
                raise PatchConflict("release cannot be published")
            db.execute("UPDATE patch_release SET status='published' WHERE release_id=?", (release_id,))
            db.execute("INSERT OR REPLACE INTO patch_active VALUES(?,?)", (release["channel"], release_id))
            self._invalidate(db)
            self._audit(db, actor, "publish", {"release_id": release_id,
                        "previous": active[0] if active else None, "hotfixes_expired": True})
            return True

    def add_hotfix(self, channel: str, target: str, source: str, actor: str,
                   *, expected_revision: int) -> str:
        """Commit only AFTER the appropriate runtime has validated/staged the source."""
        token(channel)
        if target not in ("client", "account_server", "battle_server"):
            raise ValueError("unknown hotfix target")
        if not isinstance(source, str) or not 0 < len(source.encode()) <= 128 * 1024:
            raise ValueError("hotfix source must be 1–131072 bytes")
        hotfix_id = uuid.uuid4().hex
        digest = hashlib.sha256(source.encode()).hexdigest()
        with self._transaction() as db:
            meta = db.execute("SELECT * FROM patch_meta WHERE id=1").fetchone()
            if meta["revision"] != expected_revision or not meta["deployment_id"]:
                raise PatchConflict("runtime changed; restage hotfix")
            patch_seq = self._active_seq(db, channel)
            db.execute("INSERT INTO patch_hotfix VALUES(?,?,?,?,?,?,?,'active',?)",
                       (hotfix_id, channel, meta["deployment_id"], patch_seq, target,
                        source, digest, time.time()))
            self._advance(db)
            self._audit(db, actor, "add_hotfix", {"hotfix_id": hotfix_id, "sha256": digest,
                                                "target": target})
        return hotfix_id

    def revoke_hotfix(self, hotfix_id: str, actor: str):
        with self._transaction() as db:
            changed = db.execute("UPDATE patch_hotfix SET status='revoked' "
                                 "WHERE hotfix_id=? AND status='active'", (hotfix_id,)).rowcount
            if changed:
                self._advance(db)
                self._audit(db, actor, "revoke_hotfix", {"hotfix_id": hotfix_id})
            return bool(changed)

    @staticmethod
    def _active_seq(db, channel):
        row = db.execute("SELECT r.seq FROM patch_active a JOIN patch_release r "
                         "ON r.release_id=a.release_id WHERE a.channel=?", (channel,)).fetchone()
        return row[0] if row else 0

    def snapshot(self, channel: str, platform: str, base_id: str, installed_seq: int):
        token(channel)
        token(base_id)
        if platform not in PLATFORMS or type(installed_seq) is not int or installed_seq < 0:
            raise ValueError("invalid client version")
        with self._transaction() as db:
            meta = dict(db.execute("SELECT revision,deployment_id FROM patch_meta WHERE id=1").fetchone())
            row = db.execute("SELECT r.*,a.release_id FROM patch_active a JOIN patch_release r "
                             "ON r.release_id=a.release_id WHERE a.channel=?", (channel,)).fetchone()
            result = {"protocol": 1, **meta, "channel": channel, "platform": platform,
                      "base_id": base_id, "required_patch_seq": row["seq"] if row else 0,
                      "action": "none", "artifact": None, "hotfixes": []}
            if row:
                artifact = db.execute("SELECT platform,base_id,sha256,size,url FROM patch_artifact "
                                      "WHERE release_id=? AND platform=?", (row["release_id"], platform)).fetchone()
                if artifact is None or artifact["base_id"] != base_id:
                    result["action"] = "store_update"
                elif installed_seq != row["seq"]:
                    result["action"] = "download"
                    result["artifact"] = dict(artifact)
            elif installed_seq != 0:
                result["action"] = "reset_to_base"
            if result["action"] == "none":
                fixes = db.execute("SELECT hotfix_id,source,sha256 FROM patch_hotfix WHERE "
                                   "channel=? AND status='active' AND target='client' "
                                   "AND deployment_id=? AND patch_seq=? ORDER BY rowid",
                                   (channel, meta["deployment_id"], result["required_patch_seq"])).fetchall()
                result["hotfixes"] = [dict(f) for f in fixes]
            return result

    def catalogue(self):
        with self._transaction() as db:
            meta = dict(db.execute("SELECT revision,deployment_id FROM patch_meta WHERE id=1").fetchone())
            releases = [dict(r) for r in db.execute("SELECT * FROM patch_release ORDER BY created_at DESC")]
            for release in releases:
                release["platforms"] = json.loads(release["platforms"])
                release["artifacts"] = [dict(a) for a in db.execute(
                    "SELECT * FROM patch_artifact WHERE release_id=?", (release["release_id"],))]
            return {**meta, "releases": releases,
                    "active": dict(db.execute("SELECT channel,release_id FROM patch_active")),
                    "hotfixes": [dict(h) for h in db.execute(
                        "SELECT hotfix_id,channel,deployment_id,patch_seq,target,sha256,created_at "
                        "FROM patch_hotfix WHERE status='active' ORDER BY created_at")]}

    def effective_sources(self, target: str):
        """Internal runtime API. Never serialize server sources in player responses."""
        if target not in ("client", "account_server", "battle_server"):
            raise ValueError("unknown target")
        with self._transaction() as db:
            return [(row["hotfix_id"], row["source"]) for row in db.execute(
                "SELECT hotfix_id,source FROM patch_hotfix WHERE status='active' AND target=? "
                "AND deployment_id=(SELECT deployment_id FROM patch_meta WHERE id=1) "
                "ORDER BY rowid", (target,))]

    def client_pushes(self):
        with self._transaction() as db:
            meta = dict(db.execute("SELECT revision,deployment_id FROM patch_meta WHERE id=1").fetchone())
            channels = [r[0] for r in db.execute("SELECT channel FROM patch_release UNION SELECT channel FROM patch_hotfix")]
            messages = []
            for channel in channels:
                sequence = self._active_seq(db, channel)
                items = [dict(r) for r in db.execute(
                    "SELECT hotfix_id,source,sha256 FROM patch_hotfix WHERE channel=? AND target='client' "
                    "AND status='active' AND deployment_id=? AND patch_seq=? ORDER BY rowid",
                    (channel, meta["deployment_id"], sequence))]
                messages.append({"t": "patch_hotfix_snapshot", "protocol": 1, **meta,
                    "channel": channel, "required_patch_seq": sequence, "hotfixes": items})
            return messages
