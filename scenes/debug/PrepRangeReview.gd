extends Control

# 射程圈预览（11-08）：在编辑器里打开本场景按 F6，点上面的按钮切换棋子 / 落点。
#
# 摆的是真的摆放界面（PrepScreen.tscn），看到的就是对局里的样子。
# 每个按钮模拟「正把这只棋子拖到某一格上方」：16 个站位圈亮起、落点格有光柱、
# 射程圈按这只棋子的真实攻击距离画在那一格上。
# 画面只看不点：盖了一层吃输入的遮罩 —— 在这里拖棋子会触发 SaveManager.save_run()，
# 把本机的对局存档写成这份假数据（同 PrepSkinReview）。
#
# 截图（非 headless 窗口跑）：
#   godot --path . --resolution 1600x720 res://scenes/debug/PrepRangeReview.tscn -- --capture-prep-range=<绝对目录>
# 每个情形写一张 <目录>/<key>.png，写完自动退出。

const PREP_SCENE_PATH := "res://scenes/prep/PrepScreen.tscn"
const CAPTURE_ARG := "--capture-prep-range="

# 棋盘上摆的真棋子（射程 1 / 1.5 / 2 / 3 / 4 各一只）。row 0 = 前排（靠上、面向敌人）。
const UNIT_PLACEMENTS := [
	{"id": "human_swordsman", "slot": 1},   # 剑士 近战 1
	{"id": "human_king", "slot": 6},        # 人王 1.5
	{"id": "dark_queen", "slot": 4},        # 痛苦女王 2
	{"id": "dark_suc", "slot": 10},         # 魅魔 3
	{"id": "human_archer", "slot": 13},     # 弓箭手 4
]

# unit = 拖的是哪只（取它的射程），hover = 手指当前悬在哪一格（射程圈圆心）。
const CASES := [
	{"key": "1_swordsman_melee", "label": "剑士 · 近战 1", "unit": "human_swordsman", "hover": 1},
	{"key": "2_king_1_5", "label": "人王 · 1.5", "unit": "human_king", "hover": 6},
	{"key": "3_queen_2", "label": "痛苦女王 · 2", "unit": "dark_queen", "hover": 4},
	{"key": "4_succubus_3", "label": "魅魔 · 3", "unit": "dark_suc", "hover": 10},
	{"key": "5_archer_4_back", "label": "弓箭手 · 4 · 后排", "unit": "human_archer", "hover": 13},
	{"key": "6_archer_4_front", "label": "弓箭手 · 4 · 拖到前排", "unit": "human_archer", "hover": 2},
]

var prep: Control
var _prep_host: Control
var _toolbar_layer: CanvasLayer
var _status: Label
var _definitions := {}


func _ready() -> void:
	DataRegistry.ensure_loaded()
	for unit in DataRegistry.get_table("race_units").get("units", []):
		_definitions[str(unit.get("id", ""))] = unit
	_prep_host = Control.new()
	_prep_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_prep_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_prep_host)

	_toolbar_layer = CanvasLayer.new()
	_toolbar_layer.layer = 100
	add_child(_toolbar_layer)
	var blocker := Control.new()
	blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	_toolbar_layer.add_child(blocker)

	var bar := PanelContainer.new()
	bar.position = Vector2(8.0, 8.0)
	_toolbar_layer.add_child(bar)
	var rows := VBoxContainer.new()
	bar.add_child(rows)
	var buttons := HBoxContainer.new()
	rows.add_child(buttons)
	for entry in CASES:
		var b := Button.new()
		b.text = str(entry.label)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(show_case.bind(entry))
		buttons.add_child(b)
	var clear := Button.new()
	clear.text = "清除"
	clear.focus_mode = Control.FOCUS_NONE
	clear.pressed.connect(clear_case)
	buttons.add_child(clear)
	_status = Label.new()
	rows.add_child(_status)

	_stage_game_state()
	await _build_prep()
	var capture_dir := _capture_dir_arg()
	if not capture_dir.is_empty():
		await _capture_all(capture_dir)
		return
	show_case(CASES[0])


func _build_prep() -> void:
	prep = (load(PREP_SCENE_PATH) as PackedScene).instantiate()
	# 不分帧构建时 startup_ready 在 add_child 里就发完了，所以先接信号再进树。
	var started := {"done": false}
	prep.startup_ready.connect(func() -> void: started.done = true, CONNECT_ONE_SHOT)
	_prep_host.add_child(prep)
	while not started.done:
		await get_tree().process_frame


# 模拟「正把 unit 拖到 hover 格上方」：走真实的拖动链路 —— 起拖（_on_drag_started）、
# 手指悬到格子上（BoardHud 的两个 hover），射程圈由摆放界面自己画。
func show_case(entry: Dictionary) -> void:
	if prep == null or not is_instance_valid(prep):
		return
	var definition: Dictionary = _definitions.get(str(entry.unit), {})
	var range_px: float = prep.prep_range_px_for_def(definition)
	prep._finish_drag_state()
	prep._on_drag_started({"kind": "board", "index": _unit_slot(str(entry.unit))})
	var hud: Variant = prep.get("_board_hud")
	if hud != null:
		hud.set_board_drop_hover(int(entry.hover))
		hud.set_board_range_hover(int(entry.hover))
	var radii: Vector2 = prep.prep_range_ring_world_radii(range_px)
	_status.text = "%s  ·  射程 %s → %.0f 模拟像素  ·  圆心格 %d  ·  地面半径 %.2f × %.2f" % [
		str(entry.label), str(definition.get("range", "?")), range_px, int(entry.hover), radii.x, radii.y]


func clear_case() -> void:
	if prep == null or not is_instance_valid(prep):
		return
	prep._finish_drag_state()
	_status.text = "已清除"


func _unit_slot(unit_id: String) -> int:
	for placement in UNIT_PLACEMENTS:
		if str(placement.id) == unit_id:
			return int(placement.slot)
	return -1


func _capture_dir_arg() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(CAPTURE_ARG):
			return arg.substr(CAPTURE_ARG.length())
	return ""


func _capture_all(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	_toolbar_layer.visible = false
	# 让模型、站位图、计数图案先落定（3D 视口按 30Hz 定时重渲，见 PrepBoardModels）。
	for _frame in 30:
		await get_tree().process_frame
	var failures := 0
	for entry in CASES:
		show_case(entry)
		for _frame in 12:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		var path := dir.path_join("%s.png" % str(entry.key))
		var error := image.save_png(path)
		if error != OK:
			failures += 1
		print("PREP_RANGE_REVIEW_CAPTURE key=%s path=%s error=%d text=%s" % [str(entry.key), path, error, _status.text])
	get_tree().quit(0 if failures == 0 else 1)


func _stage_game_state() -> void:
	GameState.reset_run()
	# 第 3 回合：下一轮是打怪，不会弹 PVP 预警。采集回合等于当前回合，
	# 进摆放界面时就不会再发萝卜、也就不会触发存档（同 PrepSkinReview）。
	GameState.round_index = 3
	GameState.last_harvest_round = 3
	GameState.gold = 48
	GameState.carrots = 12
	for i in UNIT_PLACEMENTS.size():
		var placement: Dictionary = UNIT_PLACEMENTS[i]
		var unit_id := str(placement.id)
		if not _definitions.has(unit_id):
			continue
		GameState.board_slots[int(placement.slot)] = {"uid": "range_review_%d" % i, "id": unit_id, "star": 1,
			"def": (_definitions[unit_id] as Dictionary).duplicate(true)}
