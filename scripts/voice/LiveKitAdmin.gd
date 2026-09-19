extends Node

# 战斗服务器 → LiveKit 语音服务器的管理接口：踢人（RemoveParticipant）、删房间（DeleteRoom）。
# docs/语音LiveKit方案.md 3.3。
#
# 为什么要踢：钥匙只管进门。LiveKit 只在**首次进房**时检查钥匙，进去以后还会自动续 ——
# 玩家换队、离开、座位被 AI 接管、关房时，不主动请他出去，他就一直留在旧队伍的语音房间里听。
# 踢人时 LiveKit 会顺带作废他的钥匙（对已经离开的人调用也一样，官方文档说明）。
#
# 异步、失败重试两次、只写日志 —— **绝不阻塞对局**（语音挂了只影响语音）。
# 走本机 http://127.0.0.1:7880（同一台机器，不经过 Caddy 和公网）。
# 接口：POST {admin_url}/twirp/livekit.RoomService/<方法>，JSON 请求体，Authorization: Bearer <管理钥匙>。
#
# 日志里只写方法、房间名和结果，不写好友码（请求体里有）。

const Auth := preload("res://scripts/voice/LiveKitAuth.gd")
const RETRY_DELAYS_SEC := [1.0, 3.0]
const TIMEOUT_SEC := 5.0

var _config: Dictionary = {}
var _log: Callable = Callable()


func setup(config: Dictionary, log_fn: Callable) -> void:
	_config = config
	_log = log_fn


func remove_participant(room: String, identity: String) -> void:
	_post("RemoveParticipant", {"room": room, "identity": identity}, room, false, 0)


func delete_room(room: String) -> void:
	_post("DeleteRoom", {"room": room}, room, true, 0)


func _post(method: String, body: Dictionary, room: String, can_delete: bool, attempt: int) -> void:
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT_SEC
	add_child(http)
	http.request_completed.connect(_on_completed.bind(http, method, body, room, can_delete, attempt))
	# 每次（包括重试）现签：管理钥匙只有 60 秒。
	var token := Auth.admin_token(_config, room, int(Time.get_unix_time_from_system()), can_delete)
	var url := "%s/twirp/livekit.RoomService/%s" % [str(_config.get("admin_url", "")), method]
	var headers := PackedStringArray(["Content-Type: application/json", "Authorization: Bearer " + token])
	var err := http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		http.queue_free()
		_retry_or_log(method, body, room, can_delete, attempt, "request_error=%d" % err)


func _on_completed(result: int, code: int, _headers: PackedStringArray, response: PackedByteArray,
		http: HTTPRequest, method: String, body: Dictionary, room: String, can_delete: bool, attempt: int) -> void:
	http.queue_free()
	# 404 = 这个人不在房间里 / 房间已经没了：要的结果已经成立。
	if result == HTTPRequest.RESULT_SUCCESS and (code == 200 or code == 404):
		_write_log("voice %s ok room=%s http=%d" % [method, room, code])
		return
	_retry_or_log(method, body, room, can_delete, attempt,
		"result=%d http=%d %s" % [result, code, response.get_string_from_utf8().left(120)])


func _retry_or_log(method: String, body: Dictionary, room: String, can_delete: bool, attempt: int, why: String) -> void:
	if attempt < RETRY_DELAYS_SEC.size() and is_inside_tree():
		get_tree().create_timer(float(RETRY_DELAYS_SEC[attempt])).timeout.connect(
			_post.bind(method, body, room, can_delete, attempt + 1))
		return
	_write_log("voice %s FAILED room=%s tries=%d %s" % [method, room, attempt + 1, why])


func _write_log(line: String) -> void:
	if _log.is_valid():
		_log.call(line)
