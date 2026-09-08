extends Node

# 账号链路的**真实**验收：Godot -> FastAPI -> Supabase 打通一次。
#
# ⚠️ **手动运行，不进核心门禁清单。** 它需要后端在跑、需要真实的 .env 凭据。
# 让门禁依赖某人本机的配置就是另一种假绿（同 backend/tests 里那条说明）。
#
# 前置：
#   cd backend && .venv/Scripts/python -m uvicorn app.main:app --port 8099
#
# 运行：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/account_live_check.tscn
#
# 覆盖两次「启动」：
#   第一次 —— 本地没有凭证 -> 走 /v1/auth/anonymous，created 应为 true
#   第二次 —— 本地有凭证   -> 走 /v1/auth/refresh，player_id 必须**不变**
#
# 第二条是这条链路最要命的判据：走错分支（重复注册）不会报错，
# 只会让玩家每次启动都变成新玩家，进度看起来就没了。

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "account_live"

var _h: CheckHarness
var _backup_text := ""
var _had_file := false
# 用例可能触发 409 → reissue_player_id()，那会改掉开发者本机的身份。
# 检查不该有这种副作用，结束前还原。
var _backup_player_id := ""


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_had_file = FileAccess.file_exists(SaveManager.ACCOUNT_PATH)
	if _had_file:
		_backup_text = FileAccess.get_file_as_string(SaveManager.ACCOUNT_PATH)
	_backup_player_id = PlayerProfile.player_id
	await _run()
	_restore()
	_h.finish(get_tree())


func _restore() -> void:
	# 先还原 player_id：本用例清掉凭证模拟「全新安装」，但 profile.json 里的
	# id 还在，服务器会以 409 拒绝（不许凭一个 id 接管已有账号），客户端于是
	# 重签一个。那是**正确的产品行为**，但作为检查的副作用不可接受 ——
	# 跑一次门禁就把开发者换成另一个玩家。
	if not _backup_player_id.is_empty() and PlayerProfile.player_id != _backup_player_id:
		PlayerProfile.player_id = _backup_player_id
		PlayerProfile.save_profile()
	SaveManager.clear_account_credentials()
	if not _had_file:
		return
	var f := FileAccess.open(SaveManager.ACCOUNT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(_backup_text)


func _run() -> void:
	var mgr := get_node_or_null("/root/AccountManager")
	if not _h.expect(mgr != null, "autoload_missing", "AccountManager 没挂上"):
		return

	# 从"干净安装"开始
	SaveManager.clear_account_credentials()

	# --- 第一次启动：应当走匿名注册 ---
	await mgr.call("login")
	if not _h.expect(bool(mgr.call("is_logged_in")),
		"first_login_failed", "第一次登录失败：%s" % str(mgr.get("last_error"))):
		return

	# 注意：本机 player_id 若已在库里注册过，服务器会回 409，客户端重签一个
	# 再试（AccountManager.login 里那段）。所以这里比对的是**当前**的
	# PlayerProfile.player_id，不是用例开始时那个。
	var first_id := str(mgr.get("player_id"))
	_h.expect(first_id == PlayerProfile.player_id,
		"server_id_mismatch",
		"服务器返回的 player_id 应与本机签发的一致：服务器 %s / 本机 %s" % [
			first_id, PlayerProfile.player_id])
	_h.expect(not str(mgr.call("access_token")).is_empty(),
		"no_access_token", "登录后内存里应当有 access token")

	var saved := SaveManager.load_account_credentials()
	_h.expect(not str(saved.get("refresh_token", "")).is_empty(),
		"refresh_not_saved", "登录后 refresh token 必须落盘，否则下次启动登不回来")

	# --- 第二次启动：有凭证，必须走 refresh 而不是再注册一个 ---
	var before_refresh := str(saved.get("refresh_token", ""))
	mgr.set("state", 0)   # State.IDLE
	mgr.set("_busy", false)
	await mgr.call("login")

	if not _h.expect(bool(mgr.call("is_logged_in")),
		"second_login_failed", "第二次登录失败：%s" % str(mgr.get("last_error"))):
		return
	_h.expect(str(mgr.get("player_id")) == first_id,
		"identity_changed_on_relaunch",
		"第二次启动必须还是同一个玩家：%s -> %s" % [first_id, str(mgr.get("player_id"))])

	var after := SaveManager.load_account_credentials()
	_h.expect(str(after.get("refresh_token", "")) != before_refresh,
		"refresh_not_rotated",
		"Supabase 会轮换 refresh token，落盘的必须是新的那个")
