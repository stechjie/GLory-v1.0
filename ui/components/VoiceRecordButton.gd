extends HBoxContainer

# 「按住说话」按钮（docs/聊天系统设计.md「语音消息」，2026-10-11）。
#
# 按下去开始录，松开就发。三个渠道（私聊、世界频道、房间与对局内）共用这一个，
# 区别只在 scope ——它决定服务器怎么记保留期，也决定这段语音能发到哪儿去。
#
# 录到 30 秒会自己停，但**不自动发**：让玩家看一眼再松手决定（同微信）。
# 松手时如果已经停了，照样发出去；想丢掉就把手指拖开再松（_cancelled）。

signal clip_ready(clip: Dictionary)     # 上传成功：{"clip_id", "media", "seconds"}
signal failed(message: String)          # 给调用方弹提示（太短、通话中、配额用完…）

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")

var _scope := VoiceClipService.SCOPE_PRIVATE
var _button: Button = null
var _hint: Label = null
var _busy := false
var _cancelled := false


static func create(scope: String) -> Control:
	var bar := new()
	bar._scope = scope
	return bar


func _ready() -> void:
	add_theme_constant_override("separation", Tokens.GAP_S)
	_button = ACTION_BUTTON.instantiate() as Button
	_button.text = _text("按住说话", "Hold to talk")
	_button.custom_minimum_size = Vector2(132, Tokens.TOUCH_MIN)
	_button.button_down.connect(_on_down)
	_button.button_up.connect(_on_up)
	add_child(_button)

	_hint = Label.new()
	_hint.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	_hint.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_hint)

	if not VoiceClipService.recording_tick.is_connected(_on_tick):
		VoiceClipService.recording_tick.connect(_on_tick)


func _exit_tree() -> void:
	if VoiceClipService.recording_tick.is_connected(_on_tick):
		VoiceClipService.recording_tick.disconnect(_on_tick)
	# 界面被关掉时手还按着：丢掉这次录音，别让麦克风留在开着的状态。
	if VoiceClipService.is_recording():
		VoiceClipService.cancel_recording()


func set_disabled(value: bool) -> void:
	if _button != null and is_instance_valid(_button):
		_button.disabled = value or _busy


func _on_down() -> void:
	if _busy:
		return
	_cancelled = false
	var reason := VoiceClipService.start_recording()
	if not reason.is_empty():
		_hint.text = ""
		failed.emit(reason)
		return
	_hint.text = _text("0″ 松开发送", "0″ release to send")


func _on_up() -> void:
	if _busy:
		return
	if not VoiceClipService.is_recording() and VoiceClipService.recorded_seconds() <= 0.0:
		# 录都没开起来（上面那条 failed 已经说过原因了）。
		return
	# 手指拖出按钮再松 = 不发。Godot 的 button_up 在按钮外也会来，所以这里自己判。
	_cancelled = not _button.get_global_rect().has_point(_button.get_global_mouse_position())
	if _cancelled:
		VoiceClipService.cancel_recording()
		_hint.text = _text("已取消", "Cancelled")
		return
	_busy = true
	set_disabled(true)
	_hint.text = _text("发送中…", "Sending…")
	var clip: Dictionary = await VoiceClipService.finish_and_upload(_scope)
	_busy = false
	set_disabled(false)
	if not is_inside_tree():
		return
	if bool(clip.get("ok", false)):
		_hint.text = ""
		clip_ready.emit(clip)
	else:
		_hint.text = ""
		failed.emit(str(clip.get("error", _text("语音发送失败", "Voice message failed"))))


func _on_tick(seconds: float, _level: float) -> void:
	if _busy or _cancelled or _hint == null or not is_instance_valid(_hint):
		return
	if seconds >= VoiceClipService.MAX_SECONDS:
		_hint.text = _text("%d″ 已到上限，松开发送" % int(VoiceClipService.MAX_SECONDS),
			"%d″ limit reached, release to send" % int(VoiceClipService.MAX_SECONDS))
		return
	_hint.text = _text("%d″ 松开发送" % int(seconds), "%d″ release to send" % int(seconds))


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
