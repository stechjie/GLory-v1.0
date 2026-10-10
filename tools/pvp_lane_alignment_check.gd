extends Node

# 门禁：PvP 的分路和棋子左右，要和房间、PvE 一致（2026-10-06 用户反馈：「平时我在最左的道，在 PvP 却突然变去最右的」）。
#
# 根因：模拟里蓝队（座位 3-5）的棋盘是左右镜像摆的（云顶式面对面），蓝队看 PvP 时画面整张转 180° 去抵消
# —— 棋子方向对了，分路左右却跟着反了：蓝队 1 号 PvE 在最左路，PvP 跑到最右。镜像还带来第二个问题：
# PvE 回合「查看另一队」看到对面主力在左边，到 PvP 它却在右边，布局没法照着看到的去针对。
#
# 现在的规矩是「正上方对正下方」（同房间里 A 在 1 正上方）：
#   · 普通 PvP 两边棋盘都不镜像（BattleSimShared.board_cell_pos 的 mirror_enemy=false）
#   · 蓝队看 PvP 只上下翻、不左右翻（BattleArena._sim_to_world_pos）
#   · 决赛（左右对打）和 PvE 的敌方照旧镜像
#
# 这里钉：
#   1. board_cell_pos 本身：不镜像时第 0 列在本路中线左边；默认（镜像）在右边。
#   2. 真的 prepare_team_state（固定对局夹具，第 6 回合 PvP）：蓝队 1 号的棋子全在最左路；
#      蓝队第 0 列在本路左边，和正下方红队第 0 列同一侧；佣兵不压在棋子身上。
#   3. 同一个蓝队棋盘：PvE 回合他自己那场（= 对面「查看另一队」看到的）第 0 列在左，PvP 也在左。
#   4. 决赛照旧镜像。
#   5. 画面：蓝队看 PvP（_arena_flip_y）只上下翻 —— 翻前翻后 x 一样、z 相反；最左路仍在最左。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const Shared := preload("res://scripts/battle/BattleSimShared.gd")
const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")
const Fixture := preload("res://scripts/qa/FixedBattleFixture.gd")
const ArenaScript := preload("res://scenes/battle/BattleArena.gd")

const SEED := 20261006
const PVP_ROUND := 6
const PVE_ROUND := 1
const BLUE_FIRST := 3   # 蓝队 1 号的座位

var _h: CheckHarness


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new("pvp_lane_alignment")
	var saved := _save_state()
	_case_board_cell_pos()
	_case_pvp_state()
	_case_scouting_matches_pvp()
	_case_final_still_mirrored()
	_case_final_spacing()
	_case_view_flip()
	_restore_state(saved)
	_h.finish(get_tree())


# --- 1. board_cell_pos -----------------------------------------------------------

func _case_board_cell_pos() -> void:
	var center := float(Shared.TEAM_LANE_CENTERS[0])
	var stacked := Shared.board_cell_pos(0, "enemy", center, false)
	var mirrored := Shared.board_cell_pos(0, "enemy", center)
	var mine := Shared.board_cell_pos(0, "player", center)
	_h.expect(stacked.x < center and mine.x < center, "stacked_col0_not_left",
		"不镜像时，敌方第 0 列应和我方第 0 列一样在本路中线左边：敌 %.0f / 我 %.0f / 中线 %.0f"
			% [stacked.x, mine.x, center])
	_h.expect(is_equal_approx(stacked.x, mine.x), "stacked_not_facing",
		"不镜像时，敌方第 0 列应正对我方第 0 列（同一个 x）：%.0f vs %.0f" % [stacked.x, mine.x])
	_h.expect(mirrored.x > center, "default_mirror_changed",
		"默认（PvE 敌方 / 决赛）应照旧镜像：敌方第 0 列在中线右边，实际 %.0f" % mirrored.x)
	_h.expect(stacked.y < Shared.ARENA_MID_Y and mine.y > Shared.ARENA_MID_Y, "rows_side_changed",
		"敌方应在上半场、我方在下半场（前后排不受这次改动影响）")


# --- 2. 真的 PvP 摆位 ---------------------------------------------------------------

func _case_pvp_state() -> void:
	_setup(PVP_ROUND, true)
	var state := BattleSim.prepare_team_state(0)
	var blue: Array = _fighters(state.get("enemy", []), BLUE_FIRST)
	var red: Array = _fighters(state.get("player", []), 0)
	if not _h.expect(not blue.is_empty() and not red.is_empty(), "pvp_fixture_empty",
			"第 %d 回合的 PvP 摆位里没有蓝队 1 号或红队 A 的棋子" % PVP_ROUND):
		return
	var lane_edge := (float(Shared.TEAM_LANE_CENTERS[0]) + float(Shared.TEAM_LANE_CENTERS[1])) * 0.5
	var outside := []
	for f in blue:
		if int(f.get("lane", -1)) != 0 or float(f.pos.x) >= lane_edge:
			outside.append("%s@%.0f" % [str(f.get("id", "")), float(f.pos.x)])
	_h.expect(outside.is_empty(), "blue_first_not_left_lane",
		"蓝队 1 号的棋子应全在最左路（房间里 1 号在最左、正对 A）：%s" % str(outside))
	var center := float(Shared.TEAM_LANE_CENTERS[0])
	var blue_col0 := _column_side(blue, 0, center)
	var red_col0 := _column_side(red, 0, center)
	_h.expect(blue_col0 == "left", "blue_col0_side",
		"蓝队摆在第 0 列（他自己的左边）的棋子，PvP 里应在本路左边，实际 %s" % blue_col0)
	_h.expect(red_col0 == "left", "red_col0_side", "红队第 0 列应在本路左边，实际 %s" % red_col0)
	# 佣兵按格子号填空格，位置要和棋子用同一套（不镜像），否则会压到棋子身上。
	var taken := {}
	var stacked := []
	for f in blue:
		var key := "%d,%d" % [roundi(float(f.pos.x)), roundi(float(f.pos.y))]
		if taken.has(key):
			stacked.append(key)
		taken[key] = true
	_h.expect(blue.any(func(f: Dictionary) -> bool: return bool(f.get("is_mercenary", false))),
		"merc_missing", "夹具里给蓝队 1 号放的佣兵没出现在 PvP 里")
	_h.expect(stacked.is_empty(), "merc_on_top_of_unit", "蓝队佣兵和棋子摆在同一个位置：%s" % str(stacked))


# --- 3. 看对面打怪时在哪，PvP 就在哪 ---------------------------------------------------

func _case_scouting_matches_pvp() -> void:
	var center := float(Shared.TEAM_LANE_CENTERS[0])
	_setup(PVE_ROUND, false)
	# 蓝队自己那场 PvE（对面点「查看另一队」看到的就是这一场，不翻转）。
	var pve := BattleSim.prepare_team_state(1)
	var pve_side := _column_side(_fighters(pve.get("player", []), BLUE_FIRST), 0, center)
	_setup(PVP_ROUND, false)
	var pvp := BattleSim.prepare_team_state(0)
	var pvp_side := _column_side(_fighters(pvp.get("enemy", []), BLUE_FIRST), 0, center)
	_h.expect(pve_side == "left" and pvp_side == pve_side, "scouting_mismatch",
		"同一个蓝队棋盘：PvE（查看另一队看到的）第 0 列在 %s，PvP 在 %s —— 看到在哪就该在哪" % [pve_side, pvp_side])


# --- 4. 决赛照旧镜像 ---------------------------------------------------------------

func _case_final_still_mirrored() -> void:
	_setup(GameState.FINAL_ROUND, false)
	GameState.final_round_played = false
	var state := BattleSim.prepare_team_state(0)
	var blue: Array = _fighters(state.get("enemy", []), BLUE_FIRST)
	# 决赛整张转 90°（模拟 x → y）。面对面镜像下，蓝队第 0 列在本路中线的「下边」（y 大）。
	var center_y := float(Shared.FINAL_LANE_CENTERS_Y[0])
	var col0 := blue.filter(func(f: Dictionary) -> bool:
		return f.has("board_cell") and int(f.board_cell) % GameConstants.BOARD_COLUMNS == 0 \
			and not bool(f.get("is_formation_ally", false)))
	if not _h.expect(not col0.is_empty(), "final_fixture_empty", "决赛摆位里没有蓝队 1 号第 0 列的棋子"):
		return
	var below := col0.all(func(f: Dictionary) -> bool: return float(f.pos.y) > center_y)
	_h.expect(below, "final_mirror_changed", "决赛（左右对打）应照旧面对面镜像，这次改动不该碰它")


func _case_final_spacing() -> void:
	_setup(GameState.FINAL_ROUND, false)
	var player: Array = []
	var enemy: Array = []
	for lane in 3:
		var center := float(Shared.TEAM_LANE_CENTERS[lane])
		for slot in GameConstants.CELL_COUNT:
			player.append({"pos": Shared.board_cell_pos(slot, "player", center),
				"lane": lane, "board_cell": slot, "footprint_cells": 1})
			enemy.append({"pos": Shared.board_cell_pos(slot, "enemy", center),
				"lane": lane, "board_cell": slot, "footprint_cells": 1})
	var player_ally := {"pos": Vector2.ZERO, "is_formation_ally": true, "footprint_cells": 4}
	var enemy_ally := {"pos": Vector2.ZERO, "is_formation_ally": true, "footprint_cells": 4}
	player.append(player_ally)
	enemy.append(enemy_ally)
	BattleSim._apply_final_round_left_right_layout(player, enemy)
	for lane in 3:
		var base := lane * GameConstants.CELL_COUNT
		var center_y := float(Shared.FINAL_LANE_CENTERS_Y[lane])
		for col in GameConstants.BOARD_COLUMNS:
			var p: Dictionary = player[base + col]
			var e: Dictionary = enemy[base + col]
			var offset := (float(col) - 1.5) * Shared.BOARD_COL_SPACING
			_h.expect(is_equal_approx(float(p.pos.y), center_y + offset),
				"final_player_pitch_%d_%d" % [lane, col], "决赛我方列距未保持 56")
			_h.expect(is_equal_approx(float(e.pos.y), center_y - offset),
				"final_enemy_pitch_%d_%d" % [lane, col], "决赛敌方镜像列距未保持 56")
		_h.expect(is_equal_approx(float(player[base + 2].pos.y - player[base].pos.y), 112.0),
			"final_empty_cell_gap_%d" % lane, "中间空一格应相隔 112 模拟像素")
	var arena = ArenaScript.new()
	for f: Dictionary in player + enemy:
		_h.expect(arena._clamp_visual_sim_pos(f.pos).is_equal_approx(f.pos),
			"final_visual_clip", "决赛 56 列距被画面边界压到一起")
	arena.free()
	for f: Dictionary in player:
		if is_same(f, player_ally):
			continue
		_h.expect(f.pos.distance_to(player_ally.pos) >= Shared.body_radius(f) + Shared.body_radius(player_ally),
			"final_player_ally_overlap", "我方法阵友军与棋盘出生点重叠")
	for f: Dictionary in enemy:
		if is_same(f, enemy_ally):
			continue
		_h.expect(f.pos.distance_to(enemy_ally.pos) >= Shared.body_radius(f) + Shared.body_radius(enemy_ally),
			"final_enemy_ally_overlap", "敌方法阵友军与棋盘出生点重叠")


# --- 5. 画面只上下翻 ----------------------------------------------------------------

func _case_view_flip() -> void:
	var arena = ArenaScript.new()
	var left := Vector2(float(Shared.TEAM_LANE_CENTERS[0]) - 40.0, 120.0)
	var right := Vector2(float(Shared.TEAM_LANE_CENTERS[2]) + 40.0, 120.0)
	arena._arena_flip_y = false
	var red_left: Vector3 = arena._sim_to_world_pos(left)
	var red_right: Vector3 = arena._sim_to_world_pos(right)
	arena._arena_flip_y = true
	var blue_left: Vector3 = arena._sim_to_world_pos(left)
	var blue_right: Vector3 = arena._sim_to_world_pos(right)
	_h.expect(is_equal_approx(blue_left.x, red_left.x) and is_equal_approx(blue_right.x, red_right.x),
		"flip_changes_x", "蓝队看 PvP 时左右被翻了（%.2f→%.2f）—— 分路会反过来，1 号跑到最右" % [red_left.x, blue_left.x])
	_h.expect(blue_left.x < blue_right.x, "lane_order", "蓝队画面里最左路应仍在最左")
	_h.expect(not is_equal_approx(blue_left.z, red_left.z), "flip_lost_y",
		"蓝队看 PvP 时没有上下翻 —— 自己会在上面")
	arena.free()


# --- 工具 --------------------------------------------------------------------------

func _setup(round_index: int, with_merc: bool) -> void:
	Fixture.setup_match_state(round_index, SEED)
	if with_merc:
		var defs := Fixture.unit_defs()
		var mercs := Fixture.empty_mercenary_slots()
		mercs[0] = {"id": "dark_suc", "star": 1, "def": (defs["dark_suc"] as Dictionary).duplicate(true), "is_mercenary": true}
		var boards: Dictionary = NetworkService.team_boards
		boards[BLUE_FIRST] = Fixture.board_submission(
			Fixture.board_from_ids(Fixture.lineup("b")[0]), mercs)
		NetworkService.team_boards = boards


func _fighters(side: Array, owner_slot: int) -> Array:
	return side.filter(func(f: Dictionary) -> bool: return int(f.get("owner_slot", -1)) == owner_slot)


# 第 col 列的棋子（不含佣兵）在本路中线哪一边：left / right / mixed / none。
func _column_side(fighters: Array, col: int, center: float) -> String:
	var sides := {}
	for f in fighters:
		if bool(f.get("is_mercenary", false)) or not f.has("board_cell"):
			continue
		if int(f.board_cell) % GameConstants.BOARD_COLUMNS != col:
			continue
		sides["left" if float(f.pos.x) < center else "right"] = true
	if sides.is_empty():
		return "none"
	return str(sides.keys()[0]) if sides.size() == 1 else "mixed"


func _save_state() -> Dictionary:
	return {
		"team_active": NetworkService.team_active,
		"team_local_slot": NetworkService.team_local_slot,
		"shared_seed": NetworkService.shared_seed,
		"team_slot_states": (NetworkService.team_slot_states as Array).duplicate(),
		"team_boards": (NetworkService.team_boards as Dictionary).duplicate(true),
	}


func _restore_state(saved: Dictionary) -> void:
	GameState.reset_run()
	NetworkService.team_active = bool(saved.team_active)
	NetworkService.team_local_slot = int(saved.team_local_slot)
	NetworkService.shared_seed = int(saved.shared_seed)
	NetworkService.team_slot_states = saved.team_slot_states
	NetworkService.team_boards = saved.team_boards
