extends Node

# 游戏内组队语音（docs/聊天系统设计.md 第九节，方案 ②）的门禁。
#
# 验不了的：回声、延迟、断续、Opus 在真机上能不能用 —— 只能在手机上听（插件开语音时会自检 Opus，不过就用 ADPCM）。
# 这里钉的是几件「不报错、只是坏」的事：
#   1. 插件包 GloryVoice.aar 是照着现在的 Java 源码打的。改了 Java 忘了重打包，
#      手机上跑的就是旧代码，而测的人以为是新的
#   2. 插件包清单：Godot 找插件用的 meta-data、两条权限、显式 targetSdkVersion
#   3. 导出插件本身的默认值是「不打包」，只看预设里的 glory_voice/enabled
#   3b. 🔴 仓库里的导出模板必须打开 Gradle + 语音：所有电脑出的包都要带语音（2026-09-17 定）
#   4. 🔴 ③ 的转发契约：不许自报座位号、软限流、大小上限、不可靠有序 + 独立通道
#   5. 🔴 只转同队：敌方永远收不到（语音里说的是战术）
#   6. Java 的包长上限不超过 ③ 的上限：两边分开改不会报错，只会最长的那种包被整包丢掉
#   7. VoiceService 的状态机：麦克风不自己打开、短暂掉线不关、离开房间自动关、
#      权限流程、自己的声音不回放、开不起来就退回「关」
#   8. 屏蔽按人（好友码）记，换座位跟着人走；没权限时开麦前先说明用途
#   9. 大厅 / 备战期 / 战斗界面都接上了按钮，并在离开时 teardown；验证版的「语音测试」入口已经删掉
#  10. ③ 的语音流量统计：每分钟一行，计数都记上了、到点清零
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

	func getCapabilities() -> String:
		return "{}"


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_aar_matches_source()
	_case_aar_manifest()
	_case_export_plugin_off_by_default()
	_case_template_ships_voice()
	_case_relay_contract()
	_case_packet_budget()
	_case_team_only()
	_case_split_packets()
	_case_voice_service_state_machine()
	_case_mutes_follow_player()
	_case_mic_rationale()
	_case_ui_wired()
	_case_server_stats()
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


# --- 3. 打不打包只看预设 ------------------------------------------------------------

func _case_export_plugin_off_by_default() -> void:
	_h.item()
	var src := FileAccess.get_file_as_string(EXPORT_PLUGIN_PATH)
	# 插件自己的默认值仍是 false：它只影响「从零新建、没从模板拷」的预设。
	# 项目要的「每个包都带语音」由 3b 的模板保证，漏网的包由 tools/apk_identity.py 判失败。
	_h.expect(src.contains("\"default_value\": false"), "voice_export_default_on",
		"glory_voice/enabled 的插件默认值应保持 false —— 打不打包由预设（模板）决定，见 3b")
	_h.expect(src.contains("if not (enabled is bool and enabled):"), "voice_export_ungated",
		"_get_android_libraries 必须先看 glory_voice/enabled，没勾就不给 .aar")
	_h.expect(load(EXPORT_PLUGIN_PATH) != null, "voice_export_plugin_broken",
		"导出插件脚本加载失败：%s" % EXPORT_PLUGIN_PATH)


# --- 3b. 🔴 模板打开 Gradle + 语音 ------------------------------------------------------
#
# 2026-09-17 实际出过的事：09-14 定了「Gradle 与语音只在 MSI 那台电脑的预设里开」，
# 而 export_presets.cfg 不进 git。于是另一台电脑出的 p27–p30 包全都没有语音插件 ——
# 包能装、能玩，唯一的症状是语音按钮说「这个版本没有语音功能」。
# 所以模板必须带着这两个键。有人从一台没开语音的电脑重新生成模板，这里就红。

func _case_template_ships_voice() -> void:
	var cfg := ConfigFile.new()
	_h.item()
	if not _h.expect(cfg.load("res://export_presets.template.cfg") == OK, "voice_template_unreadable",
			"读不到 export_presets.template.cfg"):
		return
	var android_sections: Array[String] = []
	for section in cfg.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options") \
				and str(cfg.get_value(section, "platform", "")) == "Android":
			android_sections.append(section + ".options")
	_h.expect(not android_sections.is_empty(), "voice_template_no_android",
		"模板里没有 Android 预设")
	for options in android_sections:
		_h.item()
		_h.expect(cfg.get_value(options, "gradle_build/use_gradle_build", false) == true,
			"voice_template_gradle_off",
			"[%s] use_gradle_build 不是 true —— 语音插件只能用 Gradle 构建打进包，" % options
			+ "从这份模板出的包会没有语音")
		_h.item()
		_h.expect(cfg.get_value(options, "glory_voice/enabled", false) == true,
			"voice_template_voice_off",
			"[%s] glory_voice/enabled 不是 true —— 从这份模板出的包会没有语音" % options
			+ "（p27–p30 就是这么出的事）。在开了语音的电脑上重新生成模板")


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
	var packet_src := FileAccess.get_file_as_string(PLUGIN_DIR.path_join("src/com/glory/voice/VoicePacket.java"))
	var plugin_src := FileAccess.get_file_as_string(PLUGIN_DIR.path_join("src/com/glory/voice/GloryVoicePlugin.java"))
	var java_max := _java_int(packet_src, "MAX_PACKET_BYTES")
	var frame_max := _java_int(packet_src, "MAX_FRAME_BYTES")
	var header := _java_int(packet_src, "HEADER_BYTES")
	var per_read := _java_int(plugin_src, "MAX_PACKETS_PER_READ")
	if not _h.expect(java_max > 0 and frame_max > 0 and header > 0 and per_read > 0,
			"voice_java_constants_unreadable", "从 Java 源码里读不到包格式常量 —— 常量换了写法，这条门禁要跟着改"):
		return
	var limit := int(NetworkService.VOICE_MAX_PACKET_BYTES)
	_h.expect(java_max <= limit, "voice_packet_over_limit",
		"插件打包上限 %d 字节，超过 ③ 的上限 %d：这种包会被服务端整包丢掉，而且不报错" % [java_max, limit])
	_h.expect(header + 1 + frame_max <= java_max, "voice_single_frame_over_packet",
		"一个最大的帧（%d 字节）单独成包都放不下（包头 %d + 长度 1 > 上限 %d）" % [frame_max, header, java_max])
	# 常见路径 MTU 1280~1500，扣掉 IP/UDP、DTLS、ENet、RPC 头之后，1000 以内不会被分片。
	_h.expect(limit <= 1000, "voice_limit_near_mtu",
		"VOICE_MAX_PACKET_BYTES = %d 太大：不可靠包一旦被分片，丢一片整包就没了" % limit)
	_h.expect(per_read <= int(VoiceService.MAX_PACKETS_PER_FRAME), "voice_read_batch_drift",
		"插件一次交出 %d 个包，VoiceService 一帧只拆 %d 个：多出来的会被丢掉" % [per_read, int(VoiceService.MAX_PACKETS_PER_FRAME)])


# \b：HEADER_BYTES 不能匹配到 V1_HEADER_BYTES 上。
func _java_int(src: String, name: String) -> int:
	var m := RegEx.create_from_string("\\b" + name + "\\s*=\\s*(\\d+)\\s*;").search(src)
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


# --- 状态保存与还原（下面几条都要改 autoload 上的状态）---------------------------------

func _save_state() -> Dictionary:
	return {
		"plugin": VoiceService._plugin,
		"mode": VoiceService.mode,
		"muted": VoiceService._muted_keys.duplicate(),
		"active": NetworkService.team_active,
		"slot": NetworkService.team_local_slot,
		"states": NetworkService.team_slot_states.duplicate(),
		"profiles": NetworkService.team_seat_profiles.duplicate(true),
	}


func _restore_state(saved: Dictionary) -> void:
	# 先用手上的（假）插件把会话关掉，再换回原来的插件与联机状态。
	VoiceService.set_mode(VoiceService.Mode.OFF)
	VoiceService._plugin = saved.plugin
	VoiceService.mode = int(saved.mode)
	VoiceService._muted_keys = saved.muted
	NetworkService.team_active = bool(saved.active)
	NetworkService.team_local_slot = int(saved.slot)
	NetworkService.team_slot_states = saved.states
	NetworkService.team_seat_profiles = saved.profiles


# --- 8. VoiceService 状态机 ---------------------------------------------------------

func _case_voice_service_state_machine() -> void:
	var saved := _save_state()
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

	# g) 没有麦克风权限：先进「只听」等系统弹窗；拒了停在「只听」并发 mic_permission_result(false)
	#    （界面据此提示去系统设置打开），允许了才开麦
	_h.item()
	fake.permission = false
	var permission_events: Array = []
	var on_permission := func(granted: bool) -> void: permission_events.append(granted)
	VoiceService.mic_permission_result.connect(on_permission)
	VoiceService.set_mode(VoiceService.Mode.LISTEN)
	VoiceService.set_mode(VoiceService.Mode.TALK)
	_h.expect(VoiceService.mode == VoiceService.Mode.LISTEN and not fake.capturing,
		"voice_talk_without_permission", "没有麦克风权限时不能进「开麦」")
	VoiceService._on_permission_result("android.permission.RECORD_AUDIO", false)
	_h.expect(VoiceService.mode == VoiceService.Mode.LISTEN and not fake.capturing and permission_events == [false],
		"voice_permission_denial_silent",
		"系统弹窗里拒绝后要停在「只听」并发 mic_permission_result(false)，实际档位 %d、信号 %s" % [VoiceService.mode, str(permission_events)])
	VoiceService.set_mode(VoiceService.Mode.TALK)
	fake.permission = true
	VoiceService._on_permission_result("android.permission.RECORD_AUDIO", true)
	_h.expect(VoiceService.mode == VoiceService.Mode.TALK and fake.capturing,
		"voice_permission_grant_ignored", "玩家在系统弹窗里允许之后应该进「开麦」")
	VoiceService.mic_permission_result.disconnect(on_permission)

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
	_restore_state(saved)


# --- 9. 屏蔽按人记 ------------------------------------------------------------------

func _case_mutes_follow_player() -> void:
	var saved := _save_state()
	var fake := FakePlugin.new()
	VoiceService._plugin = fake
	VoiceService._muted_keys = {}
	VoiceService.mode = VoiceService.Mode.OFF
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.team_slot_states = ["player", "player", "ai", "player", "player", "empty"]
	NetworkService.team_seat_profiles = {
		1: {"player_name": "小林", "friend_code": "AAAA1111"},
		3: {"player_name": "对面", "friend_code": "CCCC3333"},
	}
	VoiceService.set_mode(VoiceService.Mode.LISTEN)

	_h.item()
	var mates := VoiceService.teammates()
	_h.expect(mates.size() == 1 and int(mates[0].slot) == 1 and str(mates[0].name) == "小林",
		"voice_teammates_wrong",
		"队友名单应只有 1 号位小林（2 号位是 AI，3~5 号位是敌方），实际 %s" % str(mates))

	_h.item()
	var changed := [0]
	var on_mutes := func() -> void: changed[0] += 1
	VoiceService.mutes_changed.connect(on_mutes)
	VoiceService.set_muted(1, true)
	fake.pushed.clear()
	VoiceService._on_voice_received(1, PackedByteArray([1]))
	_h.expect(fake.pushed.is_empty() and changed[0] == 1 and VoiceService.is_muted(1),
		"voice_muted_player_still_heard", "屏蔽 1 号位之后，他的包不能再交给插件，且要发 mutes_changed")

	# 换座位：小林从 1 号位挪到 2 号位，新来的人坐到 1 号位 —— 屏蔽要跟着小林走
	_h.item()
	NetworkService.team_slot_states = ["player", "player", "player", "player", "player", "empty"]
	NetworkService.team_seat_profiles = {
		1: {"player_name": "新来的", "friend_code": "BBBB2222"},
		2: {"player_name": "小林", "friend_code": "AAAA1111"},
	}
	fake.pushed.clear()
	VoiceService._on_voice_received(2, PackedByteArray([1]))
	VoiceService._on_voice_received(1, PackedByteArray([1]))
	_h.expect(fake.pushed == [1], "voice_mute_not_following_player",
		"屏蔽按人（好友码）记：小林换到 2 号位仍然听不到，新坐到 1 号位的人听得到；实际交给插件的座位 %s" % str(fake.pushed))

	_h.item()
	VoiceService.set_muted(2, false)
	fake.pushed.clear()
	VoiceService._on_voice_received(2, PackedByteArray([1]))
	_h.expect(fake.pushed == [2] and not VoiceService.is_muted(2), "voice_unmute_failed", "取消屏蔽后应该重新听得到")

	_h.item()
	NetworkService.team_seat_profiles = {}
	VoiceService.set_muted(1, true)
	_h.expect(VoiceService.member_key(1) == "slot:1" and VoiceService.is_muted(1), "voice_mute_without_profile",
		"资料还没到的队友按座位号屏蔽")

	_h.item()
	NetworkService.team_seat_profiles = {1: {"player_name": "新来的", "friend_code": "BBBB2222"}}
	_h.expect(VoiceService.is_muted(1), "voice_mute_lifted_by_profile",
		"按座位号屏蔽之后他的资料到了，屏蔽不能悄悄解除")
	VoiceService.set_muted(1, false)
	_h.expect(not VoiceService.is_muted(1) and VoiceService._muted_keys.is_empty(), "voice_unmute_left_key",
		"取消屏蔽要把好友码和座位号两条都清掉，实际还剩 %s" % str(VoiceService._muted_keys))

	# 离开房间：座位号那条作废（下个房间同一个座位是别人），好友码那条留着（这局游戏里再碰到他仍然屏蔽）
	_h.item()
	NetworkService.team_seat_profiles = {}
	VoiceService.set_muted(1, true)
	NetworkService.team_seat_profiles = {2: {"player_name": "小林", "friend_code": "AAAA1111"}}
	VoiceService.set_muted(2, true)
	NetworkService.team_active = false
	NetworkService.team_local_slot = -1
	VoiceService._process(VoiceService.LEAVE_GRACE_SEC + 0.1)
	_h.expect(VoiceService._muted_keys.keys() == ["code:AAAA1111"], "voice_seat_mutes_survive_leave",
		"离开房间后按座位号记的屏蔽要清掉、按好友码记的留着；实际 %s" % str(VoiceService._muted_keys.keys()))

	VoiceService.mutes_changed.disconnect(on_mutes)
	_restore_state(saved)


# --- 10. 开麦前说明麦克风用途 ----------------------------------------------------------

func _case_mic_rationale() -> void:
	var saved := _save_state()
	var fake := FakePlugin.new()
	_h.item()
	VoiceService._plugin = null
	_h.expect(not VoiceService.needs_mic_rationale(), "voice_rationale_without_plugin", "没有插件时不该弹麦克风说明")
	VoiceService._plugin = fake
	fake.permission = false
	_h.expect(VoiceService.needs_mic_rationale(), "voice_rationale_missing", "还没有麦克风权限时，开麦前必须先说明用途")
	fake.permission = true
	_h.expect(not VoiceService.needs_mic_rationale(), "voice_rationale_repeated", "已经有权限就不要再弹说明")
	var controls := FileAccess.get_file_as_string("res://ui/components/VoiceControls.gd")
	var body := _function_body(controls, "func request_talk() -> void:")
	_h.expect(body.contains("if VoiceService.needs_mic_rationale():") and body.contains("DialogService.confirm("),
		"voice_rationale_not_wired", "VoiceControls.request_talk 必须先查 needs_mic_rationale 并弹确认框，再请求系统权限")
	_h.expect(_function_body(controls, "func _on_voice_pressed() -> void:").contains("request_talk()"),
		"voice_button_skips_rationale", "语音按钮从「只听」切「开麦」必须走 request_talk（带用途说明），不能直接 cycle_mode")
	_h.expect(_function_body(controls, "func _on_rationale_result(result: String, _request_id: String) -> void:").contains("_awaiting_mic = true")
			and _function_body(controls, "func _on_mic_permission_result(granted: bool) -> void:").contains("DialogService.info("),
		"voice_permission_denied_no_hint",
		"系统权限弹窗里被拒后必须提示去系统设置打开：安卓 11 起拒两次就不再弹窗，点开麦会毫无反应")
	_h.expect(controls.contains("VoiceService.mic_permission_result.connect(_on_mic_permission_result)")
			and controls.contains("VoiceService.mic_permission_result.disconnect(_on_mic_permission_result)"),
		"voice_permission_signal_not_wired", "VoiceControls 要在 build 里连上 mic_permission_result、在 teardown 里断开")
	_restore_state(saved)


# --- 11. 界面接线 --------------------------------------------------------------------

func _case_ui_wired() -> void:
	_h.item()
	var project := FileAccess.get_file_as_string("res://project.godot")
	_h.expect(project.contains("VoiceService=\"*res://scripts/autoload/VoiceService.gd\""),
		"voice_autoload_missing", "project.godot 的 [autoload] 里没有 VoiceService")
	var sources := {
		"Team3v3Lobby.gd": FileAccess.get_file_as_string("res://scenes/menu/Team3v3Lobby.gd"),
		"PrepUI.gd": FileAccess.get_file_as_string("res://scenes/prep/PrepUI.gd"),
		"BattleScreen.gd": FileAccess.get_file_as_string("res://scenes/battle/BattleScreen.gd"),
	}
	for file_name in sources:
		var src := str(sources[file_name])
		_h.expect(src.contains("VoiceControls.new()"), "voice_controls_missing",
			"%s 里没有语音按钮（VoiceControls.new()）" % file_name)
		_h.expect(src.contains("_voice_controls.teardown()"), "voice_controls_not_torn_down",
			"%s 离开时必须调 _voice_controls.teardown() —— VoiceService 是 autoload，活得比界面久" % file_name)
	var battle := str(sources["BattleScreen.gd"])
	_h.expect(battle.contains("\t_setup_voice_controls()"), "voice_battle_not_built", "BattleScreen._ready 没有调 _setup_voice_controls()")
	_h.expect(_function_body(battle, "func _setup_voice_controls() -> void:").contains("not NetworkService.team_active"),
		"voice_battle_offline", "战斗界面的语音按钮只在联机对局里建（单机 / 教学没有队友）")
	_h.expect(not FileAccess.get_file_as_string("res://scenes/menu/MainMenu.gd").contains("voice_spike"),
		"voice_spike_entry_left", "主菜单还留着验证版的「语音测试」入口")
	for path in ["res://scripts/autoload/VoiceService.gd", "res://ui/components/VoiceControls.gd",
			"res://ui/components/VoicePanel.gd", "res://scenes/menu/Team3v3Lobby.gd",
			"res://scenes/prep/PrepUI.gd", "res://scenes/battle/BattleScreen.gd"]:
		_h.expect(load(path) != null, "voice_script_unloadable", "%s 加载失败（解析错误见上面的 SCRIPT ERROR）" % path)


# --- 12. ③ 的语音流量统计 -----------------------------------------------------------

func _case_server_stats() -> void:
	_h.item()
	var src := FileAccess.get_file_as_string(NETWORK_SERVICE_PATH)
	_h.expect(_function_body(src, "func _process(delta: float) -> void:").contains("_voice_stats_tick(delta)"),
		"voice_stats_not_ticked", "服务器 _process 里必须调 _voice_stats_tick(delta)，否则语音流量日志永远不打")
	var submit_body := _function_body(src, "func _rpc_team_voice_submit(packet: PackedByteArray) -> void:")
	for key in ["drop_size", "drop_rate", "drop_no_room", "packets_in", "relayed"]:
		_h.expect(submit_body.contains("_voice_stats[\"%s\"]" % key), "voice_stats_not_counted",
			"_rpc_team_voice_submit 没有记 %s" % key)
	var saved_stats: Dictionary = NetworkService._voice_stats.duplicate()
	var saved_elapsed: float = NetworkService._voice_stats_elapsed
	NetworkService._voice_stats_elapsed = 0.0
	NetworkService._voice_stats["packets_in"] = 5
	NetworkService._voice_stats["bytes_in"] = 1500
	NetworkService._voice_stats_tick(1.0)
	_h.expect(int(NetworkService._voice_stats["packets_in"]) == 5, "voice_stats_flushed_early",
		"统计窗口没到就清零了")
	NetworkService._voice_stats_tick(NetworkService.VOICE_STATS_INTERVAL_SEC)
	_h.expect(int(NetworkService._voice_stats["packets_in"]) == 0 and NetworkService._voice_stats_elapsed == 0.0,
		"voice_stats_not_flushed", "统计窗口到点后必须打日志并清零")
	NetworkService._voice_stats = saved_stats
	NetworkService._voice_stats_elapsed = saved_elapsed
