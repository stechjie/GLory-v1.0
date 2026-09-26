extends Node

# 对**真实生产服务器**的连通性与线上兼容性探针。
#
# 存在的理由：D1 全程的硬约束是"facade API 不变、不改 RPC 名称和 payload"。
# 本机回环证明不了这一点 —— 回环两端跑的是同一份代码，改坏了也会一致地坏。
# 真正的证据是：**重构过的客户端，能不能和一台没改过、已部署的服务器对话。**
#
# 只做只读动作：连接 -> 握手 -> 拉一次公开房间列表 -> 断开。
# 不建房、不加入、不提交任何东西，不改服务端状态。
#
# 用法：
#   godot --headless --path . tools/live_server_probe.tscn [-- --probe-host=IP --probe-port=N]

const TIMEOUT_SEC := 25.0

var _deadline := 0.0
var _connected := false
var _rooms_seen := -1
var _room_list_received := false
var _done := false


func _ready() -> void:
	var host := _arg("--probe-host", NetworkConfig.SERVER_IP)
	var port := int(_arg("--probe-port", str(NetworkConfig.SERVER_PORT)))
	print("[LIVE] target=%s:%d protocol=%d" % [host, port, NetworkConfig.NETWORK_PROTOCOL_VERSION])

	NetworkService.session_changed.connect(_on_session_changed)
	if NetworkService.has_signal("team_room_list_received"):
		NetworkService.team_room_list_received.connect(_on_room_list)

	NetworkService.remote_address = host
	NetworkService.remote_port = port
	NetworkService.team_join(host, port)
	_deadline = Time.get_ticks_msec() / 1000.0 + TIMEOUT_SEC
	set_process(true)


func _process(_delta: float) -> void:
	if _done:
		return
	if _connected and _rooms_seen < 0:
		# 连上了就拉一次列表；这是唯一的请求，且是只读的。
		if NetworkService.has_method("team_request_room_list"):
			NetworkService.team_request_room_list()
			_rooms_seen = 0
	if Time.get_ticks_msec() / 1000.0 >= _deadline:
		_finish()


func _on_session_changed() -> void:
	var st: int = int(NetworkService.state)
	if st == NetworkService.SessionState.READY:
		_connected = true
		print("[LIVE] handshake ok, state=READY token=%s" % ("yes" if not str(NetworkService.session_token).is_empty() else "no"))
	elif st == NetworkService.SessionState.FAILED:
		print("[LIVE] FAILED last_error=%s" % str(NetworkService.last_error))
		_finish()


func _on_room_list(rooms: Array) -> void:
	_room_list_received = true
	_rooms_seen = rooms.size()
	print("[LIVE] room list received: %d 个公开房间" % _rooms_seen)
	_finish()


func _finish() -> void:
	if _done:
		return
	_done = true
	set_process(false)
	var ok := _connected and _room_list_received
	print("[LIVE] %s | connected=%s rooms=%s state=%d error=%s" % [
		"PASS" if ok else "FAIL", _connected, _rooms_seen, int(NetworkService.state), str(NetworkService.last_error)])
	NetworkService.reset()
	get_tree().quit(0 if ok else 3)


func _arg(key: String, fallback: String) -> String:
	var prefix := key + "="
	for source in [OS.get_cmdline_user_args(), OS.get_cmdline_args()]:
		for a in source:
			if str(a).begins_with(prefix):
				return str(a).substr(prefix.length())
	return fallback
