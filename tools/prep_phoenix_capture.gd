extends Node

# 凤凰涅槃棋盘凤凰的真棋盘连拍（11.04）。备战中途凑齐联动 → 拍登场、巡航、俯冲点燃。
# WARN: 必须不带 --headless：
#   "Godot_v4.7-stable_win64_console.exe" --path . res://tools/prep_phoenix_capture.tscn
# 输出 reports/prep_phoenix/f_XX_<游戏内毫秒>.png；放慢 time_scale 连拍，存图慢不影响采样密度。

const PrepScene := preload("res://scenes/prep/PrepScreen.tscn")
const OUT_DIR := "res://reports/prep_phoenix"
const WINDOW := Vector2i(1600, 720)
const TIME_SCALE := 0.5
const SHOTS := 20
const SHOT_GAME_SEC := 0.3
# `-- --link rich_path` 换别的联动（默认凤凰涅槃）
const LINKS := {
	"phoenix": ["atk_wail_resonance", "def_soul_counter"],
	"rich_path": ["money_compound", "elem_thunder_haste"],
	"toxic_burst": ["atk_burst_core", "elem_toxic_spread"],
	"blood_covenant": ["elem_flame_shatter", "def_lifesteal_emblem"],
	"paralysis_shackles": ["ctrl_interrupt_chain", "elem_frost_blade"],
	"iron_maiden": ["def_iron_wall", "ctrl_corrosive_needle"],
	"oppression_counter": ["ctrl_binding_weight", "atk_frenzy_assault"],
}
const PIECES := ["god_priest", "human_swordsman", "god_guard", "god_aurora", "human_archer", "human_mage"]

var _dir := ""


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("prep_phoenix_capture 需要真实渲染后端，请去掉 --headless")
		get_tree().quit(2)
		return
	_dir = ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(_dir)
	for f in DirAccess.get_files_at(_dir):
		DirAccess.remove_absolute(_dir + "/" + f)
	DisplayServer.window_set_size(WINDOW)
	GameState.reset_run()
	NetworkService.team_active = false
	NetworkService.is_host = true
	var defs := {}
	for c in DataRegistry.get_table("race_units").get("units", []):
		defs[str((c as Dictionary).get("id", ""))] = c
	GameState.board_slots.resize(GameConstants.CELL_COUNT)
	for i in GameConstants.CELL_COUNT:
		GameState.board_slots[i] = null
	var cells := [1, 4, 6, 9, 11, 14]
	for i in PIECES.size():
		var id: String = PIECES[i] if defs.has(PIECES[i]) else str(defs.keys()[i])
		GameState.board_slots[cells[i]] = {"id": id, "uid": "p%d" % i, "star": 1, "def": (defs[id] as Dictionary).duplicate(true)}
	GameState.owned_treasures.clear()
	var screen := PrepScene.instantiate()
	add_child(screen)
	await get_tree().create_timer(1.2).timeout
	# 中途凑齐 → 走「浴火重生」登场
	var link := "phoenix"
	var args := OS.get_cmdline_user_args()
	var at := args.find("--link")
	if at >= 0 and at + 1 < args.size():
		link = args[at + 1]
	for t in LINKS.get(link, LINKS["phoenix"]):
		GameState.owned_treasures.append(str(t))
	screen.call("_refresh_all")
	Engine.time_scale = TIME_SCALE
	var game_ms := 0.0
	for shot in SHOTS:
		await get_tree().create_timer(SHOT_GAME_SEC).timeout
		game_ms += SHOT_GAME_SEC * 1000.0
		get_viewport().get_texture().get_image().save_png("%s/f_%02d_%05d.png" % [_dir, shot, int(game_ms)])
	Engine.time_scale = 1.0
	print("PREP_PHOENIX_CAPTURE dir=%s" % _dir)
	get_tree().quit(0)
