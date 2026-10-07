extends Control

# 资料页的头像框选择器。只显示默认框和服务端归属列表中的框；服务端仍会复核装备资格。
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const Catalog := preload("res://scripts/account/AvatarCatalog.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")

signal picked(frame_value: String)
signal dismissed()

const CELL_WIDTH := 154.0
const CELL_HEIGHT := 150.0
const TouchScrollContainer := preload("res://ui/components/TouchScrollContainer.gd")

var _selected := ""
var _owned: Dictionary = {}


func configure(current_value: String, owned: Dictionary) -> void:
	_selected = Catalog.id_from_value(current_value)
	_owned = owned.duplicate()


func _ready() -> void:
	theme = Theming.get_theme()
	_build()


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE, Tokens.GOLD_EDGE, Tokens.GAP_M))
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(540, 0)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(column)
	var title := Label.new()
	title.text = _t("我的头像框", "My Avatar Frames")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	column.add_child(title)
	var hint := Label.new()
	hint.text = _t("点击已拥有的头像框即可佩戴", "Tap an owned frame to equip it")
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	column.add_child(hint)
	var scroll := TouchScrollContainer.new()
	scroll.custom_minimum_size = Vector2(510, 490)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", Tokens.GAP_S)
	grid.add_theme_constant_override("v_separation", Tokens.GAP_S)
	scroll.add_child(grid)
	for raw in Catalog.frames():
		var entry := raw as Dictionary
		var id := str(entry.get("id", ""))
		if id != "frame_default" and not _owned.has("preset:%s" % id):
			continue
		grid.add_child(_cell(entry))
	var close: Button = ACTION_BUTTON.instantiate()
	close.text = _t("关闭", "Close")
	close.custom_minimum_size.y = Tokens.TOUCH_MIN
	close.pressed.connect(func() -> void: dismissed.emit())
	column.add_child(close)


func _cell(entry: Dictionary) -> Control:
	var id := str(entry.get("id", ""))
	var button: Button = ACTION_BUTTON.instantiate()
	button.custom_minimum_size = Vector2(CELL_WIDTH, CELL_HEIGHT)
	button.theme_type_variation = (Theming.VARIATION_PRIMARY if id == _selected
		else Theming.VARIATION_GHOST)
	button.pressed.connect(func() -> void: picked.emit("preset:%s" % id))
	var preview := Control.new()
	preview.position = Vector2(11, 4)
	preview.size = Vector2(132, 112)
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(preview)
	var art := TextureRect.new()
	art.texture = Catalog.frame_texture_for("preset:%s" % id, false)
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.add_child(art)
	var name := Label.new()
	name.text = str(entry.get("name_en" if TranslationServer.get_locale().begins_with("en")
		else "name", id))
	name.position = Vector2(5, 116)
	name.size = Vector2(144, 27)
	name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name.clip_text = true
	name.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(name)
	return button


func _t(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
