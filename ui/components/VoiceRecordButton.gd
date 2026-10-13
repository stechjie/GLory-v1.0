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
	add_theme_constant_override("separation", Tokens.GAP_S)
	# 容器居中：这个 HBox 里是「麦克风按钮 + 计时提示」两颗。计时提示平时是空的，
	# 一旦它出现/消失，如果不给容器定住对齐方式，按钮会跟着横向抖动、贴左。
	# 定成 CENTER 后按钮位置稳定，图标也始终落在按钮正中（2026-10-14 用户截图反馈）。
	alignment = BoxContainer.ALIGNMENT_CENTER
	_button = ACTION_BUTTON.instantiate() as Button
	# 图标为主：这是三个渠道（私聊 / 世界 / 对局内）共用的同一颗按钮，画成麦克风
	# 一眼就知道是「说话」而不是「发送」——旁边那颗「发送」是字，两颗形状不同才分得开。
	_apply_mic_icon()
	# 按住说话这句当 tooltip 留着：图标省地方，但第一次玩的人得知道是「按住」不是「点一下」。
	_button.tooltip_text = _text("按住说话", "Hold to talk")
	_button.custom_minimum_size = Vector2(ICON_BUTTON_SIZE, Tokens.TOUCH_MIN)
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
	# 权限被拒（移动端）：界面上说清楚「去系统设置里开麦克风」，
	# 不然玩家对着按下去没反应的按钮只会以为功能坏了（2026-10-14）。
	if not VoiceClipService.permission_denied.is_connected(_on_permission_denied):
		VoiceClipService.permission_denied.connect(_on_permission_denied)


func _exit_tree() -> void:
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
	_button.add_theme_constant_override("icon_max_width", 40)
	# 🔴 居中三件套（2026-10-14 用户截图反馈「麦克风不在框里居中」）：
	#   Godot 的 Button 默认把图标与文字横排左对齐，且垂直也是 TOP —— 按钮被拉宽到
	#   ICON_BUTTON_SIZE(132) 之后，图标就贴在左上角，右边和下面留一大片空白。
	#   文字已经清空（_button.text = ""），所以这三行只管图标。
	_button.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_button.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER


func _on_down() -> void:
	if _busy:
		return
	_cancelled = false
	var reason := VoiceClipService.start_recording()
	if not reason.is_empty():
		_hint.text = ""
		failed.emit(reason)
		return
	# 移动端首次录音会先弹系统权限框（2026-10-14）。这时麦克风还没开，
	# 别显示「0″ 松开发送」——玩家会以为已经在录了。等权限回来会自动补开。
	if VoiceClipService.is_awaiting_permission():
		_hint.text = _text("正在请求麦克风权限…", "Requesting microphone…")
		return
	_hint.text = _text("0″ 松开发送", "0″ release to send")


func _on_up() -> void:
	if _busy:
		return
	# 权限框还开着：玩家松手了（多半是慌了）。权限回调会把这次录音补上，
	# 这里不要当成「录都没开起来」直接吞掉，也不要走到 finish_and_upload
	# （那会拿到「没有在录音」的错误）。授权回来如果成了，照常开始录；
	# 玩家不想录了就直接拖开松手取消 —— 由 _cancelled 分支处理。
	if VoiceClipService.is_awaiting_permission():
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
