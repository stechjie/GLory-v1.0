extends "res://scenes/battle/BattleVfx.gd"

# Count the actual legacy resolver calls while leaving its lookup semantics intact.
var lookup_calls := 0
var lookup_raw_visits := 0
var index_builds := 0
var index_raw_visits := 0
var visual_calls: Array = []
var probe_backgrounds: Dictionary = {}
var probe_lane := 0


func _state_unit_for(uid: String) -> Dictionary:
	lookup_calls += 1
	for side in ["player", "enemy"]:
		for raw in _state.get(side, []):
			if raw is Dictionary:
				lookup_raw_visits += 1
	return super._state_unit_for(uid)


func _local_lane() -> int:
	return probe_lane


func _treasure_state_units_by_uid() -> Dictionary:
	index_builds += 1
	for side in ["player", "enemy"]:
		for raw in _state.get(side, []):
			if raw is Dictionary:
				index_raw_visits += 1
	return super._treasure_state_units_by_uid()


func _set_model_for(uid: String) -> Node3D:
	visual_calls.append(["model", uid])
	return super._set_model_for(uid)


func _set_hp_bg_for(raw: Dictionary) -> ColorRect:
	var key := str(raw.get("probe_key", raw.get("uid", "")))
	visual_calls.append(["hp_background", key])
	if not probe_backgrounds.has(key):
		var bg := ColorRect.new()
		bg.color = SET_HP_BG_COLOR
		bg.set_meta("hp_max_width", 63.0)
		probe_backgrounds[key] = bg
		add_child(bg)
	return probe_backgrounds[key]


func _clear_execute_mark(uid: String) -> void:
	visual_calls.append(["clear_mark", uid])
	super._clear_execute_mark(uid)


func reset_counts() -> void:
	lookup_calls = 0
	lookup_raw_visits = 0
	index_builds = 0
	index_raw_visits = 0
	visual_calls.clear()


func visual_state() -> Dictionary:
	var marks: Dictionary = {}
	for key in probe_backgrounds:
		var bg: ColorRect = probe_backgrounds[key]
		var mark := bg.get_node_or_null("ExecuteMark") as ColorRect
		marks[key] = {} if mark == null or mark.is_queued_for_deletion() else {
			"position": mark.position, "size": mark.size, "color": mark.color,
			"z_index": mark.z_index, "mouse_filter": mark.mouse_filter}
	return {"marks": marks, "marked": _set_execute_marked.duplicate(),
		"defense_shown": _set_defense_shown.duplicate(), "sigils": _set_defense_sigils.keys()}
