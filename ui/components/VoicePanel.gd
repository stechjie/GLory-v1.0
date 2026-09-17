extends PanelContainer

# 语音面板（docs/聊天系统设计.md 第九节 v1.1）：切档 + 同队成员（谁在说话、屏蔽）+ 当前状态。
#
# 从语音按钮旁边的「队友」按钮打开（大厅 / 备战期 / 战斗界面共用，见 VoiceControls.gd）。
# 走 ModalStack：点外面收起、返回键能关、页面切走（owner 被释放）自动关。
# 按钮一律实例化 GloryActionButton.tscn，不写 Button.new()（V3 P1-08 棘轮）。
#
# 最下面那行状态（编码 / Opus 自检 / 输出设备 / 回声消除）是给测试的人看的：
# 有问题时报这一行，比描述「声音怪怪的」有用得多。

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")

const MODAL_ID := "voice_panel"
# 与 ChatInputBar 同档：高于页面级面板（40），低于 DialogService（100）—— 开麦前的用途说明要盖在它上面。
const MODAL_PRIORITY := 50
const PANEL_WIDTH := 560.0
const REFRESH_SEC := 0.25
const SPEAKING_COLOR := Color(0.55, 1.0, 0.55)

var _on_talk_requested: Callable = Callable()
var _mode_buttons: Array[Button] = []
var _note: Label
var _members: VBoxContainer
var _status: Label
var _speaking_labels: Dictionary = {}   # slot -> Label
var _member_signature := "<none>"


# on_talk_requested：点「开麦」时交给调用方（它负责没权限时先弹用途说明），与语音按钮走同一条路。
func present(owner: Object, on_talk_requested: Callable) -> void:
	_on_talk_requested = on_talk_requested
	ModalStack.push(self, {
		"id": MODAL_ID,
		"owner": owner,
		"priority": MODAL_PRIORITY,
		"dismiss_on_backdrop": true,
	})


func _ready() -> void:
	theme = Theming.get_theme()
	add_theme_stylebox_override("panel", Tokens.panel_box())
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
	var title := _label(_text("语音", "Voice"), Tokens.FONT_TITLE, Tokens.TEXT_PRIMARY)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	head.add_child(_button(_text("关闭", "Close"), _close, Theming.VARIATION_GHOST))

	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", Tokens.GAP_S)
	col.add_child(modes)
	var mode_texts := [_text("关", "Off"), _text("只听", "Listen"), _text("开麦", "Mic on")]
	for mode_value in [VoiceService.Mode.OFF, VoiceService.Mode.LISTEN, VoiceService.Mode.TALK]:
		var button := _button(str(mode_texts[int(mode_value)]), _on_mode_pressed.bind(int(mode_value)))
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		modes.add_child(button)
		_mode_buttons.append(button)

	_note = _label("", Tokens.FONT_CAPTION, Tokens.DANGER_HOVER)
	col.add_child(_note)

	col.add_child(_label(_text("同队队友（屏蔽只影响你自己听不听得到，对方不会知道）",
		"Teammates (muting only affects what you hear; they won't know)"), Tokens.FONT_CAPTION, Tokens.TEXT_SECONDARY))
	_members = VBoxContainer.new()
	_members.add_theme_constant_override("separation", Tokens.GAP_S)
	col.add_child(_members)

	_status = _label("", Tokens.FONT_CAPTION, Tokens.TEXT_SECONDARY)
	col.add_child(_status)

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
		note = _text("这个版本没有语音功能（需要带语音插件的安卓包）", "Voice is not available in this build")
	elif not VoiceService.in_room():
		note = _text("进入房间后才能开语音", "Join a room to use voice")
	_note.text = note
	_note.visible = not note.is_empty()
	_refresh_members()
	_status.text = _status_text()
	_status.visible = not _status.text.is_empty()


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
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", Tokens.GAP_S)
			var name_label := _label(str(mate.name), Tokens.FONT_BODY, Tokens.TEXT_PRIMARY)
			name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
			# 昵称最长 24 字，放不下就「…」收尾（只 clip 会把字切一半）；鼠标停上去看全名。
			name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			name_label.tooltip_text = str(mate.name)
			name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(name_label)
			var speaking := _label(_text("说话中", "Talking"), Tokens.FONT_CAPTION, SPEAKING_COLOR)
			speaking.autowrap_mode = TextServer.AUTOWRAP_OFF
			speaking.size_flags_horizontal = Control.SIZE_SHRINK_END
			row.add_child(speaking)
			_speaking_labels[slot] = speaking
			var mute := _button(_text("取消屏蔽", "Unmute") if muted else _text("屏蔽", "Mute"),
				_on_mute_pressed.bind(slot), Theming.VARIATION_DANGER if muted else Theming.VARIATION_GHOST)
			row.add_child(mute)
			_members.add_child(row)
	for mate in mates:
		var label: Label = _speaking_labels.get(int(mate.slot), null)
		if label != null and is_instance_valid(label):
			label.visible = bool(mate.speaking) and not bool(mate.muted)


func _status_text() -> String:
	if not VoiceService.is_supported():
		return ""
	var st := VoiceService.status()
	if st.is_empty():
		return _text("语音没开", "Voice is off")
	var caps := VoiceService.capabilities()
	var aec := _text("可用", "available") if bool(caps.get("aec_available", false)) else _text("无", "none")
	var device := str(st.get("output_device", "")).strip_edges()
	if device.is_empty():
		device = "-"
	if str(st.get("platform", "")) == "desktop":
		# 电脑版试用（scripts/voice/DesktopVoiceBackend.gd）：把测试时最容易误判的三件事直接写出来。
		var line := _text("电脑版 · 编码：ADPCM · 输出：%s · 没有回声消除（外放开麦队友会听到回声）",
			"PC · Codec: ADPCM · Output: %s · No echo cancellation (speakers will echo)") % device
		if bool(st.get("mic_silent", false)):
			line += _text("\n麦克风没有声音：检查 Windows 设置 → 隐私和安全性 → 麦克风，允许桌面应用访问",
				"\nMic is silent: check Windows Settings → Privacy → Microphone (allow desktop apps)")
		if bool(st.get("opus_from_teammates", false)):
			line += _text("\n有队友的手机发的是 Opus，电脑版暂时听不到他",
				"\nA teammate's phone sends Opus, which the PC build cannot play yet")
		return line
	return _text("编码：%s（Opus 自检：%s）· 输出：%s · 系统回声消除：%s",
		"Codec: %s (Opus self-test: %s) · Output: %s · Echo cancel: %s") % [
		VoiceService.codec_label(), str(st.get("opus_selftest", "-")), device, aec]


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
