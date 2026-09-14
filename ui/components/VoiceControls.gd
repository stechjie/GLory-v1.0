extends RefCounted

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
# make_menu_button 的默认字色（PrepWidgets）。
const IDLE_COLOR := Color(1.0, 0.90, 0.60)
const REFRESH_SEC := 0.25
const RATIONALE_REQUEST_ID := "voice_mic_rationale"

var voice_button: Button = null
var members_button: Button = null
var _owner: Node = null
var _timer: Timer = null
# 这一份发起了系统权限请求、还在等结果。同时开着几份时（备战期 + 战斗界面），只由发起的那份提示。
var _awaiting_mic := false


func build(owner: Node, voice_size: Vector2, members_size: Vector2, font_size: int) -> void:
	_owner = owner
	voice_button = PrepWidgets.make_menu_button(VoiceService.mode_label(), voice_size, font_size, _on_voice_pressed)
	voice_button.name = "VoiceToggle"
	members_button = PrepWidgets.make_menu_button(_text("队友", "Team"), members_size, font_size, _on_members_pressed)
	members_button.name = "VoiceMembers"
	if not VoiceService.mode_changed.is_connected(_on_mode_changed):
		VoiceService.mode_changed.connect(_on_mode_changed)
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
	voice_button.text = VoiceService.mode_label()
	voice_button.add_theme_color_override("font_color", ACTIVE_COLOR if VoiceService.is_active() else IDLE_COLOR)


# 开麦的唯一入口（语音按钮和语音面板里的「开麦」都走这里）：没权限时先说明用途。
func request_talk() -> void:
	if VoiceService.needs_mic_rationale():
		DialogService.confirm({
			"request_id": RATIONALE_REQUEST_ID,
			"owner": _owner,
			"title": _text("开麦需要麦克风权限", "Microphone permission"),
			"body": _text(
				"语音只在你开麦时使用麦克风。声音只实时发给同队队友，不录音、不保存。\n下一步系统会问你是否允许。",
				"Voice uses the microphone only while your mic is on. Your voice goes live to your teammates only and is never recorded or stored.\nAndroid will ask for permission next."),
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
	if VoiceService.mode == VoiceService.Mode.LISTEN:
		request_talk()
		return
	_apply_result(VoiceService.cycle_mode())


func _on_members_pressed() -> void:
	VoicePanel.new().present(_owner, request_talk)


func _on_mode_changed(_mode: int) -> void:
	refresh()


func _apply_result(reason: String) -> void:
	if not reason.is_empty():
		DialogService.info({"owner": _owner, "body": reason})
	refresh()


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
