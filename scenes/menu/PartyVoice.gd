extends Node

# Pre-match voice owns one LiveKit room per party membership revision.
# That room has no opponent seats and never exposes an audience switch.
#
# ★ 10.07 bug 文档第 9 条：房间语音 UI 从「一个循环切换的文字按钮」
#   改成「麦克风 + 扬声器两个图标按钮」（房间里只有队友，不需要「队友/所有人」
#   这个听众选择 —— 那是大厅/备战那套 VoiceControls 才有的第三个按钮）。
#   于是本脚本把原来「一个 cycle() 走 关→听→麦」的隐式状态拆成两个显式开关：
#     mic_enabled      —— 是否开麦（false = 只听）
#     speaker_enabled  —— 是否放声音（false = 完全静音，等价旧的 Mode.OFF）
#   `mode` 仍保留，作为「给 bridge 看的合成态」由上面两个开关推导，避免
#   改动 _join()/_emit_label() 里那套已有逻辑。

signal state_changed(label: String)

enum Mode { OFF, LISTEN, TALK }

var mode := Mode.OFF
var mic_enabled := false
var speaker_enabled := false
var _bridge: Object = null
var _party_id := ""
var _epoch := ""
var _connected := false
var _request_serial := 0
var _retry_elapsed := 0.0
var _last_error := ""


func _ready() -> void:
	if Engine.has_singleton("GloryVoice"):
		_bridge = Engine.get_singleton("GloryVoice")


func _exit_tree() -> void:
	stop()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_request_serial += 1
		_leave_bridge()
	elif what == NOTIFICATION_APPLICATION_RESUMED and mode != Mode.OFF:
		_join()


func _has_bridge_method(method: StringName) -> bool:
	if _bridge == null:
		return false
	if _bridge.has_method("has_java_method"):
		return bool(_bridge.call("has_java_method", method))
	return _bridge.has_method(method)


func configure(room: Dictionary) -> void:
	var next_id := str(room.get("id", ""))
	var next_epoch := str(room.get("voice_epoch", ""))
	if next_id == _party_id and next_epoch == _epoch:
		return
	_leave_bridge()
	_party_id = next_id
	_epoch = next_epoch
	_request_serial += 1
	if mode == Mode.OFF and _party_id != "":
		# 进房间默认「只听」：麦克风关、扬声器开。
		speaker_enabled = true
		_sync_mode()
	if mode != Mode.OFF:
		_join()
	_emit_label()


# 由两个显式开关推导 bridge 要的合成态。麦克风优先：开麦即 TALK；
# 否则扬言器开就 LISTEN，两者都关就 OFF（leaveRoom）。
func _sync_mode() -> void:
	var next := Mode.OFF
	if mic_enabled:
		next = Mode.TALK
	elif speaker_enabled:
		next = Mode.LISTEN
	if next == mode:
		return
	mode = next
	_last_error = ""
	if mode == Mode.OFF:
		_leave_bridge()
	else:
		# Android 在 join 时就定下音频模式，切换麦克风态要重连。
		_leave_bridge()
		_join()
	_emit_label()


# 麦克风开/关。开麦前没有录音权限时，向系统请求并返回一句提示，
# 让界面告诉玩家「允许后再点一次」。
#
# ★★ 10.07 第 9 条返工（用户真机反馈）：**麦克风与扬声器彻底解耦**。
#   旧实现有三处互锁，症状是「开麦必须先开扬声器」「按一下切不动、要按两下」：
#     ① 这里 `if enabled: speaker_enabled = true` —— 开麦强行把扬声器也打开；
#     ② set_speaker_enabled(false) 里把 mic_enabled 一起关掉；
#     ③ PartyLobby._refresh_voice_icons 里 `_voice_mic.disabled = not speaker_on`
#        —— 扬声器关着时麦克风按钮直接禁用，点都点不动（「要扬声器打开才能开麦」）。
#   现在两个开关各管各的：开麦就只是开麦（听不见也不影响别人听你），
#   关扬声器就只是静音（你自己还能说）。合成态 Mode 仍由两者推导，
#   但**唯一改变 Mode 的地方**是下面 _sync_mode()，开关本身不再互相赋值。
func set_mic_enabled(enabled: bool) -> String:
	if not _has_bridge_method("joinRoom"):
		return "当前设备没有可用的语音组件"
	if enabled and not bool(_bridge.call("hasRecordPermission")):
		if _has_bridge_method("requestRecordPermission"):
			_bridge.call("requestRecordPermission")
		else:
			OS.request_permission("android.permission.RECORD_AUDIO")
		return "请允许麦克风权限后再点一次开麦"
	mic_enabled = enabled
	_sync_mode()
	return ""


func set_speaker_enabled(enabled: bool) -> String:
	speaker_enabled = enabled
	_sync_mode()
	return ""


func stop() -> void:
	mode = Mode.OFF
	mic_enabled = false
	speaker_enabled = false
	_party_id = ""
	_epoch = ""
	_request_serial += 1
	_leave_bridge()
	_emit_label()


func _join() -> void:
	if mode == Mode.OFF or _party_id == "":
		return
	if not _has_bridge_method("joinRoom"):
		_last_error = "当前设备没有可用的语音组件"
		_emit_label()
		return
	_request_serial += 1
	var serial := _request_serial
	var expected_room := _party_id
	var expected_epoch := _epoch
	var result: Dictionary = await AccountManager.fetch_party_voice_token()
	if not is_inside_tree() or serial != _request_serial or expected_room != _party_id \
			or expected_epoch != _epoch or mode == Mode.OFF:
		return
	if int(result.get("code", 0)) != 200:
		_last_error = str(result.get("error", "队伍语音暂不可用"))
		if int(result.get("code", 0)) == 503:
			mode = Mode.OFF
		_retry_elapsed = 0.0
		_emit_label()
		return
	var body: Dictionary = result.get("body", {})
	var error := str(_bridge.call("joinRoom", str(body.get("url", "")),
		str(body.get("token", "")), mode == Mode.LISTEN))
	if not error.is_empty():
		_last_error = error
		_retry_elapsed = 0.0
		_emit_label()
		return
	_connected = true
	# Every participant in this LiveKit room is a current party member.
	if _has_bridge_method("setAudience"):
		_bridge.call("setAudience", true, "[]")
	if mic_enabled:
		var mic_error := str(_bridge.call("setMicrophoneEnabled", true))
		if not mic_error.is_empty():
			mic_enabled = false
			mode = Mode.LISTEN if speaker_enabled else Mode.OFF
			_last_error = mic_error
			_bridge.call("setMicrophoneEnabled", false)
	_emit_label()


func _leave_bridge() -> void:
	if _connected and _has_bridge_method("leaveRoom"):
		_bridge.call("leaveRoom")
	_connected = false


func _process(delta: float) -> void:
	if mode == Mode.OFF or _party_id == "" or _bridge == null:
		return
	_retry_elapsed += delta
	if _retry_elapsed < 8.0:
		return
	_retry_elapsed = 0.0
	if not _connected:
		_join()
		return
	if not _has_bridge_method("getStatus"):
		return
	var parsed: Variant = JSON.parse_string(str(_bridge.call("getStatus")))
	if parsed is Dictionary and str(parsed.get("state", "")) == "failed":
		_leave_bridge()
		_join()


func _emit_label() -> void:
	var english := LocaleManager.get_locale().begins_with("en")
	if not _last_error.is_empty() and mode == Mode.OFF:
		state_changed.emit("🎙 PARTY VOICE · UNAVAILABLE" if english else "🎙 队内语音 · 不可用")
		return
	var word := ("OFF" if mode == Mode.OFF else ("LISTEN" if mode == Mode.LISTEN else "TALK")) if english else \
		("关闭" if mode == Mode.OFF else ("只听" if mode == Mode.LISTEN else "开麦"))
	state_changed.emit(("🎙 PARTY VOICE · " if english else "🎙 队内语音 · ") + word)
