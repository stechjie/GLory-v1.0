extends Node
const H := preload("res://tools/CheckHarness.gd")
const Peer := preload("res://tools/replay_test_peer.gd")
const T := preload("res://scripts/multiplayer/ReplayTransferService.gd")
const Q := preload("res://scripts/multiplayer/ReplaySendQueue.gd")
@export var plain_only := false
var h: RefCounted
var branches: Array[Node] = []
var clients: Array[Node] = []
var server: Node
var port := 0
var cert: X509Certificate
var key: CryptoKey
var encrypted := false

func _ready() -> void:
	call_deferred("run")

func run() -> void:
	h = H.new("replay_transport")
	Engine.max_fps = 60
	var crypto := Crypto.new()
	var generated_key := crypto.generate_rsa(2048)
	var generated_cert := crypto.generate_self_signed_certificate(generated_key, "CN=localhost,O=LocalReplayGate")
	# Reload in-memory PEM just as deployment does. Keep generated contexts out
	# of the live DTLS host; no key material ever leaves process memory.
	key = CryptoKey.new()
	key.load_from_string(generated_key.save_to_string())
	cert = X509Certificate.new()
	cert.load_from_string(generated_cert.save_to_string())
	# Keys stay only in this process. No production certificate/account is read.
	for mode in ([false] if plain_only else [false, true]):
		encrypted = mode
		await exercise()
		await cleanup()
		await exercise_local_host()
		await cleanup()
	h.finish(get_tree())

func endpoint(label: String, peer: ENetMultiplayerPeer) -> Node:
	var branch := Node.new()
	branch.name = label
	add_child(branch)
	branches.append(branch)
	var api := SceneMultiplayer.new()
	get_tree().set_multiplayer(api, branch.get_path())
	api.multiplayer_peer = peer
	api.server_relay = false
	var node := Peer.new()
	node.name = "Network"
	branch.add_child(node)
	node._replay_transfer.set_transport_encrypted(encrypted)
	return node

func add_client(index: int) -> Node:
	var transport := ENetMultiplayerPeer.new()
	transport.set_bind_ip("::1")
	var error := transport.create_client("::1", port)
	if not h.expect(error == OK, "client_socket", "Local client socket opens: %s" % error_string(error)):
		return null
	if encrypted:
		error = transport.get_host().dtls_client_setup("localhost", TLSOptions.client(cert))
		h.expect(error == OK, "client_tls", "Client pins ephemeral local certificate")
	var client := endpoint("Client%d_%d" % [index, branches.size()], transport)
	client.team_active = true
	client.team_room_id = 100001 + index / 4
	client.server_round_index = 1
	client._set_current_replay_battle("%d:1:10" % client.team_room_id)
	return client

func payload(battle_id: String, noise_bytes: int) -> PackedByteArray:
	var rng := RandomNumberGenerator.new()
	rng.seed = 936
	var noise := PackedByteArray()
	noise.resize(noise_bytes)
	for i in range(0, noise.size(), 4):
		noise.encode_u32(i, rng.randi())
	return T.new().pack({"roster": {"u": {"id": "human_militia"}},
		"frames": [[["u", 0.0, 1.0, 100, true]]],
		"result": {"player_wins": true}, "transport_stress_padding": noise}, battle_id)

func connected(client: Node) -> bool:
	return client != null and client.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED \
		and server.multiplayer.get_peers().has(client.multiplayer.get_unique_id())

func exercise() -> void:
	var transport := ENetMultiplayerPeer.new()
	transport.set_bind_ip("::1")
	var error := ERR_CANT_CREATE
	for attempt in 20:
		port = 24000 + (Time.get_ticks_usec() + attempt) % 20000
		error = transport.create_server(port, 16)
		if error == OK:
			break
	if not h.expect(error == OK, "server_socket", "Loopback server opens: %s" % error_string(error)):
		return
	if encrypted:
		error = transport.get_host().dtls_server_setup(TLSOptions.server(key, cert))
		h.expect(error == OK, "server_tls", "Server uses ephemeral local DTLS certificate")
	server = endpoint("Server", transport)
	server._dedicated_server = true
	server.multiplayer.peer_disconnected.connect(server._replay_forget_peer)
	for i in 8:
		clients.append(add_client(i))
	clients[6].legacy_receiver = true
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		if clients.all(connected):
			break
		await get_tree().process_frame
	if not h.expect(clients.all(connected), "eight_connected", "Eight peers establish %s connections" % ("DTLS" if encrypted else "plain ENet")):
		return
	for client in clients:
		if not client.legacy_receiver:
			client._rpc_replay_flow_ready.rpc_id(1)
	deadline = Time.get_ticks_msec() + 2000
	while server._replay_flow_peers.size() < 7 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	h.expect(server._replay_flow_peers.size() == 7, "receipt_negotiated", "Modern receivers negotiate bounded receipt windows while legacy stays compatible")
	var packed: Dictionary = {}
	for room in [100001, 100002]:
		var bid := "%d:1:10" % room
		packed[room] = payload(bid, 2 * 1024 * 1024 - 4096)
		h.expect((packed[room] as PackedByteArray).size() > 1900 * 1024, "large_fixture", "Each compressed own/rival replay requires larger legacy-compatible blocks")
	clients[0].suppress_acks = true
	var started := Time.get_ticks_usec()
	for client in clients:
		var data: PackedByteArray = packed[client.team_room_id]
		server._send_replay_to_peer(client.multiplayer.get_unique_id(), client.current_battle_id, data, data)
	var frames := 0
	var max_peer_bytes := 0
	var max_global_bytes := 0
	var reconnected := false
	var replacement: Node
	var replacement_sent := false
	var retry_seen := false
	var wave_two := false
	var wave_two_start := 0
	var first_round_ms: Array[int] = []
	var slow_id := clients[0].multiplayer.get_unique_id()
	deadline = Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < deadline:
		frames += 1
		var before: int = server.sent_chunks.size()
		server._tick_replay_send()
		server._tick_replay_retry(1.0 / 30.0)
		var per_peer := {}
		var global_bytes := 0
		for i in range(before, server.sent_chunks.size()):
			var item: Dictionary = server.sent_chunks[i]
			per_peer[item.peer_id] = int(per_peer.get(item.peer_id, 0)) + int(item.bytes)
			global_bytes += int(item.bytes)
		for bytes in per_peer.values():
			max_peer_bytes = maxi(max_peer_bytes, bytes)
		max_global_bytes = maxi(max_global_bytes, global_bytes)
		if frames % 3 == 0:
			for client in clients:
				if connected(client):
					client.test_ping.rpc_id(1, Time.get_ticks_usec())
		# Drop one connection during its large replay; other room keeps receiving.
		if not reconnected and Time.get_ticks_usec() - started > 2200000:
			reconnected = true
			var old := clients[7]
			var old_id := old.multiplayer.get_unique_id()
			old.multiplayer.multiplayer_peer.close()
			server._replay_forget_peer(old_id)
			replacement = add_client(7)
			clients[7] = replacement
		if reconnected and not replacement_sent and connected(replacement):
			replacement_sent = true
			var data: PackedByteArray = packed[replacement.team_room_id]
			server._send_replay_to_peer(replacement.multiplayer.get_unique_id(), replacement.current_battle_id, data, data)
		# Wait the real six-second ACK timeout. Suppression applies only to peer 0.
		var slow: Dictionary = server._replay_out.get(slow_id, {})
		if not retry_seen and int(slow.get("tries", 0)) > 0:
			retry_seen = true
			h.expect(clients[0].received_count == 1, "lost_ack_only_once", "Lost ACK does not replay successful battle")
			clients[0].suppress_acks = false
			wave_two = true
			wave_two_start = Time.get_ticks_usec()
			for client in clients:
				first_round_ms.append((client.completed_usec - started) / 1000)
			for index in range(1, 8):
				var client := clients[index]
				var next_id := "%d:2:20" % client.team_room_id
				client._set_current_replay_battle(next_id)
				var next_payload := payload(next_id, 256 * 1024)
				server._send_replay_to_peer(client.multiplayer.get_unique_id(), next_id, next_payload, next_payload)
		if wave_two and server._replay_out.is_empty() and clients.slice(1).all(func(c): return c.received_count == 2):
			break
		await get_tree().create_timer(1.0 / 30.0).timeout
	var finished := Time.get_ticks_usec()
	h.expect(retry_seen, "real_ack_retry", "One suppressed ACK enters production timeout/retry path")
	h.expect(replacement_sent and clients[7].received_count == 2, "reconnect_delivery", "Reconnected peer receives its full replay and next battle")
	h.expect(server._replay_out.is_empty(), "all_acked", "Every live transfer eventually ACKs")
	h.expect(max_peer_bytes <= 32 * 1024, "actual_peer_budget", "2 MiB replay uses at most 32 KiB credited bursts")
	h.expect(max_global_bytes <= Q.GLOBAL_BYTES_PER_FRAME and max_global_bytes >= 2 * 16 * 1024, "actual_fairness", "Multiple peers progress per poll under the configured global cap; all peers must finish below")
	var all_pongs: Array[int] = []
	var completion_ms: Array[int] = []
	for index in 8:
		var client := clients[index]
		h.expect(client.received_count == (1 if index == 0 else 2), "delivery_once", "Peer %d receives each expected battle exactly once" % index)
		h.expect(client.failed_count == 0, "decode_ok", "Peer %d accepts real RPC codec data without failures" % index)
		h.expect(client.legacy_errors.is_empty(), "legacy_accepts", "Frozen old receiver accepts new production RPC blocks")
		h.expect(client.pongs.size() >= 20, "heartbeats_live", "Peer %d heartbeats continue while bulk/reconnect/retry run" % index)
		all_pongs.append_array(client.pongs)
		if index > 0:
			completion_ms.append((client.completed_usec - wave_two_start) / 1000)
	all_pongs.sort()
	completion_ms.sort()
	var p95 := all_pongs[int(all_pongs.size() * 0.95)] if not all_pongs.is_empty() else 99999999
	var max_rtt: int = all_pongs.back() if not all_pongs.is_empty() else 99999999
	h.expect(p95 < 250000 and max_rtt < 1000000, "heartbeat_budget", "Heartbeat p95 <250 ms and max <1 s under bulk load")
	h.expect(not completion_ms.is_empty() and completion_ms.back() < 3500, "retry_isolation", "Other 7 peers complete next round in <3.5 s while one retries")
	print("REPLAY_TRANSPORT_METRICS %s" % JSON.stringify({"dtls": encrypted, "peers": 8, "rooms_2v2": 2,
		"compressed_bytes_per_kind": (packed[100001] as PackedByteArray).size(), "duration_ms": (finished-started)/1000,
		"frames": frames, "max_peer_bytes": max_peer_bytes, "max_global_bytes": max_global_bytes,
		"heartbeat_samples": all_pongs.size(), "heartbeat_p95_usec": p95, "heartbeat_max_usec": max_rtt,
		"first_round_complete_ms": first_round_ms, "second_round_complete_ms": completion_ms, "ack_retry_seen": retry_seen, "reconnected": replacement_sent}))

func exercise_local_host() -> void:
	var transport := ENetMultiplayerPeer.new()
	transport.set_bind_ip("::1")
	var error := ERR_CANT_CREATE
	for attempt in 20:
		port = 24000 + (Time.get_ticks_usec() + attempt) % 20000
		error = transport.create_server(port, 4)
		if error == OK:
			break
	if not h.expect(error == OK, "local_host_socket", "Local room host listens"):
		return
	if encrypted:
		h.expect(transport.get_host().dtls_server_setup(TLSOptions.server(key, cert)) == OK,
			"local_host_tls", "Local room DTLS enabled")
	server = endpoint("Server", transport)
	server.is_host = true
	server.production_process = true
	server.set_process(true)
	for i in 2:
		var client := add_client(i)
		clients.append(client)
		client.team_room_id = 0
		client._set_current_replay_battle("")
	clients[1].legacy_receiver = true
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline and not clients.all(connected):
		await get_tree().process_frame
	if not h.expect(clients.all(connected), "local_host_connected", "Local room connects new and frozen old receivers"):
		return
	for i in clients.size():
		server._team_peer_slot[clients[i].multiplayer.get_unique_id()] = i + 1
	var bid := "host:%d" % GameState.round_index
	var packed := payload(bid, Q.MAX_PAYLOAD_BYTES - 2048)
	var replay: Dictionary = T.new().unpack(packed)
	h.expect(packed.size() > 85 * 32768 and packed.size() <= Q.MAX_PAYLOAD_BYTES,
		"legacy_max_fixture", "Near-4 MiB fixture exercises mandatory 48 KiB old-receiver blocks")
	clients[0].suppress_acks = true
	var started := Time.get_ticks_usec()
	server.team_broadcast_replays(replay, replay)
	var seen_retry := false
	deadline = Time.get_ticks_msec() + 40000
	var ticks := 0
	# Deliberately no manual _tick_replay_send/_tick_replay_retry: this reproduces
	# the actual local-host entry point and requires the production _process pump.
	while Time.get_ticks_msec() < deadline:
		ticks += 1
		if ticks % 6 == 0:
			for client in clients:
				client.test_ping.rpc_id(1, Time.get_ticks_usec())
		var pending: Dictionary = server._replay_out.get(clients[0].multiplayer.get_unique_id(), {})
		if int(pending.get("tries", 0)) > 0:
			seen_retry = true
			clients[0].suppress_acks = false
		if server._replay_out.is_empty():
			break
		await get_tree().process_frame
	var elapsed := (Time.get_ticks_usec() - started) / 1000
	h.expect(clients.all(func(c): return c.received_count == 1 and c.legacy_errors.is_empty()),
		"local_host_delivery", "Natural local-host processing delivers once to new and old receivers")
	h.expect(seen_retry and server._replay_out.is_empty(), "local_host_retry", "Local-host ACK retry also progresses automatically")
	var max_chunk := 0
	for item in server.sent_chunks:
		max_chunk = maxi(max_chunk, int(item.bytes))
	h.expect(max_chunk == Q.MAX_CHUNK_BYTES, "legacy_48k_exercised", "Real RPC path exercised full 48 KiB credited burst")
	var rtts: Array[int] = []
	for client in clients:
		rtts.append_array(client.pongs)
	rtts.sort()
	var p95 := rtts[int(rtts.size() * 0.95)] if not rtts.is_empty() else 99999999
	h.expect(p95 < 250000, "local_host_heartbeat", "Heartbeat p95 remains below 250 ms at legacy maximum payload")
	print("REPLAY_LOCAL_HOST_METRICS %s" % JSON.stringify({"dtls": encrypted,
		"packed_bytes_per_kind": packed.size(), "elapsed_ms": elapsed, "max_chunk_bytes": max_chunk,
		"production_process_ticks": ticks, "retry": seen_retry, "heartbeat_p95_usec": p95,
		"new_received": clients[0].received_count, "old_received": clients[1].received_count,
		"old_receiver_errors": clients[1].legacy_errors.size()}))

func cleanup() -> void:
	# Close clients first and let the DTLS server service their close packets
	# before destroying its certificate/key context.
	for branch in branches:
		if branch.name == "Server":
			continue
		var api := branch.multiplayer
		if api.multiplayer_peer != null and api.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
			api.multiplayer_peer.close()
	for i in 3:
		await get_tree().process_frame
	for branch in branches:
		var api := branch.multiplayer
		if api.multiplayer_peer != null:
			if api.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
				api.multiplayer_peer.close()
			api.multiplayer_peer = null
		get_tree().set_multiplayer(null, branch.get_path())
		branch.queue_free()
	branches.clear()
	clients.clear()
	server = null
	await get_tree().process_frame
