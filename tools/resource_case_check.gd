extends Node

# V2 P0-02：res:// 引用的大小写必须和磁盘真实条目逐段一致。
#
# 为什么需要它：Windows 和 macOS 的文件系统大小写不敏感，Linux 和 Android 敏感。
# 写成 res://Assets/Foo.png 而磁盘上是 assets/foo.png，在开发机上一切正常，  # asset-manifest-ignore
# 到真机上就是 "Failed loading resource"。本项目要出 Android 包，这一整类 bug
# 目前没有任何门禁能抓到 —— 连 asset_manifest_check 也抓不到，因为它用
# FileAccess.file_exists()，在 Windows 上那会对大小写错误的路径返回 true。
#
# 职责边界（与 asset_manifest_check 划清，避免同一个 bug 点亮两个红灯）：
#   精确命中                  -> PASS
#   大小写不敏感能唯一找到    -> case_mismatch，本检查判 FAIL
#   完全找不到                -> missing_delegated，只记数与 NOTE，
#                                判红的责任归 asset_manifest_check/missing_asset
#   同目录 case-fold 冲突     -> case_collision，本检查判 FAIL
#
# 实现要点：解析逻辑写成纯函数 `resolve_case(path, lister)`，目录枚举由调用方注入。
# 真实运行注入 DirAccess，自检注入合成目录树 —— 于是「大小写错误会不会被抓到」
# 这件事本身可以被永久、可重复地验证，而不是靠临时造一个坏文件再删掉。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const CHECK_NAME := "resource_case"

const SCAN_EXTENSIONS: PackedStringArray = ["gd", "tscn", "tres"]

# 不扫描的目录名。归档/证据目录另有 .gdignore，由 _dir_is_gdignored() 统一跳过。
const SKIP_DIR_NAMES: PackedStringArray = [
	".godot", ".git", "android", "backups", "captures", "reports", "__pycache__",
]

# 与 asset_manifest_check 共用同一个行内标记，不另发明一套约定。
const IGNORE_MARKER := "asset-manifest-ignore"

const REPORT_PATH := "res://reports/resource_case_check.json"  # asset-manifest-ignore

# 自检与探针里的路径都用它拼，不写成完整字面量。
#
# 否则本检查扫到自己头上时，会把 self-test 表里那 13 条合成路径和探针那条故意写错
# 大小写的路径全部当成真实引用报出来 —— 探针那条甚至会让检查自己判红。
# 用前缀拼接是最干净的解法：既不用给自己开特例，也不用往每行挂忽略标记。
# 单独的 "res://" 长度不超过前缀本身，_refs_in_line() 会跳过。
const RES := "res://"

# 明显不是路径的语法字符。工具脚本里有大量用 res:// 拼出来的**正则**与**格式串**
# （`res://[^\`、`res://assets/models/%s`、`res://\\.godot/imported/[^\`），
# 它们不是资源引用，报出来只会淹掉真实结果。
const NON_PATH_CHARS: PackedStringArray = ["%", "[", "]", "^", "\\", "*", "?", "$", "{", "}", "|"]

var _h: RefCounted
# 目录 -> 该目录下的真实条目名。2301 条引用逐段解析，不缓存的话会把同一个
# 目录枚举上千次。
var _dir_entries_cache: Dictionary = {}
var _missing_delegated: Array[Dictionary] = []
var _case_mismatch: Array[Dictionary] = []
var _case_collision: Array[Dictionary] = []
var _scanned_files := 0
var _references := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)

	# 先自检解析器。合成目录树喂进去，四类判定都要走到 ——
	# 解析器坏了的话，后面对真实仓库跑出来的绿是没有意义的。
	_self_test_resolver()
	# 再确认注入 DirAccess 之后在这台机器上确实拿得到真实大小写。
	# 整个检查的前提就是这一条；前提不成立时必须红，而不是安静地全绿。
	_probe_live_filesystem()

	var files := _collect_files("res://")
	_h.expect(files.size() > 100, "too_few_files",
		"只扫到 %d 个 .gd/.tscn/.tres —— 扫描路径或跳过规则多半配错了" % files.size())

	for path_value in files:
		_scan_file(str(path_value))

	_check_case_fold_collisions()
	_report()
	_h.finish(get_tree())


# --- 纯解析逻辑（自检与真实运行共用）------------------------------------------

# 逐段核对 res:// 路径的大小写。
#
# lister: Callable(dir_path: String) -> PackedStringArray，返回该目录下的真实条目名
#         （文件与子目录都要，不含 "." 与 ".."）。目录不存在时返回空数组。
#
# 返回 {"status": "exact"|"case_mismatch"|"missing", "actual": String}
# actual 在 case_mismatch 时是磁盘上的真实路径，其余情况为空串。
static func resolve_case(path: String, lister: Callable) -> Dictionary:
	if not path.begins_with("res://"):
		return {"status": "missing", "actual": ""}
	var rest := path.substr(6)
	if rest.is_empty():
		return {"status": "exact", "actual": path}

	var current := "res://"
	var actual := "res://"
	var drifted := false
	var segments := rest.split("/")
	for i in segments.size():
		var segment := str(segments[i])
		if segment.is_empty():
			continue
		var entries: PackedStringArray = lister.call(actual)
		if segment in entries:
			# 精确命中这一段。
			actual = _join(actual, segment)
			current = _join(current, segment)
			continue
		# 大小写不敏感地找唯一匹配。找到多个说明目录里有 case-fold 冲突，
		# 这种情况下"真实路径"本身就是二义的，按 missing 处理并由冲突检查报红。
		var matches: PackedStringArray = []
		var lowered := segment.to_lower()
		for entry_value in entries:
			if str(entry_value).to_lower() == lowered:
				matches.append(str(entry_value))
		if matches.size() != 1:
			return {"status": "missing", "actual": ""}
		drifted = true
		actual = _join(actual, str(matches[0]))
		current = _join(current, segment)

	if drifted:
		return {"status": "case_mismatch", "actual": actual}
	return {"status": "exact", "actual": actual}


static func _join(base: String, segment: String) -> String:
	if base.ends_with("/"):
		return base + segment
	return base + "/" + segment


# --- 自检 ---------------------------------------------------------------------

# 合成目录树驱动的永久自检。Codex 的交接建议临时造一个坏文件再删掉；改成这样是因为
# 删掉之后就不可重复了 —— 下次谁把扫描逻辑改坏，没有任何东西会发现。
func _self_test_resolver() -> void:
	var tree := {
		RES: PackedStringArray(["assets", "scenes", "Mixed"]),
		RES + "assets": PackedStringArray(["models", "icon.png"]),
		RES + "assets/models": PackedStringArray(["hero.tscn"]),
		RES + "scenes": PackedStringArray(["main"]),
		RES + "scenes/main": PackedStringArray(["Main.tscn"]),
		# 同一目录里 case-fold 冲突：解析必然二义。
		RES + "Mixed": PackedStringArray(["Thing.tres", "thing.tres"]),
	}
	var lister := func(dir_path: String) -> PackedStringArray:
		return tree.get(dir_path, PackedStringArray())

	var cases := [
		# 完全一致
		{"path": RES + "assets/models/hero.tscn", "want": "exact"},
		{"path": RES + "scenes/main/Main.tscn", "want": "exact"},
		# 末段大小写错
		{"path": RES + "assets/models/Hero.tscn", "want": "case_mismatch",
			"actual": RES + "assets/models/hero.tscn"},
		# 中间目录大小写错
		{"path": RES + "Assets/models/hero.tscn", "want": "case_mismatch",
			"actual": RES + "assets/models/hero.tscn"},
		# 多段同时错
		{"path": RES + "ASSETS/MODELS/HERO.TSCN", "want": "case_mismatch",
			"actual": RES + "assets/models/hero.tscn"},
		# 真的不存在
		{"path": RES + "assets/models/nope.tscn", "want": "missing"},
		{"path": RES + "nosuchdir/x.png", "want": "missing"},
		# case-fold 冲突目录：不唯一，按 missing 处理，由冲突检查单独报红
		{"path": RES + "Mixed/thing.tres", "want": "exact"},
		{"path": RES + "Mixed/THING.tres", "want": "missing"},
	]

	for case_value in cases:
		var case_dict: Dictionary = case_value
		var path := str(case_dict["path"])
		var got: Dictionary = resolve_case(path, lister)
		var want := str(case_dict["want"])
		if not _h.expect(str(got.get("status", "")) == want,
				"selftest_status",
				"自检：%s 应判 %s，实际 %s" % [path, want, str(got.get("status", ""))]):
			continue
		if case_dict.has("actual"):
			_h.expect(str(got.get("actual", "")) == str(case_dict["actual"]),
				"selftest_actual",
				"自检：%s 的真实路径应为 %s，实际 %s"
					% [path, str(case_dict["actual"]), str(got.get("actual", ""))])


# 自检用的是合成目录树，证明的是逻辑对。这里证明另一半：注入真实 DirAccess 之后，
# 这台机器上确实能拿到磁盘的真实大小写。Windows 大小写不敏感，如果 DirAccess 回吐的
# 是调用方传进去的拼写而不是磁盘上的名字，整个检查就会永远全绿而什么都没测。
func _probe_live_filesystem() -> void:
	var lister := func(dir_path: String) -> PackedStringArray:
		return _list_dir(dir_path)

	var self_path := RES + "tools/resource_case_check.gd"
	var exact: Dictionary = resolve_case(self_path, lister)
	_h.expect(str(exact.get("status", "")) == "exact",
		"live_probe_exact",
		"真实文件系统探针：%s 应判 exact，实际 %s —— 目录枚举没能拿到真实条目"
			% [self_path, str(exact.get("status", ""))])

	# 同一个文件、故意写错大小写：必须被判成 case_mismatch。
	# 这是"门禁不是假绿"在真实文件系统上的证明，不需要往仓库里塞坏文件。
	var wrong := RES + "Tools/Resource_Case_Check.gd"
	var drifted: Dictionary = resolve_case(wrong, lister)
	_h.expect(str(drifted.get("status", "")) == "case_mismatch",
		"live_probe_mismatch",
		"真实文件系统探针：%s 应判 case_mismatch，实际 %s —— 大小写漂移抓不出来，本检查等于假绿"
			% [wrong, str(drifted.get("status", ""))])
	_h.expect(str(drifted.get("actual", "")) == self_path,
		"live_probe_actual",
		"真实文件系统探针：真实路径应为 %s，实际 %s" % [self_path, str(drifted.get("actual", ""))])


# --- 目录枚举 -----------------------------------------------------------------

func _list_dir(dir_path: String) -> PackedStringArray:
	if _dir_entries_cache.has(dir_path):
		return _dir_entries_cache[dir_path]
	var out: PackedStringArray = []
	var dir := DirAccess.open(dir_path)
	if dir != null:
		for name_value in dir.get_directories():
			out.append(str(name_value))
		for name_value in dir.get_files():
			out.append(str(name_value))
	_dir_entries_cache[dir_path] = out
	return out


func _dir_is_gdignored(dir_path: String) -> bool:
	return FileAccess.file_exists(_join(dir_path, ".gdignore"))


func _collect_files(root: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var pending: Array[String] = [root]
	while not pending.is_empty():
		var dir_path: String = pending.pop_back()
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		for name_value in dir.get_directories():
			var name := str(name_value)
			if name.begins_with("."):
				continue
			if SKIP_DIR_NAMES.has(name):
				continue
			var child := _join(dir_path, name)
			if _dir_is_gdignored(child):
				continue
			pending.append(child)
		for file_value in dir.get_files():
			var file_name := str(file_value)
			if SCAN_EXTENSIONS.has(file_name.get_extension().to_lower()):
				out.append(_join(dir_path, file_name))
	out.sort()
	return out


# --- 扫描 ---------------------------------------------------------------------

func _scan_file(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return
	_scanned_files += 1
	var is_script := path.get_extension().to_lower() == "gd"
	var lister := func(dir_path: String) -> PackedStringArray:
		return _list_dir(dir_path)

	var seen_in_file := {}
	var line_no := 0
	for raw_line in text.split("\n"):
		line_no += 1
		var line := str(raw_line)
		if line.contains(IGNORE_MARKER):
			continue
		if is_script:
			# 注释里的 res:// 只是文字。按第一个 # 截断：字符串字面量里含 # 时
			# 会提前截断，那只会让扫描漏掉某条引用，不会造出误报。
			var hash_at := line.find("#")
			if hash_at >= 0:
				line = line.substr(0, hash_at)
		for ref_value in _refs_in_line(line):
			var ref := str(ref_value)
			var key := "%d|%s" % [line_no, ref]
			if seen_in_file.has(key):
				continue
			seen_in_file[key] = true
			_references += 1
			var verdict: Dictionary = resolve_case(ref, lister)
			var status := str(verdict.get("status", ""))
			if status == "exact":
				_h.item()
				continue
			var record := {
				"source": path,
				"line": line_no,
				"written": ref,
				"actual": str(verdict.get("actual", "")),
			}
			if status == "case_mismatch":
				_case_mismatch.append(record)
				_h.fail("case_mismatch",
					"%s:%d 写的是 %s，磁盘上是 %s —— Windows 能跑，Android/Linux 会加载失败"
						% [path, line_no, ref, str(verdict.get("actual", ""))])
			else:
				# 交给 asset_manifest_check 判红，这里只记数。
				_missing_delegated.append(record)
				_h.item()


# 取出一行里的 res:// 引用。剥掉 ::子资源 后缀与常见的包裹字符。
func _refs_in_line(line: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var from := 0
	while true:
		var at := line.find("res://", from)
		if at < 0:
			break
		var end := at
		while end < line.length():
			var ch := line.substr(end, 1)
			if ch in ["\"", "'", " ", "\t", ")", "]", ",", ">"]:
				break
			end += 1
		var ref := line.substr(at, end - at)
		from = maxi(end, at + 6)
		# 子资源：res://a.tscn::Node -> res://a.tscn  # asset-manifest-ignore
		var sub := ref.find("::")
		if sub >= 0:
			ref = ref.substr(0, sub)
		ref = ref.rstrip("/.")
		if ref.length() <= RES.length() or out.has(ref):
			continue
		if _looks_like_pattern(ref):
			continue
		out.append(ref)
	return out


# 工具脚本里大量出现用 res:// 拼出来的正则与格式串，它们不是资源引用。
# 判据是"路径里不可能出现的语法字符"，宁可漏也不误报：漏掉一条真实引用只是少测一处，
# 把 `res://assets/models/%s` 报成缺失则会淹掉真实结果、让人不再看这份报告。
func _looks_like_pattern(ref: String) -> bool:
	for ch in NON_PATH_CHARS:
		if ref.contains(str(ch)):
			return true
	return false


# 同一目录里两个条目只差大小写：在大小写不敏感的文件系统上它们无法共存，
# 一旦有人在 Linux 上提交了这种组合，Windows/macOS 检出时会静默丢一个。
func _check_case_fold_collisions() -> void:
	for dir_path in _dir_entries_cache.keys():
		var entries: PackedStringArray = _dir_entries_cache[dir_path]
		var by_lower := {}
		for entry_value in entries:
			var entry := str(entry_value)
			var lowered := entry.to_lower()
			if by_lower.has(lowered):
				var record := {
					"dir": str(dir_path),
					"a": str(by_lower[lowered]),
					"b": entry,
				}
				_case_collision.append(record)
				_h.fail("case_collision",
					"%s 下同时存在只差大小写的 %s 与 %s —— 大小写不敏感的机器上会丢一个"
						% [str(dir_path), str(by_lower[lowered]), entry])
				continue
			by_lower[lowered] = entry


# --- 输出 ---------------------------------------------------------------------

func _report() -> void:
	_h.note("扫描 %d 个文件、%d 条 res:// 引用；目录缓存 %d 项"
		% [_scanned_files, _references, _dir_entries_cache.size()])
	_h.note("大小写漂移 %d，case-fold 冲突 %d，找不到 %d（后者交由 asset_manifest_check 判红）"
		% [_case_mismatch.size(), _case_collision.size(), _missing_delegated.size()])
	if not _missing_delegated.is_empty():
		var shown := mini(5, _missing_delegated.size())
		for i in shown:
			var record: Dictionary = _missing_delegated[i]
			_h.note("  missing_delegated %s:%d %s"
				% [str(record["source"]), int(record["line"]), str(record["written"])])
		if _missing_delegated.size() > shown:
			_h.note("  …另有 %d 条，完整列表见 %s"
				% [_missing_delegated.size() - shown, REPORT_PATH])

	# 排序后再写，保证两次运行产出逐字节一致。
	var payload := {
		"schema_version": 1,
		"generated_utc": Time.get_datetime_string_from_system(true),
		"scanned_files": _scanned_files,
		"references": _references,
		"case_mismatch": _sorted_records(_case_mismatch),
		"case_collision": _case_collision.duplicate(true),
		"missing_delegated": _sorted_records(_missing_delegated),
		"note": "missing_delegated 不由本检查判红；缺失引用的门禁是 asset_manifest_check/missing_asset。",
	}
	var dir := DirAccess.open("res://")
	if dir != null and not dir.dir_exists("reports"):
		dir.make_dir("reports")
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t", false))
		file.close()


func _sorted_records(records: Array) -> Array:
	var copy := records.duplicate(true)
	copy.sort_custom(func(a, b):
		var ka := "%s|%06d|%s" % [str(a["source"]), int(a["line"]), str(a["written"])]
		var kb := "%s|%06d|%s" % [str(b["source"]), int(b["line"]), str(b["written"])]
		return ka < kb)
	return copy
