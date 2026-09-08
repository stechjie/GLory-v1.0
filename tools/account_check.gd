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
	_case_auto_login_defaults_off()
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


# 自动登录默认必须是关的。
#
# 翻成 true 的前提是后端已经部署、DEFAULT_BACKEND_URL 指向它（C15）。
# 在那之前打开的后果很具体：任何没起后端的人每次启动都看到一次登录失败；
# 真出了包，每个玩家白建一个 Supabase 账号并占掉 MAU 额度。
#
# 同 ServerFlags 对 P1 经济账本的做法：功能先接上、开关先关着。
func _case_auto_login_defaults_off() -> void:
	# 直接访问常量。**不要**写成 AccountConfig.get_script_constant_map()：
	# 那是非静态方法，在类上直接调是**解析错误** —— 而解析错误会让整个检查场景
	# 根本跑不起来（既不 PASS 也不 FAIL，只是没有输出），比断言失败难查得多。
	_h.expect(not AccountConfig.AUTO_LOGIN_DEFAULT,
		"auto_login_on_by_default",
		"启动时自动登录必须默认关闭 —— 后端还没部署，打开等于给每个人制造一次失败")

	# 没有任何命令行开关时（门禁就是这个情形），结果必须跟默认值一致。
	_h.expect(AccountConfig.auto_login_enabled() == AccountConfig.AUTO_LOGIN_DEFAULT,
		"auto_login_flag_drift", "无命令行开关时 auto_login_enabled() 必须等于默认值")

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
