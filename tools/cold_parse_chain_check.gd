extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const CHECK_NAME := "cold_parse_chain"

const TARGETS: Array[Dictionary] = [
	{"kind": "script", "path": "res://effects/runtime/presentation/BoardReadabilityStyle.gd"},
	{"kind": "resource", "path": "res://data/presentation/board_readability_default.tres"},
	{"kind": "scene", "path": "res://effects/runtime/presentation/BoardReadabilityLayer.tscn"},
	{"kind": "scene", "path": "res://effects/runtime/presentation/UnitPortraitFallback3D.tscn"},
	{"kind": "script", "path": "res://effects/runtime/presentation/UnitActor3D.gd"},
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
		harness.expect(resource is Script, "script_type", "%s must load as a Script" % path)
		return
	if kind == "scene":
		if not harness.expect(resource is PackedScene, "scene_type", "%s must load as a PackedScene" % path):
			return
		var instance: Node = (resource as PackedScene).instantiate()
		if not harness.expect(instance != null, "scene_instantiate", "%s must instantiate after a cold parse" % path):
			return
		harness.expect(instance.get_script() != null, "root_script", "%s root must retain its script" % path)
		instance.free()

