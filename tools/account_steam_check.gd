extends Node

# 电脑版 Steam 登录的客户端一侧（docs/三方登录设计.md 第八节）。
#
# 守的都是静默失效：
#   - 插件里带进了安卓 / Linux 的库 → 手机包或战斗服务器里跑起 Steam；
#   - 客户端的 App ID / 票的 identity 和账号服务器对不上 → Steam 一律说「票不对」；
#   - 拿票时收到别人的票（信号是广播的）→ 交上去的是错的票；
#   - 共用电脑时拿着上一个人的凭证登录 → B 进到 A 的号里；
#   - 资料页 / 启动页没接上 → 电脑上永远只看到游客按钮，手机上永远没有「关联电脑」。
#
# 运行：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/account_steam_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const SteamBridge := preload("res://scripts/account/SteamBridge.gd")

const CHECK_NAME := "account_steam"
const GDEXTENSION := "res://addons/godotsteam/godotsteam.gdextension"
const BACKEND_CONFIG := "res://backend/app/config.py"

var _h: CheckHarness
var _backup_account := ""
var _had_account := false
var _backup_owner := ""
var _had_owner := false


class FakeSteam extends RefCounted:
	signal get_ticket_for_web_api(auth_ticket: int, result: int, ticket_size: int, ticket_buffer: PackedByteArray)
	var id := "76561198000000042"
	var asked_identity := ""
	var result := 1

	func getSteamID() -> int:
		return int(id)

	func getPersonaName() -> String:
		return "Gabe"

	func getAuthTicketForWebApi(identity: String) -> int:
		asked_identity = identity
		# 先来一张别人的票（信号是广播的），再来自己的。
		_emit.call_deferred(99, 1, PackedByteArray([0xde, 0xad]))
		_emit.call_deferred(7, result, PackedByteArray([0x14, 0x00, 0xab, 0xcd]))
		return 7

	func _emit(handle: int, p_result: int, buffer: PackedByteArray) -> void:
		get_ticket_for_web_api.emit(handle, p_result, buffer.size(), buffer)


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_plugin_is_windows_and_mac_only()
	_case_constants_match_the_backend()
	_case_unavailable_headless()
	await _case_ticket()
	_backup()
	_case_owner_round_trip()
	_case_shared_pc_does_not_reuse_credentials()
	_restore()
	_case_wiring()
	SteamBridge.bridge_override = null
	_h.finish(get_tree())


func _case_plugin_is_windows_and_mac_only() -> void:
	var cfg := FileAccess.get_file_as_string(GDEXTENSION)
	_h.expect(cfg.contains("windows.release.x86_64") and cfg.contains("windows.debug.x86_64"), "windows_missing",
		"godotsteam.gdextension 里没有 Windows 64 位库：电脑版没有 Steam")
	for forbidden in ["android.", "linux.", "ios."]:
		_h.expect(not cfg.contains("\n" + forbidden), "foreign_platform_" + forbidden.trim_suffix("."),
			"godotsteam.gdextension 里出现了 %s 的库：手机包 / 战斗服务器会加载 Steam" % forbidden.trim_suffix("."))
	for dir in ["androidarm64", "linux64", "linux32", "linuxarm64", "win32"]:
		_h.expect(not DirAccess.dir_exists_absolute("res://addons/godotsteam/" + dir), "foreign_dir_" + dir,
			"addons/godotsteam/%s 不该在仓库里（只留 win64 与 osx）" % dir)
	_h.expect(not FileAccess.file_exists("res://addons/godotsteam/godotsteam_plugin.gd"), "updater_plugin_present",
		"GodotSteam 自带的编辑器更新插件会自己上网下载新版，不该拷进来")
	# 每个 [libraries] / [dependencies] 指向的文件都得真的在。
	var re := RegEx.create_from_string("\"(res://addons/godotsteam/[^\"]+)\"")
	for found in re.search_all(cfg):
		_h.expect(FileAccess.file_exists(found.get_string(1)), "library_missing",
			"godotsteam.gdextension 指向的文件不存在：%s" % found.get_string(1))
	var server_zip := FileAccess.get_file_as_string("res://tools/make_server_zip.ps1")
	_h.expect(not server_zip.contains("\"addons\""), "server_zip_copies_addons",
		"战斗服务器包不该带 addons/（里面有 Steam）")


func _case_constants_match_the_backend() -> void:
	var cfg := FileAccess.get_file_as_string(BACKEND_CONFIG)
	_h.expect(cfg.contains("steam_app_id: int = %d" % SteamBridge.STEAM_APP_ID), "app_id_mismatch",
		"SteamBridge.STEAM_APP_ID 和 backend/app/config.py 的 steam_app_id 对不上")
	_h.expect(cfg.contains("steam_ticket_identity: str = \"%s\"" % SteamBridge.TICKET_IDENTITY), "identity_mismatch",
		"SteamBridge.TICKET_IDENTITY 和账号服务器的 steam_ticket_identity 对不上：Steam 会说每张票都不对")


func _case_unavailable_headless() -> void:
	SteamBridge.bridge_override = null
	# 无界面运行（门禁、战斗服务器）不连 Steam，哪怕插件在。
	_h.expect(not SteamBridge.available() and SteamBridge.steam_id().is_empty(), "headless_steam",
		"无界面运行时不该初始化 Steam")


func _case_ticket() -> void:
	var fake := FakeSteam.new()
	SteamBridge.bridge_override = fake
	_h.expect(SteamBridge.available() and SteamBridge.steam_id() == fake.id and SteamBridge.persona_name() == "Gabe",
		"fake_not_used", "替身在的时候 SteamBridge 要用它")
	var got: Dictionary = await SteamBridge.ticket(get_tree())
	_h.expect(bool(got.get("ok", false)) and str(got.get("ticket", "")) == "1400abcd", "wrong_ticket",
		"要交自己那张票（十六进制），不能拿到广播里别人的那张：%s" % str(got))
	_h.expect(fake.asked_identity == SteamBridge.TICKET_IDENTITY, "ticket_identity",
		"要票时没带 identity：账号服务器那边验不过")
	fake.result = 2
	var failed: Dictionary = await SteamBridge.ticket(get_tree())
	_h.expect(not bool(failed.get("ok", true)) and not str(failed.get("error", "")).is_empty(), "failed_ticket_ok",
		"Steam 没给票（result ≠ OK）必须当失败")
	SteamBridge.bridge_override = null


func _backup() -> void:
	_had_account = FileAccess.file_exists(SaveManager.ACCOUNT_PATH)
	if _had_account:
		_backup_account = FileAccess.get_file_as_string(SaveManager.ACCOUNT_PATH)
	_had_owner = FileAccess.file_exists(SteamBridge.OWNER_PATH)
	if _had_owner:
		_backup_owner = FileAccess.get_file_as_string(SteamBridge.OWNER_PATH)


func _restore() -> void:
	SaveManager.clear_account_credentials()
	if _had_account:
		var f := FileAccess.open(SaveManager.ACCOUNT_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_backup_account)
	SteamBridge.forget_owner()
	if _had_owner:
		SteamBridge.remember_owner(_backup_owner)


func _case_owner_round_trip() -> void:
	SteamBridge.remember_owner("76561198000000001")
	_h.expect(SteamBridge.remembered_owner() == "76561198000000001", "owner_not_saved", "记不住本机凭证是谁的 Steam")
	SteamBridge.forget_owner()
	_h.expect(SteamBridge.remembered_owner().is_empty(), "owner_not_forgotten", "忘不掉")


# 共用电脑：本机凭证是 A 的 Steam，现在登录 Steam 的是 B → 不能拿 A 的凭证去续期，要停下来让 B 自己用 Steam 进。
# 这一步**不发任何请求**：凭证在发请求之前就被扔掉了，接着停在「等玩家选」。
func _case_shared_pc_does_not_reuse_credentials() -> void:
	if AccountManager.is_logged_in():
		_h.note("AccountManager 已登录，跳过共用电脑那条")
		return
	var fake := FakeSteam.new()
	fake.id = "76561198000000002"
	SteamBridge.bridge_override = fake
	SaveManager.save_account_credentials("rt-belongs-to-a", "52c7027a-3f81-4a1e-9c2d-8b7e4f0a1234")
	SteamBridge.remember_owner("76561198000000001")
	AccountManager.login()
	_h.expect(str(SaveManager.load_account_credentials().get("refresh_token", "")).is_empty(), "foreign_credential_kept",
		"本机凭证属于另一个 Steam 用户时必须扔掉：不然 B 会进到 A 的号里")
	_h.expect(AccountManager.awaiting_choice and AccountManager.state == AccountManager.State.IDLE, "steam_did_not_wait",
		"扔掉之后要停在「用 Steam 进入 / 我在手机上玩过」，不能自动开游客号")
	AccountManager.logout()
	SteamBridge.bridge_override = null


func _case_wiring() -> void:
	var boot := FileAccess.get_file_as_string("res://scenes/bootstrap/Bootstrap.gd")
	_h.expect(boot.contains("AccountManager.login_with_steam()") and boot.contains("AccountManager.steam_link_begin()")
			and boot.contains("AccountManager.steam_link_status("), "bootstrap_not_wired",
		"启动页没接上 Steam 登录 / 关联码")
	var profile := FileAccess.get_file_as_string("res://scenes/menu/ProfileScreen.gd")
	_h.expect(profile.contains("AccountManager.steam_link_preview(") and profile.contains("AccountManager.steam_link_confirm("),
		"profile_not_wired", "资料页没接上「关联电脑」")
	# 先给玩家看 Steam 昵称再确认，这一步不能省（防止被骗着关联到别人的 Steam）。
	var preview_at := profile.find("AccountManager.steam_link_preview(")
	var confirm_dialog_at := profile.find("DialogService.confirm(", preview_at)
	var confirm_at := profile.find("AccountManager.steam_link_confirm(")
	_h.expect(preview_at >= 0 and confirm_dialog_at > preview_at and confirm_at > confirm_dialog_at, "confirm_skipped",
		"关联电脑必须先看昵称、弹确认，再真正关联")
	var account := FileAccess.get_file_as_string("res://scripts/autoload/AccountManager.gd")
	_h.expect(not account.contains("Steam.") or account.contains("SteamBridge."), "steam_class_used_directly",
		"AccountManager 不能直接写 Steam 类名：手机包和战斗服务器里没有这个插件")
	for path in ["res://scripts/autoload/AccountManager.gd", "res://scenes/bootstrap/Bootstrap.gd",
			"res://scenes/menu/ProfileScreen.gd", "res://scripts/account/SteamBridge.gd"]:
		var text := FileAccess.get_file_as_string(path)
		var direct := RegEx.create_from_string("(?<![A-Za-z_\"])Steam\\.[a-z]")
		_h.expect(direct.search(text) == null, "steam_class_used_directly",
			"%s 里直接写了 Steam 类名：没有插件的平台上整个脚本会解析失败" % path)
