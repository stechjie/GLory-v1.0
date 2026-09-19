extends Node

# Render-only crowd spacing must separate a dense melee without ever mutating
# simulator positions. Run with:
# Godot_v4.7-stable_win64_console.exe --headless --path . tools/battle_visual_separation_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BattleRendererScript := preload("res://scenes/battle/BattleRenderer.gd")

const CHECK_NAME := "battle_visual_separation"
const DENSE_COUNT := 8
const MIN_READABLE_DISTANCE := 58.0

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_dense_stack_separates_without_touching_simulation()
	_case_pair_direction_is_deterministic()
	_h.finish(get_tree())


func _fighter(uid: String, pos: Vector2, slot: int) -> Dictionary:
	return {
		"uid": uid,
		"id": uid,
		"team": "player" if slot % 2 == 0 else "enemy",
		"slot": slot,
		"pos": pos,
		"hp": 100,
		"max_hp": 100,
		"alive": true,
		"def": {},
	}


func _case_dense_stack_separates_without_touching_simulation() -> void:
	var renderer := BattleRendererScript.new()
	var raw := Vector2(500.0, 260.0)
	var fighters: Array = []
	for i in DENSE_COUNT:
		fighters.append(_fighter("dense_%d" % i, raw, i))
	renderer._begin_visual_frame(fighters, 0.0)

	var positions: Array[Vector2] = []
	for fighter in fighters:
		positions.append(renderer._visual_sim_pos_for_fighter(fighter))
		_h.expect((fighter as Dictionary).pos == raw, "sim_position_mutated_%s" % str(fighter.uid),
			"显示层分离改写了 %s 的模拟坐标" % str(fighter.uid))

	var closest := INF
	for i in positions.size():
		for j in range(i + 1, positions.size()):
			closest = minf(closest, positions[i].distance_to(positions[j]))
	_h.expect(closest >= MIN_READABLE_DISTANCE, "dense_stack_still_overlaps",
		"8 个同点单位分离后最近距离只有 %.2f，仍会明显叠模" % closest)
	renderer.free()


func _case_pair_direction_is_deterministic() -> void:
	var fighters := [
		_fighter("pair_a", Vector2(500.0, 260.0), 0),
		_fighter("pair_b", Vector2(500.0, 260.0), 1),
	]
	var first := BattleRendererScript.new()
	var second := BattleRendererScript.new()
	first._begin_visual_frame(fighters, 0.0)
	second._begin_visual_frame(fighters, 0.0)
	for fighter in fighters:
		var a: Vector2 = first._visual_sim_pos_for_fighter(fighter)
		var b: Vector2 = second._visual_sim_pos_for_fighter(fighter)
		_h.expect(a.is_equal_approx(b), "pair_direction_changed_%s" % str(fighter.uid),
			"相同 UID 和坐标在两次求解中得到不同显示位置")
	first.free()
	second.free()
