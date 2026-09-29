#!/usr/bin/env python3
"""Download the publicly shared GLory Drive folder without account credentials.

Folder HTML is not a supported Google API. Fail on inconsistent listings, and
redownload files when precise remote metadata is unavailable. Different content
may replace a local file only when a trusted remote mtime is strictly newer.
Unknown/equal/older remote times and edits during sync preserve the local file.
Local-only files are kept. --force verifies content; it never bypasses protection.
"""
from __future__ import annotations

import argparse
import concurrent.futures as futures
import datetime as dt
from decimal import Decimal
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import threading
import tempfile
import time
import unicodedata
import urllib.parse

import requests
from bs4 import BeautifulSoup

ROOT = Path(__file__).resolve().parents[3]
FOLDER_ID = "19WnebPCTVXxxjY6pfJjsrAVyVJ0P9mXl"
FOLDER_MIME = "application/vnd.google-apps.folder"
RESOURCE_NAMES = {"assets", "assets.bundle.json", "assets.manifest.json"}
LOCAL = threading.local()
PRESERVE_REASONS = {
    "remote_mtime_unknown": "云端修改时间未知",
    "local_mtime_unknown": "本地内容的历史修改时间未知",
    "remote_older": "本地修改时间较新",
    "same_mtime": "双方修改时间相同但内容不同",
    "local_changed_during_download": "下载期间本地发生变化",
    "local_changed_during_backup": "备份期间本地发生变化",
    "local_changed_before_replace": "替换前本地发生变化",
}


def remote_mtime_ns(item):
    """Only Drive's precise two-timestamp metadata establishes remote age."""
    version = item.get("version")
    if not isinstance(version, list) or len(version) != 2:
        return None
    if not all(isinstance(value, (int, float)) and not isinstance(value, bool)
               and 0 < value < 2 ** 63 / 1_000_000 and math.isfinite(value) for value in version):
        return None
    # Decimal avoids float rounding making equal millisecond timestamps newer.
    return int(Decimal(str(version[1])) * 1_000_000)


def session():
    if not hasattr(LOCAL, "session"):
        LOCAL.session = requests.Session()
        LOCAL.session.headers["User-Agent"] = "Mozilla/5.0 GLoryResourceSync/1.0"
    return LOCAL.session


def get(url, **kwargs):
    for attempt in range(4):
        try:
            r = session().get(url, timeout=(20, 90), **kwargs)
            r.raise_for_status()
            return r
        except requests.RequestException:
            if attempt == 3:
                raise
            time.sleep(2 ** attempt)


def safe_name(name):
    if (not name or name in {".", ".."} or "/" in name or "\\" in name
            or any(ord(c) < 32 for c in name)):
        raise ValueError(f"云端文件名不安全，停止：{name!r}")
    return name


def local_path(root, relative):
    rel = Path(relative)
    if rel.is_absolute() or not rel.parts:
        raise ValueError(f"不安全的相对路径：{relative}")
    cursor = root
    if root.is_symlink():
        raise ValueError(f"目标目录不能是符号链接：{root}")
    for part in rel.parts:
        safe_name(part)
        cursor = cursor / part
        if cursor.is_symlink():
            raise ValueError(f"拒绝跟随符号链接：{cursor}")
    if not cursor.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"路径超出目标目录：{relative}")
    return cursor


def parse_metadata(html):
    m = re.search(r"window\['_DRIVE_ivd'\]\s*=\s*'((?:[^'\\]|\\.)*)';", html)
    if not m:
        raise ValueError("Drive 元数据页面格式已变更，或文件夹需要登录。")
    escaped = re.sub(r"\\x([0-9a-fA-F]{2})", lambda x: "\\u00" + x[1], m[1])
    data = json.loads(json.loads('"' + escaped.replace("\\'", "'") + '"'))
    if not isinstance(data, list) or not data or data[0] is None:
        return {}
    result = {}
    for row in data[0]:
        if not isinstance(row, list) or len(row) < 14:
            raise ValueError("Drive 元数据字段异常。")
        version = [row[9], row[10]]
        if remote_mtime_ns({"version": version}) is None:
            version = None
        result[row[0]] = dict(id=row[0], name=row[2], mime=row[3],
                              version=version, size=row[13])
    return result


def parse_embedded(html):
    soup = BeautifulSoup(html, "html.parser")
    if not soup.title or soup.select_one('form[action*="accounts.google"]'):
        raise ValueError("无法读取公开文件夹；请检查链接权限。")
    children = {}
    for entry in soup.select(".flip-entry"):
        link = entry.select_one(".flip-entry-info a[href]")
        title = entry.select_one(".flip-entry-title")
        if not link or not title:
            raise ValueError("Drive 文件夹列表格式异常。")
        url = urllib.parse.urlparse(link["href"])
        match = re.fullmatch(r"/(?:drive/(?:u/\d+/)?folders|file/d)/([-\w]+)(?:/view)?", url.path)
        if url.hostname != "drive.google.com" or not match:
            raise ValueError(f"暂不支持此云端文档或快捷方式：{title.get_text()}")
        fid = match[1]
        if fid in children:
            raise ValueError(f"Drive 列表中出现重复 ID：{fid}")
        children[fid] = dict(id=fid, name=safe_name(title.get_text()),
                            mime=FOLDER_MIME if "/folders/" in url.path else "application/octet-stream",
                            version=None, size=None)
    if not children and not soup.select_one(".flip-entries"):
        raise ValueError("Drive 没有返回有效的目录列表，拒绝视为空目录。")
    return children


def _read_folder_once(folder_id):
    children = parse_embedded(get(f"https://drive.google.com/embeddedfolderview?id={folder_id}").text)
    metadata = parse_metadata(get(f"https://drive.google.com/drive/folders/{folder_id}").text)
    if not set(metadata).issubset(children):
        raise ValueError("两种 Drive 列表不一致；云端可能正在更新，请稍后重试。")
    # The standard page only includes 50 entries. The embedded page enumerates
    # the rest; a second stable listing protects against transient truncation.
    if len(children) >= 50:
        again = parse_embedded(get(f"https://drive.google.com/embeddedfolderview?id={folder_id}").text)
        if children != again:
            raise ValueError("Drive 目录在扫描期间变化，请重试。")
    for fid, child in children.items():
        if fid in metadata:
            if child["name"] != metadata[fid]["name"]:
                raise ValueError("Drive 文件名在扫描期间变化，请重试。")
            child.update(metadata[fid])
        safe_name(child["name"])
    return children


def read_folder(folder_id):
    # Drive occasionally serves an incomplete page or changes a listing between
    # requests. Retry the entire validation, never accept a partial inventory.
    for attempt in range(3):
        try:
            return _read_folder_once(folder_id)
        except ValueError:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def list_folder(folder_id):
    children = read_folder(folder_id)
    groups = {}
    for child in children.values():
        key = unicodedata.normalize("NFC", child["name"]).casefold()
        groups.setdefault(key, []).append(child)
    selected, resolutions = [], []
    for items in groups.values():
        if len(items) == 1:
            selected.append(items[0])
            continue
        if len({item["name"] for item in items}) != 1:
            raise ValueError("大小写或 Unicode 文件名冲突，无法自动选择：" + items[0]["name"])
        if any(item["mime"] == FOLDER_MIME for item in items):
            raise ValueError("同名文件夹需要人工合并：" + items[0]["name"])
        candidates = []
        with tempfile.TemporaryDirectory(prefix="glory-duplicate-") as directory:
            for index, item in enumerate(sorted(items, key=lambda value: value["id"])):
                record = download(item, Path(directory) / str(index))
                candidates.append(record)
        identical = len({item["sha256"] for item in candidates}) == 1
        times = [remote_mtime_ns(item) for item in candidates]
        if identical:
            # Stable tie-break independent of Drive listing order.
            chosen = max(candidates, key=lambda item: (remote_mtime_ns(item) or 0, item["id"]))
            reason = "identical_sha256"
        elif all(value is not None for value in times) and times.count(max(times)) == 1:
            chosen = max(candidates, key=remote_mtime_ns)
            reason = "strictly_newer_drive_modified_time"
        else:
            raise ValueError("同名文件内容不同且无法确认唯一最新版本："
                             + items[0]["name"])
        resolution = dict(folder_id=folder_id, name=chosen["name"], reason=reason,
                          selected_id=chosen["id"], selected_sha256=chosen["sha256"],
                          candidates=candidates)
        selected.append(dict(children[chosen["id"]], duplicate_resolution=resolution,
                             expected_sha256=chosen["sha256"]))
        resolutions.append(resolution)
    if resolutions:
        if read_folder(folder_id) != children:
            raise ValueError("同名文件核验期间云端目录发生变化，请重试。")
        for resolution in resolutions:
            print("同名资源已核验：" + resolution["name"] + "（" + resolution["reason"] + "）", flush=True)
    return selected


def scan(folder_id, all_files, workers):
    files, directories, visited = {}, [], {folder_id}
    with futures.ThreadPoolExecutor(max_workers=workers) as pool:
        pending = {pool.submit(list_folder, folder_id): ""}
        while pending:
            done, _ = futures.wait(pending, return_when=futures.FIRST_COMPLETED)
            for job in done:
                parent = pending.pop(job)
                for item in job.result():
                    if not parent and not all_files and item["name"] not in RESOURCE_NAMES:
                        continue
                    relative = (Path(parent) / item["name"]).as_posix()
                    if item["mime"] == FOLDER_MIME:
                        if item["id"] in visited:
                            raise ValueError(f"检测到循环/重复文件夹：{relative}")
                        visited.add(item["id"])
                        directories.append(relative)
                        pending[pool.submit(list_folder, item["id"])] = relative
                    else:
                        files[relative] = item
                print(f"扫描 {parent or '/'}：累计 {len(files)} 文件，{len(visited)} 目录", flush=True)
    if not files or (not all_files and "assets" not in directories):
        raise ValueError("没有找到 assets 资源目录，停止同步。")
    return files, directories


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(4 * 1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest()


def local_snapshot(target):
    """Content plus identity/timestamps; an unstable read can never be replaced."""
    try:
        before = target.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(before.st_mode):
        raise ValueError(f"目标不是普通文件，保留本地：{target}")

    def attributes(info):
        return dict(device=info.st_dev, inode=info.st_ino, size=info.st_size,
                    mtime_ns=info.st_mtime_ns, ctime_ns=info.st_ctime_ns, mode=info.st_mode)

    try:
        sha = digest(target)
        after = target.lstat()
    except FileNotFoundError:
        return dict(attributes(before), stable=False, sha256=None)
    stable = attributes(before) == attributes(after) and stat.S_ISREG(after.st_mode)
    return dict(attributes(after), stable=stable, sha256=sha if stable else None)


def unchanged_local(before, after):
    return before == after and (before is None or before["stable"])


def local_content_time(snapshot, previous):
    """Use content provenance rather than incidental download/copy/touch times."""
    if not snapshot or not snapshot["stable"]:
        return None, "local_time_unknown"
    if isinstance(previous, dict):
        if previous.get("applied") is False or previous.get("sync_status") == "local_preserved":
            local = previous.get("local_copy", {})
            if isinstance(local, dict) and local.get("sha256") == snapshot["sha256"]:
                timestamp = local.get("modified_time_ns")
                valid = isinstance(timestamp, int) and not isinstance(timestamp, bool) and timestamp > 0
                return (timestamp if valid else None), "preserved_local_time"
        elif previous.get("sha256") == snapshot["sha256"]:
            return remote_mtime_ns(previous), "previous_cloud_time"
    return snapshot["mtime_ns"], "local_mtime"


def completed_record(record, kind):
    result = dict(record, sync_status=kind, applied=True, last_synced_sha256=record["sha256"])
    result.pop("local_preserved", None)
    result.pop("local_copy", None)
    return result


def preserve_local(relative, record, previous, snapshot, remote_ns, reason, temp, state_dir, run_id):
    # sha256 remains the verified *cloud* hash; never label local edits as synced.
    last_synced = (previous or {}).get("last_synced_sha256")
    if (last_synced is None and previous and previous.get("sync_status") != "local_preserved"
            and previous.get("applied") is not False):
        last_synced = previous.get("sha256")
    local_sha = snapshot.get("sha256") if snapshot else None
    local_ns, time_source = local_content_time(snapshot, previous)
    cloud_copy = local_path(state_dir, "conflicts/" + run_id + "/" + relative)
    cloud_copy.parent.mkdir(parents=True, exist_ok=True)
    os.replace(temp, cloud_copy)
    detail = dict(path=relative, reason=reason, local_sha256=local_sha,
                  local_mtime_ns=snapshot.get("mtime_ns") if snapshot else None,
                  local_content_mtime_ns=local_ns, local_time_source=time_source,
                  remote_mtime_ns=remote_ns,
                  cloud_copy=str(cloud_copy),
                  local_changed_since_sync=(local_sha != last_synced) if local_sha and last_synced else None)
    result = dict(record, sync_status="local_preserved", applied=False, local_preserved=detail,
                  local_copy=dict(sha256=local_sha, modified_time_ns=local_ns))
    if last_synced:
        result["last_synced_sha256"] = last_synced
    return "local_preserved", result


def write_json(path, value):
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError(f"拒绝写入符号链接：{path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    temp = Path(name)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def download(item, temp):
    url = "https://drive.usercontent.google.com/download?" + urllib.parse.urlencode(
        {"id": item["id"], "export": "download", "confirm": "t"})
    for attempt in range(4):
        try:
            with get(url, stream=True) as r:
                if "attachment" not in r.headers.get("Content-Disposition", "").lower():
                    raise ValueError("Drive 未返回下载附件（可能限流或文件无下载权限）")
                sha, size = hashlib.sha256(), 0
                with temp.open("wb") as f:
                    for block in r.iter_content(1024 * 1024):
                        f.write(block)
                        sha.update(block)
                        size += len(block)
                    f.flush()
                    os.fsync(f.fileno())
                expected = item.get("size")
                if expected is not None and size != int(expected):
                    raise ValueError(f"大小不符：期待 {expected}，实际 {size}")
                header_size = r.headers.get("Content-Length")
                if header_size and not r.headers.get("Content-Encoding") and size != int(header_size):
                    raise ValueError("下载内容未达到 Content-Length")
                actual_sha = sha.hexdigest()
                if item.get("expected_sha256") and actual_sha != item["expected_sha256"]:
                    raise ValueError("同名资源在核验后发生内容变化，拒绝替换。")
                return dict(item, sha256=actual_sha, downloaded_size=size)
        except (requests.RequestException, ValueError):
            if attempt == 3:
                raise
            time.sleep(2 ** attempt)


def sync_one(relative, item, previous, dest, state_dir, run_id, force):
    target = local_path(dest, relative)
    initial = local_snapshot(target)
    remote_ns = remote_mtime_ns(item)
    same = (previous and previous.get("id") == item["id"] and remote_ns is not None
            and previous.get("version") == item["version"] and previous.get("size") == item.get("size"))
    if (not force and not item.get("duplicate_resolution") and same and initial and initial["stable"]
            and previous.get("sync_status") != "local_preserved"
            and previous.get("applied") is not False
            and initial["size"] == previous.get("downloaded_size")
            and initial["sha256"] == previous.get("sha256")):
        return "skipped", completed_record(previous, "skipped")
    temp = local_path(state_dir, "partial/" + hashlib.sha256(relative.encode()).hexdigest() + ".part")
    record = download(item, temp)
    target.parent.mkdir(parents=True, exist_ok=True)
    current = local_snapshot(local_path(dest, relative))
    if not unchanged_local(initial, current):
        return preserve_local(relative, record, previous, current, remote_ns,
                              "local_changed_during_download", temp, state_dir, run_id)
    if current:
        if current["sha256"] == record["sha256"]:
            temp.unlink()
            return "checked", completed_record(record, "checked")
        local_ns, _ = local_content_time(current, previous)
        reason = ("remote_mtime_unknown" if remote_ns is None else
                  "local_mtime_unknown" if local_ns is None else
                  "same_mtime" if remote_ns == local_ns else
                  "remote_older" if remote_ns < local_ns else None)
        if reason:
            return preserve_local(relative, record, previous, current, remote_ns, reason, temp, state_dir, run_id)
        backup = local_path(state_dir, "backups/" + run_id + "/" + relative)
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(target, backup)
        after_backup = local_snapshot(local_path(dest, relative))
        if not unchanged_local(current, after_backup):
            return preserve_local(relative, record, previous, after_backup, remote_ns,
                                  "local_changed_during_backup", temp, state_dir, run_id)
    # Set the incoming file's timestamp before replacement, so a later local edit
    # cannot have its timestamp reset by this process after os.replace().
    if remote_ns is not None:
        os.utime(temp, ns=(remote_ns, remote_ns))
    final = local_snapshot(local_path(dest, relative))
    if not unchanged_local(current, final):
        return preserve_local(relative, record, previous, final, remote_ns,
                              "local_changed_before_replace", temp, state_dir, run_id)
    os.replace(temp, target)
    return "downloaded", completed_record(record, "downloaded")


def main():
    p = argparse.ArgumentParser(description="同步公开 Drive 资源到 GLory/res；只下载，不修改云端。")
    p.add_argument("--all", action="store_true", help="下载整个云端文件夹，包含代码、.git、缓存和历史备份")
    p.add_argument("--dry-run", action="store_true", help="扫描远端，不下载资源")
    p.add_argument("--force", action="store_true", help="重新下载全部文件进行内容检查")
    p.add_argument("--workers", type=int, default=6, choices=range(1, 17), metavar="1-16")
    args = p.parse_args()
    dest, state_dir = ROOT / "res", ROOT / ".glory-sync"
    if dest.is_symlink() or state_dir.is_symlink():
        raise ValueError("res 或 .glory-sync 不能是符号链接")
    state_dir.mkdir(exist_ok=True)
    run_id = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    with local_path(state_dir, "sync.lock").open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("另一个同步或资源快照正在运行，请稍后重试。")
        print("云端→本地：" + str(dest), flush=True)
        print("范围：" + ("完整云端目录" if args.all else "assets/ + 两份资源清单"), flush=True)
        print("覆盖规则：仅可信云端时间严格较新时替换；本地较新、同时间、时间未知和同步期间编辑均保留。--force 也遵循此规则。", flush=True)
        print("内容与已同步记录一致时沿用其修改时间；本地内容有改动才使用本地文件修改时间，避免下载/复制/touch 改变版本优先级。", flush=True)
        files, directories = scan(FOLDER_ID, args.all, args.workers)
        inventory = dict(folder_id=FOLDER_ID, scope="all" if args.all else "resources", scanned_at=run_id,
                         files=files, directories=directories)
        write_json(state_dir / "remote-inventory.json", inventory)
        known_bytes = sum(int(x["size"] or 0) for x in files.values())
        uncertain = sum(remote_mtime_ns(x) is None for x in files.values())
        print(f"扫描完成：{len(files)} 文件，已知大小 {known_bytes / 1e9:.2f} GB；{uncertain} 个无精确元数据的文件将重新下载检查。", flush=True)
        if args.dry_run:
            return
        dest.mkdir(exist_ok=True)
        local_path(state_dir, "partial").mkdir(exist_ok=True)
        for relative in directories:
            local_path(dest, relative).mkdir(parents=True, exist_ok=True)
        state_file = state_dir / "state.json"
        old = json.loads(state_file.read_text()) if state_file.exists() else {"folder_id": FOLDER_ID, "files": {}}
        if old.get("folder_id") != FOLDER_ID:
            raise ValueError("同步状态的云端文件夹不匹配。")
        records = old["files"].copy()
        counts, errors = {"downloaded": 0, "checked": 0, "skipped": 0, "local_preserved": 0}, []
        preserved = []
        write_json(state_dir / "last-run.json", dict(status="running", started_at=run_id,
                                                    counts=counts, local_preserved=preserved))
        with futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
            jobs = {pool.submit(sync_one, path, item, records.get(path), dest, state_dir, run_id, args.force): path
                    for path, item in files.items()}
            for index, job in enumerate(futures.as_completed(jobs), 1):
                relative = jobs[job]
                try:
                    kind, record = job.result()
                    records[relative] = record
                    counts[kind] += 1
                    suffix = ""
                    if kind == "local_preserved":
                        detail = record["local_preserved"]
                        preserved.append(detail)
                        suffix = "（" + PRESERVE_REASONS[detail["reason"]] + "）"
                    print(f"[{index}/{len(files)}] {kind}: {relative}{suffix}", flush=True)
                except Exception as e:
                    errors.append(dict(path=relative, error=str(e)))
                    print(f"失败：{relative}: {e}", file=sys.stderr, flush=True)
                # Checkpoint successful files so an interrupted run can resume.
                if index % 10 == 0 or index == len(files):
                    write_json(state_file, dict(folder_id=FOLDER_ID, files=records, last_run_id=run_id,
                                                counts=counts, local_preserved=preserved))
                    write_json(state_dir / "last-run.json", dict(status="running", started_at=run_id,
                                                                counts=counts, local_preserved=preserved, errors=errors))
        local_only = sorted(set(records) - set(files))
        result = dict(status="failed" if errors else "success", started_at=run_id,
                      finished_at=dt.datetime.now().isoformat(), scope=inventory["scope"],
                      remote_files=len(files), counts=counts, errors=errors,
                      local_preserved=preserved,
                      local_only_kept=local_only, backup_directory=str(state_dir / "backups" / run_id))
        write_json(state_dir / "last-run.json", result)
        print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
        if errors:
            raise ValueError(f"{len(errors)} 个文件失败；已完成的保留，重跑相同命令即可继续。")
        print("同步完成。云端已删除/移走的文件和本地自行添加的文件保留，旧版本备份在 .glory-sync/backups。", flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("同步已中断；再次运行相同命令即可继续。", file=sys.stderr)
        sys.exit(130)
    except Exception as error:
        print(f"同步失败：{error}", file=sys.stderr)
        sys.exit(1)
