extends Node

# Pre-match voice owns one LiveKit room per party membership revision.
# That room has no opponent seats and never exposes an audience switch.

signal state_changed(label: String)

enum Mode { OFF, LISTEN, TALK }

var mode := Mode.OFF
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
		mode = Mode.LISTEN
	if mode != Mode.OFF:
		_join()
	_emit_label()


func cycle() -> String:
	if not _has_bridge_method("joinRoom"):
		return "当前设备没有可用的语音组件"
	var next := (mode + 1) % 3
	if next == Mode.TALK and not bool(_bridge.call("hasRecordPermission")):
		if _has_bridge_method("requestRecordPermission"):
			_bridge.call("requestRecordPermission")
		else:
			OS.request_permission("android.permission.RECORD_AUDIO")
		return "请允许麦克风权限后再点一次开麦"
	mode = next
	_last_error = ""
	if mode == Mode.OFF:
		_leave_bridge()
	elif mode == Mode.LISTEN:
		_leave_bridge()
		_join()
	else:
		# Android fixes its audio mode at join time; reconnect for microphone mode.
		_leave_bridge()
		_join()
	_emit_label()
	return ""


func stop() -> void:
	mode = Mode.OFF
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
	if mode == Mode.TALK:
		var mic_error := str(_bridge.call("setMicrophoneEnabled", true))
		if not mic_error.is_empty():
			mode = Mode.LISTEN
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
