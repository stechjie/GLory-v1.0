extends Node

# 游戏内组队语音（docs/聊天系统设计.md 第九节，方案 ②）的门禁。
#
# 验不了的：回声、延迟、断续 —— 只能在真手机上听（出包之后同事测）。
# 这里钉的是几件「不报错、只是坏」的事：
#   1. 插件包 GloryVoice.aar 是照着现在的 Java 源码打的。改了 Java 忘了重打包，
#      手机上跑的就是旧代码，而测的人以为是新的
#   2. 插件包清单：Godot 找插件用的 meta-data、两条权限、显式 targetSdkVersion
#   3. 导出插件默认不打包：没开 Gradle 的出包流程不能被它弄失败
#   4. 🔴 ③ 的转发契约：不许自报座位号、软限流、大小上限、不可靠有序 + 独立通道
#   5. 🔴 只转同队：敌方永远收不到（语音里说的是战术）
#   6. Java 的最大包长不超过 ③ 的上限：两边分开改不会报错，只会最长的那种包被整包丢掉
#   7. VoiceService 的状态机：麦克风不自己打开、短暂掉线不关、离开房间自动关、
#      权限流程、自己的声音不回放、开不起来就退回「关」
#   8. 两个界面都接上了按钮，并在离开时断开信号；验证版的「语音测试」入口已经删掉
#
# 运行：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . res://tools/voice_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const RateLimitService := preload("res://scripts/multiplayer/RateLimitService.gd")

const CHECK_NAME := "voice"
const AAR_PATH := "res://addons/glory_voice/bin/GloryVoice.aar"
const PLUGIN_DIR := "res://android_plugins/glory_voice"
const EXPORT_PLUGIN_PATH := "res://addons/glory_voice/glory_voice_plugin.gd"
const NETWORK_SERVICE_PATH := "res://scripts/autoload/NetworkService.gd"

var _h: CheckHarness


# 假插件：方法与 GloryVoicePlugin 的 @UsedByGodot 方法同名同参。
class FakePlugin extends RefCounted:
	var permission := true
	var start_error := ""
	var session := false
	var capturing := false
	var pushed: Array = []
	var outgoing := PackedByteArray()

	func hasRecordPermission() -> bool:
		return permission

	func startSession(_speakerphone: bool) -> String:
		if not start_error.is_empty():
			return start_error
		session = true
		return ""

	func stopSession() -> void:
		session = false
		capturing = false

	func setCapture(enabled: bool) -> String:
		if enabled and not session:
			return "no_session"
		capturing = enabled
		return ""

	func readPackets() -> PackedByteArray:
		var out := outgoing
		outgoing = PackedByteArray()
		return out

	func pushPacket(slot: int, _packet: PackedByteArray) -> void:
		pushed.append(slot)

	func getStatus() -> String:
		return "{}"


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_aar_matches_source()
	_case_aar_manifest()
	_case_export_plugin_off_by_default()
	_case_relay_contract()
	_case_packet_budget()
	_case_team_only()
	_case_split_packets()
	_case_voice_service_state_machine()
	_case_ui_wired()
	_h.finish(get_tree())


# --- 1. 插件包与源码对得上 --------------------------------------------------------

func _case_aar_matches_source() -> void:
	_h.item()
	var zr := ZIPReader.new()
	if not _h.expect(zr.open(AAR_PATH) == OK, "aar_missing",
			"没有 %s —— 跑一次 android_plugins/glory_voice/build_aar.ps1" % AAR_PATH):
		return
	var recorded := ""
	if zr.get_files().has("glory_voice_source.sha256"):
		recorded = zr.read_file("glory_voice_source.sha256").get_string_from_utf8().strip_edges()
	zr.close()
	var actual := _source_digest()
	_h.expect(not actual.is_empty() and recorded == actual, "aar_stale",
		("插件包不是照着现在的源码打的（包里 %s…，源码 %s…）。改了 Java / 清单 / 保留规则之后"
			+ "要重跑 android_plugins/glory_voice/build_aar.ps1。") % [recorded.left(12), actual.left(12)])


# 与 build_aar.ps1 完全同一个算法：「相对路径:sha256」逐行、按码点排序、\n 连接，再 SHA-256。
func _source_digest() -> String:
	var rel := PackedStringArray(["AndroidManifest.xml", "proguard.txt"])
	_collect_java(PLUGIN_DIR.path_join("src"), "src", rel)
	rel.sort()
	var lines := PackedStringArray()
	for path in rel:
		var sha := FileAccess.get_sha256(PLUGIN_DIR.path_join(path))
		if sha.is_empty():
			return ""
		lines.append("%s:%s" % [path, sha])
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update("\n".join(lines).to_utf8_buffer())
	return ctx.finish().hex_encode()


func _collect_java(dir_path: String, rel_prefix: String, out: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_collect_java(dir_path.path_join(sub), rel_prefix + "/" + sub, out)
	for file in dir.get_files():
		if file.ends_with(".java"):
			out.append(rel_prefix + "/" + file)


# --- 2. 清单 --------------------------------------------------------------------

func _case_aar_manifest() -> void:
	_h.item()
	var zr := ZIPReader.new()
	if zr.open(AAR_PATH) != OK:
		_h.fail("aar_missing", "没有 %s" % AAR_PATH)
		return
	var files := zr.get_files()
	var manifest := ""
	if files.has("AndroidManifest.xml"):
		manifest = zr.read_file("AndroidManifest.xml").get_string_from_utf8()
	zr.close()
	_h.expect(files.has("classes.jar"), "aar_no_classes", "插件包里没有 classes.jar")
	_h.expect(manifest.contains("org.godotengine.plugin.v2.GloryVoice")
			and manifest.contains("com.glory.voice.GloryVoicePlugin"),
		"aar_no_plugin_meta", "插件包清单里没有 Godot 找插件用的 meta-data —— 打进包也不会被加载")
	_h.expect(manifest.contains("android.permission.RECORD_AUDIO")
			and manifest.contains("android.permission.MODIFY_AUDIO_SETTINGS"),
		"aar_missing_permissions", "插件包清单里少了 RECORD_AUDIO / MODIFY_AUDIO_SETTINGS")
	_h.expect(manifest.contains("android:targetSdkVersion"), "aar_no_target_sdk",
		"插件包清单没写 targetSdkVersion：清单合并会给整个应用加上 READ_PHONE_STATE 等隐含权限")


# --- 3. 默认不打包 ----------------------------------------------------------------

func _case_export_plugin_off_by_default() -> void:
	_h.item()
	var src := FileAccess.get_file_as_string(EXPORT_PLUGIN_PATH)
	_h.expect(src.contains("\"default_value\": false"), "voice_export_default_on",
		"glory_voice/enabled 的默认值必须是 false —— 默认打包会让不开 Gradle 的出包直接失败")
	_h.expect(src.contains("if not (enabled is bool and enabled):"), "voice_export_ungated",
		"_get_android_libraries 必须先看 glory_voice/enabled，没勾就不给 .aar")
	_h.expect(load(EXPORT_PLUGIN_PATH) != null, "voice_export_plugin_broken",
		"导出插件脚本加载失败：%s" % EXPORT_PLUGIN_PATH)


# --- 4. 🔴 ③ 的转发契约 -------------------------------------------------------------

func _case_relay_contract() -> void:
	_h.item()
	var src := FileAccess.get_file_as_string(NETWORK_SERVICE_PATH)
	var submit := "func _rpc_team_voice_submit(packet: PackedByteArray) -> void:"
	var relay := "func _rpc_team_voice(slot: int, packet: PackedByteArray) -> void:"
	if not _h.expect(src.contains(submit) and src.contains(relay), "voice_rpc_signature_changed",
			("语音两条 RPC 的签名变了。上行必须**只收 packet** —— 带 slot 就等于能以队友的名义说话，"
				+ "座位号一律由 ③ 从 sender 反查。期望：%s / %s") % [submit, relay]):
		return
	_h.expect(src.contains("@rpc(\"any_peer\", \"call_remote\", \"unreliable_ordered\", NetworkConfig.CH_VOICE)\n"
			+ submit), "voice_submit_transfer_mode",
		"上行必须是 unreliable_ordered + CH_VOICE：可靠传输会把丢的包重传回来，晚到的语音只是杂音，"
			+ "还会在弱网时把整条通道拖住")
	_h.expect(src.contains("@rpc(\"authority\", \"call_remote\", \"unreliable_ordered\", NetworkConfig.CH_VOICE)\n"
			+ relay), "voice_relay_transfer_mode", "下行必须是 unreliable_ordered + CH_VOICE（理由同上）")
	var body := _function_body(src, submit)
	_h.expect(body.contains("_rate_ok(sender, \"voice\", false)"), "voice_rate_limit_not_soft",
		"③ 必须调 _rate_ok(sender, \"voice\", false)：要限流，但不计 strike —— 弱网恢复时包会攒成一串到")
	_h.expect(body.contains("packet.size() > VOICE_MAX_PACKET_BYTES"), "voice_size_unchecked",
		"③ 转发前必须自己检查包大小，客户端那一道改包就绕过了")
	_h.expect(body.contains("voice_recipients(room, slot, sender)"), "voice_not_team_routed",
		"③ 必须按 voice_recipients 转（只转同队），不能全房广播")
	_h.expect(RateLimitService.LIMITS.has("voice"), "voice_rate_limit_missing",
		"RateLimitService.LIMITS 里没有 voice —— allow() 会静默退回默认额度 20，语音每秒只剩 2 个包")
	_h.expect(NetworkConfig.CH_VOICE > NetworkConfig.CH_BULK, "voice_channel_shared",
		"CH_VOICE 必须是独立的用户通道（> CH_BULK），不能和控制流 / 大包共用")


# 从函数头到下一个顶层声明为止。只看这一段，不看整个文件 ——
# 整个文件里别处也有同样的调用，整文件 contains 会被那些满足，断言就成了摆设。
func _function_body(src: String, header: String) -> String:
	var start := src.find(header)
	if start < 0:
		return ""
	var stop := src.length()
	for marker in ["\n@rpc(", "\nfunc ", "\nstatic func "]:
		var at := src.find(marker, start + header.length())
		if at >= 0 and at < stop:
			stop = at
	return src.substr(start, stop - start)


# --- 5. Java 包长 ≤ ③ 上限 ----------------------------------------------------------

func _case_packet_budget() -> void:
	_h.item()
	var codec := FileAccess.get_file_as_string(PLUGIN_DIR.path_join("src/com/glory/voice/AdpcmCodec.java"))
	var plugin := FileAccess.get_file_as_string(PLUGIN_DIR.path_join("src/com/glory/voice/GloryVoicePlugin.java"))
	var frames := _java_int(codec, "MAX_FRAMES_PER_PACKET")
	var samples := _java_int(codec, "FRAME_SAMPLES")
	var header := _java_int(codec, "PACKET_HEADER_BYTES")
	var per_read := _java_int(plugin, "MAX_PACKETS_PER_READ")
	if not _h.expect(frames > 0 and samples > 0 and header > 0 and per_read > 0, "voice_java_constants_unreadable",
			"从 Java 源码里读不到包格式常量 —— 常量换了写法，这条门禁要跟着改"):
		return
	var java_max := header + frames * (3 + samples / 2)
	var limit := int(NetworkService.VOICE_MAX_PACKET_BYTES)
	_h.expect(java_max <= limit, "voice_packet_over_limit",
		"插件最长的包 %d 字节，超过 ③ 的上限 %d：这种包会被服务端整包丢掉，而且不报错" % [java_max, limit])
	# 常见路径 MTU 1280~1500，扣掉 IP/UDP、DTLS、ENet、RPC 头之后，1000 以内不会被分片。
	_h.expect(limit <= 1000, "voice_limit_near_mtu",
		"VOICE_MAX_PACKET_BYTES = %d 太大：不可靠包一旦被分片，丢一片整包就没了" % limit)
	_h.expect(per_read <= int(VoiceService.MAX_PACKETS_PER_FRAME), "voice_read_batch_drift",
		"插件一次交出 %d 个包，VoiceService 一帧只拆 %d 个：多出来的会被丢掉" % [per_read, int(VoiceService.MAX_PACKETS_PER_FRAME)])


func _java_int(src: String, name: String) -> int:
	var m := RegEx.create_from_string(name + "\\s*=\\s*(\\d+)\\s*;").search(src)
	return int(m.get_string(1)) if m != null else -1


# --- 6. 🔴 只转同队 -----------------------------------------------------------------

func _case_team_only() -> void:
	_h.item()
	var room := {"peer_slot": {11: 0, 12: 1, 13: 2, 21: 3, 22: 4, 23: 5}}
	_h.expect(_same(NetworkService.voice_recipients(room, 0, 11), [12, 13]), "voice_red_team_recipients",
		"0 号位说话应只转给 12、13（同队），实际 %s" % str(NetworkService.voice_recipients(room, 0, 11)))
	_h.expect(_same(NetworkService.voice_recipients(room, 4, 22), [21, 23]), "voice_blue_team_recipients",
		"4 号位说话应只转给 21、23（同队），实际 %s" % str(NetworkService.voice_recipients(room, 4, 22)))
	_h.expect(NetworkService.voice_recipients({"peer_slot": {11: 0, 21: 3}}, 0, 11).is_empty(),
		"voice_leaks_to_enemy", "红方只有自己一个人时，包不能转给蓝方")
	_h.expect(NetworkService.voice_recipients(room, -1, 99).is_empty(), "voice_unseated_sender_relayed",
		"没有座位的 peer 说话不该转给任何人")
	_h.expect(NetworkService.voice_recipients({}, 0, 11).is_empty(), "voice_empty_room_relayed",
		"房间里没有 peer_slot 时不该转给任何人")


func _same(actual: Array, expected: Array) -> bool:
	var sorted_actual := actual.duplicate()
	sorted_actual.sort()
	if sorted_actual.size() != expected.size():
		return false
	for i in expected.size():
		if int(sorted_actual[i]) != int(expected[i]):
			return false
	return true


# --- 7. 插件交出来的包怎么拆 --------------------------------------------------------

func _case_split_packets() -> void:
	_h.item()
	var blob := PackedByteArray()
	blob.append_array(_framed(PackedByteArray([1, 2, 3])))
	blob.append_array(_framed(PackedByteArray([4, 5])))
	var parts := VoiceService.split_packets(blob)
	_h.expect(parts.size() == 2 and parts[0] == PackedByteArray([1, 2, 3]) and parts[1] == PackedByteArray([4, 5]),
		"voice_split_wrong", "两个首尾相接的包没有被原样拆开：%s" % str(parts))
	var truncated := _framed(PackedByteArray([9, 9, 9, 9]))
	truncated.resize(truncated.size() - 1)
	_h.expect(VoiceService.split_packets(truncated).is_empty(), "voice_split_half_packet",
		"长度不够的包必须整个丢掉，不能把半个包发出去")
	_h.expect(VoiceService.split_packets(PackedByteArray([0, 0, 7])).is_empty(), "voice_split_zero_length",
		"长度为 0 的包必须停下，不能死循环或发空包")


func _framed(payload: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, payload.size())
	out.append_array(payload)
	return out


# --- 8. VoiceService 状态机 ---------------------------------------------------------

func _case_voice_service_state_machine() -> void:
	var saved_plugin: Object = VoiceService._plugin
	var saved_mode: int = VoiceService.mode
	var saved_active: bool = NetworkService.team_active
	var saved_slot: int = NetworkService.team_local_slot
	var fake := FakePlugin.new()
	var events: Array = []
	var on_changed := func(changed: int) -> void: events.append(changed)
	VoiceService.mode_changed.connect(on_changed)

	# a) 没有插件的包（桌面、没勾插件的安卓包）：点了只给原因，档位不动
	_h.item()
	VoiceService._plugin = null
	VoiceService.mode = VoiceService.Mode.OFF
	_h.expect(not VoiceService.cycle_mode().is_empty() and VoiceService.mode == VoiceService.Mode.OFF,
		"voice_no_plugin_changed_mode", "没有插件时点语音按钮必须给原因、并停在「关」")

	# b) 有插件但不在房间：不开
	_h.item()
	VoiceService._plugin = fake
	NetworkService.team_active = false
	NetworkService.team_local_slot = -1
	_h.expect(not VoiceService.set_mode(VoiceService.Mode.LISTEN).is_empty() and not fake.session,
		"voice_started_outside_room", "不在房间里不能开语音会话")

	# c) 进房间：只听 = 会话开、麦克风关
	_h.item()
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	_h.expect(VoiceService.set_mode(VoiceService.Mode.LISTEN).is_empty() and fake.session and not fake.capturing,
		"voice_listen_wrong", "「只听」必须开会话、但不开麦克风")

	# d) 开麦
	_h.item()
	_h.expect(VoiceService.cycle_mode().is_empty() and VoiceService.mode == VoiceService.Mode.TALK and fake.capturing,
		"voice_talk_wrong", "从「只听」再点一次应该进「开麦」并打开麦克风")

	# e) 收到的包：别人的交给插件，自己的不回放
	_h.item()
	fake.pushed.clear()
	VoiceService._on_voice_received(1, PackedByteArray([1]))
	VoiceService._on_voice_received(0, PackedByteArray([1]))
	_h.expect(fake.pushed == [1], "voice_plays_own_slot",
		"只有队友（1 号位）的包该交给插件，自己座位（0 号位）的不能回放，实际 %s" % str(fake.pushed))

	# f) 再点一次 = 关：全停
	_h.item()
	_h.expect(VoiceService.cycle_mode().is_empty() and VoiceService.mode == VoiceService.Mode.OFF
			and not fake.session and not fake.capturing,
		"voice_off_not_stopped", "从「开麦」再点一次应该回到「关」，会话和麦克风都停")

	# g) 没有麦克风权限：先进「只听」等系统弹窗，允许之后才开麦
	_h.item()
	fake.permission = false
	VoiceService.set_mode(VoiceService.Mode.LISTEN)
	VoiceService.set_mode(VoiceService.Mode.TALK)
	_h.expect(VoiceService.mode == VoiceService.Mode.LISTEN and not fake.capturing,
		"voice_talk_without_permission", "没有麦克风权限时不能进「开麦」")
	fake.permission = true
	VoiceService._on_permission_result("android.permission.RECORD_AUDIO", true)
	_h.expect(VoiceService.mode == VoiceService.Mode.TALK and fake.capturing,
		"voice_permission_grant_ignored", "玩家在系统弹窗里允许之后应该进「开麦」")

	# h) 短暂掉出房间（重连、切场景）不关；连续 LEAVE_GRACE_SEC 秒才关
	_h.item()
	NetworkService.team_local_slot = -1
	VoiceService._process(1.0)
	_h.expect(VoiceService.mode == VoiceService.Mode.TALK and fake.session, "voice_closed_on_blip",
		"掉出房间 1 秒（重连中）就把语音关了")
	NetworkService.team_local_slot = 0
	VoiceService._process(0.1)
	NetworkService.team_active = false
	NetworkService.team_local_slot = -1
	VoiceService._process(VoiceService.LEAVE_GRACE_SEC + 0.1)
	_h.expect(VoiceService.mode == VoiceService.Mode.OFF and not fake.session and not fake.capturing,
		"voice_survives_leaving_room",
		"离开房间 %.0f 秒后语音必须全关 —— 麦克风绝不能带进下一个房间" % VoiceService.LEAVE_GRACE_SEC)

	# i) 会话开不起来：给原因，退回「关」，不显示一个没生效的状态
	_h.item()
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	fake.start_error = "play_init_failed"
	var reason := VoiceService.set_mode(VoiceService.Mode.LISTEN)
	_h.expect(not reason.is_empty() and VoiceService.mode == VoiceService.Mode.OFF,
		"voice_failed_start_left_on", "插件开不起来时必须给原因并停在「关」，实际档位 %d" % VoiceService.mode)
	fake.start_error = ""
	_h.expect(events.size() >= 6, "voice_mode_changed_not_emitted",
		"档位变化时必须发 mode_changed（界面按钮靠它刷新），只收到 %d 次" % events.size())

	VoiceService.mode_changed.disconnect(on_changed)
	VoiceService.set_mode(VoiceService.Mode.OFF)
	VoiceService._plugin = saved_plugin
	VoiceService.mode = saved_mode
	NetworkService.team_active = saved_active
	NetworkService.team_local_slot = saved_slot


# --- 9. 界面接线 --------------------------------------------------------------------

func _case_ui_wired() -> void:
	_h.item()
	var project := FileAccess.get_file_as_string("res://project.godot")
	_h.expect(project.contains("VoiceService=\"*res://scripts/autoload/VoiceService.gd\""),
		"voice_autoload_missing", "project.godot 的 [autoload] 里没有 VoiceService")
	var lobby := FileAccess.get_file_as_string("res://scenes/menu/Team3v3Lobby.gd")
	var prep := FileAccess.get_file_as_string("res://scenes/prep/PrepUI.gd")
	for pair in [["Team3v3Lobby.gd", lobby], ["PrepUI.gd", prep]]:
		var file_name := str(pair[0])
		var src := str(pair[1])
		_h.expect(src.contains("VoiceService.cycle_mode()"), "voice_button_missing",
			"%s 里没有语音按钮（VoiceService.cycle_mode）" % file_name)
		_h.expect(src.contains("VoiceService.mode_changed.disconnect(_on_voice_mode_changed)"),
			"voice_signal_not_disconnected",
			"%s 离开时必须断开 VoiceService.mode_changed —— VoiceService 是 autoload，活得比界面久" % file_name)
	_h.expect(not FileAccess.get_file_as_string("res://scenes/menu/MainMenu.gd").contains("voice_spike"),
		"voice_spike_entry_left", "主菜单还留着验证版的「语音测试」入口")
	for path in ["res://scripts/autoload/VoiceService.gd", "res://scenes/menu/Team3v3Lobby.gd",
			"res://scenes/prep/PrepUI.gd"]:
		_h.expect(load(path) != null, "voice_script_unloadable", "%s 加载失败（解析错误见上面的 SCRIPT ERROR）" % path)
