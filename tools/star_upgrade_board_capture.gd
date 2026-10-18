extends Node

# 升星表现**在真棋盘上**的截帧。
#
# tools/star_upgrade_preview 是在空地上单独看特效本体；这里是把它接进
# PrepBoardController 的两个合成函数之后，在**真的备战界面**上跑一遍：真棋盘底图、
# 真模型、真格子下方的「名字 ★星级」标签、真相机。预览里看着可以、真机上被草地
# 吃掉一档，就是靠这一步才看得出来。
#
# WARN: **必须不带 --headless 运行** —— headless 是 dummy 渲染后端，抓出来是空图。
#   "Godot_v4.7-stable_win64_console.exe" --path . res://tools/star_upgrade_board_capture.tscn
# 输出：reports/star_upgrade_board/（reports/ 在 .gitignore 里，不会进版本库）
#
# 取样办法与预览不同：这里**不能** seek —— 走的是真实的 Tween + create_timer + 自动
# 合成链，只能跟着真实帧走。所以按固定帧距连拍，每张标上从触发算起的毫秒数。

const PrepScene := preload("res://scenes/prep/PrepScreen.tscn")

const OUT_DIR := "res://reports/star_upgrade_board"
# WARN: 必须就是项目的基准分辨率（project.godot 的 viewport_width/height = 1600x720）。
#       换成别的尺寸时 stretch_mode=canvas_items + aspect=expand 会把画面放大裁切，
#       抓出来是棋盘左上角的一小块（第一版用 1280x800 就是这样）。
const WINDOW := Vector2i(1600, 720)
const SETTLE_FRAMES := 30
# 每隔几帧抓一张、一共抓几张。整段升星（光点 0.25s + 迸发 0.5~0.7s）约 0.8 秒，
# 60fps 下 3 帧一张 × 20 张 ≈ 1 秒，够盖住全程。
# 放慢到这个倍率再抓帧，否则存图太慢、整段升星只抓得到两帧。
const CAPTURE_TIME_SCALE := 0.06
const SHOT_EVERY_FRAMES := 1
# 每帧一张。整段 = 光点 0.25s + 迸发 0.5~0.7s ≈ 0.95s，一张约 24ms（见
# CAPTURE_TIME_SCALE），所以要 40 张才盖得全 —— 20 张只抓到迸发刚起头。
const SHOT_COUNT := 40
const SHEET_COLS := 8
# 联络表每格按裁剪区（600x400）的比例缩，不然棋盘会被压扁。
const SHEET_CELL := Vector2i(300, 200)
# 整屏 1600x720 里棋子只有四十来像素高，缩进联络表后根本看不出特效。
# 裁到棋盘中段这一块再拼 —— 判断「特效在真棋盘上够不够看」只需要这一块。
const CROP_RECT := Rect2i(390, 60, 600, 400)

var _dir := ""
var _shots := 0
var _screen: Node


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("star_upgrade_board_capture 需要真实渲染后端，请去掉 --headless")
		get_tree().quit(2)
		return
	_dir = ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(_dir)
	DisplayServer.window_set_size(WINDOW)

	GameState.reset_run()
	NetworkService.team_active = false
	NetworkService.is_host = true
	_screen = PrepScene.instantiate()
	add_child(_screen)
	await _settle(SETTLE_FRAMES)
	var probe := get_viewport().get_texture().get_image()
	print("[PROBE] window=%s viewport_rect=%s image=%s scale=%s" % [
		str(DisplayServer.window_get_size()), str(get_viewport().get_visible_rect().size),
		str(probe.get_size()), str(get_window().content_scale_factor)])

	var def := _pick_unit_def()
	if def.is_empty():
		push_error("units 表里取不到带模型的棋子，没法摆真棋盘")
		get_tree().quit(3)
		return

	# 1→2★：两枚一星同名棋子进棋盘，_refresh_all() 里的自动合成会把它们融成二星。
	await _run_case(def, 1, "2star")
	# 2→3★：三枚二星。
	await _run_case(def, 2, "3star")
	# 4.3：可升 4★ 的三星棋子，脚下那圈缓慢旋转的金环 + 上升光点。
	await _run_four_star_ready(def)
	# 4.2：营地「升级石」页 —— 页签呼吸光 + 带数字、4★ 列表每行以棋子为主、
	#      规则一句话在页顶。
	await _run_camp_page()

	print("STAR_UPGRADE_BOARD_CAPTURE shots=%d dir=%s" % [_shots, _dir])
	get_tree().quit(0)


# 取表里第一个棋子。模型不在这张表上（由 UnitVisualResolver 按 id 解析），
# 所以这里**不能**拿 "model" 字段当筛选条件 —— 第一版就是这么写的，结果一个都选不出来。
func _pick_unit_def() -> Dictionary:
	# 表名是 "race_units"（不是 "units"）—— 第一版写错名字，取回来是个空字典。
	var table: Dictionary = DataRegistry.get_table("race_units")
	for key in ["units", "race_units", "list"]:
		var rows: Variant = table.get(key, [])
		if typeof(rows) != TYPE_ARRAY:
			continue
		for row in (rows as Array):
			if typeof(row) == TYPE_DICTIONARY and not str((row as Dictionary).get("id", "")).is_empty():
				return (row as Dictionary).duplicate(true)
	return {}


func _run_case(def: Dictionary, star: int, tag: String) -> void:
	# 先清干净：上一段留下的棋子会被自动合成再融一次，两段就串台了。
	for i in GameState.board_slots.size():
		GameState.board_slots[i] = null
	for i in GameState.bench_slots.size():
		GameState.bench_slots[i] = null
	_screen.call("_refresh_all")
	await _settle(12)

	var copies := GameState.copies_to_upgrade(star)
	# 摆在相邻格上，光点飞行那一段才看得出是「从旁边飞过来」。
	var cells := [5, 6, 9]
	# ★ 分两步放：先放 copies-1 枚并刷新一次，让它们**先有 3D 模型**，
	#   再放最后一枚触发合成。一次性全放的话，自动合成是 _refresh_all() 的第一步，
	#   那时这些棋子的模型还没建出来，prep_slot_positions_by_uid() 取不到坐标，
	#   「化成光点飞入」那一段就整个没有了（第一版截出来 from=0 就是这个原因）。
	for i in (copies - 1):
		GameState.board_slots[int(cells[i % cells.size()])] = {
			"id": str(def.get("id", "")),
			"uid": GameState.mint_piece_uid(),
			"star": star,
			"def": def.duplicate(true),
		}
	_screen.call("_refresh_all")
	await _settle(20)
	GameState.board_slots[int(cells[(copies - 1) % cells.size()])] = {
		"id": str(def.get("id", "")),
		"uid": GameState.mint_piece_uid(),
		"star": star,
		"def": def.duplicate(true),
	}
	# 这一下会走 _auto_combine_all() -> _combine_copies_auto() -> queue_star_upgrade()，
	# 再在同一个 _refresh_all() 的末尾 flush 出来。
	# ★ 这个 harness 存一张 1600x720 的 PNG 就要 ~400ms，实时跑的话整段升星
	#   （光点 0.25s + 迸发 0.5~0.7s）只抓得到两帧。把时间放慢再抓 ——
	#   Tween 与 create_timer 都跟 time_scale 走，所以抓出来的是同一段动作、
	#   只是采样密了。**只有截帧工具能这么干**：正式游戏里动 time_scale 会把备战
	#   倒计时一起拖慢（升星特效本体因此明确不做顿帧）。
	Engine.time_scale = CAPTURE_TIME_SCALE
	var started := Time.get_ticks_msec()
	_screen.call("_refresh_all")

	var frames: Array[Image] = []
	for shot in SHOT_COUNT:
		await _settle(SHOT_EVERY_FRAMES)
		var full := get_viewport().get_texture().get_image()
		var image := full.get_region(CROP_RECT)
		# 实测耗时，不要按 60fps 推算 —— 这个 harness 真跑下来只有 9~45 fps，
		# 按帧数换算出来的毫秒数跟画面对不上。
		# 换算回「游戏里实际过了多少毫秒」：墙上时间 × time_scale。
		var ms := int(round(float(Time.get_ticks_msec() - started) * CAPTURE_TIME_SCALE))
		image.save_png("%s/%s_%02d_%04dms.png" % [_dir, tag, shot, ms])
		_shots += 1
		frames.append(image)
	Engine.time_scale = 1.0
	_save_sheet(frames, "%s_sheet" % tag)


# 摆一枚**现在就能升 4★** 的三星棋子（给够石头和金币），连拍一段看环转起来的样子。
# 判据与游戏里一致：GameState.four_star_check(cell).ok 为真时 _sync_four_star_actor
# 的 state 才会是 1，那圈环才会挂上。
func _run_four_star_ready(def: Dictionary) -> void:
	for i in GameState.board_slots.size():
		GameState.board_slots[i] = null
	for i in GameState.bench_slots.size():
		GameState.bench_slots[i] = null
	GameState.gold = 5000
	for stone_type in ["sky", "land", "ren"]:
		GameState.team_upgrade_stones[stone_type] = 3
	GameState.board_slots[5] = {
		"id": str(def.get("id", "")),
		"uid": GameState.mint_piece_uid(),
		"star": GameState.MAX_MERGE_STAR,
		"def": def.duplicate(true),
	}
	_screen.call("_refresh_all")
	await _settle(20)
	var ready := bool(GameState.four_star_check(GameState.board_slots[5]).get("ok", false))
	print("[READY_RING] four_star_check.ok=%s" % str(ready))
	Engine.time_scale = CAPTURE_TIME_SCALE
	var frames: Array[Image] = []
	# 环 6 秒一圈，放慢之后抓 16 张刚好铺开大半圈，看得出它在转。
	for shot in 16:
		await _settle(1)
		var full := get_viewport().get_texture().get_image()
		var image := full.get_region(CROP_RECT)
		image.save_png("%s/ready_%02d.png" % [_dir, shot])
		_shots += 1
		frames.append(image)
	Engine.time_scale = 1.0
	_save_sheet(frames, "ready_sheet")


# 打开萝卜营地并切到「升级石」页，整屏抓一张。这一页的三处改动都只能整屏看：
# 页签的呼吸光、4★ 列表每行的棋子头像与属性对比、页顶那句规则。
func _run_camp_page() -> void:
	_screen.call("_toggle_carrot_camp")
	await _settle(20)
	var panel = _screen.get("_carrot_panel")
	if panel != null and is_instance_valid(panel):
		panel.call("_show_page", 1)
		panel.call("refresh")
	await _settle(20)
	var image := get_viewport().get_texture().get_image()
	image.save_png("%s/camp_stone_page.png" % _dir)
	_shots += 1


func _save_sheet(frames: Array[Image], out_name: String) -> void:
	if frames.is_empty():
		return
	var rows := int(ceil(float(frames.size()) / float(SHEET_COLS)))
	var sheet := Image.create(SHEET_COLS * SHEET_CELL.x, rows * SHEET_CELL.y, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.05, 0.06, 0.05))
	for i in frames.size():
		var cell := frames[i].duplicate() as Image
		# 视口抓下来的图不一定是 RGBA8，blit_rect 要求两边格式一致（不转会直接报错）。
		cell.convert(Image.FORMAT_RGBA8)
		cell.resize(SHEET_CELL.x, SHEET_CELL.y, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(cell, Rect2i(Vector2i.ZERO, cell.get_size()),
			Vector2i((i % SHEET_COLS) * SHEET_CELL.x, (i / SHEET_COLS) * SHEET_CELL.y))
	sheet.save_png("%s/%s.png" % [_dir, out_name])
	_shots += 1


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
