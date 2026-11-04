extends Node

# 备战棋子宝藏套装 / 联动常驻表现的真棋盘截图（11.04）。
# WARN: 必须不带 --headless（dummy 渲染抓出来是空图）：
#   "Godot_v4.7-stable_win64_console.exe" --path . res://tools/prep_treasure_visuals_capture.tscn
# 输出 reports/prep_treasure_visuals/<case>_a.png / _b.png（同一状态隔 0.7 秒两张，看动的部分）。

const PrepScene := preload("res://scenes/prep/PrepScreen.tscn")
const OUT_DIR := "res://reports/prep_treasure_visuals"
const WINDOW := Vector2i(1600, 720)
const PIECES := ["god_priest", "human_swordsman", "dark_imp", "undead_wisp"]

const CASES := [
	["set_defense", ["def_iron_wall", "def_life_monument", "def_formation_heal", "def_soul_counter"], 5000],
	["set_attack", ["atk_blood_pact", "atk_fury_roster", "atk_burst_core", "atk_wail_resonance"], 5000],
	["set_control", ["ctrl_shockwave", "ctrl_corrosive_needle", "ctrl_interrupt_chain", "ctrl_time_compress"], 5000],
	["set_element", ["elem_flame_shatter", "elem_frost_blade", "elem_thunder_haste", "elem_toxic_spread"], 5000],
	["set_money_poor", ["money_compound", "money_generous_fate", "money_discount", "money_golden_altar"], 0],
	["set_money_rich", ["money_compound", "money_generous_fate", "money_discount", "money_golden_altar"], 10000],
	["link_phoenix", ["atk_wail_resonance", "def_soul_counter"], 100],
	["link_iron_maiden", ["def_iron_wall", "ctrl_corrosive_needle"], 100],
	["link_oppression_counter", ["ctrl_binding_weight", "atk_frenzy_assault"], 100],
	["link_toxic_burst", ["atk_burst_core", "elem_toxic_spread"], 100],
	["link_blood_covenant", ["elem_flame_shatter", "def_lifesteal_emblem"], 100],
	["link_paralysis_shackles", ["ctrl_interrupt_chain", "elem_frost_blade"], 100],
	["link_rich_path", ["money_compound", "elem_thunder_haste"], 100],
	["link_two_iron_toxic", ["def_iron_wall", "ctrl_corrosive_needle", "atk_burst_core", "elem_toxic_spread"], 100],
	["set_defense_plus_link", ["def_iron_wall", "def_life_monument", "def_formation_heal", "def_soul_counter", "atk_wail_resonance"], 100],
]

var _dir := ""
var _screen: Node
var _defs: Dictionary = {}


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("prep_treasure_visuals_capture 需要真实渲染后端，请去掉 --headless")
		get_tree().quit(2)
		return
	_dir = ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(_dir)
	DisplayServer.window_set_size(WINDOW)
	GameState.reset_run()
	NetworkService.team_active = false
	NetworkService.is_host = true
	for cand in DataRegistry.get_table("race_units").get("units", []):
		_defs[str((cand as Dictionary).get("id", ""))] = cand
	_place()
	_screen = PrepScene.instantiate()
	add_child(_screen)
	await get_tree().create_timer(1.0).timeout
	for c in CASES:
		GameState.owned_treasures.clear()
		for id in c[1]:
			GameState.owned_treasures.append(str(id))
		GameState.gold = int(c[2])
		_screen.call("_refresh_all")
		await get_tree().create_timer(1.4).timeout
		get_viewport().get_texture().get_image().save_png("%s/%s_a.png" % [_dir, c[0]])
		await get_tree().create_timer(0.7).timeout
		get_viewport().get_texture().get_image().save_png("%s/%s_b.png" % [_dir, c[0]])
	print("PREP_TREASURE_VISUALS_CAPTURE dir=%s" % _dir)
	get_tree().quit(0)


# 棋盘 4 枚不同族普通棋子 + 1 枚佣兵（不该亮）；备战席 1 枚（不该亮）。
func _place() -> void:
	GameState.board_slots.resize(GameConstants.CELL_COUNT)
	for i in GameConstants.CELL_COUNT:
		GameState.board_slots[i] = null
	for i in GameState.bench_slots.size():
		GameState.bench_slots[i] = null
	var cells := [4, 5, 6, 7]
	for i in PIECES.size():
		var id: String = PIECES[i] if _defs.has(PIECES[i]) else str(_defs.keys()[i])
		GameState.board_slots[cells[i]] = _cell(id, "p%d" % i, false)
	GameState.board_slots[9] = _cell("human_militia", "merc", true)
	GameState.bench_slots[0] = _cell("god_aurora", "bench", false)


func _cell(id: String, uid: String, merc: bool) -> Dictionary:
	return {"id": id, "uid": uid, "star": 1, "is_mercenary": merc, "def": (_defs[id] as Dictionary).duplicate(true)}
