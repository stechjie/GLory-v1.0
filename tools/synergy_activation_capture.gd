extends Node

# 羁绊跨档表现**在真棋盘上**的截帧（10.31）。照 star_upgrade_board_capture 的做法：
# 真备战界面、真模型、真相机，放慢 time_scale 连拍，拼成联络表。
#
# WARN: 必须不带 --headless 运行（headless 是 dummy 渲染，抓出来是空图）。
#   "Godot_v4.7-stable_win64_console.exe" --path . res://tools/synergy_activation_capture.tscn
# 输出：reports/synergy_activation/（reports/ 在 .gitignore 里）
#   · <race>_major_*.png：五族各跨一次中间档（每族 RACE_THRESHOLDS 的第 2 档）
#   · god_ultimate_*.png：神 6 -> 7，整屏（看暗角与弹字）
#   · races_peak.png：五族中间档峰值帧并排，比颜色用

const PrepScene := preload("res://scenes/prep/PrepScreen.tscn")
const SynergyService := preload("res://scripts/units/SynergyService.gd")
const OUT_DIR := "res://reports/synergy_activation"
const WINDOW := Vector2i(1600, 720)
const CAPTURE_TIME_SCALE := 0.06
const SHOTS := 30
const SHEET_COLS := 6
const CROP_RECT := Rect2i(390, 60, 600, 400)
const CROP_CELL := Vector2i(300, 200)
const FULL_CELL := Vector2i(400, 180)
# 峰值帧（约 0.25 秒处：光环扩到一半、最亮）
const PEAK_SHOT := 9
const RACES := ["god", "human", "undead", "dark", "crimson"]

var _dir := ""
var _screen: Node
var _ids_by_race: Dictionary = {}
var _defs: Dictionary = {}
var _peaks: Array[Image] = []


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("synergy_activation_capture 需要真实渲染后端，请去掉 --headless")
		get_tree().quit(2)
		return
	_dir = ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(_dir)
	DisplayServer.window_set_size(WINDOW)
	GameState.reset_run()
	NetworkService.team_active = false
	NetworkService.is_host = true
	_index_units()
	_set_board("", 0)
	_screen = PrepScene.instantiate()
	add_child(_screen)
	await _settle(30)

	for race in RACES:
		var thresholds: Array = SynergyService.RACE_THRESHOLDS[race]
		var t := int(thresholds[1])
		await _run(race, t - 1, t, "%s_major" % race, true)
	await _run("god", 6, 7, "god_ultimate", false)
	_save_sheet(_peaks, "races_peak", CROP_CELL, RACES.size())
	print("SYNERGY_ACTIVATION_CAPTURE dir=%s" % _dir)
	get_tree().quit(0)


func _run(race: String, before: int, after: int, tag: String, crop: bool) -> void:
	_set_board(race, before)
	_screen.call("_refresh_all")
	# 等上一段的光环 / 弹字全部播完，不然会串进这一段的画面
	await get_tree().create_timer(1.6).timeout
	_set_board(race, after)
	Engine.time_scale = CAPTURE_TIME_SCALE
	var started := Time.get_ticks_msec()
	_screen.call("_refresh_all")
	var frames: Array[Image] = []
	for shot in SHOTS:
		await _settle(1)
		var image := get_viewport().get_texture().get_image()
		var ms := int(round(float(Time.get_ticks_msec() - started) * CAPTURE_TIME_SCALE))
		image.save_png("%s/%s_%02d_%04dms.png" % [_dir, tag, shot, ms])
		var framed := image.get_region(CROP_RECT) if crop else image
		frames.append(framed)
		if crop and shot == PEAK_SHOT:
			_peaks.append(framed)
	Engine.time_scale = 1.0
	_save_sheet(frames, "%s_sheet" % tag, CROP_CELL if crop else FULL_CELL, SHEET_COLS)


func _save_sheet(frames: Array[Image], name: String, cell: Vector2i, cols: int) -> void:
	if frames.is_empty():
		return
	var rows := int(ceil(float(frames.size()) / float(cols)))
	var sheet := Image.create(cell.x * cols, cell.y * rows, false, Image.FORMAT_RGBA8)
	for i in frames.size():
		var img := frames[i].duplicate() as Image
		img.convert(Image.FORMAT_RGBA8)
		img.resize(cell.x, cell.y, Image.INTERPOLATE_BILINEAR)
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, cell), Vector2i((i % cols) * cell.x, (i / cols) * cell.y))
	sheet.save_png("%s/%s.png" % [_dir, name])


# 每族取不同 id 的棋子（同 id 会被自动合成，人数就对不上了）。
func _index_units() -> void:
	for cand in DataRegistry.get_table("race_units").get("units", []):
		var def := cand as Dictionary
		var id := str(def.get("id", ""))
		var race := str(def.get("race", ""))
		_defs[id] = def
		if not _ids_by_race.has(race):
			_ids_by_race[race] = []
		(_ids_by_race[race] as Array).append(id)


# 摆 count 枚该族棋子，外加 1 枚别族棋子做对照（它不该跟着亮）。
func _set_board(race: String, count: int) -> void:
	GameState.board_slots.resize(GameConstants.CELL_COUNT)
	for i in GameConstants.CELL_COUNT:
		GameState.board_slots[i] = null
	for i in GameState.bench_slots.size():
		GameState.bench_slots[i] = null
	if race.is_empty():
		return
	var cells := [4, 5, 6, 7, 8, 9, 10, 11, 12, 13]
	var ids: Array = _ids_by_race.get(race, [])
	var idx := 0
	for i in mini(count, ids.size()):
		GameState.board_slots[cells[idx]] = _cell(str(ids[i]), "%s%d" % [race, i])
		idx += 1
	var other := "human" if race != "human" else "god"
	GameState.board_slots[cells[idx]] = _cell(str((_ids_by_race[other] as Array)[0]), "other")


func _cell(unit_id: String, uid: String) -> Dictionary:
	return {"id": unit_id, "uid": uid, "star": 1,
		"def": (_defs[unit_id] as Dictionary).duplicate(true), "is_mercenary": false}


func _settle(frames: int) -> void:
	for _i in frames:
		await get_tree().process_frame
