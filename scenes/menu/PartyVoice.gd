extends Node

# 组队房（休闲 / 排位开局前）的语音：一个队伍一个 LiveKit 房间，钥匙找**账号服务器**要
# （/v1/party/voice-token，backend/app/party_voice.py，身份 = 好友码，10 分钟有效）；
# 成员一变，服务器换房间（voice_epoch）。房间里只有队友，所以麦克风永远对全房间开放，
# 没有「队友 / 所有人」那个选择（那是对局里 VoiceControls 才有的第三个按钮）。
#
# ★ 10.07 第 9 条：两个**互相独立**的开关（界面上两个图标）：
#     mic_enabled      是否开麦（false = 只听）
#     speaker_enabled  是否放声音
#   `mode` 是给桥接看的合成态：开麦 = TALK；没开麦但开着扬声器 = LISTEN；两个都关 = OFF（退出房间）。
#   开着麦、关了扬声器：人还在房间里（别人照样听得到你），只是把每个人的音量设成 0。
#   唯一改 mode 的地方是 _sync_mode()，两个开关之间不互相赋值。
#
# ★ 10-08 返工（用户「排位、休闲房间全是 bug」）：
#   · 钥匙复用：只听 ↔ 开麦要退房再进（安卓的声音模式进房时定），原来每次都重新要钥匙，
#     加上连不上时每 8 秒自动重试，很快撞上账号服务器「每人每分钟 8 把」的限流（429）。
#     现在同一个房间 TOKEN_REUSE_SEC 内拿到的钥匙直接再用。
#   · 失败按 RETRY_SEC 退避重试；服务器说没配语音（503）隔 UNAVAILABLE_RETRY_SEC 再问。
#     原来 503 会偷偷把档位改成关：图标还亮着，实际已经退出，也再不重试。
#   · 出错原因给界面（last_error()），PartyLobby 显示在语音按钮旁边 —— 手机上没有悬停提示。
#   · 关扬声器原来在开着麦时不生效（人还在房间、照样放声音）；现在按人设音量。
#   · 屏蔽某个队友（VoiceService 的屏蔽表，与对局里是同一张）、谁在说话（speaking_codes）。
#   · 成员变动换房间时不再把玩家自己关掉的扬声器重新打开（「进房默认只听」只在进一个新队伍时做一次）。

signal state_changed(label: String)

# 语音音量的裁决处（同 VoiceService）：设置页那条「语音音量」在这里也生效。
const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")

enum Mode { OFF, LISTEN, TALK }

# 钥匙 10 分钟有效，留 2 分钟余量（同 VoiceService.TOKEN_REUSE_SEC）。
const TOKEN_REUSE_SEC := 480.0
# 要不到钥匙 / 连不上时的重试间隔（依次加长，停在最后一个）。账号服务器每人每分钟给 8 把。
const RETRY_SEC := [2.0, 4.0, 8.0, 15.0, 30.0]
# 服务器明说「没配语音」：配好之前问得再勤也没用。
const UNAVAILABLE_RETRY_SEC := 30.0
const STATUS_INTERVAL_SEC := 0.25

var mode := Mode.OFF
var mic_enabled := false
var speaker_enabled := false
var _bridge: Object = null
var _party_id := ""
var _epoch := ""
var _connected := false
var _fetching := false
var _request_serial := 0
var _retry_in := 0.0
var _retry_index := 0
var _last_error := ""
# 最近一次拿到的钥匙：{room: "队伍|epoch", url, token, at_msec}。
var _token_cache: Dictionary = {}
var _status: Dictionary = {}
var _status_at_msec := -100000
# 好友码 -> 最后一次设给桥接的音量（只在变了时才调）
var _applied_volumes: Dictionary = {}


func _ready() -> void:
	if Engine.has_singleton("GloryVoice"):
		_bridge = Engine.get_singleton("GloryVoice")
	if not VoiceService.mutes_changed.is_connected(_on_mutes_changed):
		VoiceService.mutes_changed.connect(_on_mutes_changed)


func _exit_tree() -> void:
	if VoiceService.mutes_changed.is_connected(_on_mutes_changed):
		VoiceService.mutes_changed.disconnect(_on_mutes_changed)
	stop()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_request_serial += 1
		_leave_bridge()
	elif what == NOTIFICATION_APPLICATION_RESUMED and mode != Mode.OFF:
		_retry_in = 0.0
		_retry_index = 0
		_join()


func _has_bridge_method(method: StringName) -> bool:
	if _bridge == null:
		return false
	if _bridge.has_method("has_java_method"):
		return bool(_bridge.has_java_method(method))
	return _bridge.has_method(method)


func configure(room: Dictionary) -> void:
	var next_id := str(room.get("id", ""))
	var next_epoch := str(room.get("voice_epoch", ""))
	if next_id == _party_id and next_epoch == _epoch:
		return
	var new_party := next_id != _party_id
	_leave_bridge()
	_party_id = next_id
	_epoch = next_epoch
	_request_serial += 1
	_retry_in = 0.0
	_retry_index = 0
	_last_error = ""
	if new_party and mode == Mode.OFF and _party_id != "":
		# 进一个新队伍默认「只听」：麦克风关、扬声器开。只在换队伍时做 —— 同一个队伍有人进出
		# 只是换语音房间，玩家自己关掉的扬声器不能被悄悄打开。
		speaker_enabled = true
		_sync_mode()
	if mode != Mode.OFF:
		_join()
	_emit_label()


# 由两个显式开关推导 bridge 要的合成态。麦克风优先：开麦即 TALK；
# 否则扬声器开就 LISTEN，两者都关就 OFF（leaveRoom）。
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
	# Android 在 join 时就定下音频模式，切换麦克风态要重进（钥匙走缓存，不再问服务器）。
	_leave_bridge()
	if mode != Mode.OFF:
		_retry_in = 0.0
		_retry_index = 0
		_join()
	_emit_label()


# 麦克风开/关。开麦前没有录音权限时，向系统请求并返回一句提示，让界面告诉玩家「允许后再点一次」。
func set_mic_enabled(enabled: bool) -> String:
	if not _has_bridge_method("joinRoom"):
		return "当前设备没有可用的语音组件"
	if enabled and not bool(_bridge.hasRecordPermission()):
		if _has_bridge_method("requestRecordPermission"):
			_bridge.requestRecordPermission()
		else:
			OS.request_permission("android.permission.RECORD_AUDIO")
		return "请允许麦克风权限后再点一次开麦"
	mic_enabled = enabled
	_sync_mode()
	return ""


func set_speaker_enabled(enabled: bool) -> String:
	speaker_enabled = enabled
	_applied_volumes.clear()
	_sync_mode()
	_apply_volumes()
	return ""


func stop() -> void:
	mode = Mode.OFF
	mic_enabled = false
	speaker_enabled = false
	_party_id = ""
	_epoch = ""
	_request_serial += 1
	_token_cache = {}
	_leave_bridge()
	_emit_label()


# 最近一次出错给玩家看的话（空 = 正常）。
func last_error() -> String:
	return _last_error


# 已经让桥接进了房间（包括正在连）。语音面板显示状态用。
func connected() -> bool:
	return _connected


# 正在说话的队友（好友码），被我屏蔽的不算 —— 屏蔽了我也听不到，头像上不该亮。
func speaking_codes() -> Array[String]:
	var out: Array[String] = []
	for identity in status().get("speaking", []):
		var code := str(identity)
		if not VoiceService.is_code_muted(code):
			out.append(code)
	return out


func self_speaking() -> bool:
	return mode == Mode.TALK and bool(status().get("self_speaking", false))


# 桥接状态（JSON 解析后），0.25 秒内的重复调用走缓存。
func status() -> Dictionary:
	if _bridge == null or not _connected or not _has_bridge_method("getStatus"):
		return {}
	var now := Time.get_ticks_msec()
	if now - _status_at_msec < int(STATUS_INTERVAL_SEC * 1000.0):
		return _status
	_status_at_msec = now
	var parsed: Variant = JSON.parse_string(str(_bridge.getStatus()))
	_status = parsed if parsed is Dictionary else {}
	return _status


func _room_key() -> String:
	return "%s|%s" % [_party_id, _epoch]


func _join() -> void:
	if mode == Mode.OFF or _party_id == "" or _connected or _fetching:
		return
	if not _has_bridge_method("joinRoom"):
		_fail("当前设备没有可用的语音组件", UNAVAILABLE_RETRY_SEC)
		return
	var key := _room_key()
	if str(_token_cache.get("room", "")) == key \
			and Time.get_ticks_msec() - int(_token_cache.get("at_msec", 0)) <= int(TOKEN_REUSE_SEC * 1000.0):
		_enter(str(_token_cache.url), str(_token_cache.token))
		return
	_fetching = true
	_request_serial += 1
	var serial := _request_serial
	var result: Dictionary = await AccountManager.fetch_party_voice_token()
	_fetching = false
	if not is_inside_tree() or serial != _request_serial or key != _room_key() or mode == Mode.OFF:
		return
	var code := int(result.get("code", 0))
	if code != 200:
		_fail(str(result.get("error", "队伍语音暂不可用")),
			UNAVAILABLE_RETRY_SEC if code == 503 else _next_retry())
		return
	var body: Dictionary = result.get("body", {})
	_token_cache = {"room": key, "url": str(body.get("url", "")), "token": str(body.get("token", "")),
		"at_msec": Time.get_ticks_msec()}
	_enter(str(_token_cache.url), str(_token_cache.token))


func _enter(url: String, token: String) -> void:
	var error := str(_bridge.joinRoom(url, token, mode == Mode.LISTEN))
	if not error.is_empty():
		_token_cache = {}
		_fail(VoiceService.explain(error), _next_retry())
		return
	_connected = true
	_retry_index = 0
	_last_error = ""
	_status = {}
	_status_at_msec = -100000
	_applied_volumes.clear()
	# 这个 LiveKit 房间里的每个人都是现在的队友。
	if _has_bridge_method("setAudience"):
		_bridge.setAudience(true, "[]")
	if mic_enabled:
		var mic_error := str(_bridge.setMicrophoneEnabled(true))
		if not mic_error.is_empty():
			mic_enabled = false
			_bridge.setMicrophoneEnabled(false)
			_last_error = VoiceService.explain(mic_error)
			mode = Mode.LISTEN if speaker_enabled else Mode.OFF
			if mode == Mode.OFF:
				_leave_bridge()
	_emit_label()


func _fail(message: String, retry_sec: float) -> void:
	_last_error = message
	_retry_in = retry_sec
	_emit_label()


func _next_retry() -> float:
	var wait := float(RETRY_SEC[mini(_retry_index, RETRY_SEC.size() - 1)])
	_retry_index += 1
	return wait


func _leave_bridge() -> void:
	if _connected and _has_bridge_method("leaveRoom"):
		_bridge.leaveRoom()
	_connected = false
	_status = {}


# 关扬声器 = 每个人音量 0；屏蔽 = 这个人音量 0（只影响自己）；
# 「语音音量」设置（10.10 反馈第 4 条）乘上来 —— 与对局里的 VoiceService 同一个裁决处。
func _apply_volumes() -> void:
	if not _connected or not _has_bridge_method("setParticipantVolume"):
		return
	var level := Presentation.voice_volume()
	for identity in status().get("participants", []):
		var code := str(identity)
		var volume := 0.0 if not speaker_enabled or VoiceService.is_code_muted(code) else level
		if float(_applied_volumes.get(code, -1.0)) != volume:
			_bridge.setParticipantVolume(code, volume)
			_applied_volumes[code] = volume


func _on_mutes_changed() -> void:
	_applied_volumes.clear()
	_apply_volumes()


func _process(delta: float) -> void:
	if mode == Mode.OFF or _party_id == "" or _bridge == null:
		return
	if not _connected:
		if _retry_in > 0.0:
			_retry_in = maxf(0.0, _retry_in - delta)
			return
		_join()
		return
	var st := status()
	if str(st.get("state", "")) == "failed":
		# 连不上、放弃重连、被服务器请出房间：退房，那把钥匙不再用（可能已经作废），退避之后重新要。
		var code := str(st.get("error", "")).strip_edges()
		_leave_bridge()
		_token_cache = {}
		_fail(VoiceService.explain(code if not code.is_empty() else "disconnected"), _next_retry())
		return
	_apply_volumes()


func _emit_label() -> void:
	var english := LocaleManager.get_locale().begins_with("en")
	if not _last_error.is_empty():
		state_changed.emit("🎙 PARTY VOICE · UNAVAILABLE" if english else "🎙 队内语音 · 不可用")
		return
	var word := ("OFF" if mode == Mode.OFF else ("LISTEN" if mode == Mode.LISTEN else "TALK")) if english else \
		("关闭" if mode == Mode.OFF else ("只听" if mode == Mode.LISTEN else "开麦"))
	state_changed.emit(("🎙 PARTY VOICE · " if english else "🎙 队内语音 · ") + word)
