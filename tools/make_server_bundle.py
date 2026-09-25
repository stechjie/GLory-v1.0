#!/usr/bin/env python3
"""Build a source-only dedicated server ZIP with an attributable cold-start smoke.

Python 3.10+, Git and the matching Godot console binary are required. Example:
  python tools/make_server_bundle.py --godot /path/to/godot --out-dir /tmp/bundles

Only the smoke copy receives disposable TLS credentials and a unique user directory.
The ZIP retains production application/user-directory settings and the production
public TLS pin. No production credentials or user data are read. macOS smoke uses
sandbox-exec; Linux uses a private network namespace. Other hosts can provide a
network-isolation command prefix as a JSON array, or build an explicitly UNVERIFIED
artifact with --skip-smoke. No deployment, service restart, or Git mutation occurs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile

ROOTS = ("scripts", "scenes", "effects", "data", "tools", "ui")
EXTENSIONS = {".gd", ".uid", ".tscn", ".tres", ".gdshader", ".gdshaderinc",
              ".json", ".csv", ".txt", ".cfg", ".py", ".sh", ".ps1", ".bat", ".md", ".java"}
EXCLUDED_PARTS = {".git", ".godot", "__pycache__", "reference_packages", "node_modules",
                  "userdata", "app_userdata", "certs", "credentials", "secrets"}
ERROR_RE = re.compile(r"SCRIPT ERROR|Parse Error|^ERROR:|Failed to instantiate an autoload|"
                      r"Failed to load (?:script|resource)|Failed loading resource", re.M)
PRIVATE_KEY_RE = re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----\r?\n")
ENTRY = "res://scenes/server/ServerMain.tscn"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(command, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, **kwargs)


def selected_files(source: Path) -> dict[str, bytes]:
    files = {"project.godot": (source / "project.godot").read_bytes()}
    for directory in ROOTS:
        base = source / directory
        if not base.is_dir():
            raise ValueError(f"Missing required source directory: {base}")
        for path in sorted(base.rglob("*")):
            rel = path.relative_to(source)
            if any(part in EXCLUDED_PARTS or part.startswith(".env") for part in rel.parts):
                continue
            if path.is_symlink():
                raise ValueError(f"Symlinks are not allowed in the bundle: {rel}")
            if not path.is_file() or path.suffix.lower() not in EXTENSIONS:
                continue
            if re.search(r"\.(bak|tmp|orig)(?:_|$)|~$", path.name, re.I):
                continue
            if path.name in {"godot_path.txt", "export_credentials.cfg", "export_presets.cfg"}:
                continue
            data = path.read_bytes()
            if PRIVATE_KEY_RE.search(data):
                raise ValueError(f"Private key content is forbidden: {rel}")
            files[rel.as_posix()] = data
    return files


def tree_hash(files: dict[str, bytes]) -> str:
    rows = [{"path": name, "sha256": digest(data), "bytes": len(data)}
            for name, data in sorted(files.items())]
    return digest(json.dumps(rows, ensure_ascii=False, separators=(",", ":")).encode())


def project_setting(text: str, section: str, key: str, value: str | None) -> str:
    pattern = re.compile(r"(?ms)^\[" + re.escape(section) + r"\]\s*\n(.*?)(?=^\[|\Z)")
    match = pattern.search(text)
    if not match:
        raise ValueError(f"project.godot has no [{section}] section")
    body = re.sub(r"(?m)^" + re.escape(key) + r"=.*\n?", "", match[1])
    if value is not None:
        body = f"{key}={value}\n" + body
    return text[:match.start(1)] + body + text[match.end(1):]


def server_project(original: bytes) -> bytes:
    text = original.decode("utf-8-sig")
    text = project_setting(text, "application", "run/main_scene", json.dumps(ENTRY))
    for key in ("boot_splash/image", "config/icon"):
        text = project_setting(text, "application", key, None)
    # The server bundle deliberately does not ship the editor/native voice addon.
    text = project_setting(text, "editor_plugins", "enabled", "PackedStringArray()")
    return text.encode()


def fresh_class_cache(files: dict[str, bytes]) -> tuple[bytes, int]:
    """Generate cache metadata from current source, never a stale imported checkout.

    This repository's named classes extend an identifier, not a script-path or
    expression. Fail closed if that grammar changes rather than inventing a base.
    The actual default-entry Godot smoke then validates the server's parse chain.
    """
    classes = {}
    for path, content in sorted(files.items()):
        if not path.endswith(".gd"):
            continue
        text = content.decode("utf-8-sig")
        found = re.search(r"(?m)^class_name\s+(\w+)\s*(?:#.*)?$", text)
        if not found:
            continue
        name = found[1]
        base = re.search(r"(?m)^extends\s+([\w.]+)\s*(?:#.*)?$", text)
        if not base or name in classes:
            raise ValueError(f"Unsupported/duplicate named class: {name} in {path}")
        icon = re.search(r'(?m)^@icon\("([^"\n]+)"\)', text)
        classes[name] = {"base": base[1], "class": name, "icon": icon[1] if icon else "",
                         "is_abstract": bool(re.search(r"(?m)^@abstract\b", text)),
                         "is_tool": bool(re.search(r"(?m)^@tool\b", text)),
                         "language": "GDScript", "path": "res://" + path}
    entries = []
    for _, fields in sorted(classes.items()):
        lines = []
        for key, value in fields.items():
            prefix = "&" if key in {"base", "class", "language"} else ""
            lines.append(json.dumps(key) + ": " + prefix + json.dumps(value, ensure_ascii=False))
        entries.append("{\n" + ",\n".join(lines) + "\n}")
    return ("list=[" + ", ".join(entries) + "]\n").encode(), len(classes)


def isolation_prefix(port: int, supplied: str | None) -> tuple[list[str], str]:
    if supplied:
        prefix = json.loads(supplied)
        if not isinstance(prefix, list) or not prefix or not all(isinstance(x, str) for x in prefix):
            raise ValueError("--smoke-network-wrapper-json must be a nonempty string array")
        return prefix, "caller-provided network isolation wrapper"
    if sys.platform == "darwin":
        # ENet binds INADDR_ANY; allow only the test port to bind and deny ALL
        # inbound/outbound traffic. Listening is tested, no production route opens.
        policy = f'(version 1)(allow default)(deny network*)(allow network-bind (local ip "*:{port}"))'
        return ["/usr/bin/sandbox-exec", "-p", policy], "all traffic denied; only test-port bind permitted"
    if sys.platform.startswith("linux") and shutil.which("unshare"):
        return ["unshare", "--net", "--"], "private Linux network namespace"
    raise ValueError("No network isolation provider; supply --smoke-network-wrapper-json or --skip-smoke")


SMOKE_KEYS = '''extends SceneTree
func _initialize() -> void:
    var folder := OS.get_cmdline_user_args()[0]
    var expected_user_dir := OS.get_cmdline_user_args()[1]
    if OS.get_user_data_dir().get_file() != expected_user_dir:
        push_error("Smoke user directory is not isolated")
        quit(2)
        return
    var crypto := Crypto.new()
    var key := crypto.generate_rsa(2048)
    if key.save(folder + "/test-private.pem") != OK:
        quit(2)
        return
    var cert := crypto.generate_self_signed_certificate(key, "CN=glory-smoke-only,O=Test", "20200101000000", "20400101000000")
    var cert_script := FileAccess.open("res://scripts/multiplayer/NetTLSCert.gd", FileAccess.WRITE)
    cert_script.store_string("extends RefCounted\\nconst PEM := " + JSON.stringify(cert.save_to_string()) + "\\n")
    cert_script.close()
    var card := FileAccess.open(folder + "/test-public.pem", FileAccess.WRITE)
    card.store_string(key.save_to_string(true))
    card.close()
    print("SMOKE_USER_DIR=" + OS.get_user_data_dir())
    quit(0)
'''


def smoke(zip_path: Path, godot: Path, protocol: int, report_dir: Path,
          wrapper: str | None, seconds: float) -> dict:
    tag = "GloryServerBundleSmoke-" + uuid.uuid4().hex
    user_dir = None
    with tempfile.TemporaryDirectory(prefix="glory-server-smoke-") as temp:
        root = Path(temp)
        project = root / "project"
        with zipfile.ZipFile(zip_path) as archive:
            archive.extractall(project)
        text = (project / "project.godot").read_text()
        text = project_setting(text, "application", "config/use_custom_user_dir", "true")
        text = project_setting(text, "application", "config/custom_user_dir_name", json.dumps(tag))
        (project / "project.godot").write_text(text)
        key_script = root / "smoke_keys.gd"
        key_script.write_text(SMOKE_KEYS)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        prefix, policy = isolation_prefix(port, wrapper)
        key_command = prefix + [str(godot), "--headless", "--path", str(project),
                                "--dedicated-server", "--script", str(key_script), "--", str(root), tag]
        key_result = run(key_command, timeout=45)
        key_log = key_result.stdout.decode(errors="replace")
        (report_dir / "smoke-keygen.log").write_text(key_log)
        found = re.search(r"(?m)^SMOKE_USER_DIR=(.+)$", key_log)
        if found:
            user_dir = Path(found[1].strip())
        if ERROR_RE.search(key_log) or not found or user_dir.name != tag or not (root / "test-private.pem").is_file():
            raise ValueError("Disposable smoke credentials failed; see smoke-keygen.log")
        command = prefix + [str(godot), "--headless", "--path", str(project), "--server",
                            f"--port={port}", "--server-fps=30",
                            f"--tls-key={root / 'test-private.pem'}",
                            f"--battle-card-key={root / 'test-public.pem'}",
                            f"--battle-report-key={root / 'test-private.pem'}"]
        log_path = report_dir / "smoke-startup.log"
        started = time.monotonic()
        try:
            with log_path.open("w") as output:
                process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT)
                # Observe a real continuously-running daemon. An intentional kill
                # ends this bounded startup smoke; this is not graceful-shutdown QA.
                try:
                    while time.monotonic() - started < seconds and process.poll() is None:
                        time.sleep(0.1)
                    alive = process.poll() is None
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.wait(timeout=10)
            log = log_path.read_text(errors="replace")
            errors = [line for line in log.splitlines() if ERROR_RE.search(line)]
            ready = f"server started protocol={protocol} port={port}" in log
            entry_ready = "[SERVER] ServerMain ready (headless, no UI assets required)" in log
            result = {"passed": alive and ready and entry_ready and not errors,
                      "duration_seconds": round(time.monotonic() - started, 3),
                      "default_entry": ENTRY, "scene_argument_passed": False,
                      "engine_errors": errors, "network_isolation": policy,
                      "test_port": port, "server_fps": 30, "dtls": "on; disposable test key and pin",
                      "user_dir_isolated": str(user_dir), "stop": "intentional process kill after startup observation",
                      "graceful_shutdown_tested": False, "log": str(log_path)}
            (report_dir / "smoke.json").write_text(json.dumps(result, indent=2) + "\n")
            if not result["passed"]:
                raise ValueError(f"Default-entry startup smoke failed: {log_path}")
            return result
        finally:
            if user_dir and user_dir.name == tag and user_dir.is_dir():
                shutil.rmtree(user_dir)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--out-dir", type=Path, default=Path(tempfile.gettempdir()) / "glory-server-bundles")
    parser.add_argument("--godot", type=Path)
    parser.add_argument("--skip-smoke", action="store_true")
    parser.add_argument("--smoke-seconds", type=float, default=8.0)
    parser.add_argument("--smoke-network-wrapper-json")
    args = parser.parse_args()
    source = args.source.resolve()
    if not args.skip_smoke and (not args.godot or not args.godot.is_file()):
        parser.error("--godot must name the matching console binary for a verified candidate")
    if args.smoke_seconds < 3:
        parser.error("--smoke-seconds must be at least 3")
    files = selected_files(source)
    source_hash = tree_hash(files)
    git_sha = run(["git", "-C", str(source), "rev-parse", "HEAD"]).stdout.decode().strip()
    git_dirty = bool(run(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=normal"]).stdout)
    match = re.search(rb"NETWORK_PROTOCOL_VERSION\s*:?=\s*(\d+)", files["scripts/multiplayer/NetworkConfig.gd"])
    if not match:
        raise ValueError("Cannot determine network protocol from source")
    protocol = int(match[1])
    godot_version = run([str(args.godot), "--version"], timeout=10).stdout.decode().strip() if args.godot else "unverified"
    original_project = files["project.godot"]
    files["project.godot"] = server_project(original_project)
    cache, class_count = fresh_class_cache(files)
    files[".godot/global_script_class_cache.cfg"] = cache
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    name = f"glory_server_p{protocol}_{stamp}_{git_sha[:12]}_{source_hash[:16]}_{uuid.uuid4().hex[:8]}"
    if args.skip_smoke:
        name += "_UNVERIFIED"
    out_dir = args.out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    report_dir = out_dir / (name + ".evidence")
    report_dir.mkdir()
    manifest = {"schema_version": 1, "built_utc": stamp, "protocol": protocol,
                "git_sha": git_sha, "git_dirty": git_dirty, "source_tree_sha256": source_hash,
                "godot_version": godot_version, "entry_scene": ENTRY,
                "class_cache": {"generated_from_current_source": True, "named_classes": class_count},
                "production_application_settings_preserved": True,
                "project_derivations": ["default ServerMain entry", "remove boot splash image/icon", "disable editor addon"],
                "content_roots": list(ROOTS), "art_assets_included": False,
                "files": [{"path": path, "sha256": digest(data), "bytes": len(data)}
                          for path, data in sorted(files.items())]}
    files["server_bundle_manifest.json"] = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode()
    temp_zip = report_dir / "candidate.pending.zip"
    final_zip = out_dir / (name + ".zip")
    with zipfile.ZipFile(temp_zip, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path, data in sorted(files.items()):
            info = zipfile.ZipInfo(path, (1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data)
    with zipfile.ZipFile(temp_zip) as archive:
        if archive.testzip() is not None or set(archive.namelist()) != set(files):
            raise ValueError("ZIP integrity/member validation failed")
        for row in manifest["files"]:
            if digest(archive.read(row["path"])) != row["sha256"]:
                raise ValueError("ZIP hash mismatch: " + row["path"])
    result = {"passed": False, "skipped": True} if args.skip_smoke else smoke(
        temp_zip, args.godot.resolve(), protocol, report_dir,
        args.smoke_network_wrapper_json, args.smoke_seconds)
    # Never silently publish a mixed snapshot if collaborators edited during capture.
    if source_hash != tree_hash(selected_files(source)):
        raise ValueError("Source changed during build; rerun after source freeze")
    temp_zip.rename(final_zip)
    summary = {"bundle": str(final_zip), "sha256": digest(final_zip.read_bytes()),
               "bytes": final_zip.stat().st_size, "file_count": len(files),
               "source_tree_sha256": source_hash, "git_sha": git_sha, "git_dirty": git_dirty,
               "godot_version": godot_version, "candidate_verified": bool(result["passed"]),
               "smoke": result, "evidence_directory": str(report_dir)}
    (report_dir / "build.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    (out_dir / (name + ".sha256")).write_text(summary["sha256"] + "  " + final_zip.name + "\n")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Server bundle failed: {error}", file=sys.stderr)
        sys.exit(1)
