extends Node

# Body contacts are resolved in the simulator; the renderer must not add offsets.
# The central invariant is strict: displayed_delta == raw_delta for every actor.
# Run with:
# Godot_v4.7-stable_win64_console.exe --headless --path . tools/battle_visual_separation_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BattleRendererScript := preload("res://scenes/battle/BattleRenderer.gd")

const CHECK_NAME := "battle_visual_separation"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_renderer_preserves_authoritative_contacts()
	_case_fixed_slots_are_deterministic()
	_case_displayed_path_exactly_matches_raw_path()
	_case_neighbour_changes_never_move_survivors()
	_case_edge_fit_never_expands_during_travel()
	_case_animation_uses_raw_movement()
	_case_interp_stays_on_tick_segment()
	_case_interp_snaps_large_jump()
	_case_interp_new_actor_snaps()
	_case_interp_snap_restores_raw()
	_case_interp_leaves_animation_raw()
	_case_archer_intercept_uses_display_tick()
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


func _case_renderer_preserves_authoritative_contacts() -> void:
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

	for position in positions:
		_h.expect(position == raw, "renderer_added_collision_offset",
			"表现层不能另外推开模型，否则血条/伤害判定与服务器坐标分离")
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


# With no tick-to-tick interpolation in progress (alpha 1, the default and every
# seek/skip/finish path) each sample is drawn at exactly the raw displacement.
# This still rejects any neighbour-driven push or easing.
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


# --- 10.29 逻辑帧之间的显示插值 ------------------------------------------------

func _interp_renderer(fighters: Array) -> Node:
	var renderer := BattleRendererScript.new()
	renderer._state = {"player": fighters, "enemy": [], "elapsed": 0.0}
	renderer._begin_visual_frame(fighters, 0.0)
	return renderer


# 进度 0 = 上一逻辑帧，进度 1 = 当前逻辑帧（与原始坐标逐字相等），中间都在连线上。
func _case_interp_stays_on_tick_segment() -> void:
	var fighter := _fighter("interp_walk", Vector2(420.0, 240.0), 0)
	var renderer := _interp_renderer([fighter])
	var from_visual: Vector2 = renderer._visual_sim_pos_for_fighter(fighter)
	renderer._visual_interp_capture_tick_start()
	var step := Vector2(17.6, -4.0)
	fighter.pos = Vector2(fighter.pos) + step
	var max_off_segment := 0.0
	var max_progress_error := 0.0
	for k in 11:
		var alpha := float(k) / 10.0
		renderer._visual_interp_set_alpha(alpha)
		renderer._begin_visual_frame([fighter], 1.0 / 60.0)
		var shown: Vector2 = renderer._visual_sim_pos_for_fighter(fighter)
		var expected := from_visual + step * alpha
		max_off_segment = maxf(max_off_segment, shown.distance_to(expected))
		if k == 0:
			max_progress_error = maxf(max_progress_error, shown.distance_to(from_visual))
	_h.expect(max_off_segment <= 0.001, "interp_left_tick_segment",
		"插值位置偏离两帧连线，最大误差 %.4f" % max_off_segment)
	_h.expect(max_progress_error <= 0.001, "interp_alpha0_not_previous_tick",
		"进度 0 时没有停在上一逻辑帧")
	renderer._visual_interp_set_alpha(1.0)
	renderer._begin_visual_frame([fighter], 1.0 / 60.0)
	var at_one: Vector2 = renderer._visual_sim_pos_for_fighter(fighter)
	_h.expect(at_one == from_visual + step or at_one.is_equal_approx(from_visual + step), "interp_alpha1_not_raw",
		"进度 1 时显示位置 %s 不等于逻辑位置 %s" % [at_one, from_visual + step])
	renderer.free()


# 闪现/冲锋这类单帧大位移当帧到位，不在半路画一个从没存在过的位置。
func _case_interp_snaps_large_jump() -> void:
	var fighter := _fighter("interp_blink", Vector2(300.0, 240.0), 0)
	var renderer := _interp_renderer([fighter])
	renderer._visual_interp_capture_tick_start()
	fighter.pos = Vector2(fighter.pos) + Vector2(renderer.VISUAL_INTERP_SNAP_SIM + 30.0, 0.0)
	renderer._visual_interp_set_alpha(0.3)
	renderer._begin_visual_frame([fighter], 1.0 / 60.0)
	var shown: Vector2 = renderer._visual_sim_pos_for_fighter(fighter)
	_h.expect(shown.is_equal_approx(Vector2(fighter.pos)), "interp_large_jump_not_snapped",
		"单帧位移超过阈值仍被插值：显示 %s，逻辑 %s" % [shown, Vector2(fighter.pos)])
	renderer.free()


# 推进前不在场的单位（召唤、复活）没有上一帧，当帧显示逻辑位置。
func _case_interp_new_actor_snaps() -> void:
	var walker := _fighter("interp_old", Vector2(300.0, 240.0), 0)
	var renderer := _interp_renderer([walker])
	renderer._visual_interp_capture_tick_start()
	var summon := _fighter("interp_summon", Vector2(520.0, 250.0), 1)
	renderer._state["player"] = [walker, summon]
	renderer._visual_interp_set_alpha(0.4)
	renderer._begin_visual_frame([walker, summon], 1.0 / 60.0)
	var shown: Vector2 = renderer._visual_sim_pos_for_fighter(summon)
	_h.expect(shown.is_equal_approx(Vector2(summon.pos)), "interp_new_actor_not_snapped",
		"新出现的单位被插值到了 %s" % shown)
	renderer.free()


# 跳帧/定位/结算调用 _visual_interp_snap 后，立刻回到逻辑坐标。
func _case_interp_snap_restores_raw() -> void:
	var fighter := _fighter("interp_seek", Vector2(300.0, 240.0), 0)
	var renderer := _interp_renderer([fighter])
	renderer._visual_interp_capture_tick_start()
	fighter.pos = Vector2(fighter.pos) + Vector2(15.0, 0.0)
	renderer._visual_interp_set_alpha(0.5)
	renderer._visual_interp_snap()
	renderer._begin_visual_frame([fighter], 1.0 / 60.0)
	var shown: Vector2 = renderer._visual_sim_pos_for_fighter(fighter)
	_h.expect(shown.is_equal_approx(Vector2(fighter.pos)), "interp_snap_not_raw",
		"snap 之后仍显示插值位置 %s" % shown)
	_h.expect(renderer._interp_prev_pos_by_id.is_empty(), "interp_snap_kept_prev",
		"snap 之后上一帧记录没有清空")
	renderer.free()


# 插值只改显示坐标；动画判定继续读逻辑坐标，静止单位不会因插值进入跑步。
func _case_interp_leaves_animation_raw() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/battle/BattleRenderer.gd")
	var start := src.find("func _update_model_animation_state(")
	var stop := src.find("\nfunc ", start + 10)
	var body := src.substr(start, stop - start) if start >= 0 else ""
	_h.expect(not body.is_empty(), "animation_state_fn_missing", "找不到 _update_model_animation_state")
	_h.expect(body.find("var current_sim_pos := Vector2(float(f.pos.x), float(f.pos.y))") >= 0,
		"animation_reads_display_pos", "跑步判定必须读逻辑坐标 f.pos")
	_h.expect(body.find("_visual_interp_raw_pos(") < 0 and body.find("_visual_sim_pos_for_fighter(") < 0,
		"animation_reads_interp_pos", "跑步判定不得读插值后的显示坐标")


# 弓箭手预判：目标锚点是插值后的显示位置，预判必须从显示时刻起算。
# 目标在第 3 帧停下：显示进度 0.5 时它画在 25，箭飞 1 帧后它在 30，
# 正确的落点偏移是 +5；旧算法（从逻辑帧 3 起算）给 0，箭会落在目标身后。
func _case_archer_intercept_uses_display_tick() -> void:
	var screen_script: GDScript = load("res://scenes/battle/BattleScreen.gd")
	var screen: Node = screen_script.new()
	var uid := "archer_target"
	var xs := [0.0, 10.0, 20.0, 30.0, 30.0, 30.0]
	var frames: Array = []
	for x in xs:
		frames.append([[uid, 400.0 + float(x), 240.0, 100, true]])
	screen._replay_mode = true
	screen._replay = {"frames": frames}
	screen._readable_speed = 1.0
	screen._archer_intercept_tick = 3
	screen._interp_prev_pos_by_id = {uid: Vector2(420.0, 240.0)}
	screen._interp_alpha = 0.5
	var flight: float = screen.SIM_TICK_SEC / screen.PLAYBACK_SPEED
	var anchor := Vector3(1.0, 0.0, 2.0)
	var got: Variant = screen.cue_archer_replay_intercept(uid, anchor, flight)
	var want: Vector3 = anchor + screen._sim_to_world_pos(Vector2(430.0, 240.0)) - screen._sim_to_world_pos(Vector2(425.0, 240.0))
	_h.expect(got is Vector3 and (got as Vector3).is_equal_approx(want), "archer_intercept_ignores_display_tick",
		"预判落点 %s，应为 %s" % [str(got), str(want)])
	screen._interp_alpha = 1.0
	screen._interp_prev_pos_by_id = {}
	var settled: Variant = screen.cue_archer_replay_intercept(uid, anchor, flight)
	_h.expect(settled is Vector3 and (settled as Vector3).is_equal_approx(anchor), "archer_intercept_alpha1_changed",
		"进度 1 时预判应与原算法一致（目标已停下，偏移为 0），得到 %s" % str(settled))
	screen.free()
