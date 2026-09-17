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
#   godot --headless --path <proj> tools/channel_check.tscn -- --ch-role=server --battle-card-key=user://test_battle_card_public.pem
#   godot --headless --path <proj> tools/channel_check.tscn -- --ch-role=client
#
# 出战名片（BattleCard.gd）：专服没有公钥不肯启动，建房请求也必须带一张验得过的名片。
# 这里没有账号服务器，所以 server 现场生成一把一次性钥匙（公钥给自己、私钥留给 client），
# client 用那把私钥自己签名片。于是「建房带名片、过 ENet、验章、入座」这一路也顺带真跑了一遍 ——
# room_state 收不到（第 3 条）就说明这一路断了。
#
# --ch-chunked=1：把回放走**分块**路径（D1：原始 README 的分块/确认/重试）。
# 这个模式存在的理由和本文件开头一样：分块包发错通道、拼错顺序、或者重组
# 无声失败，后果都不是抛错而是**回放不来**。同进程单测测不到这一层。
# 又因为实测最坏一场压缩后只有 61.8 KB、低于 192 KiB 阈值，生产里永远走不到
# 分块路径 —— 不强制跑一遍的话，那条代码路等于没人验。

const ReplayTransferService := preload("res://scripts/multiplayer/ReplayTransferService.gd")
const BattleCardTestKeys := preload("res://tools/battle_card_test_keys.gd")

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
		var key_error := BattleCardTestKeys.install_for_server(true)
		if not key_error.is_empty():
			print("[CH] FATAL: %s" % key_error)
			get_tree().quit(2)
			return
		if not NetworkService.start_dedicated_server(PORT):
			print("[CH] FATAL: cannot start server on %d: %s" % [PORT, NetworkService.last_error])
			BattleCardTestKeys.remove_files()
			get_tree().quit(2)
			return
		multiplayer.peer_connected.connect(_on_peer_connected)
		if _chunked:
			NetworkService.set_force_replay_chunking(true)
		_deadline = _now() + SERVER_LIFETIME_SEC
		print("[CH] server ready port=%d chunked=%s" % [PORT, _chunked])
		_dump_channel_info()
	else:
		# 必须在 team_join 之前：连上、建房之后 NetworkService 就会写重连凭证（见 _snapshot_reconnect）。
		_snapshot_reconnect()
		NetworkService.team_replay_received.connect(func(): _got_replay = true)
		# 服务端进程启动时写下的一次性私钥。读进内存就删掉，不在用户目录里留着。
		var card_key := BattleCardTestKeys.load_private()
		BattleCardTestKeys.remove_files()
		if card_key == null:
			print("[CH] FATAL: 读不到 %s（server 要先起来）" % BattleCardTestKeys.TEST_PRIVATE_PATH)
			_restore_reconnect()
			get_tree().quit(2)
			return
		NetworkService.seat_card_provider = func() -> String:
			return BattleCardTestKeys.sign(card_key, BattleCardTestKeys.card("channel-check"))
		if not NetworkService.team_join("127.0.0.1", PORT):
			print("[CH] FATAL: cannot create client")
			_restore_reconnect()
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
		# 块大小要问**服务实例**，不能读常量：加密链路下它是 16 KiB 而不是 48 KiB
		# （C14，见 ReplayTransferService）。读常量的话这里算出来的块数是错的，
		# 下面那条 `nchunks < 3` 的守卫就会按错的数字放行或误杀。
		var nchunks := int(ceil(float(packed.size())
			/ float(NetworkService._replay_transfer.chunk_payload_bytes())))
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
	_restore_reconnect()
	get_tree().quit(0 if ok else 3)

# 客户端走的是真的 team_join + 建房：NetworkService 会把这一局的重连凭证写进 user://
# （和开发机上的真实游戏**共用同一个存档目录**）并标成已开局。不还原的话，跑完一次回归，
# 本机的游戏就会一直去 127.0.0.1:8092 确认「上一局」，而那台测试服务器早就退出了 ——
# 结果是「自定义房间」被 NetworkService.allow_new_match() 永久挡住。2026-09-11 实测踩过。
# 做法同 tools/active_match_transport_check.gd：跑之前把文件原样存下来，结束时原样写回。
var _saved_reconnect := {}   # path -> PackedByteArray，只存跑之前就存在的那几个文件

func _snapshot_reconnect() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		var path: String = SaveManager.RECONNECT_PATH + suffix
		if FileAccess.file_exists(path):
			_saved_reconnect[path] = FileAccess.get_file_as_bytes(path)

func _restore_reconnect() -> void:
	# 先连 .bak/.tmp 一起清掉本轮写进去的，再把跑之前的原样写回（原来没有就保持没有）。
	SaveManager.clear_reconnect()
	for path in _saved_reconnect:
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			print("[CH] WARN: 还原重连凭证失败 %s" % path)
			continue
		f.store_buffer(_saved_reconnect[path])
		f.close()

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
