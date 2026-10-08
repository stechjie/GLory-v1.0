extends Control
# Full-screen result presentation. Match state and settlement actions stay in Main.

signal details_requested
signal return_room_requested
signal return_menu_requested

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const Action := preload("res://ui/components/GloryActionButton.tscn")
const WIN_ART := preload("res://assets/ui/game_over/victory.png")
const LOSE_ART := preload("res://assets/ui/game_over/defeat.png")

var result_kind := "lose"
var title_text := ""
var body_text := ""
var show_details := false
var can_return_room := false


func _ready() -> void:
	theme = Theming.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var art := TextureRect.new()
	art.texture = WIN_ART if result_kind == "win" else LOSE_ART
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(art)
	var veil := ColorRect.new()
	veil.color = Color(0.02, 0.04, 0.08, 0.23)
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(veil)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(590, 0)
	var accent := Color("f6d583") if result_kind == "win" else Color("a8c7df")
	frame.add_theme_stylebox_override("panel", Tokens.panel_box(Color(0.035, 0.065, 0.11, 0.84), accent, 18))
	center.add_child(frame)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 15)
	frame.add_child(column)

	var eyebrow := Label.new()
	eyebrow.text = _text("荣耀战绩", "MATCH RESULT") if result_kind == "win" else _text("战局落幕", "MATCH ENDED")
	eyebrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	eyebrow.add_theme_font_size_override("font_size", 17)
	eyebrow.add_theme_color_override("font_color", accent)
	column.add_child(eyebrow)
	var title := Label.new()
	title.text = title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 48)
	title.add_theme_color_override("font_color", accent)
	column.add_child(title)
	var line := HSeparator.new()
	column.add_child(line)
	var body := Label.new()
	body.text = body_text
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(540, 82)
	body.add_theme_font_size_override("font_size", 20)
	body.add_theme_color_override("font_color", Color("e5eaf1"))
	column.add_child(body)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 18)
	column.add_child(actions)
	if show_details:
		var details := _button(_text("查看详情", "View Details"), actions)
		details.pressed.connect(func() -> void: details_requested.emit())
	else:
		if can_return_room:
			var room := _button(_text("返回房间", "Return to Room"), actions)
			room.pressed.connect(func() -> void:
				room.disabled = true
				return_room_requested.emit())
		var menu := _button(_text("返回主菜单", "Main Menu"), actions)
		menu.pressed.connect(func() -> void: return_menu_requested.emit())


func _button(label: String, parent: Node) -> Button:
	var button := Action.instantiate() as Button
	button.text = label
	button.custom_minimum_size = Vector2(180, Tokens.TOUCH_MIN)
	parent.add_child(button)
	return button


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
