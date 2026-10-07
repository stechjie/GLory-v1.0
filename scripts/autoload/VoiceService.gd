extends Node

# 游戏内组队语音（docs/语音LiveKit方案.md —— 2026-09-19 起改用 LiveKit 自建）。
#
# 三档（界面上的语音按钮循环切换，见 ui/components/VoiceControls.gd）：
#   OFF     不连语音服务器、不用麦克风。
#   LISTEN  连上本局语音房间；麦克风关着。**进房间的默认档**（2026-09-27 起，原来默认 OFF）。
#   TALK    开麦，直接对话（不是按住说话）。回声消除 / 降噪由各平台的 LiveKit 开发包做。
#
# 这里是游戏里**唯一**的语音入口，界面和游戏代码不分平台：
#   录音 / 编码 / 网络 / 播放  各平台的桥接（安卓 Kotlin、电脑 C++ 扩展、苹果 Swift），都注册成同一个单例
#                             Engine.get_singleton("GloryVoice")，方法见 BRIDGE_METHODS
#   钥匙                       战斗服务器签发，只能进「本对局」的语音房间（NetworkService.team_request_voice_token）
#   离开 / 被踢 / 被 AI 接管    战斗服务器把人请出语音房间（钥匙只管进门）
#   换座（含跨队）               **不重连**：两队共用一个房间（协议 36），谁能听到我由 _apply_audience 每帧按座位重算
#
# 桥接的方法（名字刻意避开 Object 自带的 connect / disconnect）：
#   hasRecordPermission() -> bool
#   joinRoom(url, token, listen_only) -> String   开始连（异步）；空串 = 已开始，否则是原因代码。
#                                                 listen_only 决定声音模式（安卓：只听用媒体模式，蓝牙耳机保持高音质）
#   leaveRoom()                                   断开，停止录音和播放
#   setMicrophoneEnabled(enabled) -> String       开 / 关麦；还没连上时先记下，连上再生效。
#                                                 空串 = 已受理；真正打不开（异步）写在 getStatus 的 mic_error
#   setParticipantVolume(identity, volume)        某个队友的音量 0 ~ 1，0 = 屏蔽（只影响自己）
#   setAudience(all, identities_json)              发布者麦克风订阅权限；队友范围按身份列表，全部范围开放全房间
#   getStatus() -> String   JSON：state（disconnected / connecting / connected / reconnecting / failed）、error、
#                           mic_on、mic_error、self_speaking、speaking（身份列表）、participants（身份列表）、
#                           audio_mode、output。放弃重连、被服务器请出房间、切后台时 state = failed，
#                           这边退避之后重新要钥匙
#   getCapabilities() -> String   JSON：platform、sdk、aec（system / webrtc / none）、listen_mode_fixed_at_join
# 身份 = 战斗服务器按座位名片填的好友码（没有名片的测试座位是 seat<N>），这里用它对回座位。
#
# listen_mode_fixed_at_join（安卓）：「只听」和「开麦」用的是两种声音模式（只听 = 媒体声道，游戏声和蓝牙音质不受影响；
# 开麦 = 通话模式，有系统回声消除），只能在进房时定。所以换档 = 退房再进，用刚才那把钥匙（TOKEN_REUSE_SEC 内），
# 不用再问战斗服务器；中间断一两秒。
#
# 🔴 麦克风绝不自己打开：
#   - 每进一个新房间自动切到「只听」一次（只收听、不开麦克风）；玩家在这个房间里自己关掉就保持关。
#     连续 LEAVE_GRACE_SEC 秒不在房间里就回到 OFF，下一个房间又回到「只听」；开麦永远要自己点；
#   - 切到后台就断开（不申请后台音频，后台不录音），回来只恢复离开前的档位，不会升档。
#
# 屏蔽：按玩家的好友码记，队友换座位也跟着人走；**整个游戏进程内有效**（骚扰的人下一局还可能
# 分到一起），重开游戏清空。屏蔽 = 让桥接把这个人的音量设成 0，只影响自己听不听得到，对方不知道。
#
# 语音连不上（服务器没开语音、网络不通、钥匙被拒）只影响语音：面板写出原因，按 TOKEN_RETRY_SEC 退避重试，
# 对局照常。没有桥接的包（电脑版第 3 阶段之前、苹果版之前）按钮照样在，点了说明原因。

signal mode_changed(mode: int)
signal audience_changed(audience: int)
signal mutes_changed
# 系统麦克风权限弹窗的结果（只在这里请求过时发）。界面据此在被拒时提示去系统设置打开。
signal mic_permission_result(granted: bool)

enum Mode { OFF, LISTEN, TALK }
enum Audience { TEAM, ALL }

const SINGLETON := "GloryVoice"
# 桥接必须提供的方法（名字 → 参数个数）。三个平台照这张表实现；tools/voice_check 拿它对账。
const BRIDGE_METHODS := {
	"hasRecordPermission": 0,
	"joinRoom": 3,
	"leaveRoom": 0,
	"setMicrophoneEnabled": 1,
	"setParticipantVolume": 2,
	"setAudience": 2,
	"getStatus": 0,
	"getCapabilities": 0,
}
const MIC_PERMISSION := "android.permission.RECORD_AUDIO"
# 重连、切场景时 team_local_slot 可能短暂变成 -1。这么久都不在房间里才算真的离开。
const LEAVE_GRACE_SEC := 3.0
const STATUS_INTERVAL_SEC := 0.25
# 要不到钥匙 / 连不上时的重试间隔（依次加长，停在最后一个）。与服务器的 voice_token 限流（10 秒 5 次）相容。
const TOKEN_RETRY_SEC := [2.0, 4.0, 8.0, 15.0, 30.0]
# 要了钥匙这么久没回音（请求被限流丢掉、连接正好断了）就当失败，走重试。
const TOKEN_REPLY_TIMEOUT_SEC := 10.0
# 换档重进时，这么久以内拿到的钥匙直接再用（钥匙 10 分钟内可以进房，留 2 分钟余量）。
# 只用于自己换档：连不上 / 被请出之后一律重新要（旧钥匙可能已经被服务器作废）。
const TOKEN_REUSE_SEC := 480.0
# 与 Team3v3Lobby.SLOT_LABELS / RoomChatLog.SEAT_LABELS 一致：资料还没到时用座位号顶着。
const SEAT_LABELS := ["A", "B", "C", "1", "2", "3"]

var mode: int = Mode.OFF
var audience: int = Audience.TEAM
var speaker_enabled := true
# 已经替哪个房间切过默认的「只听」（-1 = 还没有）。每个房间只切一次：
# 玩家在房间里自己关掉之后，不能每帧又被切回去。离开房间（LEAVE_GRACE_SEC）时清掉。
var _defaulted_room := -1
# 门禁注入「要钥匙」的函数（返回 bool：发出去没有）；空 = NetworkService.team_request_voice_token。
var token_requester: Callable = Callable()

var _bridge: Object = null
var _joined := false          # 已让桥接进房（包括正在连）
var _joined_listen_only := false
var _room_name := ""
# 最近一次拿到的钥匙：{url, token, room, at_msec}。换档重进时再用，见 TOKEN_REUSE_SEC。
var _token_cache: Dictionary = {}
var _mic_on := false          # 已让桥接开麦
var _awaiting_token := false
var _awaiting_sec := 0.0
var _retry_index := 0
var _retry_in := 0.0          # > 0：倒计时到了再要钥匙
var _last_error := ""         # 给玩家看的原因（空 = 正常）
var _out_of_room_sec := 0.0
var _want_talk_after_permission := false
var _status: Dictionary = {}
var _status_at_msec := -100000
var _capabilities: Dictionary = {}
# 玩家键（"code:好友码"，没有好友码时 "slot:座位号"）-> true
var _muted_keys: Dictionary = {}
# 语音身份 -> 最后一次设给桥接的音量（只在变了时才调）
var _applied_volumes: Dictionary = {}
var _applied_audience := ""
var _application_paused := false


func _ready() -> void:
	if Engine.has_singleton(SINGLETON):
		_bridge = Engine.get_singleton(SINGLETON)
	if not NetworkService.team_voice_token_received.is_connected(_on_voice_token):
		NetworkService.team_voice_token_received.connect(_on_voice_token)
	if not get_tree().on_request_permissions_result.is_connected(_on_permission_result):
		get_tree().on_request_permissions_result.connect(_on_permission_result)


# Android plugin methods live in JNI, outside Object.has_method().
# Desktop GDExtensions and test bridges use the ordinary Object method table.
func _bridge_has_method(method: StringName) -> bool:
	if _bridge == null:
		return false
	if _bridge.has_method("has_java_method"):
		return bool(_bridge.call("has_java_method", method))
	return _bridge.has_method(method)


func is_supported() -> bool:
	return _bridge != null and _bridge_has_method("setAudience")


func audience_label() -> String:
	if lobby_open_to_room():
		return _text("全房间", "Whole room")
	return _text("队友", "Team") if audience == Audience.TEAM else _text("全部", "All")


func set_audience(next: int) -> void:
	if next != Audience.TEAM and next != Audience.ALL:
		return
	if next == audience:
		return
	audience = next
	_applied_audience = ""
	_apply_audience()
	audience_changed.emit(audience)


func toggle_audience() -> void:
	set_audience(Audience.ALL if audience == Audience.TEAM else Audience.TEAM)


# 没有语音桥接时给玩家看的话。
# Windows 版的桥接是 addons/glory_voice/glory_voice.gdextension（docs/语音LiveKit方案.md 5.2）：
# 在 Windows 上还没有，就是那几个 dll 没加载起来（包里缺了，或者被杀毒软件拦了）。
func unsupported_reason() -> String:
	if _bridge != null and not _bridge_has_method("setAudience"):
		return _text("语音组件需要更新，请安装新版游戏", "Voice component needs an update; install the latest game build")
	if OS.has_feature("windows"):
		return _text("语音组件没有加载起来，请重新安装游戏", "Voice component failed to load; please reinstall the game")
	if OS.has_feature("pc"):
		return _text("这个系统的电脑版还没有语音", "Voice is not available on this system yet")
	return _text("这个版本没有语音功能", "Voice is not available in this build")


func in_room() -> bool:
	return NetworkService.team_active and int(NetworkService.team_local_slot) >= 0


# 界面按钮：关 → 只听 → 开麦 → 关。返回空串 = 已切换（或在等系统权限弹窗）；否则是给玩家看的原因。
func cycle_mode() -> String:
	return set_mode((mode + 1) % 3)


func set_microphone_enabled(enabled: bool) -> String:
	return set_mode(Mode.TALK if enabled else (Mode.LISTEN if speaker_enabled else Mode.OFF))

func set_speaker_enabled(enabled: bool) -> String:
	if enabled and not is_supported():
		return unsupported_reason()
	if enabled and not in_room():
		return _text("进入房间后才能开语音", "Join a room to use voice")
	speaker_enabled = enabled
	_applied_volumes.clear()
	var error := ""
	if mode != Mode.TALK and not _want_talk_after_permission:
		error = set_mode(Mode.LISTEN if enabled else Mode.OFF)
	_apply_volumes()
	mode_changed.emit(mode)
	return error

func set_mode(next: int) -> String:
	if next == mode:
		return ""
	if next == Mode.OFF:
		speaker_enabled = false
		_want_talk_after_permission = false
		return _change_mode(Mode.OFF)
	if not is_supported():
		return unsupported_reason()
	if not in_room():
		return _text("进入房间后才能开语音", "Join a room to use voice")
	if next == Mode.TALK and not bool(_bridge.hasRecordPermission()):
		# 先进「只听」，等系统权限弹窗的结果；允许了再开麦（_on_permission_result）。
		# 用途说明由界面在调这里之前弹（VoiceControls.request_talk），这里不再叠一层。
		_want_talk_after_permission = true
		_change_mode(Mode.LISTEN)
		if _bridge_has_method("requestRecordPermission"):
			_bridge.requestRecordPermission()
		else:
			OS.request_permission(MIC_PERMISSION)
		return ""
	if next == Mode.LISTEN:
		speaker_enabled = true
	return _change_mode(next)


# 开麦前是否要先向玩家说明麦克风用途（还没拿到系统权限时）。
func needs_mic_rationale() -> bool:
	return is_supported() and not bool(_bridge.hasRecordPermission())


func mode_label() -> String:
	match mode:
		Mode.LISTEN:
			return _text("语音：只听", "Voice: listen")
		Mode.TALK:
			return _text("语音：开麦", "Voice: mic on")
	return _text("语音：关", "Voice: off")


# 按钮变色用：有没屏蔽的队友在说话，或者自己开着麦且正在说。
func is_active() -> bool:
	for slot in speaking_slots():
		if not is_muted(slot):
			return true
	return mode == Mode.TALK and bool(status().get("self_speaking", false))


# 连接状态，给界面看：off / connecting / connected / reconnecting / failed。
func connection_state() -> String:
	if mode == Mode.OFF or not is_supported():
		return "off"
	if _joined:
		return str(status().get("state", "connecting"))
	if not _last_error.is_empty():
		return "failed"
	return "connecting"


# 最近一次出错给玩家看的话（空 = 没出错）。连上、或者关掉语音时清空。
func last_error() -> String:
	return _last_error


# 桥接状态（JSON 解析后）。界面每 0.25 秒拉一次；同一时间窗里的重复调用走缓存。
func status() -> Dictionary:
	if _bridge == null or not _joined:
		return {}
	var now := Time.get_ticks_msec()
	if now - _status_at_msec < int(STATUS_INTERVAL_SEC * 1000.0):
		return _status
	_status_at_msec = now
	var parsed: Variant = JSON.parse_string(str(_bridge.getStatus()))
	_status = parsed if parsed is Dictionary else {}
	return _status


# 这台设备的能力（平台、有没有系统回声消除），第一次问的时候取一次。
func capabilities() -> Dictionary:
	if _bridge == null:
		return {}
	if _capabilities.is_empty():
		var parsed: Variant = JSON.parse_string(str(_bridge.getCapabilities()))
		_capabilities = parsed if parsed is Dictionary else {}
	return _capabilities


# 正在说话的其他玩家座位（不含自己）。
func speaking_slots() -> Array[int]:
	var out: Array[int] = []
	var me := int(NetworkService.team_local_slot)
	for identity in status().get("speaking", []):
		var slot := identity_slot(str(identity))
		if slot >= 0 and slot != me and not out.has(slot):
			out.append(slot)
	return out


# 这个座位的人此刻在不在说话 —— 头像上的小麦克风用（VoiceControls.show_speaking_mic）。
# 自己：开着麦、桥接说在说；别人：在说话名单里、没被我屏蔽（屏蔽了我也听不到，不该亮）。
func slot_speaking(slot: int) -> bool:
	if not _joined or slot < 0:
		return false
	if slot == int(NetworkService.team_local_slot):
		return mode == Mode.TALK and bool(status().get("self_speaking", false))
	return speaking_slots().has(slot) and not is_muted(slot)


# 语音身份（好友码 / seat<N>）→ 座位号；对不上返回 -1。
func identity_slot(identity: String) -> int:
	if identity.begins_with("seat") and identity.substr(4).is_valid_int():
		return int(identity.substr(4))
	if identity.is_empty():
		return -1
	var profiles: Dictionary = NetworkService.team_seat_profiles
	for key in profiles.keys():
		var profile: Variant = profiles[key]
		if profile is Dictionary and str((profile as Dictionary).get("friend_code", "")).strip_edges() == identity:
			return int(key)
	return -1


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
	_apply_volumes()
	mutes_changed.emit()


func _seat_key(slot: int) -> String:
	return "slot:%d" % slot


# 按好友码屏蔽 —— 组队房（PartyVoice）没有座位号，语音身份就是好友码。
# 和座位上的屏蔽是**同一张表**：在组队房里屏蔽了谁，进了对局他还是被屏蔽的，反过来也一样。
func is_code_muted(code: String) -> bool:
	return _muted_keys.has("code:" + code.strip_edges())


func set_code_muted(code: String, muted: bool) -> void:
	var key := "code:" + code.strip_edges()
	if code.strip_edges().is_empty() or muted == _muted_keys.has(key):
		return
	if muted:
		_muted_keys[key] = true
	else:
		_muted_keys.erase(key)
	_apply_volumes()
	mutes_changed.emit()


# 这个语音身份该不该静音：对得上座位就按座位判（含按座位号记的那条），对不上就按好友码判。
func _identity_muted(identity: String) -> bool:
	var slot := identity_slot(identity)
	if slot >= 0:
		return is_muted(slot)
	return _muted_keys.has("code:" + identity)


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


func audience_members() -> Array[Dictionary]:
	if not open_to_room():
		return teammates()
	var out: Array[Dictionary] = []
	if not in_room():
		return out
	var me := int(NetworkService.team_local_slot)
	var states: Array = NetworkService.team_slot_states
	var profiles: Dictionary = NetworkService.team_seat_profiles
	var speaking := speaking_slots()
	for slot in NetworkService.TEAM_SLOTS:
		if slot == me:
			continue
		var state := str(states[slot]) if slot < states.size() else ""
		var has_profile := profiles.has(slot) or profiles.has(str(slot))
		if state != "player" and not (state.is_empty() and has_profile):
			continue
		out.append({"slot": slot, "name": member_name(slot), "muted": is_muted(slot), "speaking": speaking.has(slot)})
	return out


func _team_audience_identities() -> Array[String]:
	var ids: Array[String] = []
	if not in_room():
		return ids
	var me := int(NetworkService.team_local_slot)
	var team := GameConstants.team_of_slot(me)
	var states: Array = NetworkService.team_slot_states
	var profiles: Dictionary = NetworkService.team_seat_profiles
	for slot in NetworkService.TEAM_SLOTS:
		if slot == me or GameConstants.team_of_slot(slot) != team:
			continue
		var state := str(states[slot]) if slot < states.size() else ""
		var profile: Dictionary = profiles.get(slot, profiles.get(str(slot), {}))
		if state != "player" and not (state.is_empty() and not profile.is_empty()):
			continue
		var code := str(profile.get("friend_code", "")).strip_edges()
		ids.append(code if not code.is_empty() else "seat%d" % slot)
	ids.sort()
	return ids


func _apply_audience() -> void:
	if not _joined or not is_supported():
		return
	var open := open_to_room()
	var identities: Array[String] = []
	if not open:
		identities = _team_audience_identities()
	var key := "%d:%s" % [1 if open else 0, JSON.stringify(identities)]
	if key == _applied_audience:
		return
	_bridge.setAudience(open, JSON.stringify(identities))
	_applied_audience = key


# 我的麦克风此刻是不是对全房间开放：自己选了「所有人」，或者在自定义房间开局前的大厅里。
func open_to_room() -> bool:
	return audience == Audience.ALL or lobby_open_to_room()


# 用户 10-08 定（B 方案）：**自定义房间开局前**，全房间的人互相都听得到；开局后才按「队友 / 所有人」分。
# 只管自定义房间 —— 匹配进来的房间（休闲 / 排位）里是陌生人，大厅阶段也只对队友说。
# match_mode 为空（还不知道是什么房）按匹配房处理：宁可少开放。
func lobby_open_to_room() -> bool:
	return NetworkService.match_mode == "custom" and NetworkService.server_phase == NetworkService.ROOM_LOBBY


# --- 每帧 ----------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _application_paused:
		return
	if in_room():
		_out_of_room_sec = 0.0
		_apply_room_default()
	else:
		_out_of_room_sec += delta
		if _out_of_room_sec >= LEAVE_GRACE_SEC:
			# 真离开了（不是重连那种一两秒的掉线）：语音全关，按座位号记的屏蔽作废。
			_out_of_room_sec = 0.0
			_defaulted_room = -1
			set_audience(Audience.TEAM)
			_forget_seat_mutes()
			if mode != Mode.OFF:
				_want_talk_after_permission = false
				_change_mode(Mode.OFF)
			return
	if mode == Mode.OFF or not is_supported():
		return
	if _want_talk_after_permission and _bridge_has_method("requestRecordPermission"):
		# Permission can finish before a voice token arrives. status() intentionally
		# hides room state until joined, so read the native permission independently.
		var native_status: Variant = JSON.parse_string(str(_bridge.getStatus()))
		var permission := str(native_status.get("permission", "")) if native_status is Dictionary else ""
		if permission == "granted" or permission == "denied":
			_on_permission_result("microphone", permission == "granted")
	if _retry_in > 0.0:
		_retry_in = maxf(0.0, _retry_in - delta)
	if _awaiting_token:
		_awaiting_sec += delta
		if _awaiting_sec >= TOKEN_REPLY_TIMEOUT_SEC:
			_awaiting_token = false
			_token_failed("no_reply")
	_watch_bridge()
	_sync_and_fallback()
	_apply_volumes()
	_apply_audience()


# 进了一个新房间：还关着就切到「只听」（2026-09-27 用户定的默认档）。只切这一次 ——
# 之后玩家自己关掉就保持关。没有语音桥接的包什么都不做（不弹「这个版本没有语音」）。
func _apply_room_default() -> void:
	var room := int(NetworkService.team_room_id)
	if room == _defaulted_room:
		return
	_defaulted_room = room
	if mode == Mode.OFF and is_supported():
		set_mode(Mode.LISTEN)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_IN:
			# iOS starts CoreAudio immediately after this notification and before
			# APPLICATION_RESUMED. Activate its session synchronously first.
			if _bridge != null and _bridge_has_method("prepareAudioResume"):
				var audio_ready := bool(_bridge.prepareAudioResume())
				NetworkService._net_log("ios audio focus ready=%s" % str(audio_ready))
		NOTIFICATION_APPLICATION_PAUSED:
			# 切到后台：断开（不申请后台音频，后台不录音）。档位不变，回来之后 _process 里自动重连。
			_application_paused = true
			if _bridge != null and _bridge_has_method("setApplicationActive"):
				_bridge.setApplicationActive(false)
			_leave()
		NOTIFICATION_APPLICATION_RESUMED:
			_application_paused = false
			if _bridge != null and _bridge_has_method("setApplicationActive"):
				_bridge.setApplicationActive(true)
			_retry_in = 0.0
			_retry_index = 0


func _on_permission_result(permission: String, granted: bool) -> void:
	if (not permission.ends_with("RECORD_AUDIO") and permission != "microphone") or not _want_talk_after_permission:
		return
	_want_talk_after_permission = false
	if granted and mode == Mode.LISTEN and in_room():
		_change_mode(Mode.TALK)
	mic_permission_result.emit(granted)


# 战斗服务器回了钥匙（或原因）。
# token_team 不看：两队共用一个房间，钥匙与队伍无关（换座不重连，见 _sync）。参数留着是因为信号带它。
func _on_voice_token(url: String, token: String, room_name: String, error: String, _token_team: int) -> void:
	if not _awaiting_token:
		return   # 已经不要了（关了语音、离开了房间、超时之后才到）
	# 只接受当前对局的全员语音房，上一局的旧钥匙作废。
	if error.is_empty() and not _is_current_room(room_name):
		return
	_awaiting_token = false
	if mode == Mode.OFF or _bridge == null or not in_room():
		return
	if not error.is_empty():
		_token_failed(error)
		return
	_token_cache = {"url": url, "token": token, "room": room_name, "at_msec": Time.get_ticks_msec()}
	if _join(url, token, room_name, true):
		_sync_and_fallback()


func _is_current_room(room_name: String) -> bool:
	return room_name.begins_with("g%d-" % int(NetworkService.team_room_id)) and room_name.ends_with("-all")


# 让桥接按当前档位进房。clear_error：拿新钥匙进房时清掉旧的出错原因；换档重进时保留（例如「麦克风被占用」要留给玩家看）。
func _join(url: String, token: String, room_name: String, clear_error: bool) -> bool:
	var listen_only := mode == Mode.LISTEN
	var code := str(_bridge.joinRoom(url, token, listen_only))
	if not code.is_empty():
		_token_cache = {}
		_token_failed(code)
		return false
	_joined = true
	_joined_listen_only = listen_only
	_room_name = room_name
	_mic_on = false
	_applied_volumes.clear()
	_applied_audience = ""
	_apply_audience()
	_status = {}
	_status_at_msec = -100000
	_retry_index = 0
	if clear_error:
		_last_error = ""
	return true


# 换档重进：钥匙是本局的、还新，就直接再用，不去问战斗服务器。
func _rejoin_from_cache() -> void:
	if _token_cache.is_empty() or not _is_current_room(str(_token_cache.get("room", ""))):
		return
	if Time.get_ticks_msec() - int(_token_cache.get("at_msec", 0)) > int(TOKEN_REUSE_SEC * 1000.0):
		return
	_join(str(_token_cache.url), str(_token_cache.token), str(_token_cache.room), false)


func _listen_mode_fixed() -> bool:
	return bool(capabilities().get("listen_mode_fixed_at_join", false))


func _change_mode(next: int) -> String:
	var previous := mode
	mode = next
	if next == Mode.OFF:
		_retry_in = 0.0
		_retry_index = 0
		_last_error = ""
		_token_cache = {}
	var err := _sync()
	if not err.is_empty() and mode == Mode.TALK:
		# 麦克风打不开：退回「只听」，不让按钮显示一个实际没生效的档位。
		mode = Mode.LISTEN
		_sync()
	if mode != previous:
		mode_changed.emit(mode)
	return err


# 让桥接的实际状态跟上档位与座位。每帧调；只在要变的时候才调桥接。返回开麦失败的原因（空 = 没事）。
func _sync() -> String:
	if not is_supported() or _application_paused:
		return ""
	if mode == Mode.OFF:
		_leave()
		return ""
	if not in_room():
		return ""   # 重连、切场景的那一两秒：不动，等回来或等 LEAVE_GRACE_SEC 到点
	# 换座（含跨队）在这里什么都不做：两队共用一个语音房间，连接不动；
	# 新队伍谁能听到我，由 _apply_audience 按新座位重算（同一帧里就会调）。
	if _joined and _listen_mode_fixed() and _joined_listen_only != (mode == Mode.LISTEN):
		# 只听 ↔ 开麦：这个桥接的声音模式只能在进房时定（见文件头 listen_mode_fixed_at_join），退房再进。
		_leave()
		_rejoin_from_cache()
		if not _joined:
			_retry_in = 0.0
			_retry_index = 0
	if not _joined:
		if not _awaiting_token and _retry_in <= 0.0:
			_request_token()
		return ""
	var want_mic := mode == Mode.TALK
	if want_mic == _mic_on:
		return ""
	var code := str(_bridge.setMicrophoneEnabled(want_mic))
	if code.is_empty():
		_mic_on = want_mic
		return ""
	return explain(code) if want_mic else ""


# 每帧与连上之后用：开麦失败就退回「只听」并把原因留给界面。
func _sync_and_fallback() -> void:
	var err := _sync()
	if err.is_empty() or mode != Mode.TALK:
		return
	_last_error = err
	mode = Mode.LISTEN
	_sync()
	mode_changed.emit(mode)


func _request_token() -> void:
	_awaiting_token = true
	_awaiting_sec = 0.0
	var sent := bool(token_requester.call()) if token_requester.is_valid() else NetworkService.team_request_voice_token()
	if not sent:
		_awaiting_token = false
		_token_failed("not_connected")


func _token_failed(code: String) -> void:
	_last_error = explain(code)
	_retry_in = float(TOKEN_RETRY_SEC[mini(_retry_index, TOKEN_RETRY_SEC.size() - 1)])
	_retry_index += 1


# 桥接自己连不上、放弃重连、被服务器请出房间：当作断开，退避之后重新要钥匙。
func _watch_bridge() -> void:
	if not _joined:
		return
	var st := status()
	if str(st.get("state", "")) == "failed":
		var code := str(st.get("error", "")).strip_edges()
		_leave()
		_token_cache = {}   # 可能是被服务器请出去的：那把钥匙已经作废
		_token_failed(code if not code.is_empty() else "join_failed")
		return
	# 开麦请求受理了，麦克风却打不开（被占用、没权限）：退回「只听」并说明原因。
	# _mic_on 留着不动，让接下来的 _sync 去关麦或按「只听」重进。
	var mic_error := str(st.get("mic_error", "")).strip_edges()
	if mode == Mode.TALK and _mic_on and not mic_error.is_empty():
		_last_error = explain(mic_error)
		mode = Mode.LISTEN
		mode_changed.emit(mode)


func _leave() -> void:
	if _joined and _bridge != null:
		_bridge.leaveRoom()
	_joined = false
	_joined_listen_only = false
	_room_name = ""
	_mic_on = false
	_awaiting_token = false
	_applied_volumes.clear()
	_applied_audience = ""
	_status = {}
	_status_at_msec = -100000


# 屏蔽 = 音量 0。只在变了时才调桥接；新进房的队友下一次状态刷新（≤ 0.25 秒）就会被设上。
func _apply_volumes() -> void:
	if _bridge == null or not _joined:
		return
	for identity in status().get("participants", []):
		var id := str(identity)
		var volume := 0.0 if not speaker_enabled or _identity_muted(id) else 1.0
		if float(_applied_volumes.get(id, -1.0)) != volume:
			_bridge.setParticipantVolume(id, volume)
			_applied_volumes[id] = volume


static func explain(code: String) -> String:
	match code:
		"voice_not_configured":
			return "服务器还没开语音"
		"not_in_room", "not_seated":
			return "进入房间后才能开语音"
		"not_connected", "no_reply":
			return "还没连上服务器，稍后自动重试"
		"join_failed", "disconnected", "connection_failed":
			return "语音服务器连不上，稍后自动重试"
		"no_permission":
			return "没有麦克风权限：到系统设置里给这个应用麦克风权限"
		"mic_busy":
			return "麦克风被别的应用占着（比如正在通话）"
		"mic_failed":
			return "麦克风打不开"
		"audience_failed":
			return "语音范围设置失败，麦克风已关闭"
		"removed":
			return "你已不在这个队伍的语音里"
		"room_deleted":
			return "这一局的语音已结束"
		"duplicate_identity":
			return "这个账号在别的设备上进了语音"
		"paused":
			return "切到后台时语音断开了，正在重连"
		"audio_device_failed":
			return "打不开电脑的声音设备（麦克风 / 喇叭），检查一下是否被别的程序占用"
		"sdk_failed":
			return "语音组件启动失败"
	return "语音出错：%s" % code


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
