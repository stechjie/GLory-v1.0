extends Control
# 头像选择器。由 ProfileScreen 推进 ModalStack，选中后 emit picked 再自行关闭。
#
# 只铺**缩略图**（128x128），不铺原图。原图 330x330、解码后每张约 435 KB 显存，
# 二十张一起铺出来会卡一下 —— 而这是每个玩家进资料页必做的第一个操作。
# 缩略图由 tools/make_avatar_thumbs.py 生成。
#
# 这里**不判「你有没有资格用这个头像」**。今天全部免费，以后有活动限定时，
# 判定归后端 avatar_catalog.py —— 客户端的清单可能比部署的后端旧。

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const Catalog := preload("res://scripts/account/AvatarCatalog.gd")

signal picked(avatar_value: String)
signal dismissed()

const COLUMNS := 5
const CELL := 96.0

var _selected := ""


func configure(current_value: String) -> void:
	_selected = Catalog.id_from_value(current_value)


func _ready() -> void:
	theme = Theming.get_theme()
	_build()


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box())
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(COLUMNS * CELL + 64, 0)
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

	# 二十张放得下，不用滚。以后头像池变大时这里要换成 ScrollContainer ——
	# 留个记号免得那时候才发现底下几排点不到。
	var grid := GridContainer.new()
	grid.columns = COLUMNS
	grid.add_theme_constant_override("h_separation", Tokens.GAP_S)
	grid.add_theme_constant_override("v_separation", Tokens.GAP_S)
	column.add_child(grid)

	for entry in Catalog.avatars():
		grid.add_child(_make_cell(entry as Dictionary))

	var cancel := Button.new()
	cancel.text = _text("取消", "Cancel")
	cancel.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	cancel.pressed.connect(func() -> void: dismissed.emit())
	column.add_child(cancel)


func _make_cell(entry: Dictionary) -> Control:
	var id := str(entry.get("id", ""))
	var button := Button.new()
	button.custom_minimum_size = Vector2(CELL, CELL)
	button.tooltip_text = Catalog.display_name(id)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# 选中的那个描金边：这一页的核心操作是「换」，玩家得先看清现在是哪个。
	var edge := Tokens.GOLD_EDGE if id == _selected else Tokens.BORDER
	var box := Tokens.flat_box(Tokens.SURFACE_RAISED, edge, 3 if id == _selected else 1)
	for state in ["normal", "hover", "pressed"]:
		button.add_theme_stylebox_override(state, box)
	button.pressed.connect(func() -> void: picked.emit("preset:%s" % id))

	var icon := TextureRect.new()
	icon.texture = Catalog.texture_for("preset:%s" % id, true)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 6
	icon.offset_top = 6
	icon.offset_right = -6
	icon.offset_bottom = -6
	# 图不能吃掉点击 —— 否则整个格子只有边框那一圈能点。
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(icon)
	return button


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
