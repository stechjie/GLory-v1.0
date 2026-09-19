extends PanelContainer

# 语音面板（docs/聊天系统设计.md 第九节 v1.1）：切档 + 同队成员（谁在说话、屏蔽）+ 当前状态。
#
# 从语音按钮旁边的「队友」按钮打开（大厅 / 备战期 / 战斗界面共用，见 VoiceControls.gd）。
# 走 ModalStack：点外面收起、返回键能关、页面切走（owner 被释放）自动关。
# 按钮一律实例化 GloryActionButton.tscn，不写 Button.new()（V3 P1-08 棘轮）。
#
# 连接状态 / 声音模式 / 输出设备 / 回声消除收在「诊断信息」里，默认不占主界面层级。

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")

const MODAL_ID := "voice_panel"
# 与 ChatInputBar 同档：高于页面级面板（40），低于 DialogService（100）—— 开麦前的用途说明要盖在它上面。
const MODAL_PRIORITY := 50
const PANEL_WIDTH := 520.0
const REFRESH_SEC := 0.25
const SPEAKING_COLOR := Color(0.55, 1.0, 0.55)
const MODE_LISTEN_COLOR := Color(0.50, 0.88, 1.0)

var _on_talk_requested: Callable = Callable()
var _mode_buttons: Array[Button] = []
var _note: Label
var _members: VBoxContainer
var _state: Label
var _status: Label
var _details_button: Button
var _details_open := false
var _context := ""
var _speaking_labels: Dictionary = {}   # slot -> Label
var _member_signature := "<none>"


# on_talk_requested：点「开麦」时交给调用方（它负责没权限时先弹用途说明），与语音按钮走同一条路。
func present(owner: Object, on_talk_requested: Callable, options: Dictionary = {}) -> void:
	_on_talk_requested = on_talk_requested
	_context = str(options.get("context", ""))
	ModalStack.push(self, {
		"id": MODAL_ID,
		"owner": owner,
		"priority": MODAL_PRIORITY,
		"dismiss_on_backdrop": true,
	})


func _ready() -> void:
	name = "PrepVoicePanel" if _context == "prep" else "VoicePanel"
	theme = Theming.get_theme()
	add_theme_stylebox_override("panel",
		Tokens.panel_box(Tokens.INK_PANEL, Tokens.INK_EDGE, Tokens.GAP_M))
	var width := minf(PANEL_WIDTH, get_viewport_rect().size.x - Tokens.PAD * 2.0)
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -width * 0.5
	offset_right = width * 0.5
	offset_top = 0.0
	offset_bottom = 0.0
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	mouse_filter = Control.MOUSE_FILTER_STOP

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", Tokens.GAP_S)
	add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", Tokens.GAP_S)
	col.add_child(head)
	var title := _label(_text("队伍语音", "Team Voice"), Tokens.FONT_TITLE, Tokens.GOLD_HOVER)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close_button := _button("×", _close, Theming.VARIATION_GHOST)
	close_button.custom_minimum_size = Vector2(Tokens.TOUCH_MIN, Tokens.TOUCH_MIN)
	head.add_child(close_button)

	var privacy := _label(_text("只传给同队队友 · 不录音，不保存",
		"Teammates only · Never recorded or stored"), Tokens.FONT_CAPTION, Tokens.TEXT_SECONDARY)
	privacy.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(privacy)

	_state = _label("", Tokens.FONT_BODY, Tokens.TEXT_PRIMARY)
	_state.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_state)

	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", Tokens.GAP_S)
	col.add_child(modes)
	var mode_texts := [_text("关闭", "Off"), _text("只听", "Listen"), _text("开麦", "Mic on")]
	for mode_value in [VoiceService.Mode.OFF, VoiceService.Mode.LISTEN, VoiceService.Mode.TALK]:
		var button := _button(str(mode_texts[int(mode_value)]), _on_mode_pressed.bind(int(mode_value)))
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		modes.add_child(button)
		_mode_buttons.append(button)

	_note = _label("", Tokens.FONT_CAPTION, Tokens.DANGER_HOVER)
	col.add_child(_note)

	var member_title := _label(_text("队伍频道", "TEAM CHANNEL"), Tokens.FONT_CAPTION, Tokens.GOLD)
	member_title.add_theme_constant_override("outline_size", 1)
	col.add_child(member_title)
	col.add_child(_label(_text("屏蔽只影响你自己，对方不会收到提示",
		"Muting only affects what you hear; teammates are not notified"), Tokens.FONT_CAPTION, Tokens.TEXT_SECONDARY))
	_members = VBoxContainer.new()
	_members.add_theme_constant_override("separation", Tokens.GAP_S)
	col.add_child(_members)

	_status = _label("", Tokens.FONT_CAPTION, Tokens.TEXT_SECONDARY)
	_status.visible = false
	col.add_child(_status)
	_details_button = _button(_text("诊断信息", "Diagnostics"), _toggle_details, Theming.VARIATION_GHOST)
	_details_button.custom_minimum_size = Vector2(128, Tokens.TOUCH_MIN)
	_details_button.size_flags_horizontal = Control.SIZE_SHRINK_END
	col.add_child(_details_button)

	if not VoiceService.mode_changed.is_connected(_on_voice_mode_changed):
		VoiceService.mode_changed.connect(_on_voice_mode_changed)
	if not VoiceService.mutes_changed.is_connected(_refresh):
		VoiceService.mutes_changed.connect(_refresh)
	var timer := Timer.new()
	timer.wait_time = REFRESH_SEC
	timer.autostart = true
	timer.timeout.connect(_refresh)
	add_child(timer)
	_refresh()


func _exit_tree() -> void:
	if VoiceService.mode_changed.is_connected(_on_voice_mode_changed):
		VoiceService.mode_changed.disconnect(_on_voice_mode_changed)
	if VoiceService.mutes_changed.is_connected(_refresh):
		VoiceService.mutes_changed.disconnect(_refresh)


func _on_mode_pressed(target: int) -> void:
	if target == VoiceService.Mode.TALK and _on_talk_requested.is_valid():
		_on_talk_requested.call()
	else:
		var reason := VoiceService.set_mode(target)
		if not reason.is_empty():
			DialogService.info({"owner": self, "body": reason})
	_refresh()


func _on_voice_mode_changed(_mode: int) -> void:
	_refresh()


func _on_mute_pressed(slot: int) -> void:
	VoiceService.set_muted(slot, not VoiceService.is_muted(slot))


func _refresh() -> void:
	for i in _mode_buttons.size():
		_mode_buttons[i].theme_type_variation = Theming.VARIATION_PRIMARY if i == VoiceService.mode \
			else Theming.VARIATION_GHOST
	var note := ""
	if not VoiceService.is_supported():
		note = VoiceService.unsupported_reason()
	elif not VoiceService.in_room():
		note = _text("进入房间后才能开语音", "Join a room to use voice")
	elif not VoiceService.last_error().is_empty():
		# 连不上（服务器没开语音、网络不通……）或开麦失败：原因直接写出来；连接问题 VoiceService 会自己退避重试。
		note = VoiceService.last_error()
	_note.text = note
	_note.visible = not note.is_empty()
	_state.text = _state_text()
	_state.add_theme_color_override("font_color", _state_color())
	_refresh_members()
	_status.text = _diagnostic_text()
	_status.visible = _details_open and not _status.text.is_empty()
	_details_button.visible = not _status.text.is_empty()
	_details_button.text = _text("收起诊断", "Hide diagnostics") if _details_open \
		else _text("诊断信息", "Diagnostics")


func _refresh_members() -> void:
	var mates := VoiceService.teammates()
	var signature := ""
	for mate in mates:
		signature += "%d|%s|%s;" % [int(mate.slot), str(mate.name), str(mate.muted)]
	if signature != _member_signature:
		_member_signature = signature
		for child in _members.get_children():
			_members.remove_child(child)
			child.queue_free()
		_speaking_labels.clear()
		if mates.is_empty():
			_members.add_child(_label(_text("暂时没有同队的真人队友", "No human teammates yet"),
				Tokens.FONT_BODY, Tokens.TEXT_SECONDARY))
		for mate in mates:
			var slot := int(mate.slot)
			var muted := bool(mate.muted)
			var row_panel := PanelContainer.new()
			row_panel.custom_minimum_size = Vector2(0, 58)
			var row_style := Tokens.flat_box(Tokens.SURFACE_RAISED, Tokens.BORDER, 1, Tokens.RADIUS_SMALL)
			row_style.set_content_margin_all(Tokens.GAP_S)
			row_panel.add_theme_stylebox_override("panel", row_style)
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", Tokens.GAP_S)
			row_panel.add_child(row)
			var seat := _label(_seat_text(slot), Tokens.FONT_CAPTION, Tokens.GOLD_HOVER)
			seat.custom_minimum_size = Vector2(26, 0)
			seat.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			seat.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			row.add_child(seat)
			var name_label := _label(str(mate.name), Tokens.FONT_BODY, Tokens.TEXT_PRIMARY)
			name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
			# 昵称最长 24 字，放不下就「…」收尾（只 clip 会把字切一半）；鼠标停上去看全名。
			name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			name_label.tooltip_text = str(mate.name)
			name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(name_label)
			var speaking := _label(_text("● 说话中", "● Talking"), Tokens.FONT_CAPTION, SPEAKING_COLOR)
			speaking.autowrap_mode = TextServer.AUTOWRAP_OFF
			speaking.size_flags_horizontal = Control.SIZE_SHRINK_END
			row.add_child(speaking)
			_speaking_labels[slot] = speaking
			var mute := _button(_text("取消屏蔽", "Unmute") if muted else _text("屏蔽", "Mute"),
				_on_mute_pressed.bind(slot), Theming.VARIATION_DANGER if muted else Theming.VARIATION_GHOST)
			mute.custom_minimum_size = Vector2(104, Tokens.TOUCH_MIN)
			row.add_child(mute)
			_members.add_child(row_panel)
	for mate in mates:
		var label: Label = _speaking_labels.get(int(mate.slot), null)
		if label != null and is_instance_valid(label):
			label.visible = bool(mate.speaking) and not bool(mate.muted)


func _state_text() -> String:
	match VoiceService.mode:
		VoiceService.Mode.LISTEN:
			return _text("● 只听模式 · 麦克风已关闭", "● Listen only · Microphone off")
		VoiceService.Mode.TALK:
			return _text("● 麦克风已开启 · 同队队友可以听见你", "● Mic on · Teammates can hear you")
		_:
			return _text("● 语音已关闭 · 不使用麦克风", "● Voice off · Microphone not in use")


func _state_color() -> Color:
	if VoiceService.mode == VoiceService.Mode.TALK:
		return SPEAKING_COLOR
	if VoiceService.mode == VoiceService.Mode.LISTEN:
		return MODE_LISTEN_COLOR
	return Tokens.TEXT_SECONDARY


# 测试有问题时报这一行，比「声音怪怪的」有用：连没连上、手机在哪种声音模式、从哪出声、谁在做回声消除。
func _diagnostic_text() -> String:
	if not VoiceService.is_supported() or VoiceService.mode == VoiceService.Mode.OFF:
		return ""
	var connection := {
		"connected": _text("已连上", "connected"),
		"connecting": _text("连接中", "connecting"),
		"reconnecting": _text("重连中", "reconnecting"),
		"failed": _text("连不上", "failed"),
		"disconnected": _text("已断开", "disconnected"),
	}
	var audio_mode := {"call": _text("通话", "call"), "media": _text("媒体（只听）", "media (listen only)")}
	var aec := {"system": _text("系统", "system"), "webrtc": "WebRTC"}
	var outputs := {
		"speaker": _text("外放", "speaker"),
		"earpiece": _text("听筒", "earpiece"),
		"bluetooth": _text("蓝牙耳机", "Bluetooth"),
		"wired": _text("有线耳机", "wired headset"),
		"system": _text("系统决定", "system"),
	}
	var state := VoiceService.connection_state()
	var st := VoiceService.status()
	var caps := VoiceService.capabilities()
	var output := str(st.get("output", "")).strip_edges()
	return _text("连接：%s · 声音模式：%s · 输出：%s · 回声消除：%s",
		"Connection: %s · Audio mode: %s · Output: %s · Echo cancel: %s") % [
		str(connection.get(state, state)),
		str(audio_mode.get(str(st.get("audio_mode", "")), "-")),
		str(outputs.get(output, output)) if not output.is_empty() else "-",
		str(aec.get(str(caps.get("aec", "")), _text("无", "none")))]


func _toggle_details() -> void:
	_details_open = not _details_open
	_refresh()


func _seat_text(slot: int) -> String:
	var seats := ["A", "B", "C", "1", "2", "3"]
	return seats[slot] if slot >= 0 and slot < seats.size() else "?"


func _close() -> void:
	ModalStack.pop(MODAL_ID)


func _button(label_text: String, on_press: Callable, variation: StringName = &"") -> Button:
	var button := ACTION_BUTTON.instantiate() as Button
	button.text = label_text
	button.custom_minimum_size = Vector2(96, Tokens.TOUCH_MIN)
	if variation != &"":
		button.theme_type_variation = variation
	button.pressed.connect(on_press)
	return button


func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
