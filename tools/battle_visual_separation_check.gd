extends Node

# Fixed visual slots reduce dense overlap without changing the simulator path.
# The central invariant is strict: displayed_delta == raw_delta for every actor.
# Run with:
# Godot_v4.7-stable_win64_console.exe --headless --path . tools/battle_visual_separation_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BattleRendererScript := preload("res://scenes/battle/BattleRenderer.gd")

const CHECK_NAME := "battle_visual_separation"
const MIN_READABLE_DISTANCE := 60.0

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_eight_stacked_units_have_fixed_readable_slots()
	_case_fixed_slots_are_deterministic()
	_case_displayed_path_exactly_matches_raw_path()
	_case_neighbour_changes_never_move_survivors()
	_case_edge_fit_never_expands_during_travel()
	_case_animation_uses_raw_movement()
	_h.finish(get_tree())


func _fighter(uid: String, pos: Vector2, slot: int, team := "player") -> Dictionary:
	return {
		"uid": uid,
		"id": uid,
		"team": team,
		"slot": slot,
		"pos": pos,
		"hp": 100,
		"max_hp": 100,
		"alive": true,
		"def": {},
	}


func _case_eight_stacked_units_have_fixed_readable_slots() -> void:
	var renderer := BattleRendererScript.new()
	var raw := Vector2(500.0, 260.0)
	var fighters: Array = []
	for slot in 8:
		fighters.append(_fighter("player_%d" % slot, raw, slot, "player"))
	renderer._begin_visual_frame(fighters, 0.0)

	var positions: Array[Vector2] = []
	for fighter in fighters:
		positions.append(renderer._visual_sim_pos_for_fighter(fighter))
		_h.expect((fighter as Dictionary).pos == raw, "sim_position_mutated_%s" % str(fighter.uid),
			"固定显示槽改写了 %s 的模拟坐标" % str(fighter.uid))

	var closest := INF
	for i in positions.size():
		for j in range(i + 1, positions.size()):
			closest = minf(closest, positions[i].distance_to(positions[j]))
	_h.expect(closest >= MIN_READABLE_DISTANCE, "dense_stack_still_overlaps",
		"8 个同点单位的固定槽最近距离只有 %.2f" % closest)
	renderer.free()


func _case_fixed_slots_are_deterministic() -> void:
	var fighters := [
		_fighter("stable_a", Vector2(500.0, 260.0), 2, "player"),
		_fighter("stable_b", Vector2(500.0, 260.0), 6, "enemy"),
	]
	var first := BattleRendererScript.new()
	var second := BattleRendererScript.new()
	first._begin_visual_frame(fighters, 0.0)
	second._begin_visual_frame(fighters, 0.0)
	for fighter in fighters:
		var a: Vector2 = first._visual_sim_pos_for_fighter(fighter)
		var b: Vector2 = second._visual_sim_pos_for_fighter(fighter)
		_h.expect(a.is_equal_approx(b), "fixed_slot_changed_%s" % str(fighter.uid),
			"相同单位在两次初始化中得到不同固定槽")
	first.free()
	second.free()


# Every replay sample must be drawn immediately at the same displacement. This
# rejects both the removed 10 Hz interpolation and any neighbour-driven push.
func _case_displayed_path_exactly_matches_raw_path() -> void:
	var renderer := BattleRendererScript.new()
	var fighters: Array = []
	for i in 6:
		fighters.append(_fighter("moving_%d" % i, Vector2(420.0, 240.0), i))
	renderer._begin_visual_frame(fighters, 0.0)
	var previous_raw: Dictionary = {}
	var previous_visual: Dictionary = {}
	for fighter in fighters:
		var uid := str(fighter.uid)
		previous_raw[uid] = Vector2(fighter.pos)
		previous_visual[uid] = renderer._visual_sim_pos_for_fighter(fighter)
	var max_path_error := 0.0
	for step in 12:
		var raw_step := Vector2(9.0 + float(step % 3), -3.0 + float(step % 2))
		for fighter in fighters:
			fighter.pos = Vector2(fighter.pos) + raw_step
		renderer._begin_visual_frame(fighters, 1.0 / 60.0)
		for fighter in fighters:
			var uid := str(fighter.uid)
			var raw_delta := Vector2(fighter.pos) - (previous_raw[uid] as Vector2)
			var visual := renderer._visual_sim_pos_for_fighter(fighter)
			var visual_delta := visual - (previous_visual[uid] as Vector2)
			max_path_error = maxf(max_path_error, raw_delta.distance_to(visual_delta))
			previous_raw[uid] = Vector2(fighter.pos)
			previous_visual[uid] = visual
	_h.expect(max_path_error <= 0.001, "display_path_differs_from_raw",
		"显示路径仍被插值或横推，最大误差 %.4f" % max_path_error)
	renderer.free()


# Removing or adding neighbours must never reflow a survivor's fixed slot.
func _case_neighbour_changes_never_move_survivors() -> void:
	var renderer := BattleRendererScript.new()
	var raw := Vector2(500.0, 260.0)
	var fighters: Array = []
	for slot in 8:
		fighters.append(_fighter("crowd_%d" % slot, raw, slot))
	renderer._begin_visual_frame(fighters, 0.0)
	var before: Dictionary = {}
	for fighter in fighters:
		before[str(fighter.uid)] = renderer._visual_sim_pos_for_fighter(fighter)
	for _frame in 30:
		renderer._begin_visual_frame(fighters, 1.0 / 60.0)
	var survivors := fighters.slice(0, 4)
	for _frame in 30:
		renderer._begin_visual_frame(survivors, 1.0 / 60.0)
	for fighter in survivors:
		var uid := str(fighter.uid)
		var drift := renderer._visual_sim_pos_for_fighter(fighter).distance_to(before[uid] as Vector2)
		_h.expect(drift <= 0.001, "neighbour_change_moved_%s" % uid,
			"邻居移除后 %s 漂移了 %.4f" % [uid, drift])
	renderer.free()


# An actor first seen at the arena edge may receive a truncated slot. That exact
# fitted offset must remain fixed when it later travels into the open field.
func _case_edge_fit_never_expands_during_travel() -> void:
	var renderer := BattleRendererScript.new()
	var fighter := _fighter("edge_probe", Vector2(96.0, 70.0), 0, "player")
	var fighters := [fighter]
	renderer._begin_visual_frame(fighters, 0.0)
	var first_raw := Vector2(fighter.pos)
	var first_visual := renderer._visual_sim_pos_for_fighter(fighter)
	var fixed_offset := first_visual - first_raw
	fighter.pos = Vector2(400.0, 260.0)
	renderer._begin_visual_frame(fighters, 1.0 / 60.0)
	var interior_offset := renderer._visual_sim_pos_for_fighter(fighter) - Vector2(fighter.pos)
	_h.expect(interior_offset.is_equal_approx(fixed_offset), "edge_offset_expanded",
		"单位离开边缘后固定槽发生变化：%s -> %s" % [fixed_offset, interior_offset])
	renderer.free()


# The immutable slot is presentation-only. It must not start the run animation;
# real simulator travel must still run.
func _case_animation_uses_raw_movement() -> void:
	var renderer := BattleRendererScript.new()
	add_child(renderer)
	var actor := Node3D.new()
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	actor.add_child(player)
	renderer.add_child(actor)
	var library := AnimationLibrary.new()
	var idle := Animation.new()
	idle.length = 1.0
	var run := Animation.new()
	run.length = 1.0
	library.add_animation("idle", idle)
	library.add_animation("run", run)
	player.add_animation_library("", library)
	actor.set_meta("animation_player_path", actor.get_path_to(player))
	actor.set_meta("idle_animation", "idle")
	actor.set_meta("run_animation", "run")
	actor.set_meta("attack_animation", "")
	actor.set_meta("last_animation_raw_pos", Vector2(500.0, 260.0))
	actor.set_meta("last_attack_count", 0)
	actor.set_meta("attack_lock_until", 0.0)
	actor.set_meta("run_lock_until", 0.0)
	var fighter := _fighter("animation_probe", Vector2(500.0, 260.0), 0)
	fighter["attack_count"] = 0

	renderer._fixed_visual_offset_by_id["animation_probe"] = Vector2(80.0, -45.0)
	renderer._update_model_animation_state(actor, fighter)
	_h.expect(player.current_animation == "idle", "fixed_slot_started_run",
		"单位模拟坐标没动，但固定显示偏移触发了跑步动画")
	fighter.pos = Vector2(503.0, 260.0)
	renderer._update_model_animation_state(actor, fighter)
	_h.expect(player.current_animation == "run", "raw_movement_missed_run",
		"单位真实移动 3 像素后没有进入跑步动画")
	renderer.queue_free()
