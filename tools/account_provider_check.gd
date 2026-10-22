extends Node

# 用 Google 登录的客户端一侧（docs/三方登录设计.md 第六节）。
#
# 守的都是**静默失效**：
#   - 插件包不是照着现在的源码打的 → 装上去跑的是旧桥接；
#   - 导出插件交给 Gradle 的依赖版本和编译用的对不上 → 第一次点 Google 就崩；
#   - 单例名 / 方法名 / 清单里的插件名有一处对不上 → 启动页悄悄不出 Google 按钮，
#     换手机的老玩家被直接塞进一个新游客号；
#   - 新装时 login() 没停下来问 → 同上。
# 这些都不会在编辑器里报错，只能靠断言挡在出包之前。
#
# 运行：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/account_provider_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const SignInBridge := preload("res://scripts/account/SignInBridge.gd")
const AccountConfig := preload("res://scripts/account/AccountConfig.gd")
const Bootstrap := preload("res://scenes/bootstrap/Bootstrap.gd")

const CHECK_NAME := "account_provider"

const AAR_PATH := "res://addons/glory_signin/bin/GlorySignIn.aar"
const PLUGIN_DIR := "res://android_plugins/glory_signin"
const KOTLIN_PATH := "res://android_plugins/glory_signin/src/com/glory/signin/GlorySignInPlugin.kt"
const GRADLE_PATH := "res://android_plugins/glory_signin/build.gradle.kts"
const MANIFEST_PATH := "res://android_plugins/glory_signin/AndroidManifest.xml"
const EXPORT_PLUGIN_PATH := "res://addons/glory_signin/glory_signin_plugin.gd"
# 与 build_aar.ps1 的 $projectFiles 一致，外加 src/ 下全部 .kt。
const PLUGIN_PROJECT_FILES := ["AndroidManifest.xml", "proguard.txt", "build.gradle.kts", "settings.gradle.kts", "gradle.properties"]
# SignInBridge 调的三个方法，Kotlin 那边必须都有（@UsedByGodot）。
const BRIDGE_METHODS := ["isGoogleAvailable", "beginGoogleSignIn", "pollSignIn"]
# 导出插件交给 Gradle 的依赖（与 build.gradle.kts 的 compileOnly 逐个对账）。
const RUNTIME_ARTIFACTS := [
	"androidx.credentials:credentials",
	"androidx.credentials:credentials-play-services-auth",
	"com.google.android.libraries.identity.googleid:googleid",
]

var _h: CheckHarness
var _backup_text := ""
var _had_file := false


class FakeBridge extends RefCounted:
	var available := true
	var begin_result := 7
	var replies: Array[String] = []
	var client_id := ""
	var hashed_nonce := ""

	func isGoogleAvailable() -> bool:
		return available

	func beginGoogleSignIn(p_client_id: String, p_nonce: String) -> int:
		client_id = p_client_id
		hashed_nonce = p_nonce
		return begin_result

	func pollSignIn(_request_id: int) -> String:
		if replies.is_empty():
			return '{"state":"pending"}'
		return replies.pop_front()


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_aar_matches_source()
	_case_dependency_versions_agree()
	_case_plugin_wiring()
	_case_kotlin_never_logs_the_token()
	_case_unavailable_without_plugin()
	await _case_sign_in_flows()
	_case_token_claims()
	_case_entry_view_choose()
	_backup_existing()
	_case_login_stops_for_choice()
	_restore_existing()
	SignInBridge.bridge_override = null
	_h.finish(get_tree())


# --- 插件包与源码 -----------------------------------------------------------------

func _case_aar_matches_source() -> void:
	var zr := ZIPReader.new()
	if not _h.expect(zr.open(AAR_PATH) == OK, "aar_missing",
			"没有 %s —— 跑一次 android_plugins/glory_signin/build_aar.ps1" % AAR_PATH):
		return
	var recorded := ""
	if zr.get_files().has("glory_signin_source.sha256"):
		recorded = zr.read_file("glory_signin_source.sha256").get_string_from_utf8().strip_edges()
	zr.close()
	var actual := _source_digest()
	_h.expect(not actual.is_empty() and recorded == actual, "aar_stale",
		("插件包不是照着现在的源码打的（包里 %s…，源码 %s…）。改了 Kotlin / 清单 / Gradle 配置 / 保留规则之后"
			+ "要重跑 android_plugins/glory_signin/build_aar.ps1。") % [recorded.left(12), actual.left(12)])


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


func _case_dependency_versions_agree() -> void:
	var gradle := FileAccess.get_file_as_string(GRADLE_PATH)
	var export_plugin := FileAccess.get_file_as_string(EXPORT_PLUGIN_PATH)
	for artifact in RUNTIME_ARTIFACTS:
		var compiled := _version_in(gradle, artifact)
		var shipped := _version_in(export_plugin, artifact)
		_h.expect(not compiled.is_empty() and compiled == shipped, "dependency_version_mismatch",
			"%s：编译用 %s，出包交给 Gradle 的是 %s。两边必须一样，不然装上去第一次点 Google 就可能崩"
				% [artifact, compiled, shipped])


static func _version_in(text: String, artifact: String) -> String:
	var re := RegEx.new()
	re.compile("\"" + artifact.replace(".", "\\.") + ":([^\"]+)\"")
	var found := re.search(text)
	return "" if found == null else found.get_string(1)


func _case_plugin_wiring() -> void:
	var kotlin := FileAccess.get_file_as_string(KOTLIN_PATH)
	var manifest := FileAccess.get_file_as_string(MANIFEST_PATH)
	var project := FileAccess.get_file_as_string("res://project.godot")
	var export_plugin := FileAccess.get_file_as_string(EXPORT_PLUGIN_PATH)
	_h.expect(manifest.contains("org.godotengine.plugin.v2." + SignInBridge.SINGLETON)
			and manifest.contains("com.glory.signin.GlorySignInPlugin"),
		"manifest_plugin_name", "清单里的插件名必须是 org.godotengine.plugin.v2.%s，Godot 才找得到它" % SignInBridge.SINGLETON)
	_h.expect(kotlin.contains("getPluginName(): String = \"%s\"" % SignInBridge.SINGLETON),
		"singleton_name_mismatch", "Kotlin 的 getPluginName 与 SignInBridge.SINGLETON 对不上：Engine.has_singleton 永远是 false")
	for method in BRIDGE_METHODS:
		var re := RegEx.new()
		re.compile("@UsedByGodot\\s+fun " + method + "\\(")
		_h.expect(re.search(kotlin) != null, "bridge_method_missing",
			"Kotlin 桥接缺 @UsedByGodot fun %s —— SignInBridge 调它会直接报错" % method)
	_h.expect(project.contains("res://addons/glory_signin/plugin.cfg"), "export_plugin_disabled",
		"project.godot 没启用 addons/glory_signin：出包时不会带上插件，启动页永远没有 Google 按钮")
	_h.expect(export_plugin.contains("\"glory_signin/bin/GlorySignIn.aar\""), "export_plugin_aar_path",
		"导出插件交出的 AAR 路径与 build_aar.ps1 的产物对不上")


# 身份证明一小时内能拿来登录：桥接的日志里绝不能有它。
func _case_kotlin_never_logs_the_token() -> void:
	var kotlin := FileAccess.get_file_as_string(KOTLIN_PATH)
	for line in kotlin.split("\n"):
		if line.contains("Log."):
			_h.expect(not line.to_lower().contains("idtoken") and not line.contains("id_token"),
				"kotlin_logs_token", "桥接的日志行里出现了身份证明：%s" % line.strip_edges())


# --- GDScript 一侧 ---------------------------------------------------------------

func _case_unavailable_without_plugin() -> void:
	SignInBridge.bridge_override = null
	# 无界面跑门禁的这台电脑上没有安卓插件：必须报不可用，启动页和资料页都不出 Google 按钮。
	_h.expect(not SignInBridge.google_available() and not SignInBridge.any_available(),
		"available_without_plugin", "没有插件时 SignInBridge 不该报可用")
	_h.expect(not SignInBridge.apple_available(), "apple_before_ios_phase",
		"Apple 登录要等 iOS 那一期，现在必须恒为不可用")


func _case_sign_in_flows() -> void:
	var fake := FakeBridge.new()
	SignInBridge.bridge_override = fake
	_h.expect(SignInBridge.google_available(), "fake_not_available", "替身报可用时 SignInBridge 也该报可用")
	fake.available = false
	_h.expect(not SignInBridge.google_available(), "no_play_services_still_available",
		"没有 Google 服务（isGoogleAvailable=false）时不该报可用")
	fake.available = true

	fake.replies = ['{"state":"pending"}', '{"state":"ok","id_token":"tok-123"}']
	var ok: Dictionary = await SignInBridge.sign_in_google(get_tree())
	_h.expect(bool(ok.get("ok", false)) and str(ok.get("id_token", "")) == "tok-123", "ok_not_passed_through",
		"等到 ok 之后要把身份证明交出来")
	_h.expect(fake.client_id == AccountConfig.GOOGLE_WEB_CLIENT_ID, "wrong_client_id",
		"交给 Google 的必须是 Web 客户端编号（Supabase 只认它）")
	var raw_nonce := str(ok.get("nonce", ""))
	_h.expect(raw_nonce.length() >= 32 and fake.hashed_nonce == raw_nonce.sha256_text(), "nonce_mismatch",
		"交给 Google 的必须是 nonce 的 SHA-256、交给账号服务器的是原文，否则 Supabase 核对不上")

	fake.replies = ['{"state":"cancelled"}']
	var cancelled: Dictionary = await SignInBridge.sign_in_google(get_tree())
	_h.expect(not bool(cancelled.get("ok", true)) and bool(cancelled.get("cancelled", false))
			and not cancelled.has("error"), "cancel_shown_as_error", "玩家自己关掉弹窗不是错误，不该给错误文案")

	fake.replies = ['{"state":"no_account"}']
	var none: Dictionary = await SignInBridge.sign_in_google(get_tree())
	_h.expect(not bool(none.get("ok", true)) and str(none.get("error", "")).contains("Google 账号"),
		"no_account_message", "手机上没有 Google 账号时要说清楚去哪加")

	fake.replies = ['{"state":"error","error":"28444: Developer console is not set up correctly"}']
	var failed: Dictionary = await SignInBridge.sign_in_google(get_tree())
	_h.expect(not bool(failed.get("ok", true)) and not str(failed.get("error", "")).contains("28444"),
		"raw_error_shown", "插件的原始报错只进日志，玩家看一句人话")

	fake.begin_result = -1
	var unstarted: Dictionary = await SignInBridge.sign_in_google(get_tree())
	_h.expect(not bool(unstarted.get("ok", true)), "begin_failure_ignored", "发不起来（-1）必须当失败")
	SignInBridge.bridge_override = null


func _case_token_claims() -> void:
	var guest := _fake_jwt({"sub": "u1", "is_anonymous": true})
	var linked := _fake_jwt({"sub": "u1", "is_anonymous": false})
	_h.expect(bool(AccountManager.token_claims(guest).get("is_anonymous", false)), "guest_not_detected",
		"游客令牌的 is_anonymous 读不出来：红点和资料页那句话都会错")
	_h.expect(not bool(AccountManager.token_claims(linked).get("is_anonymous", true)), "linked_shown_as_guest",
		"绑过的令牌被读成游客")
	_h.expect(AccountManager.token_claims("").is_empty() and AccountManager.token_claims("a.%%%.c").is_empty(),
		"garbage_token_claims", "坏令牌要读成空，不能报错")


static func _fake_jwt(claims: Dictionary) -> String:
	var body := Marshalls.utf8_to_base64(JSON.stringify(claims)).replace("+", "-").replace("/", "_").rstrip("=")
	return "eyJhbGciOiJFUzI1NiJ9.%s.sig" % body


func _case_entry_view_choose() -> void:
	var view: Dictionary = Bootstrap.entry_view({"login": "choose"})
	_h.expect(str(view.get("state", "")) == "choose" and not bool(view.get("pass", false)), "choose_not_shown",
		"等玩家选登录方式时启动页要显示三个按钮，不能放行")
	_h.expect(str(Bootstrap.entry_view({"login": "choose", "banned": true}).get("state", "")) == "banned",
		"banned_hidden_by_choose", "被封压过一切")
	_h.expect(str(Bootstrap.entry_view({"login": "choose", "kicked": true}).get("state", "")) == "kicked",
		"kicked_hidden_by_choose", "被顶号压过一切")


# --- 新装时 login() 要停下来问 --------------------------------------------------------
# 会碰真实的 user://glory_account.json，所以同 account_check：先备份、最后还原。

func _backup_existing() -> void:
	_had_file = FileAccess.file_exists(SaveManager.ACCOUNT_PATH)
	if _had_file:
		_backup_text = FileAccess.get_file_as_string(SaveManager.ACCOUNT_PATH)


func _restore_existing() -> void:
	SaveManager.clear_account_credentials()
	if not _had_file:
		return
	var f := FileAccess.open(SaveManager.ACCOUNT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(_backup_text)


func _case_login_stops_for_choice() -> void:
	if AccountManager.is_logged_in():
		_h.note("AccountManager 已登录，跳过「新装时停下来问」")
		return
	SaveManager.clear_account_credentials()
	var fake := FakeBridge.new()
	SignInBridge.bridge_override = fake
	# 没凭证、又能用 Google：login() 必须**不发任何请求**就停下来（发了就是自动开了一个游客号）。
	AccountManager.login()
	_h.expect(AccountManager.awaiting_choice and AccountManager.state == AccountManager.State.IDLE,
		"login_did_not_wait_for_choice", "新装时 login() 没停下来等玩家选：换手机的老玩家会被塞进一个新游客号")
	AccountManager.logout()
	_h.expect(not AccountManager.awaiting_choice, "logout_kept_choice_state",
		"登出之后「等玩家选」的状态要清掉（下一次 login() 重新判断）")
	SignInBridge.bridge_override = null
