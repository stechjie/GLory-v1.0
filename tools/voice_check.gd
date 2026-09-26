extends Node

# 游戏内组队语音（docs/语音LiveKit方案.md —— 2026-09-19 起改用 LiveKit 自建）的门禁。
#
# 验不了的：真的连上 LiveKit、回声、延迟、断续 —— 要真服务器、真手机（方案第七节第 1、2 阶段的验收）。
# 这里钉的是几件「不报错、只是坏」的事：
#   1. 插件包 GloryVoice.aar 是照着现在的 Kotlin 源码与 Gradle 配置打的
#   2. 插件包清单：Godot 找插件用的 meta-data、两条权限、minSdkVersion
#   3. 🔴 安卓导出无条件带语音插件和 LiveKit（三处版本号一致）、去掉 LiveKit 带来的摄像头 / 屏幕录制；
#      仓库里的导出模板打开 Gradle 构建；安卓桥接（Kotlin）的方法、状态字段与 VoiceService 对得上
#   3b. 电脑版桥接（C++ 扩展，docs/语音LiveKit方案.md 5.2）：方法、状态字段、单例名对得上；
#      dll 是照着现在的源码编的；扩展声明的文件都在；LiveKit 开发包版本两处一致
#   4. 🔴 钥匙：签名与 JWT 标准样例逐字节一致；只能进「本房间本队」的语音房间、只准发麦克风、10 分钟
#   5. 🔴 发钥匙的规矩：谁、哪队一律从连接反查；没座位、AI 座位、服务器没配语音都不发；敌方拿不到本队的钥匙
#   6. 🔴 踢人：换座跨队、离开 / 被踢、座位被 AI 接管都要请出语音房间，关房删两队的语音房间；
#      对局中掉线保留座位**不踢**
#   7. 旧的语音转发（语音包经战斗服务器）和电脑试用版删干净了；语音密钥不进客户端
#   8. VoiceService 状态机（假桥接）：麦克风不自己打开、要钥匙 / 进房 / 开麦、换队重连、连不上退避重试、
#      切后台断开、离开房间自动关；安卓那种「声音模式进房时定」的桥接：换档重进、钥匙再用、麦克风打不开退回只听
#   9. 屏蔽按人（好友码）记、换座位跟着人走 = 让桥接把这个人的音量设成 0
#  10. 没权限时开麦前先说明用途；大厅 / 备战期 / 战斗界面都接上了按钮
#
# 运行：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . res://tools/voice_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const RateLimitService := preload("res://scripts/multiplayer/RateLimitService.gd")
const DedicatedServerService := preload("res://scripts/multiplayer/DedicatedServerService.gd")
const LiveKitAuth := preload("res://scripts/voice/LiveKitAuth.gd")

const CHECK_NAME := "voice"
const AAR_PATH := "res://addons/glory_voice/bin/GloryVoice.aar"
const PLUGIN_DIR := "res://android_plugins/glory_voice"
const EXPORT_PLUGIN_PATH := "res://addons/glory_voice/glory_voice_plugin.gd"
const KOTLIN_BRIDGE_PATH := "res://android_plugins/glory_voice/src/com/glory/voice/GloryVoicePlugin.kt"
const GRADLE_PATH := "res://android_plugins/glory_voice/build.gradle.kts"
# 进源码指纹的文件（与 build_aar.ps1 的 $projectFiles 一致），外加 src/ 下全部 .kt。
const PLUGIN_PROJECT_FILES := ["AndroidManifest.xml", "proguard.txt", "build.gradle.kts", "settings.gradle.kts", "gradle.properties"]
# VoiceService 读的状态字段 / 能力字段：安卓桥接必须都给（在 Kotlin 源码里对账）。
const BRIDGE_STATUS_KEYS := ["state", "error", "mic_on", "mic_error", "self_speaking", "speaking", "participants", "audio_mode", "output"]
const BRIDGE_CAPABILITY_KEYS := ["platform", "sdk", "aec", "listen_mode_fixed_at_join"]
const DESKTOP_DIR := "res://native/glory_voice_desktop"
const DESKTOP_CPP_PATH := "res://native/glory_voice_desktop/src/glory_voice_desktop.cpp"
const DESKTOP_GDEXTENSION_PATH := "res://addons/glory_voice/glory_voice.gdextension"
const DESKTOP_BIN_DIR := "res://addons/glory_voice/bin/windows"
const NETWORK_SERVICE_PATH := "res://scripts/autoload/NetworkService.gd"
# 只在门禁里用的假配置（secret ≥ 32 个字符）。
const TEST_CONFIG := {
	"client_url": "wss://voice.example.test",
	"admin_url": "http://127.0.0.1:7880",
	"api_key": "APIvoicecheck",
	"api_secret": "voice-check-secret-0123456789abcdefghij",
}

var _h: CheckHarness


# 假桥接：方法与 VoiceService.BRIDGE_METHODS 同名同参（第 2~4 阶段的真桥接照同一张表实现）。
class FakeBridge extends RefCounted:
	var permission := true
	var join_error := ""
	var mic_error := ""
	# 安卓桥接那种「声音模式只能在进房时定」（getCapabilities 的 listen_mode_fixed_at_join）
	var listen_fixed := false
	# 开麦受理了、麦克风却异步打不开（getStatus 的 mic_error）
	var mic_error_async := ""
	var joins := 0
	var joined := false
	var join_args: Array = []
	var leaves := 0
	var mic_on := false
	var state := "connected"
	var error := ""
	var speaking: Array = []
	var self_speaking := false
	var participants: Array = []
	var volumes: Dictionary = {}

	func hasRecordPermission() -> bool:
		return permission

	func joinRoom(url: String, token: String, listen_only: bool) -> String:
		if not join_error.is_empty():
			return join_error
		joined = true
		joins += 1
		join_args = [url, token, listen_only]
		mic_on = false
		return ""

	func leaveRoom() -> void:
		joined = false
		mic_on = false
		leaves += 1

	func setMicrophoneEnabled(enabled: bool) -> String:
		if enabled and not mic_error.is_empty():
			return mic_error
		mic_on = enabled
		return ""

	func setParticipantVolume(identity: String, volume: float) -> void:
		volumes[identity] = volume

	func getStatus() -> String:
		return JSON.stringify({
			"state": state if joined else "disconnected",
			"error": error,
			"mic_on": mic_on,
			"mic_error": mic_error_async if mic_on else "",
			"self_speaking": self_speaking,
			"speaking": speaking,
			"participants": participants,
			"audio_mode": "call" if mic_on else "media",
			"output": "speaker",
		})

	func getCapabilities() -> String:
		return JSON.stringify({"platform": "fake", "sdk": "test", "aec": "webrtc", "listen_mode_fixed_at_join": listen_fixed})


class FakeIOSBridge extends FakeBridge:
	var permission_requests := 0
	var permission_state := "undetermined"

	func requestRecordPermission() -> void:
		permission_requests += 1
		permission_state = "prompting"

	func getStatus() -> String:
		var result: Dictionary = JSON.parse_string(super.getStatus())
		result.permission = permission_state
		return JSON.stringify(result)


# 假的 LiveKit 管理接口：只记账（战斗服务器上是 scripts/voice/LiveKitAdmin.gd）。
class FakeAdmin extends RefCounted:
	var removed: Array = []
	var deleted: Array = []

	func remove_participant(room: String, identity: String) -> void:
		removed.append([room, identity])

	func delete_room(room: String) -> void:
		deleted.append(room)


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_aar_matches_source()
	_case_aar_local_headers()
	_case_aar_manifest()
	_case_export_plugin_off_by_default()
	_case_export_livekit()
	_case_template_ships_voice()
	_case_jwt_vector()
	_case_join_token()
	_case_admin_token()
	_case_config_loader()
	_case_token_policy()
	_case_rpc_contract()
	_case_kick_hooks()
	_case_old_transport_removed()
	_case_bridge_contract()
	_case_kotlin_bridge_contract()
	_case_desktop_bridge_contract()
	_case_desktop_build()
	_case_state_machine()
	_case_ios_permission()
	_case_state_machine_fixed_listen_mode()
	_case_mutes_follow_player()
	_case_mic_rationale()
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
		("插件包不是照着现在的源码打的（包里 %s…，源码 %s…）。改了 Kotlin / 清单 / Gradle 配置 / 保留规则之后"
			+ "要重跑 android_plugins/glory_voice/build_aar.ps1。") % [recorded.left(12), actual.left(12)])


# 与 build_aar.ps1 完全同一个算法：「相对路径:sha256」逐行、按码点排序、\n 连接，再 SHA-256。
func _source_digest() -> String:
	var rel := PackedStringArray(PLUGIN_PROJECT_FILES)
	_collect_sources(PLUGIN_DIR.path_join("src"), "src", rel)
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


func _collect_sources(dir_path: String, rel_prefix: String, out: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_collect_sources(dir_path.path_join(sub), rel_prefix + "/" + sub, out)
	for file in dir.get_files():
		if file.ends_with(".kt"):
			out.append(rel_prefix + "/" + file)


# 按顺序走一遍插件包的本地文件头（Gradle 解 aar 用的就是这种顺序读法，不看末尾的目录）。
# 2026-09-19 出过的事：打包脚本用 .NET 的「就地更新」补写指纹，把空的 R.txt 重写成「不压缩」却仍记着
# 压缩后的 2 字节 —— ZIPReader 照样能读（它看末尾的目录），出包时 Gradle 却在这里停下，
# AndroidManifest.xml 没解出来，导出只报一个路径。所以这里逐项对「不压缩的项：记录大小 = 实际大小」。
func _case_aar_local_headers() -> void:
	var bytes := FileAccess.get_file_as_bytes(AAR_PATH)
	_h.item()
	if not _h.expect(bytes.size() > 30, "aar_missing", "没有 %s" % AAR_PATH):
		return
	var names := PackedStringArray()
	var bad := PackedStringArray()
	var at := 0
	while at + 30 <= bytes.size() and bytes.decode_u32(at) == 0x04034b50:
		var flags := bytes.decode_u16(at + 6)
		var method := bytes.decode_u16(at + 8)
		var csize := bytes.decode_u32(at + 18)
		var usize := bytes.decode_u32(at + 22)
		var name_len := bytes.decode_u16(at + 26)
		var extra_len := bytes.decode_u16(at + 28)
		var entry_name := bytes.slice(at + 30, at + 30 + name_len).get_string_from_utf8()
		names.append(entry_name)
		if flags & 0x8:
			bad.append("%s（大小写在数据之后，顺序读法拿不到）" % entry_name)
			break
		if method == 0 and csize != usize:
			bad.append("%s（不压缩，却记着 %d / %d 字节）" % [entry_name, csize, usize])
		at += 30 + name_len + extra_len + csize
	_h.expect(bad.is_empty() and names.has("AndroidManifest.xml") and names.has("classes.jar"),
		"aar_stream_unreadable",
		"插件包按顺序读不完整（出包时 Gradle 会解不出清单，导出失败）：%s；读到 %s" % [", ".join(bad), str(names)])


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
	# 库清单里 minSdk、targetSdk 都没有时，清单合并按 1 算，会给整个应用加上 READ_PHONE_STATE 等隐含权限。
	# AGP 从 build.gradle.kts 的 minSdk 写进来；只要它在，targetSdk 缺省就按它算（24），不会加。
	_h.expect(manifest.contains("android:minSdkVersion"), "aar_no_min_sdk",
		"插件包清单没有 minSdkVersion：清单合并会给整个应用加上 READ_PHONE_STATE 等隐含权限")
	var bundled_livekit := false
	for f in files:
		if str(f).begins_with("io/livekit/") or str(f).begins_with("jni/"):
			bundled_livekit = true
	_h.expect(not bundled_livekit, "aar_bundles_livekit",
		"插件包里不该带 LiveKit / WebRTC 本身（compileOnly；APK 里那份由导出插件的依赖提供，带两份会冲突）")


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
	# iOS purpose text uses _get_export_options_overrides; that does not
	# introduce an optional export toggle. Match the option-list hook exactly.
	var optional_options := RegEx.create_from_string("func\\s+_get_export_options\\s*\\(")
	_h.expect(optional_options.search(src) == null, "voice_export_option_back",
		"不要再加 glory_voice/enabled 这种预设开关：它在 .gitignore 的文件里，每台机器各一份")
	_h.expect(load(EXPORT_PLUGIN_PATH) != null, "voice_export_plugin_broken",
		"导出插件脚本加载失败：%s" % EXPORT_PLUGIN_PATH)


# LiveKit 本身不在插件包里，由导出插件交给出包时的 Gradle 下载。三处版本号必须一样：
#   build.gradle.kts（编译桥接用的）、导出插件（打进 APK 的）、GloryVoicePlugin.kt 的 LIVEKIT_VERSION（报给界面的）。
# 不一样的话，桥接是照 A 版编的、APK 里跑的是 B 版 —— 方法签名一变就是运行时 NoSuchMethodError，桌面上看不出来。
func _case_export_livekit() -> void:
	var export_src := FileAccess.get_file_as_string(EXPORT_PLUGIN_PATH)
	var gradle_src := FileAccess.get_file_as_string(GRADLE_PATH)
	var kotlin_src := FileAccess.get_file_as_string(KOTLIN_BRIDGE_PATH)
	var re := RegEx.create_from_string("io\\.livekit:livekit-android:([0-9][0-9.]*)")
	var export_ver := re.search(export_src)
	var gradle_ver := re.search(gradle_src)
	var kotlin_ver := RegEx.create_from_string("LIVEKIT_VERSION = \"([0-9][0-9.]*)\"").search(kotlin_src)
	_h.item()
	_h.expect(export_ver != null and gradle_ver != null and kotlin_ver != null
			and export_ver.get_string(1) == gradle_ver.get_string(1) and gradle_ver.get_string(1) == kotlin_ver.get_string(1),
		"voice_livekit_version_drift", "LiveKit 版本号三处不一致（导出插件 %s / build.gradle.kts %s / Kotlin %s）" % [
			export_ver.get_string(1) if export_ver != null else "?", gradle_ver.get_string(1) if gradle_ver != null else "?",
			kotlin_ver.get_string(1) if kotlin_ver != null else "?"])
	_h.item()
	_h.expect(export_src.contains("func _get_android_dependencies(") and export_src.contains("return PackedStringArray([LIVEKIT])")
			and gradle_src.contains("compileOnly(\"io.livekit:livekit-android:"),
		"voice_livekit_not_exported",
		"导出插件要无条件把 LiveKit 交给出包的 Gradle（_get_android_dependencies），桥接编译时 LiveKit 只能 compileOnly")
	_h.item()
	_h.expect(export_src.contains("func _get_android_dependencies_maven_repos(") and export_src.contains("\"https://jitpack.io\"")
			and FileAccess.get_file_as_string("res://android_plugins/glory_voice/settings.gradle.kts").contains("includeGroup(\"com.github.davidliu\")"),
		"voice_jitpack_missing",
		"LiveKit 依赖的 audioswitch 只在 JitPack 上：导出插件要交出 JitPack 仓库，否则出包时 Gradle 找不到依赖；"
		+ "编译桥接时 JitPack 只准拿 com.github.davidliu 这一组")
	# 🔴 LiveKit 自己的清单带着摄像头和屏幕录制前台服务：摄像头会出现在 Play 的应用信息里，
	# 屏幕录制前台服务要在 Play 管理中心单独申报。只用语音，一样都不要。
	for permission in ["android.permission.CAMERA", "android.permission.FOREGROUND_SERVICE",
			"android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION"]:
		_h.item()
		_h.expect(export_src.contains("\"%s\"" % permission) and export_src.contains("tools:node=\"remove\""),
			"voice_unwanted_permission_kept", "导出插件没有在应用清单里去掉 LiveKit 带来的 %s" % permission)
	_h.item()
	_h.expect(export_src.contains("io.livekit.android.room.track.screencapture.ScreenCaptureService")
			and export_src.contains("func _get_android_manifest_application_element_contents("),
		"voice_screen_capture_service_kept", "导出插件没有在应用清单里去掉 LiveKit 的屏幕录制服务")
	# 生成的片段本身（EditorExportPlugin 只能在编辑器里实例化，门禁里跑不了，只能按源码核对）。
	_h.item()
	_h.expect(export_src.contains("'<uses-permission android:name=\"%s\" tools:node=\"remove\" />' % permission")
			and export_src.contains("'<service android:name=\"%s\" tools:node=\"remove\" />' % REMOVED_SERVICE"),
		"voice_manifest_snippet_wrong", "导出插件生成的清单片段必须是 tools:node=\"remove\" 的 uses-permission / service")


# 语音插件只能用 Gradle 构建打进包。有人从一台没开 Gradle 的电脑重新生成模板，这里就红。
# （原来还钉着 glory_voice/enabled：那个预设开关 09-18 已经删了，导出插件不再读它，这里也不再要求。）
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
			+ "从这份模板出的包会导出失败")


# --- 4. 🔴 钥匙 ------------------------------------------------------------------------

# jwt.io 首页的标准样例（HS256，密钥 your-256-bit-secret）。逐字节一致 = 头、载荷、base64url、HMAC 四样都对；
# 任何一样不对，LiveKit 会拒绝这边签的**所有**钥匙，而这在桌面上看不出来。
func _case_jwt_vector() -> void:
	_h.item()
	var token := LiveKitAuth.sign_hs256({"sub": "1234567890", "name": "John Doe", "iat": 1516239022},
		"your-256-bit-secret")
	_h.expect(token == "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
			+ "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ."
			+ "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
		"voice_jwt_vector", "钥匙签名与 JWT 标准样例对不上：%s" % token)


func _case_join_token() -> void:
	var token := LiveKitAuth.join_token(TEST_CONFIG, "AAAA1111", "小林", "g123456-a1b2c3-t0", 1000)
	var header := LiveKitAuth.base64url(JSON.stringify({"alg": "HS256", "typ": "JWT"}, "", false).to_utf8_buffer())
	_h.item()
	_h.expect(token.split(".").size() == 3 and token.split(".")[0] == header, "voice_token_header",
		"钥匙的头不是 HS256 JWT")
	var payload := LiveKitAuth.decode_payload(token)
	_h.item()
	_h.expect(str(payload.get("iss", "")) == "APIvoicecheck" and str(payload.get("sub", "")) == "AAAA1111"
			and str(payload.get("name", "")) == "小林" and int(payload.get("nbf", 0)) == 1000
			and int(payload.get("exp", 0)) == 1000 + 600 and LiveKitAuth.JOIN_TTL_SEC == 600,
		"voice_token_claims", "钥匙的签发方 / 身份 / 名字 / 有效期（10 分钟）不对：%s" % str(payload))
	var expected := {
		"roomJoin": true, "room": "g123456-a1b2c3-t0", "canSubscribe": true, "canPublish": true,
		"canPublishSources": ["microphone"], "canPublishData": false,
	}
	_h.item()
	_h.expect(JSON.stringify(payload.get("video", {})) == JSON.stringify(expected), "voice_token_grants",
		"钥匙的权限必须正好是：进这一个房间、能听、只准发麦克风、不准发数据。实际 %s" % str(payload.get("video", {})))


func _case_admin_token() -> void:
	var kick := LiveKitAuth.decode_payload(LiveKitAuth.admin_token(TEST_CONFIG, "g1-x-t1", 5000, false))
	_h.item()
	_h.expect(JSON.stringify(kick.get("video", {})) == JSON.stringify({"roomAdmin": true, "room": "g1-x-t1"})
			and int(kick.get("exp", 0)) - int(kick.get("nbf", 0)) == LiveKitAuth.ADMIN_TTL_SEC
			and not kick.has("sub"),
		"voice_admin_token_kick", "踢人用的管理钥匙只能管这一个房间、60 秒有效：%s" % str(kick))
	var drop := LiveKitAuth.decode_payload(LiveKitAuth.admin_token(TEST_CONFIG, "g1-x-t1", 5000, true))
	_h.item()
	_h.expect(JSON.stringify(drop.get("video", {})) == JSON.stringify({"roomCreate": true}),
		"voice_admin_token_delete", "删房间用的管理钥匙应只带 roomCreate：%s" % str(drop))


func _case_config_loader() -> void:
	var dir := "user://voice_check_cfg"
	DirAccess.make_dir_recursive_absolute(dir)
	var cases := {
		"ok.json": [TEST_CONFIG, true],
		"short_secret.json": [TEST_CONFIG.merged({"api_secret": "too-short"}, true), false],
		"https_client.json": [TEST_CONFIG.merged({"client_url": "https://voice.example.test"}, true), false],
		"no_key.json": [TEST_CONFIG.merged({"api_key": ""}, true), false],
		"bad_admin.json": [TEST_CONFIG.merged({"admin_url": "127.0.0.1:7880"}, true), false],
	}
	for file_name in cases:
		var path := dir.path_join(file_name)
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify(cases[file_name][0]))
		f.close()
		_h.item()
		var got := LiveKitAuth.load_config(path)
		_h.expect(bool(got.get("ok", false)) == bool(cases[file_name][1]), "voice_config_validation",
			"%s：期望 ok=%s，实际 %s" % [file_name, str(cases[file_name][1]), str(got.get("error", "ok"))])
		DirAccess.remove_absolute(path)
	_h.item()
	_h.expect(not bool(LiveKitAuth.load_config(dir.path_join("missing.json")).get("ok", true)),
		"voice_config_missing_ok", "没有配置文件时必须 ok=false（照常开服、只是不发钥匙）")
	DirAccess.remove_absolute(dir)
	# 默认在 user://（战斗服务器用户的 Godot 目录）：密钥不能跟着代码和服务器包走。
	_h.item()
	_h.expect(LiveKitAuth.DEFAULT_CONFIG_PATH.begins_with("user://"), "voice_config_in_package",
		"语音配置默认路径必须在 user://，不能在 res://（会被打进服务器包）")


# --- 5. 🔴 发钥匙的规矩 ----------------------------------------------------------------

func _test_room() -> Dictionary:
	return {
		"id": 123456,
		"voice_salt": "a1b2c3",
		"voice_used": false,
		"peer_slot": {11: 0, 12: 1, 21: 3, 22: 4},
		"slot_states": ["player", "player", "ai", "player", "player", "empty"],
		"seat_profiles": {
			0: {"friend_code": "AAAA1111", "player_name": "小林"},
			3: {"friend_code": "CCCC3333", "player_name": "对面"},
			4: {"friend_code": "DDDD4444", "player_name": "对面二"},
		},
	}


func _case_token_policy() -> void:
	var saved_config: Dictionary = NetworkService._voice_config
	var saved_dirty: bool = NetworkService._rooms_dirty
	NetworkService._voice_config = {}
	var room := _test_room()
	_h.item()
	_h.expect(str(NetworkService.voice_token_for_peer(room, 11, 1000).error) == "voice_not_configured",
		"voice_token_without_config", "服务器没配语音时应回 voice_not_configured，不能发钥匙")

	NetworkService._voice_config = TEST_CONFIG.duplicate()
	var red := NetworkService.voice_token_for_peer(room, 11, 1000)
	var blue := NetworkService.voice_token_for_peer(room, 21, 1000)
	_h.item()
	_h.expect(str(red.error).is_empty() and str(red.room) == "g123456-a1b2c3-t0"
			and str(red.url) == str(TEST_CONFIG.client_url),
		"voice_token_red_room", "红方 0 号位应拿到本队（t0）的钥匙：%s" % str(red))
	_h.item()
	_h.expect(str(blue.error).is_empty() and str(blue.room) == "g123456-a1b2c3-t1",
		"voice_token_blue_room", "蓝方 3 号位应拿到本队（t1）的钥匙：%s" % str(blue))
	var red_payload := LiveKitAuth.decode_payload(str(red.token))
	_h.item()
	_h.expect(str(red_payload.get("sub", "")) == "AAAA1111" and str(red_payload.get("name", "")) == "小林"
			and str((red_payload.get("video", {}) as Dictionary).get("room", "")) == str(red.room),
		"voice_token_identity", "钥匙里的身份应是座位名片的好友码、房间与回复一致：%s" % str(red_payload))
	var no_card := NetworkService.voice_token_for_peer(room, 12, 1000)
	_h.item()
	_h.expect(str(LiveKitAuth.decode_payload(str(no_card.token)).get("sub", "")) == "seat1",
		"voice_token_seat_identity", "没有名片的座位身份应是 seat<N>")

	# 🔴 谁都拿不到对面的房间：每个人拿到的房间号末尾一定是自己座位的队伍
	_h.item()
	var leaked: Array = []
	for peer in (room.peer_slot as Dictionary).keys():
		var reply := NetworkService.voice_token_for_peer(room, int(peer), 1000)
		var team := GameConstants.team_of_slot(int(room.peer_slot[peer]))
		if str(reply.error).is_empty() and not str(reply.room).ends_with("-t%d" % team):
			leaked.append(peer)
	_h.expect(leaked.is_empty(), "voice_token_wrong_team", "这些连接拿到了不是自己队伍的语音房间：%s" % str(leaked))

	_h.item()
	_h.expect(str(NetworkService.voice_token_for_peer(room, 99, 1000).error) == "not_seated"
			and str(NetworkService.voice_token_for_peer({}, 11, 1000).error) == "not_in_room",
		"voice_token_unseated", "不在座位上 / 不在房间里的连接不能拿钥匙")
	var ai_room := _test_room()
	(ai_room.peer_slot as Dictionary)[13] = 2
	_h.item()
	_h.expect(str(NetworkService.voice_token_for_peer(ai_room, 13, 1000).error) == "not_seated",
		"voice_token_ai_seat", "AI 座位不发钥匙")

	_h.item()
	_h.expect(bool(room.get("voice_used", false)), "voice_used_not_marked",
		"发过钥匙的房间要记 voice_used —— 否则换队 / 关房时不会去 LiveKit 请人出去")
	var old_room := _test_room()
	old_room.erase("voice_salt")
	var first := NetworkService.voice_room_name(old_room, 0)
	_h.item()
	_h.expect(not str(old_room.get("voice_salt", "")).is_empty() and NetworkService.voice_room_name(old_room, 0) == first,
		"voice_salt_unstable", "旧快照读回来的房间没有随机串时要补一个，而且之后不再变")
	_h.item()
	_h.expect(FileAccess.get_file_as_string("res://scripts/multiplayer/RoomService.gd").contains(
			"\"voice_salt\": Crypto.new().generate_random_bytes(6).hex_encode(),")
			and DedicatedServerService.PERSISTED_ROOM_FIELDS.has("voice_salt")
			and DedicatedServerService.PERSISTED_ROOM_FIELDS.has("voice_used"),
		"voice_salt_not_persisted",
		"新房间要带语音随机串，并且随房间存盘 —— 服务器一重启随机串变了，已经在语音里的人就和新钥匙不在一个房间了")
	NetworkService._voice_config = saved_config
	NetworkService._rooms_dirty = saved_dirty


func _case_rpc_contract() -> void:
	var src := FileAccess.get_file_as_string(NETWORK_SERVICE_PATH)
	var request := "func _rpc_team_voice_token_request() -> void:"
	var reply := "func _rpc_team_voice_token(url: String, token: String, room_name: String, error: String) -> void:"
	_h.item()
	_h.expect(src.contains("@rpc(\"any_peer\", \"call_remote\", \"reliable\")\n" + request),
		"voice_token_request_signature",
		"要钥匙的 RPC 必须**不带任何参数**（谁、哪队由服务器从连接反查；带参数就等于能冒充别人）：%s" % request)
	_h.item()
	_h.expect(src.contains("@rpc(\"authority\", \"call_remote\", \"reliable\")\n" + reply),
		"voice_token_reply_signature", "回钥匙的 RPC 签名变了：%s" % reply)
	var body := _function_body(src, request)
	_h.item()
	_h.expect(body.contains("_rate_ok(sender, \"voice_token\", false)")
			and body.contains("voice_token_for_peer(_room_for_peer(sender), sender,"),
		"voice_token_request_unguarded",
		"发钥匙前必须软限流（不计 strike）并按连接反查房间：_rate_ok(sender, \"voice_token\", false) + voice_token_for_peer(_room_for_peer(sender), sender, …)")
	_h.item()
	_h.expect(RateLimitService.LIMITS.has("voice_token") and not RateLimitService.LIMITS.has("voice"),
		"voice_rate_limit_table", "RateLimitService.LIMITS 要有 voice_token（没有会静默退回默认额度），旧的 voice 要删")
	_h.item()
	var client := _function_body(src, "func team_request_voice_token() -> bool:")
	_h.expect(client.contains("_rpc_team_voice_token_request.rpc_id(1)") and client.contains("is_host"),
		"voice_token_client_request", "客户端要钥匙只发给服务器（peer 1），本地房主调试房不要")


# --- 6. 🔴 踢人 ------------------------------------------------------------------------

func _case_kick_hooks() -> void:
	var src := FileAccess.get_file_as_string(NETWORK_SERVICE_PATH)
	var move := _function_body(src, "func _room_do_move(room: Dictionary, peer_id: int, from_slot: int, to_slot: int) -> void:")
	var move_id := move.find("_voice_identity(room, from_slot)")
	_h.item()
	_h.expect(move_id >= 0 and move_id < move.find("_move_seat_metadata(")
			and move.contains("if GameConstants.team_of_slot(from_slot) != GameConstants.team_of_slot(to_slot):\n\t\t_voice_seat_released(room, from_slot, voice_identity)"),
		"voice_move_not_kicked",
		"跨队换座：要在搬座位信息之前取语音身份，搬完把他请出旧队伍的语音房间（同队换座不用）")
	var remove := _function_body(src, "func _room_remove_peer(room: Dictionary, peer_id: int) -> void:")
	var remove_id := remove.find("_voice_identity(room, slot)")
	_h.item()
	_h.expect(remove_id >= 0 and remove_id < remove.find("_clear_seat_metadata(room, slot)")
			and remove.contains("_voice_seat_released(room, slot, voice_identity)"),
		"voice_remove_not_kicked", "离开 / 被踢 / 大厅掉线：清座位之前取语音身份，清完请出语音房间")
	var takeover := _function_body(src, "func _room_auto_complete_seat(room: Dictionary, slot: int) -> void:")
	var takeover_id := takeover.find("_voice_identity(room, slot)")
	_h.item()
	_h.expect(takeover_id >= 0 and takeover_id < takeover.find("_reconnect_service.apply_ai_takeover(")
			and takeover.contains("_voice_seat_released(room, slot, voice_identity)"),
		"voice_takeover_not_kicked", "座位被 AI 接管：原来的人要请出语音房间")
	var close := _function_body(src, "func _room_close(room: Dictionary, reason: String) -> void:")
	var close_at := close.find("_voice_rooms_closed(room)")
	_h.item()
	_h.expect(close_at >= 0 and close_at < close.find("_clear_seat_metadata("), "voice_close_not_deleted",
		"关房要先删两队的语音房间（要用房间里的语音随机串），再清座位")
	_h.item()
	_h.expect(not _function_body(src, "func _room_reserve_peer(room: Dictionary, peer_id: int) -> void:").contains("_voice_seat_released"),
		"voice_reserve_kicked", "对局中掉线、座位保留时**不能**请出语音：人还在这一队，重连回来要接着说")

	var saved_admin: Object = NetworkService._voice_admin
	var admin := FakeAdmin.new()
	NetworkService._voice_admin = admin
	var room := _test_room()
	NetworkService._voice_seat_released(room, 0, "AAAA1111")
	NetworkService._voice_rooms_closed(room)
	_h.item()
	_h.expect(admin.removed.is_empty() and admin.deleted.is_empty(), "voice_kick_without_use",
		"这个房间从没发过语音钥匙，不该去 LiveKit 踢人 / 删房间")
	room["voice_used"] = true
	NetworkService._voice_seat_released(room, 1, "AAAA1111")
	NetworkService._voice_seat_released(room, 4, "DDDD4444")
	_h.item()
	_h.expect(str(admin.removed) == str([["g123456-a1b2c3-t0", "AAAA1111"], ["g123456-a1b2c3-t1", "DDDD4444"]]),
		"voice_kick_wrong_room", "应从各自所在队伍的语音房间请出去，实际 %s" % str(admin.removed))
	NetworkService._voice_rooms_closed(room)
	_h.item()
	_h.expect(str(admin.deleted) == str(["g123456-a1b2c3-t0", "g123456-a1b2c3-t1"]), "voice_close_rooms",
		"关房应删掉两队的语音房间，实际 %s" % str(admin.deleted))
	NetworkService._voice_admin = saved_admin


# --- 7. 旧的删干净了；密钥不进客户端 ------------------------------------------------------

func _case_old_transport_removed() -> void:
	var src := FileAccess.get_file_as_string(NETWORK_SERVICE_PATH)
	for gone in ["_rpc_team_voice_submit", "team_send_voice", "voice_recipients", "_voice_stats",
			"VOICE_MAX_PACKET_BYTES", "team_voice_received"]:
		_h.item()
		_h.expect(not src.contains(gone), "voice_old_relay_left",
			"旧的语音转发还留着：%s（v31 起语音不经过战斗服务器）" % gone)
	_h.item()
	# 只看声明（注释里记着 v31 删了它，那是历史）
	_h.expect(RegEx.create_from_string("(?m)^const CH_VOICE\b").search(
			FileAccess.get_file_as_string("res://scripts/multiplayer/NetworkConfig.gd")) == null,
		"voice_old_channel_left", "语音通道 CH_VOICE 还在：v31 起没人用它")
	for path in ["res://scripts/voice/DesktopVoiceBackend.gd", "res://scripts/voice/VoiceAdpcm.gd",
			"res://scripts/voice/VoicePacketCodec.gd"]:
		_h.item()
		_h.expect(not FileAccess.file_exists(path), "voice_desktop_trial_left",
			"电脑试用版 %s 还在：它靠的战斗服务器转发已经删了" % path)
	# 🔴 手机不能开 Godot 自带的录音：它不设录音模式，拿不到系统回声消除。手机录音一律走桥接。
	_h.item()
	_h.expect(RegEx.create_from_string("(?m)^driver/enable_input(\\.android|\\.ios)?\\s*=\\s*true")
			.search(FileAccess.get_file_as_string("res://project.godot")) == null,
		"voice_godot_input_on_mobile", "录音输入不能全局打开，也不能对安卓 / 苹果打开")
	for path in ["res://scripts/autoload/VoiceService.gd", "res://ui/components/VoiceControls.gd",
			"res://ui/components/VoicePanel.gd"]:
		var client_src := FileAccess.get_file_as_string(path)
		_h.item()
		_h.expect(not client_src.contains("api_secret") and not client_src.contains("LiveKitAuth"),
			"voice_secret_in_client", "%s 碰了签钥匙的东西：语音密钥只能在战斗服务器上" % path)
	# 安装脚本在服务器上现生成密钥：配置里的 keys 只能是变量，不能是写死的值。
	var installer := FileAccess.get_file_as_string("res://deploy/livekit/install_livekit.sh")
	_h.item()
	_h.expect(installer.contains("secrets.token_urlsafe(36)") and installer.contains("\n  $api_key: $api_secret\n")
			and RegEx.create_from_string("(?m)^\\s+API[A-Za-z0-9]{6,}:\\s").search(installer) == null,
		"voice_installer_has_secret",
		"deploy/livekit/install_livekit.sh 要在服务器上现生成密钥，文件里不能写死 key / secret")


# --- 8. VoiceService 状态机 ---------------------------------------------------------

func _case_bridge_contract() -> void:
	# 假桥接必须与 BRIDGE_METHODS 完全一致 —— 状态机那几条测的才是真桥接要实现的那套方法。
	var fake_script: Script = FakeBridge
	var have := {}
	for method in fake_script.get_script_method_list():
		have[str(method.name)] = (method.args as Array).size()
	var object_methods := {}
	for method in ClassDB.class_get_method_list("Object"):
		object_methods[str(method.name)] = true
	_h.item()
	_h.expect(object_methods.has("connect") and object_methods.has("disconnect"), "voice_name_clash_selfcheck",
		"门禁自检：读到的 Object 方法表里没有 connect / disconnect，下面的撞名检查就成了摆设")
	for method_name in VoiceService.BRIDGE_METHODS:
		_h.item()
		_h.expect(have.has(method_name) and int(have[method_name]) == int(VoiceService.BRIDGE_METHODS[method_name]),
			"voice_fake_bridge_drift", "假桥接缺方法或参数个数不对：%s" % method_name)
		# 名字不能和 Object 自带的方法撞：在安卓单例上会被 Object 的同名方法截走（connect / disconnect 就是）。
		_h.item()
		_h.expect(not object_methods.has(method_name), "voice_bridge_name_clash",
			"桥接方法 %s 与 Object 自带的方法同名" % method_name)


# 安卓桥接（Kotlin）对账：@UsedByGodot 方法与 BRIDGE_METHODS 同名、同参数个数；VoiceService 读的状态 / 能力字段它都给。
# 对不上的表现：GDScript 调一个桥接上没有的方法 → 那一帧的脚本直接中断，按钮点了没反应；
# 少一个状态字段 → 界面一直显示「连接中」。都只在手机上出现，桌面门禁用的是假桥接。
func _case_kotlin_bridge_contract() -> void:
	var src := FileAccess.get_file_as_string(KOTLIN_BRIDGE_PATH)
	_h.item()
	if not _h.expect(not src.is_empty(), "voice_kotlin_bridge_missing", "读不到 %s" % KOTLIN_BRIDGE_PATH):
		return
	var exported := {}
	for m in RegEx.create_from_string("@UsedByGodot\\s+fun\\s+(\\w+)\\(([^)]*)\\)").search_all(src):
		var params := m.get_string(2).strip_edges()
		exported[m.get_string(1)] = 0 if params.is_empty() else params.split(",").size()
	for method_name in VoiceService.BRIDGE_METHODS:
		_h.item()
		_h.expect(exported.has(method_name) and int(exported[method_name]) == int(VoiceService.BRIDGE_METHODS[method_name]),
			"voice_kotlin_method_drift", "安卓桥接缺方法或参数个数不对：%s（Kotlin 里是 %s）" % [method_name, str(exported.get(method_name, "没有"))])
	_h.item()
	_h.expect(exported.size() == VoiceService.BRIDGE_METHODS.size(), "voice_kotlin_extra_method",
		"安卓桥接有 VoiceService 不认识的方法（没人调就删掉）：%s" % str(exported.keys()))
	for key in BRIDGE_STATUS_KEYS:
		_h.item()
		_h.expect(src.contains("o.put(\"%s\"" % key), "voice_kotlin_status_key_missing", "安卓桥接 getStatus 没给 %s" % key)
	for key in BRIDGE_CAPABILITY_KEYS:
		_h.item()
		_h.expect(src.contains("o.put(\"%s\"" % key), "voice_kotlin_capability_key_missing", "安卓桥接 getCapabilities 没给 %s" % key)
	_h.item()
	_h.expect(src.contains("override fun getPluginName(): String = \"%s\"" % VoiceService.SINGLETON)
			and src.contains("package com.glory.voice") and src.contains("class GloryVoicePlugin(godot: Godot) : GodotPlugin(godot)"),
		"voice_kotlin_plugin_identity", "安卓桥接的单例名 / 类名要和 VoiceService.SINGLETON、清单里的 com.glory.voice.GloryVoicePlugin 一致")
	# 切后台必须断开（不申请后台录音）。这件事桥接自己也做 —— Godot 的暂停通知不保证在进后台前送到脚本。
	_h.item()
	_h.expect(src.contains("override fun onMainPause()") and src.contains("error = \"paused\""),
		"voice_kotlin_background", "安卓桥接切后台时要自己断开，并报 failed / paused 让 VoiceService 回来后重连")
	# 只听 = 媒体声道、开麦 = 通话模式：这是「游戏声 / 蓝牙音质不受只听影响」的来源。
	_h.item()
	_h.expect(src.contains("if (listenOnly) AudioType.MediaAudioType() else AudioType.CallAudioType()"),
		"voice_kotlin_audio_type", "安卓桥接：只听要用 MediaAudioType、开麦用 CallAudioType（改之前先看 docs/语音LiveKit方案.md 5.1）")


# 电脑版桥接（C++）对账：绑定给 Godot 的方法与 BRIDGE_METHODS 同名同参；VoiceService 读的字段它都给；
# 注册成同一个单例名。对不上的表现同安卓：脚本调了不存在的方法、或者界面一直「连接中」—— 只在电脑上出现。
func _case_desktop_bridge_contract() -> void:
	var src := FileAccess.get_file_as_string(DESKTOP_CPP_PATH)
	_h.item()
	if not _h.expect(not src.is_empty(), "voice_desktop_bridge_missing", "读不到 %s" % DESKTOP_CPP_PATH):
		return
	var bound := {}
	for m in RegEx.create_from_string("D_METHOD\\(\"(\\w+)\"((?:,\\s*\"\\w+\")*)\\)").search_all(src):
		bound[m.get_string(1)] = m.get_string(2).count(",")
	for method_name in VoiceService.BRIDGE_METHODS:
		_h.item()
		_h.expect(bound.has(method_name) and int(bound[method_name]) == int(VoiceService.BRIDGE_METHODS[method_name]),
			"voice_desktop_method_drift", "电脑版桥接缺方法或参数个数不对：%s（C++ 里是 %s）" % [method_name, str(bound.get(method_name, "没有"))])
	_h.item()
	_h.expect(bound.size() == VoiceService.BRIDGE_METHODS.size(), "voice_desktop_extra_method",
		"电脑版桥接绑了 VoiceService 不认识的方法（没人调就删掉）：%s" % str(bound.keys()))
	for key in BRIDGE_STATUS_KEYS + BRIDGE_CAPABILITY_KEYS:
		_h.item()
		_h.expect(src.contains("d[\"%s\"]" % key), "voice_desktop_status_key_missing", "电脑版桥接没给 %s" % key)
	# 电脑上只听 / 开麦是同一套设备：报 false，VoiceService 换档时就不会退房重进。
	_h.item()
	_h.expect(src.contains("d[\"listen_mode_fixed_at_join\"] = false;"), "voice_desktop_rejoin_on_switch",
		"电脑版不需要换档重进，listen_mode_fixed_at_join 应当是 false")
	var register := FileAccess.get_file_as_string(DESKTOP_DIR.path_join("src/register_types.cpp"))
	var gdext := ConfigFile.new()
	_h.item()
	_h.expect(register.contains("register_singleton(\"%s\"" % VoiceService.SINGLETON)
			and gdext.load(DESKTOP_GDEXTENSION_PATH) == OK
			and register.contains("GDExtensionBool GDE_EXPORT %s(" % str(gdext.get_value("configuration", "entry_symbol", "?"))),
		"voice_desktop_identity", "电脑版桥接的单例名要是 %s，入口函数名要和 glory_voice.gdextension 的 entry_symbol 一致" % VoiceService.SINGLETON)
	# 关麦要撤掉麦克风轨道并放掉录音源，不能只是静音 —— 静音的话麦克风其实还在录。
	_h.item()
	_h.expect(src.contains("local->unpublishTrack(publication->sid());") and src.contains("mic_source_.reset();"),
		"voice_desktop_mic_kept_open", "电脑版关麦要撤掉麦克风轨道并放掉录音源")
	# LiveKit 开发包版本：头文件里的常量（报给界面）和打包脚本核对的必须一样。
	var header := FileAccess.get_file_as_string(DESKTOP_DIR.path_join("src/glory_voice_desktop.h"))
	var script_src := FileAccess.get_file_as_string(DESKTOP_DIR.path_join("build_dll.ps1"))
	var h_ver := RegEx.create_from_string("LIVEKIT_SDK_VERSION = \"([0-9.]+)\"").search(header)
	var s_ver := RegEx.create_from_string("\\$SdkVersion = \"([0-9.]+)\"").search(script_src)
	_h.item()
	_h.expect(h_ver != null and s_ver != null and h_ver.get_string(1) == s_ver.get_string(1),
		"voice_desktop_sdk_version_drift", "LiveKit C++ 开发包版本两处不一致（头文件 / build_dll.ps1）")


# 电脑版 dll 是照着现在的源码编的，扩展声明要带的文件都在。
# 这一条在 Windows 出包前必须绿：缺一个 dll，电脑版装上去点语音就是「语音组件没有加载起来」。
func _case_desktop_build() -> void:
	var gdext := ConfigFile.new()
	_h.item()
	if not _h.expect(gdext.load(DESKTOP_GDEXTENSION_PATH) == OK, "voice_desktop_gdextension_unreadable",
			"读不到 %s" % DESKTOP_GDEXTENSION_PATH):
		return
	var declared: Array[String] = []
	for key in gdext.get_section_keys("libraries"):
		if str(key).begins_with("windows."):
			declared.append(str(gdext.get_value("libraries", key)))
	var deps: Variant = gdext.get_value("dependencies", "windows.x86_64", {})
	if deps is Dictionary:
		for path in (deps as Dictionary).keys():
			declared.append(str(path))
	var missing: Array[String] = []
	for path in declared:
		if not FileAccess.file_exists(path):
			missing.append(path.get_file())
	_h.item()
	_h.expect(declared.size() == 7 and missing.is_empty(), "voice_desktop_files_missing",
		"电脑版语音扩展声明的文件缺了（跑 native/glory_voice_desktop/build_dll.ps1）：%s" % str(missing))
	var recorded := FileAccess.get_file_as_string(DESKTOP_BIN_DIR.path_join("glory_voice_desktop_source.sha256")).strip_edges()
	var actual := _desktop_source_digest()
	_h.item()
	_h.expect(not actual.is_empty() and recorded == actual, "voice_desktop_dll_stale",
		("电脑版 dll 不是照着现在的源码编的（记录 %s…，源码 %s…）。改了 C++ / SConstruct 之后"
			+ "要重跑 native/glory_voice_desktop/build_dll.ps1。") % [recorded.left(12), actual.left(12)])


# 与 build_dll.ps1 同一个算法：SConstruct + src/ 下的 .cpp / .h，「相对路径:sha256」逐行、按码点排序、\n 连接。
func _desktop_source_digest() -> String:
	var rel := PackedStringArray(["SConstruct"])
	var dir := DirAccess.open(DESKTOP_DIR.path_join("src"))
	if dir == null:
		return ""
	for file in dir.get_files():
		if file.ends_with(".cpp") or file.ends_with(".h"):
			rel.append("src/" + file)
	rel.sort()
	var lines := PackedStringArray()
	for path in rel:
		var sha := FileAccess.get_sha256(DESKTOP_DIR.path_join(path))
		if sha.is_empty():
			return ""
		lines.append("%s:%s" % [path, sha])
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update("\n".join(lines).to_utf8_buffer())
	return ctx.finish().hex_encode()


func _save_state() -> Dictionary:
	return {
		"bridge": VoiceService._bridge,
		"mode": VoiceService.mode,
		"muted": VoiceService._muted_keys.duplicate(),
		"active": NetworkService.team_active,
		"slot": NetworkService.team_local_slot,
		"states": NetworkService.team_slot_states.duplicate(),
		"profiles": NetworkService.team_seat_profiles.duplicate(true),
	}


func _restore_state(saved: Dictionary) -> void:
	# 先用手上的假桥接把语音关掉，再换回原来的桥接与联机状态。
	VoiceService.set_mode(VoiceService.Mode.OFF)
	VoiceService._leave()
	VoiceService._bridge = saved.bridge
	VoiceService.mode = int(saved.mode)
	VoiceService._muted_keys = saved.muted
	VoiceService.token_requester = Callable()
	VoiceService._retry_in = 0.0
	VoiceService._retry_index = 0
	VoiceService._last_error = ""
	VoiceService._capabilities = {}
	VoiceService._token_cache = {}
	NetworkService.team_active = bool(saved.active)
	NetworkService.team_local_slot = int(saved.slot)
	NetworkService.team_slot_states = saved.states
	NetworkService.team_seat_profiles = saved.profiles


# 桥接状态有 0.25 秒缓存；门禁里改了假桥接之后要立刻看到。
func _fresh_status() -> void:
	VoiceService._status_at_msec = -100000


func _reply(room: String, error: String = "", token: String = "tok") -> void:
	NetworkService.team_voice_token_received.emit("wss://voice.example.test" if error.is_empty() else "",
		token if error.is_empty() else "", room if error.is_empty() else "", error)


func _case_ios_permission() -> void:
	var saved := _save_state()
	var fake := FakeIOSBridge.new()
	fake.permission = false
	VoiceService._bridge = fake
	VoiceService.mode = VoiceService.Mode.OFF
	VoiceService.token_requester = func() -> bool: return true
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.team_slot_states = ["player", "player", "ai", "player", "player", "empty"]
	var events: Array = []
	var callback := func(granted: bool) -> void: events.append(granted)
	VoiceService.mic_permission_result.connect(callback)
	VoiceService.set_mode(VoiceService.Mode.TALK)
	_h.expect(fake.permission_requests == 1 and VoiceService.mode == VoiceService.Mode.LISTEN and not fake.mic_on,
		"ios_permission_prompt", "iOS 必须经原生桥接请求权限，等待时不开麦")
	fake.permission_state = "denied"
	_fresh_status()
	VoiceService._process(0.01)
	_h.expect(events == [false] and VoiceService.mode == VoiceService.Mode.LISTEN,
		"ios_permission_denied", "iOS 拒绝权限应返回只听并通知界面")
	VoiceService.set_mode(VoiceService.Mode.TALK)
	_reply("ios-team-t0")
	fake.permission = true
	fake.permission_state = "granted"
	_fresh_status()
	VoiceService._process(0.01)
	_h.expect(events == [false, true] and VoiceService.mode == VoiceService.Mode.TALK and fake.mic_on,
		"ios_permission_granted", "iOS 允许权限后才开启麦克风")
	VoiceService.set_mode(VoiceService.Mode.LISTEN)
	fake.permission = false
	VoiceService.set_mode(VoiceService.Mode.TALK)
	VoiceService.set_mode(VoiceService.Mode.OFF)
	fake.permission = true
	fake.permission_state = "granted"
	_fresh_status()
	VoiceService._process(0.01)
	_h.expect(VoiceService.mode == VoiceService.Mode.OFF and not fake.mic_on,
		"ios_late_permission", "已关闭语音后迟到的授权不能重新开麦")
	VoiceService.mic_permission_result.disconnect(callback)
	_restore_state(saved)


func _case_state_machine() -> void:
	var saved := _save_state()
	var fake := FakeBridge.new()
	var requests := [0]
	VoiceService.token_requester = func() -> bool:
		requests[0] += 1
		return true
	var events: Array = []
	var on_changed := func(changed: int) -> void: events.append(changed)
	VoiceService.mode_changed.connect(on_changed)

	# a) 没有桥接（电脑版第 3 阶段之前、苹果版之前）：点了只给原因，档位不动，也不去要钥匙
	_h.item()
	VoiceService._bridge = null
	VoiceService.mode = VoiceService.Mode.OFF
	_h.expect(not VoiceService.cycle_mode().is_empty() and VoiceService.mode == VoiceService.Mode.OFF
			and requests[0] == 0,
		"voice_no_bridge_changed_mode", "没有桥接时点语音按钮必须给原因、停在「关」")

	# b) 有桥接但不在房间：不开
	_h.item()
	VoiceService._bridge = fake
	NetworkService.team_active = false
	NetworkService.team_local_slot = -1
	_h.expect(not VoiceService.set_mode(VoiceService.Mode.LISTEN).is_empty() and requests[0] == 0,
		"voice_started_outside_room", "不在房间里不能开语音")

	# c) 进房间、只听：先要钥匙，还没进房
	_h.item()
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.team_slot_states = ["player", "player", "ai", "player", "player", "empty"]
	_h.expect(VoiceService.set_mode(VoiceService.Mode.LISTEN).is_empty() and VoiceService.mode == VoiceService.Mode.LISTEN
			and requests[0] == 1 and not fake.joined,
		"voice_listen_no_token_request", "「只听」应向战斗服务器要一次钥匙（要到之前不进房）")

	# d) 钥匙到了：以「只听」进本队房间
	_h.item()
	_reply("g1-s-t0", "", "tok-red")
	_h.expect(fake.joined and str(fake.join_args) == str(["wss://voice.example.test", "tok-red", true])
			and VoiceService.connection_state() == "connected" and not fake.mic_on,
		"voice_join_wrong", "拿到钥匙应以「只听」进房（listen_only = true），麦克风关着。实际 %s" % str(fake.join_args))

	# e) 开麦 / 回到只听
	_h.item()
	_h.expect(VoiceService.cycle_mode().is_empty() and VoiceService.mode == VoiceService.Mode.TALK and fake.mic_on,
		"voice_talk_wrong", "从「只听」再点一次应该进「开麦」并打开麦克风")
	_h.item()
	_h.expect(VoiceService.set_mode(VoiceService.Mode.LISTEN).is_empty() and not fake.mic_on and fake.joined,
		"voice_listen_mic_left_on", "回到「只听」要关麦，但不退房")

	# f) 麦克风打不开：给原因，停在「只听」
	_h.item()
	fake.mic_error = "mic_busy"
	var reason := VoiceService.set_mode(VoiceService.Mode.TALK)
	_h.expect(not reason.is_empty() and VoiceService.mode == VoiceService.Mode.LISTEN and not fake.mic_on,
		"voice_mic_failure_left_talk", "开麦失败必须给原因并停在「只听」，实际档位 %d" % VoiceService.mode)
	fake.mic_error = ""

	# g) 自己跨队换座：退出旧房间、要新队伍的钥匙；旧队伍那张迟到的回复要丢掉
	_h.item()
	var before := int(requests[0])
	var leaves := fake.leaves
	NetworkService.team_local_slot = 3
	VoiceService._process(0.1)
	_h.expect(fake.leaves == leaves + 1 and not fake.joined and int(requests[0]) == before + 1,
		"voice_team_change_not_followed", "换到对面队伍后应退出旧房间并要新队伍的钥匙")
	_reply("g1-s-t0", "", "tok-red-late")
	_h.item()
	_h.expect(not fake.joined, "voice_stale_token_used", "换队之前那张（旧队伍的）钥匙迟到了，不能拿它进房")
	_reply("g1-s-t1", "", "tok-blue")
	_h.item()
	_h.expect(fake.joined and str(fake.join_args[1]) == "tok-blue", "voice_new_team_not_joined",
		"新队伍的钥匙到了应进新房间")

	# h) 桥接说连不上 / 被请出房间：退房、给原因、退避之后再要钥匙
	_h.item()
	fake.state = "failed"
	fake.error = "disconnected"
	_fresh_status()
	before = int(requests[0])
	VoiceService._process(0.1)
	_h.expect(not fake.joined and VoiceService.connection_state() == "failed" and not VoiceService.last_error().is_empty()
			and int(requests[0]) == before,
		"voice_bridge_failure_ignored", "桥接失败后应退房、显示原因，并且不马上重要钥匙（要退避）")
	fake.state = "connected"
	fake.error = ""
	VoiceService._process(float(VoiceService.TOKEN_RETRY_SEC[0]) + 0.1)
	_h.item()
	_h.expect(int(requests[0]) == before + 1, "voice_no_retry", "退避时间到了应重新要钥匙")

	# i) 服务器回原因（例如没配语音）：不进房、给原因、退避
	_reply("", "voice_not_configured")
	_h.item()
	_h.expect(not fake.joined and VoiceService.last_error() == VoiceService.explain("voice_not_configured"),
		"voice_token_error_ignored", "服务器说没配语音时要把原因给界面")
	before = int(requests[0])
	VoiceService._process(0.5)
	_h.item()
	_h.expect(int(requests[0]) == before, "voice_retry_too_fast", "被拒之后不能马上重试（服务器那边 10 秒只给 5 次）")

	# j) 要了钥匙一直没回音：超时算失败
	VoiceService._process(float(VoiceService.TOKEN_RETRY_SEC[1]) + 0.1)
	var waiting := VoiceService._awaiting_token
	VoiceService._process(VoiceService.TOKEN_REPLY_TIMEOUT_SEC + 0.1)
	_h.item()
	_h.expect(waiting and not VoiceService._awaiting_token and not VoiceService.last_error().is_empty(),
		"voice_token_wait_forever", "要了钥匙超过 %.0f 秒没回音应算失败、走重试" % VoiceService.TOKEN_REPLY_TIMEOUT_SEC)

	# k) 切后台：断开；回来之后自动重连（档位不变）
	VoiceService._retry_in = 0.0
	VoiceService._process(0.01)
	_reply("g1-s-t1")
	_h.item()
	_h.expect(fake.joined, "voice_rejoin_failed", "退避之后重新要到钥匙应能进房")
	VoiceService._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	_h.item()
	_h.expect(not fake.joined and VoiceService.mode == VoiceService.Mode.LISTEN, "voice_background_kept",
		"切到后台必须断开（不申请后台音频），档位不变")
	before = int(requests[0])
	VoiceService._notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	VoiceService._process(0.01)
	_h.item()
	_h.expect(int(requests[0]) == before + 1, "voice_resume_no_rejoin", "回到前台应自动重新要钥匙进房")
	_reply("g1-s-t1")

	# l) 没有麦克风权限：先停在「只听」等系统弹窗；拒了发 mic_permission_result(false)，允许了才开麦
	_h.item()
	fake.permission = false
	var permission_events: Array = []
	var on_permission := func(granted: bool) -> void: permission_events.append(granted)
	VoiceService.mic_permission_result.connect(on_permission)
	VoiceService.set_mode(VoiceService.Mode.TALK)
	_h.expect(VoiceService.mode == VoiceService.Mode.LISTEN and not fake.mic_on, "voice_talk_without_permission",
		"没有麦克风权限时不能进「开麦」")
	VoiceService._on_permission_result("android.permission.RECORD_AUDIO", false)
	_h.item()
	_h.expect(VoiceService.mode == VoiceService.Mode.LISTEN and permission_events == [false],
		"voice_permission_denial_silent", "系统弹窗里拒绝后要停在「只听」并发 mic_permission_result(false)")
	VoiceService.set_mode(VoiceService.Mode.TALK)
	fake.permission = true
	VoiceService._on_permission_result("android.permission.RECORD_AUDIO", true)
	_h.item()
	_h.expect(VoiceService.mode == VoiceService.Mode.TALK and fake.mic_on, "voice_permission_grant_ignored",
		"玩家在系统弹窗里允许之后应该进「开麦」")
	VoiceService.mic_permission_result.disconnect(on_permission)

	# m) 短暂掉出房间（重连、切场景）不断；连续 LEAVE_GRACE_SEC 秒才全关
	_h.item()
	NetworkService.team_local_slot = -1
	VoiceService._process(1.0)
	_h.expect(VoiceService.mode == VoiceService.Mode.TALK and fake.joined, "voice_closed_on_blip",
		"掉出房间 1 秒（重连中）就把语音断了")
	NetworkService.team_active = false
	VoiceService._process(VoiceService.LEAVE_GRACE_SEC + 0.1)
	_h.item()
	_h.expect(VoiceService.mode == VoiceService.Mode.OFF and not fake.joined and not fake.mic_on,
		"voice_survives_leaving_room",
		"离开房间 %.0f 秒后语音必须全关 —— 麦克风绝不能带进下一个房间" % VoiceService.LEAVE_GRACE_SEC)
	# 只听 → 开麦 → 只听 →（开麦失败退回只听：档位没变，不发）→ 权限允许后开麦 → 离开房间关
	_h.item()
	_h.expect(events == [VoiceService.Mode.LISTEN, VoiceService.Mode.TALK, VoiceService.Mode.LISTEN,
			VoiceService.Mode.TALK, VoiceService.Mode.OFF],
		"voice_mode_changed_wrong", "档位每变一次都要发且只发一次 mode_changed（界面按钮靠它刷新），实际 %s" % str(events))

	VoiceService.mode_changed.disconnect(on_changed)
	_restore_state(saved)


# 安卓桥接那种「声音模式只能在进房时定」（listen_mode_fixed_at_join = true）：
# 只听 = 媒体声道、开麦 = 通话模式，换档 = 退房再进；刚拿的钥匙直接再用，不去问战斗服务器。
func _case_state_machine_fixed_listen_mode() -> void:
	var saved := _save_state()
	var fake := FakeBridge.new()
	fake.listen_fixed = true
	VoiceService._bridge = fake
	VoiceService._capabilities = {}
	VoiceService._token_cache = {}
	VoiceService._last_error = ""
	VoiceService.mode = VoiceService.Mode.OFF
	var requests := [0]
	VoiceService.token_requester = func() -> bool:
		requests[0] += 1
		return true
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.team_slot_states = ["player", "player", "ai", "player", "player", "empty"]

	# a) 只听：以 listen_only = true 进房
	VoiceService.set_mode(VoiceService.Mode.LISTEN)
	_reply("g1-s-t0", "", "tok-1")
	_h.item()
	_h.expect(fake.joined and str(fake.join_args) == str(["wss://voice.example.test", "tok-1", true]) and requests[0] == 1,
		"voice_fixed_listen_join", "只听应以 listen_only = true 进房：%s" % str(fake.join_args))

	# b) 开麦：退房，用同一把钥匙以 listen_only = false 重进（不再问服务器），然后开麦
	var leaves := fake.leaves
	var reason := VoiceService.set_mode(VoiceService.Mode.TALK)
	_h.item()
	_h.expect(reason.is_empty() and VoiceService.mode == VoiceService.Mode.TALK and fake.leaves == leaves + 1 and fake.joins == 2
			and str(fake.join_args) == str(["wss://voice.example.test", "tok-1", false]) and fake.mic_on and requests[0] == 1,
		"voice_fixed_talk_no_rejoin",
		"开麦要按通话模式重进（同一把钥匙、不问服务器）再开麦：进房 %d 次、钥匙请求 %d 次、%s" % [fake.joins, requests[0], str(fake.join_args)])

	# c) 回到只听：再重进一次（媒体声道），麦克风关着
	VoiceService.set_mode(VoiceService.Mode.LISTEN)
	_h.item()
	_h.expect(fake.joins == 3 and bool(fake.join_args[2]) and not fake.mic_on and requests[0] == 1,
		"voice_fixed_listen_no_rejoin", "回到只听要按媒体声道重进、麦克风关")

	# d) 钥匙旧了：换档要重新问服务器，不能拿旧钥匙硬进
	VoiceService._token_cache["at_msec"] = Time.get_ticks_msec() - int(VoiceService.TOKEN_REUSE_SEC * 1000.0) - 1000
	VoiceService.set_mode(VoiceService.Mode.TALK)
	_h.item()
	_h.expect(requests[0] == 2 and not fake.joined, "voice_fixed_stale_token_reused",
		"钥匙超过 %.0f 秒就不能再用来重进，要重新向战斗服务器要" % VoiceService.TOKEN_REUSE_SEC)
	_reply("g1-s-t0", "", "tok-2")
	_h.item()
	_h.expect(fake.joined and str(fake.join_args) == str(["wss://voice.example.test", "tok-2", false]) and fake.mic_on,
		"voice_fixed_new_token_talk", "新钥匙到了应按通话模式进房并开麦：%s" % str(fake.join_args))

	# e) 麦克风异步打不开（被别的应用占着）：退回只听、说明原因、按只听重进（用刚才的钥匙，不问服务器）
	fake.mic_error_async = "mic_busy"
	_fresh_status()
	var before := int(requests[0])
	VoiceService._process(0.01)
	_h.item()
	_h.expect(VoiceService.mode == VoiceService.Mode.LISTEN and VoiceService.last_error() == VoiceService.explain("mic_busy")
			and fake.joined and bool(fake.join_args[2]) and not fake.mic_on and int(requests[0]) == before,
		"voice_fixed_mic_failure",
		"麦克风打不开时要退回只听、把原因留给界面、按只听重进：档位 %d、原因「%s」、%s" % [VoiceService.mode, VoiceService.last_error(), str(fake.join_args)])
	fake.mic_error_async = ""

	# f) 被服务器请出房间：那把钥匙已经作废 —— 之后一律重新要，不能拿缓存的钥匙
	fake.state = "failed"
	fake.error = "removed"
	_fresh_status()
	VoiceService._process(0.01)
	_h.item()
	_h.expect(not fake.joined and VoiceService._token_cache.is_empty() and VoiceService.last_error() == VoiceService.explain("removed"),
		"voice_fixed_revoked_token_kept", "被请出房间后要退房、清掉钥匙缓存、显示原因")
	fake.state = "connected"
	fake.error = ""
	before = int(requests[0])
	VoiceService._process(float(VoiceService.TOKEN_RETRY_SEC[0]) + 0.1)
	_h.item()
	_h.expect(int(requests[0]) == before + 1, "voice_fixed_no_retry", "被请出之后退避时间到了应重新要钥匙")
	_reply("g1-s-t0", "", "tok-3")

	# g) 关掉：钥匙缓存一起清掉
	VoiceService.set_mode(VoiceService.Mode.OFF)
	_h.item()
	_h.expect(not fake.joined and VoiceService._token_cache.is_empty(), "voice_fixed_off_keeps_token", "关掉语音要退房并清掉钥匙缓存")

	_restore_state(saved)


# --- 9. 屏蔽按人记 ------------------------------------------------------------------

func _case_mutes_follow_player() -> void:
	var saved := _save_state()
	var fake := FakeBridge.new()
	VoiceService._bridge = fake
	VoiceService._muted_keys = {}
	VoiceService.mode = VoiceService.Mode.OFF
	VoiceService.token_requester = func() -> bool: return true
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.team_slot_states = ["player", "player", "ai", "player", "player", "empty"]
	NetworkService.team_seat_profiles = {
		1: {"player_name": "小林", "friend_code": "AAAA1111"},
		3: {"player_name": "对面", "friend_code": "CCCC3333"},
	}
	VoiceService.set_mode(VoiceService.Mode.LISTEN)
	_reply("g1-s-t0")
	fake.participants = ["AAAA1111"]
	fake.speaking = ["AAAA1111"]
	_fresh_status()

	_h.item()
	var mates := VoiceService.teammates()
	_h.expect(mates.size() == 1 and int(mates[0].slot) == 1 and str(mates[0].name) == "小林" and bool(mates[0].speaking),
		"voice_teammates_wrong",
		"队友名单应只有 1 号位小林且在说话（2 号位是 AI，3~5 号位是敌方），实际 %s" % str(mates))
	_h.item()
	_h.expect(str(VoiceService.speaking_slots()) == "[1]" and VoiceService.is_active(), "voice_speaking_not_mapped",
		"语音身份（好友码）要对回座位：小林在说话 → 1 号位")

	_h.item()
	var changed := [0]
	var on_mutes := func() -> void: changed[0] += 1
	VoiceService.mutes_changed.connect(on_mutes)
	VoiceService.set_muted(1, true)
	_h.expect(float(fake.volumes.get("AAAA1111", -1.0)) == 0.0 and changed[0] == 1 and VoiceService.is_muted(1)
			and not VoiceService.is_active(),
		"voice_muted_player_still_heard", "屏蔽 1 号位 = 把小林的音量设成 0，并发 mutes_changed")

	# 换座位：小林从 1 号位挪到 2 号位，新来的人坐到 1 号位 —— 屏蔽要跟着小林走
	_h.item()
	NetworkService.team_slot_states = ["player", "player", "player", "player", "player", "empty"]
	NetworkService.team_seat_profiles = {
		1: {"player_name": "新来的", "friend_code": "BBBB2222"},
		2: {"player_name": "小林", "friend_code": "AAAA1111"},
	}
	fake.participants = ["AAAA1111", "BBBB2222"]
	_fresh_status()
	VoiceService._apply_volumes()
	_h.expect(float(fake.volumes.get("AAAA1111", -1.0)) == 0.0 and float(fake.volumes.get("BBBB2222", -1.0)) == 1.0
			and VoiceService.is_muted(2) and not VoiceService.is_muted(1),
		"voice_mute_not_following_player",
		"屏蔽按人（好友码）记：小林换到 2 号位仍然是 0，新坐到 1 号位的人是 1；实际 %s" % str(fake.volumes))

	_h.item()
	VoiceService.set_muted(2, false)
	_h.expect(float(fake.volumes.get("AAAA1111", -1.0)) == 1.0 and not VoiceService.is_muted(2), "voice_unmute_failed",
		"取消屏蔽后音量应回到 1")

	_h.item()
	NetworkService.team_seat_profiles = {}
	fake.participants = ["seat1"]
	_fresh_status()
	VoiceService.set_muted(1, true)
	_h.expect(VoiceService.member_key(1) == "slot:1" and VoiceService.is_muted(1)
			and float(fake.volumes.get("seat1", -1.0)) == 0.0,
		"voice_mute_without_profile", "资料还没到的队友按座位号屏蔽（身份 seat<N>）")

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


# --- 10. 开麦前说明麦克风用途；界面接线 ------------------------------------------------

func _case_mic_rationale() -> void:
	var saved := _save_state()
	var fake := FakeBridge.new()
	_h.item()
	VoiceService._bridge = null
	_h.expect(not VoiceService.needs_mic_rationale(), "voice_rationale_without_bridge", "没有桥接时不该弹麦克风说明")
	VoiceService._bridge = fake
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
	var panel := FileAccess.get_file_as_string("res://ui/components/VoicePanel.gd")
	_h.item()
	_h.expect(panel.contains("VoiceService.unsupported_reason()") and panel.contains("VoiceService.last_error()"),
		"voice_panel_reasons_missing", "语音面板要把「为什么用不了 / 为什么连不上」写出来（unsupported_reason / last_error）")
	_h.expect(not FileAccess.get_file_as_string("res://scenes/menu/MainMenu.gd").contains("voice_spike"),
		"voice_spike_entry_left", "主菜单还留着验证版的「语音测试」入口")
	for path in ["res://scripts/autoload/VoiceService.gd", "res://ui/components/VoiceControls.gd",
			"res://ui/components/VoicePanel.gd", "res://scenes/menu/Team3v3Lobby.gd",
			"res://scenes/prep/PrepUI.gd", "res://scenes/battle/BattleScreen.gd",
			"res://scripts/voice/LiveKitAuth.gd", "res://scripts/voice/LiveKitAdmin.gd"]:
		var script := load(path) as Script
		_h.expect(script != null and script.can_instantiate(), "voice_script_unloadable",
			"%s 加载失败（解析错误见上面的 SCRIPT ERROR）" % path)


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
