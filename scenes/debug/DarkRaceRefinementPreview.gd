extends "res://scenes/debug/ModelRefinementPreview.gd"
## 暗族八个单位的精修对照预览。--unit <dark_id> 选目标（默认 dark_dragon）；
## "暗族同框" 把全族按当前 原版/新版 一起摆出，用来判断无名字时能否区分。
## 比例、三阶放大和 model_in_place_actions 都从 data/units/race_units.json 读，
## 与 BattleRenderer 一致：0.42 × model_visual_scale，三阶再 ×1.2（TIER3_VISUAL_BOOST），
## 并对配置的动作做同一套 ModelRootMotionPolicy 原地锁定。
## 美术正面：八个单位的双眼骨中点都在头骨 +Z 侧（rig.json 实测），因此 art_front_yaw = 0。

const RootMotionPolicy := preload("res://effects/runtime/presentation/ModelRootMotionPolicy.gd")
const UNIT_DATA := "res://data/units/race_units.json"
const BATTLE_SCALE := 0.42
const TIER3_BOOST := 1.2
const ORDER := ["dark_imp", "dark_mage", "dark_scythe", "dark_suc", "dark_fear", "dark_queen", "dark_doom", "dark_dragon"]
const OLD_MODELS := {
	"dark_imp": "res://assets/models/units/dark_imp_motong/dark_imp_motong_animated.tscn",
	"dark_mage": "res://assets/models/units/dark_mage_violet_necromancer/dark_mage_animated.tscn",
	"dark_scythe": "res://assets/models/units/dark_scythe_animated/dark_scythe_animated.tscn",
	"dark_suc": "res://assets/models/units/dark_suc_animated/dark_suc_animated.tscn",
	"dark_fear": "res://assets/models/units/dark_fear_animated/dark_fear_animated.tscn",
	"dark_queen": "res://assets/models/units/dark_queen_animated/dark_queen_animated.tscn",
	"dark_doom": "res://assets/models/units/dark_doom_animated/dark_doom_animated.tscn",
	"dark_dragon": "res://assets/models/units/dark_dragon_animated/dark_dragon_animated.tscn",
}
# The original wrappers were all shown at model_visual_scale 1.0.
const OLD_VISUAL_SCALE := 1.0

var _defs := {}


static func new_model_path(unit_id: String) -> String:
	return "res://assets/models/units/dark_refined/%s/%s_refined.tscn" % [unit_id, unit_id]


func _unit_defs() -> Dictionary:
	if _defs.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(UNIT_DATA))
		for unit in (parsed as Dictionary).get("units", []):
			if str(unit.get("race", "")) == "dark":
				_defs[str(unit.id)] = unit
	return _defs


func _scale(unit_id: String, which: String) -> float:
	var unit: Dictionary = _unit_defs()[unit_id]
	var visual := OLD_VISUAL_SCALE if which == "old" else float(unit.get("model_visual_scale", 1.0))
	return BATTLE_SCALE * visual * (TIER3_BOOST if int(unit.get("tier", 1)) == 3 else 1.0)


func _targets() -> Dictionary:
	var names: Array[String] = []
	for id in ORDER:
		names.append(str(_unit_defs()[id].name))
	var table := {}
	for id in ORDER:
		table[id] = {"title": "暗族模型精修 · " + str(_unit_defs()[id].name), "old": OLD_MODELS[id], "new": new_model_path(id),
			"scale": _scale(id, "old"), "old_scale": _scale(id, "old"), "new_scale": _scale(id, "new"),
			"art_front_yaw": 0.0, "lineup_button": "暗族同框", "lineup_text": "暗族同框：" + " · ".join(names)}
	return table


func _default_target_id() -> String:
	return "dark_dragon"


func _lineup_placements() -> Array:
	var placements: Array = []
	for i in ORDER.size():
		var id: String = ORDER[i]
		placements.append({"path": OLD_MODELS[id] if _variant == "old" else new_model_path(id),
			"x": (float(i) - (ORDER.size() - 1) * 0.5) * 1.15, "scale": _scale(id, _variant), "art_front_yaw": 0.0})
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
	for id in ORDER:
		if path == OLD_MODELS[id] or path == new_model_path(id):
			return id
	return ""


func _update_labels() -> void:
	super._update_labels()
	if _title != null and _layout == "lineup":
		_title.text += "（原版）" if _variant == "old" else "（新版）"
