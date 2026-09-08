extends Node
# 账号门面。**Godot 侧唯一与账号后端说话的地方。**
#
# 这条规矩来自 docs/账号系统RFC.md 第三节：UI、玩法、商城都只认这个门面，
# 谁都不许自己拼 HTTP 请求。换后端时要改的是这一个文件，不是几十个 .gd。
# 与 NetworkService（战斗链路）平级 —— 那条走 ENet，这条走 HTTPS，互不相干。
#
# 启动流程：
#
#   本地有 refresh token？
#      有 ──> POST /v1/auth/refresh
#              成功 ──> 登录完成
#              401  ──> 凭证已失效，清掉，往下走
#      没有 ─> POST /v1/auth/anonymous（带上本机 player_id）
#
# ⚠️ **绝不能反过来先试匿名注册。** /v1/auth/anonymous 天然不幂等，
# 每调一次就在 Supabase 多一个用户、在 players 多一行 —— 玩家每次启动都会
# 变成新玩家，进度看起来就没了。有凭证时必须走 refresh。

const AccountConfig := preload("res://scripts/account/AccountConfig.gd")

signal login_started()
signal login_succeeded(player_id: String, player_name: String)
signal login_failed(reason: String)

enum State { IDLE, WORKING, LOGGED_IN, FAILED }

# 失败分类。**给日志与 bug 报告用的稳定标识，不是给玩家看的文案。**
#
# 为什么不直接用 last_error 那句话：它可能带上后端地址或上游返回的原文，
# 而 IssueReport 顶部的隐私规则明写着「绝不带服务器地址」——报告是要被粘进
# 聊天窗口的。分类是枚举名，粘到哪都安全，而且不会因为改了一句提示文案就让
# 日志里的历史记录对不上。
enum Failure {
	NONE,
	OFFLINE,        # 请求没发出去 / 没收到响应：断网、后端没起、DNS、超时
	RATE_LIMITED,   # 429，注册太频繁
	SERVER_ERROR,   # 5xx，后端或它上游出错
	AUTH_REJECTED,  # 401，凭证不再有效（正常流程会自动改走注册，走到这说明注册也失败了）
	CONFLICT,       # 409 且重签后仍冲突
	BAD_RESPONSE,   # HTTP 200 但响应里缺东西
	UNKNOWN,
}

var state: int = State.IDLE
var player_id := ""
var player_name := ""
# 给人看的一句话，可能含地址等细节。**不要**把它写进结构化日志或 IssueReport。
var last_error := ""
# 给机器看的分类，可以安全地进日志与报告。
var last_failure: int = Failure.NONE

# access token **只在内存里**，永不落盘。
#
# 它一小时就过期，存它没有任何收益，却多一处会泄漏的地方（日志、崩溃报告、
# 玩家发来的截图）。落盘的只有 refresh token，在 SaveManager.ACCOUNT_PATH。
var _access_token := ""

var _http: HTTPRequest = null
var _busy := false


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = AccountConfig.REQUEST_TIMEOUT_SEC
	add_child(_http)


func is_logged_in() -> bool:
	return state == State.LOGGED_IN and not player_id.is_empty()


# 内存里的 access token。给以后需要带令牌的接口用；**不要写进任何文件或日志**。
func access_token() -> String:
	return _access_token


# --- 登录 ---------------------------------------------------------------------

# 启动时调一次。重复调用在进行中会被忽略，避免连点两次开出两个账号。
func login() -> void:
	if _busy:
		return
	_busy = true
	state = State.WORKING
	last_error = ""
	last_failure = Failure.NONE
	login_started.emit()

	var saved: Dictionary = SaveManager.load_account_credentials()
	var refresh_token := str(saved.get("refresh_token", ""))
	if not refresh_token.is_empty():
		var refreshed := await _post("/v1/auth/refresh", {"refresh_token": refresh_token})
		if int(refreshed.get("code", 0)) == 200:
			_finish_success(refreshed.get("body", {}))
			return
		if int(refreshed.get("code", 0)) == 401:
			# 凭证过期 / 已被轮换掉 / 被吊销。清干净再走注册，
			# 留着只会让下次启动再失败一次。
			print("[ACCOUNT] refresh 凭证已失效，改走匿名注册")
			SaveManager.clear_account_credentials()
		else:
			# 网络不通、后端没起、5xx —— 这些**不是**凭证问题。
			# 这时候绝不能去注册新账号：那会把一个临时故障变成永久丢号。
			_finish_failure(str(refreshed.get("error", "刷新失败")),
				classify(int(refreshed.get("code", 0))))
			return

	var created := await _post("/v1/auth/anonymous", {"player_id": PlayerProfile.player_id})
	if int(created.get("code", 0)) == 200:
		_finish_success(created.get("body", {}))
		return
	if int(created.get("code", 0)) == 409:
		# 本机签发的 player_id 撞号了（概率约等于零）。服务器不许我们接管别人的
		# 账号，只能重签一个再试一次。见 backend/app/routes/auth.py 里同一处说明。
		push_warning("[ACCOUNT] player_id 已被占用，重新签发后重试")
		PlayerProfile.reissue_player_id()
		var retried := await _post("/v1/auth/anonymous", {"player_id": PlayerProfile.player_id})
		if int(retried.get("code", 0)) == 200:
			_finish_success(retried.get("body", {}))
			return
		_finish_failure(str(retried.get("error", "注册失败")),
			classify(int(retried.get("code", 0))))
		return
	_finish_failure(str(created.get("error", "注册失败")),
		classify(int(created.get("code", 0))))


func logout() -> void:
	SaveManager.clear_account_credentials()
	_access_token = ""
	player_id = ""
	player_name = ""
	state = State.IDLE


func _finish_success(body: Dictionary) -> void:
	player_id = str(body.get("player_id", ""))
	player_name = str(body.get("player_name", ""))
	_access_token = str(body.get("access_token", ""))
	var refresh_token := str(body.get("refresh_token", ""))

	# ⚠️ 必须存**返回的**那个 refresh token。Supabase 默认轮换，
	# 存回旧的等于下次刷新必失败。
	if not refresh_token.is_empty() and not player_id.is_empty():
		SaveManager.save_account_credentials(refresh_token, player_id)

	state = State.LOGGED_IN
	last_failure = Failure.NONE
	_busy = false
	# 只打 player_id，**不打任何 token**。
	print("[ACCOUNT] 登录成功 player_id=%s" % player_id)
	_emit_status()
	login_succeeded.emit(player_id, player_name)


func _finish_failure(reason: String, failure: int = Failure.UNKNOWN) -> void:
	state = State.FAILED
	last_error = reason
	last_failure = failure
	_busy = false
	# push_warning 只在编辑器/调试里显眼，真机上没人看得到；结构化那行才是
	# 能在 logcat 里被 tools/android_logcat_errors.py 扫到的。两条都留。
	push_warning("[ACCOUNT] 登录失败：%s" % reason)
	_emit_status()
	login_failed.emit(reason)


# 把 HTTP 结果映射成稳定分类。
static func classify(code: int) -> int:
	if code == 0:
		return Failure.OFFLINE
	if code == 429:
		return Failure.RATE_LIMITED
	if code == 401 or code == 403:
		return Failure.AUTH_REJECTED
	if code == 409:
		return Failure.CONFLICT
	if code >= 500:
		return Failure.SERVER_ERROR
	return Failure.UNKNOWN


# 结构化状态行的载荷。**单独一个函数是为了能被门禁断言。**
#
# 硬规则：**不含任何凭证，也不含后端地址与 last_error。**
# 日志会进 logcat、会被贴进 issue、会被截图。player_id 是打的 ——
# 它不是凭证，而且没有它就没法把一份报告和库里的账号对上，那正是它的用途。
#
# tools/account_check.tscn 断言这里的键集合恰好是这四个，并用哨兵值验证
# 内存里的 access token 不会出现在输出里。加字段前先想清楚它会不会泄漏。
func status_payload() -> Dictionary:
	return {
		"state": State.keys()[state],
		"failure": Failure.keys()[last_failure],
		"player_id": player_id,
		"has_saved_credential": not str(
			SaveManager.load_account_credentials().get("refresh_token", "")).is_empty(),
	}


# 体例同 GLORY_STARTUP / GLORY_BUILD / GLORY_ISSUE，真机上 logcat 扫得到。
func _emit_status() -> void:
	print("GLORY_ACCOUNT %s" % JSON.stringify(status_payload()))


# --- HTTP --------------------------------------------------------------------

# 返回 {"code": int, "body": Dictionary, "error": String}。
# code 为 0 表示请求根本没发出去或没收到响应（断网、后端没起、超时）。
func _post(path: String, payload: Dictionary) -> Dictionary:
	var url := AccountConfig.endpoint(path)
	var headers := PackedStringArray(["Content-Type: application/json"])
	var err := _http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		return {"code": 0, "error": "请求发不出去（%s）" % error_string(err)}

	var result: Array = await _http.request_completed
	var outcome := int(result[0])
	var code := int(result[1])
	var raw := (result[3] as PackedByteArray).get_string_from_utf8()

	if outcome != HTTPRequest.RESULT_SUCCESS:
		# 连不上后端最常见：本机没起服务、真机上填了 127.0.0.1、明文被 Android 拦。
		return {"code": 0, "error": "连不上账号服务器（result=%d）" % outcome}

	var parsed = JSON.parse_string(raw)
	var body: Dictionary = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	if code == 200:
		return {"code": code, "body": body}
	# 后端的 detail 已经脱敏（backend 那边有测试钉着不含 token），可以直接显示。
	return {"code": code, "error": str(body.get("detail", "HTTP %d" % code))}
