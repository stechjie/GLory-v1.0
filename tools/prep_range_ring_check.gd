extends Node

# 11-08 用户要求：「在摆放界面的时候，玩家拖动棋子会显示棋子的攻击距离」。
#
# 做法（PrepBoardModels / PrepUI / BoardHud）：
#   * 射程圈是躺在棋盘地面上的 3D 面片（PrepRangeRing），与站位图同一层，棋子挡在它上面；
#   * 半径 = 战斗判定同一个公式（BattleSimShared.range_px_for + 体型半格），
#     再按「战斗里一列 56、一行 44」逐轴换算到棋盘的列宽 / 行深；
#   * 拖动中：圆心 = 手指悬着的那一格（BoardHud.range_hover_index，能不能放下都算，
#     悬在原格上也画），射程取被拖的那只（棋盘 / 待命 / 商店卡）；离开棋盘格、松手就撤；
#   * 跟「战场辅助标记」开关走。
#
# 判据（每一条都指着会坏的那一处）：
#   A 半径公式与战斗判定同口径；逐轴换算正确（换成格数 = 模拟像素 / 列距或行距）
#   B 面片在棋盘 3D 视口里、层级在站位图之上待命台之下、平时藏着
#   C 拖棋盘棋子：悬到别的格 → 圈在那格；悬回原格（不能放下）→ 圈也在原格；
#     离开格子 → 撤；松手收尾 → 撤
#   D 拖待命棋子、拖商店卡：射程取被拖的那只，不是格子上原来那只
#   E 没在拖时 hover 不生效；关掉辅助标记开关就不画
#
# 运行：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/prep_range_ring_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const PrepBoardModels := preload("res://scenes/prep/PrepBoardModels.gd")

const CHECK_NAME := "prep_range_ring"

const RANGE4_UNIT := "god_priest"      # 射程 4
const RANGE1_UNIT := "god_guard"       # 射程 1
const RANGE2_UNIT := "dark_queen"      # 射程 2（商店卡用）
const RANGE15_UNIT := "human_king"     # 射程 1.5（被拖的不是它：用来证明取的是被拖那只）

var _h: CheckHarness
# 不标类型：下面直接调摆放界面的方法。写成 .call("名字") 会被 dynamic_call_check
# 记作「接收者不明」，那个数只许降不许升。
var _screen
var _definitions := {}


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	DataRegistry.ensure_loaded()
	for unit in DataRegistry.get_table("race_units").get("units", []):
		_definitions[str(unit.get("id", ""))] = unit
	_case_formula()
	_screen = await _spawn()
	if _screen == null:
		_h.finish(get_tree())
		return
	_case_ring_node()
	_case_drag_board_piece()
	_case_drag_bench_and_shop()
	_case_guards()
	_teardown()
	await get_tree().process_frame
	_h.finish(get_tree())


# --- 夹具 ---------------------------------------------------------------------

func _spawn() -> Variant:
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "PrepScreen.tscn 无法加载"):
		return null
	GameState.reset_run()
	GameState.tutorial_mode = false
	NetworkService.team_active = false
	NetworkService.is_host = false
	var screen: Node = packed.instantiate()
	add_child(screen)
	for _i in 12:
		await get_tree().process_frame
	return screen


func _teardown() -> void:
	if _screen != null and is_instance_valid(_screen):
		_screen.queue_free()
	_screen = null


func _hud() -> Variant:
	return _screen.get("_board_hud")


func _cell(index: int) -> Variant:
	return _hud().buttons[index]


func _ring() -> Dictionary:
	return _screen.prep_range_ring_snapshot()


func _piece(unit_id: String) -> Dictionary:
	return {"uid": GameState.mint_piece_uid(), "id": unit_id, "star": 1,
		"def": (_definitions.get(unit_id, {}) as Dictionary).duplicate(true)}


func _clear_slots() -> void:
	for i in GameState.board_slots.size():
		GameState.board_slots[i] = null
	for i in GameState.bench_slots.size():
		GameState.bench_slots[i] = null


func _expect_ring(code: String, center: int, range_value: float, context: String) -> void:
	var ring := _ring()
	var want_px := BattleSimShared.range_px_for(range_value)
	_h.expect(bool(ring.get("visible", false)) and int(ring.get("center_index", -1)) == center
			and is_equal_approx(float(ring.get("range_px", 0.0)), want_px),
		code,
		"%s：期望射程圈在第 %d 格、半径 %.0f 模拟像素（射程 %s），实际 visible=%s 第 %d 格 %.0f"
			% [context, center, want_px, str(range_value), str(ring.get("visible", false)),
				int(ring.get("center_index", -1)), float(ring.get("range_px", 0.0))])


func _expect_no_ring(code: String, context: String) -> void:
	var ring := _ring()
	_h.expect(not bool(ring.get("visible", true)) and int(ring.get("center_index", 0)) == -1,
		code, "%s：射程圈应当撤掉，实际 visible=%s 第 %d 格"
			% [context, str(ring.get("visible", true)), int(ring.get("center_index", 0))])


# --- A 半径公式 ---------------------------------------------------------------

func _case_formula() -> void:
	for range_value in [1.0, 1.5, 2.0, 3.0, 4.0]:
		var px := PrepBoardModels.prep_range_px_for_def({"range": range_value})
		_h.expect(is_equal_approx(px, BattleSimShared.range_px_for(range_value)), "formula_range",
			"射程 %s 的射程圈半径 %.1f 与战斗判定 %.1f 不同 —— 圈和实际打得到的距离对不上"
				% [str(range_value), px, BattleSimShared.range_px_for(range_value)])
	# 体型大的单位判定时自己多半格（BattleSimShared._effective_attack_distance 的 attacker_extra）。
	var big := PrepBoardModels.prep_range_px_for_def({"range": 1.0, "footprint_cells": 2})
	_h.expect(is_equal_approx(big, BattleSimShared.range_px_for(1.0) + BattleSimShared.CELL_SPACING * 0.5),
		"formula_footprint", "占 2 格的单位应多算半格（%.1f），实际 %.1f"
			% [BattleSimShared.range_px_for(1.0) + BattleSimShared.CELL_SPACING * 0.5, big])
	# 逐轴换算：地面半径 ÷ 一列（一行）的世界长度 = 模拟像素 ÷ 列距（行距）。
	var px4 := BattleSimShared.range_px_for(4.0)
	var radii := PrepBoardModels.prep_range_ring_world_radii(px4)
	var col_world := (PrepBoardModels.BOARD_STONE_U.y - PrepBoardModels.BOARD_STONE_U.x) \
		/ float(GameConstants.BOARD_COLUMNS) * PrepBoardModels.PREP_BOARD_GROUND_SIZE.x
	var row_world := (PrepBoardModels.BOARD_STONE_V.y - PrepBoardModels.BOARD_STONE_V.x) \
		/ float(GameConstants.BOARD_ROWS) * PrepBoardModels.PREP_BOARD_GROUND_SIZE.y
	_h.expect(is_equal_approx(radii.x / col_world, px4 / BattleSimShared.BOARD_COL_SPACING)
			and is_equal_approx(radii.y / row_world, px4 / BattleSimShared.BOARD_ROW_SPACING),
		"formula_axes", "射程圈换算成格数应与战斗一致：横 %.2f 列 / 纵 %.2f 行，实际 %.2f / %.2f"
			% [px4 / BattleSimShared.BOARD_COL_SPACING, px4 / BattleSimShared.BOARD_ROW_SPACING,
				radii.x / col_world, radii.y / row_world])


# --- B 面片本身 ---------------------------------------------------------------

func _case_ring_node() -> void:
	var ring := _ring()
	_h.expect(bool(ring.get("exists", false)), "ring_missing", "摆放界面没建出射程圈面片")
	_h.expect(bool(ring.get("in_board_world", false)), "ring_not_in_board_world",
		"射程圈不在棋盘的 3D 视口里 —— 放到 2D 层会整块盖住棋子（10.05 计数图案的教训）")
	_h.expect(int(ring.get("render_priority", -1)) == PrepBoardModels.PREP_RANGE_RING_RENDER_PRIORITY,
		"ring_priority", "射程圈层级应为 %d（站位图之上、待命台之下），实际 %d"
			% [PrepBoardModels.PREP_RANGE_RING_RENDER_PRIORITY, int(ring.get("render_priority", -1))])
	var lift := float(ring.get("y_lift", -1.0))
	_h.expect(lift > PrepBoardModels.PREP_CELL_MARK_Y_LIFT and lift < PrepBoardModels.PREP_STANDBY_BG_Y_LIFT,
		"ring_lift", "射程圈离地 %.4f，应在站位图（%.4f）与待命台（%.4f）之间"
			% [lift, PrepBoardModels.PREP_CELL_MARK_Y_LIFT, PrepBoardModels.PREP_STANDBY_BG_Y_LIFT])
	_expect_no_ring("ring_idle_visible", "没拖、没长按")


# --- C 拖棋盘上的棋子 ---------------------------------------------------------

func _case_drag_board_piece() -> void:
	_clear_slots()
	GameState.board_slots[13] = _piece(RANGE4_UNIT)
	GameState.board_slots[6] = _piece(RANGE15_UNIT)
	_hud().refresh_board()
	var payload := {"kind": "board", "index": 13}
	_screen._on_drag_started(payload)
	_expect_no_ring("drag_ring_before_hover", "刚起拖、手指还没悬到任何格子上")

	# 走真实的格子按钮：引擎拖动中每帧对鼠标下的控件调 _can_drop_data。
	_cell(2)._can_drop_data(Vector2.ZERO, payload)
	_expect_ring("drag_ring_follow_hover", 2, 4.0, "拖射程 4 的棋子悬到第 2 格")

	# 悬到有别的棋子的格子（换位）：射程仍是被拖的那只，不是格子上的人王。
	_cell(6)._can_drop_data(Vector2.ZERO, payload)
	_expect_ring("drag_ring_uses_dragged_unit", 6, 4.0, "悬到人王所在的第 6 格（射程应取被拖的弓手）")

	# 悬回原格：PrepRules 不让放回原格（drop hover = -1），但射程圈要画 —— 玩家会先看一眼现在的射程。
	var can_drop: bool = _cell(13)._can_drop_data(Vector2.ZERO, payload)
	_h.expect(not can_drop, "origin_droppable_changed",
		"原格变成可放下了 —— 下面「悬回原格也画圈」那条的前提不成立，要重看")
	_expect_ring("drag_ring_on_origin", 13, 4.0, "悬回棋子原来那格")

	_cell(13)._on_mouse_exited()
	_expect_no_ring("drag_ring_after_exit", "手指离开棋盘格")

	_cell(2)._can_drop_data(Vector2.ZERO, payload)
	_screen._finish_drag_state()
	_expect_no_ring("drag_ring_after_release", "松手收尾之后")
	_h.expect(int(_hud().range_hover_index) == -1, "range_hover_not_reset",
		"松手收尾后 range_hover_index 没清（%d）—— 下一次起拖会带着旧圆心" % int(_hud().range_hover_index))


# --- D 拖待命棋子、拖商店卡 ---------------------------------------------------

func _case_drag_bench_and_shop() -> void:
	_clear_slots()
	GameState.bench_slots[0] = _piece(RANGE1_UNIT)
	GameState.board_slots[5] = _piece(RANGE4_UNIT)
	_hud().refresh_board()
	_hud().refresh_bench()
	var bench_payload := {"kind": "bench", "index": 0}
	_screen._on_drag_started(bench_payload)
	_cell(5)._can_drop_data(Vector2.ZERO, bench_payload)
	_expect_ring("drag_bench_ring", 5, 1.0, "拖待命区射程 1 的棋子悬到第 5 格（格子上原来是射程 4）")
	_screen._finish_drag_state()

	if not _h.expect(GameState.shop_offers.size() > 0 and GameState.shop_sold.size() > 0, "shop_offers_empty",
			"商店没有报价位 —— 拖商店卡这条测不了"):
		return
	var saved_offer = GameState.shop_offers[0]
	var saved_sold = GameState.shop_sold[0]
	GameState.shop_offers[0] = (_definitions.get(RANGE2_UNIT, {}) as Dictionary).duplicate(true)
	GameState.shop_sold[0] = false
	var shop_payload := {"kind": "shop", "index": 0}
	_screen._on_drag_started(shop_payload)
	_cell(9)._can_drop_data(Vector2.ZERO, shop_payload)
	_expect_ring("drag_shop_ring", 9, 2.0, "拖商店里射程 2 的卡悬到第 9 格")
	_screen._finish_drag_state()
	GameState.shop_offers[0] = saved_offer
	GameState.shop_sold[0] = saved_sold


# --- E 守卫 -------------------------------------------------------------------

func _case_guards() -> void:
	_clear_slots()
	GameState.board_slots[13] = _piece(RANGE4_UNIT)
	_hud().refresh_board()
	# 没在拖：hover 不该生效（set_board_range_hover 认 drop_highlight_active）。
	_hud().set_board_range_hover(2)
	_expect_no_ring("ring_without_drag", "没在拖时设 hover")

	# 关掉「战场辅助标记」：拖动也不画。直接改字段、不走 set_board_readability_enabled（那个会存档）。
	var saved := PlayerProfile.board_readability_enabled
	PlayerProfile.board_readability_enabled = false
	var payload := {"kind": "board", "index": 13}
	_screen._on_drag_started(payload)
	_cell(2)._can_drop_data(Vector2.ZERO, payload)
	_expect_no_ring("ring_with_guides_off", "关掉战场辅助标记后拖动")
	_screen._finish_drag_state()
	PlayerProfile.board_readability_enabled = saved
