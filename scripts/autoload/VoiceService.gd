extends Node

# 游戏内组队语音（docs/聊天系统设计.md 第九节，方案 ②「自建 + 手机自带的回声消除」）。
#
# 三档（界面上一个按钮循环切换）：
#   OFF     什么都不开（默认）。
#   LISTEN  进通话模式、放队友的声音；麦克风关着。
#   TALK    开麦：说话时（插件自己判断有没有在说）把声音发给同队。
#
# 这里只管「什么时候开关」和「包往哪送」：
#   录音 / 编码 / 混音 / 播放  安卓插件（android_plugins/glory_voice → addons/glory_voice/bin）
#   转发                       ③（NetworkService._rpc_team_voice_submit，只转同队）
#
# 🔴 麦克风绝不自己打开：
#   - 默认 OFF；连续 LEAVE_GRACE_SEC 秒不在房间里就回到 OFF，下一个房间要自己再开；
#   - 从后台回来只恢复离开前的档位，不会升档。
# 没有插件的包（桌面、没勾 glory_voice/enabled 的安卓包）按钮照样在，点了说明原因。

signal mode_changed(mode: int)

enum Mode { OFF, LISTEN, TALK }

const SINGLETON := "GloryVoice"
const MIC_PERMISSION := "android.permission.RECORD_AUDIO"
# 重连、切场景时 team_local_slot 可能短暂变成 -1。这么久都不在房间里才算真的离开。
const LEAVE_GRACE_SEC := 3.0
# 与插件 readPackets() 一次最多交出的包数一致。正常每帧 0~1 个。
const MAX_PACKETS_PER_FRAME := 12
const STATUS_INTERVAL_SEC := 0.25

var mode: int = Mode.OFF
var _plugin: Object = null
var _session := false
var _capturing := false
var _out_of_room_sec := 0.0
var _want_talk_after_permission := false
var _status: Dictionary = {}
var _status_at_msec := -100000


func _ready() -> void:
	if Engine.has_singleton(SINGLETON):
		_plugin = Engine.get_singleton(SINGLETON)
	if not NetworkService.team_voice_received.is_connected(_on_voice_received):
		NetworkService.team_voice_received.connect(_on_voice_received)
	if not get_tree().on_request_permissions_result.is_connected(_on_permission_result):
		get_tree().on_request_permissions_result.connect(_on_permission_result)


func is_supported() -> bool:
	return _plugin != null


func in_room() -> bool:
	return NetworkService.team_active and int(NetworkService.team_local_slot) >= 0


# 界面按钮：关 → 只听 → 开麦 → 关。返回空串 = 已切换（或在等系统权限弹窗）；否则是给玩家看的原因。
func cycle_mode() -> String:
	return set_mode((mode + 1) % 3)


func set_mode(next: int) -> String:
	if next == mode:
		return ""
	if next == Mode.OFF:
		_want_talk_after_permission = false
		return _change_mode(Mode.OFF)
	if not is_supported():
		return _text("这个版本没有语音功能", "Voice is not available in this build")
	if not in_room():
		return _text("进入房间后才能开语音", "Join a room to use voice")
	if next == Mode.TALK and not bool(_plugin.hasRecordPermission()):
		# 先进「只听」，等系统权限弹窗的结果；允许了再开麦（_on_permission_result）。
		# 不另外弹提示：系统弹窗本身就在眼前，再叠一层只会挡住它。
		_want_talk_after_permission = true
		var err := _change_mode(Mode.LISTEN)
		if err.is_empty():
			OS.request_permission(MIC_PERMISSION)
		return err
	return _change_mode(next)


func mode_label() -> String:
	match mode:
		Mode.LISTEN:
			return _text("语音：只听", "Voice: listen")
		Mode.TALK:
			return _text("语音：开麦", "Voice: mic on")
	return _text("语音：关", "Voice: off")


# 按钮文字后面的小圆点：有队友在说话，或者自己开着麦且正在说。
func activity_mark() -> String:
	var st := status()
	if st.is_empty():
		return ""
	var speaking: Array = st.get("speaking_slots", [])
	if not speaking.is_empty() or (mode == Mode.TALK and bool(st.get("mic_active", false))):
		return " ●"
	return ""


# 插件状态（JSON 解析后）。界面每 0.25 秒拉一次；同一时间窗里的重复调用走缓存。
func status() -> Dictionary:
	if _plugin == null or not _session:
		return {}
	var now := Time.get_ticks_msec()
	if now - _status_at_msec < int(STATUS_INTERVAL_SEC * 1000.0):
		return _status
	_status_at_msec = now
	var parsed: Variant = JSON.parse_string(str(_plugin.getStatus()))
	_status = parsed if parsed is Dictionary else {}
	return _status


func _process(delta: float) -> void:
	if mode == Mode.OFF:
		return
	if in_room():
		_out_of_room_sec = 0.0
	else:
		_out_of_room_sec += delta
		if _out_of_room_sec >= LEAVE_GRACE_SEC:
			_out_of_room_sec = 0.0
			_want_talk_after_permission = false
			_change_mode(Mode.OFF)
			return
	if _capturing and _plugin != null:
		for packet in split_packets(_plugin.readPackets()):
			NetworkService.team_send_voice(packet)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			# 插件在 onMainPause 里已经自己全停了（后台不录音）。这里只同步状态。
			_session = false
			_capturing = false
		NOTIFICATION_APPLICATION_RESUMED:
			if mode != Mode.OFF and _apply() != "":
				_change_mode(Mode.OFF)


func _on_voice_received(slot: int, packet: PackedByteArray) -> void:
	if not _session or _plugin == null:
		return
	if slot == int(NetworkService.team_local_slot):
		return
	_plugin.pushPacket(slot, packet)


func _on_permission_result(permission: String, granted: bool) -> void:
	if not permission.ends_with("RECORD_AUDIO") or not _want_talk_after_permission:
		return
	_want_talk_after_permission = false
	if granted and mode == Mode.LISTEN and in_room():
		_change_mode(Mode.TALK)


func _change_mode(next: int) -> String:
	var previous := mode
	mode = next
	var err := _apply()
	if not err.is_empty():
		# 开不起来就退回到能工作的那一档，不让按钮显示一个实际没生效的状态。
		mode = Mode.LISTEN if next == Mode.TALK and _session else Mode.OFF
		_apply()
	if mode != previous:
		mode_changed.emit(mode)
	return err


# 让插件的实际状态与 mode 一致。返回空串 = 一致；否则是给玩家看的原因。
func _apply() -> String:
	if _plugin == null:
		_session = false
		_capturing = false
		return "" if mode == Mode.OFF else _text("这个版本没有语音功能", "Voice is not available in this build")
	var want_session := mode != Mode.OFF and in_room()
	if want_session and not _session:
		var start_code := str(_plugin.startSession(true))
		if not start_code.is_empty():
			return explain(start_code)
		_session = true
	elif not want_session and _session:
		_plugin.stopSession()
		_session = false
		_capturing = false
	var want_capture := _session and mode == Mode.TALK
	if want_capture != _capturing:
		var capture_code := str(_plugin.setCapture(want_capture))
		if not capture_code.is_empty():
			return explain(capture_code)
		_capturing = want_capture
	return ""


# 插件一次交出来的是「[u16 长度][包]」首尾相接的一串（GloryVoicePlugin.readPackets）。
# 长度对不上就停：宁可丢掉这一批，也不把半个包发出去。
static func split_packets(blob: PackedByteArray) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	var offset := 0
	while offset + 2 <= blob.size() and out.size() < MAX_PACKETS_PER_FRAME:
		var length := blob.decode_u16(offset)
		offset += 2
		if length <= 0 or offset + length > blob.size():
			break
		out.append(blob.slice(offset, offset + length))
		offset += length
	return out


static func explain(code: String) -> String:
	match code:
		"no_permission":
			return "没有麦克风权限：到系统设置里给这个应用麦克风权限"
		"mic_busy":
			return "麦克风被别的应用占着（比如正在通话）"
		"record_init_failed", "record_start_failed", "bad_record_params":
			return "麦克风打不开"
		"play_init_failed", "no_audio_manager":
			return "声音输出打不开"
		"no_session":
			return "语音还没开"
	return "语音出错：%s" % code


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
