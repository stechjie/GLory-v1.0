extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "asset_delivery"
const DEFAULT_MANIFEST_PATH := "res://assets.manifest.json"
const CACHE_PATH := "user://asset_delivery_hash_cache.json"
const SUPPORTED_SCHEMA_VERSION := 2
const HASH_CHUNK := 1048576
const MAX_FAILURE_DETAILS := 50
const SKIP_DIR_NAMES := ["backups", "android", "captures", "__pycache__"]

var _h: CheckHarness
var _manifest_path := DEFAULT_MANIFEST_PATH
var _strict_extras := false
var _full_hash := false
var _cache: Dictionary = {}
var _problem_counts: Dictionary = {}
var _problem_total := 0
var _reported_problems := 0
var _cache_hits := 0
var _expected_inventory := ""


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_parse_args()
	if not _full_hash:
		_load_cache()

	if not FileAccess.file_exists(_manifest_path):
		_problem("manifest_missing", "清单不存在：%s" % _manifest_path)
		_finish(0, 0, 0, 0)
		return

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_manifest_path))
	if not (parsed is Dictionary):
		_problem("manifest_parse_failed", "清单不是有效 JSON 对象：%s" % _manifest_path)
		_finish(0, 0, 0, 0)
		return

	var manifest: Dictionary = parsed
	_expected_inventory = str(manifest.get("inventory_sha256", "")).to_lower()
	if int(manifest.get("schema_version", 0)) != SUPPORTED_SCHEMA_VERSION:
		_problem("schema_unsupported", "schema_version=%s，当前只接受 %d" % [
			str(manifest.get("schema_version", "missing")), SUPPORTED_SCHEMA_VERSION])

	var entries_value: Variant = manifest.get("entries", [])
	if not (entries_value is Array):
		_problem("entries_invalid", "manifest.entries 不是数组")
		_finish(0, 0, 0, 0)
		return
	var entries: Array = entries_value
	if entries.is_empty():
		_problem("entries_empty", "manifest.entries 为空；空清单不能证明资源完整")
	else:
		_h.item(entries.size())

	var roots := _read_roots(manifest.get("roots", []))
	if roots.is_empty():
		_problem("roots_invalid", "manifest.roots 为空或格式错误")

	var expected_paths: Dictionary = {}
	for value in entries:
		if not (value is Dictionary):
			_problem("entry_invalid", "manifest.entries 中存在非对象条目")
			continue
		var entry: Dictionary = value
		var path := str(entry.get("path", ""))
		if path.is_empty() or not path.begins_with("res://") or not _path_in_roots(path, roots):
			_problem("path_outside_roots", "条目路径不在声明的资源根内：%s" % path)
			continue
		if expected_paths.has(path):
			_problem("duplicate_path", "清单路径重复：%s" % path)
			continue
		expected_paths[path] = true
		var sha := str(entry.get("sha256", "")).to_lower()
		if sha.length() != 64 or not sha.is_valid_hex_number():
			_problem("entry_hash_invalid", "条目 SHA-256 非 64 位十六进制：%s" % path)
		if int(entry.get("size", -1)) < 0:
			_problem("entry_size_invalid", "条目 size 无效：%s" % path)

	var actual_inventory := _inventory_digest(entries)
	if _expected_inventory.length() != 64 or not _expected_inventory.is_valid_hex_number():
		_problem("inventory_hash_invalid", "manifest.inventory_sha256 不是有效 SHA-256")
	elif actual_inventory != _expected_inventory:
		_problem("inventory_hash_mismatch", "清单稳定指纹不匹配：expected=%s actual=%s" % [
			_expected_inventory, actual_inventory])

	var missing := 0
	var size_mismatch := 0
	var hash_mismatch := 0
	var progress := 0
	for value in entries:
		if not (value is Dictionary):
			continue
		var entry: Dictionary = value
		var path := str(entry.get("path", ""))
		if path.is_empty() or not expected_paths.has(path):
			continue
		progress += 1
		if progress % 500 == 0:
			print("[%s] 校验进度 %d/%d" % [CHECK_NAME, progress, entries.size()])
		if not FileAccess.file_exists(path):
			missing += 1
			_problem("file_missing", "资源缺失：%s" % path)
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			missing += 1
			_problem("file_unreadable", "资源无法读取：%s（error=%d）" % [path, FileAccess.get_open_error()])
			continue
		var actual_size := int(f.get_length())
		f.close()
		var expected_size := int(entry.get("size", -1))
		if actual_size != expected_size:
			size_mismatch += 1
			_problem("size_mismatch", "大小不匹配：%s expected=%d actual=%d" % [
				path, expected_size, actual_size])
			continue
		var actual_sha := _hash_file(path, actual_size)
		var expected_sha := str(entry.get("sha256", "")).to_lower()
		if actual_sha != expected_sha:
			hash_mismatch += 1
			_problem("hash_mismatch", "SHA-256 不匹配：%s expected=%s actual=%s" % [
				path, expected_sha, actual_sha])

	var extras := 0
	if _strict_extras:
		var actual_paths: Array[String] = []
		for root in roots:
			_collect_files(root, actual_paths)
		for path in actual_paths:
			if not expected_paths.has(path):
				extras += 1
				_problem("unexpected_file", "清单根内存在未登记文件：%s" % path)

	_save_cache()
	_finish(entries.size(), missing, size_mismatch, hash_mismatch, extras)


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--strict-extras":
			_strict_extras = true
		elif arg == "--full-hash":
			_full_hash = true
		elif arg.begins_with("--manifest="):
			_manifest_path = arg.trim_prefix("--manifest=")
		else:
			_problem("unknown_argument", "未知参数：%s" % arg)


func _read_roots(value: Variant) -> Array[String]:
	var roots: Array[String] = []
	if not (value is Array):
		return roots
	for item in (value as Array):
		var root := str(item).trim_suffix("/")
		if root.begins_with("res://") and not root.contains(".."):
			roots.append(root)
	return roots


func _path_in_roots(path: String, roots: Array[String]) -> bool:
	for root in roots:
		if path.begins_with(root + "/"):
			return true
	return false


func _collect_files(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = d.get_next()
			continue
		var full := dir_path.path_join(entry)
		if d.current_is_dir():
			if not SKIP_DIR_NAMES.has(entry):
				_collect_files(full, out)
		else:
			out.append(full)
		entry = d.get_next()
	d.list_dir_end()


func _hash_file(path: String, size: int) -> String:
	var mtime := int(FileAccess.get_modified_time(path))
	if not _full_hash:
		var cached: Variant = _cache.get(path)
		if cached is Dictionary:
			var c: Dictionary = cached
			if int(c.get("size", -1)) == size and int(c.get("mtime", -1)) == mtime:
				var cached_sha := str(c.get("sha256", "")).to_lower()
				if cached_sha.length() == 64 and cached_sha.is_valid_hex_number():
					_cache_hits += 1
					return cached_sha

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while not f.eof_reached():
		ctx.update(f.get_buffer(HASH_CHUNK))
	f.close()
	var digest := ctx.finish().hex_encode()
	_cache[path] = {"size": size, "mtime": mtime, "sha256": digest}
	return digest


func _inventory_digest(entries: Array) -> String:
	var ordered := entries.duplicate()
	ordered.sort_custom(func(a, b): return str(a.get("path", "")) < str(b.get("path", "")))
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for value in ordered:
		if not (value is Dictionary):
			continue
		var entry: Dictionary = value
		var line := "%s\t%d\t%s\t%s\n" % [
			str(entry.get("path", "")),
			int(entry.get("size", 0)),
			str(entry.get("sha256", "")).to_lower(),
			str(entry.get("class", "")),
		]
		ctx.update(line.to_utf8_buffer())
	return ctx.finish().hex_encode()


func _load_cache() -> void:
	if not FileAccess.file_exists(CACHE_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CACHE_PATH))
	if parsed is Dictionary:
		_cache = parsed


func _save_cache() -> void:
	var f := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_cache))
	f.close()


func _problem(code: String, message: String) -> void:
	_problem_total += 1
	_problem_counts[code] = int(_problem_counts.get(code, 0)) + 1
	if _reported_problems < MAX_FAILURE_DETAILS:
		_reported_problems += 1
		_h.fail(code, message)


func _finish(entry_count: int, missing: int, size_mismatch: int, hash_mismatch: int, extras: int = 0) -> void:
	if _problem_total > _reported_problems:
		_h.fail("additional_failures", "另有 %d 项失败未逐条打印；分类计数=%s" % [
			_problem_total - _reported_problems, JSON.stringify(_problem_counts)])
	var status := "PASS" if _problem_total == 0 else "FAIL"
	print("ASSET_DELIVERY_RESULT status=%s entries=%d missing=%d size_mismatch=%d hash_mismatch=%d extras=%d cache_hits=%d inventory_sha256=%s" % [
		status, entry_count, missing, size_mismatch, hash_mismatch, extras, _cache_hits, _expected_inventory])
	_h.finish(get_tree())
