extends "res://tools/replay_transport_check.gd"

# Isolated capacity experiment: real pinned DTLS peers, production replay queue,
# codec, ACK and scheduler. Accounts, matchmaking and the public network are not
# included. Both client and server consume the same test machine's CPU/memory.
const Fixture := preload("res://tools/server_battle_scheduler_check.gd")
const Sim := preload("res://scripts/battle/BattleSimulator.gd")
var measurements: Array = []

func _ready() -> void:
	call_deferred("capacity_run")

func arg(name: String, fallback: String) -> String:
	for value in OS.get_cmdline_user_args():
		if value.begins_with(name + "="):
			return value.substr(name.length() + 1)
	return fallback

func capacity_run() -> void:
	h = H.new("server_capacity")
	NetworkService.set_process(false)
	NetworkService.enter_test_server_mode()
	DataRegistry.load_all()
	Engine.max_fps = 60
	var peer_count := clampi(int(arg("--peers", "16")), 4, 512)
	var room_count := clampi(int(arg("--rooms", "4")), 0, peer_count / 4)
	var mode := arg("--mode", "cooperative")
	encrypted = arg("--dtls", "true") == "true"
	var crypto := Crypto.new()
	var generated_key := crypto.generate_rsa(2048)
	var generated_cert := crypto.generate_self_signed_certificate(generated_key, "CN=localhost,O=CapacityQA")
	key = CryptoKey.new()
	key.load_from_string(generated_key.save_to_string())
	cert = X509Certificate.new()
	cert.load_from_string(generated_cert.save_to_string())
	var transport := ENetMultiplayerPeer.new()
	transport.set_bind_ip("::1")
	if transport.create_server(0, 512) != OK:
		h.expect(false, "listen", "Cannot bind isolated capacity server")
		h.finish(get_tree())
		return
	port = transport.host.get_local_port()
	if encrypted:
		h.expect(transport.host.dtls_server_setup(TLSOptions.server(key, cert)) == OK, "tls_setup", "Ephemeral pinned DTLS server")
	server = endpoint("Server", transport)
	server._dedicated_server = true
	server.multiplayer.peer_disconnected.connect(server._replay_forget_peer)
	var handshake_started := Time.get_ticks_usec()
	for index in peer_count:
		var client := add_client(index)
		clients.append(client)
		# Decode/schema/identity/ACK complete before this signal. Discard the
		# decoded client view immediately: mobile clients live on other machines,
		# so retaining hundreds of client-side dictionaries would measure a fake
		# server memory bottleneck. Peak decoding cost is still included.
		client.team_replay_received.connect(func():
			client.team_replay = {}
			client.team_replay_rival = {})
		if index % 8 == 7:
			await get_tree().process_frame
	var deadline := Time.get_ticks_msec() + 60000
	while not clients.all(connected) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var established := clients.filter(connected).size()
	print("CAPACITY_HANDSHAKE " + JSON.stringify({"requested": peer_count, "connected": established, "dtls": encrypted, "wall_ms": (Time.get_ticks_usec() - handshake_started) / 1000.0}))
	if established != peer_count:
		h.expect(false, "connect", "Not all capacity peers connected")
		h.finish(get_tree())
		return
	await capacity_phase("idle", [], mode, 10000)
	if room_count > 0:
		var fixture := Fixture.new()
		var rooms: Array = []
		for index in room_count:
			var room: Dictionary = fixture._fixture(100001 + index, 21, true)
			# Each seat receives a real worst-case round-21 replay, not padding.
			for client in clients:
				if client.team_room_id == room.id:
					client.server_round_index = 21
					client._set_current_replay_battle(room.battle_id)
			rooms.append(room)
		await capacity_phase("battle", rooms, mode, 0)
		fixture.free()
	h.expect(measurements.size() == (2 if room_count > 0 else 1), "complete_phases", "Every requested phase must complete")
	print("CAPACITY_COMPLETE " + JSON.stringify({"peers": peer_count, "rooms_2v2": room_count, "mode": mode, "dtls": encrypted, "measurements": measurements}))
	# Normal close intentionally remains visible: Godot 4.7 currently reports a
	# reproduced DTLS shutdown error. The runner separates runtime from teardown.
	await cleanup()
	h.finish(get_tree())

func capacity_phase(label: String, rooms: Array, mode: String, idle_ms: int) -> void:
	for client in clients:
		client.pongs.clear()
	var sent := 0
	var next_ping := 0
	var delivered := {}
	var published := {}
	var ready_ms: Array = []
	var delivery_ms: Array = []
	var frames: Array = []
	var gaps: Array = []
	var peak_memory := 0
	var total_bytes := 0
	var started := Time.get_ticks_usec()
	var previous := started
	var deadline := Time.get_ticks_msec() + 180000
	for room in rooms:
		NetworkService._rooms[room.id] = room
		if mode == "cooperative":
			NetworkService._enqueue_finalize(room)
	var sync_index := 0
	while Time.get_ticks_msec() < deadline:
		var begin := Time.get_ticks_usec()
		gaps.append(begin - previous)
		previous = begin
		if begin >= next_ping:
			for client in clients:
				if connected(client):
					client.test_ping.rpc_id(1, begin)
					sent += 1
			next_ping = begin + 250000
		if mode == "cooperative":
			NetworkService._drain_finalize_queue()
		elif sync_index < rooms.size():
			var room: Dictionary = rooms[sync_index]
			# Same simulation/data as the candidate, but the old indivisible two-
			# side compute and packing path. This isolates scheduling's effect.
			var context := preload("res://scripts/multiplayer/BattleReplayJob.gd").new(room)
			var prior: Dictionary = context.enter_context()
			var a := Sim.compute_team_replay(0, room.battle_id)
			var b := Sim.compute_team_replay(1, room.battle_id)
			Sim.stamp_team_round_damages(a, b)
			context.exit_context(prior)
			room.replay_packed = {"a": T.new().pack(a, room.battle_id), "b": T.new().pack(b, room.battle_id)}
			sync_index += 1
		for room in rooms:
			if published.has(room.id) or not (room.get("replay_packed", {}) as Dictionary).has("a"):
				continue
			published[room.id] = true
			ready_ms.append((Time.get_ticks_usec() - started) / 1000.0)
			var packed: Dictionary = room.replay_packed
			for index in clients.size():
				var client: Node = clients[index]
				if client.team_room_id == room.id:
					var own: PackedByteArray = packed.a if index % 4 < 2 else packed.b
					var rival: PackedByteArray = packed.b if index % 4 < 2 else packed.a
					total_bytes += own.size() + rival.size()
					server._send_replay_to_peer(client.multiplayer.get_unique_id(), room.battle_id, own, rival)
		server._tick_replay_send()
		server._tick_replay_retry(1.0 / 60.0)
		# Instrumentation must not retain every sent chunk throughout a soak.
		server.sent_chunks.clear()
		for index in clients.size():
			if not delivered.has(index) and clients[index].received_count > 0:
				delivered[index] = true
				delivery_ms.append((Time.get_ticks_usec() - started) / 1000.0)
		peak_memory = maxi(peak_memory, Performance.get_monitor(Performance.MEMORY_STATIC))
		frames.append(Time.get_ticks_usec() - begin)
		if idle_ms > 0 and begin - started >= idle_ms * 1000:
			break
		if idle_ms == 0 and delivered.size() == rooms.size() * 4 and server._replay_out.is_empty():
			break
		await get_tree().process_frame
	for index in 60:
		await get_tree().process_frame
	var pongs: Array = []
	var failures := 0
	for client in clients:
		pongs.append_array(client.pongs)
		failures += client.failed_count
	var stats := {"phase": label, "wall_ms": (Time.get_ticks_usec() - started) / 1000.0,
		"connected": clients.filter(connected).size(), "heartbeat_sent": sent, "heartbeat_replies": pongs.size(),
		"heartbeat_p95_ms": percentile(pongs, 0.95) / 1000.0, "heartbeat_max_ms": percentile(pongs, 1.0) / 1000.0,
		"frame_max_ms": percentile(frames, 1.0) / 1000.0, "gap_max_ms": percentile(gaps, 1.0) / 1000.0,
		"ready_p95_ms": percentile(ready_ms, 0.95), "delivery_p95_ms": percentile(delivery_ms, 0.95),
		"delivered": delivered.size(), "expected_deliveries": rooms.size() * 4, "failed_replays": failures,
		"replay_bytes": total_bytes, "combined_static_memory_peak_bytes": peak_memory}
	measurements.append(stats)
	print("CAPACITY_PHASE " + JSON.stringify(stats))
	h.expect(stats.connected == clients.size(), label + "_connected", "Every peer remains connected")
	h.expect(failures == 0 and delivered.size() == rooms.size() * 4, label + "_delivery", "All battle clients receive validated own/rival replays")
	NetworkService._rooms.clear()

func percentile(values: Array, fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var ordered := values.duplicate()
	ordered.sort()
	return float(ordered[mini(ordered.size() - 1, int(ceil(ordered.size() * fraction)) - 1)])
