extends Control

signal selected(value: Variant)
signal canceled

const RACE_LOGO_PATH := "res://assets/ui/race_logos/%s.png"
# 11.11 羊皮纸风（ui/theme/ParchmentKit.gd）：外框大面板、模式选项纸条卡、种族小框、羊皮纸按钮。
const Kit := preload("res://ui/theme/ParchmentKit.gd")
const UiJuice := preload("res://ui/theme/UiJuice.gd")
const INK := Color("4a2c14")
const SUBTLE := Color("7a5634")
const GOLD := Color("8a4b12")
const DARK := Color("15252a")
const PICK_TINT := Color(1.0, 0.86, 0.56)

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
	frame.add_theme_stylebox_override("panel", Kit.box("panel", Vector4(70, 50, 70, 40)))
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
	UiJuice.pop_in([frame], 0.0, 0.0, 0.88)


func _build_modes(content: VBoxContainer) -> void:
	var specs := [
		["casual", _t("青苗", "SEEDLING"), _t("13回合·最多3族·休闲娱乐", "13 rounds · up to 3 races · casual play")],
		["casual_normal", _t("普通", "NORMAL"), _t("21回合·至少携带4族·休闲娱乐", "21 rounds · equip at least 4 races · casual play")],
		["ranked", _t("排位", "RANKED"), _t("21回合·至少携带4族·段位积分", "21 rounds · equip at least 4 races · ranked points")],
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
		title.position = Vector2(44, 10)
		title.size = Vector2(400, 38)
		title.mouse_filter = Control.MOUSE_FILTER_IGNORE
		title.add_theme_font_size_override("font_size", 28)
		title.add_theme_color_override("font_color", GOLD if mode == current_mode else INK)
		card.add_child(title)
		var summary := Label.new()
		summary.text = str(spec[2])
		summary.position = Vector2(45, 50)
		summary.size = Vector2(720, 28)
		summary.mouse_filter = Control.MOUSE_FILTER_IGNORE
		summary.add_theme_font_size_override("font_size", 17)
		summary.add_theme_color_override("font_color", SUBTLE)
		card.add_child(summary)
		if mode == current_mode:
			var badge := Label.new()
			badge.text = _t("当前", "ACTIVE")
			badge.position = Vector2(560, 12)
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
	# 三种按钮各用一种羊皮纸部件：
	#   种族卡（166x180）→ 方形小框，选中染金
	#   模式卡（整行宽、92 高）→ 纸条，当前模式用金色那条
	#   其余（返回 / 确认）→ 羊皮纸小底板，可点的主操作用金色
	var m := button.custom_minimum_size
	if m.y >= 150.0:
		var tint := PICK_TINT if active else Color.WHITE
		button.add_theme_stylebox_override("normal", Kit.box("slot", Vector4(8, 8, 8, 8), tint))
		button.add_theme_stylebox_override("hover", Kit.box("slot", Vector4(8, 8, 8, 8), tint * Color(1.06, 1.05, 1.0)))
		button.add_theme_stylebox_override("pressed", Kit.box("slot", Vector4(8, 8, 8, 8), tint * Color(0.9, 0.88, 0.84)))
		button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		button.add_theme_stylebox_override("disabled", Kit.box("slot", Vector4(8, 8, 8, 8), Color(0.72, 0.68, 0.62)))
		UiJuice.attach(button, 1.04, 0.95)
	elif m.x <= 0.0 and m.y >= 80.0:
		var piece := "list_row_gold" if active else "list_row"
		var pad := Vector4(30, 8, 34, 10)
		button.add_theme_stylebox_override("normal", Kit.box(piece, pad))
		button.add_theme_stylebox_override("hover", Kit.box(piece, pad, Color(1.06, 1.05, 1.0)))
		button.add_theme_stylebox_override("pressed", Kit.box(piece, pad, Color(0.9, 0.88, 0.84)))
		button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		UiJuice.attach(button, 1.02, 0.97)
	else:
		Kit.style_plate(button, active)
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
