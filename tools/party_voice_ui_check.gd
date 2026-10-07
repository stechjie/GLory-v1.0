extends Node

# 10.07 bug 文档第 9 条：房间语音 UI 改为「麦克风 + 扬声器」两个图标按钮。
#
# 判据分两层：
#   1. 行为：`PartyVoice` 由「一个 cycle() 循环态」拆成两个**互相独立**的显式开关
#      （`set_mic_enabled` / `set_speaker_enabled`），合成出正确的 bridge 态：
#        · 进房默认「只听」：麦克风关、扬声器开；
#        · ★ 开麦**不**动扬声器（10.07 第 9 条返工，用户真机反馈）；
#        · ★ 关扬声器**不**动麦克风（同上）；
#        · 两个开关都关 ⇒ 合成态 OFF；
#        · 没有录音权限时开麦 ⇒ 返回提示、不真的开麦。
#
#      ⚠️ 旧口径是「开麦⇒扬声器必须开」「关扬声器⇒麦克风一并关」—— 那两条互锁正是
#      玩家报的「麦克风没法独立打开」，**已被本轮的独立口径推翻**，不要再改回去。
#   2. 结构：`PartyLobby` 源码里必须真的有两个图标按钮（麦克风/扬声器），
#      不再有旧的单文字按钮与 cycle() 调用。
#
# ★ 行为断言走**真 PartyVoice 实例 + 假 bridge**，不直读源码 —— 结构断言只补一条
#   「接线在不在」，证明不了状态机对不对。
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/party_voice_ui_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const PartyVoiceScript := preload("res://scenes/menu/PartyVoice.gd")
const LOBBY_SRC := "res://scenes/menu/PartyLobby.gd"

const CHECK_NAME := "party_voice_ui"

var _h: CheckHarness


# 假 bridge：模拟安卓 JNI 暴露的方法集（has_java_method 与直接调用两条路）。
class FakeBridge extends RefCounted:
	var permission := true
	var joined := false
	var joins := 0
	var leaves := 0
	var mic_on := false
	var audience_all := false
	var last_join_listen_only := false

	func has_java_method(method: StringName) -> bool:
		return str(method) in ["joinRoom", "leaveRoom", "setMicrophoneEnabled",
			"setAudience", "hasRecordPermission", "requestRecordPermission", "getStatus"]

	func hasRecordPermission() -> bool:
		return permission
	func requestRecordPermission() -> void:
		pass
	func joinRoom(_url: String, _token: String, listen_only: bool) -> String:
		joined = true
		joins += 1
		last_join_listen_only = listen_only
		mic_on = false
		return ""
	func leaveRoom() -> void:
		joined = false
		mic_on = false
		leaves += 1
	func setMicrophoneEnabled(enabled: bool) -> String:
		mic_on = enabled
		return ""
	func setAudience(_all: bool, _ids: String) -> void:
		audience_all = _all
	func getStatus() -> String:
		return '{"state":"connected"}'


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	await get_tree().process_frame

	await _case_default_listen()
	await _case_mic_independent_of_speaker()
	await _case_speaker_independent_of_mic()
	await _case_both_off_is_mode_off()
	await _case_mic_needs_permission()
	_case_lobby_wiring()

	_h.finish(get_tree())


func _make() -> Dictionary:
	var voice := PartyVoiceScript.new()
	var bridge := FakeBridge.new()
	# ★ 必须**先 add_child 再 set("_bridge", ...)**：PartyVoice._ready() 里有一句
	#   `if Engine.has_singleton("GloryVoice"): _bridge = Engine.get_singleton(...)`，
	#   桌面构建里确实挂着 GloryVoiceDesktop 单例 ⇒ 它会**盖掉**先塞进去的假 bridge
	#   （实测）。所以等 _ready() 跑完再覆盖。
	add_child(voice)
	voice.set("_bridge", bridge)
	voice.set("_party_id", "room-1")
	voice.set("_epoch", "e1")
	return {"voice": voice, "bridge": bridge}


# 1) 进房默认「只听」：麦克风关、扬声器开、bridge 收到 listen_only=true。
func _case_default_listen() -> void:
	var made := _make()
	var voice: Node = made["voice"]
	var bridge: FakeBridge = made["bridge"]
	# 清掉 _make() 预置的 id/epoch，让 configure() 不因「房间没变」提前返回。
	voice.set("_party_id", "")
	voice.set("_epoch", "")
	voice.call("configure", {"id": "room-1", "voice_epoch": "e1"})
	await get_tree().process_frame
	_h.expect(not bool(voice.get("mic_enabled")), "default_mic_off",
		"进房默认麦克风关，实际 mic_enabled=%s" % str(voice.get("mic_enabled")))
	_h.expect(bool(voice.get("speaker_enabled")), "default_speaker_on",
		"进房默认扬声器开（否则进房听不见队友）")
	voice.queue_free()


# 2) ★ 开麦**不**碰扬声器（10.07 第 9 条返工）。
#    真机反馈：旧实现 `if enabled: speaker_enabled = true` 让玩家「必须先开扬声器才能开麦」。
#    现在的口径是两者独立 —— 扬声器关着也能开麦（你说话、只是听不见别人，是合理的）。
func _case_mic_independent_of_speaker() -> void:
	var made := _make()
	var voice: Node = made["voice"]
	var bridge: FakeBridge = made["bridge"]
	voice.set("speaker_enabled", false)
	voice.set("mic_enabled", false)
	voice.set("mode", 0)
	var err := str(voice.call("set_mic_enabled", true))
	_h.expect(err.is_empty(), "mic_ok_no_error", "有权限开麦不该返回错误，实际 %s" % err)
	_h.expect(bool(voice.get("mic_enabled")), "mic_on_after_toggle", "点开麦后麦克风应为开")
	_h.expect(not bool(voice.get("speaker_enabled")), "mic_does_not_touch_speaker",
		"★ 开麦不该顺手把扬声器打开 —— 两个开关必须独立（扬声器关着也能开麦）")
	_h.expect(int(voice.get("mode")) == 2, "mode_talk", "合成态应为 TALK(2)，实际 %d" % int(voice.get("mode")))
	voice.queue_free()


# 3) ★ 关扬声器**不**碰麦克风（10.07 第 9 条返工）。
#    旧实现 `if not enabled: mic_enabled = false` 会把你正在说的话也摁掉。
#    现在关扬声器只是「我听不见」，不影响别人听你。
func _case_speaker_independent_of_mic() -> void:
	var made := _make()
	var voice: Node = made["voice"]
	var bridge: FakeBridge = made["bridge"]
	voice.set("speaker_enabled", true)
	voice.set("mic_enabled", true)
	voice.set("mode", 2)
	voice.call("set_speaker_enabled", false)
	_h.expect(not bool(voice.get("speaker_enabled")), "speaker_off", "关扬声器后 speaker_enabled 应为 false")
	_h.expect(bool(voice.get("mic_enabled")), "speaker_off_keeps_mic",
		"★ 关扬声器不该把麦克风一起关掉 —— 两个开关必须独立（静音不影响开麦）")
	_h.expect(int(voice.get("mode")) == 2, "mode_stays_talk",
		"麦克风还开着 ⇒ 合成态仍是 TALK(2)，实际 %d" % int(voice.get("mode")))
	voice.queue_free()


# 4) 两个开关都关 ⇒ 合成态 OFF（这时才离开 bridge 房间）。
func _case_both_off_is_mode_off() -> void:
	var made := _make()
	var voice: Node = made["voice"]
	var bridge: FakeBridge = made["bridge"]
	voice.set("speaker_enabled", true)
	voice.set("mic_enabled", false)
	voice.set("mode", 1)
	voice.call("set_speaker_enabled", false)
	_h.expect(not bool(voice.get("mic_enabled")) and not bool(voice.get("speaker_enabled")),
		"both_off", "麦克风与扬声器都应为关")
	_h.expect(int(voice.get("mode")) == 0, "mode_off",
		"两个开关都关 ⇒ 合成态 OFF(0)，实际 %d" % int(voice.get("mode")))
	voice.queue_free()


# 5) 无录音权限时开麦：返回提示、不真的开麦。
func _case_mic_needs_permission() -> void:
	var made := _make()
	var voice: Node = made["voice"]
	var bridge: FakeBridge = made["bridge"]
	bridge.permission = false
	var err := str(voice.call("set_mic_enabled", true))
	_h.expect(not err.is_empty(), "mic_no_permission_hint",
		"没有录音权限时开麦必须返回一句提示（让界面告诉玩家），实际空串")
	_h.expect(not bool(voice.get("mic_enabled")), "mic_stays_off_without_permission",
		"没有权限时麦克风不该被标成开")
	voice.queue_free()


# 6) 结构：PartyLobby 里必须有两个图标按钮，且不再调用旧的 cycle()/单按钮。
func _case_lobby_wiring() -> void:
	var src := FileAccess.get_file_as_string(LOBBY_SRC)
	if not _h.expect(not src.is_empty(), "lobby_src_readable", "读不到 PartyLobby.gd"):
		return
	_h.expect(src.contains("_voice_mic") and src.contains("_voice_speaker"),
		"two_buttons_exist", "房间界面必须有 _voice_mic 与 _voice_speaker 两个按钮")
	_h.expect(src.contains("set_mic_enabled") and src.contains("set_speaker_enabled"),
		"two_toggles_wired", "两个按钮分别接到 set_mic_enabled / set_speaker_enabled")
	_h.expect(not src.contains("_party_voice.cycle("), "old_cycle_gone",
		"不再调用旧的 cycle() 循环切换")
	_h.expect(not src.contains("_voice = _button("), "old_single_button_gone",
		"旧的单个文字按钮 _voice 必须删掉")
	_h.expect(src.contains("mic_on") and src.contains("mic_off")
			and src.contains("speaker_on") and src.contains("speaker_off"),
		"icon_keys_present", "图标用 mic_on/mic_off 与 speaker_on/speaker_off 四张状态图")
	# ★ 10.07 第 9 条返工：麦克风按钮**不能**再被扬声器状态禁用 ——
	#   那正是真机反馈的「要扬声器打开才能开麦」。
	#   先归一化行尾（仓库侧 .gd 是 CRLF），否则跨行片段永远 find 不到、断言静默判假。
	#   ⚠️ 再**剥掉注释行**：本文件（PartyLobby）的注释里逐字写了那条旧实现用来解释
	#   为什么删它，裸 contains 会把注释当成代码命中 —— 这是踩过的坑。
	var code := ""
	for line in src.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
		if (line as String).strip_edges().begins_with("#"):
			continue
		code += line + "\n"
	_h.expect(not code.contains("_voice_mic.disabled = _local_only or not speaker_on"),
		"mic_not_gated_by_speaker",
		"★ 麦克风按钮不得因扬声器关闭而被禁用（必须能独立开麦）")
	# 反向：麦克风那行的 disabled 赋值必须**只剩** _local_only（剥注释后仍能找到这一句）。
	_h.expect(code.contains("_voice_mic.disabled = _local_only"),
		"mic_disabled_only_local", "★ 麦克风按钮只允许被 _local_only 禁用")
	# ★ 10.07 第 9 条返工：「按两下才切换」的根因 —— state_changed 回调必须**重画图标**。
	#   旧回调只写 tooltip，而状态是在 await fetch_party_voice_token() 之后才改的，
	#   图标要等那次网络往返，玩家点一下看不到反馈。这里钉住「回调里也有 _refresh_voice_icons()」。
	var cb_start := code.find("_party_voice.state_changed.connect")
	_h.expect(cb_start >= 0, "state_changed_wired", "必须接 state_changed 信号")
	if cb_start >= 0:
		var cb_end := code.find("\n\n", cb_start)
		var cb_body := code.substr(cb_start, (cb_end - cb_start) if cb_end > cb_start else 400)
		_h.expect(cb_body.contains("_refresh_voice_icons()"),
			"state_changed_repaints",
			"★ state_changed 回调里必须重画图标，否则要点两下才看到切换")
