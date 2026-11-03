extends Node

# 战斗服务器 → 账号服务器：对局一结束就把签过章的战报直接交上去（2026-11-03）。
#
# 为什么不能只靠手机转交：转交的前提是「结束那一刻有人连着」。AI 补位开的桌只有一个真人，
# 他一退出（或掉线超时）这局就作废 —— 战报签了，可一个连着的人都没有，账号服务器收不到
# 就不结算：跑路不扣信誉分、不扣排位分，历史里也没有这局（11-02 测试服作废的 5 局全是这样）。
#
# 手机那条照留（NetworkService._submit_battle_report）：两边交的是同一串字节，
# 账号服务器按 match_uid 只记第一份，谁先到都一样。
#
# 走本机 http://127.0.0.1:8099（两个服务在同一台机器上，不经过 Caddy 和公网）。
# 账号服务器那边只收「本机、没经过 Caddy」的请求（backend/app/routes/battle_report.py），
# 所以两台以后分开放时，光改 GLORY_BATTLE_REPORT_UPLINK_URL 不够，还要另加鉴权。
#
# 异步、失败重试、只写日志 —— **绝不阻塞对局**。账号服务器重启（update.sh）一般几秒到
# 半分钟，重试排到约 4 分钟。本进程重启时还没交出去的会丢，手机那条兜着。
#
# 日志里只写对局编号和结果，不写战报本身（里面有全场玩家 id）。

const URL_ENV := "GLORY_BATTLE_REPORT_UPLINK_URL"
const DEFAULT_BASE_URL := "http://127.0.0.1:8099"
const PATH := "/v1/internal/battle/report"
const RETRY_DELAYS_SEC := [2.0, 5.0, 15.0, 30.0, 60.0, 120.0]
const TIMEOUT_SEC := 10.0

var url := ""
# 门禁把这两个调小，不用真等 4 分钟（Windows 上连本机关着的端口要等到超时才算失败）。
var retry_delays_sec: Array = RETRY_DELAYS_SEC
var timeout_sec := TIMEOUT_SEC
var _log: Callable = Callable()


# 环境变量给的是**完整地址**（含路径）；没给就是本机账号服务器。
static func configured_url() -> String:
	var custom := OS.get_environment(URL_ENV).strip_edges()
	return custom if not custom.is_empty() else DEFAULT_BASE_URL + PATH


func setup(log_fn: Callable) -> void:
	url = configured_url()
	_log = log_fn


func submit(match_uid: String, wire: String) -> void:
	_post(match_uid, wire, 0)


func _post(match_uid: String, wire: String, attempt: int) -> void:
	var http := HTTPRequest.new()
	http.timeout = timeout_sec
	add_child(http)
	http.request_completed.connect(_on_completed.bind(http, match_uid, wire, attempt))
	var headers := PackedStringArray(["Content-Type: application/json"])
	var err := http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify({"report": wire}))
	if err != OK:
		http.queue_free()
		_retry_or_log(match_uid, wire, attempt, "request_error=%d" % err)


func _on_completed(result: int, code: int, _headers: PackedStringArray, response: PackedByteArray,
		http: HTTPRequest, match_uid: String, wire: String, attempt: int) -> void:
	http.queue_free()
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		# recorded=false = 手机先交上了。是成功，不是重复提交。
		var body: Variant = JSON.parse_string(response.get_string_from_utf8())
		var recorded := body is Dictionary and bool((body as Dictionary).get("recorded", false))
		_write_log("battle report uplink ok match=%s recorded=%s tries=%d" % [match_uid, str(recorded), attempt + 1])
		return
	# 4xx = 这份战报本身（签名 / 格式 / 太旧）或这条通道（不是本机直连）有问题，
	# 重试多少次都一样。🔴 这条出现就是配置或我们自己的 bug，要能在日志里一眼看见。
	if result == HTTPRequest.RESULT_SUCCESS and code >= 400 and code < 500:
		_write_log("⚠ battle report uplink REJECTED match=%s http=%d %s" % [
			match_uid, code, response.get_string_from_utf8().left(160)])
		return
	_retry_or_log(match_uid, wire, attempt, "result=%d http=%d %s" % [
		result, code, response.get_string_from_utf8().left(120)])


func _retry_or_log(match_uid: String, wire: String, attempt: int, why: String) -> void:
	if attempt < retry_delays_sec.size() and is_inside_tree():
		get_tree().create_timer(float(retry_delays_sec[attempt])).timeout.connect(
			_post.bind(match_uid, wire, attempt + 1))
		return
	_write_log("⚠ battle report uplink GAVE UP match=%s tries=%d %s（有人连着的话手机那条还会交）" % [
		match_uid, attempt + 1, why])


func _write_log(line: String) -> void:
	if _log.is_valid():
		_log.call(line)
