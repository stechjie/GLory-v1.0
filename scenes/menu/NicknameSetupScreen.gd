extends Control

signal nickname_saved

const Kit := preload("res://ui/theme/ParchmentKit.gd")
const DEFAULT_NICKNAME := "Player"
const MAX_LENGTH := 24

var _english := LocaleManager.get_locale().begins_with("en")
var _name_edit: LineEdit
var _continue: Button
var _status: Label
var _saving := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = Kit.theme()
	Kit.backdrop(self, "profile_hall", 0.28)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	add_child(scroll)
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = 18
	scroll.offset_top = 18
	scroll.offset_right = -18
	scroll.offset_bottom = -18
	SafeArea.track(scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 12)
	center.add_child(page)

	var title := Kit.title_banner(_t("为自己取个昵称", "Choose Your Nickname"), 78.0, 27)
	title.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	page.add_child(title)

	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 556
	panel.add_theme_stylebox_override("panel", Kit.box("panel", Vector4(56, 48, 56, 40)))
	page.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	panel.add_child(column)
	column.add_child(_label(_t("这个昵称会显示在大厅和对局中。", "This is the name players will see in the lobby and in matches."), 19, Kit.INK))

	_name_edit = LineEdit.new()
	_name_edit.name = "Nickname"
	_name_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_edit.custom_minimum_size.y = 58
	_name_edit.max_length = MAX_LENGTH
	_name_edit.placeholder_text = _t("输入昵称", "Enter nickname")
	_name_edit.add_theme_font_size_override("font_size", 23)
	_name_edit.text_changed.connect(_on_name_changed)
	_name_edit.text_submitted.connect(func(_value: String) -> void: _submit())
	column.add_child(_name_edit)

	_status = _label(_t("最多 %d 个字符" % MAX_LENGTH, "Up to %d characters" % MAX_LENGTH), 16, Kit.INK_SOFT)
	_status.custom_minimum_size.y = 26
	column.add_child(_status)

	_continue = Button.new()
	_continue.name = "Continue"
	_continue.text = _t("确认昵称", "Confirm Nickname")
	_continue.custom_minimum_size = Vector2(256, 54)
	_continue.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_continue.disabled = true
	Kit.style_plate(_continue, true)
	_continue.pressed.connect(_submit)
	column.add_child(_continue)


func _label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _on_name_changed(value: String) -> void:
	var length := value.strip_edges().length()
	_continue.disabled = _saving or length == 0
	_set_status("%d / %d" % [length, MAX_LENGTH])


func _submit() -> void:
	var nickname := _name_edit.text.strip_edges()
	if _saving or nickname.is_empty():
		return
	_saving = true
	_continue.disabled = true
	_name_edit.editable = false
	_name_edit.release_focus()
	_set_status(_t("正在保存昵称…", "Saving nickname…"))
	var result := await _save_nickname(nickname)
	if not is_inside_tree() or is_queued_for_deletion():
		return
	var saved_name := str((result.get("body", {}) as Dictionary).get("player_name", ""))
	if int(result.get("code", 0)) == 200 and not saved_name.is_empty():
		nickname_saved.emit()
		return
	_saving = false
	_continue.disabled = false
	_name_edit.editable = true
	var message := _t("昵称暂时未保存，请重试。", "Could not save your nickname. Try again.")
	if int(result.get("code", 0)) == 400:
		message = _t("这个昵称无法使用，请换一个。", "Choose a different nickname.")
	_set_status(message, true)


func _save_nickname(nickname: String) -> Dictionary:
	return await AccountManager.update_profile({"player_name": nickname})


func _set_status(value: String, failed := false) -> void:
	_status.text = value
	_status.add_theme_color_override("font_color", Color("8b2d24") if failed else Kit.INK_SOFT)


func _t(zh: String, en: String) -> String:
	return en if _english else zh

