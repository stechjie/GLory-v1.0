extends RefCounted

const SfxService := preload("res://ui/services/SfxService.gd")

# 语音按钮 + 队友按钮（docs/聊天系统设计.md 第九节 v1.1）。大厅、备战期、战斗界面共用。
#
# 语音按钮：点一下切一档（关 → 只听 → 开麦 → 关）。从「只听」切「开麦」时如果还没有麦克风权限，
# 先弹一句用途说明，玩家点「去开启」才请求系统权限 —— 直接甩一个系统弹窗，玩家不知道为什么要麦克风；
# Google Play 对麦克风这类敏感权限也要求用途在应用里说清楚。
# 队友按钮：打开 VoicePanel（同队成员、谁在说话、屏蔽、当前编码与输出设备）。
# 有没屏蔽的队友在说话、或自己开着麦正在说时，语音按钮的字变绿。
#
# 调用方负责摆放（大厅走 _track、备战期与战斗界面走锚点），并**必须在离开时调 teardown()**：
# VoiceService 是 autoload，活得比界面久，信号不断开会一直指向已经释放的界面。
# 按钮用 PrepWidgets.make_menu_button，不写 Button.new()（V3 P1-08 棘轮）。

const PrepWidgets := preload("res://scenes/prep/PrepWidgets.gd")
const VoicePanel := preload("res://ui/components/VoicePanel.gd")
const ConfirmDialog := preload("res://ui/components/GloryConfirmDialog.gd")

const ACTIVE_COLOR := Color(0.55, 1.0, 0.55)
const LISTEN_COLOR := Color(0.50, 0.88, 1.0)
# make_menu_button 的默认字色（PrepWidgets）。
const IDLE_COLOR := Color(1.0, 0.90, 0.60)
const REFRESH_SEC := 0.25
const RATIONALE_REQUEST_ID := "voice_mic_rationale"

var voice_button: Button = null
var audience_button: Button = null
var members_button: Button = null
var _owner: Node = null
var _timer: Timer = null
var _panel_context := ""
# 这一份发起了系统权限请求、还在等结果。同时开着几份时（备战期 + 战斗界面），只由发起的那份提示。
var _awaiting_mic := false
var _speaker_hold_started := -1
var _speaker_hold_opened := false


func build(owner: Node, voice_size: Vector2, members_size: Vector2, font_size: int,
		options: Dictionary = {}) -> void:
	_owner = owner
	_panel_context = str(options.get("panel_context", ""))
	voice_button = PrepWidgets.make_menu_button(VoiceService.mode_label(), voice_size, font_size, _on_voice_pressed)
	voice_button.name = "VoiceToggle"
	audience_button = PrepWidgets.make_menu_button("", members_size, font_size, _on_speaker_pressed)
	audience_button.name = "VoiceAudience"
	audience_button.button_down.connect(func():
		_speaker_hold_started = Time.get_ticks_msec()
		_speaker_hold_opened = false)
	audience_button.button_up.connect(func(): _speaker_hold_started = -1)
	members_button = PrepWidgets.make_menu_button(_text("队友", "Team"), members_size, font_size, _on_audience_pressed)
	members_button.name = "VoiceMembers"
	# 三个按钮统一使用紧凑内边距，避免双行文字把实际高度撑到布局尺寸之外。
	for button in [voice_button, audience_button, members_button]:
		var style := PrepWidgets.menu_button_style()
		style.content_margin_top = 3.0
		style.content_margin_bottom = 3.0
		style.content_margin_left = 4.0
		style.content_margin_right = 4.0
		for state in ["normal", "hover", "pressed"]:
			button.add_theme_stylebox_override(state, style)

	if not VoiceService.mode_changed.is_connected(_on_mode_changed):
		VoiceService.mode_changed.connect(_on_mode_changed)
	if not VoiceService.audience_changed.is_connected(_on_audience_changed):
		VoiceService.audience_changed.connect(_on_audience_changed)
	if not VoiceService.mutes_changed.is_connected(refresh):
		VoiceService.mutes_changed.connect(refresh)
	if not VoiceService.mic_permission_result.is_connected(_on_mic_permission_result):
		VoiceService.mic_permission_result.connect(_on_mic_permission_result)
	_timer = Timer.new()
	_timer.wait_time = REFRESH_SEC
	_timer.autostart = true
	_timer.timeout.connect(refresh)
	owner.add_child(_timer)
	refresh()


func teardown() -> void:
	if VoiceService.mode_changed.is_connected(_on_mode_changed):
		VoiceService.mode_changed.disconnect(_on_mode_changed)
	if VoiceService.audience_changed.is_connected(_on_audience_changed):
		VoiceService.audience_changed.disconnect(_on_audience_changed)
	if VoiceService.mutes_changed.is_connected(refresh):
		VoiceService.mutes_changed.disconnect(refresh)
	if VoiceService.mic_permission_result.is_connected(_on_mic_permission_result):
		VoiceService.mic_permission_result.disconnect(_on_mic_permission_result)
	_awaiting_mic = false
	if _timer != null and is_instance_valid(_timer):
		_timer.stop()


func refresh() -> void:
	if voice_button == null or not is_instance_valid(voice_button):
		return
	if _speaker_hold_started >= 0 and not _speaker_hold_opened and Time.get_ticks_msec() - _speaker_hold_started >= 700:
		_speaker_hold_opened = true
		_on_members_pressed()
	voice_button.text = ""
	audience_button.text = ""
	_set_icon(voice_button, "mic_on" if VoiceService.mode == VoiceService.Mode.TALK else "mic_off")
	_set_icon(audience_button, "speaker_on" if VoiceService.speaker_enabled else "speaker_off")
	voice_button.tooltip_text = _text("关闭麦克风" if VoiceService.mode == VoiceService.Mode.TALK else "打开麦克风", "Toggle microphone")
	audience_button.tooltip_text = _text("关闭扬声器" if VoiceService.speaker_enabled else "打开扬声器", "Toggle speaker")
	audience_button.tooltip_text += _text("\n长按查看语音状态", "\nHold for voice status")
	if not VoiceService.last_error().is_empty():
		voice_button.tooltip_text += "\n" + VoiceService.last_error()
		audience_button.tooltip_text += "\n" + VoiceService.last_error()
	if VoiceService.lobby_open_to_room():
		members_button.text = _text("全房间", "Room")
	else:
		members_button.text = _text("所有人", "All") if VoiceService.audience == VoiceService.Audience.ALL else _text("队友", "Team")
	members_button.add_theme_color_override("font_color", ACTIVE_COLOR if VoiceService.open_to_room() else IDLE_COLOR)

func _set_icon(button: Button, key: String) -> void:
	var art := button.get_node_or_null("VoiceIcon") as TextureRect
	if art == null:
		art = TextureRect.new()
		art.name = "VoiceIcon"
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		button.add_child(art)
		art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		art.offset_left = 8
		art.offset_right = -8
		art.offset_top = 5
		art.offset_bottom = -5
	var path := "res://assets/ui/voice/%s.svg" % key
	if art.get_meta("voice_icon", "") != key:
		art.texture = load(path)
		art.set_meta("voice_icon", key)

func _on_speaker_pressed() -> void:
	if _speaker_hold_opened:
		_speaker_hold_opened = false
		return
	_apply_result(VoiceService.set_speaker_enabled(not VoiceService.speaker_enabled))


# 开麦的唯一入口（语音按钮和语音面板里的「开麦」都走这里）：没权限时先说明用途。
func request_talk() -> void:
	if VoiceService.needs_mic_rationale():
		DialogService.confirm({
			"request_id": RATIONALE_REQUEST_ID,
			"owner": _owner,
			"title": _text("开麦需要麦克风权限", "Microphone permission"),
			"body": _text(
				"语音只在你开麦时使用麦克风。自定义房间开局前，房间里所有人都能听到；开局后只传给你选的范围（队友或所有人）。不录音、不保存。\n下一步系统会问你是否允许。",
				"Voice uses the microphone only while your mic is on. Before a custom match starts everyone in the room can hear you; after that only your chosen audience (team or all). Never recorded or stored.\nAndroid will ask for permission next."),
			"confirm_text": _text("去开启", "Continue"),
			"cancel_text": _text("先不用", "Not now"),
			"on_result": _on_rationale_result,
		})
		return
	_apply_result(VoiceService.set_mode(VoiceService.Mode.TALK))


func _on_rationale_result(result: String, _request_id: String) -> void:
	if result != ConfirmDialog.RESULT_CONFIRMED:
		return
	_awaiting_mic = true
	var reason := VoiceService.set_mode(VoiceService.Mode.TALK)
	if not reason.is_empty():
		_awaiting_mic = false
	_apply_result(reason)


# 系统权限弹窗的结果。被拒时必须说点什么：安卓 11 起拒绝两次系统就不再弹窗，
# 之后点「开麦」→「去开启」会瞬间被拒，玩家看到的是按了没反应。
func _on_mic_permission_result(granted: bool) -> void:
	if not _awaiting_mic:
		return
	_awaiting_mic = false
	refresh()
	if granted or _owner == null or not is_instance_valid(_owner):
		return
	DialogService.info({"owner": _owner, "body": _text(
		"没有拿到麦克风权限，现在是「只听」。\n如果点「开麦」不再弹出系统窗口，请到手机的 设置 → 应用 → 本游戏 → 权限 里允许麦克风。",
		"Microphone permission was not granted, so voice stays on listen-only.\nIf Android no longer asks, allow the microphone in Settings → Apps → this game → Permissions.")})


func _on_voice_pressed() -> void:
	if VoiceService.mode == VoiceService.Mode.TALK:
		_apply_result(VoiceService.set_microphone_enabled(false))
	else:
		request_talk()


func _on_members_pressed() -> void:
	VoicePanel.new().present(_owner, request_talk, {"context": _panel_context})


func _on_audience_pressed() -> void:
	SfxService.play(SfxService.CUE_VOICE_SWITCH)
	if VoiceService.lobby_open_to_room():
		# 开局前全房间互通，这时没有可选的：说清楚规则，不偷偷改一个开局后才生效的设置。
		DialogService.info({"owner": _owner, "body": _text(
			"开局前，房间里所有人都能互相听到。\n开局后默认只对队友说话，可以在对局里切到「所有人」。",
			"Before the match starts, everyone in the room can hear each other.\nAfter it starts you talk to your team by default; switch to All during the match.")})
		return
	VoiceService.toggle_audience()
	refresh()


func _on_audience_changed(_audience: int) -> void:
	refresh()


func _on_mode_changed(_mode: int) -> void:
	refresh()


func _apply_result(reason: String) -> void:
	if not reason.is_empty():
		DialogService.info({"owner": _owner, "body": reason})
	refresh()


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh


# --- 「谁在说话」的小麦克风 ---------------------------------------------------------------
#
# 10-08 用户要求：所有用到语音的地方，正在说话的人头像上要有个小麦克风，让人知道是谁在说。
# 组队房、自定义房间座位、摆放界面的头像排都用这两个函数；战斗界面没有头像，单独列名字。
# 图标用运行时 load()，不 preload：战斗服务器包不带导入过的贴图（服务器会冷启动失败）。

const SPEAKING_NODE := "SpeakingMic"
const SPEAKING_BG := Color(0.06, 0.12, 0.10, 0.92)


# 在头像右下角挂一个（已经挂过就直接返回那一个）。fraction = 标记占头像边长的比例。
# 全用锚点、不用像素：大厅的头像会随窗口缩放（_track），标记要跟着一起缩。头像都是正方形。
static func attach_speaking_mic(avatar: Control, fraction: float = 0.36) -> Control:
	var existing := avatar.get_node_or_null(SPEAKING_NODE) as Control
	if existing != null:
		return existing
	var badge := Panel.new()
	badge.name = SPEAKING_NODE
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 拿现成的菜单按钮样式改色，不另写 StyleBoxFlat.new()（procedural_ui_ratchet 只许降不许升）。
	var style := PrepWidgets.menu_button_style()
	style.bg_color = SPEAKING_BG
	style.border_color = ACTIVE_COLOR
	style.set_border_width_all(2)
	style.set_corner_radius_all(999)
	badge.add_theme_stylebox_override("panel", style)
	_anchor_inside(badge, 1.0 - fraction, 1.0)
	var icon := TextureRect.new()
	icon.texture = load("res://assets/ui/voice/mic_on.svg")
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor_inside(icon, 0.16, 0.84)
	badge.add_child(icon)
	badge.visible = false
	avatar.add_child(badge)
	return badge


static func _anchor_inside(node: Control, start: float, end: float) -> void:
	node.anchor_left = start
	node.anchor_top = start
	node.anchor_right = end
	node.anchor_bottom = end
	node.offset_left = 0
	node.offset_top = 0
	node.offset_right = 0
	node.offset_bottom = 0


static func show_speaking_mic(avatar: Control, speaking: bool) -> void:
	if avatar == null or not is_instance_valid(avatar):
		return
	var badge := avatar.get_node_or_null(SPEAKING_NODE) as Control
	if badge != null:
		badge.visible = speaking
