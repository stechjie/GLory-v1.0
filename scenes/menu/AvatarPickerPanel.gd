extends Control
# Profile avatar picker: five race tabs and one mercenary tab.
# Existing avatar IDs remain stable; catalog entries decide the visual group.

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const Catalog := preload("res://scripts/account/AvatarCatalog.gd")

signal picked(avatar_value: String)
signal dismissed()

const COLUMNS := 5
const CELL := 96.0
const GROUPS := [
	["human", "人族", "Human"],
	["dark", "魔族", "Dark"],
	["god", "神族", "Divine"],
	["undead", "灵族", "Undead"],
	["crimson", "赤律", "Crimson"],
	["mercenary", "佣兵", "Mercs"],
]

var _selected := ""
var _active_group := "human"
var _grid: GridContainer
var _tabs: Dictionary = {}


func configure(current_value: String) -> void:
	_selected = Catalog.id_from_value(current_value)
	for entry in Catalog.avatars():
		var row := entry as Dictionary
		if str(row.get("id", "")) == _selected:
			_active_group = str(row.get("group", "human"))
			break


func _ready() -> void:
	theme = Theming.get_theme()
	_build()


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box())
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(COLUMNS * CELL + 80, 0)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Tokens.GAP_M)
	panel.add_child(column)
	var title := Label.new()
	title.text = _text("选择头像", "Choose Avatar")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	column.add_child(title)

	var tabs := HBoxContainer.new()
	tabs.alignment = BoxContainer.ALIGNMENT_CENTER
	tabs.add_theme_constant_override("separation", 6)
	column.add_child(tabs)
	_tabs.clear()
	for spec in GROUPS:
		var group := str(spec[0])
		var tab := Button.new()
		tab.text = _text(str(spec[1]), str(spec[2]))
		tab.custom_minimum_size = Vector2(82, Tokens.TOUCH_MIN)
		tab.pressed.connect(_show_group.bind(group))
		tabs.add_child(tab)
		_tabs[group] = tab

	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("h_separation", Tokens.GAP_S)
	_grid.add_theme_constant_override("v_separation", Tokens.GAP_S)
	column.add_child(_grid)
	_show_group(_active_group)

	var cancel := Button.new()
	cancel.text = _text("取消", "Cancel")
	cancel.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	cancel.pressed.connect(func() -> void: dismissed.emit())
	column.add_child(cancel)


func _show_group(group: String) -> void:
	_active_group = group
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	for entry in Catalog.avatars():
		var row := entry as Dictionary
		if str(row.get("group", "")) == group:
			_grid.add_child(_make_cell(row))
	for key in _tabs:
		var tab := _tabs[key] as Button
		var selected: bool = key == group
		var edge := Tokens.GOLD_EDGE if selected else Tokens.BORDER
		var box := Tokens.flat_box(Tokens.SURFACE_RAISED, edge, 2 if selected else 1)
		for state in ["normal", "hover", "pressed"]:
			tab.add_theme_stylebox_override(state, box)


func _make_cell(entry: Dictionary) -> Control:
	var id := str(entry.get("id", ""))
	var button := Button.new()
	button.custom_minimum_size = Vector2(CELL, CELL)
	button.tooltip_text = Catalog.display_name(id)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var edge := Tokens.GOLD_EDGE if id == _selected else Tokens.BORDER
	var box := Tokens.flat_box(Tokens.SURFACE_RAISED, edge, 3 if id == _selected else 1)
	for state in ["normal", "hover", "pressed"]:
		button.add_theme_stylebox_override(state, box)
	button.pressed.connect(func() -> void: picked.emit("preset:%s" % id))
	var icon := TextureRect.new()
	icon.texture = Catalog.texture_for("preset:%s" % id, true)
	if icon.texture == null:
		# A thin checkout can lack external art; never equip a blank avatar.
		button.disabled = true
		button.text = "—"
		button.tooltip_text = _text("头像素材未安装：", "Portrait art unavailable: ") + Catalog.display_name(id)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 6
	icon.offset_top = 6
	icon.offset_right = -6
	icon.offset_bottom = -6
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(icon)
	return button


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
