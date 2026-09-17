extends Node

# 游戏内组队语音（docs/聊天系统设计.md 第九节，方案 ②「自建 + 手机自带的回声消除」）。
#
# 三档（界面上的语音按钮循环切换，见 ui/components/VoiceControls.gd）：
#   OFF     什么都不开（默认）。
#   LISTEN  进通话模式、放队友的声音；麦克风关着。
#   TALK    开麦：说话时（插件自己判断有没有在说）把声音发给同队。
#
# 这里只管「什么时候开关」「包往哪送」「屏蔽谁」：
#   录音 / 编码 / 混音 / 播放  安卓插件（android_plugins/glory_voice → addons/glory_voice/bin）
#   转发                       ③（NetworkService._rpc_team_voice_submit，只转同队）
#
# 🔴 麦克风绝不自己打开：
#   - 默认 OFF；连续 LEAVE_GRACE_SEC 秒不在房间里就回到 OFF，下一个房间要自己再开；
#   - 从后台回来只恢复离开前的档位，不会升档。
#
# 屏蔽（v1.1）：按玩家的好友码记，队友换座位也跟着人走；**整个游戏进程内有效**（骚扰的人下一局还可能
# 分到一起），重开游戏清空。被屏蔽的人的包在交给插件之前就丢掉，解都不解。只影响自己听不听得到。
#
# 电脑（Windows）上用 scripts/voice/DesktopVoiceBackend.gd 顶替插件（2026-09-17 试用版：只有 ADPCM、没有回声消除）。
# 没有插件的包（没勾 glory_voice/enabled 的安卓包、其它平台）按钮照样在，点了说明原因。

signal mode_changed(mode: int)
signal mutes_changed
# 系统麦克风权限弹窗的结果（只在这里请求过时发）。界面据此在被拒时提示去系统设置打开。
signal mic_permission_result(granted: bool)

enum Mode { OFF, LISTEN, TALK }

const SINGLETON := "GloryVoice"
const DesktopVoiceBackend := preload("res://scripts/voice/DesktopVoiceBackend.gd")
const MIC_PERMISSION := "android.permission.RECORD_AUDIO"
# 重连、切场景时 team_local_slot 可能短暂变成 -1。这么久都不在房间里才算真的离开。
const LEAVE_GRACE_SEC := 3.0
# 与插件 readPackets() 一次最多交出的包数一致。正常每帧 0~1 个。
const MAX_PACKETS_PER_FRAME := 12
const STATUS_INTERVAL_SEC := 0.25
# 与 Team3v3Lobby.SLOT_LABELS / PrepUI.CHAT_SEAT_LABELS 一致：资料还没到时用座位号顶着。
const SEAT_LABELS := ["A", "B", "C", "1", "2", "3"]

var mode: int = Mode.OFF
var _plugin: Object = null
var _session := false
var _capturing := false
var _out_of_room_sec := 0.0
var _want_talk_after_permission := false
var _status: Dictionary = {}
var _status_at_msec := -100000
var _capabilities: Dictionary = {}
# 玩家键（"code:好友码"，没有好友码时 "slot:座位号"）-> true
var _muted_keys: Dictionary = {}


func _ready() -> void:
	if Engine.has_singleton(SINGLETON):
		_plugin = Engine.get_singleton(SINGLETON)
	elif OS.has_feature("windows") and DisplayServer.get_name() != "headless":
		# 电脑版（scripts/voice/DesktopVoiceBackend.gd）：方法与安卓插件同名同参，下面的代码不用分平台。
		# 无界面运行（门禁、战斗服务器）不挂：那里没人说话，也免得门禁里的「没有插件」用例失真。
		var desktop: Node = DesktopVoiceBackend.new()
		desktop.name = "DesktopVoice"
		add_child(desktop)
		_plugin = desktop
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
		# 用途说明由界面在调这里之前弹（VoiceControls.request_talk），这里不再叠一层。
		_want_talk_after_permission = true
		var err := _change_mode(Mode.LISTEN)
		if err.is_empty():
			OS.request_permission(MIC_PERMISSION)
		return err
	return _change_mode(next)


# 开麦前是否要先向玩家说明麦克风用途（还没拿到系统权限时）。
func needs_mic_rationale() -> bool:
	return is_supported() and not bool(_plugin.hasRecordPermission())


func mode_label() -> String:
	match mode:
		Mode.LISTEN:
			return _text("语音：只听", "Voice: listen")
		Mode.TALK:
			return _text("语音：开麦", "Voice: mic on")
	return _text("语音：关", "Voice: off")


# 按钮变色用：有没屏蔽的队友在说话，或者自己开着麦且正在说。
func is_active() -> bool:
	var st := status()
	if st.is_empty():
		return false
	for slot in speaking_slots():
		if not is_muted(slot):
			return true
	return mode == Mode.TALK and bool(st.get("mic_active", false))


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


# 手机能力（有没有系统回声消除等），开游戏后第一次问的时候取一次。
func capabilities() -> Dictionary:
	if _plugin == null:
		return {}
	if _capabilities.is_empty():
		var parsed: Variant = JSON.parse_string(str(_plugin.getCapabilities()))
		_capabilities = parsed if parsed is Dictionary else {}
	return _capabilities


# JSON 里的数字都是 float，这里统一成 int，免得 has(1) 对不上 1.0。
func speaking_slots() -> Array[int]:
	var out: Array[int] = []
	for value in status().get("speaking_slots", []):
		out.append(int(value))
	return out


func codec_label() -> String:
	match str(status().get("codec", "")):
		"opus":
			return "Opus"
		"adpcm":
			return "ADPCM"
	return "-"


# --- 屏蔽 ----------------------------------------------------------------------------

func member_key(slot: int) -> String:
	var profiles: Dictionary = NetworkService.team_seat_profiles
	var identity: Dictionary = profiles.get(slot, profiles.get(str(slot), {}))
	var code := str(identity.get("friend_code", "")).strip_edges()
	return ("code:" + code) if not code.is_empty() else _seat_key(slot)


func member_name(slot: int) -> String:
	var profiles: Dictionary = NetworkService.team_seat_profiles
	var identity: Dictionary = profiles.get(slot, profiles.get(str(slot), {}))
	var who := str(identity.get("player_name", "")).strip_edges()
	if not who.is_empty():
		return who
	var seat: String = SEAT_LABELS[slot] if slot >= 0 and slot < SEAT_LABELS.size() else "?"
	return _text("席位", "Seat ") + seat


# 按人记（好友码），换座位跟着人走；资料还没到的队友先按座位号记。
# 座位号那条在资料到了之后仍然算数 —— 否则资料一到，屏蔽就悄悄解除了。
# 离开房间时清掉座位号那条（下一个房间同一个座位是别人）。只存在内存里，重开游戏就没了。
func is_muted(slot: int) -> bool:
	return _muted_keys.has(member_key(slot)) or _muted_keys.has(_seat_key(slot))


func set_muted(slot: int, muted: bool) -> void:
	if muted == is_muted(slot):
		return
	if muted:
		_muted_keys[member_key(slot)] = true
	else:
		_muted_keys.erase(member_key(slot))
		_muted_keys.erase(_seat_key(slot))
	mutes_changed.emit()


func _seat_key(slot: int) -> String:
	return "slot:%d" % slot


func _forget_seat_mutes() -> void:
	var changed := false
	for key in _muted_keys.keys():
		if str(key).begins_with("slot:"):
			_muted_keys.erase(key)
			changed = true
	if changed:
		mutes_changed.emit()


# 同队的其他真人：[{slot, name, muted, speaking}]。AI 座位、空座位、敌方、自己都不在里面。
func teammates() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not in_room():
		return out
	var me := int(NetworkService.team_local_slot)
	var team := GameConstants.team_of_slot(me)
	var states: Array = NetworkService.team_slot_states
	var profiles: Dictionary = NetworkService.team_seat_profiles
	var speaking := speaking_slots()
	for slot in NetworkService.TEAM_SLOTS:
		if slot == me or GameConstants.team_of_slot(slot) != team:
			continue
		var state := str(states[slot]) if slot < states.size() else ""
		var has_profile := profiles.has(slot) or profiles.has(str(slot))
		if state != "player" and not (state.is_empty() and has_profile):
			continue
		out.append({
			"slot": slot,
			"name": member_name(slot),
			"muted": is_muted(slot),
			"speaking": speaking.has(slot),
		})
	return out


# --- 每帧 ----------------------------------------------------------------------------

func _process(delta: float) -> void:
	if in_room():
		_out_of_room_sec = 0.0
	else:
		_out_of_room_sec += delta
		if _out_of_room_sec >= LEAVE_GRACE_SEC:
			# 真离开了（不是重连那种一两秒的掉线）：语音全关，按座位号记的屏蔽作废。
			_out_of_room_sec = 0.0
			_forget_seat_mutes()
			if mode != Mode.OFF:
				_want_talk_after_permission = false
				_change_mode(Mode.OFF)
			return
	if mode == Mode.OFF:
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
	if slot == int(NetworkService.team_local_slot) or is_muted(slot):
		return
	_plugin.pushPacket(slot, packet)


func _on_permission_result(permission: String, granted: bool) -> void:
	if not permission.ends_with("RECORD_AUDIO") or not _want_talk_after_permission:
		return
	_want_talk_after_permission = false
	if granted and mode == Mode.LISTEN and in_room():
		_change_mode(Mode.TALK)
	mic_permission_result.emit(granted)


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
		"input_disabled":
			# 电脑版：项目设置里没打开录音输入（audio/driver/enable_input.windows）。是打包问题，不是玩家的错。
			return "麦克风打不开（这个版本没有打开电脑录音）"
		"play_init_failed", "no_audio_manager":
			return "声音输出打不开"
		"no_session":
			return "语音还没开"
	return "语音出错：%s" % code


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
