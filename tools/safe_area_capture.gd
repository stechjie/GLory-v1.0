extends Node

# 假装是横屏 iPhone，把主要页面真渲染出来存图，被挡住的那几条涂成半透明红色
# （ui/services/SafeArea.gd，docs/安全区适配.md）。门禁 tools/safe_area_check 验的是矩形算得对不对；
# 好不好看、有没有挤在一起，只有出图才看得见。
#
# ⚠️ 必须不带 --headless（headless 抓出来是空图），并且用隔离的用户目录跑（页面会读存档）：
#   Godot_v4.7.1-stable_win64_console.exe --path . res://tools/safe_area_capture.tscn
#   Godot_v4.7.1-stable_win64_console.exe --path . res://tools/safe_area_capture.tscn -- --island=right
# 输出：reports/safe_area/<页面>.png

const OUT_DIR := "res://reports/safe_area"
# iPhone 17 横屏 874×402 pt，按 2 倍开窗；灵动岛一侧 62 pt、底 21 pt → 逻辑单位约 114 / 38。
const WINDOW := Vector2i(1748, 804)
const ISLAND := 114.0
const HOME_BAR := 38.0
const SETTLE_FRAMES := 40

const PAGES: Array = [
	["main_menu", "res://scenes/menu/MainMenu.tscn"],
	["lobby", "res://scenes/menu/Team3v3Lobby.tscn"],
	["prep", "res://scenes/prep/PrepScreen.tscn"],
	["battle", "res://scenes/battle/BattleScreen.tscn"],
	["shop", "res://scenes/menu/ShopScreen.tscn"],
	["friends", "res://scenes/menu/FriendsScreen.tscn"],
	["codex", "res://scenes/menu/CodexScreen.tscn"],
	["pet", "res://scenes/menu/PetScreen.tscn"],
]

var _strips: Array[ColorRect] = []


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("safe_area_capture 需要真实渲染后端，请去掉 --headless")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	get_window().size = WINDOW
	var right := "--island=right" in OS.get_cmdline_user_args()
	SafeArea.set_test_insets(Vector4(0.0 if right else ISLAND, 0.0, ISLAND if right else 0.0, HOME_BAR))
	var layer := CanvasLayer.new()
	layer.layer = 1000
	add_child(layer)
	for i in 3:
		var strip := ColorRect.new()
		strip.color = Color(1.0, 0.0, 0.0, 0.28)
		strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(strip)
		_strips.append(strip)
	for page in PAGES:
		await _capture(str(page[0]), str(page[1]), "right" if right else "left")
	get_tree().quit(0)


func _capture(label: String, path: String, side: String) -> void:
	if label == "prep" or label == "battle":
		GameState.reset_run()
	GameState.team_mode = label == "battle"
	var page := (load(path) as PackedScene).instantiate() as Control
	add_child(page)
	move_child(page, 0)
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for i in SETTLE_FRAMES:
		await get_tree().process_frame
	_place_strips()
	await RenderingServer.frame_post_draw
	var file := "%s/%s_island_%s.png" % [OUT_DIR, label, side]
	get_viewport().get_texture().get_image().save_png(file)
	print("SAFE_AREA_CAPTURE %s" % ProjectSettings.globalize_path(file))
	page.queue_free()
	for i in 3:
		await get_tree().process_frame


# 被挡的三条：左、右、底。
func _place_strips() -> void:
	var view := get_viewport().get_visible_rect().size
	var insets := SafeArea.insets()
	_strips[0].position = Vector2.ZERO
	_strips[0].size = Vector2(insets.x, view.y)
	_strips[1].position = Vector2(view.x - insets.z, 0.0)
	_strips[1].size = Vector2(insets.z, view.y)
	_strips[2].position = Vector2(0.0, view.y - insets.w)
	_strips[2].size = Vector2(view.x, insets.w)
