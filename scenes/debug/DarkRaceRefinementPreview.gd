extends "res://scenes/debug/ModelRefinementPreview.gd"
## 种族模型精修对照预览（暗族、灵族、赤律族）。--unit <id> 选目标（默认 dark_dragon）；
## "同框" 把目标所属种族的八个单位按当前 原版/新版 一起摆出，用来判断无名字时能否区分，
## 例如 --unit undead_mother --lineup 摆出灵族。
## 比例、三阶放大和 model_in_place_actions 都从 data/units/race_units.json 读，
## 与 BattleRenderer 一致：0.42 × model_visual_scale，三阶再 ×1.2（TIER3_VISUAL_BOOST），
## 并对配置的动作做同一套 ModelRootMotionPolicy 原地锁定。
## 美术正面：两族十六个单位的双眼骨中点都在头骨 +Z 侧（rig.json 实测），因此 art_front_yaw = 0。

const RootMotionPolicy := preload("res://effects/runtime/presentation/ModelRootMotionPolicy.gd")
const UNIT_DATA := "res://data/units/race_units.json"
const BATTLE_SCALE := 0.42
const TIER3_BOOST := 1.2
# "old" are the original wrappers, kept unchanged for comparison and rollback.
const RACES := {
	"dark": {"label": "暗族", "old": {
		"dark_imp": "res://assets/models/units/dark_imp_motong/dark_imp_motong_animated.tscn",
		"dark_mage": "res://assets/models/units/dark_mage_violet_necromancer/dark_mage_animated.tscn",
		"dark_scythe": "res://assets/models/units/dark_scythe_animated/dark_scythe_animated.tscn",
		"dark_suc": "res://assets/models/units/dark_suc_animated/dark_suc_animated.tscn",
		"dark_fear": "res://assets/models/units/dark_fear_animated/dark_fear_animated.tscn",
		"dark_queen": "res://assets/models/units/dark_queen_animated/dark_queen_animated.tscn",
		"dark_doom": "res://assets/models/units/dark_doom_animated/dark_doom_animated.tscn",
		"dark_dragon": "res://assets/models/units/dark_dragon_animated/dark_dragon_animated.tscn",
	}},
	"undead": {"label": "灵族", "old": {
		"undead_small": "res://assets/models/units/undead_small_animated/undead_small_animated.tscn",
		"undead_poison": "res://assets/models/units/undead_poison_animated/undead_poison_animated.tscn",
		"undead_parasite": "res://assets/models/units/undead_parasite_animated/undead_parasite_animated.tscn",
		"undead_spike": "res://assets/models/units/undead_spike_animated/undead_spike_animated.tscn",
		"undead_fly": "res://assets/models/units/undead_fly_animated/undead_fly_animated.tscn",
		"undead_bomb": "res://assets/models/units/undead_bomb_animated/undead_bomb_animated.tscn",
		"undead_titan": "res://assets/models/units/undead_titan_animated/undead_titan_animated.tscn",
		"undead_mother": "res://assets/models/units/undead_mother_animated/undead_mother_animated.tscn",
	}},
	# Crimson originals are single Meshy GLBs ("glb": refined scenes instance a refined GLB, not
	# the original); their current model_visual_scale is kept.
	"crimson": {"label": "赤律族", "glb": true, "keep_visual_scale": true, "old": {
		"crimson": "res://assets/models/units/crimson_race/crimson.glb",
		"dancer": "res://assets/models/units/crimson_race/dancer.glb",
		"drumer": "res://assets/models/units/crimson_race/drumer.glb",
		"hunter": "res://assets/models/units/crimson_race/hunter.glb",
		"armbreaker": "res://assets/models/units/crimson_race/armbreaker.glb",
		"Icey": "res://assets/models/units/crimson_race/Icey.glb",
		"skypierce": "res://assets/models/units/crimson_race/skypierce.glb",
		"lattern": "res://assets/models/units/crimson_race/lattern.glb",
	}},
}

var _defs := {}


static func race_of(unit_id: String) -> String:
	for race in RACES:
		if (RACES[race].old as Dictionary).has(unit_id):
			return race
	return ""


static func new_model_path(unit_id: String) -> String:
	return "res://assets/models/units/%s_refined/%s/%s_refined.tscn" % [race_of(unit_id), unit_id, unit_id]


func _unit_defs() -> Dictionary:
	if _defs.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(UNIT_DATA))
		for unit in (parsed as Dictionary).get("units", []):
			if RACES.has(str(unit.get("race", ""))):
				_defs[str(unit.id)] = unit
	return _defs


func _scale(unit_id: String, which: String) -> float:
	var unit: Dictionary = _unit_defs()[unit_id]
	# Dark and undead originals were all shown at model_visual_scale 1.0.
	var keep: bool = RACES[race_of(unit_id)].get("keep_visual_scale", false)
	var visual := 1.0 if which == "old" and not keep else float(unit.get("model_visual_scale", 1.0))
	return BATTLE_SCALE * visual * (TIER3_BOOST if int(unit.get("tier", 1)) == 3 else 1.0)


func _targets() -> Dictionary:
	var table := {}
	for race in RACES:
		var label: String = RACES[race].label
		var olds: Dictionary = RACES[race].old
		var names: Array[String] = []
		for id in olds:
			names.append(str(_unit_defs()[id].name))
		for id in olds:
			table[id] = {"title": "%s模型精修 · %s" % [label, _unit_defs()[id].name], "old": olds[id], "new": new_model_path(id),
				"scale": _scale(id, "old"), "old_scale": _scale(id, "old"), "new_scale": _scale(id, "new"),
				"art_front_yaw": 0.0, "lineup_button": label + "同框", "lineup_text": "%s同框：%s" % [label, " · ".join(names)]}
	return table


func _default_target_id() -> String:
	return "dark_dragon"


func _lineup_placements() -> Array:
	var olds: Dictionary = RACES[race_of(_target_id)].old
	var ids: Array = olds.keys()
	var placements: Array = []
	for i in ids.size():
		var id: String = ids[i]
		placements.append({"path": olds[id] if _variant == "old" else new_model_path(id),
			"x": (float(i) - (ids.size() - 1) * 0.5) * 1.15, "scale": _scale(id, _variant), "art_front_yaw": 0.0})
	return placements


func _rebuild() -> void:
	super._rebuild()
	if not _ready_done:
		return
	# Same in-place lock BattleRenderer applies right after creating the model.
	for i in _models.size():
		var unit_id := _unit_for_path(_paths[i])
		for action in _unit_defs().get(unit_id, {}).get(RootMotionPolicy.CONFIG_KEY, []):
			RootMotionPolicy._make_action_in_place(_models[i], str(action))
	_reset_cycle()


func _unit_for_path(path: String) -> String:
	for race in RACES:
		for id in RACES[race].old:
			if path == RACES[race].old[id] or path == new_model_path(id):
				return id
	return ""


func _update_labels() -> void:
	super._update_labels()
	if _title != null and _layout == "lineup":
		_title.text += "（原版）" if _variant == "old" else "（新版）"
