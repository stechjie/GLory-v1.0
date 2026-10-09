extends Control
# Battle result presentation. Main still owns settlement state and navigation.

signal details_requested
signal return_room_requested
signal return_party_requested
signal return_menu_requested

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const WIN_ART := preload("res://assets/ui/game_over/victory.png")
const LOSE_ART := preload("res://assets/ui/game_over/defeat.png")

var result_kind := "lose"
var title_text := ""
var body_text := ""
var show_details := false
var can_return_room := false
# 10.10 bug 第 9 条：休闲 / 排位的账号服务器队伍房间在「六人确认」时被后端保留，
# 所以结算首屏也要能「返回队伍」（原来这颗只在结算面板里，而休闲首屏走的是本界面）。
var can_return_party := false


func _ready() -> void:
	theme = Theming.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var accent := Color("f6d583") if result_kind == "win" else Color("bfd3e2")
	var art := TextureRect.new()
	art.texture = WIN_ART if result_kind == "win" else LOSE_ART
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(art)
	# The artwork carries the scene. Keep the tint slight and put text directly over
	# its quiet lower half instead of covering the crest with a dark center panel.
	var veil := ColorRect.new()
	veil.color = Color(0.02, 0.025, 0.04, 0.08)
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(veil)

	var heading := VBoxContainer.new()
	heading.add_theme_constant_override("separation", 8)
	_region(0.43, 0.67).add_child(heading)
	var eyebrow := _label(
		_text("荣耀战绩", "MATCH RESULT") if result_kind == "win" else _text("战局落幕", "MATCH ENDED"),
		17, accent)
	heading.add_child(eyebrow)
	var title := _label(title_text, 52, accent)
	heading.add_child(title)
	var rule := ColorRect.new()
	rule.color = Color(accent.r, accent.g, accent.b, 0.85)
	rule.custom_minimum_size = Vector2(560, 2)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	heading.add_child(rule)

	var body := _label(body_text, 21, Color("f4f0e6"))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(700, 70)
	_region(0.69, 0.82).add_child(body)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 18)
	_region(0.83, 0.96).add_child(actions)
	if show_details:
		var details := _button(_text("查看详情", "View Details"), actions, accent)
		details.pressed.connect(func() -> void: details_requested.emit())
	else:
		if can_return_room:
			var room := _button(_text("返回房间", "Return to Room"), actions, accent)
			room.pressed.connect(func() -> void:
				room.disabled = true
				return_room_requested.emit())
		# 10.10 bug 第 9 条：休闲 / 排位对局结束能回到原队伍房间。
		# ⚠ 文案走 LocaleManager 的 settle_back_party —— 与结算面板那颗是**同一个 key**，
		#   一处改中英两边都跟着变，别在这里再写一份字面量。
		if can_return_party:
			var party := _button(tr("settle_back_party"), actions, accent)
			party.pressed.connect(func() -> void:
				party.disabled = true
				return_party_requested.emit())
		var menu := _button(_text("返回主菜单", "Main Menu"), actions, accent)
		menu.pressed.connect(func() -> void: return_menu_requested.emit())


func _region(top: float, bottom: float) -> CenterContainer:
	var region := CenterContainer.new()
	region.anchor_left = 0.0
	region.anchor_right = 1.0
	region.anchor_top = top
	region.anchor_bottom = bottom
	add_child(region)
	return region


func _label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 5)
	label.add_theme_color_override("font_outline_color", Color(0.035, 0.025, 0.02, 0.95))
	return label


func _button(value: String, parent: Node, accent: Color) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size = Vector2(190, Tokens.TOUCH_MIN + 4)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# Match the prep screen's dark brown and bronze button treatment.
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.11, 0.075, 0.035, 0.91)
	normal.border_color = accent
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(16)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.28, 0.18, 0.075, 0.96)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.07, 0.045, 0.025, 0.98)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("focus", hover)
	button.add_theme_color_override("font_color", Color("f6e8be"))
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_font_size_override("font_size", 21)
	parent.add_child(button)
	return button


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
