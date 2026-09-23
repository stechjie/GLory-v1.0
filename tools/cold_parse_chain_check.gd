extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const CHECK_NAME := "cold_parse_chain"

const TARGETS: Array[Dictionary] = [
	{"kind": "script", "path": "res://effects/runtime/presentation/BoardReadabilityStyle.gd"},
	{"kind": "resource", "path": "res://data/presentation/board_readability_default.tres"},
	{"kind": "scene", "path": "res://effects/runtime/presentation/BoardReadabilityLayer.tscn"},
	{"kind": "scene", "path": "res://effects/runtime/presentation/UnitPortraitFallback3D.tscn"},
	{"kind": "script", "path": "res://effects/runtime/presentation/UnitActor3D.gd"},
	# 战斗继承链 `BattleUI → BattleArena → BattleRenderer → BattleVfx → BattleResult → BattleScreen`。
	# ★ 9.22 事故后补齐：此前只列了 BattleResult.gd，而**真正被改坏的那一层是 BattleVfx.gd**。
	#   出事形态是 `elif _owned:` 的语句体被整段抬出缩进 → 只剩注释 → 解析期错误。
	#   它能被抓到纯属侥幸（BattleScreen.tscn 实例化时连带失败）；把链上每一层都单列出来，
	#   才是「谁坏了就指谁」，而不是靠上层连带。
	{"kind": "script", "path": "res://scenes/battle/BattleUI.gd"},
	{"kind": "script", "path": "res://scenes/battle/BattleArena.gd"},
	{"kind": "script", "path": "res://scenes/battle/BattleRenderer.gd"},
	{"kind": "script", "path": "res://scenes/battle/BattleVfx.gd"},
	{"kind": "script", "path": "res://scenes/battle/BattleResult.gd"},
	{"kind": "scene", "path": "res://scenes/battle/BattleScreen.tscn"},
	{"kind": "scene", "path": "res://scenes/prep/PrepScreen.tscn"},
	{"kind": "script", "path": "res://scripts/tutorial/TutorialMode.gd"},
]


func _ready() -> void:
	var harness := CheckHarness.new(CHECK_NAME)
	for target: Dictionary in TARGETS:
		_check_target(harness, target)
	harness.finish(get_tree())


func _check_target(harness: RefCounted, target: Dictionary) -> void:
	var path: String = str(target.get("path", ""))
	var kind: String = str(target.get("kind", ""))
	var resource: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if not harness.expect(resource != null, "resource_load", "%s must load without a warm global class cache" % path):
		return
	if kind == "script":
		if not harness.expect(resource is Script, "script_type", "%s must load as a Script" % path):
			return
		# ★ 判据必须落在 `can_instantiate()` 上，**不能只看 `load() != null`**。
		#   9.22 实测：一个**解析失败**的 GDScript，`ResourceLoader.load()` 照样返回
		#   非 null 对象（`res == null` 为 false、`res is Script` 为 true），
		#   但 `can_instantiate()` 为 false、`get_script_method_list()` 为 0 条。
		#   所以「load 得到东西」证明不了「这份脚本是好的」。
		var script := resource as Script
		harness.expect(script.can_instantiate(), "script_parseable",
			"%s 解析失败：load() 拿到了非 null 对象，但 can_instantiate() 为 false（说明有解析期错误）" % path)
		return
	if kind == "scene":
		if not harness.expect(resource is PackedScene, "scene_type", "%s must load as a PackedScene" % path):
			return
		var instance: Node = (resource as PackedScene).instantiate()
		if not harness.expect(instance != null, "scene_instantiate", "%s must instantiate after a cold parse" % path):
			return
		harness.expect(instance.get_script() != null, "root_script", "%s root must retain its script" % path)
		instance.free()

