#!/usr/bin/env python3
"""Repeatable debug APK build; --sync updates Git and Drive before staging."""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[3]
SKIP_DIRS = {".git", ".godot", ".svn", "__pycache__", "__MACOSX"}
SKIP_FILES = {".DS_Store", "Thumbs.db", "desktop.ini"}
ERROR_RE = re.compile(r"(?:^|\n)(?:SCRIPT ERROR:|ERROR:)|Failed to (?:load|import)|Parse Error:")


def note(message):
    print(f"[APK] {message}", flush=True)


def json_write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def capture(args, **kwargs):
    return subprocess.check_output([str(x) for x in args], text=True, stderr=subprocess.STDOUT, **kwargs).strip()


def sync_project(project):
    """Follow the current branch's upstream, without discarding local work."""
    project = project.resolve()
    git = ["git", "-C", project]
    try:
        top = Path(capture(git + ["rev-parse", "--show-toplevel"])).resolve()
        if top != project:
            raise RuntimeError(f"Git 同步必须指定项目仓库根目录：{project}（仓库根目录：{top}）")
        if capture(git + ["status", "--porcelain", "--untracked-files=normal"]):
            raise RuntimeError(f"项目存在未提交改动或未跟踪文件，已停止同步并保留现场：{project}。请先自行提交或整理；仅用本地内容构建可运行 ./tools/build_apk.sh。")
        try:
            branch = capture(git + ["symbolic-ref", "--quiet", "--short", "HEAD"])
            upstream = capture(git + ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
            remote = capture(git + ["config", "--get", f"branch.{branch}.remote"])
        except subprocess.CalledProcessError as error:
            raise RuntimeError("当前分支未设置远端跟踪分支，或处于 detached HEAD；请先切换到有 upstream 的分支再运行 --sync。") from error
        if not remote or remote == ".":
            raise RuntimeError("当前分支没有远端仓库 upstream，无法同步 GitHub 最新内容。")
        before = capture(git + ["rev-parse", "HEAD"])
        note(f"更新 Git 代码和仓库资源：{project}，分支 {branch} → {upstream}")
        subprocess.run([str(v) for v in git + ["fetch", "--no-tags", remote]], check=True)
        ahead, _ = map(int, capture(git + ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"]).split())
        if ahead:
            raise RuntimeError(f"本地分支含 {ahead} 个远端没有的提交，可能领先或已分叉；已停止且未合并、未重置。请先处理分支差异，或不带 --sync 使用本地版本构建。")
        # merge exposes --no-overwrite-ignore, which pull does not forward.
        # Fetch above + a guarded fast-forward also protects ignored local assets.
        subprocess.run([str(v) for v in git + [
            "-c", "merge.autoStash=false", "-c", "rebase.autoStash=false",
            "merge", "--ff-only", "--no-autostash", "--no-overwrite-ignore", "@{upstream}",
        ]], check=True)
        after = capture(git + ["rev-parse", "HEAD"])
        if after != capture(git + ["rev-parse", "@{upstream}"]):
            raise RuntimeError("拉取后本地 HEAD 与 upstream 不一致，已停止打包。")
        if capture(git + ["status", "--porcelain", "--untracked-files=normal"]):
            raise RuntimeError("拉取后工作目录出现未提交改动，已停止打包并保留现场。")
        result = {"branch": branch, "upstream": upstream, "before": before,
                  "after": after, "updated": before != after}
        note(f"Git 已同步：{after[:8]}" + (f"（原 {before[:8]}）" if before != after else "（已是最新）"))
        return result
    except subprocess.CalledProcessError as error:
        # check_output captures useful Git diagnostics; run() already displays them.
        detail = (error.output or "").strip()
        raise RuntimeError("Git 同步失败，已停止，未继续同步 Drive 或构建 APK。" + (f"\n{detail}" if detail else "请查看上方 Git 错误。")) from error


def find_executable(values):
    for value in values:
        if not value:
            continue
        resolved = shutil.which(str(value))
        candidate = Path(resolved or str(value)).expanduser()
        if candidate.is_dir() and candidate.suffix == ".app":
            candidate = candidate / "Contents/MacOS/Godot"
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate.resolve()
    return None


def read_editor_paths():
    configs = [Path.home() / "Library/Application Support/Godot", Path.home() / ".config/godot"]
    settings = {}
    for folder in configs:
        for file in sorted(folder.glob("editor_settings-*.tres"), reverse=True):
            for key in ("java_sdk_path", "android_sdk_path", "debug_keystore"):
                match = re.search(r'^export/android/' + key + r'\s*=\s*"([^"]+)"', file.read_text(), re.M)
                if match and key not in settings:
                    settings[key] = match[1]
    return settings


def first_dir(values, needed):
    for value in values:
        if value and (Path(value).expanduser() / needed).exists():
            return Path(value).expanduser().resolve()
    return None


def environment(args):
    settings = read_editor_paths()
    godot = find_executable([
        args.godot, os.environ.get("GODOT_BIN"), "godot", "godot4",
        ROOT / "tools/godot/Godot.app", "/Applications/Godot.app",
        Path.home() / "Applications/Godot.app",
        ROOT.parents[1] / "glory-ios-dev/tools/godot/Godot.app",
        ROOT.parents[1] / "乐工坊/tools/godot/Godot.app",
    ])
    if not godot:
        raise RuntimeError("找不到 Godot；使用 --godot /完整路径/Godot（需与项目版本一致）。")
    version = capture([godot, "--version"]).splitlines()[-1]
    match = re.match(r"(\d+\.\d+)(?:\.(\d+))?\.([^.]+)", version)
    if not match:
        raise RuntimeError(f"无法识别 Godot 版本：{version}")
    major_minor = match[1]
    template_version = f"{major_minor}{'.' + match[2] if match[2] else ''}.{match[3]}"
    template = first_dir([
        args.templates, os.environ.get("GODOT_TEMPLATES"),
        Path.home() / "Library/Application Support/Godot/export_templates" / template_version,
        Path.home() / ".local/share/godot/export_templates" / template_version,
    ], "android_debug.apk")
    if not template:
        raise RuntimeError(f"缺少 {template_version} Android 导出模板；在 Godot 导出模板管理器安装，或用 --templates 指定目录。")
    java = first_dir([
        args.java_home, os.environ.get("JAVA_HOME"), settings.get("java_sdk_path"),
        "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home",
        "/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home",
        "/usr/lib/jvm/java-17-openjdk-amd64",
    ], "bin/java")
    if not java or not (java / "bin/keytool").is_file():
        raise RuntimeError("缺少 JDK；安装 JDK 17 后设置 JAVA_HOME 或 --java-home。")
    sdk = first_dir([
        args.android_sdk, os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"),
        settings.get("android_sdk_path"), Path.home() / "Library/Android/sdk",
        "/opt/homebrew/share/android-commandlinetools", Path.home() / "Android/Sdk",
    ], "build-tools")
    if not sdk:
        raise RuntimeError("缺少 Android SDK；用 --android-sdk 指定包含 build-tools 和 platform-tools 的目录。")
    build_tools = sorted((p for p in (sdk / "build-tools").iterdir()
                          if (p / "apksigner").is_file() and (p / "aapt2").is_file() and (p / "zipalign").is_file()),
                         key=lambda p: tuple(int(n) for n in re.findall(r"\d+", p.name)), reverse=True)
    if not build_tools or not (sdk / "platform-tools/adb").is_file():
        raise RuntimeError(f"Android SDK 不完整：{sdk}（需要 aapt2、apksigner、zipalign、adb）。")
    keystore = Path(settings.get("debug_keystore") or Path.home() / ".android/debug.keystore").expanduser()
    return {"godot": godot, "version": version, "major_minor": major_minor,
            "template_version": template_version, "templates": template,
            "java": java, "sdk": sdk, "build_tools": build_tools[0], "keystore": keystore}


def asset_root(base):
    base = base.expanduser().resolve()
    if (base / "assets").is_dir():
        candidate = base / "assets"
    elif (base / "models").is_dir() and (base / "ui").is_dir():
        candidate = base
    else:
        candidates = [p / "assets" for p in base.iterdir() if p.is_dir() and (p / "assets").is_dir()] if base.is_dir() else []
        if len(candidates) != 1:
            raise RuntimeError(f"资源尚未同步/目录不明确：{base}。先执行 ./tools/sync_res.sh；支持 res/assets/ 或 res/models/ + res/ui/。")
        candidate = candidates[0]
    if not (candidate / "models").is_dir() or not (candidate / "ui").is_dir():
        raise RuntimeError(f"资源目录缺 models 或 ui：{candidate}")
    return candidate


def files_under(base):
    if not base.exists():
        return
    for parent, dirs, files in os.walk(base, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for directory in dirs:
            if (Path(parent) / directory).is_symlink():
                raise RuntimeError(f"资源不能包含目录符号链接：{Path(parent) / directory}")
        for filename in sorted(files):
            if filename in SKIP_FILES:
                continue
            path = Path(parent) / filename
            if path.is_symlink():
                raise RuntimeError(f"资源不能包含文件符号链接：{path}")
            yield path.relative_to(base), path


def copy_changed(source, target):
    if target.is_file() and not target.is_symlink():
        left, right = source.stat(), target.stat()
        if left.st_size == right.st_size and digest(source) == digest(target):
            return
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    # Content can change while Drive retains its size/mtime; ensure Godot notices it.
    os.utime(target, None)


@contextlib.contextmanager
def file_lock(path, shared=False, nonblocking=False):
    import fcntl  # POSIX-only; keeps this module importable on Windows (model pilot audit).
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+") as stream:
        try:
            fcntl.flock(stream.fileno(), (fcntl.LOCK_SH if shared else fcntl.LOCK_EX) | (fcntl.LOCK_NB if nonblocking else 0))
        except BlockingIOError:
            raise RuntimeError("已有 APK 构建在运行，请等待完成。") from None
        yield
        fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


def asset_sync_records(assets):
    """Read Drive provenance only for the resource tree managed by sync_res.sh."""
    if not assets.resolve().is_relative_to((ROOT / "res").resolve()):
        return {}
    state = ROOT / ".glory-sync/state.json"
    if not state.is_file():
        return {}
    records = json.loads(state.read_text(encoding="utf-8")).get("files", {})
    if not isinstance(records, dict):
        raise RuntimeError("资源同步记录格式异常，无法确认资源来源时间。")
    return records


def resource_source_time(path, content_hash, records):
    """A downloaded file's local mtime is not evidence of its remote freshness."""
    try:
        relative = path.resolve().relative_to((ROOT / "res").resolve()).as_posix()
    except ValueError:
        return path.stat().st_mtime_ns, "local_mtime"
    record = records.get(relative)
    if isinstance(record, dict) and record.get("applied") is False:
        local = record.get("local_copy", {})
        if isinstance(local, dict) and local.get("sha256") == content_hash:
            timestamp = local.get("modified_time_ns")
            valid = isinstance(timestamp, int) and not isinstance(timestamp, bool) and timestamp > 0
            return (timestamp if valid else None), "preserved_local_time" if valid else "preserved_local_time_unknown"
    elif isinstance(record, dict) and record.get("sha256") == content_hash:
        version = record.get("version")
        timestamp = version[1] if isinstance(version, (list, tuple)) and len(version) > 1 else None
        try:
            valid = (isinstance(timestamp, (int, float)) and not isinstance(timestamp, bool)
                     and timestamp > 0 and math.isfinite(timestamp))
        except OverflowError:
            valid = False
        if valid:
            return int(timestamp * 1_000_000), "drive_modified_time"
        return None, "drive_modified_time_unknown"
    # A different hash is a local edit; keep the old cloud baseline untouched.
    return path.stat().st_mtime_ns, "local_edit_mtime" if record else "local_mtime"


def project_source_times(project, paths):
    """Use Git content history for clean tracked files, not checkout timestamps."""
    paths = list(paths)
    result = {path: (path.stat().st_mtime_ns, "local_mtime") for path in paths}
    try:
        repository = Path(capture(["git", "-C", project, "rev-parse", "--show-toplevel"])).resolve()
    except (subprocess.CalledProcessError, FileNotFoundError):
        # A plain local project has no checkout-generated timestamps to discount.
        return result
    git = ["git", "-C", str(repository)]
    try:
        tracked = set(subprocess.check_output(git + ["ls-files", "--cached", "-z"]).split(b"\0"))
        changed = set(subprocess.check_output(git + ["diff", "HEAD", "--name-only", "-z"]).split(b"\0"))
        clean = {os.fsencode(path.resolve().relative_to(repository)): path for path in paths
                 if os.fsencode(path.resolve().relative_to(repository)) in tracked
                 and os.fsencode(path.resolve().relative_to(repository)) not in changed}
        if not clean:
            return result
        # One batched history traversal avoids a Git subprocess per source file.
        history = subprocess.check_output(git + [
            "log", "--format=%x00%ct", "--name-only", "-z", "--no-renames",
            "--diff-merges=first-parent", "--", *[os.fsdecode(name) for name in clean],
        ])
    except subprocess.CalledProcessError as error:
        raise RuntimeError("无法读取项目 Git 文件历史，已停止，避免误用 checkout 时间判断新旧。") from error
    remaining = dict(clean)
    timestamp = None
    expect_timestamp = False
    first_path = False
    for part in history.split(b"\0"):
        if not part:
            expect_timestamp = True
        elif expect_timestamp:
            timestamp = int(part) * 1_000_000_000
            expect_timestamp = False
            first_path = True
        else:
            name = part.removeprefix(b"\n") if first_path else part
            first_path = False
            path = remaining.pop(name, None)
            if path is not None:
                result[path] = (timestamp, "git_commit_time")
    for path in remaining.values():
        result[path] = (None, "git_commit_time_unknown")
    return result


def choose_asset_source(project_file, resource_file, records, project_times=None, project_code=False):
    """Select from original inputs, never timestamps generated in the stage."""
    project_hash = digest(project_file) if project_file else None
    resource_hash = digest(resource_file) if resource_file else None
    project_time, project_time_source = ((project_times or {}).get(project_file, (project_file.stat().st_mtime_ns, "local_mtime"))
                                         if project_file else (None, None))
    resource_time, time_source = resource_source_time(resource_file, resource_hash, records) if resource_file else (None, None)
    if resource_file is None:
        selected, reason = "project", "project_only"
    elif project_file is None:
        selected, reason = "res", "resource_only"
    elif project_hash == resource_hash:
        selected, reason = "project", "identical_content"
    elif resource_time is None or project_time is None:
        selected, reason = "project", "resource_time_unknown" if resource_time is None else "project_time_unknown"
    elif resource_time > project_time:
        selected, reason = "res", "resource_strictly_newer"
    else:
        selected = "project"
        reason = "project_newer" if project_time > resource_time else "project_same_time"
    source = project_file if selected == "project" else resource_file
    return source, {"source": selected, "source_reason": reason,
                    "project_sha256": project_hash, "resource_sha256": resource_hash,
                    "project_mtime_ns": project_time, "resource_mtime_ns": resource_time,
                    "project_time_source": project_time_source, "resource_time_source": time_source}


def plan_asset_merge(project, assets):
    """Read-only merge preview shared by builds and source-selection audits."""
    original = dict(files_under(project / "assets"))
    cloud = dict(files_under(assets))
    records = asset_sync_records(assets)
    descriptor_root = assets.parent if assets.name == "assets" else assets
    descriptor_names = ("assets.manifest.json", "assets.bundle.json")
    project_times = project_source_times(project, [*original.values(),
                                        *(project / name for name in descriptor_names if (project / name).is_file())])
    desired = {}
    choices = {}
    protected = []
    protected_assets = []
    overwritten = []
    for relative in sorted(original.keys() | cloud.keys()):
        is_code = relative.suffix in (".gd", ".cs") or relative.name.endswith((".gd.uid", ".cs.uid"))
        source, choice = choose_asset_source(original.get(relative), cloud.get(relative), records, project_times=project_times)
        desired[relative] = source
        choices[relative.as_posix()] = choice
        if relative in original and relative in cloud and choice["project_sha256"] != choice["resource_sha256"]:
            if choice["source"] == "project":
                (protected if is_code else protected_assets).append(relative.as_posix())
            else:
                overwritten.append(relative.as_posix())
    descriptors = {}
    descriptor_choices = {}
    for name in descriptor_names:
        project_file, resource_file = project / name, descriptor_root / name
        if project_file.is_file() or resource_file.is_file():
            source, choice = choose_asset_source(project_file if project_file.is_file() else None,
                                                 resource_file if resource_file.is_file() else None, records,
                                                 project_times=project_times)
            descriptors[name] = source
            descriptor_choices[name] = choice
    decisions = [{"path": "assets/" + path, **choice} for path, choice in choices.items()]
    decisions += [{"path": path, **choice} for path, choice in descriptor_choices.items()]
    conflicts = [decision for decision in decisions if decision["source_reason"] in
                 ("resource_time_unknown", "project_time_unknown", "project_same_time")]
    report = {"asset_source": str(assets), "merged_file_count": len(desired), "missing_required": [],
              "missing_optional": [], "changed_required": [], "expected_manifest": "",
              "protected_project_code": sorted(protected), "protected_project_assets": sorted(protected_assets),
              "overridden_by_cloud_assets": sorted(overwritten), "asset_choices": choices,
              "descriptor_choices": descriptor_choices, "decisions": decisions, "selection_conflicts": conflicts}
    return desired, descriptors, report


def stage_project(project, assets, stage, logdir):
    desired, descriptors, report = plan_asset_merge(project, assets)
    stage.mkdir(parents=True, exist_ok=True)
    excluded = ["/.git", "/.godot", "/assets", "/build", "/backups", "/captures", "/reports", "/logs",
                "/delivery", "/work", "/backend", "/android", "/.claude", "/.codex", "/certs", "*.pem", "*.key", ".env*",
                "*.apk", "*.zip", "__pycache__", ".DS_Store", "upload ssh code.txt"]
    command = ["rsync", "-ac", "--delete", "--safe-links"]
    for value in excluded:
        command += ["--exclude", value]
    subprocess.run(command + [str(project) + "/", str(stage) + "/"], check=True)
    # Older staging runs copied diagnostic backups; rsync preserves excluded paths.
    # Ignore them in a reused stage without deleting any evidence.
    if (stage / "delivery").is_dir():
        (stage / "delivery/.gdignore").touch(exist_ok=True)
    asset_stage = stage / "assets"
    inputs_path = stage.parent / "asset-input-hashes.json"
    previous_inputs = json.loads(inputs_path.read_text()) if inputs_path.is_file() else {}
    input_hashes = {}
    for relative, source in desired.items():
        source_hash = digest(source)
        input_hashes[relative.as_posix()] = source_hash
        # Godot enriches .import files. Keep that generated metadata until the
        # original cloud/project .import changes, so warm builds remain incremental.
        if relative.suffix == ".import" and previous_inputs.get(relative.as_posix()) == source_hash and (asset_stage / relative).is_file():
            continue
        copy_changed(source, asset_stage / relative)
    for relative, path in list(files_under(asset_stage)):
        if relative not in desired:
            path.unlink()
    json_write(inputs_path, input_hashes)
    # Inventories follow the same policy, comparing their original source times.
    for name, source in descriptors.items():
        copy_changed(source, stage / name)
    manifest = stage / "assets.manifest.json"
    if manifest.is_file():
        data = json.loads(manifest.read_text(encoding="utf-8-sig"))
        report["expected_manifest"] = data.get("inventory_sha256", "")
        for entry in data.get("entries", []):
            relative = entry.get("path", "").removeprefix("res://")
            if not relative.startswith("assets/") or ".." in Path(relative).parts:
                continue
            actual = stage / relative
            required = entry.get("class") in ("runtime_required", "dynamic_dir")
            if not actual.is_file():
                report["missing_required" if required else "missing_optional"].append(relative)
            elif required and (actual.stat().st_size != entry.get("size") or digest(actual) != entry.get("sha256")):
                report["changed_required"].append(relative)
    inventory = hashlib.sha256()
    for relative in sorted(desired):
        actual = asset_stage / relative
        inventory.update(f"{relative.as_posix()}\t{actual.stat().st_size}\t{digest(actual)}\n".encode())
    report["actual_assets_sha256"] = inventory.hexdigest()
    json_write(logdir / "assets-check.json", report)
    if report["selection_conflicts"]:
        note(f"{len(report['selection_conflicts'])} 个同路径文件内容不同且时间未知或相同；已保留项目副本，详见 {logdir / 'assets-check.json'} 的 selection_conflicts。")
    if report["missing_required"]:
        raise RuntimeError(f"缺少 {len(report['missing_required'])} 个清单所需运行资源，已停止构建。详见 {logdir / 'assets-check.json'}")
    if report["changed_required"]:
        note(f"{len(report['changed_required'])} 个资源与随附清单版本不同；已记录实际资源指纹，后续检查真实导入结果。")
    note(f"隔离副本已就绪：{len(desired)} 个资源文件。")
    return report


def prepare_engine(env, work):
    folder = work / "engine"
    folder.mkdir(parents=True, exist_ok=True)
    if sys.platform == "darwin" and env["godot"].parent.name == "MacOS" and env["godot"].parents[2].suffix == ".app":
        # A signed macOS executable must retain its app bundle (Info.plist and signature).
        source_app = env["godot"].parents[2]
        target_app = folder / "Godot.app"
        subprocess.run(["rsync", "-ac", "--delete", str(source_app) + "/", str(target_app) + "/"], check=True)
        engine = target_app / "Contents/MacOS" / env["godot"].name
    else:
        engine = folder / "Godot"
        copy_changed(env["godot"], engine)
    (folder / "_sc_").touch()
    editor_data = folder / "editor_data"
    editor_data.mkdir(exist_ok=True)
    templates = editor_data / "export_templates"
    templates.mkdir(exist_ok=True)
    target = templates / env["template_version"]
    if target.is_symlink():
        if target.resolve() != env["templates"]:
            target.unlink()
    if not target.exists():
        target.symlink_to(env["templates"], target_is_directory=True)
    keystore = env["keystore"]
    if not keystore.is_file():
        keystore = folder / "debug.keystore"
        if not keystore.is_file():
            subprocess.run([str(env["java"] / "bin/keytool"), "-genkeypair", "-keystore", str(keystore),
                            "-storepass", "android", "-alias", "androiddebugkey", "-keypass", "android",
                            "-dname", "CN=Android Debug,O=Android,C=US", "-keyalg", "RSA", "-keysize", "2048",
                            "-validity", "10000"], check=True, stdout=subprocess.DEVNULL)
            keystore.chmod(0o600)
    values = {"export/android/java_sdk_path": str(env["java"]), "export/android/android_sdk_path": str(env["sdk"]),
              "export/android/debug_keystore": str(keystore), "export/android/debug_keystore_user": "androiddebugkey",
              "export/android/debug_keystore_pass": "android"}
    settings = '[gd_resource type="EditorSettings" format=3]\n\n[resource]\n'
    settings += "\n".join(f"{key} = {json.dumps(value)}" for key, value in values.items()) + "\n"
    (editor_data / f"editor_settings-{env['major_minor']}.tres").write_text(settings)
    return engine


def export_preset(stage, wanted):
    file = stage / "export_presets.cfg"
    if not file.is_file():
        shutil.copy2(stage / "export_presets.template.cfg", file)
    text = file.read_text(encoding="utf-8-sig")
    sections = list(re.finditer(r"^\[preset\.(\d+)\]\s*$", text, re.M))
    selected = None
    for match in sections:
        end = text.find("\n[", match.end())
        body = text[match.end():end if end != -1 else len(text)]
        name = re.search(r'^name="([^"]+)"', body, re.M)
        if 'platform="Android"' in body and name and (not wanted or name[1] == wanted):
            selected = (match, end, body, name[1])
            break
    if not selected:
        raise RuntimeError(f"找不到 Android 导出预设：{wanted or '(自动选择)'}")
    match, end, body, name = selected
    for key, extra in (
        ("include_filter", ["assets.manifest.json", "assets.bundle.json", "build_info.json",
                            "ui/fonts/NotoSansSC-OFL.txt"]),
        ("exclude_filter", ["*.bak", "*.bak_*", "*.backup*", "backups/*", "*/backups/*", "*/Demo_GodotVFX/*",
                            "*/New folder/*", "*/desktop.ini", "*/Thumbs.db", "tools/*", "officetest/*", "reports/*",
                            "backend/*", "work/*", "build/*", "logs/*", "docs/*", "*.pem", "*.key", ".env*",
                            "scenes/debug/*", "effects/vfx3d/experimental/*", "addons/effekseer/*",
                            "addons/glory_voice/glory_voice.gdextension",
                            # Unreferenced vendor demo points to an undelivered shield_02 scene.
                            # The rest of binbun_reference is required by real battle VFX.
                            "effects/vfx3d/vfxv2/binbun_reference/assets/BinbunVFX_Vol2/BattleFX/battle_fx_scene_free.tscn"]),
    ):
        field = re.search(r'^' + key + r'="([^"]*)"', body, re.M)
        values = [v for v in (field[1].split(",") if field else []) + extra if v]
        line = f'{key}="{",".join(dict.fromkeys(values))}"'
        body = body[:field.start()] + line + body[field.end():] if field else body + "\n" + line + "\n"
    text = text[:match.end()] + body + text[end:] if end != -1 else text[:match.end()] + body
    option_match = re.search(r'^\[preset\.' + match[1] + r'\.options\]\s*\n(.*?)(?=^\[|\Z)', text, re.M | re.S)
    if not option_match:
        raise RuntimeError("Android 预设缺少 options。")
    options = option_match[1]
    options = re.sub(r'(?m)^gradle_build/use_gradle_build=.*\n?', '', options)
    options = 'gradle_build/use_gradle_build=true\n' + options
    text = text[:option_match.start(1)] + options + text[option_match.end(1):]
    file.write_text(text, encoding="utf-8")
    file.chmod(0o600)
    option_match = re.search(r'^\[preset\.' + match[1] + r'\.options\]\s*\n(.*?)(?=^\[|\Z)', text, re.M | re.S)
    options = option_match[1] if option_match else ""
    package = re.search(r'^package/unique_name="([^"]+)"', options, re.M)
    if not package:
        raise RuntimeError("Android 预设缺少 package/unique_name。")
    return name, package[1]


def logged_process(command, log, env, strict=True):
    note(f"运行中，完整日志：{log}")
    with log.open("w") as output:
        process = subprocess.Popen([str(v) for v in command], stdout=output, stderr=subprocess.STDOUT, env=env)
        try:
            while True:
                try:
                    code = process.wait(timeout=30)
                    break
                except subprocess.TimeoutExpired:
                    tail = log.read_text(errors="replace").splitlines()[-1:]
                    note("仍在处理：" + (tail[0][:160] if tail else "等待 Godot"))
        except BaseException:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
            raise
    content = re.sub(r"\x1b\[[0-9;]*m", "", log.read_text(errors="replace"))
    if code != 0 or (strict and ERROR_RE.search(content)):
        raise RuntimeError(f"步骤失败（退出码 {code}）。详见 {log}\n" + "\n".join(content.splitlines()[-12:]))
    return content


def verify_model_materials(engine, stage, logdir, env):
    """Reuse the project's runtime material audit, including non-roster wrappers."""
    checker = stage / "tools/model_material_integrity_check.gd"
    if not checker.is_file():
        return None
    source = checker.read_text()
    hook = "\t_check_stale_whitelist_entries()"
    if source.count(hook) != 1:
        raise RuntimeError("模型材质检查脚本结构已变更，请更新构建适配。")
    extras = [
        "assets/models/allies/abyss_beast_animated/abyss_beast_animated.tscn",
        "assets/models/monsters/ren/pve_ren_puppet_master_animated/pve_ren_puppet_master_animated.tscn",
        "assets/models/pets/pet_cat/pet_cat_animated.tscn",
        "assets/models/pets/pet_mushroom/pet_mushroom_animated.tscn",
        "assets/models/pets/pet_rabbit/pet_rabbit_animated.tscn",
    ]
    extra_code = ""
    for path in extras:
        if (stage / path).is_file():
            extra_code += f'\tawait _audit_model("build_extra", "extra", "res://{path}")\n'
    source = source.replace(hook, extra_code + hook)
    (stage / "tools/_build_material_integrity.gd").write_text(source)
    (stage / "tools/_build_material_integrity.tscn").write_text(
        '[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://tools/_build_material_integrity.gd" id="1"]\n'
        '[node name="BuildMaterialIntegrity" type="Node"]\nscript = ExtResource("1")\n')
    note("验证全部战斗模型及补充模型的最终材质、纹理与三个动作…")
    # Runtime checks create autoloads: keep user:// away from the player's saves.
    # The temporary override is restored before Android export.
    override = stage / "override.cfg"
    original_override = override.read_bytes() if override.is_file() else None
    test_override = original_override.decode("utf-8-sig") if original_override else ""
    for key in ("config/use_custom_user_dir", "config/custom_user_dir_name"):
        test_override = re.sub(r"^" + re.escape(key) + r"=.*\n?", "", test_override, flags=re.M)
    test_user_dir = "GLoryBuildChecks/" + hashlib.sha256(str(ROOT).encode()).hexdigest()[:12]
    settings = f'config/use_custom_user_dir=true\nconfig/custom_user_dir_name="{test_user_dir}"\n'
    if "[application]" in test_override:
        test_override = test_override.replace("[application]", "[application]\n" + settings, 1)
    else:
        test_override += "\n[application]\n" + settings
    override.write_text(test_override)
    try:
        # The audit scene's explicit CHECK_RESULT and JSON report are the
        # authoritative result.  A project may also contain a platform-only
        # GDExtension (for example the Windows voice bridge); Godot reports
        # that extension as an ERROR while running the macOS editor even
        # though it is not part of the iOS runtime.  Keep the audit output in
        # the log and validate the report below instead of rejecting a valid
        # model audit on that platform warning.
        output = logged_process([engine, "--headless", "--path", stage, "res://tools/_build_material_integrity.tscn"],
                                logdir / "model-materials.log", env, strict=False)
    finally:
        if original_override is None:
            override.unlink(missing_ok=True)
        else:
            override.write_bytes(original_override)
    report_file = stage / "reports/model_material_integrity.json"
    if "CHECK_RESULT name=model_material_integrity status=PASS" not in output or not report_file.is_file():
        raise RuntimeError("模型材质检查未通过或未生成报告。")
    report = json.loads(report_file.read_text())
    summary = report["summary"]
    if not summary.get("models") or any(summary.get(key) for key in
            ("scene_load_failed", "material_missing", "missing_texture", "white_material_suspect")):
        raise RuntimeError("模型材质完整性报告存在失败项。")
    shutil.copy2(report_file, logdir / "model-materials.json")
    note(f"材质验证通过：{summary['models']} 个模型，{summary['surfaces']} 个表面，{summary['textures']} 个纹理引用。")
    return report


def verify_import_diagnostics(content, stage, logdir, material_report):
    """Only accept unused FBX source-image errors backed by live material checks.

    Godot 4.7 tries to read original FBX texture paths even with Discard All
    Textures selected. These wrappers apply shipped .tres materials after loading
    their action meshes; the runtime audit verifies those actual surfaces.
    """
    lines = content.splitlines()
    # The Windows-only voice bridge is intentionally present in the source
    # project, but it has no macOS host library. Godot emits these exact
    # diagnostics while scanning the project on this Mac; they do not affect
    # the iOS export. Keep them in the import log and exclude only these
    # known platform diagnostics from the FBX error pairing below.
    platform_extension_errors = {
        "ERROR: No GDExtension library found for current OS and architecture (macos.arm64) in configuration file: res://addons/glory_voice/glory_voice.gdextension",
        "ERROR: GDExtension dynamic library not found: 'res://addons/glory_voice/glory_voice.gdextension'.",
        "ERROR: Error loading extension: 'res://addons/glory_voice/glory_voice.gdextension'.",
    }
    all_errors = [line for line in lines if ERROR_RE.search(line)]
    ignored_platform_errors = [line for line in all_errors if line in platform_extension_errors]
    errors = [line for line in all_errors if line not in platform_extension_errors]
    if not ERROR_RE.search(content):
        return {"accepted_fbx_source_texture_errors": 0, "ignored_platform_extension_errors": [], "paths": []}
    if not material_report or len(errors) % 2:
        raise RuntimeError(f"资源导入有未验证的错误，详见 {logdir / 'import.log'}")
    paths = []
    generic = "ERROR: Resource file not found: res:// (expected type: Texture2D)"
    audited_models = [row for row in material_report["models"] if row.get("status") == "PASS"]
    for index in range(0, len(errors), 2):
        match = re.fullmatch(r"ERROR: Can't open file from path '(res://assets/models/[^']+)'\.", errors[index + 1])
        if errors[index] != generic or not match:
            raise RuntimeError(f"资源导入存在不属于已验证 FBX 源纹理的错误：{errors[index:index + 2]}")
        missing = match[1]
        if not any("WARNING: FBX: Image index" in line and f"path: {missing} because there was no data" in line for line in lines):
            raise RuntimeError(f"缺失纹理不能归属 FBX 源文件：{missing}")
        relative = Path(missing.removeprefix("res://"))
        covered = []
        for row in audited_models:
            model_dir = Path(row["scene_path"].removeprefix("res://")).parent
            if relative.is_relative_to(model_dir):
                covered.append(row["scene_path"])
        if not covered:
            raise RuntimeError(f"FBX 源纹理所属最终模型未通过运行材质检查：{missing}")
        paths.append({"missing_original_fbx_image": missing, "verified_wrapper_scenes": covered})
    # Every imported FBX must actually have a compiled scene, independent of logs.
    compiled = 0
    compiled_dirs = set()
    for metadata in (stage / "assets/models").rglob("*.fbx.import"):
        match = re.search(r'^path="res://([^"]+)"', metadata.read_text(encoding="utf-8"), re.M)
        artifact = (stage / match[1]).resolve() if match else None
        if not match or not metadata.with_suffix("").is_file() or not artifact.is_file() or artifact.stat().st_size == 0 \
                or not artifact.is_relative_to((stage / ".godot/imported").resolve()):
            raise RuntimeError(f"FBX 未生成有效导入场景：{metadata}")
        compiled += 1
        compiled_dirs.add(metadata.parent.relative_to(stage))
    if not compiled:
        raise RuntimeError("FBX 源纹理错误缺少实际 FBX 导入产物，不能放行。")
    for entry in paths:
        missing_relative = Path(entry["missing_original_fbx_image"].removeprefix("res://"))
        owners = [directory for directory in compiled_dirs if missing_relative.is_relative_to(directory)]
        if ".." in missing_relative.parts or not owners:
            raise RuntimeError(f"FBX 源纹理没有对应目录的有效导入元数据和产物：{entry['missing_original_fbx_image']}")
        entry["verified_fbx_directories"] = sorted(str(directory) for directory in owners)
    report = {"accepted_fbx_source_texture_errors": len(errors),
              "ignored_platform_extension_errors": ignored_platform_errors,
              "compiled_fbx_scenes": compiled,
              "reason": "Original FBX texture references are superseded by shipped wrapper materials; every final model surface and texture passed the runtime material audit.",
              "paths": paths}
    json_write(logdir / "import-diagnostics.json", report)
    note(f"已核验 {len(paths)} 条 FBX 原始纹理诊断；最终材质检查通过，{compiled} 个 FBX 导入场景有效。")
    return report


def verify_export_diagnostics(content, logdir):
    """Classify known exporter diagnostics without hiding a failed export.

    The current upstream checkout carries the Effekseer extension but not its
    Android shared libraries (the repository documents this as a known
    packaging gap). Godot still completes the APK export and embeds empty
    placeholders, so keep those two expected diagnostics visible in the build
    report while failing on every other export error.
    """
    done = content.rfind("[ DONE ] export")
    if done < 0:
        raise RuntimeError(f"Godot 日志没有确认导出完成，详见 {logdir / 'export.log'}")
    accepted = []
    platform_extension_errors = {
        "ERROR: No GDExtension library found for current OS and architecture (macos.arm64) in configuration file: res://addons/glory_voice/glory_voice.gdextension",
        "ERROR: GDExtension dynamic library not found: 'res://addons/glory_voice/glory_voice.gdextension'.",
        "ERROR: Error loading extension: 'res://addons/glory_voice/glory_voice.gdextension'.",
    }
    for match in re.finditer(r"^.*$", content, re.M):
        line = match[0]
        if not ERROR_RE.search(line):
            continue
        if done >= 0 and match.start() > done and re.fullmatch(
                r"ERROR: \d+ RID allocations of type 'N13RendererDummy15MaterialStorage11DummyShaderE' were leaked at exit\.", line):
            accepted.append(line)
        elif re.fullmatch(
                r"ERROR: Can't open file from path 'res://addons/effekseer/bin/android/libeffekseer\.(arm32|arm64)\.so'\.",
                line):
            accepted.append(line)
        elif line in platform_extension_errors:
            accepted.append(line)
        else:
            raise RuntimeError(f"APK 导出存在错误：{line}。详见 {logdir / 'export.log'}")
    json_write(logdir / "export-diagnostics.json", {"export_completed": done >= 0, "host_shutdown_diagnostics": accepted})
    return accepted


def main():
    parser = argparse.ArgumentParser(description="将 GLory-v1.0 与本地 res 合并到隔离目录构建 Android 调试 APK；--sync 先更新 Git 和 Drive。")
    parser.add_argument("--sync", action="store_true", help="先 git pull --ff-only 更新当前分支代码和仓库资源，再同步 Drive 资源，最后构建")
    parser.add_argument("--check", action="store_true", help="只读检查工具环境和资源目录；即使带 --sync 也不更新、导入或构建")
    parser.add_argument("--project", type=Path, default=ROOT / "GLory-v1.0")
    parser.add_argument("--assets", type=Path, default=ROOT / "res", help="res、res/assets 或其他已展开的资源目录")
    parser.add_argument("--godot", help="Godot 二进制或 .app 路径，也可设置 GODOT_BIN")
    parser.add_argument("--java-home", help="JDK 根目录，也可设置 JAVA_HOME")
    parser.add_argument("--android-sdk", help="Android SDK 根目录，也可设置 ANDROID_HOME")
    parser.add_argument("--templates", help="匹配 Godot 版本的导出模板目录")
    parser.add_argument("--preset", help="导出预设名，默认选首个 Android 预设")
    args = parser.parse_args()
    project = args.project.expanduser().resolve()
    if not (project / "project.godot").is_file():
        raise RuntimeError(f"不是 Godot 工程：{project}")
    git_sync = None
    if args.sync and not args.check:
        # Serialize Git updates against other script-driven builds/snapshots.
        with file_lock(ROOT / "build/.apk-build.lock", nonblocking=True):
            git_sync = sync_project(project)
        subprocess.run([str(Path(__file__).resolve().with_name("sync_res.sh"))], check=True)
    env = environment(args)
    note(f"Godot {env['version']}；JDK：{env['java']}；Android SDK：{env['sdk']}")
    feature = re.search(r'config/features=.*?"(\d+\.\d+)"', (project / "project.godot").read_text())
    if feature and feature[1] != env["major_minor"]:
        raise RuntimeError(f"项目声明 Godot {feature[1]}，当前是 {env['version']}；请使用匹配版本。")
    assets = asset_root(args.assets)
    stage_path = (ROOT / "build/android-work/project").resolve()
    for source in (project, assets):
        if source.is_relative_to(stage_path) or stage_path.is_relative_to(source):
            raise RuntimeError(f"源目录与隔离构建目录重叠，已停止以保护源文件：{source}")
    note(f"资源目录：{assets}")
    if args.check:
        status_path = ROOT / ".glory-sync/last-run.json"
        if assets.is_relative_to((ROOT / "res").resolve()) and status_path.is_file():
            sync_state = json.loads(status_path.read_text()).get("status")
            if sync_state in ("running", "failed"):
                raise RuntimeError(f"工具环境可用；最近资源同步状态是 {sync_state}，需同步成功后再构建。")
        note("环境与资源目录检查通过；实际资源完整性及导入将在构建时检查。")
        return
    if not shutil.which("rsync"):
        raise RuntimeError("缺少 rsync，请先安装。")
    build = ROOT / "build"
    with file_lock(build / ".apk-build.lock", nonblocking=True):
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        logdir = build / "logs" / f"apk-{stamp}-{os.getpid()}"
        logdir.mkdir(parents=True)
        work = build / "android-work"
        work.mkdir(exist_ok=True)
        stage = work / "project"
        # A generated-only workspace; never rsync/delete the source project or res.
        try:
            with file_lock(ROOT / ".glory-sync/sync.lock", shared=True):
                sync_status = ROOT / ".glory-sync/last-run.json"
                if assets.is_relative_to((ROOT / "res").resolve()) and sync_status.is_file():
                    state = json.loads(sync_status.read_text()).get("status")
                    if state in ("running", "failed"):
                        raise RuntimeError("资源同步尚未成功完成，请重新运行 ./tools/sync_res.sh 后再打包。")
                report = stage_project(project, assets, stage, logdir)
            engine = prepare_engine(env, work)
            preset, package = export_preset(stage, args.preset)
            commit = capture(["git", "-C", project, "rev-parse", "HEAD"])
            status = capture(["git", "-C", project, "status", "--porcelain"])
            identity = {"build_id": str(uuid.uuid4()), "git_commit": commit, "git_commit_short": commit[:8],
                        "dirty_files": len(status.splitlines()) if status else 0, "build_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
                        "godot_version": env["version"], "package_id": package, "export_preset": preset,
                        "asset_inventory_sha256": report["actual_assets_sha256"], "asset_inventory_kind": "merged_source_files_sha256"}
            json_write(stage / "build_info.json", identity)
            json_write(logdir / "build_info.json", identity)
            child_env = dict(os.environ, JAVA_HOME=str(env["java"]), ANDROID_HOME=str(env["sdk"]), ANDROID_SDK_ROOT=str(env["sdk"]))
            child_env["PATH"] = str(env["java"] / "bin") + os.pathsep + child_env.get("PATH", "")
            note("导入资源（首次运行耗时较长，后续复用隔离目录的导入缓存）…")
            imported = logged_process([engine, "--headless", "--path", stage, "--import"], logdir / "import.log", child_env, strict=False)
            materials = verify_model_materials(engine, stage, logdir, child_env)
            import_diagnostics = verify_import_diagnostics(imported, stage, logdir, materials)
            outdir = build / "apk"
            outdir.mkdir(exist_ok=True)
            apk = outdir / f"Glory-debug-{stamp}-{commit[:8]}.apk"
            note(f"导出 Android 调试包，包名 {package}，预设 {preset}…")
            export_command = [engine, "--headless", "--path", stage]
            # A clean checkout has no generated android/build module. Ask
            # Godot to install the matching source template as part of this
            # first export; subsequent builds reuse the isolated module.
            if not (stage / "android/build/config.gradle").is_file():
                export_command.append("--install-android-build-template")
            export_command += ["--export-debug", preset, apk]
            exported = logged_process(export_command, logdir / "export.log", child_env, strict=False)
            export_diagnostics = verify_export_diagnostics(exported, logdir)
            if not apk.is_file():
                raise RuntimeError("Godot 未生成 APK。")
            with zipfile.ZipFile(apk) as archive:
                bad = archive.testzip()
                if bad:
                    raise RuntimeError(f"APK ZIP 校验失败：{bad}")
                if json.loads(archive.read("assets/build_info.json")) != identity:
                    raise RuntimeError("APK 内构建身份与本次构建不一致。")
                dex = [archive.read(n) for n in archive.namelist() if n.endswith('.dex')]
                for required in (b'com/glory/voice/GloryVoicePlugin', b'io/livekit/android/room/Room'):
                    if not any(required in blob for blob in dex):
                        raise RuntimeError("APK 缺少语音运行依赖：" + required.decode())
            logged_process([env["build_tools"] / "apksigner", "verify", "--verbose", apk], logdir / "signature.log", child_env)
            badging = capture([env["build_tools"] / "aapt2", "dump", "badging", apk], env=child_env)
            (logdir / "apk-badging.txt").write_text(badging + "\n")
            if f"package: name='{package}'" not in badging:
                raise RuntimeError("APK 包名与导出预设不一致。")
            if "android.permission.RECORD_AUDIO" not in badging:
                raise RuntimeError("APK 缺少语音录音权限。")
            for unwanted in ("android.permission.CAMERA", "android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION"):
                if unwanted in badging:
                    raise RuntimeError("APK 包含非语音所需权限：" + unwanted)
            summary = dict(identity, apk=str(apk), apk_bytes=apk.stat().st_size, apk_sha256=digest(apk),
                           logs=str(logdir), source_project=str(project), asset_source=str(assets),
                           signed=True, built=True, device_installed=False, device_tested=False,
                           accepted_fbx_source_texture_errors=import_diagnostics["accepted_fbx_source_texture_errors"],
                           host_shutdown_diagnostics=export_diagnostics,
                           model_materials=materials["summary"] if materials else None,
                           git_sync=git_sync)
            json_write(logdir / "result.json", summary)
            json_write(build / "latest-apk.json", summary)
            latest = outdir / "Glory-latest.apk"
            temporary = outdir / f".latest-{os.getpid()}"
            temporary.symlink_to(apk.name)
            os.replace(temporary, latest)
            note(f"构建完成：{apk}（{apk.stat().st_size / 1048576:.1f} MiB）")
            note(f"固定入口：{latest}；SHA-256：{summary['apk_sha256']}")
        except BaseException as error:
            json_write(logdir / "failure.json", {"built": False, "error": str(error), "logs": str(logdir)})
            raise


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"[APK] 失败：{error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("[APK] 已中止；--sync 已完成的 Git/Drive 更新会保留，可重新运行。", file=sys.stderr)
        sys.exit(130)
