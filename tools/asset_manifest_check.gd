extends Node

# A1 —— 可复现资产清单。
#
# 回答两个问题：
#   1. 哪些资源是运行时真的会被加载的？（决定能裁掉什么、发布包该带什么）
#   2. 每个文件的确切内容是什么？（sha256，供 A2 在新机器上校验恢复结果）
#
# 和 tools/dep_scan.tscn 的分工：dep_scan 只回答"哪些 PNG 没人用"，
# 而且查依赖失败时只打印不失败。这里覆盖 assets/ 下**全部**文件类型，
# 并且把"查不动依赖"当成硬失败 —— 少算的依赖会让在用的文件被判成没用，
# 上次就是这样把水晶正在用的 46 MB 贴图搬走导致模型加载失败。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/asset_manifest_check.tscn
#   不要加 --quit-after，那会把退出码强制成 0。
#
# 产出：
#   assets.manifest.json    机读，A2 用它校验新机器上的资源恢复
#   docs/ASSET_MANIFEST.md  人读汇总

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "asset_manifest"

# 清单覆盖范围。effects/vfx3d/vfxv2 是外部参考包，不在 assets/ 下，
# 但 A5/C1 要给它们建许可台账，所以一并纳入盘点。
const INVENTORY_ROOTS := ["res://assets", "res://effects/vfx3d/vfxv2"]

# 会被 get_dependencies 问到的类型。.fbx/.glb 是源文件，Godot 把它们的
# 贴图依赖记在导入产物上，两边都要问。
const RESOURCE_EXT := ["tscn", "scn", "tres", "res", "material", "mesh",
	"fbx", "glb", "gltf", "obj", "gdshader"]

# 代码用目录常量在运行时拼路径的地方 —— 单个文件名不出现在任何静态引用里，
# 所以"没找到引用"对这些目录没有说服力，一律标 dynamic_dir 保留。
# 来源与 tools/dep_scan_node.gd 保持一致。
const DYNAMIC_DIRS := [
	"res://assets/ui/codex_portraits",
	"res://assets/ui/mercenary_portraits",
	"res://assets/ui/race_logos",
	"res://assets/ui/treasure_cards",
	"res://assets/ui/treasure_logos",
	"res://assets/ui/unit_portraits",
	"res://assets/vfx/boss",
	"res://assets/vfx/skills",
	"res://assets/vfx/status",
]

# 只被这些前缀下的文件引用 => 编辑器/调试用，不必进发布包。
const EDITOR_ONLY_PREFIXES := ["res://tools/", "res://scenes/debug/"]

const SKIP_DIR_NAMES := ["backups", "android", "captures", "__pycache__"]

# 归档/证据目录也在 res:// 下，但里面是**某次改动当时**的旧副本。
# 它们引用的是那一刻存在的文件，不代表当前工程状态：D6 删掉
# BattlePresentationSlice.gd 之后，D5_/D6_prechange_backup_* 里的副本仍在引用它，
# 于是清单会报出一个永远修不好的 missing_asset。用通配符匹配目录名，
# 避免每加一个证据目录就要改一次常量。匹配到的目录会在日志里逐个列出 ——
# 静默跳过目录本身就是一种假绿。
const SKIP_DIR_PATTERNS := [
	"*_prechange_backup_*",
	"*_backup_2*",
	"D?_*_20*",
	"E?_*_20*",
]

# 源码里"故意写出的不存在路径"的抑制标记。加在该行行尾即可。
# 两种真实场景：测试夹具（喂一个坏路径验证 fallback），以及
# 反向断言（D6 断言 BattlePresentationSlice.gd 必须不存在）。
# 这类路径永远不该存在，登记进允许列表会年年到期，用标记表达意图更准确。
const IGNORE_MARKER := "asset-manifest-ignore"

const MANIFEST_PATH := "res://assets.manifest.json"
const DOC_PATH := "res://docs/ASSET_MANIFEST.md"
const CACHE_PATH := "user://asset_manifest_hash_cache.json"
const MANIFEST_SCHEMA_VERSION := 2

const HASH_CHUNK := 1048576  # 1 MiB

var _h: CheckHarness

var _files: Array[String] = []              # 盘点范围内的全部文件
var _refs: Dictionary = {}                  # res:// 路径 -> Array[String] 引用者
var _visited: Dictionary = {}
var _dep_failed: Array[String] = []
var _missing: Dictionary = {}               # 被引用但不存在 -> Array[String] 引用者
var _cache: Dictionary = {}
var _cache_hits := 0
var _skipped_dirs: Array[String] = []       # 被跳过的归档/证据目录，收尾时列出
var _ignored_literal_lines := 0             # 带 asset-manifest-ignore 标记的行数

# V2 收尾 G2：**默认只读**。只有显式 `--update-manifest` 才写基准。
#
# 以前这个检查每次运行都改写 assets.manifest.json 和 docs/ASSET_MANIFEST.md，
# 而 asset_delivery_check 读的正是前者。字母序上 delivery 排在 manifest 前面，
# 于是任何资产改动都会让**第一次**全量红、**第二次**绿 ——
# 自愈的假红会训练人「再跑一遍就好」，长期比假绿还危险。
#
# 拆开之后：普通套件不再改写任何基准，delivery 校验的永远是进入本次套件时
# 已有的受信任清单，顺序依赖自然消失。run_check.ps1 另有一道守卫：
# 普通运行若改写了这两份文件，整套判失败并点名文件。
var _update_manifest := false


# 归档/证据目录不参与扫描。名字命中 SKIP_DIR_NAMES 或 SKIP_DIR_PATTERNS 即跳过，
# 并记下来在日志里列出 —— 悄悄少扫一个目录，等于悄悄放宽判定。
func _should_skip_dir(dir_name: String) -> bool:
	var skip := SKIP_DIR_NAMES.has(dir_name)
	if not skip:
		for pattern in SKIP_DIR_PATTERNS:
			if dir_name.match(pattern):
				skip = true
				break
	if skip and not _skipped_dirs.has(dir_name):
		_skipped_dirs.append(dir_name)
	return skip


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var started := Time.get_ticks_msec()
	_parse_args()

	_load_cache()

	for root in INVENTORY_ROOTS:
		_collect_files(root)
	print("[%s] 盘点范围内文件 %d 个" % [CHECK_NAME, _files.size()])

	# --- 四路引用来源 ---
	var resource_roots := _collect_resource_files("res://")
	print("[%s] 待问依赖的资源文件 %d 个" % [CHECK_NAME, resource_roots.size()])
	for r in resource_roots:
		_walk_dependencies(r, r)

	var literal_hits := _scan_text_literals()
	print("[%s] 文本字面量额外命中 %d 条" % [CHECK_NAME, literal_hits])

	var data_hits := _scan_data_json()
	print("[%s] data/*.json 字段额外命中 %d 条" % [CHECK_NAME, data_hits])

	print("[%s] 被引用到的路径 %d 条" % [CHECK_NAME, _refs.size()])
	_skipped_dirs.sort()
	print("[%s] 跳过的归档/证据目录 %d 个：%s" % [
		CHECK_NAME, _skipped_dirs.size(), ", ".join(_skipped_dirs)])
	print("[%s] 带 %s 标记而被忽略的行 %d 行" % [CHECK_NAME, IGNORE_MARKER, _ignored_literal_lines])

	# --- 判定 ---
	_check_missing()
	_check_dependency_failures()

	# --- 产出 ---
	var entries := _build_entries()
	if _update_manifest:
		_explicit_update(entries)
	else:
		_read_only_report(entries)

	print("[%s] 完成，耗时 %.1f 秒（hash 缓存命中 %d 个）" % [
		CHECK_NAME, (Time.get_ticks_msec() - started) / 1000.0, _cache_hits])
	_save_cache()
	_h.finish(get_tree())


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--update-manifest":
			_update_manifest = true
		else:
			_h.fail("unknown_argument", "未知参数：%s" % arg)


# 默认路径：把候选结果算出来给人看，但**一个字节都不写**。
func _read_only_report(entries: Array) -> void:
	var candidate := _inventory_digest(entries)
	var current := _current_inventory_sha()
	print("[%s] 只读模式（未写任何基准）。候选 inventory=%s 条目=%d；已提交基准 inventory=%s" % [
		CHECK_NAME, candidate, entries.size(), current if not current.is_empty() else "<读不到>"])
	if not current.is_empty() and candidate != current:
		print(("[%s] 候选与已提交基准不同 —— 这本身不是失败。要更新基准请显式跑："
			+ "powershell -File tools/update_asset_manifest.ps1") % CHECK_NAME)


# 显式更新路径。守卫保留：树不完整时仍拒绝覆盖最后一次可信基准。
#
# 这不是普通的红灯。assets.manifest.json 正是 asset_delivery_check 的比对基准；
# 从残缺树重新生成，会把「这批文件缺了」洗成「它们本来就不该在」，
# 于是 delivery 从此再也报不出这批缺失 —— 基准被自己毁掉，而套件依然全绿。
# 红灯能被人看见，被洗掉的基准不能。
#
# 判据用 failure_count()（**未被允许列表豁免**的失败数），不是 _missing.size()：
# 树里长期有 4 条挂了负责人和到期日的豁免项，按原始计数拦会把生成器焊死。
func _explicit_update(entries: Array) -> void:
	var candidate := _inventory_digest(entries)
	var current := _current_inventory_sha()
	if _h.failure_count() != 0:
		print(("[%s] manifest_untrusted=true 未豁免失败=%d（缺失=%d 依赖查询失败=%d）"
			+ "拒绝覆盖 %s 与 %s") % [
			CHECK_NAME, _h.failure_count(), _missing.size(), _dep_failed.size(),
			MANIFEST_PATH, DOC_PATH])
		return
	print("[%s] 显式更新基准：" % CHECK_NAME)
	print("[%s]   %s" % [CHECK_NAME, MANIFEST_PATH])
	print("[%s]   %s" % [CHECK_NAME, DOC_PATH])
	print("[%s]   inventory  旧=%s  新=%s" % [
		CHECK_NAME, current if not current.is_empty() else "<读不到>", candidate])
	print("[%s]   条目数     新=%d" % [CHECK_NAME, entries.size()])
	_write_manifest(entries)
	_write_doc(entries)


# 读已提交基准里的 inventory_sha256，用于「旧 -> 新」对照。读不到返回空串。
func _current_inventory_sha() -> String:
	if not FileAccess.file_exists(MANIFEST_PATH):
		return ""
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	if not (parsed is Dictionary):
		return ""
	return str((parsed as Dictionary).get("inventory_sha256", ""))


# --- 收集盘点范围 -------------------------------------------------------------

func _collect_files(dir_path: String) -> void:
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
			if not _should_skip_dir(entry):
				_collect_files(full)
		else:
			_files.append(full)
		entry = d.get_next()
	d.list_dir_end()


func _collect_resource_files(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = d.get_next()
			continue
		var full := dir_path.path_join(entry)
		if d.current_is_dir():
			# backups/ 里的旧副本引用了什么不代表当前还在用。
			if not _should_skip_dir(entry):
				out.append_array(_collect_resource_files(full))
		else:
			if RESOURCE_EXT.has(entry.get_extension().to_lower()):
				out.append(full)
		entry = d.get_next()
	d.list_dir_end()
	return out


# --- 引用来源 1：引擎依赖图 ---------------------------------------------------

func _walk_dependencies(path: String, origin: String, depth: int = 0) -> void:
	if depth > 12 or _visited.has(path):
		return
	_visited[path] = true
	var deps := ResourceLoader.get_dependencies(path)
	# 空结果分两种：真的没依赖，和读取失败（引擎往 stderr 吐 Method/function failed）。
	# 后者必须记成失败 —— dep_scan 里这只是个警告，那正是要修的假绿。
	if deps.is_empty() and not ResourceLoader.exists(path):
		if not _dep_failed.has(path):
			_dep_failed.append(path)
	for raw in deps:
		var parts := str(raw).split("::")
		var target := str(parts[parts.size() - 1])
		if not target.begins_with("res://"):
			continue
		_add_ref(target, origin)
		if RESOURCE_EXT.has(target.get_extension().to_lower()):
			_walk_dependencies(target, origin, depth + 1)


# --- 引用来源 2：脚本与场景里的 res:// 字面量 ---------------------------------

func _scan_text_literals() -> int:
	var hits := 0
	# 比 dep_scan 宽：不再限定 .png，任何扩展名都收。
	# 用「排除引号/空白」而不是列举合法字符 —— 列举法漏掉中文路径，
	# 而且写错时 RegEx 编译失败、search_all 静默返回空，等于又造一个假绿。
	var re := RegEx.create_from_string("res://[^\"'\\s<>|]*\\.[A-Za-z0-9_]+")
	if re == null or not re.is_valid():
		_h.fail("regex_compile_failed", "文本字面量扫描的正则编译失败，这一路引用全部漏算")
		return 0
	# 逐行扫而不是整段扫：这样才能看到该行有没有 asset-manifest-ignore 标记。
	for ext in ["gd", "tscn", "tres"]:
		for file_path in _collect_by_ext("res://", ext):
			var f := FileAccess.open(file_path, FileAccess.READ)
			if f == null:
				continue
			var text := f.get_as_text()
			f.close()
			for line in text.split("\n"):
				if line.contains(IGNORE_MARKER):
					_ignored_literal_lines += 1
					continue
				for m in re.search_all(line):
					var p := m.get_string()
					if p == file_path or not _looks_like_path(p):
						continue
					if _add_ref(p, file_path):
						hits += 1
	return hits


# 源码里出现的 "res://..." 不一定是路径 —— dep_scan_node.gd 里就有一条
# res://assets/[A-Za-z0-9_./-]+?\.png 的正则字面量。带正则元字符的一律不算引用，
# 否则会凭空报出一个永远修不好的 missing_asset。
func _looks_like_path(p: String) -> bool:
	for bad in ["[", "]", "*", "?", "+", "\\", "%", "$", "(", ")", "{", "}"]:
		if p.contains(bad):
			return false
	return true


# --- 引用来源 3：data/*.json 里的路径字段 -------------------------------------

func _scan_data_json() -> int:
	var hits := 0
	for file_path in _collect_by_ext("res://data", "json"):
		var text := FileAccess.get_file_as_string(file_path)
		var parsed: Variant = JSON.parse_string(text)
		if parsed == null:
			_h.fail("data_json_parse_failed", "%s 解析失败" % file_path)
			continue
		hits += _harvest_paths(parsed, file_path)
	return hits


# 递归找出任意层级里以 res:// 开头的字符串值，不按字段名白名单 ——
# 白名单会在新增字段时静默漏掉。
func _harvest_paths(value: Variant, origin: String) -> int:
	var hits := 0
	match typeof(value):
		TYPE_STRING:
			var s := str(value)
			if s.begins_with("res://") and _add_ref(s, origin):
				hits += 1
		TYPE_ARRAY:
			for v in (value as Array):
				hits += _harvest_paths(v, origin)
		TYPE_DICTIONARY:
			for k in (value as Dictionary):
				hits += _harvest_paths((value as Dictionary)[k], origin)
	return hits


func _add_ref(path: String, origin: String) -> bool:
	var is_new := not _refs.has(path)
	if is_new:
		_refs[path] = []
	var list: Array = _refs[path]
	if not list.has(origin):
		list.append(origin)
	return is_new


func _collect_by_ext(dir_path: String, ext: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = d.get_next()
			continue
		var full := dir_path.path_join(entry)
		if d.current_is_dir():
			if not _should_skip_dir(entry):
				out.append_array(_collect_by_ext(full, ext))
		elif entry.get_extension().to_lower() == ext:
			out.append(full)
		entry = d.get_next()
	d.list_dir_end()
	return out


# --- 判定 ---------------------------------------------------------------------

# 被引用却不存在的文件。这是 A1 的核心判定：资源被移走时必须红。
func _check_missing() -> void:
	for path in _refs:
		var p := str(path)
		# .import 是导入产物的元数据，引用形态特殊，交给引擎自己管。
		if p.ends_with(".import"):
			continue
		if FileAccess.file_exists(p) or DirAccess.dir_exists_absolute(p):
			continue
		_missing[p] = _refs[p]
	for path in _missing:
		var origins: Array = _missing[path]
		_h.fail("missing_asset", "%s 不存在，被 %d 处引用：%s" % [
			str(path), origins.size(), _join_head(origins, 3)])


func _check_dependency_failures() -> void:
	for path in _dep_failed:
		_h.fail("dependency_query_failed",
			"%s 依赖查询失败，其依赖未计入清单（会把在用的文件误判成没用）" % path)


# --- 构建清单条目 -------------------------------------------------------------

func _build_entries() -> Array:
	var out: Array = []
	var progress := 0
	for path in _files:
		progress += 1
		if progress % 500 == 0:
			print("[%s] hash 进度 %d/%d" % [CHECK_NAME, progress, _files.size()])
		_h.item()
		var origins: Array = _refs.get(path, [])
		var info := _hash_file(path)
		out.append({
			"path": path,
			"type": path.get_extension().to_lower(),
			"size": int(info.get("size", 0)),
			"sha256": str(info.get("sha256", "")),
			"required_by": _join_head(origins, 5),
			"required_by_count": origins.size(),
			"class": _classify(path, origins),
			"license_id": "unknown",
		})
	out.sort_custom(func(a, b): return str(a["path"]) < str(b["path"]))
	return out


func _classify(path: String, origins: Array) -> String:
	if path.ends_with(".import"):
		return "import_meta"
	if path.begins_with("res://effects/vfx3d/vfxv2"):
		return "third_party"
	if path.contains("/backups/") or path.contains(".bak"):
		return "backup"
	if origins.is_empty():
		for d in DYNAMIC_DIRS:
			if path.begins_with(d):
				return "dynamic_dir"
		return "unreferenced"
	var all_editor := true
	for o in origins:
		var is_editor := false
		for prefix in EDITOR_ONLY_PREFIXES:
			if str(o).begins_with(prefix):
				is_editor = true
				break
		if not is_editor:
			all_editor = false
			break
	return "editor_only" if all_editor else "runtime_required"


# --- 哈希（带 path+size+mtime 缓存）-------------------------------------------

func _hash_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_h.fail("unreadable_file", "%s 无法读取（%d）" % [path, FileAccess.get_open_error()])
		return {"size": 0, "sha256": ""}
	var size := int(f.get_length())
	var mtime := int(FileAccess.get_modified_time(path))

	var cached: Variant = _cache.get(path)
	if cached is Dictionary:
		var c: Dictionary = cached
		if int(c.get("size", -1)) == size and int(c.get("mtime", -1)) == mtime:
			f.close()
			_cache_hits += 1
			return {"size": size, "sha256": str(c.get("sha256", ""))}

	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while not f.eof_reached():
		ctx.update(f.get_buffer(HASH_CHUNK))
	f.close()
	var digest := ctx.finish().hex_encode()
	_cache[path] = {"size": size, "mtime": mtime, "sha256": digest}
	return {"size": size, "sha256": digest}


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


# --- 输出 ---------------------------------------------------------------------

func _write_manifest(entries: Array) -> void:
	var by_class: Dictionary = {}
	var total_size := 0
	var inventory_sha256 := _inventory_digest(entries)
	for e in entries:
		var c := str((e as Dictionary)["class"])
		by_class[c] = int(by_class.get(c, 0)) + 1
		total_size += int((e as Dictionary)["size"])

	var doc := {
		"schema_version": MANIFEST_SCHEMA_VERSION,
		"inventory_sha256": inventory_sha256,
		"generated_by": "tools/asset_manifest_check.gd",
		"generated_at": Time.get_datetime_string_from_system(true),
		"godot_version": Engine.get_version_info().get("string", ""),
		"roots": INVENTORY_ROOTS,
		"file_count": entries.size(),
		"total_bytes": total_size,
		"by_class": by_class,
		"missing_count": _missing.size(),
		"dependency_query_failed": _dep_failed,
		"entries": entries,
	}
	var f := FileAccess.open(MANIFEST_PATH, FileAccess.WRITE)
	if f == null:
		_h.fail("manifest_write_failed", "无法写入 %s" % MANIFEST_PATH)
		return
	f.store_string(JSON.stringify(doc, "  "))
	f.close()
	print("[%s] 已写出 %s（%d 条，%.1f MiB，inventory=%s）" % [
		CHECK_NAME, MANIFEST_PATH, entries.size(), total_size / 1048576.0, inventory_sha256])


func _write_doc(entries: Array) -> void:
	var by_class: Dictionary = {}
	var size_by_class: Dictionary = {}
	var inventory_sha256 := _inventory_digest(entries)
	for e in entries:
		var c := str((e as Dictionary)["class"])
		by_class[c] = int(by_class.get(c, 0)) + 1
		size_by_class[c] = int(size_by_class.get(c, 0)) + int((e as Dictionary)["size"])

	var lines: Array[String] = []
	lines.append("# 资产清单（自动生成，勿手改）")
	lines.append("")
	lines.append("生成者：`tools/asset_manifest_check.gd`　生成时间：%s　Godot：%s"
		% [Time.get_datetime_string_from_system(true), Engine.get_version_info().get("string", "")])
	lines.append("")
	lines.append("清单协议：`schema_version=%d`　稳定库存指纹：`%s`" % [
		MANIFEST_SCHEMA_VERSION, inventory_sha256])
	lines.append("")
	lines.append("机读版本在 `assets.manifest.json`，A2 用它在新机器上校验资源恢复结果。")
	lines.append("")
	lines.append("## 分类汇总")
	lines.append("")
	lines.append("| 分类 | 文件数 | 体积 | 含义 |")
	lines.append("| --- | ---: | ---: | --- |")
	var meaning := {
		"runtime_required": "正式运行会加载，必须进发布包",
		"editor_only": "只被 tools/ 或 scenes/debug/ 引用，不必进发布包",
		"dynamic_dir": "代码运行时按目录拼路径，静态查不到引用，一律保留",
		"third_party": "外部参考包，发布前必须有许可证（C1/A5）",
		"backup": "备份副本，不应进运行仓库（A5）",
		"import_meta": "Godot 导入元数据，由引擎生成",
		"unreferenced": "任何静态引用都查不到，可评估删除",
	}
	for c in ["runtime_required", "dynamic_dir", "editor_only", "third_party", "backup", "import_meta", "unreferenced"]:
		if not by_class.has(c):
			continue
		lines.append("| `%s` | %d | %.1f MiB | %s |" % [
			c, int(by_class[c]), int(size_by_class[c]) / 1048576.0, str(meaning.get(c, ""))])
	lines.append("")
	lines.append("## 判定结果")
	lines.append("")
	lines.append("- 被引用但不存在的文件：**%d**" % _missing.size())
	lines.append("- 依赖查询失败的资源：**%d**" % _dep_failed.size())
	if not _missing.is_empty():
		lines.append("")
		lines.append("### 缺失明细")
		lines.append("")
		for path in _missing:
			lines.append("- `%s` ← %s" % [str(path), _join_head(_missing[path], 3)])
	if not _dep_failed.is_empty():
		lines.append("")
		lines.append("### 依赖查询失败明细")
		lines.append("")
		for path in _dep_failed:
			lines.append("- `%s`" % path)
	lines.append("")
	lines.append("## 未被引用的文件（可评估删除）")
	lines.append("")
	var unref: Array[String] = []
	for e in entries:
		if str((e as Dictionary)["class"]) == "unreferenced":
			unref.append(str((e as Dictionary)["path"]))
	if unref.is_empty():
		lines.append("（无）")
	else:
		for p in unref:
			lines.append("- `%s`" % p)
	lines.append("")
	lines.append("## 许可证")
	lines.append("")
	lines.append("所有条目的 `license_id` 当前均为 `unknown`。A5/C1 必须为每个 "
		+ "`third_party` 与可发布资源补齐来源、作者、许可证与原始链接，并写入 `THIRD_PARTY_NOTICES.md`。")
	lines.append("")

	var f := FileAccess.open(DOC_PATH, FileAccess.WRITE)
	if f == null:
		_h.fail("doc_write_failed", "无法写入 %s" % DOC_PATH)
		return
	f.store_string("\n".join(lines))
	f.close()
	print("[%s] 已写出 %s" % [CHECK_NAME, DOC_PATH])


# A2 的稳定库存身份。generated_at、Godot 版本、引用说明等报告元数据不参与，
# 所以相同 path/size/content/class 在不同机器和不同时间生成相同指纹。
# entries 在 _build_entries() 已按 path 排序；这里再次排序，避免将来调用方改动顺序。
func _inventory_digest(entries: Array) -> String:
	var ordered := entries.duplicate()
	ordered.sort_custom(func(a, b): return str(a.get("path", "")) < str(b.get("path", "")))
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for value in ordered:
		var entry: Dictionary = value
		var line := "%s\t%d\t%s\t%s\n" % [
			str(entry.get("path", "")),
			int(entry.get("size", 0)),
			str(entry.get("sha256", "")).to_lower(),
			str(entry.get("class", "")),
		]
		ctx.update(line.to_utf8_buffer())
	return ctx.finish().hex_encode()


func _join_head(values: Array, limit: int) -> String:
	var head: Array[String] = []
	for i in mini(limit, values.size()):
		head.append(str(values[i]))
	if values.size() > limit:
		head.append("...(+%d)" % (values.size() - limit))
	return ", ".join(head)
