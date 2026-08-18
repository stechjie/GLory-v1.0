extends Node

# 权威依赖扫描：哪些 assets/ 里的 PNG 真的没人用。
#
# 为什么不能用 grep 文件名：FBX 引用贴图的方式不是明文字符串，`.tscn` 也可能
# 只带 `uid://` 不带路径。之前用字符串搜索判定，把水晶正在用的 46 MB 贴图当成
# 「零引用」搬走，模型直接加载失败。
#
# 这里改用 ResourceLoader.get_dependencies()：拿的是**引擎自己解析出来的**依赖，
# 无论对方用路径、uid 还是 FBX 内部格式引用，都能拿到。递归展开（场景 -> 材质 ->
# 贴图），并额外扫 .gd 里写死的 res:// 字面量（脚本里的 load() 不是资源依赖，
# get_dependencies 看不到）。
#
# 运行：Godot --headless --path . tools/dep_scan.tscn
# 只出报告，不动任何文件。

# 代码用目录常量在运行时拼路径的地方 —— 单个文件名不出现在任何地方，
# 所以「没找到引用」对这些目录完全没有说服力，一律视为在用。
# 来源：grep 'res://assets/<dir>/' 的全部命中。
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

# 会被 get_dependencies 问到的类型。.fbx/.glb 是源文件，Godot 会把它们的贴图
# 依赖记在导入产物上，两边都要问。
const RESOURCE_EXT := ["tscn", "scn", "tres", "res", "material", "mesh",
	"fbx", "glb", "gltf", "obj", "gdshader"]
const OUT_PATH := "user://dep_scan_report.txt"

const CheckHarness := preload("res://tools/CheckHarness.gd")
const CHECK_NAME := "dep_scan"

var _h: CheckHarness

var _all_png: Array[String] = []
var _referenced: Dictionary = {}      # res:// 路径 -> 第一个引用者
var _visited: Dictionary = {}
var _lines: Array[String] = []
# 查依赖失败的资源。静默跳过等于凭空少算依赖，上次就是这样把在用的文件判成没用。
var _failed: Array[String] = []

func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_say("=== Glory 依赖扫描 ===")
	_collect_png("res://assets")
	_say("assets/ 下 PNG 总数: %d" % _all_png.size())
	# 一张都没扫到 = 什么都没验证。留给 harness 判成 SKIP（非零退出），
	# 而不是让"0 张未引用"读起来像全过。
	_h.item(_all_png.size())

	var roots := _collect_resource_files("res://")
	_say("待问依赖的资源文件: %d" % roots.size())
	for r in roots:
		_walk(r, r)

	var script_hits := _scan_script_literals()
	_say("脚本字面量里额外命中: %d" % script_hits)
	_say("被引用到的 PNG: %d" % _referenced.size())

	_report()
	_flush()
	_h.finish(get_tree())

# --- 收集 ---------------------------------------------------------------------

func _collect_png(dir_path: String) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name.begins_with("."):
			name = d.get_next()
			continue
		var full := dir_path.path_join(name)
		if d.current_is_dir():
			_collect_png(full)
		elif name.to_lower().ends_with(".png"):
			_all_png.append(full)
		name = d.get_next()
	d.list_dir_end()

func _collect_resource_files(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name.begins_with("."):
			name = d.get_next()
			continue
		var full := dir_path.path_join(name)
		if d.current_is_dir():
			# backups/ 里的旧副本引用了什么不代表当前还在用。
			if name != "backups" and name != "android":
				out.append_array(_collect_resource_files(full))
		else:
			var ext := name.get_extension().to_lower()
			if RESOURCE_EXT.has(ext):
				out.append(full)
		name = d.get_next()
	d.list_dir_end()
	return out

# --- 递归展开依赖 -------------------------------------------------------------

func _walk(path: String, origin: String, depth: int = 0) -> void:
	if depth > 12 or _visited.has(path):
		return
	_visited[path] = true
	# get_dependencies 返回形如 "Type::uid://xxx::res://real/path" 或 "Type::res://path"，
	# 取最后一段就是真实路径。
	var deps := ResourceLoader.get_dependencies(path)
	# 空结果分两种：真的没依赖，和读取失败（引擎会往 stderr 吐 Method/function failed）。
	# 后者必须记下来 —— 少算的依赖会让在用的文件被判成没用。
	if deps.is_empty() and not ResourceLoader.exists(path):
		_failed.append(path)
	for raw in deps:
		var dep := str(raw)
		var parts := dep.split("::")
		var target := str(parts[parts.size() - 1])
		if not target.begins_with("res://"):
			continue
		if target.to_lower().ends_with(".png"):
			if not _referenced.has(target):
				_referenced[target] = origin
			continue
		_walk(target, origin, depth + 1)

# --- 脚本里写死的路径 ---------------------------------------------------------

func _scan_script_literals() -> int:
	var hits := 0
	var re := RegEx.create_from_string("res://assets/[A-Za-z0-9_./-]+?\\.png")
	for gd in _collect_by_ext("res://", "gd"):
		var f := FileAccess.open(gd, FileAccess.READ)
		if f == null:
			continue
		var text := f.get_as_text()
		f.close()
		for m in re.search_all(text):
			var p := m.get_string()
			if not _referenced.has(p):
				_referenced[p] = gd
				hits += 1
	return hits

func _collect_by_ext(dir_path: String, ext: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name.begins_with("."):
			name = d.get_next()
			continue
		var full := dir_path.path_join(name)
		if d.current_is_dir():
			if name != "backups" and name != "android":
				out.append_array(_collect_by_ext(full, ext))
		elif name.get_extension().to_lower() == ext:
			out.append(full)
		name = d.get_next()
	d.list_dir_end()
	return out

# --- 报告 ---------------------------------------------------------------------

func _report() -> void:
	var unused: Array[String] = []
	var dynamic: Array[String] = []
	for p in _all_png:
		if _referenced.has(p):
			continue
		if _in_dynamic_dir(p):
			dynamic.append(p)
		else:
			unused.append(p)

	_say("")
	_say("--- 无法判定（运行时按目录拼路径，一律保留）: %d 张, %.1f MB ---"
		% [dynamic.size(), _mb(dynamic)])
	_say_dirs(dynamic)
	_say("")
	_say("--- 引擎依赖图里查不到任何引用: %d 张, %.1f MB ---"
		% [unused.size(), _mb(unused)])
	_say_dirs(unused)
	_say("")
	_say("完整清单（可安全审阅后处理的那部分）:")
	unused.sort()
	for p in unused:
		_say("  %s" % p)

	# 交叉验证用上次事故的已知答案：移走 _texture_0.png 时 Godot 报的是
	# "Can't load dependency: ..._texture_0.png"，所以 texture_0 必须被认出来。
	# （不能拿「11 张全在用」当标准 —— 实测 FBX 只引用 texture_0/1/2，
	# 其余 8 张是 Meshy 导出的副产物，从来没人引用。）
	_say("")
	_say("--- 自检：上次事故点名的依赖必须被认出来 ---")
	var must_find: Array[String] = []
	for p in _all_png:
		if p.contains("battle_crystals") and p.ends_with("_texture_0.png"):
			must_find.append(p)
	var ok := true
	for p in must_find:
		if _referenced.has(p):
			_say("  ✅ 认出 %s\n       引用者: %s" % [p.get_file(), _referenced[p]])
		else:
			ok = false
			_say("  ❌ 漏掉 %s —— 这套方法不能用来删文件" % p)
	if must_find.is_empty():
		_say("  ⚠️ 没找到基准文件，自检无效")
		# 自检失效时整份报告都不该被信任，更不能拿它去删文件。
		_h.fail("selfcheck_no_baseline", "没找到 battle_crystals 基准贴图，依赖解析方法未经验证")
	elif not ok:
		_h.fail("selfcheck_failed", "基准贴图未被认出，依赖解析方法不可用于删除判定")
	else:
		_say("  → 方法有效：FBX 的贴图依赖能被正确解析")

	if not _failed.is_empty():
		_say("")
		_say("--- ⚠️ 查依赖失败的资源: %d 个（它们的依赖没被计入，下面的清单对相关文件不可信）---"
			% _failed.size())
		for p in _failed:
			_say("  %s" % p)
			# 原来这里只打印。少算的依赖会把在用的文件判成没用 ——
			# 上次正是这样把水晶在用的 46 MB 贴图搬走导致模型加载失败。
			_h.fail("dependency_query_failed", "%s 依赖查询失败，其依赖未计入清单" % str(p))

func _in_dynamic_dir(p: String) -> bool:
	for d in DYNAMIC_DIRS:
		if p.begins_with(d + "/"):
			return true
	return false

func _mb(list: Array) -> float:
	var total := 0
	for p in list:
		var f := FileAccess.open(str(p), FileAccess.READ)
		if f != null:
			total += f.get_length()
			f.close()
	return float(total) / 1048576.0

func _say_dirs(list: Array) -> void:
	var per: Dictionary = {}
	for p in list:
		var d := str(p).get_base_dir()
		per[d] = int(per.get(d, 0)) + 1
	var keys := per.keys()
	keys.sort()
	for k in keys:
		_say("  %-72s %d 张" % [k, int(per[k])])

func _say(s: String) -> void:
	print(s)
	_lines.append(s)

func _flush() -> void:
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("\n".join(_lines))
	f.close()
	print("")
	print("报告已写入: %s" % ProjectSettings.globalize_path(OUT_PATH))
