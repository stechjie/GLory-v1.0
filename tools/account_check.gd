extends Node

# 账号层客户端侧的验收：凭证存储、门面接线、后端地址解析。
#
# 这里守的核心是一条**静默失效**的规则：
#
#     access token 永不落盘。落盘的只有 refresh token。
#
# 违反了不会报错、不会崩溃 —— 只是多了一份会出现在日志、崩溃报告、玩家截图里的
# 凭证。这类问题没有任何运行时症状，只能靠断言挡在上线之前。
#
# 用例会读写真实的 user://glory_account.json（路径是 const，没法注入），
# 所以开头备份、结尾还原 —— 不能因为跑了一次检查就把开发者的登录状态清掉。
#
# 运行：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/account_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const AccountConfig := preload("res://scripts/account/AccountConfig.gd")

const CHECK_NAME := "account"

var _h: CheckHarness
var _backup_text := ""
var _had_file := false


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_backup_existing()
	_case_credentials_round_trip()
	_case_access_token_is_never_persisted()
	_case_clear_removes_fallback_copies()
	_case_backend_url_shape()
	_case_manager_wiring()
	_case_auto_login_implies_https()
	_case_status_payload_is_safe()
	_case_failure_classification()
	_restore_existing()
	_h.finish(get_tree())


# --- 备份 / 还原 ---------------------------------------------------------------

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


# --- 用例 ---------------------------------------------------------------------

func _case_credentials_round_trip() -> void:
	SaveManager.save_account_credentials("rt-abc-123", "52c7027a-3f81-4a1e-9c2d-8b7e4f0a1234")
	var loaded := SaveManager.load_account_credentials()
	_h.expect(str(loaded.get("refresh_token", "")) == "rt-abc-123",
		"refresh_not_round_tripped", "refresh token 存进去又读出来必须一致")
	_h.expect(str(loaded.get("player_id", "")) == "52c7027a-3f81-4a1e-9c2d-8b7e4f0a1234",
		"player_id_not_round_tripped", "player_id 存进去又读出来必须一致")


# 本文件最重要的一条。
func _case_access_token_is_never_persisted() -> void:
	var forbidden := "eyJ_ACCESS_TOKEN_MUST_NEVER_BE_WRITTEN"
	SaveManager.save_account_credentials(forbidden, "52c7027a-3f81-4a1e-9c2d-8b7e4f0a1234")
	var raw := FileAccess.get_file_as_string(SaveManager.ACCOUNT_PATH)
	var parsed = JSON.parse_string(raw)
	if not _h.expect(typeof(parsed) == TYPE_DICTIONARY,
		"account_file_unparseable", "凭证文件必须是合法 JSON"):
		return
	# 落盘的键必须**恰好**是这两个。多出任何一个都要在这里炸 ——
	# 尤其是有人图方便顺手把 access_token 一起存了。
	var keys: Array = (parsed as Dictionary).keys()
	keys.sort()
	_h.expect(keys == ["player_id", "refresh_token"],
		"unexpected_persisted_keys",
		"凭证文件只允许 refresh_token 与 player_id，实得：%s" % str(keys))
	_h.expect(not raw.contains("access_token"),
		"access_token_persisted", "access token 绝不能落盘 —— 它只该待在内存里")


func _case_clear_removes_fallback_copies() -> void:
	# 原子写会留下 .bak。清凭证时如果只删主文件，下次启动会从 .bak 里
	# 把一个已经被服务器吊销的 token 读回来，然后再失败一次。
	# 这个坑 SaveManager 在 clear_reconnect 上已经踩过并写在注释里了。
	SaveManager.save_account_credentials("first", "52c7027a-3f81-4a1e-9c2d-8b7e4f0a1234")
	SaveManager.save_account_credentials("second", "52c7027a-3f81-4a1e-9c2d-8b7e4f0a1234")
	SaveManager.clear_account_credentials()
	for suffix in ["", ".bak", ".tmp"]:
		var path: String = SaveManager.ACCOUNT_PATH + suffix
		_h.expect(not FileAccess.file_exists(path),
			"stale_credential_file", "清凭证后不该还剩 %s" % path)
	_h.expect(SaveManager.load_account_credentials().is_empty(),
		"cleared_but_still_loads", "清掉之后再读必须是空的")


func _case_backend_url_shape() -> void:
	var url := AccountConfig.backend_url()
	_h.expect(not url.is_empty(), "backend_url_empty", "后端地址不能为空")
	_h.expect(not url.ends_with("/"),
		"backend_url_trailing_slash",
		"后端地址不能以 / 结尾，否则拼出来是 //v1/... ：%s" % url)
	_h.expect(url.begins_with("http://") or url.begins_with("https://"),
		"backend_url_scheme", "后端地址要带协议头：%s" % url)
	var joined := AccountConfig.endpoint("/v1/me")
	_h.expect(not joined.contains("//v1"),
		"endpoint_double_slash", "拼接出了双斜杠：%s" % joined)
	# 这里刻意**不**断言默认值是 https：本机开发就是明文 http。
	# 上线前换域名那一步由 RFC 第九节的待拍板清单覆盖。


func _case_manager_wiring() -> void:
	var mgr := get_node_or_null("/root/AccountManager")
	if not _h.expect(mgr != null, "autoload_missing", "AccountManager autoload 没挂上"):
		return
	_h.expect(not bool(mgr.call("is_logged_in")),
		"logged_in_at_boot", "刚启动时不该是已登录状态 —— 登录必须是显式调用")
	_h.expect(str(mgr.call("access_token")).is_empty(),
		"token_at_boot", "刚启动时内存里不该有 access token")
	# 门面完整性：UI 与玩法只认这几个入口，少一个就会有人绕过去自己拼 HTTP。
	for method in ["login", "logout", "is_logged_in", "access_token"]:
		_h.expect(mgr.has_method(method),
			"facade_method_missing", "AccountManager 缺少门面方法：%s" % method)


# 自动登录开着的时候，默认后端地址必须是 https 的公网地址。
#
# 这条取代了原来那条「自动登录必须默认关闭」——那条的前提是「后端还没部署」，
# 2026-09-09 后端上线后不再成立。
#
# 现在真正危险的组合是「自动登录开着 + 后端地址是本机或明文」：
#   - 指向 127.0.0.1：每个玩家的客户端去连**他自己的手机**，必然失败，
#     而登录失败目前对玩家是无感的 —— 没人会发现，直到账号真的开始承载数据。
#   - 明文 http：账号凭证（JWT / refresh token）过公网等于送出去；
#     Android 9+ 还会直接拒绝。
#
# 两者都不会在本机开发时暴露（本机连 127.0.0.1 当然是通的），只有出包给别人
# 才会炸 —— 正是需要断言挡住的那类。
func _case_auto_login_implies_https() -> void:
	var url: String = AccountConfig.DEFAULT_BACKEND_URL

	# 无命令行开关时（门禁就是这个情形），结果必须等于常量本身。
	_h.expect(AccountConfig.auto_login_enabled() == AccountConfig.AUTO_LOGIN_DEFAULT,
		"auto_login_flag_drift", "无命令行开关时 auto_login_enabled() 必须等于默认值")

	if AccountConfig.AUTO_LOGIN_DEFAULT:
		_h.expect(url.begins_with("https://"),
			"auto_login_over_plaintext",
			"自动登录开着时 DEFAULT_BACKEND_URL 必须是 https —— 账号凭证不能明文过公网：%s" % url)
		for local in ["127.0.0.1", "localhost", "192.168.", "10.0.", "0.0.0.0"]:
			_h.expect(not url.contains(local),
				"auto_login_points_at_localhost",
				"自动登录开着时后端地址不能是本机/内网地址（玩家连不上）：%s" % url)
	else:
		# 关着的话地址指向哪都无所谓，但记一条，免得检查集看起来是空的。
		_h.item()

	# Bootstrap 侧的挂载点还在。放在 Bootstrap 而不是 autoload 的 _ready，
	# 正是为了让 tools/ 下的检查场景不去建真实账号 —— 这条一旦被人挪回
	# autoload，整个门禁套件都会开始注册账号。
	var boot := load("res://scenes/bootstrap/Bootstrap.gd")
	if not _h.expect(boot != null, "bootstrap_unloadable", "Bootstrap.gd 载入失败"):
		return
	var method_names: Array = []
	for m in boot.get_script_method_list():
		method_names.append(str(m.get("name", "")))
	_h.expect("_kick_off_account_login" in method_names,
		"bootstrap_hook_missing",
		"Bootstrap 应保留 _kick_off_account_login —— 登录不能挪回 autoload 的 _ready")


# 结构化日志与 bug 报告里绝不能出现凭证。
#
# 这条守的是一类**静默泄漏**：加一个字段进 GLORY_ACCOUNT 很容易，而那行会进
# logcat、被贴进 issue、被截图。多带一个 token 出去不会有任何报错。
func _case_status_payload_is_safe() -> void:
	var mgr := get_node_or_null("/root/AccountManager")
	if not _h.expect(mgr != null, "autoload_missing", "AccountManager 没挂上"):
		return
	if not _h.expect(mgr.has_method("status_payload"),
		"status_payload_missing", "AccountManager 缺少 status_payload()"):
		return

	var keys: Array = (mgr.call("status_payload") as Dictionary).keys()
	keys.sort()
	_h.expect(keys == ["failure", "has_saved_credential", "player_id", "state"],
		"status_payload_keys_changed",
		"GLORY_ACCOUNT 的字段集合变了，先确认新字段不含凭证：%s" % str(keys))

	# 哨兵：把一个可识别的假令牌塞进内存，断言它不出现在输出里。
	var sentinel := "eyJ_ACCESS_TOKEN_MUST_NEVER_BE_LOGGED"
	var original := str(mgr.get("_access_token"))
	mgr.set("_access_token", sentinel)
	var dumped := JSON.stringify(mgr.call("status_payload"))
	mgr.set("_access_token", original)
	_h.expect(not dumped.contains(sentinel),
		"token_in_status_log", "access token 出现在了 GLORY_ACCOUNT 行里")
	_h.expect(not dumped.contains("last_error"),
		"last_error_in_status_log",
		"last_error 可能含后端地址，不该进结构化日志（IssueReport 的隐私规则同）")


# 失败分类的映射。分类是给日志和报告用的稳定标识，映射错了会让排查看错方向 ——
# 例如把限流（429）报成 UNKNOWN，就没人会想到去调额度。
func _case_failure_classification() -> void:
	var mgr := get_node_or_null("/root/AccountManager")
	if mgr == null:
		return
	var expected := {
		0: "OFFLINE",        # 请求没发出去 / 没收到响应
		429: "RATE_LIMITED",
		401: "AUTH_REJECTED",
		403: "AUTH_REJECTED",
		409: "CONFLICT",
		500: "SERVER_ERROR",
		502: "SERVER_ERROR",
		418: "UNKNOWN",      # 没归类的一律 UNKNOWN，而不是猜
	}
	var names: Array = mgr.get("Failure").keys()
	for code in expected:
		var got := str(names[int(mgr.call("classify", code))])
		_h.expect(got == expected[code],
			"classify_wrong", "HTTP %d 应归为 %s，实得 %s" % [code, expected[code], got])
