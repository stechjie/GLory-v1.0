extends HBoxContainer

# 「按住说话」按钮（docs/聊天系统设计.md「语音消息」，2026-10-11）。
#
# 世界频道与私聊共用：按住录音，正常松手发语音；滑到上方取消或转文字再松手执行。
# scope 决定服务器保留期。房间与对局输入条不再开放录音。
#
# 录到 30 秒会自己停，但**不自动发**：让玩家看一眼再松手决定（同微信）。
# 松手时如果已经停了，照样发出去；想丢掉就把手指拖开再松（_cancelled）。

signal clip_ready(clip: Dictionary)     # 上传成功：{"clip_id", "media", "seconds"}
signal text_ready(text: String)
signal recording_started()
signal failed(message: String)          # 给调用方弹提示（太短、通话中、配额用完…）

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const Kit := preload("res://ui/theme/ParchmentKit.gd")

var _scope := VoiceClipService.SCOPE_PRIVATE
var _button: Button = null
var _hint: Label = null
var _busy := false
var _cancelled := false
var _held := false
var _ios_touch_index := -1
var _ios_touch_origin := Vector2.ZERO
var _disabled := false
var _overlay: CanvasLayer
var _actions: HBoxContainer
var _cancel_action: Button
var _text_action: Button
var _timer: Label
var _gesture_origin := Vector2.ZERO
var _selected_action := "send"
var _seconds := 0.0
const GESTURE_DISTANCE := 56.0

# 按钮画麦克风图标而不是「按住说话」四个字（2026-10-12 用户要求：图标更好识别）。
# 图标用运行时 load()，不 preload：服务器包不带导入过的贴图（同 VoiceControls 的注释）。
#
# ⚠ 用的是 mic_on.svg（那个「开着的麦克风」）。它和 VoiceControls 里的同款图标
# **不是一回事**：那边是「语音通话开/关」的开关状态，这边是「按住录入」的一个动作。
# 位置也分得开（这颗在聊天输入行，那颗在房间/对局的语音条上）。别为了"统一"把它们并起来。
const MIC_ON_ICON := "res://assets/ui/voice/mic_on.svg"
const ICON_BUTTON_SIZE := 132


static func create(scope: String) -> Control:
	var bar := new()
	bar._scope = scope
	return bar


func _ready() -> void:
	if SafeArea.uses_ios_layout():
		SafeArea.changed.connect(_cancel_ios_gesture)
	add_theme_constant_override("separation", Tokens.GAP_S)
	# 容器居中：这个 HBox 里是「麦克风按钮 + 计时提示」两颗。计时提示平时是空的，
	# 一旦它出现/消失，如果不给容器定住对齐方式，按钮会跟着横向抖动、贴左。
	# 定成 CENTER 后按钮位置稳定，图标也始终落在按钮正中（2026-10-14 用户截图反馈）。
	alignment = BoxContainer.ALIGNMENT_CENTER
	_button = ACTION_BUTTON.instantiate() as Button
	# 图标为主：这是三个渠道（私聊 / 世界 / 对局内）共用的同一颗按钮，画成麦克风
	# 一眼就知道是「说话」而不是「发送」——旁边那颗「发送」是字，两颗形状不同才分得开。
	_apply_mic_icon()
	_button.accessibility_name = _text("按住说话", "Hold to talk")
	_button.custom_minimum_size = Vector2(ICON_BUTTON_SIZE, Tokens.TOUCH_MIN)
	_button.button_down.connect(_on_down)
	_button.button_up.connect(_on_up)
	add_child(_button)

	_hint = Label.new()
	_hint.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	_hint.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint.hide()
	add_child(_hint)

	if not VoiceClipService.recording_tick.is_connected(_on_tick):
		VoiceClipService.recording_tick.connect(_on_tick)
	# 权限被拒（移动端）：界面上说清楚「去系统设置里开麦克风」，
	# 不然玩家对着按下去没反应的按钮只会以为功能坏了（2026-10-14）。
	if not VoiceClipService.permission_denied.is_connected(_on_permission_denied):
		VoiceClipService.permission_denied.connect(_on_permission_denied)


func _exit_tree() -> void:
	if SafeArea.changed.is_connected(_cancel_ios_gesture):
		SafeArea.changed.disconnect(_cancel_ios_gesture)
	if _busy:
		VoiceClipService.cancel_transcription()
	if VoiceClipService.recording_tick.is_connected(_on_tick):
		VoiceClipService.recording_tick.disconnect(_on_tick)
	if VoiceClipService.permission_denied.is_connected(_on_permission_denied):
		VoiceClipService.permission_denied.disconnect(_on_permission_denied)
	# 界面被关掉时手还按着：丢掉这次录音，别让麦克风留在开着的状态。
	if VoiceClipService.is_recording():
		VoiceClipService.cancel_recording()


func _on_permission_denied() -> void:
	_hint.text = ""
	failed.emit(_text("没有麦克风权限，去系统设置里打开后再试",
		"Microphone permission denied — enable it in system settings"))


func set_disabled(value: bool) -> void:
	_disabled = value
	if _button != null and is_instance_valid(_button):
		_button.disabled = value or _busy


# 把按钮画成麦克风。素材没了就退回文字 —— 一颗空白按钮玩家不知道是什么，
# 而「图标丢了」这种事在打包时最不容易被发现（开发机上贴图都在）。
func _apply_mic_icon() -> void:
	if _button == null or not is_instance_valid(_button):
		return
	if not ResourceLoader.exists(MIC_ON_ICON):
		_button.text = _text("按住说话", "Hold to talk")
		_button.icon = null
		return
	_button.text = ""
	_button.icon = load(MIC_ON_ICON)
	# 图标居中放大：默认图标跟着字体大小走，96px 的素材会缩成一小点。
	_button.expand_icon = true
	_button.add_theme_constant_override("icon_max_width", 28)
	# 🔴 居中三件套（2026-10-14 用户截图反馈「麦克风不在框里居中」）：
	#   Godot 的 Button 默认把图标与文字横排左对齐，且垂直也是 TOP —— 按钮被拉宽到
	#   ICON_BUTTON_SIZE(132) 之后，图标就贴在左上角，右边和下面留一大片空白。
	#   文字已经清空（_button.text = ""），所以这三行只管图标。
	_button.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_button.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER


func _on_down() -> void:
	if _busy or _disabled:
		return
	_cancelled = false
	var reason := VoiceClipService.start_recording()
	if not reason.is_empty():
		failed.emit(reason)
		return
	if not VoiceClipService.is_recording():
		return
	_held = true
	recording_started.emit()
	_show_actions()
	_gesture_origin = _ios_touch_origin if SafeArea.uses_ios_layout() and _ios_touch_index >= 0 else _button.get_global_mouse_position()


func _show_actions() -> void:
	if _overlay == null:
		_overlay = CanvasLayer.new()
		_overlay.layer = 80
		add_child(_overlay)
		var col := VBoxContainer.new()
		col.name = "RecordingActions"
		col.theme = Kit.theme()
		_overlay.add_child(col)
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_timer = Label.new()
		_timer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_timer.add_theme_color_override("font_color", Color("493018"))
		col.add_child(_timer)
		_actions = HBoxContainer.new()
		_actions.add_theme_constant_override("separation", 22)
		_actions.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(_actions)
		for title in [_text("↖ 取消", "↖ Cancel"), _text("转文字 ↗", "To Text ↗")]:
			# A plain wrapper preserves the tilt when HBoxContainer sorts its children.
			var wing := Control.new()
			wing.custom_minimum_size = Vector2(164, 56)
			wing.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_actions.add_child(wing)
			var action := ACTION_BUTTON.instantiate() as Button
			action.text = title
			action.custom_minimum_size = Vector2(164, 56)
			action.add_theme_font_size_override("font_size", 18)
			action.mouse_filter = Control.MOUSE_FILTER_IGNORE
			action.focus_mode = Control.FOCUS_NONE
			wing.add_child(action)
			action.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_cancel_action = _actions.get_child(0).get_child(0)
		_text_action = _actions.get_child(1).get_child(0)
	var col := _overlay.get_child(0) as Control
	var mic := _button.get_global_rect()
	col.position = Vector2(clampf(mic.get_center().x - 175, 12,
		get_viewport_rect().size.x - 362), maxf(12, mic.position.y - 124))
	_gesture_origin = mic.get_center()
	_selected_action = "send"
	_seconds = 0.0
	_overlay.show()
	_style_action(_cancel_action, false, true)
	_style_action(_text_action, false, false)
	_update_recording_caption()
	_tilt_actions.call_deferred()


func _tilt_actions() -> void:
	if not is_instance_valid(_cancel_action):
		return
	_cancel_action.pivot_offset = _cancel_action.size * 0.5
	_text_action.pivot_offset = _text_action.size * 0.5
	_cancel_action.rotation = -0.09
	_text_action.rotation = 0.09


func _style_action(action: Button, selected: bool, cancel: bool) -> void:
	var fill := Color("edd5a7")
	if selected:
		fill = Color("dca88c") if cancel else Color("bdcb96")
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = Color("af7836") if not selected else Color("7e512a")
	style.set_border_width_all(2)
	style.set_corner_radius_all(28)
	style.set_content_margin_all(12)
	style.shadow_color = Color(0.20, 0.12, 0.04, 0.25)
	style.shadow_size = 5 if selected else 3
	for state in ["normal", "hover", "pressed", "focus"]:
		action.add_theme_stylebox_override(state, style)
	action.add_theme_color_override("font_color", Color("493018"))
	action.add_theme_color_override("font_outline_color", Color.TRANSPARENT)
	action.add_theme_constant_override("outline_size", 0)


# Direction and distance from the initial press, independent of the visual chips.
func _gesture_choice(point: Vector2) -> String:
	var delta := point - _gesture_origin
	if delta.y > GESTURE_DISTANCE * 1.5:
		return "cancel"
	if delta.x <= -GESTURE_DISTANCE:
		return "cancel"
	if delta.x >= GESTURE_DISTANCE:
		return "text"
	if delta.y <= -GESTURE_DISTANCE:
		return "text" if delta.x > 16 else "cancel"
	return "send"


func _update_recording_caption() -> void:
	var caption := _text("松开发送", "Release to send")
	if _selected_action == "cancel":
		caption = _text("松开取消", "Release to cancel")
	elif _selected_action == "text":
		caption = _text("松开转文字", "Release for text")
	_timer.text = "%d″ · %s" % [int(_seconds), caption]


func _input(event: InputEvent) -> void:
	if SafeArea.uses_ios_layout() and _handle_ios_input(event):
		return
	if not _held:
		return
	if event is InputEventMouseMotion or event is InputEventScreenDrag:
		_highlight_action(event.position)
	elif event is InputEventScreenTouch and not event.pressed:
		_release(event.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_release(event.position)


# 真实 iOS 触摸只由开始录音的手指结束；模拟鼠标和其他手指不能代替它提交。
# 用同一处理函数接受门禁输入，不伪造 OS，也不调用录音/上传服务来测试分发。
func _handle_ios_input(event: InputEvent) -> bool:
	if event is InputEventScreenTouch:
		if event.pressed:
			if not _held and is_instance_valid(_button) and not _button.disabled and is_visible_in_tree() and _button.get_global_rect().has_point(event.position):
				_ios_touch_index = event.index
				_ios_touch_origin = event.position
			return true
		if event.index != _ios_touch_index:
			return true
		if event.canceled:
			_cancel_ios_gesture()
		else:
			if _held:
				_release(event.position)
			_ios_touch_index = -1
		return true
	if event is InputEventScreenDrag:
		if _held and event.index == _ios_touch_index:
			_highlight_action(event.position)
		return true
	if _ios_touch_index >= 0 and (event is InputEventMouseButton or event is InputEventMouseMotion):
		return true
	return false


func _cancel_ios_gesture() -> void:
	_ios_touch_index = -1
	if not _held:
		return
	_held = false
	_cancelled = true
	VoiceClipService.cancel_recording()
	if _overlay != null:
		_overlay.hide()


func _notification(what: int) -> void:
	if SafeArea.uses_ios_layout() and what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_cancel_ios_gesture()
		return
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and _held:
		_held = false
		_cancelled = true
		VoiceClipService.cancel_recording()
		if _overlay != null:
			_overlay.hide()


func _highlight_action(point: Vector2) -> void:
	_selected_action = _gesture_choice(point)
	_style_action(_cancel_action, _selected_action == "cancel", true)
	_style_action(_text_action, _selected_action == "text", false)
	_update_recording_caption()


func _on_up() -> void:
	if SafeArea.uses_ios_layout() and _ios_touch_index >= 0:
		return
	if _held:
		_release(_button.get_global_mouse_position())


func _release(point: Vector2) -> void:
	if not _held or _busy:
		return
	_held = false
	var choice := _gesture_choice(point)
	var to_text := choice == "text"
	_cancelled = choice == "cancel"
	_overlay.hide()
	if _cancelled:
		VoiceClipService.cancel_recording()
		return
	_busy = true
	_button.disabled = true
	if to_text:
		_timer.text = _text("识别中…", "Recognizing…")
		_overlay.show()
		_actions.hide()
		var result: Dictionary = await VoiceClipService.finish_and_transcribe()
		if not is_inside_tree():
			return
		_overlay.hide()
		_actions.show()
		_busy = false
		_button.disabled = _disabled
		if bool(result.get("ok", false)):
			text_ready.emit(str(result.get("text", "")))
		else:
			failed.emit(_recognition_error(str(result.get("error", ""))))
		return
	var clip: Dictionary = await VoiceClipService.finish_and_upload(_scope)
	if not is_inside_tree():
		return
	_busy = false
	_button.disabled = _disabled
	if bool(clip.get("ok", false)):
		clip_ready.emit(clip)
	else:
		failed.emit(str(clip.get("error", _text("语音发送失败", "Voice message failed"))))


func _on_tick(seconds: float, _level: float) -> void:
	if _held and _timer != null:
		_seconds = seconds
		_update_recording_caption()


func _recognition_error(code: String) -> String:
	match code:
		"windows_model_missing":
			return _text("本地语音识别组件不完整，请修复或重新安装游戏。", "Local speech files are missing. Repair or reinstall the game.")
		"no_speech":
			return _text("没有识别到语音，请按住麦克风重新说一次。", "No speech detected. Hold the microphone and try again.")
		"timeout":
			return _text("识别超时，请缩短录音后重试。", "Recognition timed out. Try a shorter recording.")
		"android_13_required":
			return _text("录音转文字需要 Android 13 或更高版本。", "Recorded speech recognition requires Android 13 or later.")
		"unavailable", "plugin_update_required":
			return _text("当前版本暂不支持转文字，请使用包含新版手机语音插件的安装包。", "Speech-to-text requires the updated mobile voice plugin.")
		"permission_denied":
			return _text("请在系统设置中允许语音识别。", "Allow speech recognition in system settings.")
		"too_short":
			return _text("说得太短了，按住多说一会儿。", "Hold and speak a little longer.")
	return _text("未能识别，请检查系统语音识别服务及语言包后重试。", "Recognition failed. Check system speech services and language packs, then retry.")


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
