extends Node

# 通道映射的**真实网络**验证（B9）。
#
# 这一项和别的不一样：它没有"逻辑正确性"可以在同进程里断言 —— 通道号写错的后果
# 不是抛错，而是**包被静默丢弃**。所以只能真的过一遍 ENet，看包到没到。
#
# 两个进程（PowerShell 起 server 后台，再跑 client 前台）：
#   server  真的 start_dedicated_server，等客户端连上后往 CH_BULK 发一份 replay
#   client  team_join 连上，验证三件事：
#             1. pong 收到      -> unreliable 通道通（心跳不再排在大包后面）
#             2. replay 收到    -> CH_BULK 通（通道数申报正确，包没被丢）
#             3. room_state 收到 -> CH_CONTROL 仍然通（没把默认通道改坏）
#
# 用法：
#   godot --headless --path <proj> tools/channel_check.tscn -- --ch-role=server
#   godot --headless --path <proj> tools/channel_check.tscn -- --ch-role=client

const PORT := 8092
const SERVER_LIFETIME_SEC := 90.0
const CLIENT_TIMEOUT_SEC := 20.0
# 有意造一份"大到会触发分片重传"的 payload：小包在回环上永远不排队，
# 用小包测不出通道分离有没有生效。
const BULK_PAYLOAD_BYTES := 200000

var _role := "server"
var _deadline := 0.0
var _sent_bulk := {}          # peer_id -> true
var _got_replay := false
var _got_room_state := false
var _asked_room := false
var _done := false

func _ready() -> void:
	_role = _arg("--ch-role", "server")
	if _role == "server":
		NetworkService._shard_index = 9
		if not NetworkService.start_dedicated_server(PORT):
			print("[CH] FATAL: cannot listen on %d" % PORT)
			get_tree().quit(2)
			return
		multiplayer.peer_connected.connect(_on_peer_connected)
		_deadline = _now() + SERVER_LIFETIME_SEC
		print("[CH] server ready port=%d" % PORT)
		_dump_channel_info()
	else:
		NetworkService.team_replay_received.connect(func(): _got_replay = true)
		if not NetworkService.team_join("127.0.0.1", PORT):
			print("[CH] FATAL: cannot create client")
			get_tree().quit(2)
			return
		_deadline = _now() + CLIENT_TIMEOUT_SEC

func _process(_delta: float) -> void:
	if _done:
		return
	if _role == "server":
		if _now() >= _deadline:
			_done = true
			print("[CH] server done")
			get_tree().quit(0)
		return
	# --- client ---
	# 连上之后要开个房间，才会有 room_state 下来（CH_CONTROL 那一路的观测点）。
	if not _asked_room and NetworkService.state == NetworkService.SessionState.READY:
		_asked_room = true
		NetworkService.team_request_create_room()
	if int(NetworkService.team_local_slot) >= 0:
		_got_room_state = true   # 座位号只可能来自 CH_CONTROL 上的 room_state（E2）
	if _got_replay and _got_room_state:
		_finish()
		return
	if _now() >= _deadline:
		_finish()

# 记录 ENet host 实际有多少条通道。CH_BULK 落在系统通道之后，通道数不够时
# 包不会报错、只会消失 —— 所以这个数字必须打出来看，不能靠"包到了"反推。
# 实测不传 max_channels 时是 255；传具体数字只会把上限调低（见 NetworkConfig 注释）。
func _dump_channel_info() -> void:
	var host: ENetConnection = (multiplayer.multiplayer_peer as ENetMultiplayerPeer).host
	if host != null:
		print("[CH] enet host max_channels=%d (CH_BULK=%d)" % [
			host.get_max_channels(), NetworkConfig.CH_BULK])

func _on_peer_connected(peer_id: int) -> void:
	if _sent_bulk.has(peer_id):
		return
	_sent_bulk[peer_id] = true
	# 直接走真的 replay 通道，不另造探针 RPC —— 要验的就是这条 RPC 的通道设置。
	var blob := {"kind": "channel_probe", "frames": []}
	var frames: Array = blob["frames"]
	while var_to_bytes(blob).size() < BULK_PAYLOAD_BYTES:
		frames.append({"t": frames.size(), "pad": "0123456789abcdef".repeat(16)})
	var packed := NetworkService._pack_replay(blob)
	print("[CH] server -> peer=%d bulk bytes=%d (raw %d)" % [
		peer_id, packed.size(), var_to_bytes(blob).size()])
	NetworkService._rpc_team_replay.rpc_id(peer_id, packed, PackedByteArray())

func _finish() -> void:
	_done = true
	set_process(false)
	var ok := _got_replay and _got_room_state and NetworkService._last_pong_at > 0.0
	print("[CH] client %s | pong=%s bulk_replay=%s control_room_state=%s" % [
		"PASS" if ok else "FAIL",
		NetworkService._last_pong_at > 0.0, _got_replay, _got_room_state])
	get_tree().quit(0 if ok else 3)

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _arg(key: String, fallback: String) -> String:
	var prefix := key + "="
	# `--` 之后的参数只在 get_cmdline_user_args() 里（见测试台"假绿"三类）。
	for source in [OS.get_cmdline_user_args(), OS.get_cmdline_args()]:
		for a in source:
			if str(a).begins_with(prefix):
				return str(a).substr(prefix.length())
	return fallback
