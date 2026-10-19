extends Control

signal selected(value: Variant)
signal canceled

const RACE_LOGO_PATH := "res://assets/ui/race_logos/%s.png"
const INK := Color("f8efd7")
const SUBTLE := Color("c9d1c3")
const GOLD := Color("e5bf6d")
const DARK := Color("15252a")

var kind := "mode"
var current_mode := "casual"
var races: Array = []
var _picked: Array[String] = []
var _confirm: Button
var _counter: Label
var _race_buttons: Dictionary = {}


func configure_modes(active: String) -> void:
	kind = "mode"
	current_mode = active


func configure_races(available: Array) -> void:
	kind = "races"
	races = available.duplicate()
	for raw in races:
		if _picked.size() >= 3:
			break
		_picked.append(str(raw))


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(820, 0)
	frame.add_theme_stylebox_override("panel", _box(Color("14262b"), GOLD, 26, 3))
	center.add_child(frame)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 14)
	frame.add_child(content)
	var heading := Label.new()
	heading.text = _t("选择匹配模式", "CHOOSE A MODE") if kind == "mode" else _t("青苗出战种族", "SEEDLING LINEUP")
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 34)
	heading.add_theme_color_override("font_color", GOLD)
	content.add_child(heading)
	var help := Label.new()
	help.text = _t("选择适合本次对局的规则", "Select the rules for this match") if kind == "mode" else _t("本局最多携带 3 族；不会改动备战区的常驻配置", "Bring up to 3 races for this match. Your prep loadout stays unchanged.")
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.add_theme_color_override("font_color", SUBTLE)
	help.add_theme_font_size_override("font_size", 18)
	content.add_child(help)
	if kind == "mode":
		_build_modes(content)
	else:
		_build_races(content)
	var cancel := Button.new()
	cancel.text = _t("返回", "BACK")
	cancel.custom_minimum_size = Vector2(210, 55)
	_style_button(cancel, false)
	cancel.pressed.connect(func() -> void: canceled.emit())
	content.add_child(cancel)
	cancel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER


func _build_modes(content: VBoxContainer) -> void:
	var specs := [
		["casual", _t("青苗", "SEEDLING"), _t("13 回合 · 每回合 60 秒 · 最多 3 族", "13 rounds · 60s prep · up to 3 races")],
		["casual_normal", _t("普通", "NORMAL"), _t("21 回合 · 至少携带 4 族", "21 rounds · equip at least 4 races")],
		["ranked", _t("排位", "RANKED"), _t("至少 3 族参赛 · 携带 4 族才能突破森卫", "3+ races to play · equip 4 to pass Forest")],
	]
	for spec in specs:
		var mode: String = spec[0]
		var card := Button.new()
		card.text = ""
		card.custom_minimum_size = Vector2(0, 92)
		_style_button(card, mode == current_mode)
		card.pressed.connect(_choose_mode.bind(mode))
		content.add_child(card)
		var title := Label.new()
		title.text = str(spec[1])
		title.position = Vector2(19, 10)
		title.size = Vector2(400, 38)
		title.mouse_filter = Control.MOUSE_FILTER_IGNORE
		title.add_theme_font_size_override("font_size", 28)
		title.add_theme_color_override("font_color", GOLD if mode == current_mode else INK)
		card.add_child(title)
		var summary := Label.new()
		summary.text = str(spec[2])
		summary.position = Vector2(20, 50)
		summary.size = Vector2(720, 28)
		summary.mouse_filter = Control.MOUSE_FILTER_IGNORE
		summary.add_theme_font_size_override("font_size", 17)
		summary.add_theme_color_override("font_color", SUBTLE)
		card.add_child(summary)
		if mode == current_mode:
			var badge := Label.new()
			badge.text = _t("当前", "ACTIVE")
			badge.position = Vector2(640, 12)
			badge.size = Vector2(90, 32)
			badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
			badge.add_theme_color_override("font_color", GOLD)
			badge.add_theme_font_size_override("font_size", 16)
			card.add_child(badge)


func _build_races(content: VBoxContainer) -> void:
	# Five unlocked races need two centered rows; the permanent prep lineup only holds four.
	var per_row := 3 if races.size() > 4 else 4
	var row: HBoxContainer = null
	for index in range(races.size()):
		if index % per_row == 0:
			row = HBoxContainer.new()
			row.alignment = BoxContainer.ALIGNMENT_CENTER
			row.add_theme_constant_override("separation", 12)
			content.add_child(row)
		var race := str(races[index])
		var card := Button.new()
		card.custom_minimum_size = Vector2(166, 180)
		card.text = ""
		card.add_theme_color_override("font_color", INK)
		card.pressed.connect(_toggle_race.bind(race))
		row.add_child(card)
		_race_buttons[race] = card
		var name_label := Label.new()
		name_label.text = _race_name(race)
		name_label.position = Vector2(8, 117)
		name_label.size = Vector2(150, 45)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_label.add_theme_font_size_override("font_size", 22)
		name_label.add_theme_color_override("font_color", INK)
		card.add_child(name_label)
		var logo_path := RACE_LOGO_PATH % race
		if ResourceLoader.exists(logo_path):
			var logo := TextureRect.new()
			logo.texture = load(logo_path)
			logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
			card.add_child(logo)
			logo.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
			logo.position = Vector2(43, 18)
			logo.size = Vector2(80, 80)
	_counter = Label.new()
	_counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_counter.add_theme_color_override("font_color", SUBTLE)
	_counter.add_theme_font_size_override("font_size", 20)
	content.add_child(_counter)
	_confirm = Button.new()
	_confirm.text = _t("确认阵容，继续匹配", "CONFIRM LINEUP")
	_confirm.custom_minimum_size = Vector2(400, 68)
	_confirm.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_confirm.pressed.connect(func() -> void: selected.emit(_picked.duplicate()))
	content.add_child(_confirm)
	_refresh_races()


func _toggle_race(race: String) -> void:
	if _picked.has(race):
		_picked.erase(race)
	elif _picked.size() < 3:
		_picked.append(race)
	else:
		_counter.text = _t("最多选 3 族，请先取消一族", "Select up to 3; deselect one first")
		return
	_refresh_races()


func _choose_mode(mode: String) -> void:
	selected.emit(mode)


func _refresh_races() -> void:
	for race in _race_buttons:
		var card: Button = _race_buttons[race]
		_style_button(card, _picked.has(race))
	_counter.text = _t("已选 %d / 3 族", "Selected %d / 3 races") % _picked.size()
	_confirm.disabled = _picked.is_empty()
	_style_button(_confirm, not _confirm.disabled)


func _style_button(button: Button, active: bool) -> void:
	var fill := Color("45533a") if active else DARK
	var edge := GOLD if active else Color("62736c")
	button.add_theme_stylebox_override("normal", _box(fill, edge, 13, 2))
	button.add_theme_stylebox_override("hover", _box(fill.lightened(0.12), GOLD, 13, 2))
	button.add_theme_stylebox_override("pressed", _box(fill.darkened(0.12), GOLD, 13, 2))
	button.add_theme_stylebox_override("focus", _box(fill, GOLD, 13, 2))
	button.add_theme_stylebox_override("disabled", _box(Color("283331"), Color("667066"), 13, 1))
	button.add_theme_color_override("font_color", INK)
	button.add_theme_color_override("font_hover_color", INK)
	button.add_theme_color_override("font_pressed_color", INK)
	button.add_theme_color_override("font_disabled_color", SUBTLE)
	button.add_theme_font_size_override("font_size", 22)


func _box(fill: Color, edge: Color, radius: int, border: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = edge
	box.set_border_width_all(border)
	box.set_corner_radius_all(radius)
	box.set_content_margin_all(16)
	return box


func _race_name(race: String) -> String:
	var names := {"human": ["人族", "Human"], "god": ["神族", "Divine"],
		"dark": ["暗族", "Dark"], "undead": ["灵族", "Spirit"],
		"crimson": ["赤律族", "Crimson"]}
	if names.has(race):
		return names[race][0 if not LocaleManager.get_locale().begins_with("en") else 1]
	return race.capitalize()


func _t(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale().begins_with("en") else zh
