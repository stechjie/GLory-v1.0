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
#  11. 🔴 电脑版（scripts/voice/）：方法表与插件一致；参数与 Java 一致；ADPCM 与 Java 逐字节一致
#      （Java 跑出来的样本 tools/fixtures/voice_adpcm_golden.json）；包格式同 VoicePacket.java；
#      说话检测 → 预录 → 打包的流程；接收缓冲；手机不开 Godot 自带录音
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
# 电脑版（2026-09-17 试用版）
const DESKTOP_BACKEND := preload("res://scripts/voice/DesktopVoiceBackend.gd")
const VOICE_ADPCM := preload("res://scripts/voice/VoiceAdpcm.gd")
const VOICE_PACKET := preload("res://scripts/voice/VoicePacketCodec.gd")
const ADPCM_GOLDEN_PATH := "res://tools/fixtures/voice_adpcm_golden.json"

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
	_case_desktop_contract()
	_case_desktop_adpcm_golden()
	_case_desktop_packets()
	_case_desktop_capture_pipeline()
	_case_desktop_jitter()
	_case_desktop_wiring()
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


# --- 3. 🔴 安卓导出无条件带语音 --------------------------------------------------------
#
# 2026-09-18：预设里那个 glory_voice/enabled 开关**删掉了**。它两次让语音悄悄从包里消失
# （09-14「只在一台电脑开」、09-17「靠仓库模板」——而 export_presets.cfg 在 .gitignore 里，
# 模板覆盖不了同事机器上已有的那份）。现在只剩两种结果：包里有语音，或者导出直接报错。

func _case_export_plugin_off_by_default() -> void:
	_h.item()
	var src := FileAccess.get_file_as_string(EXPORT_PLUGIN_PATH)
	_h.expect(src.contains("return PackedStringArray([AAR])") and not src.contains("get_option("),
		"voice_export_optional_again",
		"安卓导出必须无条件交出 GloryVoice.aar —— 一旦又变成「看预设里的开关」，"
		+ "某台机器上没勾就会出一个装上去才发现没语音的包（p27–p30 就是这么来的）")
	_h.expect(not src.contains("_get_export_options"), "voice_export_option_back",
		"不要再加 glory_voice/enabled 这种预设开关：它在 .gitignore 的文件里，每台机器各一份")
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


# 形如 `NAME = 0.006f;`。读不到返回 -1。
func _java_float(src: String, name: String) -> float:
	var m := RegEx.create_from_string("\\b" + name + "\\s*=\\s*([0-9.]+)f?\\s*;").search(src)
	return float(m.get_string(1)) if m != null else -1.0


# 形如 `NAME = { 1, 2, -3, }` 的整数数组。
func _java_int_array(src: String, name: String) -> Array[int]:
	var out: Array[int] = []
	var m := RegEx.create_from_string("\\b" + name + "\\s*=\\s*\\{([^}]*)\\}").search(src)
	if m == null:
		return out
	for part in m.get_string(1).split(","):
		var text := part.strip_edges()
		if not text.is_empty():
			out.append(int(text))
	return out


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


# --- 11. 🔴 电脑版（scripts/voice/，2026-09-17 试用版）----------------------------------
#
# 电脑和手机要互相听得见，靠的是「包格式、编码、参数」三样完全一致。任何一样对不上都不会报错，
# 只会变成杂音、断断续续、或者干脆没声音。所以这里全部拿 Java 源码与 Java 跑出来的样本对账。

func _case_desktop_contract() -> void:
	# 方法表：VoiceService 只认假插件里那几个名字。电脑版少一个、参数个数不对，都是运行时才炸。
	# 先放进 Script 变量：解析器不让在类名上直接调 get_script_method_list()。
	var fake_script: Script = FakePlugin
	var backend_script: Script = DESKTOP_BACKEND
	var wanted := {}
	for method in fake_script.get_script_method_list():
		wanted[str(method.name)] = (method.args as Array).size()
	var have := {}
	for method in backend_script.get_script_method_list():
		have[str(method.name)] = (method.args as Array).size()
	for method_name in wanted:
		_h.item()
		_h.expect(have.has(method_name) and int(have[method_name]) == int(wanted[method_name]),
			"voice_desktop_method_missing",
			"电脑版后端缺少方法或参数个数不对：%s（要 %d 个参数）" % [method_name, int(wanted[method_name])])

	var src_dir := PLUGIN_DIR.path_join("src/com/glory/voice")
	var plugin_src := FileAccess.get_file_as_string(src_dir.path_join("GloryVoicePlugin.java"))
	var remote_src := FileAccess.get_file_as_string(src_dir.path_join("RemoteStream.java"))
	var packet_src := FileAccess.get_file_as_string(src_dir.path_join("VoicePacket.java"))
	var codec_src := FileAccess.get_file_as_string(src_dir.path_join("FrameCodec.java"))
	var adpcm_src := FileAccess.get_file_as_string(src_dir.path_join("AdpcmCodec.java"))
	var ints := [
		[plugin_src, "SLOTS", DESKTOP_BACKEND.SLOTS],
		[plugin_src, "FRAMES_PER_PACKET", DESKTOP_BACKEND.FRAMES_PER_PACKET],
		[plugin_src, "MAX_QUEUED_PACKETS", DESKTOP_BACKEND.MAX_QUEUED_PACKETS],
		[plugin_src, "MAX_PACKETS_PER_READ", DESKTOP_BACKEND.MAX_PACKETS_PER_READ],
		[plugin_src, "VAD_HANGOVER_FRAMES", DESKTOP_BACKEND.VAD_HANGOVER_FRAMES],
		[plugin_src, "VAD_PREROLL_FRAMES", DESKTOP_BACKEND.VAD_PREROLL_FRAMES],
		[remote_src, "START_FRAMES", DESKTOP_BACKEND.Remote.START_FRAMES],
		[remote_src, "MAX_QUEUED_FRAMES", DESKTOP_BACKEND.Remote.MAX_QUEUED_FRAMES],
		[remote_src, "IDLE_RESET_MS", DESKTOP_BACKEND.Remote.IDLE_RESET_MS],
		[remote_src, "SHORT_SPURT_WAIT_MS", DESKTOP_BACKEND.Remote.SHORT_SPURT_WAIT_MS],
		[packet_src, "VERSION_V1", VOICE_PACKET.VERSION_V1],
		[packet_src, "VERSION", VOICE_PACKET.VERSION],
		[packet_src, "V1_HEADER_BYTES", VOICE_PACKET.V1_HEADER_BYTES],
		[packet_src, "HEADER_BYTES", VOICE_PACKET.HEADER_BYTES],
		[packet_src, "FLAG_SPURT_START", VOICE_PACKET.FLAG_SPURT_START],
		[packet_src, "MAX_FRAMES", VOICE_PACKET.MAX_FRAMES],
		[packet_src, "MAX_FRAME_BYTES", VOICE_PACKET.MAX_FRAME_BYTES],
		[packet_src, "MAX_PACKET_BYTES", VOICE_PACKET.MAX_PACKET_BYTES],
		[codec_src, "ADPCM", VOICE_PACKET.CODEC_ADPCM],
		[codec_src, "OPUS", VOICE_PACKET.CODEC_OPUS],
		[adpcm_src, "SAMPLE_RATE", VOICE_ADPCM.SAMPLE_RATE],
		[adpcm_src, "FRAME_SAMPLES", VOICE_ADPCM.FRAME_SAMPLES],
	]
	for row in ints:
		_h.item()
		var java_value := _java_int(str(row[0]), str(row[1]))
		_h.expect(java_value >= 0 and java_value == int(row[2]), "voice_desktop_const_drift",
			"%s：Java 是 %d，电脑版是 %d —— 两边分开改不会报错，只会手机和电脑互相听不清"
				% [str(row[1]), java_value, int(row[2])])
	var floats := [
		["VAD_MIN_THRESHOLD", DESKTOP_BACKEND.VAD_MIN_THRESHOLD],
		["VAD_MAX_THRESHOLD", DESKTOP_BACKEND.VAD_MAX_THRESHOLD],
		["SPEAKING_LEVEL", DESKTOP_BACKEND.SPEAKING_LEVEL],
	]
	for row in floats:
		_h.item()
		var java_float := _java_float(plugin_src, str(row[0]))
		_h.expect(java_float >= 0.0 and is_equal_approx(java_float, float(row[1])), "voice_desktop_const_drift",
			"%s：Java 是 %s，电脑版是 %s" % [str(row[0]), str(java_float), str(row[1])])
	_h.item()
	_h.expect(_java_int_array(adpcm_src, "STEP_TABLE") == VOICE_ADPCM.STEP_TABLE, "voice_desktop_table_drift",
		"ADPCM 步长表与 AdpcmCodec.java 不一致")
	_h.item()
	_h.expect(_java_int_array(adpcm_src, "INDEX_TABLE") == VOICE_ADPCM.INDEX_TABLE, "voice_desktop_table_drift",
		"ADPCM 序号表与 AdpcmCodec.java 不一致")


func _case_desktop_adpcm_golden() -> void:
	_h.item()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ADPCM_GOLDEN_PATH))
	if not _h.expect(parsed is Dictionary, "voice_desktop_golden_missing",
			"读不到 %s —— 跑 tools/voice_adpcm_golden.ps1 生成" % ADPCM_GOLDEN_PATH):
		return
	var golden: Dictionary = parsed
	var pcm_bytes := str(golden.get("pcm_le_hex", "")).hex_decode()
	var pcm := PackedInt32Array()
	pcm.resize(pcm_bytes.size() >> 1)
	for i in pcm.size():
		pcm[i] = pcm_bytes.decode_s16(i * 2)
	var blocks: Array = golden.get("blocks_hex", [])
	if not _h.expect(not blocks.is_empty() and pcm.size() == blocks.size() * VOICE_ADPCM.FRAME_SAMPLES,
			"voice_desktop_golden_shape", "样本形状不对：%d 个采样、%d 块" % [pcm.size(), blocks.size()]):
		return
	var state := VOICE_ADPCM.new_state()
	var decoded := PackedByteArray()
	decoded.resize(pcm.size() * 2)
	for f in blocks.size():
		_h.item()
		var mine := VOICE_ADPCM.encode_block(pcm, f * VOICE_ADPCM.FRAME_SAMPLES, state).hex_encode()
		_h.expect(mine == str(blocks[f]), "voice_desktop_adpcm_encode_drift",
			"第 %d 块编码与手机不一致 —— 电脑发给手机的声音会变成杂音" % f)
		var samples := VOICE_ADPCM.decode_block(str(blocks[f]).hex_decode(), 0)
		for i in samples.size():
			decoded.encode_s16((f * VOICE_ADPCM.FRAME_SAMPLES + i) * 2, samples[i])
	_h.item()
	_h.expect(decoded.hex_encode() == str(golden.get("decoded_le_hex", "")), "voice_desktop_adpcm_decode_drift",
		"解手机编出来的块，结果与手机自己解的不一致 —— 手机发给电脑的声音会变成杂音")


func _case_desktop_packets() -> void:
	var state := VOICE_ADPCM.new_state()
	var tone := _tone_frame(6000)
	var b0 := VOICE_ADPCM.encode_block(tone, 0, state)
	var b1 := VOICE_ADPCM.encode_block(tone, 0, state)
	var frames: Array[PackedByteArray] = [b0, b1]
	var packet := VOICE_PACKET.build(0x1234, true, VOICE_PACKET.CODEC_ADPCM, frames)
	_h.item()
	_h.expect(packet.size() == 6 + 2 * (1 + 163) and packet.slice(0, 6) == PackedByteArray([2, 1, 0x34, 0x12, 2, 0])
			and packet[6] == 163 and packet[6 + 164] == 163,
		"voice_desktop_packet_layout",
		"电脑版打出来的包与 VoicePacket.java 的布局不一致：%s" % packet.slice(0, 8).hex_encode())
	var parsed := VOICE_PACKET.parse(packet)
	_h.item()
	_h.expect(not parsed.is_empty() and int(parsed.seq) == 0x1234 and bool(parsed.spurt_start)
			and int(parsed.codec) == VOICE_PACKET.CODEC_ADPCM and (parsed.frames as Array).size() == 2
			and parsed.frames[0] == b0 and parsed.frames[1] == b1,
		"voice_desktop_packet_roundtrip", "自己打的包自己解不回来")
	# 手机发的 Opus 包（帧长不定）要能认出来 —— 电脑版不放，但要知道那是 Opus，好提示测试的人。
	var opus_frames: Array[PackedByteArray] = [PackedByteArray([1, 2, 3]), PackedByteArray([4, 5, 6, 7, 8])]
	var opus := VOICE_PACKET.build(7, false, VOICE_PACKET.CODEC_OPUS, opus_frames)
	var parsed_opus := VOICE_PACKET.parse(opus)
	_h.item()
	_h.expect(not parsed_opus.is_empty() and int(parsed_opus.codec) == VOICE_PACKET.CODEC_OPUS,
		"voice_desktop_opus_unrecognized", "认不出手机发的 Opus 包")
	# v1 包（09-13 第一版）照样能解
	var v1 := PackedByteArray([1, 0, 5, 0, 1])
	v1.append_array(b0)
	var parsed_v1 := VOICE_PACKET.parse(v1)
	_h.item()
	_h.expect(not parsed_v1.is_empty() and int(parsed_v1.seq) == 5 and parsed_v1.frames[0] == b0,
		"voice_desktop_v1_rejected", "解不了 v1 包")
	# 坏包一律拒（照 VoicePacket.parse 的规则：长度必须正好对上）
	var one_more := packet.duplicate()
	one_more.append(0)
	var bad := {
		"少一个字节": packet.slice(0, packet.size() - 1),
		"多一个字节": one_more,
		"帧数为 0": _patched(packet, 4, 0),
		"帧数为 4": _patched(packet, 4, 4),
		"未知编码": _patched(packet, 5, 7),
		"未知版本": _patched(packet, 0, 3),
		"ADPCM 帧长不是 163": _patched(packet, 6, 162),
		"Opus 帧长为 0": _patched(opus, 6, 0),
		"太短": PackedByteArray([2, 0, 0, 0, 1]),
	}
	for label in bad:
		_h.item()
		_h.expect(VOICE_PACKET.parse(bad[label]).is_empty(), "voice_desktop_bad_packet_accepted",
			"坏包没被拒：%s" % label)


func _case_desktop_capture_pipeline() -> void:
	var backend: DESKTOP_BACKEND = DESKTOP_BACKEND.new()
	add_child(backend)
	_h.item()
	_h.expect(backend.setCapture(true) == "no_session", "voice_desktop_capture_without_session",
		"没开语音就开麦，应该返回 no_session")
	backend.startSession(true)
	var silence := PackedInt32Array()
	silence.resize(VOICE_ADPCM.FRAME_SAMPLES)
	for _i in 10:
		backend._on_capture_frame(silence.duplicate())
	_h.item()
	_h.expect(backend.readPackets().is_empty(), "voice_desktop_sends_silence", "没说话也发包了")

	var tone := _tone_frame(8000)
	for _i in 6:
		backend._on_capture_frame(tone.duplicate())
	for _i in 25:
		backend._on_capture_frame(silence.duplicate())
	var packets: Array[PackedByteArray] = []
	for _round in 3:
		packets.append_array(VoiceService.split_packets(backend.readPackets()))
	# 预录 2 帧 + 说话 6 帧 + 拖尾 19 帧（第 20 帧静音时拖尾到期）= 27 帧，每包 2 帧 → 14 个包，最后一个 1 帧。
	_h.item()
	var count_ok := _h.expect(packets.size() == 14, "voice_desktop_packet_count",
		"应打出 14 个包（预录 2 + 说话 6 + 拖尾 19 帧），实际 %d —— 说话检测或打包与手机不一致" % packets.size())
	if count_ok:
		var first := VOICE_PACKET.parse(packets[0])
		_h.item()
		_h.expect(not first.is_empty() and bool(first.spurt_start) and int(first.seq) == 0
				and int(first.codec) == VOICE_PACKET.CODEC_ADPCM,
			"voice_desktop_first_packet", "第一个包应带「一段话开头」标志、序号 0、ADPCM")
		_h.item()
		_h.expect(not first.is_empty() and first.frames[0].slice(0, 3) == PackedByteArray([0, 0, 0]),
			"voice_desktop_encoder_not_reset", "一段话开头编码器没有归零（第一帧的块头应是 0,0,0）")
		_h.item()
		var second := VOICE_PACKET.parse(packets[1])
		_h.expect(not first.is_empty() and not second.is_empty()
				and VOICE_ADPCM.rms(VOICE_ADPCM.decode_block(first.frames[0], 0)) < 0.001
				and VOICE_ADPCM.rms(VOICE_ADPCM.decode_block(second.frames[0], 0)) > 0.02,
			"voice_desktop_preroll_missing", "开头应先发 2 帧预录（静音），第 3 帧才是说话")
		var seq_ok := true
		var total_frames := 0
		for i in packets.size():
			var p := VOICE_PACKET.parse(packets[i])
			if p.is_empty() or int(p.seq) != total_frames or (i > 0 and bool(p.spurt_start)):
				seq_ok = false
				break
			total_frames += (p.frames as Array).size()
		_h.item()
		_h.expect(seq_ok and total_frames == 27, "voice_desktop_seq_broken",
			"序号不连续、中途又出现「开头」标志、或总帧数不是 27（实际 %d）" % total_frames)
		_h.item()
		_h.expect((VOICE_PACKET.parse(packets[13]).get("frames", []) as Array).size() == 1,
			"voice_desktop_tail_not_flushed", "说完之后没把凑了一半的包发出去")
	var st: Dictionary = JSON.parse_string(backend.getStatus())
	_h.item()
	_h.expect(str(st.get("platform", "")) == "desktop" and st.has("speaking_slots") and st.has("mic_active")
			and str(st.get("codec", "")) == "adpcm" and st.has("output_device"),
		"voice_desktop_status_shape", "状态字段不全：%s" % str(st.keys()))
	backend.stopSession()
	backend.queue_free()


func _case_desktop_jitter() -> void:
	var state := VOICE_ADPCM.new_state()
	var tone := _tone_frame(8000)
	var r: DESKTOP_BACKEND.Remote = DESKTOP_BACKEND.Remote.new()
	var t := 10000
	r.push(_adpcm_packet(0, true, tone, state), t)
	_h.item()
	_h.expect(r.pull(t).is_empty(), "voice_desktop_jitter_no_buffering", "只到了 2 帧、还没过 60 毫秒，不该开始放")
	_h.item()
	_h.expect(not r.pull(t + DESKTOP_BACKEND.Remote.SHORT_SPURT_WAIT_MS).is_empty() and r.level > DESKTOP_BACKEND.SPEAKING_LEVEL,
		"voice_desktop_short_spurt_stuck", "短句等过 60 毫秒应该直接放，而且算「在说话」")
	r.push(_adpcm_packet(6, false, tone, state), t + 40)
	_h.item()
	_h.expect(r.frames_lost == 4, "voice_desktop_loss_not_counted", "序号从 2 跳到 6，应记丢 4 帧，实际 %d" % r.frames_lost)
	r.push(_adpcm_packet(2, false, tone, state), t + 60)
	_h.item()
	_h.expect(r.packets_late == 1, "voice_desktop_late_played", "比已收到的还旧的包应该丢掉")
	var before := r.ring.size()
	var opus_frames: Array[PackedByteArray] = [PackedByteArray([1, 2, 3])]
	r.push(VOICE_PACKET.build(8, false, VOICE_PACKET.CODEC_OPUS, opus_frames), t + 80)
	_h.item()
	_h.expect(r.opus_dropped == 1 and r.ring.size() == before, "voice_desktop_opus_played",
		"电脑版解不了 Opus：应记一笔、不放")
	r.push(PackedByteArray([9, 9, 9]), t + 90)
	_h.item()
	_h.expect(r.packets_bad == 1, "voice_desktop_bad_not_counted", "坏包应记一笔")

	var big: DESKTOP_BACKEND.Remote = DESKTOP_BACKEND.Remote.new()
	for n in 11:
		big.push(_adpcm_packet(n * 2, n == 0, tone, state), t + n)
	_h.item()
	_h.expect(big.ring.size() == DESKTOP_BACKEND.Remote.MAX_QUEUED_FRAMES and big.frames_dropped == 2,
		"voice_desktop_backlog_unbounded", "最多压 20 帧（400 毫秒），多的丢最老的：实际压了 %d、丢了 %d"
			% [big.ring.size(), big.frames_dropped])


func _case_desktop_wiring() -> void:
	var service_src := FileAccess.get_file_as_string("res://scripts/autoload/VoiceService.gd")
	_h.item()
	_h.expect(service_src.contains("DesktopVoiceBackend.new()") and service_src.contains("OS.has_feature(\"windows\")")
			and service_src.contains("DisplayServer.get_name() != \"headless\""),
		"voice_desktop_not_wired", "VoiceService 没在 Windows（有界面时）挂上电脑版后端")
	var project := FileAccess.get_file_as_string("res://project.godot")
	_h.item()
	_h.expect(project.contains("driver/enable_input.windows=true"), "voice_desktop_input_off",
		"project.godot 没对 Windows 打开录音输入 —— 电脑版开麦会报「麦克风打不开」")
	# 🔴 手机不能开 Godot 自带的录音：它不设录音模式，拿不到系统回声消除。手机录音一律走插件。
	_h.item()
	_h.expect(RegEx.create_from_string("(?m)^driver/enable_input(\\.android)?\\s*=\\s*true").search(project) == null,
		"voice_desktop_input_global", "录音输入只能对 Windows 打开（.windows），不能全局或对安卓打开")
	if OS.has_feature("windows"):
		_h.item()
		_h.expect(DESKTOP_BACKEND.input_enabled(), "voice_desktop_override_ignored",
			"Windows 上读到的 enable_input 不是 true：.windows 覆盖没生效")


func _tone_frame(amplitude: int) -> PackedInt32Array:
	var frame := PackedInt32Array()
	frame.resize(VOICE_ADPCM.FRAME_SAMPLES)
	for i in frame.size():
		frame[i] = amplitude if (i % 20) < 10 else -amplitude
	return frame


func _adpcm_packet(seq: int, spurt: bool, frame: PackedInt32Array, state: Array[int]) -> PackedByteArray:
	var frames: Array[PackedByteArray] = [
		VOICE_ADPCM.encode_block(frame, 0, state),
		VOICE_ADPCM.encode_block(frame, 0, state),
	]
	return VOICE_PACKET.build(seq, spurt, VOICE_PACKET.CODEC_ADPCM, frames)


func _patched(src: PackedByteArray, index: int, value: int) -> PackedByteArray:
	var out := src.duplicate()
	out[index] = value
	return out
