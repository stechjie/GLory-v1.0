extends Node

# C14 传输加密的门禁。
#
# 这个检查存在的理由，和 account_check 钉"access token 永不落盘"是同一类：
# **DTLS 配错了没有任何运行时症状。** 连接照常建立、游戏照常跑、日志里什么都没有，
# 只是线路是明文的。人工测试永远发现不了，只能靠断言挡在上线之前。
#
# 六个用例，前三个走真实 ENet 回环（L2 级），后三个是纯逻辑：
#
#   1 dtls_round_trip        两端都配 DTLS -> 必须连上
#   2 plaintext_rejected     客户端不配    -> 必须连不上   ← 证明 DTLS 不是空操作
#   3 wrong_cert_rejected    客户端拿别的证书 -> 必须连不上 ← 证明真的在验服务端身份
#   4 cert_material          证书能解析、服务器私钥在
#   5 encrypted_chunking     加密模式下 62 KB 回放必须分块，且每块 16 KiB
#   6 split_shape            切出来的块数与大小对得上，且不会被接收端的上限拒掉
#
# 用例 2 和 3 是这份门禁的**全部价值**。只有用例 1 的话，把 dtls_server_setup
# 删掉它照样全绿 —— 明文两端一样连得上。
#
# ⚠️ 用例 2/3 会在 stderr 打 `TLS handshake error` 与 mbedtls 负数错误码。
#    **那是预期输出，不是失败**：正是握手被拒的证据。看 CHECK_RESULT 那一行。
#
# 跑：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/dtls_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const NetTLS := preload("res://scripts/multiplayer/NetTLS.gd")
const ReplayTransferService := preload("res://scripts/multiplayer/ReplayTransferService.gd")

const CHECK_NAME := "dtls"
# 每个用例换一个端口：连着复用同一个会撞上前一个 host 的回收窗口，
# 症状是第二个用例莫名连不上 —— 那会被读成"加密坏了"。
const BASE_PORT := 8097
const CONNECT_DEADLINE_SEC := 5.0
# 实测最坏一场压缩后 61.8 KB（审计文档 B2）。用例 5/6 就按这个量级来。
const TYPICAL_REPLAY_BYTES := 63488

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_h.note("用例 2/3 会在 stderr 打 TLS handshake error —— 那是握手被拒的证据，不是失败")

	_case_cert_material()
	_case_encrypted_chunking()
	_case_split_shape()
	await _case_round_trip()
	await _case_plaintext_rejected()
	await _case_wrong_cert_rejected()

	_h.finish(get_tree())


# --- 纯逻辑用例 ---------------------------------------------------------------

func _case_cert_material() -> void:
	var cert := NetTLS.pinned_cert()
	_h.expect(cert != null, "pinned_cert_missing",
		"scripts/multiplayer/NetTLSCert.gd 里的证书解析不出来 —— 跑 tools/dtls_make_cert.tscn 重新生成")
	var key_path := NetTLS.server_key_path()
	_h.expect(FileAccess.file_exists(key_path), "server_key_missing",
		"服务器私钥不在 %s。**这台机器上跑不了服务端用例**；跑 tools/dtls_make_cert.tscn 生成" % key_path)


func _case_encrypted_chunking() -> void:
	var blob := PackedByteArray()
	blob.resize(TYPICAL_REPLAY_BYTES)
	var svc: RefCounted = ReplayTransferService.new()

	svc.set_transport_encrypted(false)
	_h.expect(not svc.should_chunk(blob), "plain_should_not_chunk",
		"明文链路下 62 KB 不该分块（阈值 192 KiB）—— 改动必须逐字节保持旧行为")
	_h.expect(svc.chunk_payload_bytes() == ReplayTransferService.CHUNK_PAYLOAD_BYTES,
		"plain_chunk_size_changed", "明文链路的块大小不该变")

	svc.set_transport_encrypted(true)
	_h.expect(svc.should_chunk(blob), "encrypted_must_chunk",
		"加密链路下 62 KB **必须**分块：单包会挤爆接收端 UDP 缓冲，实测 20ms -> 2686ms")
	_h.expect(svc.chunk_payload_bytes() == 16 * 1024, "encrypted_chunk_size",
		"加密链路每块应为 16 KiB（实测 48 KiB/帧 会塌、32 KiB 可以，取一倍余量）")


func _case_split_shape() -> void:
	var blob := PackedByteArray()
	blob.resize(TYPICAL_REPLAY_BYTES)
	var svc: RefCounted = ReplayTransferService.new()
	svc.set_transport_encrypted(true)
	var chunks: Array = svc.split(blob, "battle-1", ReplayTransferService.CHUNK_KIND_OWN)
	_h.expect(chunks.size() == 4, "split_count",
		"62 KB / 16 KiB 应切成 4 块，实际 %d 块" % chunks.size())
	var oversize := 0
	for env in chunks:
		var data: PackedByteArray = (env as Dictionary).get("data", PackedByteArray())
		# 接收端 accept_chunk 用 CHUNK_PAYLOAD_BYTES 当上限。发送端把块调小是安全的，
		# 调大就会被自己人拒收 —— 这一条锁住那个方向。
		if data.size() > ReplayTransferService.CHUNK_PAYLOAD_BYTES:
			oversize += 1
	_h.expect(oversize == 0, "split_oversize",
		"有 %d 块超过接收端 accept_chunk 的上限，会被自己人拒收" % oversize)


# --- 真实 ENet 回环用例 -------------------------------------------------------

func _case_round_trip() -> void:
	var r := await _try_connect(BASE_PORT, true, NetTLS.pinned_cert())
	_h.expect(r["connected"], "dtls_round_trip_failed",
		"两端都配了 DTLS 却连不上：%s" % str(r["detail"]))


func _case_plaintext_rejected() -> void:
	var r := await _try_connect(BASE_PORT + 1, false, null)
	_h.expect(not r["connected"], "plaintext_accepted",
		"明文客户端连上了 DTLS 服务器 —— 说明 dtls_server_setup 是空操作，线路根本没加密")


func _case_wrong_cert_rejected() -> void:
	var crypto := Crypto.new()
	var other_key := crypto.generate_rsa(2048)
	var other_cert := crypto.generate_self_signed_certificate(other_key, "CN=glory-battle,O=NotUs")
	var r := await _try_connect(BASE_PORT + 2, true, other_cert)
	_h.expect(not r["connected"], "wrong_cert_accepted",
		"拿别人的证书也连上了 —— 说明没有校验服务端身份，中间人照样成立")


# 起一个 DTLS 服务器，再用指定配置连一次。返回 {connected: bool, detail: String}。
#
# 两端都用**独立的 SceneMultiplayer**：主 MultiplayerAPI 是 NetworkService 的，
# 上面挂着协议握手的 auth_callback（那条链路归 tools/handshake_check 管）。
# 这份门禁只验传输层，混在一起会让失败原因分不清是哪一层。
func _try_connect(port: int, client_dtls: bool, client_cert: X509Certificate) -> Dictionary:
	var server_mp := SceneMultiplayer.new()
	var server_peer := ENetMultiplayerPeer.new()
	if server_peer.create_server(port, 4) != OK:
		_h.fail("server_listen_failed", "端口 %d 起不来（被占用？）" % port)
		return {"connected": false, "detail": "listen failed"}
	var tls_err := NetTLS.apply_server(server_peer)
	if not tls_err.is_empty():
		_h.fail("server_dtls_setup_failed", "服务端 DTLS 配置失败：%s" % tls_err)
		return {"connected": false, "detail": tls_err}
	server_mp.multiplayer_peer = server_peer

	var client_mp := SceneMultiplayer.new()
	var client_peer := ENetMultiplayerPeer.new()
	if client_peer.create_client("127.0.0.1", port) != OK:
		_h.fail("client_create_failed", "客户端建不出来（端口 %d）" % port)
		return {"connected": false, "detail": "create_client failed"}
	if client_dtls:
		# 刻意不走 NetTLS.apply_client：用例 3 要塞一张**别的**证书进去，
		# 而 apply_client 只认 pin 住的那张。这里复刻它的调用形状。
		var host := client_peer.get_host()
		if host == null or host.dtls_client_setup(NetTLS.PIN_HOSTNAME,
				TLSOptions.client_unsafe(client_cert)) != OK:
			_h.fail("client_dtls_setup_failed", "客户端 DTLS 配置失败（端口 %d）" % port)
			return {"connected": false, "detail": "dtls_client_setup failed"}
	client_mp.multiplayer_peer = client_peer

	# 判据刻意**不用 client_mp.connected_to_server**。
	#
	# 实测：这两个 SceneMultiplayer 是独立对象、没挂进场景树，那条信号不会发 ——
	# 而 ENet 层其实已经连上了（status=CONNECTED、拿到了 id、服务端也看见了它）。
	# 照着信号写判据，得到的是「加密明明是好的，门禁却报红」。
	#
	# 换成两侧交叉验证，比信号更强：
	#   服务端看见一个 peer 接进来 + 客户端拿到非零 id + 两边说的是同一个 id
	# 少任何一条都不算连上。中间人拿不到证书时，这三条一条都不会成立。
	var srv_saw: Array = []
	server_mp.peer_connected.connect(func(id: int): srv_saw.append(id))
	var failed := false
	client_mp.connection_failed.connect(func(): failed = true)

	var deadline := Time.get_ticks_msec() + int(CONNECT_DEADLINE_SEC * 1000.0)
	var connected := false
	while Time.get_ticks_msec() < deadline and not connected and not failed:
		server_mp.poll()
		client_mp.poll()
		var cid := client_mp.get_unique_id()
		connected = (client_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED
			and cid != 0 and srv_saw.has(cid))
		await get_tree().process_frame

	# 这一行在门禁变红时是唯一有用的东西：能立刻分出「握手被拒」（srv_saw 空、
	# status=0/1）和「连上了但判据写错」（srv_saw 非空、status=2）。
	var detail := "connected=%s failed=%s cli_status=%d cli_id=%d srv_saw=%s" % [
		connected, failed, client_peer.get_connection_status(),
		client_mp.get_unique_id(), str(srv_saw)]
	print("[dtls] port=%d %s" % [port, detail])
	client_peer.close()
	server_peer.close()
	client_mp.multiplayer_peer = null
	server_mp.multiplayer_peer = null
	return {"connected": connected, "detail": detail}
