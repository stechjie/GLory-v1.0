extends Node

# 10.12 bug 文档第 4 条 —— 备战棋子 轻点 / 长按 / 拖拽 三态。
#
# 需求（用户原话）：
#   「只是点击棋子的时候，不会变成选中棋子；长按棋子不动为查看属性，查看属性不会
#     使棋子变成挪动状态；按住棋子（未出现属性弹窗时）进行拖动到相应落点才会进行挪动。」
#
# 旧实现为什么错（根因，代码级）：
#   棋盘格/待命格的 `pressed` 与 `attach_long_press` 挂在**同一个按钮**上，而
#   `pressed` 的回调（PrepUI._on_board_pressed / _on_bench_pressed）既管「点 A 选中
#   → 点 B 把 A 挪过去」，又管「商店卡已选中 → 点格子买入」。长按动作超时后会同时
#   把 long_press_consumed 置位**并**照常发 pressed，于是同一次长按既弹了属性框、
#   又把 A 设成选中态；关掉属性框后 A 还是选中的，下一次轻点别的格子就把它挪走。
#
# 修法：
#   1) 新增 PrepUI._on_board_activated / _on_bench_activated 两个 wrapper，先用
#      PrepDetailOverlay.consume_long_press() 吃掉「长按 / 拖拽取消」那一次，再转交业务；
#   2) _on_board_pressed / _on_bench_pressed 里「点 A 选中 → 点 B 挪过去」整条链删除
#      （挪动只剩拖拽一条路：PrepDragButton 起拖 → _drop_on_board/_drop_on_bench）；
#   3) 射程预览改挂在「长按查看属性」上（PrepUI._inspect_board_cell），详情框一关
#      （PrepScreen._process → _sync_board_inspect_after_overlay）就撤掉高亮。
#
# 判据（每一条都指着会坏的那一处，且都做了变异验证）：
#   A 轻点棋子不选中（棋盘 / 空格 / 待命格）
#   B 轻点不挪动：旧链的四种方向（场↔场、待命→场、场→待命）都不能再靠轻点完成
#   C 长按不穿透：long_press_consumed 那一次绝不能落到业务上（不买入、不选中）；
#     反向用例证明守卫不会把正常轻点也挡掉
#   D 拖拽仍能挪动（场→场、待命→场）—— 唯一剩下的挪动路径不能坏
#   E 长按查看属性会点亮检视格 + 算出射程格；详情框关掉后翻转那一下必须撤掉高亮
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/prep_piece_interaction_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "prep_piece_interaction"

# range=1 的单位（射程格 = 本格 + 正交四邻，4×4 下 index 0 → {0,1,4}），
# 用来把「射程预览算得出东西」判得具体一点，range=4 的会把整盘都盖住。
const RANGE1_UNIT := "god_guard"
const RANGE4_UNIT := "god_priest"
const OTHER_UNIT := "god_aurora"
# 商店买入链路用的非唯一、买得起的单位。
const SHOP_UNIT := "god_guard"

var _h: CheckHarness
var _screen: Node


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_screen = await _spawn()
	if _screen == null:
		_h.finish(get_tree())
		return
	_case_tap_does_not_select()
	_case_tap_does_not_move_pieces()
	_case_long_press_does_not_fall_through()
	_case_bench_tap_does_not_select()
	_case_drag_still_moves()
	await _case_inspect_lights_range_and_clears()
	await _case_long_press_blocks_drag_for_this_gesture()
	_teardown()
	await get_tree().process_frame
	_h.finish(get_tree())


# --- 夹具 ---------------------------------------------------------------------

func _spawn() -> Node:
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "PrepScreen.tscn 无法加载"):
		return null
	# 教学局会走另一套（TutorialMode 会接管部分刷新），这一条测的是普通备战。
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


func _hud() -> Node:
	return _screen.get("_board_hud")


func _shop() -> Variant:
	return _screen.get("_shop")


func _overlay() -> Variant:
	return _screen.get("_overlay")


func _cell(index: int) -> BaseButton:
	return _hud().buttons[index] as BaseButton


func _bench_card(index: int) -> BaseButton:
	return _hud().bench_buttons[index] as BaseButton


func _selected_board() -> int:
	return int(_hud().get("_selected_board"))


func _selected_bench() -> int:
	return int(_hud().get("_selected_bench"))


func _uid(cell: Variant) -> String:
	if typeof(cell) != TYPE_DICTIONARY:
		return ""
	return str((cell as Dictionary).get("uid", ""))


func _def_for(id: String) -> Dictionary:
	for unit in DataRegistry.get_table("race_units").get("units", []):
		if str((unit as Dictionary).get("id", "")) == id:
			return unit as Dictionary
	return {}


func _piece(id: String) -> Dictionary:
	return {"id": id, "uid": GameState.mint_piece_uid(), "star": 1, "def": _def_for(id).duplicate(true)}


# 清空全部格子 + 待命区 + 商店选中 + 检视标记，避免用例间互相污染。
#
# ★ 摆棋子时**每只用不同的 id**，别图省事全用同一个：`_refresh_all()` 的第一步是
#   `_auto_combine_all()`，它把棋盘与待命区**一起**按 id+star 分组，两份同名同星
#   1 星会在任何一次刷新里自动融成 2 星（`copies_to_upgrade(1) == 2`）。
#   本门禁第一版就踩了这个坑：E 用例摆了两只 god_guard，第一次 `_drop_on_board`
#   触发的刷新把它们合掉了，第二次拖拽的 from_cell 已经是 null，
#   于是「待命 → 棋盘拖拽」这条断言假红。
func _clear_slots() -> void:
	for i in GameState.board_slots.size():
		GameState.board_slots[i] = null
	for i in GameState.bench_slots.size():
		GameState.bench_slots[i] = null
	_hud().set("_selected_board", -1)
	_hud().set("_selected_bench", -1)
	var shop: Variant = _shop()
	if shop != null:
		shop.set("selected", -1)


# 摆一张确定性商店卡（第 0 格），其余清空。
func _prepare_offer(unit_id: String) -> void:
	for i in GameState.shop_offers.size():
		GameState.shop_offers[i] = {}
		GameState.shop_sold[i] = false
	GameState.shop_offers[0] = _def_for(unit_id).duplicate(true)


# --- A 轻点不选中 -------------------------------------------------------------

func _case_tap_does_not_select() -> void:
	_clear_slots()
	GameState.board_slots[0] = _piece(RANGE1_UNIT)
	GameState.bench_slots[0] = _piece(RANGE4_UNIT)

	_screen.call("_on_board_activated", 0, _cell(0))
	_h.expect(_selected_board() == -1, "tap_selected_board",
		"轻点棋盘棋子后 _selected_board=%d —— 第 4 条要求轻点不选中棋子" % _selected_board())
	_h.expect(_selected_bench() == -1, "tap_selected_bench_sideeffect",
		"轻点棋盘棋子后 _selected_bench=%d —— 轻点不该动任何选中态" % _selected_bench())

	# 空格也不该被选中（旧实现会把空格设 -1，但那是"顺手清空"，语义不同；
	# 这里钉的是「轻点空格后仍然没有任何选中格」）。
	_screen.call("_on_board_activated", 5, _cell(5))
	_h.expect(_selected_board() == -1, "tap_empty_selected",
		"轻点空格后 _selected_board=%d —— 空格也不该被选中" % _selected_board())

	# 轻点也不该弹出属性框（属性框是长按的职责）。
	var overlay: Variant = _overlay()
	if overlay != null and bool(overlay.call("is_ready")):
		overlay.call("hide_detail")
		_screen.call("_on_board_activated", 0, _cell(0))
		_h.expect(not bool(overlay.call("is_showing")), "tap_opened_detail",
			"轻点棋子弹出了属性框 —— 属性框只应由长按（0.7s）触发")


# --- B 轻点不挪动（旧「点 A 选中 → 点 B 挪过去」链已删） ------------------------

func _case_tap_does_not_move_pieces() -> void:
	_clear_slots()
	GameState.board_slots[0] = _piece(RANGE1_UNIT)
	GameState.board_slots[1] = _piece(RANGE4_UNIT)
	GameState.bench_slots[0] = _piece(OTHER_UNIT)
	var uid_board0 := _uid(GameState.board_slots[0])
	var uid_board1 := _uid(GameState.board_slots[1])
	var uid_bench0 := _uid(GameState.bench_slots[0])

	# 故意摆出旧实现的残留：一个「选中格」。第 4 条之后它最多只是射程预览标记，
	# 绝不能成为「下一次轻点就把棋子挪走」的起点。
	_hud().set("_selected_board", 0)
	_screen.call("_on_board_activated", 1, _cell(1))
	_h.expect(_uid(GameState.board_slots[0]) == uid_board0 and _uid(GameState.board_slots[1]) == uid_board1,
		"tap_moved_board_board",
		"轻点另一个棋盘格把棋子挪走了 —— 「点 A 选中 → 点 B 挪过去」这条链应已删除")

	_hud().set("_selected_bench", 0)
	_screen.call("_on_board_activated", 5, _cell(5))
	_h.expect(GameState.board_slots[5] == null and _uid(GameState.bench_slots[0]) == uid_bench0,
		"tap_moved_bench_board",
		"轻点棋盘空格把待命区棋子挪上去了 —— 轻点不该是挪动入口（只能拖）")

	_hud().set("_selected_board", 1)
	_screen.call("_on_bench_activated", 1, _bench_card(1))
	_h.expect(GameState.bench_slots[1] == null and _uid(GameState.board_slots[1]) == uid_board1,
		"tap_moved_board_bench",
		"轻点待命格把棋盘棋子挪下去了 —— 同上")


# --- C 长按不穿透到业务 -------------------------------------------------------

func _case_long_press_does_not_fall_through() -> void:
	_clear_slots()
	_prepare_offer(SHOP_UNIT)
	GameState.gold = 500
	var shop: Variant = _shop()
	var cell := _cell(6)

	# 长按超时那一次在按钮 meta 上留下的判据（PrepDetailOverlay.attach_long_press 写）。
	cell.set_meta("long_press_triggered", true)
	cell.set_meta("long_press_consumed", true)
	cell.set_meta("long_press_cancelled", false)
	shop.set("selected", 0)
	var gold_before := GameState.gold

	_screen.call("_on_board_activated", 6, cell)
	_h.expect(int(shop.get("selected")) == 0, "long_press_ran_business",
		"长按松手那一下仍执行了业务（_shop.selected 被清成 %s）—— 旧版正是这样顺手选中的" % str(shop.get("selected")))
	_h.expect(GameState.gold == gold_before and GameState.board_slots[6] == null, "long_press_bought",
		"长按被当成一次轻点买入了：gold %d→%d，目标格=%s" % [gold_before, GameState.gold, str(GameState.board_slots[6])])
	_h.expect(_selected_board() == -1, "long_press_selected",
		"长按后棋盘出现选中格（_selected_board=%d）—— 第 4 条要求「查看属性不会使棋子变成挪动状态」" % _selected_board())
	_h.expect(not bool(cell.get_meta("long_press_consumed", false)), "long_press_not_consumed",
		"长按判据没有被消费掉 —— 同一次手势的余波会污染下一次输入")

	# 反向：判据清干净后，同样的轻点必须**真的**能买入。
	# 没有这一条的话，把 wrapper 写成「一律 return」也能让上面四条全绿。
	cell.set_meta("long_press_triggered", false)
	cell.set_meta("long_press_consumed", false)
	cell.set_meta("long_press_cancelled", false)
	shop.set("selected", 0)
	_screen.call("_on_board_activated", 6, cell)
	_h.expect(GameState.board_slots[6] != null, "tap_blocked_by_guard",
		"清干净长按判据后的普通轻点被挡下了 —— 「商店卡选中 → 点格子买入」这条链断了")


# --- D 轻点待命格不选中 -------------------------------------------------------

func _case_bench_tap_does_not_select() -> void:
	_clear_slots()
	GameState.bench_slots[2] = _piece(RANGE4_UNIT)
	_screen.call("_on_bench_activated", 2, _bench_card(2))
	_h.expect(_selected_bench() == -1, "bench_tap_selected",
		"轻点待命棋子后 _selected_bench=%d —— 第 4 条要求轻点不选中" % _selected_bench())
	_h.expect(_selected_board() == -1, "bench_tap_touched_board",
		"轻点待命棋子后 _selected_board=%d —— 不该动棋盘选中态" % _selected_board())


# --- E 拖拽仍能挪动 -----------------------------------------------------------

func _case_drag_still_moves() -> void:
	_clear_slots()
	GameState.board_slots[0] = _piece(RANGE1_UNIT)
	GameState.bench_slots[0] = _piece(RANGE4_UNIT)
	var uid_board := _uid(GameState.board_slots[0])
	var uid_bench := _uid(GameState.bench_slots[0])

	_screen.call("_drop_on_board", 7, {"kind": "board", "index": 0})
	_h.expect(_uid(GameState.board_slots[7]) == uid_board and GameState.board_slots[0] == null,
		"drag_board_not_moved",
		"拖拽落点（棋盘 → 棋盘）没有挪动棋子 —— 这是第 4 条之后**唯一**的挪动路径，不能坏")

	_screen.call("_drop_on_board", 9, {"kind": "bench", "index": 0})
	_h.expect(_uid(GameState.board_slots[9]) == uid_bench and GameState.bench_slots[0] == null,
		"drag_bench_not_moved",
		"拖拽落点（待命 → 棋盘）没有把棋子挪上去")


# --- F 长按查看属性：点亮射程预览，关框后撤掉 ---------------------------------

func _case_inspect_lights_range_and_clears() -> void:
	_clear_slots()
	GameState.board_slots[0] = _piece(RANGE1_UNIT)
	_h.expect(_hud().readability_layer != null, "readability_layer_missing",
		"可读性层没建出来 —— 射程预览无处可画")

	_screen.call("_inspect_board_cell", 0)
	_h.expect(_selected_board() == 0, "inspect_did_not_light",
		"长按查看属性没有点亮检视格（_selected_board=%d）—— 玩家看不到射程预览了" % _selected_board())
	var range_cells: PackedInt32Array = _screen.call("_prep_attack_range_indices", 0)
	_h.expect(range_cells.size() > 0 and range_cells.has(0), "inspect_range_empty",
		"检视格算出来的射程格为空 —— 射程预览这条唯一入口断了（range=1 至少应含本格）")

	var overlay: Variant = _overlay()
	_h.expect(bool(overlay.call("is_ready")), "overlay_not_ready",
		"详情浮层没有绑定 popup/text_label —— 后面的「详情框开合」两帧都测不出东西")

	# 空格长按不该点亮（_show_board_detail 对空格静默 return）。
	_screen.call("_inspect_board_cell", 11)
	_h.expect(_selected_board() == 0, "inspect_empty_lit",
		"长按空格也点亮了检视格（_selected_board=%d）—— 应该只在有棋子的格上点亮" % _selected_board())

	# 「查看属性」的正文得真的弹出来。_show_detail → popup_centered 是 deferred 的，
	# 所以要等两帧再看（不然读到的永远是"还没开"）。
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(bool(overlay.call("is_showing")), "inspect_popup_not_open",
		"长按查看属性后详情框没有打开 —— 「查看属性」这条职责断了（只点了个高亮）")

	# 关框那一下必须撤掉高亮。走**真实的 _process** 两帧，顺带证明
	# PrepScreen._process 里确实接了 _sync_board_inspect_after_overlay：
	#   第 1 帧（框开着）→ 记下「上一帧开着」；第 2 帧（框已关）→ 撤高亮。
	_screen.call("_process", 0.016)
	_h.expect(bool(_screen.get("_overlay_was_showing")), "overlay_state_not_tracked",
		"详情框明明开着，_process 却记成没开 —— 关闭翻转检测的前提不成立，下面那条会变成恒真")
	overlay.call("hide_detail")
	_h.expect(_selected_board() == 0, "inspect_cleared_too_early",
		"详情框刚关、_process 还没跑就清了检视格 —— 判据不成立（下面那条会变成恒真）")
	_screen.call("_process", 0.016)
	_h.expect(_selected_board() == -1, "inspect_not_cleared",
		"详情框关掉后检视高亮没撤 —— 会留下一个「看起来还选中着」的格子，正是第 4 条要消掉的现象")


# --- G 长按弹过属性框之后，同一次手势不许再起拖（用户 10.12 追加口径）-----------
#
# 用户原话：「当前长按会弹窗，弹窗点击消失后依然触发可进行挪动，应该改为触发长按
#   弹窗了不再有挪动了，只有按住进行滑动才可挪动。」
#
# 根因：长按（0.7s）与拖拽（位移 ≥ 28px）是同一个按钮上的**两种**手势，而此前只做了
#   **单向**解耦 —— PrepDragButton._launch_drag() 会停长按表、置 long_press_cancelled
#   （即「拖拽赢」），但 long_press_triggered 之后**没有反过来挡拖拽**：长按看完属性、
#   手指还没松，随手一划超过阈值，照样 force_drag 把棋子挪走。
#
# 这一节走**真手势**：真起 PrepDetailOverlay 的长按表、真等它 0.7s 到点，再滑动；
#   不是照抄 meta（照抄只能证明「读到 meta 会挡」，证明不了长按真的写了那个 meta）。
#   ★ 宿主必须是 **Control**：PrepDragButton.drag_owner 是 `Control` 类型，
#     塞个 Node 进去会被类型检查挡掉（静默留 null）⇒ _on_drag_started 永不回调，
#     「起没起拖」就只能靠 _gesture_drag_launched 单看，判据变弱。
class DragGateOwner extends Control:
	var starts := 0

	func _on_drag_started(_payload: Dictionary) -> void:
		starts += 1

	func _on_drag_ended() -> void:
		pass


func _case_long_press_blocks_drag_for_this_gesture() -> void:
	var drag_script := load("res://scenes/prep/PrepDragButton.gd") as Script
	var overlay_script := load("res://scenes/prep/PrepDetailOverlay.gd") as Script
	if not _h.expect(drag_script != null and overlay_script != null, "drag_scripts_missing",
			"PrepDragButton.gd / PrepDetailOverlay.gd 载入失败"):
		return
	var owner_node := DragGateOwner.new()
	add_child(owner_node)
	var btn: Control = drag_script.new()
	btn.set("drag_owner", owner_node)
	btn.set("drag_payload", {"kind": "board", "index": 0})
	btn.position = Vector2(300, 200)
	btn.size = Vector2(200, 120)
	if btn.has_method("configure_polygon"):
		btn.call("configure_polygon", PackedVector2Array([
			Vector2(0, 0), Vector2(200, 0), Vector2(200, 120), Vector2(0, 120)]))
	add_child(btn)
	var overlay: Variant = overlay_script.new()
	var fired := {"n": 0}
	overlay.call("attach_long_press", btn, func() -> void: fired["n"] = int(fired["n"]) + 1)

	# ── 手势 1：真长按（等长按表 0.7s 到点）→ 同一次手势再大幅滑动必须**不起拖**。
	_press_touch(btn, Vector2(100, 60), 0)
	await get_tree().create_timer(0.9).timeout
	var triggered := bool(btn.get_meta("long_press_triggered", false))
	if not _h.expect(int(fired["n"]) == 1 and triggered, "probe_long_press_not_fired",
			"夹具没等到长按表到点（回调 %d 次，long_press_triggered=%s）—— 本段判据失效" % [
				int(fired["n"]), str(triggered)]):
		_release_touch(btn, Vector2(100, 60), 0)
		btn.queue_free()
		owner_node.queue_free()
		return
	var starts_before: int = owner_node.starts
	_drag_touch(btn, Vector2(220, 60), 0)      # 位移 120px ≥ 28px，远超拖拽阈值
	_h.expect(owner_node.starts == starts_before
			and not bool(btn.get("_gesture_drag_launched")),
		"long_press_then_dragged",
		"长按弹出属性框之后，同一次手势再滑动仍然起了拖（_on_drag_started 累计 %d 次，_gesture_drag_launched=%s）—— 用户口径是「触发长按弹窗了不再有挪动」" % [
			owner_node.starts, str(btn.get("_gesture_drag_launched"))])
	_release_touch(btn, Vector2(220, 60), 0)

	# ── 手势 2（反向对照）：没触发长按的「按住就滑」仍然必须能挪动。
	_press_touch(btn, Vector2(100, 60), 0)
	_drag_touch(btn, Vector2(160, 60), 0)      # 位移 60px ≥ 28px，且远早于 0.7s
	_h.expect(owner_node.starts == starts_before + 1, "slide_drag_lost",
		"普通的「按住就滑」不再起拖了（_on_drag_started 仍是 %d 次）—— 用户口径是「只有按住进行滑动才可挪动」，这条不能坏" % owner_node.starts)
	_release_touch(btn, Vector2(160, 60), 0)

	overlay = null
	btn.queue_free()
	owner_node.queue_free()


# 触摸三件套（position 用按钮局部坐标，与真实事件一致）。
func _press_touch(btn: Control, pos: Vector2, index: int) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.pressed = true
	ev.position = pos
	btn.gui_input.emit(ev)


func _drag_touch(btn: Control, pos: Vector2, index: int) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = index
	ev.position = pos
	btn.gui_input.emit(ev)


func _release_touch(btn: Control, pos: Vector2, index: int) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.pressed = false
	ev.position = pos
	btn.gui_input.emit(ev)
