extends Node

# D5 review scene (checklist section 8, "视觉评审").
#
# Runs a fixed-seed battle through the real BattleScreen so a profile change can be
# judged without playing a whole session. Quality tier, playback speed and seed are
# switchable, and every run can be saved as a screenshot plus a metrics json so the
# two can be compared side by side later.
#
# This scene is diagnostic only: it never writes PlayerProfile, never changes the
# simulation, and reads the same replay entry point the game uses.

const BattleScreenScene := preload("res://scenes/battle/BattleScreen.tscn")
const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")
const BudgetScript := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")

const DEFAULT_SEED := 20260823
const SPEEDS := [0.25, 0.5, 1.0, 2.0]
const TIERS := ["LOW", "MEDIUM", "HIGH"]

var _screen: Node = null
var _seed_edit: LineEdit
var _tier_option: OptionButton
var _speed_option: OptionButton
var _round_option: OptionButton
var _metrics_label: RichTextLabel
var _status_label: Label
var _out_dir := ""
var _run_index := 0
var _frames_seen := 0
var _fps_samples: Array[float] = []


func _ready() -> void:
	_out_dir = ProjectSettings.globalize_path("user://battle_vfx_review")
	DirAccess.make_dir_recursive_absolute(_out_dir)
	DataRegistry.load_all()
	_build_ui()
	_set_status("Ready. Output: %s" % _out_dir)


func _process(_delta: float) -> void:
	if _screen == null or not is_instance_valid(_screen):
		return
	_frames_seen += 1
	_fps_samples.append(Engine.get_frames_per_second())
	if _frames_seen % 15 == 0:
		_refresh_metrics()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_TOP_LEFT)
	root.custom_minimum_size = Vector2(430, 0)
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	var title := Label.new()
	title.text = "Battle VFX Review (D5)"
	title.add_theme_font_size_override("font_size", 20)
	root.add_child(title)

	var seed_row := HBoxContainer.new()
	var seed_label := Label.new()
	seed_label.text = "Seed"
	seed_label.custom_minimum_size = Vector2(70, 0)
	_seed_edit = LineEdit.new()
	_seed_edit.text = str(DEFAULT_SEED)
	_seed_edit.custom_minimum_size = Vector2(160, 0)
	seed_row.add_child(seed_label)
	seed_row.add_child(_seed_edit)
	root.add_child(seed_row)

	_round_option = _add_option(root, "Round", ["1", "2", "3", "4"], 0)
	_tier_option = _add_option(root, "Quality", TIERS, 1)
	var speed_labels: Array = []
	for speed in SPEEDS:
		speed_labels.append("%.2fx" % speed)
	_speed_option = _add_option(root, "Speed", speed_labels, 2)

	var run_button := Button.new()
	run_button.text = "Run fixed battle"
	run_button.pressed.connect(_on_run_pressed)
	root.add_child(run_button)

	var shot_button := Button.new()
	shot_button.text = "Save screenshot + metrics"
	shot_button.pressed.connect(_on_capture_pressed)
	root.add_child(shot_button)

	var stop_button := Button.new()
	stop_button.text = "Stop"
	stop_button.pressed.connect(_on_stop_pressed)
	root.add_child(stop_button)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.custom_minimum_size = Vector2(420, 0)
	root.add_child(_status_label)

	_metrics_label = RichTextLabel.new()
	_metrics_label.custom_minimum_size = Vector2(420, 340)
	_metrics_label.bbcode_enabled = false
	root.add_child(_metrics_label)


func _add_option(parent: Node, label_text: String, items: Array, selected: int) -> OptionButton:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(70, 0)
	var option := OptionButton.new()
	for item in items:
		option.add_item(str(item))
	option.select(selected)
	row.add_child(label)
	row.add_child(option)
	parent.add_child(row)
	return option


func _on_run_pressed() -> void:
	_clear_screen()
	var seed_value := int(_seed_edit.text) if _seed_edit.text.is_valid_int() else DEFAULT_SEED
	var round_index := int(_round_option.get_item_text(_round_option.selected))
	BudgetScript.tier = _tier_from_name(TIERS[_tier_option.selected])

	NetworkService.shared_seed = seed_value
	GameState.round_index = round_index
	var replay: Dictionary = BattleSim.compute_team_replay(0, "review:%d:%d" % [seed_value, round_index])
	if replay.is_empty() or (replay.get("frames", []) as Array).is_empty():
		_set_status("Replay came back empty for seed %d round %d." % [seed_value, round_index])
		return

	GameState.set_pending_battle_package({
		"mode": "team_replay",
		"round_index": round_index,
		"replay": replay,
	})
	_screen = BattleScreenScene.instantiate()
	if _screen == null:
		_set_status("BattleScreen failed to instantiate.")
		return
	add_child(_screen)
	move_child(_screen, 0)
	_frames_seen = 0
	_fps_samples.clear()
	_run_index += 1
	var enemy := _enemy_summary(replay)
	_set_status("Run %d: seed %d, round %d, tier %s, speed %s. Enemy: %s" % [
		_run_index, seed_value, round_index,
		TIERS[_tier_option.selected], _speed_option.get_item_text(_speed_option.selected), enemy])
	# Playback speed is applied after BattleScreen resumes its own Director, so it is
	# set on the next frame rather than immediately.
	call_deferred("_apply_speed")


func _apply_speed() -> void:
	await get_tree().process_frame
	if _screen == null or not is_instance_valid(_screen):
		return
	var director = _screen.get("_presentation_director")
	if director != null and (director as Object).has_method("set_playback_speed"):
		(director as Object).call("set_playback_speed", SPEEDS[_speed_option.selected])


func _on_stop_pressed() -> void:
	_clear_screen()
	_set_status("Stopped.")


func _on_capture_pressed() -> void:
	var metrics := _collect_metrics()
	var stamp := "run%02d_seed%s_%s_%s" % [
		_run_index, _seed_edit.text, TIERS[_tier_option.selected],
		_speed_option.get_item_text(_speed_option.selected).replace(".", "_")]
	var image := get_viewport().get_texture().get_image()
	var png_path := _out_dir.path_join(stamp + ".png")
	image.save_png(png_path)
	var json_path := _out_dir.path_join(stamp + ".json")
	var file := FileAccess.open(json_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(metrics, "  "))
		file.close()
	_set_status("Saved %s and %s" % [png_path.get_file(), json_path.get_file()])


func _refresh_metrics() -> void:
	var metrics := _collect_metrics()
	var lines: Array[String] = []
	for key in metrics.keys():
		var value = metrics[key]
		if value is Dictionary or value is Array:
			lines.append("%s: %s" % [str(key), JSON.stringify(value)])
		else:
			lines.append("%s: %s" % [str(key), str(value)])
	_metrics_label.text = "\n".join(lines)


func _collect_metrics() -> Dictionary:
	var out := {
		"run": _run_index,
		"seed": _seed_edit.text,
		"round": _round_option.get_item_text(_round_option.selected),
		"quality_tier": TIERS[_tier_option.selected],
		"playback_speed": SPEEDS[_speed_option.selected],
		"frames_observed": _frames_seen,
		"fps_avg": _average(_fps_samples),
		"fps_min": _minimum(_fps_samples),
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"tweens": get_tree().get_processed_tweens().size(),
		"video_mem_mb": snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.01),
	}
	if _screen == null or not is_instance_valid(_screen):
		return out
	var director = _screen.get("_presentation_director")
	if director != null:
		if (director as Object).has_method("resolution_stats"):
			out["resolution"] = (director as Object).call("resolution_stats")
		if (director as Object).has_method("budget_stats"):
			out["budget"] = (director as Object).call("budget_stats")
		if (director as Object).has_method("active_cue_count"):
			out["cues_active"] = (director as Object).call("active_cue_count")
			out["cues_pending"] = (director as Object).call("pending_cue_count")
	var adapter = _screen.get("_legacy_vfx_adapter")
	if adapter != null and (adapter as Object).has_method("stats"):
		out["adapter"] = (adapter as Object).call("stats")
	var resolver = _screen.get("_vfx_profile_resolver")
	if resolver != null and (resolver as Object).has_method("resolved_counts"):
		out["profiles_resolved"] = (resolver as Object).call("resolved_counts")
		out["profiles_missing"] = (resolver as Object).call("missing_rows")
	out["replay_frame"] = int(_screen.get("_replay_frame"))
	return out


func _enemy_summary(replay: Dictionary) -> String:
	var roster: Dictionary = replay.get("roster", {})
	var names: Dictionary = {}
	for entry_value in roster.values():
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		if str(entry.get("team", "")) != "enemy":
			continue
		names[str(entry.get("id", ""))] = int(names.get(str(entry.get("id", "")), 0)) + 1
	var parts: Array[String] = []
	for key in names.keys():
		parts.append("%s x%d" % [str(key), int(names[key])])
	return ", ".join(parts) if not parts.is_empty() else "(none)"


func _clear_screen() -> void:
	if _screen != null and is_instance_valid(_screen):
		_screen.queue_free()
	_screen = null


func _tier_from_name(name_value: String) -> int:
	match name_value:
		"LOW":
			return BudgetScript.Tier.LOW
		"HIGH":
			return BudgetScript.Tier.HIGH
	return BudgetScript.Tier.MEDIUM


func _set_status(text: String) -> void:
	_status_label.text = text
	print("[VFXREVIEW] %s" % text)


func _average(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return snappedf(total / float(values.size()), 0.01)


func _minimum(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var lowest := values[0]
	for value in values:
		lowest = minf(lowest, value)
	return snappedf(lowest, 0.01)
