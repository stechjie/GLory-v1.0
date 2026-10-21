extends Node

# 🔴 10-21 补：**全量脚本编译门禁**。
#
# ## 为什么必需（血的教训）
# `--headless --editor --quit` **只解析编辑器加载集里的脚本**。没有 `class_name`
# 的脚本不在其中 —— `scenes/battle/BattleVfx.gd` 正是这种。我在里面写了一个
# `target_uid` 未声明的错误，编辑器编译**零报错**，真跑游戏才炸成 5 级链：
#     Could not resolve class "BattleVfx.gd"
#       → BattleResult.gd 加载失败 → BattleScreen.gd 加载失败
#       → OfficeTestScreen.gd 加载失败
#       → Invalid access to property 'back_requested' on 'Control'
# 根因只有一个，症状五条。
#
# ## 判据为什么是 can_instantiate() 而不是 load()==null
# 实测（变异对照）：给 `scripts/` 注入一个 `var q := 未声明符号` 的脚本后
#   * `load()` **仍返回非空 GDScript** ⇒ 用它判红会假绿（我第一版就假绿了）；
#   * `reload()` 对好脚本也返回非 OK（22）⇒ 不是判别器；
#   * `can_instantiate()` 坏脚本 **false** / 好脚本 **true** ⇒ 可用。
#
# ## 两个桶
#   runtime —— 游戏真会加载的（scripts/scenes/ui/effects/officetest/patcher）⇒ **判红**
#   gates   —— 门禁与工具脚本（tools/、_qa_*/、work/）⇒ **只报告不判红**
#              （它们不进包，且已知与生产代码有历史漂移；见文件末尾的输出）
#
# 跑法：<godot> --headless res://_qa_1018/parse_all_scripts_probe.tscn

const RUNTIME_DIRS := ["scripts", "scenes", "ui", "effects", "officetest", "patcher"]
const GATE_DIRS := ["tools", "_qa_1016", "_qa_1017", "_qa_1018", "_qa_godpulse", "_qa_t3unique"]
# 一律不扫
const HARD_SKIP := [
	".godot", ".git", ".workbuddy", "android", "android_plugins", "addons",
	"work", "backend", "database", "deploy", "native", "docs", "art_source",
	"_local_test_server", "resources", "captures", "reports", "logs",
]

var _rt_total := 0
var _rt_bad: Array = []
var _gt_total := 0
var _gt_bad: Array = []
var _other_checked := 0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var seen := {}
	_walk("res://", "", seen)

	print("PARSE_ALL runtime=%d bad=%d | gates=%d bad=%d | other=%d" % [
		_rt_total, _rt_bad.size(), _gt_total, _gt_bad.size(), _other_checked])
	for f in _rt_bad:
		print("  RT_FAIL ", f)
	for f in _gt_bad:
		print("  GATE_FAIL(不判红) ", f)

	var ok := _rt_bad.is_empty()
	print("PARSE_ALL_EXIT " + ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)


func _walk(dir_path: String, rel: String, seen: Dictionary) -> void:
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
		var child_rel := (rel + "/" + name) if rel != "" else name
		if d.current_is_dir():
			if not (name in HARD_SKIP):
				_walk(full, child_rel, seen)
		elif name.ends_with(".gd"):
			if not seen.has(full):
				seen[full] = true
				_check(full, child_rel)
		name = d.get_next()
	d.list_dir_end()


func _bucket(rel: String) -> String:
	var top := rel.split("/")[0] if rel.contains("/") else ""
	if top in RUNTIME_DIRS:
		return "runtime"
	if top in GATE_DIRS:
		return "gates"
	return "other"


func _check(path: String, rel: String) -> void:
	var b := _bucket(rel)
	var s: Variant = load(path)
	var broken := false
	if s == null:
		broken = true
	elif s is GDScript:
		broken = not (s as GDScript).can_instantiate()
	else:
		broken = true

	match b:
		"runtime":
			_rt_total += 1
			if broken:
				_rt_bad.append(rel)
		"gates":
			_gt_total += 1
			if broken:
				_gt_bad.append(rel)
		_:
			_other_checked += 1
