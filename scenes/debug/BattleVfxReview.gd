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
const ResolverScript := preload("res://effects/runtime/presentation/VfxProfileResolver.gd")
const Fixture := preload("res://scripts/qa/FixedBattleFixture.gd")

const DEFAULT_SEED := 20260823
const SPEEDS := [0.25, 0.5, 1.0, 2.0]
const TIERS := ["LOW", "MEDIUM", "HIGH"]

# B5 A/B compare. "旧/新 profile 对照" no longer means legacy-vs-Director: D6
# deleted the legacy route. What is worth comparing now is the live profile set
# against a candidate one, or one quality tier against another.
const LIVE_PROFILE_DIR := "res://data/vfx/battle_cues/"
const CANDIDATE_PROFILE_DIR := "res://data/vfx/battle_cues_candidate/"
const COMPARE_MODES := ["候选 profile 目录", "另一质量档"]
# Both sides are captured at the same replay frame, otherwise the two screenshots
# would show different moments of the battle and be useless to compare.
const DEFAULT_CAPTURE_FRAME := 20

var _screen: Node = null
var _seed_edit: LineEdit
var _tier_option: OptionButton
var _speed_option: OptionButton
var _round_option: OptionButton
var _metrics_label: RichTextLabel
var _status_label: Label
var _out_dir := ""
var _compare_mode: OptionButton
var _compare_dir_edit: LineEdit
var _compare_tier: OptionButton
var _capture_frame_edit: LineEdit
var _compare_busy := false
var _compare_index := 0
var _run_index := 0
var _frames_seen := 0
var _fps_samples: Array[float] = []


func _ready() -> void:
	_out_dir = ProjectSettings.globalize_path("user://battle_vfx_review")
	DirAccess.make_dir_recursive_absolute(_out_dir)
	DataRegistry.load_all()
	_build_ui()
	_set_status("Ready. Output: %s" % _out_dir)
	_apply_cmdline()


func _process(_delta: float) -> void:
	if _screen == null or not is_instance_valid(_screen):
		return
	_frames_seen += 1
	_fps_samples.append(Engine.get_frames_per_second())
	if _frames_seen % 15 == 0:
		_refresh_metrics()


# Lets the A/B comparison run unattended, which is the only way it can be part of a
# gate or be verified without a human clicking the button. Nothing here changes what
# the manual path does; it just presses the same buttons.
#
#   Godot --path . res://scenes/debug/BattleVfxReview.tscn -- #       --review-compare --seed 20260823 --round 1 --capture-frame 20 [--compare-tier LOW]
func _apply_cmdline() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.has("--review-compare"):
		return
	for i in args.size():
		var key := str(args[i])
		var value := str(args[i + 1]) if i + 1 < args.size() else ""
		match key:
			"--seed":
				_seed_edit.text = value
			"--round":
				for r in _round_option.item_count:
					if _round_option.get_item_text(r) == value:
						_round_option.select(r)
			"--capture-frame":
				_capture_frame_edit.text = value
			"--tier":
				_tier_option.select(maxi(0, TIERS.find(value.to_upper())))
			"--compare-tier":
				_compare_mode.select(1)
				_compare_tier.select(maxi(0, TIERS.find(value.to_upper())))
			"--compare-dir":
				_compare_mode.select(0)
				_compare_dir_edit.text = value
	call_deferred("_run_cmdline_compare")


func _run_cmdline_compare() -> void:
	await _on_compare_pressed()
	await get_tree().process_frame
	_clear_screen()
	get_tree().quit(0)


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

	var separator := HSeparator.new()
	root.add_child(separator)

	_compare_mode = _add_option(root, "对照方式", COMPARE_MODES, 0)
	var dir_row := HBoxContainer.new()
	var dir_label := Label.new()
	dir_label.text = "候选目录"
	dir_label.custom_minimum_size = Vector2(70, 0)
	_compare_dir_edit = LineEdit.new()
	_compare_dir_edit.text = CANDIDATE_PROFILE_DIR
	_compare_dir_edit.custom_minimum_size = Vector2(300, 0)
	dir_row.add_child(dir_label)
	dir_row.add_child(_compare_dir_edit)
	root.add_child(dir_row)
	_compare_tier = _add_option(root, "对照档位", TIERS, 0)
	var frame_row := HBoxContainer.new()
	var frame_label := Label.new()
	frame_label.text = "截帧于帧"
	frame_label.custom_minimum_size = Vector2(70, 0)
	_capture_frame_edit = LineEdit.new()
	_capture_frame_edit.text = str(DEFAULT_CAPTURE_FRAME)
	_capture_frame_edit.custom_minimum_size = Vector2(80, 0)
	frame_row.add_child(frame_label)
	frame_row.add_child(_capture_frame_edit)
	root.add_child(frame_row)

	var compare_button := Button.new()
	compare_button.text = "A/B 对照（同一 seed、同一帧，跑两遍）"
	compare_button.pressed.connect(_on_compare_pressed)
	root.add_child(compare_button)

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
	_start_run(TIERS[_tier_option.selected], "")


# `tier_name` and `profile_dir` let the A/B compare drive the exact same path the
# manual Run button uses, so the two sides cannot diverge in setup.
func _start_run(tier_name: String, profile_dir: String) -> bool:
	_clear_screen()
	var seed_value := int(_seed_edit.text) if _seed_edit.text.is_valid_int() else DEFAULT_SEED
	var round_index := int(_round_option.get_item_text(_round_option.selected))
	BudgetScript.tier = _tier_from_name(tier_name)
	ResolverScript.review_profile_dir_override = profile_dir

	# Setting only the seed and the round left the boards empty, which is why this
	# scene's replay always came back empty. The fixture puts GameState and
	# NetworkService into the same state the baseline recorder uses.
	Fixture.setup_match_state(round_index, seed_value)
	var replay: Dictionary = BattleSim.compute_team_replay(0, "review:%d:%d" % [seed_value, round_index])
	if replay.is_empty() or (replay.get("frames", []) as Array).is_empty():
		_set_status("Replay came back empty for seed %d round %d." % [seed_value, round_index])
		ResolverScript.review_profile_dir_override = ""
		return false

	GameState.set_pending_battle_package({
		"mode": "team_replay",
		"round_index": round_index,
		"replay": replay,
	})
	_screen = BattleScreenScene.instantiate()
	if _screen == null:
		_set_status("BattleScreen failed to instantiate.")
		ResolverScript.review_profile_dir_override = ""
		return false
	add_child(_screen)
	move_child(_screen, 0)
	_frames_seen = 0
	_fps_samples.clear()
	_run_index += 1
	var enemy := _enemy_summary(replay)
	var dir_label := profile_dir if not profile_dir.is_empty() else LIVE_PROFILE_DIR
	_set_status("Run %d: seed %d, round %d, tier %s, speed %s, profiles %s. Enemy: %s" % [
		_run_index, seed_value, round_index, tier_name,
		_speed_option.get_item_text(_speed_option.selected), dir_label.get_base_dir().get_file(), enemy])
	# Playback speed is applied after BattleScreen resumes its own Director, so it is
	# set on the next frame rather than immediately.
	call_deferred("_apply_speed")
	return true


func _apply_speed() -> void:
	await get_tree().process_frame
	if _screen == null or not is_instance_valid(_screen):
		return
	var director = _screen.get("_presentation_director")
	if director != null and (director as Object).has_method("set_playback_speed"):
		(director as Object).call("set_playback_speed", SPEEDS[_speed_option.selected])


# Runs the fixed battle twice and writes both screenshots plus a metrics delta.
# Both sides stop at the same replay frame so the two images show the same moment.
func _on_compare_pressed() -> void:
	if _compare_busy:
		_set_status("A/B 对照正在进行中。")
		return
	var capture_frame := int(_capture_frame_edit.text) if _capture_frame_edit.text.is_valid_int() else DEFAULT_CAPTURE_FRAME
	var side_a := {"label": "A", "tier": TIERS[_tier_option.selected], "dir": ""}
	var side_b := {}
	if _compare_mode.selected == 0:
		var candidate := _compare_dir_edit.text.strip_edges()
		if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(candidate)):
			_set_status("候选目录不存在：%s" % candidate)
			return
		side_b = {"label": "B", "tier": TIERS[_tier_option.selected], "dir": candidate}
	else:
		if _compare_tier.selected == _tier_option.selected:
			_set_status("对照档位和当前档位相同，换一个再比。")
			return
		side_b = {"label": "B", "tier": TIERS[_compare_tier.selected], "dir": ""}

	_compare_busy = true
	_compare_index += 1
	var results: Array[Dictionary] = []
	for side in [side_a, side_b]:
		var captured := await _run_side_and_capture(side, capture_frame)
		if captured.is_empty():
			_compare_busy = false
			return
		results.append(captured)
	_write_comparison(results, capture_frame)
	_compare_busy = false


func _run_side_and_capture(side: Dictionary, capture_frame: int) -> Dictionary:
	if not _start_run(str(side.get("tier", "MEDIUM")), str(side.get("dir", ""))):
		return {}
	# Wait for the battle to reach the shared capture frame. The cap keeps a stalled
	# or too-short replay from hanging the review scene.
	var deadline := Time.get_ticks_msec() + 60000
	while true:
		await get_tree().process_frame
		if not is_inside_tree() or _screen == null or not is_instance_valid(_screen):
			_set_status("对照中断：战斗场景消失。")
			ResolverScript.review_profile_dir_override = ""
			return {}
		if int(_screen.get("_replay_frame")) >= capture_frame:
			break
		if Time.get_ticks_msec() > deadline:
			_set_status("对照中断：等待第 %d 帧超时。" % capture_frame)
			ResolverScript.review_profile_dir_override = ""
			return {}
	# One more frame so the cues scheduled on the capture frame are actually drawn.
	await get_tree().process_frame
	var metrics := _collect_metrics()
	metrics["side"] = str(side.get("label", ""))
	metrics["profile_dir"] = str(side.get("dir", "")) if not str(side.get("dir", "")).is_empty() else LIVE_PROFILE_DIR
	metrics["capture_frame"] = capture_frame
	var stamp := "compare%02d_%s_%s" % [_compare_index, str(side.get("label", "")), str(side.get("tier", ""))]
	var png_path := _out_dir.path_join(stamp + ".png")
	get_viewport().get_texture().get_image().save_png(png_path)
	metrics["screenshot"] = png_path.get_file()
	ResolverScript.review_profile_dir_override = ""
	return metrics


# Numeric fields get an explicit delta so a reviewer does not have to diff by eye.
func _write_comparison(results: Array[Dictionary], capture_frame: int) -> void:
	var a: Dictionary = results[0]
	var b: Dictionary = results[1]
	var delta := {}
	for key in a.keys():
		if not b.has(key):
			continue
		var av = a[key]
		var bv = b[key]
		if (av is int or av is float) and (bv is int or bv is float):
			delta[key] = float(bv) - float(av)
	var report := {
		"generated_utc": Time.get_datetime_string_from_system(true, false),
		"seed": _seed_edit.text,
		"round": _round_option.get_item_text(_round_option.selected),
		"playback_speed": SPEEDS[_speed_option.selected],
		"capture_frame": capture_frame,
		"compare_mode": COMPARE_MODES[_compare_mode.selected],
		"side_a": a,
		"side_b": b,
		"delta_b_minus_a": delta,
		"fps_is_not_comparable": {
			"why": "Side A always runs first and absorbs the one-off costs of this process: "
				+ "shader compilation, resource loading and cache fills. Measured drift is about "
				+ "+26 fps for B on an otherwise identical pair, so fps_avg and fps_min say more "
				+ "about run order than about the two profile sets.",
			"compare_these_instead": ["draw_calls", "nodes", "tweens", "cues_active", "cues_pending", "budget", "adapter", "the two screenshots"],
			"if_fps_matters": "run the compare twice with the two sides swapped and look at whether the sign of the difference follows the profile set or the run order",
		},
	}
	var path := _out_dir.path_join("compare%02d.json" % _compare_index)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	# The format operator binds tighter than +, so the concatenation has to be
	# parenthesised or only the trailing literal gets the arguments.
	_set_status(("A/B 对照完成：%s、%s 与 %s。draw call %d→%d，节点 %d→%d，待播 cue %d→%d。"
		+ "（fps 不可比：A 侧先跑，吃掉了 shader 编译等一次性开销）") % [
		str(a.get("screenshot", "")), str(b.get("screenshot", "")), path.get_file(),
		int(a.get("draw_calls", 0)), int(b.get("draw_calls", 0)),
		int(a.get("nodes", 0)), int(b.get("nodes", 0)),
		int(a.get("cues_pending", 0)), int(b.get("cues_pending", 0))])


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
	ResolverScript.review_profile_dir_override = ""
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
