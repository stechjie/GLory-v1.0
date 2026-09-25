extends "res://tools/server_capacity_check.gd"

const CapacityPeer := preload("res://tools/server_capacity_peer.gd")

func _ready() -> void:
	call_deferred("split_run")

func endpoint(label: String, peer: ENetMultiplayerPeer) -> Node:
	var branch := Node.new()
	branch.name = label
	add_child(branch)
	branches.append(branch)
	var api := SceneMultiplayer.new()
	get_tree().set_multiplayer(api, branch.get_path())
	api.multiplayer_peer = peer
	api.server_relay = false
	var node := CapacityPeer.new()
	node.name = "Network"
	branch.add_child(node)
	node._replay_transfer.set_transport_encrypted(true)
	return node

func split_run() -> void:
	h = H.new("server_capacity_split")
	NetworkService.set_process(false)
	NetworkService.enter_test_server_mode()
	DataRegistry.load_all()
	Engine.max_fps = 60
	encrypted = true
	var count := clampi(int(arg("--peers", "16")), 4, 512)
	var rooms := clampi(int(arg("--rooms", "4")), 0, count / 4)
	var mode := arg("--mode", "cooperative")
	var rendezvous := arg("--rendezvous", "")
	assert(not rendezvous.is_empty())
	if arg("--role", "server") == "clients":
		await split_clients(count, rendezvous)
		return
	var crypto := Crypto.new()
	key = crypto.generate_rsa(2048)
	cert = crypto.generate_self_signed_certificate(key, "CN=localhost,O=SplitCapacityQA")
	var transport := ENetMultiplayerPeer.new()
	transport.set_bind_ip("::1")
	assert(transport.create_server(0, 512) == OK)
	assert(transport.host.dtls_server_setup(TLSOptions.server(key, cert)) == OK)
	port = transport.host.get_local_port()
	server = endpoint("Server", transport)
	server._dedicated_server = true
	server.multiplayer.peer_disconnected.connect(server._replay_forget_peer)
	var file := FileAccess.open(rendezvous, FileAccess.WRITE)
	file.store_string(JSON.stringify({"port": port, "public_cert": cert.save_to_string()}))
	file.close()
	var deadline := Time.get_ticks_msec() + 90000
	while server.registrations.size() < count and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	print("CAPACITY_HANDSHAKE " + JSON.stringify({"requested": count, "registered": server.registrations.size(), "connected": server.multiplayer.get_peers().size()}))
	if not h.expect(server.registrations.size() == count, "registered", "All separate-process clients registered"):
		h.finish(get_tree())
		return
	await split_phase("idle", [], mode, count, clampi(int(arg("--idle-ms", "10000")), 10000, 120000))
	if rooms > 0:
		var fixture := Fixture.new()
		var fixtures: Array = []
		for index in rooms:
			fixtures.append(fixture._fixture(100001 + index, 21, true))
		fixture.free()
		await split_phase("battle", fixtures, mode, count, 0)
	h.expect(measurements.size() == (2 if rooms > 0 else 1), "phases_complete", "Every requested phase completed")
	print("CAPACITY_COMPLETE " + JSON.stringify({"peers": count, "rooms_2v2": rooms, "mode": mode, "split_processes": true, "measurements": measurements}))
	server.capacity_done.rpc()
	for index in 30:
		await get_tree().process_frame
	await cleanup()
	h.finish(get_tree())

func split_clients(count: int, rendezvous: String) -> void:
	var settings: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(rendezvous))
	port = settings.port
	cert = X509Certificate.new()
	cert.load_from_string(settings.public_cert)
	for index in count:
		var client := add_client(index)
		client.server_round_index = 21
		client._set_current_replay_battle("%d:21:1" % client.team_room_id)
		client.team_replay_received.connect(func():
			client.team_replay = {}
			client.team_replay_rival = {})
		clients.append(client)
		if index % 8 == 7:
			# Capacity measures established sessions. Bound connection ramp rather
			# than flooding the engine's pending DTLS handshake queue in one burst.
			var connect_deadline := Time.get_ticks_msec() + 15000
			while not clients.all(func(c): return c.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED) and Time.get_ticks_msec() < connect_deadline:
				await get_tree().process_frame
	var registered := {}
	var next_ping := 0
	var deadline := Time.get_ticks_msec() + 250000
	while Time.get_ticks_msec() < deadline:
		var now := Time.get_ticks_usec()
		for index in clients.size():
			var client: Node = clients[index]
			if client.multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
				continue
			if not registered.has(index):
				client.capacity_register.rpc_id(1, index)
				registered[index] = true
			if now >= next_ping:
				client.test_ping.rpc_id(1, now)
		if now >= next_ping:
			next_ping = now + 250000
		if clients.all(func(c): return c.phase_name == "done"):
			break
		await get_tree().process_frame
	h.expect(clients.all(func(c): return c.phase_name == "done"), "server_finished", "Server finished every requested phase")
	await cleanup()
	h.finish(get_tree())

func split_phase(label: String, rooms: Array, mode: String, count: int, idle_ms: int) -> void:
	server.capacity_begin.rpc(label)
	for index in 5:
		await get_tree().process_frame
	var started := Time.get_ticks_usec()
	var previous := started
	var published := {}
	var ready_ms: Array = []
	var frames: Array = []
	var gaps: Array = []
	var peak_memory := 0
	var total_bytes := 0
	var sync_index := 0
	for room in rooms:
		NetworkService._rooms[room.id] = room
		if mode == "cooperative":
			NetworkService._enqueue_finalize(room)
	var deadline := Time.get_ticks_msec() + 180000
	while Time.get_ticks_msec() < deadline:
		var begin := Time.get_ticks_usec()
		gaps.append(begin - previous)
		previous = begin
		if mode == "cooperative":
			NetworkService._drain_finalize_queue()
		elif sync_index < rooms.size():
			var room: Dictionary = rooms[sync_index]
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
			for peer_id in server.registrations:
				var index: int = server.registrations[peer_id]
				if 100001 + index / 4 == room.id:
					var packed: Dictionary = room.replay_packed
					var own: PackedByteArray = packed.a if index % 4 < 2 else packed.b
					var rival: PackedByteArray = packed.b if index % 4 < 2 else packed.a
					total_bytes += own.size() + rival.size()
					server._send_replay_to_peer(peer_id, room.battle_id, own, rival)
		server._tick_replay_send()
		server._tick_replay_retry(1.0 / 60.0)
		server.sent_chunks.clear()
		peak_memory = maxi(peak_memory, Performance.get_monitor(Performance.MEMORY_STATIC))
		frames.append(Time.get_ticks_usec() - begin)
		if idle_ms > 0 and begin - started >= idle_ms * 1000:
			break
		if idle_ms == 0 and published.size() == rooms.size() and server._replay_out.is_empty():
			break
		await get_tree().process_frame
	var host_wall_ms := (Time.get_ticks_usec() - started) / 1000.0
	server.capacity_collect.rpc(label)
	deadline = Time.get_ticks_msec() + 10000
	while server.reports.size() < count * (2 if label == "battle" else 1) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var pongs: Array = []
	var delivery: Array = []
	var received := 0
	var failed := 0
	var reports := 0
	for peer_id in server.registrations:
		var report: Dictionary = server.reports.get("%s/%d" % [label, peer_id], {})
		if report.is_empty():
			continue
		reports += 1
		pongs.append_array(report.pongs)
		received += int(report.received)
		failed += int(report.failed)
		if report.received > 0:
			delivery.append(report.delivery_ms)
	var stats := {"phase": label, "wall_ms": host_wall_ms, "connected": server.multiplayer.get_peers().size(),
		"heartbeat_p95_ms": percentile(pongs, 0.95) / 1000.0, "heartbeat_max_ms": percentile(pongs, 1.0) / 1000.0,
		"server_frame_max_ms": percentile(frames, 1.0) / 1000.0, "server_gap_max_ms": percentile(gaps, 1.0) / 1000.0,
		"ready_p95_ms": percentile(ready_ms, 0.95), "delivery_p95_ms": percentile(delivery, 0.95),
		"delivered": received, "expected_deliveries": rooms.size() * 4, "failed_replays": failed,
		"replay_bytes": total_bytes, "server_static_memory_peak_bytes": peak_memory, "reports": reports}
	measurements.append(stats)
	print("CAPACITY_PHASE " + JSON.stringify(stats))
	h.expect(reports == count and stats.connected == count, label + "_peers", "Every peer stayed connected and reported")
	h.expect(failed == 0 and received == rooms.size() * 4, label + "_replays", "All real replays decoded, validated and acknowledged")
	NetworkService._rooms.clear()
