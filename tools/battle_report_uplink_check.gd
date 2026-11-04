extends Node

# 门禁：战斗服务器直交战报（scripts/multiplayer/BattleReportUplink.gd，2026-11-03）。
#
# 账号服务器那一侧在 backend/tests/test_battle_report.py（只收本机直连、和手机那份去重）。
# 这里起一个本机假 HTTP 服务器顶替账号服务器，走真的 HTTPRequest，验四件事：
#
#   1. 发对地方、发对内容：POST 到 /v1/internal/battle/report，body 是 {"report": 原样那串}
#   2. 200 交一次就停
#   3. 4xx 不重试 —— 签名 / 格式坏了重试多少次都一样，重试只会刷屏
#   4. 5xx / 连不上会重试，用完才放弃，并且留一行 GAVE UP
#
# 跑：
#   godot --headless --path <项目> tools/battle_report_uplink_check.tscn

const Harness := preload("res://tools/CheckHarness.gd")
const Uplink := preload("res://scripts/multiplayer/BattleReportUplink.gd")

var h := Harness.new("battle_report_uplink")
var _server := TCPServer.new()
var _conns: Array = []          # [StreamPeerTCP, PackedByteArray]
var _replies: Array = []        # 按顺序回：[状态码, body]
var requests: Array = []        # {method, path, headers, body}
var logs: Array = []


func _ready() -> void:
	NetworkService.set_process(false)
	_check_url()
	if _server.listen(0, "127.0.0.1") != OK:
		h.expect(false, "listen", "本机假账号服务器起不来")
		h.finish(get_tree())
		return
	var base := "http://127.0.0.1:%d" % _server.get_local_port()

	# 1 + 2：200 一次就停，内容原样。
	var up := _uplink(base + Uplink.PATH)
	_replies = [[200, "{\"recorded\": true, \"match_uid\": \"%s\"}" % "a".repeat(32)]]
	up.submit("a".repeat(32), "Ym9keQ==.c2ln")
	await _until(func(): return _logged("uplink ok"))
	h.expect(requests.size() == 1, "ok_once", "200 只交一次，实测 %d 次" % requests.size())
	if requests.size() >= 1:
		var req: Dictionary = requests[0]
		h.expect(req.method == "POST" and req.path == Uplink.PATH, "ok_route",
			"应 POST %s，实测 %s %s" % [Uplink.PATH, req.method, req.path])
		h.expect(str(req.headers.get("content-type", "")).begins_with("application/json"), "ok_json",
			"Content-Type 应是 JSON，实测 %s" % str(req.headers.get("content-type", "")))
		h.expect(JSON.parse_string(req.body) == {"report": "Ym9keQ==.c2ln"}, "ok_body_verbatim",
			"战报必须原样放进 report 字段（账号服务器验的就是这串字节），实测 %s" % req.body)
		h.expect(not _has_forwarded_header(req.headers), "ok_no_forwarded",
			"直连请求不能带 X-Forwarded-*，账号服务器靠它分辨是不是从 Caddy 进来的")
	h.expect(_logged("recorded=true tries=1"), "ok_logged", "成功要留一行带 recorded 的日志：%s" % str(logs))

	# 3：4xx 不重试。
	_reset()
	up = _uplink(base + Uplink.PATH)
	_replies = [[400, "{\"detail\": \"战报签名验不过\"}"], [200, "{\"recorded\": true}"]]
	up.submit("b".repeat(32), "x.y")
	await _until(func(): return _logged("REJECTED"))
	await _wait(0.4)
	h.expect(requests.size() == 1, "reject_no_retry", "4xx 不该重试，实测交了 %d 次" % requests.size())
	h.expect(_logged("http=400"), "reject_logged", "被拒要留状态码：%s" % str(logs))

	# 4a：503（账号服务器在重启 / 数据库没连上）-> 重试，第二次成功。
	_reset()
	up = _uplink(base + Uplink.PATH)
	_replies = [[503, "{\"detail\": \"稍后再试\"}"], [200, "{\"recorded\": false}"]]
	up.submit("c".repeat(32), "x.y")
	await _until(func(): return _logged("uplink ok"))
	h.expect(requests.size() == 2, "unavailable_retried", "5xx 应重试，实测交了 %d 次" % requests.size())
	h.expect(_logged("recorded=false tries=2"), "unavailable_then_ok",
		"手机先交了 = recorded=false，也是成功：%s" % str(logs))

	# 4b：根本连不上（账号服务器没起）-> 重试用完才放弃。
	_reset()
	var dead := TCPServer.new()
	dead.listen(0, "127.0.0.1")
	var dead_port := dead.get_local_port()
	dead.stop()
	up = _uplink("http://127.0.0.1:%d%s" % [dead_port, Uplink.PATH])
	up.timeout_sec = 1.0
	up.submit("d".repeat(32), "x.y")
	await _until(func(): return _logged("GAVE UP"), 15.0)
	h.expect(_logged("GAVE UP match=%s tries=3" % "d".repeat(32)), "dead_gave_up_after_retries",
		"连不上要按重试表试满再放弃：%s" % str(logs))

	# 线上那张重试表要能扛过账号服务器一次重启（update.sh 一般几秒到半分钟）。
	var total := 0.0
	for d in Uplink.RETRY_DELAYS_SEC:
		total += float(d)
	h.expect(total >= 120.0, "retry_budget_covers_restart", "重试总时长只有 %s 秒" % str(total))

	_server.stop()
	h.finish(get_tree())


func _check_url() -> void:
	var saved := OS.get_environment(Uplink.URL_ENV)
	OS.unset_environment(Uplink.URL_ENV)
	h.expect(Uplink.configured_url() == "http://127.0.0.1:8099/v1/internal/battle/report", "default_url",
		"默认应交给本机账号服务器，实测 %s" % Uplink.configured_url())
	OS.set_environment(Uplink.URL_ENV, " http://10.0.0.2:8099/v1/internal/battle/report ")
	h.expect(Uplink.configured_url() == "http://10.0.0.2:8099/v1/internal/battle/report", "env_url",
		"环境变量给的地址应原样使用（去掉首尾空白），实测 %s" % Uplink.configured_url())
	if saved.is_empty():
		OS.unset_environment(Uplink.URL_ENV)
	else:
		OS.set_environment(Uplink.URL_ENV, saved)


func _uplink(url: String) -> Uplink:
	var up := Uplink.new()
	add_child(up)
	up.setup(func(line: String) -> void: logs.append(line))
	up.url = url
	up.retry_delays_sec = [0.05, 0.05]
	return up


func _reset() -> void:
	requests.clear()
	logs.clear()
	_replies.clear()


func _logged(fragment: String) -> bool:
	for line in logs:
		if str(line).contains(fragment):
			return true
	return false


func _has_forwarded_header(headers: Dictionary) -> bool:
	for name in headers:
		if str(name).begins_with("x-forwarded-"):
			return true
	return false


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _until(cond: Callable, timeout_sec: float = 5.0) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


# --- 假账号服务器：一次连接一个请求，回完就关 ---------------------------------------

func _process(_delta: float) -> void:
	while _server.is_listening() and _server.is_connection_available():
		_conns.append([_server.take_connection(), PackedByteArray()])
	for entry in _conns.duplicate():
		var peer: StreamPeerTCP = entry[0]
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_conns.erase(entry)
			continue
		var available := peer.get_available_bytes()
		if available > 0:
			var chunk: Array = peer.get_data(available)
			if int(chunk[0]) == OK:
				entry[1] = (entry[1] as PackedByteArray) + (chunk[1] as PackedByteArray)
		var req := _parse(entry[1])
		if req.is_empty():
			continue
		requests.append(req)
		var reply: Array = _replies.pop_front() if not _replies.is_empty() else [500, "{}"]
		var body := (reply[1] as String).to_utf8_buffer()
		var head := "HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [
			int(reply[0]), body.size()]
		peer.put_data(head.to_utf8_buffer() + body)
		peer.disconnect_from_host()
		_conns.erase(entry)


# 头收齐、body 按 Content-Length 收齐才算一个完整请求；否则返回空字典接着等。
func _parse(raw: PackedByteArray) -> Dictionary:
	var text := raw.get_string_from_utf8()
	var split := text.find("\r\n\r\n")
	if split < 0:
		return {}
	var lines := text.substr(0, split).split("\r\n")
	var first := lines[0].split(" ")
	var headers := {}
	for i in range(1, lines.size()):
		var colon := lines[i].find(":")
		if colon > 0:
			headers[lines[i].substr(0, colon).strip_edges().to_lower()] = lines[i].substr(colon + 1).strip_edges()
	var need := int(headers.get("content-length", "0"))
	var head_bytes := text.substr(0, split + 4).to_utf8_buffer().size()
	if raw.size() - head_bytes < need:
		return {}
	var body := raw.slice(head_bytes, head_bytes + need).get_string_from_utf8()
	return {"method": first[0] if first.size() > 0 else "", "path": first[1] if first.size() > 1 else "",
		"headers": headers, "body": body}
