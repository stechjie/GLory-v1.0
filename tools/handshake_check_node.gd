extends Node

# 握手的**真实网络**验证（E1 / C10）。
#
# 这是目前唯一一个 L2 级用例：服务端和客户端是两个真的 ENet peer，
# 认证数据真的过网线，而不是直接调函数。
#
# 三个场景：
#   ok        协议号一致        -> 应当连上
#   bad       协议号伪造成别的  -> 应当在**连接建立之前**被拒，并给出原因
#   silent    完全不发认证数据  -> 应当被 auth_timeout 拒掉（模拟旧版本客户端）
#
# 用法：godot --headless --path <proj> tools/handshake_check.tscn -- --hs-case=ok|bad|silent

const PORT := 8091
const CASE_TIMEOUT_SEC := 14.0

var _case := "ok"
var _server_peer: ENetMultiplayerPeer
var _client_mp: SceneMultiplayer
var _client_peer: ENetMultiplayerPeer
var _connected := false
var _rejected := ""
var _deadline := 0.0

func _ready() -> void:
	_case = _arg("--hs-case", "ok")
	# 服务端用主 MultiplayerAPI（NetworkService 已经在 _ready 里配好 auth_callback）
	NetworkService.enter_test_server_mode()
	NetworkService._dedicated_server = true
	_server_peer = ENetMultiplayerPeer.new()
	if _server_peer.create_server(PORT, 8) != OK:
		print("[HS] FATAL: cannot listen on %d" % PORT)
		get_tree().quit(2)
		return
	multiplayer.multiplayer_peer = _server_peer

	# 客户端用**独立的 SceneMultiplayer**（同进程但走真实 ENet 回环）。
	# 不能复用主 API：那是服务端的，auth_callback 会按服务端分支跑。
	_client_mp = SceneMultiplayer.new()
	_client_mp.auth_timeout = NetworkService.AUTH_TIMEOUT_SEC
	_client_mp.auth_callback = _client_auth_callback
	_client_mp.peer_authenticating.connect(_client_authenticating)
	_client_mp.peer_authentication_failed.connect(_client_auth_failed)
	_client_mp.connected_to_server.connect(func(): _connected = true)
	_client_peer = ENetMultiplayerPeer.new()
	if _client_peer.create_client("127.0.0.1", PORT) != OK:
		print("[HS] FATAL: cannot create client")
		get_tree().quit(2)
		return
	_client_mp.multiplayer_peer = _client_peer
	_deadline = Time.get_ticks_msec() / 1000.0 + CASE_TIMEOUT_SEC

func _process(_delta: float) -> void:
	if _client_mp != null:
		_client_mp.poll()
	if _connected or not _rejected.is_empty():
		_finish()
		return
	if Time.get_ticks_msec() / 1000.0 >= _deadline:
		_rejected = "timeout"
		_finish()

func _client_authenticating(id: int) -> void:
	match _case:
		"ok":
			_client_mp.send_auth(id, NetworkService._client_hello_bytes())
		"bad":
			# 伪造一个不同的协议号 —— 模拟"旧客户端连新服务器"
			_client_mp.send_auth(id, var_to_bytes({
				"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION + 1,
				"build": "", "data_manifest": "", "sim_manifest": "",
			}))
		_:
			# silent：什么都不发，等服务端 auth_timeout
			pass

func _client_auth_callback(id: int, data: PackedByteArray) -> void:
	var value = bytes_to_var(data)
	var verdict: Dictionary = value if typeof(value) == TYPE_DICTIONARY else {}
	if bool(verdict.get("ok", false)):
		_client_mp.complete_auth(id)
	else:
		_rejected = str(verdict.get("code", "unknown"))

func _client_auth_failed(_id: int) -> void:
	if _rejected.is_empty():
		_rejected = "auth_timeout"

func _finish() -> void:
	set_process(false)
	var ok := false
	var detail := ""
	match _case:
		"ok":
			ok = _connected and _rejected.is_empty()
			detail = "connected=%s rejected=%s" % [_connected, _rejected]
		"bad":
			# 必须被拒、且**没有建立连接**，还要带上可读的原因
			ok = (not _connected) and _rejected == "protocol_mismatch"
			detail = "connected=%s rejected=%s (want protocol_mismatch)" % [_connected, _rejected]
		"silent":
			ok = (not _connected) and not _rejected.is_empty()
			detail = "connected=%s rejected=%s (want any rejection)" % [_connected, _rejected]
	print("[HS] case=%-6s %s | %s" % [_case, "PASS" if ok else "FAIL", detail])
	get_tree().quit(0 if ok else 3)

func _arg(key: String, fallback: String) -> String:
	var prefix := key + "="
	# `--` 之后的参数**只**出现在 get_cmdline_user_args()，不在 get_cmdline_args() 里。
	# 只查后者会让 --hs-case 被静默忽略，三个用例全部退化成默认的 "ok" —— 看起来
	# 三连 PASS，其实 bad/silent 从来没跑过。
	for source in [OS.get_cmdline_user_args(), OS.get_cmdline_args()]:
		for a in source:
			if str(a).begins_with(prefix):
				return str(a).substr(prefix.length())
	return fallback
