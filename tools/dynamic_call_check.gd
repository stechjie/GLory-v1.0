extends Node

# 守「按名字调用的方法，那个方法真的存在」。
#
# 起因（同一个坑已经踩了两次）：
#
#   1. D2 改名时漏了 scripts/tutorial/TutorialMode.gd 里 15 处 _prep.get("...")，
#      进教学第一关直接崩（"Nonexistent 'bool' constructor"）。
#   2. D2 第二步把 _can_drop_on_board 搬进 PrepRules 后，PrepShared 的内部类里
#      还留着 `screen.has_method("_can_drop_on_board") and screen._can_drop_on_board(...)`。
#      **has_method 返回 false，于是拖放静默全部失效** —— 编译期一句话不报，
#      运行时也不报，表现只是「东西拖不动」。
#
# 静态类型的调用编译器会管；**按名字的调用编译器一概不管**：
#   obj.call("foo", ...)          方法没了 → 运行时报错（还算响）
#   obj.has_method("foo") and ... 方法没了 → 静默走 false 分支（最危险）
#   Callable(obj, "foo")          方法没了 → 连接时才发现
#
# 这条检查扫全仓源码，把这三种写法里的方法名收集起来，
# 再去被调用方的脚本里确认该方法确实存在。
#
# 只查「接收者能静态确定」的情况：
#   * self.call("x") / call("x")            → 本文件（含其 extends 链）
#   * <成员/局部变量>.has_method("x")        → 该变量声明的类型
# 查不出接收者类型的，登记为 unresolved 并打印，不算失败 ——
# 但数量会被钉住，防止有人靠「让接收者变模糊」来绕过这条检查。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/dynamic_call_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "dynamic_call"

# 扫描根目录。备份目录一律跳过（里面是过期副本，见 docs/CHECKS.md 4.7）。
# assets/ 必须包含：模型包装脚本（play_idle / play_attack / play_run）就定义在那里。
# 第一版漏了它，于是 BattleRenderer 的动作调用被全判成「方法不存在」—— 那是误报，
# 不是产品坏了。教训：断言「全仓没有这个名字」之前，先确认「全仓」真的是全仓。
const ROOTS := ["res://scenes", "res://scripts", "res://tools", "res://effects", "res://assets"]
const SKIP_DIR_PATTERNS := ["*_prechange_backup_*", "*_backup_2*", "D?_*_20*", "E?_*_20*"]

# 无法静态确定接收者的调用处数**棘轮**：当前实测 213，只许降不许升。
# 这类调用编译器一概管不到 —— 方法搬走 / 改名时它们不会报错，
# 用 has_method 保护的还会**静默走 false 分支**（拖放整个失效就是这么来的）。
# 调高这个数字等于承认又多了一处这种调用，改之前先想清楚能不能写成静态调用。
const MAX_UNRESOLVED := 189

var _h: CheckHarness
var _files: Array[String] = []
var _methods_by_file := {}      # 文件 -> 该文件（含继承链）定义的方法名集合
var _extends_of := {}           # 文件 -> 父脚本路径（res:// 形式，无则空）
var _unresolved := 0
var _all_methods := {}      # 全仓任何脚本定义过的方法名


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	for root in ROOTS:
		_collect(root)
	if not _h.expect(_files.size() > 50, "too_few_files",
			"只扫到 %d 个脚本，扫描路径可能配错了" % _files.size()):
		_h.finish(get_tree())
		return

	for f in _files:
		_index_methods(f)
	for f in _files:
		_scan_calls(f)

	print("[%s] 扫描 %d 个脚本；接收者无法静态确定的调用 %d 处" % [
		CHECK_NAME, _files.size(), _unresolved])
	_h.expect(_unresolved <= MAX_UNRESOLVED, "unresolved_grew",
		"无法静态确定接收者的动态调用有 %d 处，上限 %d —— 新增的这些编译器管不到" % [
			_unresolved, MAX_UNRESOLVED])

	_h.finish(get_tree())


func _skip_dir(name: String) -> bool:
	for pattern in SKIP_DIR_PATTERNS:
		if name.match(pattern):
			return true
	return false


func _collect(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			if not _skip_dir(entry):
				_collect(full)
		elif entry.ends_with(".gd"):
			_files.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return "" if f == null else f.get_as_text()


# 收集一个文件里定义的所有方法名（含内部类里的 —— 内部类的方法也可能被按名调用），
# 以及它 extends 的父脚本路径。
func _index_methods(path: String) -> void:
	var names := {}
	var parent := ""
	for raw in _read(path).split("\n"):
		var line := str(raw)
		var stripped := line.strip_edges()
		if stripped.begins_with("extends \"res://") or stripped.begins_with("extends 'res://"):
			parent = stripped.substr(stripped.find("res://"))
			parent = parent.substr(0, parent.length() - 1)
		if not (stripped.begins_with("func ") or stripped.begins_with("static func ")):
			continue
		var after := stripped.substr(stripped.find("func ") + 5)
		var paren := after.find("(")
		if paren > 0:
			names[after.substr(0, paren).strip_edges()] = true
	_methods_by_file[path] = names
	_extends_of[path] = parent
	for k in names:
		_all_methods[k] = true


# 沿 extends 链把方法名并起来。父类找不到就停 —— 那通常是 extends 引擎类。
func _methods_including_parents(path: String, depth: int = 0) -> Dictionary:
	var out: Dictionary = (_methods_by_file.get(path, {}) as Dictionary).duplicate()
	if depth > 12:
		return out
	var parent := str(_extends_of.get(path, ""))
	if parent.is_empty() or not _methods_by_file.has(parent):
		return out
	for k in _methods_including_parents(parent, depth + 1):
		out[k] = true
	return out


# 从一行里提取所有 "字面量方法名"（第一个参数是字符串字面量的那几种写法）。
func _names_in(line: String, marker: String) -> Array:
	var out: Array = []
	var from := 0
	while true:
		var at := line.find(marker, from)
		if at < 0:
			break
		var q1 := line.find("\"", at)
		if q1 < 0:
			break
		var q2 := line.find("\"", q1 + 1)
		if q2 < 0:
			break
		# 拼接出来的方法名（node.call("play_" + action)）只能拿到前缀，
		# 拿它去断言「全仓没这个方法」必然误报 —— 第一版就是这么误报的。
		var after_quote := line.substr(q2 + 1).strip_edges()
		if not after_quote.begins_with("+"):
			out.append(line.substr(q1 + 1, q2 - q1 - 1))
		from = q2 + 1
	return out


# 接收者是不是 self（或省略）。只有这种情况才能可靠地静态判定。
func _receiver_is_self(line: String, marker: String) -> bool:
	var at := line.find(marker)
	if at < 0:
		return false
	var before := line.substr(0, at).strip_edges()
	return before.is_empty() or before.ends_with("self") or before.ends_with("(") \
		or before.ends_with(",") or before.ends_with("and") or before.ends_with("or") \
		or before.ends_with("not") or before.ends_with("=") or before.ends_with("return")


func _scan_calls(path: String) -> void:
	var own := _methods_including_parents(path)
	var line_no := 0
	for raw in _read(path).split("\n"):
		line_no += 1
		var line := str(raw)
		var stripped := line.strip_edges()
		if stripped.begins_with("#"):
			continue
		# 跳过本文件：它的源码里把 has_method(" / .call(" 当消息模板用，
		# 扫自己会把格式串当成真实调用。
		if path.ends_with("tools/dynamic_call_check.gd"):
			return
		for marker in [".call(", "has_method(", ".callv("]:
			for name in _names_in(line, marker):
				if name.is_empty() or name.begins_with("_on_"):
					continue   # 信号回调名由连接方决定，不在这条检查范围内
				if _receiver_is_self(line, marker):
					_h.expect(own.has(name), "self_method_missing",
						"%s:%d 按名字调用了本类不存在的方法 %s()" % [path, line_no, name])
				else:
					# 接收者的类型静态定不下来，但**方法名总得有人定义**。
					# 两次真实事故都是「方法被搬走/改名，按名字调用的那处没跟上」，
					# 全仓找不到这个名字就是确凿的漏改。
					_unresolved += 1
					_h.expect(_all_methods.has(name), "method_name_not_defined_anywhere",
						"%s:%d 按名字调用 %s()，但全仓没有任何脚本定义这个方法" % [path, line_no, name])
		# Callable(self, "x")
		if line.contains("Callable(self,"):
			for name in _names_in(line, "Callable(self,"):
				_h.expect(own.has(name), "callable_method_missing",
					"%s:%d Callable(self, \"%s\") 指向不存在的方法" % [path, line_no, name])
