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
#
# --ch-chunked=1：把回放走**分块**路径（D1：原始 README 的分块/确认/重试）。
# 这个模式存在的理由和本文件开头一样：分块包发错通道、拼错顺序、或者重组
# 无声失败，后果都不是抛错而是**回放不来**。同进程单测测不到这一层。
# 又因为实测最坏一场压缩后只有 61.8 KB、低于 192 KiB 阈值，生产里永远走不到
# 分块路径 —— 不强制跑一遍的话，那条代码路等于没人验。

const ReplayTransferService := preload("res://scripts/multiplayer/ReplayTransferService.gd")

const PORT := 8092
const SERVER_LIFETIME_SEC := 90.0
const CLIENT_TIMEOUT_SEC := 20.0
# 有意造一份"大到会触发分片重传"的 payload：小包在回环上永远不排队，
# 用小包测不出通道分离有没有生效。
const BULK_PAYLOAD_BYTES := 200000
# 分块模式下"压缩后"至少要有这么大，才能切出 3 块以上（CHUNK_PAYLOAD_BYTES = 48 KiB）。
# 只切一块的话，重组路径等于没测。
const CHUNKED_PACKED_MIN_BYTES := 160 * 1024

var _role := "server"
var _chunked := false
var _ack_ok := false
var _chunk_started := false
var _deadline := 0.0
var _sent_bulk := {}          # peer_id -> true
var _got_replay := false
var _got_room_state := false
var _asked_room := false
var _done := false

func _ready() -> void:
	_role = _arg("--ch-role", "server")
	_chunked = _arg("--ch-chunked", "0") == "1"
	if _role == "server":
		NetworkService._shard_index = 9
		if not NetworkService.start_dedicated_server(PORT):
			print("[CH] FATAL: cannot listen on %d" % PORT)
			get_tree().quit(2)
			return
		multiplayer.peer_connected.connect(_on_peer_connected)
		if _chunked:
			NetworkService.set_force_replay_chunking(true)
		_deadline = _now() + SERVER_LIFETIME_SEC
		print("[CH] server ready port=%d chunked=%s" % [PORT, _chunked])
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
		# 确认：客户端收齐后会回 _rpc_replay_ack，服务端据此把下发条目删掉。
		# _replay_out 空了就是"确认真的回来了" —— 这是唯一能证明确认链路
		# 跑通的观测点（客户端那边只知道自己发了，不知道服务端收没收到）。
		# _chunk_started 是必需的：没有它的话，一旦分块根本没发生（比如阈值
		# 判断被改坏、走了单包路径），_replay_out 从一开始就是空的，
		# ack_ok 会立刻变 true —— 一个什么都没验的假绿。
		if _chunked and _chunk_started and NetworkService._replay_out.is_empty():
			_ack_ok = true
			# 确认已到，没必要再挘满 90 秒：直接体面退出，
			# 回归脚本才能从服务端日志里读到这一行（被 kill 掉就什么都不剩）。
			_done = true
			print("[CH] server done chunked=true ack_ok=true")
			get_tree().quit(0)
			return
		if _now() >= _deadline:
			_done = true
			print("[CH] server done chunked=%s ack_ok=%s" % [_chunked, _ack_ok])
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
	if _chunked:
		# 分块模式要的是**压缩后仍然够大**的载荷。原来的填充是重复字符串，
		# 200 KB 原始数据 zstd 之后只剩 1543 字节 —— 那连一块都切不满，
		# 多块重组、乱序、缺块补发在真实网络上全都没被走到（实测踩过）。
		# 用带噪声的值，压不动，才能真的切出好几块。
		var rng := RandomNumberGenerator.new()
		rng.seed = 20260821
		while true:
			frames.append({"t": frames.size(), "a": rng.randf(), "b": rng.randi(),
				"c": "%x%x" % [rng.randi(), rng.randi()]})
			if frames.size() % 64 == 0 and NetworkService._pack_replay(blob).size() > CHUNKED_PACKED_MIN_BYTES:
				break
	else:
		while var_to_bytes(blob).size() < BULK_PAYLOAD_BYTES:
			frames.append({"t": frames.size(), "pad": "0123456789abcdef".repeat(16)})
	var packed := NetworkService._pack_replay(blob)
	print("[CH] server -> peer=%d bulk bytes=%d (raw %d) chunked=%s" % [
		peer_id, packed.size(), var_to_bytes(blob).size(), _chunked])
	if _chunked:
		# 走和生产完全同一条路径（_send_replay_to_peer），不另造探针：
		# 要验的就是那条路径本身。
		NetworkService._send_replay_to_peer(peer_id, "chprobe:1", packed, PackedByteArray())
		# 分块真的开始了吗？没建下发条目就说明走的是单包路径，
		# 那本轮测的不是分块，必须当失败报而不是默默通过。
		_chunk_started = NetworkService._replay_out.has(peer_id)
		var nchunks := int(ceil(float(packed.size()) / float(ReplayTransferService.CHUNK_PAYLOAD_BYTES)))
		print("[CH] server chunk_started=%s inflight=%d chunks=%d" % [
			_chunk_started, NetworkService._replay_out.size(), nchunks])
		if _chunk_started and nchunks < 3:
			# 只切出一两块时"重组"其实没发生。这种情况必须报失败，
			# 否则这条门禁看着绿、实际什么都没验。
			print("[CH] server done chunked=true ack_ok=false (只有 %d 块，测不到重组)" % nchunks)
			get_tree().quit(5)
		if not _chunk_started:
			print("[CH] server done chunked=true ack_ok=false (分块未发生)")
			get_tree().quit(4)
	else:
		NetworkService._rpc_team_replay.rpc_id(peer_id, packed, PackedByteArray())

func _finish() -> void:
	_done = true
	set_process(false)
	# 内容校验：光看"事件触发了"不够。分块拼错顺序或丢中间一块时，
	# team_replay_received 照样会发 —— 只是里面的回放是碎的。
	# 最后一帧的 t 必须等于帧数-1：这一条同时盯住截断和乱序。
	var content_ok := false
	var frames: Array = (NetworkService.team_replay as Dictionary).get("frames", [])
	if str((NetworkService.team_replay as Dictionary).get("kind", "")) == "channel_probe" and frames.size() > 0:
		content_ok = int((frames[frames.size() - 1] as Dictionary).get("t", -1)) == frames.size() - 1
	var ok := _got_replay and _got_room_state and NetworkService._last_pong_at > 0.0 and content_ok
	print("[CH] client %s | pong=%s bulk_replay=%s control_room_state=%s chunked=%s content_ok=%s frames=%d" % [
		"PASS" if ok else "FAIL",
		NetworkService._last_pong_at > 0.0, _got_replay, _got_room_state,
		_chunked, content_ok, frames.size()])
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
