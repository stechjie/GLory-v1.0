extends CanvasLayer

# 观战者对局内的那一条：右上角 6 个头像（点哪个看哪个选手）+「退出观战」。
# 2026-10-22 定：默认看红队第一个座位；红队三个在左、蓝队三个在右，边框用队伍色。
#
# 挂在 Main 上、盖在备战 / 战斗 / 结算界面之上（layer 高于各界面），所以备战页那层
# 观战遮罩挡不住它。数据都来自 NetworkService.spectate_state（只有公开身份）。

signal seat_selected(slot: int)
signal leave_requested

const AvatarCatalog := preload("res://scripts/account/AvatarCatalog.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")

const AVATAR := 58.0
const GAP := 8.0

var _row: HBoxContainer
var _buttons: Array[Button] = []
var _caption: Label


func _ready() -> void:
	layer = 60
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	var box := VBoxContainer.new()
	box.anchor_left = 1.0
	box.anchor_right = 1.0
	# 右上角那一列（x > 1470）是备战页的「佣兵 / 队伍佣兵 / 萝卜」按钮，往左让开，
	# 顶上那排（设定 / 上一局统计）在 y < 70，往下让开（截图核对过，reports/spectator/match_*）。
	box.offset_right = -134
	box.offset_top = 80
	box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	box.alignment = BoxContainer.ALIGNMENT_END
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(box)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", int(GAP))
	_row.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(_row)
	for slot in 6:
		var btn := Button.new()
		btn.name = "seat_%d" % slot
		btn.custom_minimum_size = Vector2(AVATAR, AVATAR)
		btn.focus_mode = Control.FOCUS_NONE
		btn.expand_icon = true
		btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.pressed.connect(func(): seat_selected.emit(slot))
		if slot == 3:
			# 两队之间留一道缝，一眼看出哪三个是一队。
			var spacer := Control.new()
			spacer.custom_minimum_size = Vector2(10, 0)
			_row.add_child(spacer)
		_row.add_child(btn)
		_buttons.append(btn)
	var bottom := HBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGNMENT_END
	bottom.add_theme_constant_override("separation", 10)
	box.add_child(bottom)
	_caption = Label.new()
	_caption.add_theme_font_size_override("font_size", 17)
	_caption.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	_caption.add_theme_color_override("font_outline_color", Tokens.INK_PANEL)
	_caption.add_theme_constant_override("outline_size", 3)
	bottom.add_child(_caption)
	var leave := Button.new()
	leave.name = "leave"
	leave.text = _t("退出观战", "Leave")
	leave.focus_mode = Control.FOCUS_NONE
	leave.add_theme_font_size_override("font_size", 16)
	leave.pressed.connect(func(): leave_requested.emit())
	bottom.add_child(leave)
	refresh()


# state：NetworkService.spectate_state；selected：当前看的座位。
func refresh(state: Dictionary = NetworkService.spectate_state, selected: int = NetworkService.spectate_view_slot) -> void:
	if _buttons.is_empty():
		return
	var states: Array = state.get("slot_states", [])
	var profiles: Dictionary = state.get("seat_profiles", {})
	for slot in 6:
		var btn := _buttons[slot]
		var seat_state := str(states[slot]) if slot < states.size() else "empty"
		var identity: Dictionary = profiles.get(slot, profiles.get(str(slot), {}))
		btn.icon = AvatarCatalog.texture_for(str(identity.get("avatar", AvatarCatalog.default_avatar())), true)
		btn.disabled = seat_state == "empty"
		btn.tooltip_text = _seat_name(slot, seat_state, identity)
		var picked := slot == selected
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.08, 0.07, 0.06, 0.85)
		sb.border_color = Tokens.GOLD_HOVER if picked else GameConstants.team_color_of_slot(slot)
		sb.set_border_width_all(4 if picked else 2)
		sb.set_corner_radius_all(int(AVATAR * 0.5))
		for style in ["normal", "hover", "pressed", "focus", "disabled"]:
			btn.add_theme_stylebox_override(style, sb)
		btn.modulate = Color(1, 1, 1, 0.45 if seat_state == "empty" else 1.0)
	var picked_identity: Dictionary = profiles.get(selected, profiles.get(str(selected), {}))
	var picked_state := str(states[selected]) if selected < states.size() else "empty"
	_caption.text = _t("正在观看：%s", "Watching: %s") % _seat_name(selected, picked_state, picked_identity)


func _seat_name(slot: int, seat_state: String, identity: Dictionary) -> String:
	if seat_state == "dummy":
		return "AI"
	var name := str(identity.get("player_name", ""))
	if name.is_empty():
		return ["A", "B", "C", "1", "2", "3"][slot]
	return name


func _t(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
