extends "res://tools/server_capacity_check.gd"

var disconnected_peers := 0
var target_host := "::1"

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

func add_client(index: int) -> Node:
	var transport := ENetMultiplayerPeer.new()
	transport.set_bind_ip("::1" if target_host == "::1" else "0.0.0.0")
	var error := transport.create_client(target_host, port)
	if not h.expect(error == OK, "client_socket", "Capacity client socket opens"):
		return null
	error = transport.get_host().dtls_client_setup("localhost", TLSOptions.client(cert))
	h.expect(error == OK, "client_tls", "Client pins the test server certificate")
	var client := endpoint("Client%d_%d" % [index, branches.size()], transport)
	client.team_active = true
	client.team_room_id = 100001 + index / 4
	return client

func split_run() -> void:
	h = H.new("server_capacity_split")
	var expected_dir := arg("--qa-user-dir-tag", "")
	print("CAPACITY_USER_DIR " + OS.get_user_data_dir())
	if not expected_dir.is_empty() and not h.expect(OS.get_user_data_dir().get_file() == expected_dir, "isolated_user_dir", "Capacity process uses its own user data directory"):
		h.finish(get_tree())
		return
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
	var generated_key := crypto.generate_rsa(2048)
	var generated_cert := crypto.generate_self_signed_certificate(generated_key, "CN=localhost,O=SplitCapacityQA")
	key = CryptoKey.new()
	key.load_from_string(generated_key.save_to_string())
	cert = X509Certificate.new()
	cert.load_from_string(generated_cert.save_to_string())
	var transport := ENetMultiplayerPeer.new()
	transport.set_bind_ip(arg("--bind-host", "::1"))
	assert(transport.create_server(int(arg("--bind-port", "0")), 512) == OK)
	assert(transport.host.dtls_server_setup(TLSOptions.server(key, cert)) == OK)
	port = transport.host.get_local_port()
	server = endpoint("Server", transport)
	server._dedicated_server = true
	server.multiplayer.peer_disconnected.connect(server._replay_forget_peer)
	server.multiplayer.peer_disconnected.connect(func(_id): disconnected_peers += 1)
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
	var waves := clampi(int(arg("--waves", "1")), 1, 100)
	for wave in (waves if rooms > 0 else 0):
		var fixture := Fixture.new()
		var fixtures: Array = []
		for index in rooms:
			var room := fixture._fixture(100001 + index, 21, true)
			room.battle_id = "%d:21:%d" % [room.id, wave + 1]
			room.shared_seed += wave * 1000
			fixtures.append(room)
		fixture.free()
		await split_phase("battle_%02d" % (wave + 1), fixtures, mode, count, 0, wave + 1)
		if disconnected_peers > 0:
			break
	h.expect(measurements.size() == (1 + waves if rooms > 0 else 1), "phases_complete", "Every requested phase completed")
	print("CAPACITY_COMPLETE " + JSON.stringify({"peers": count, "rooms_2v2": rooms, "mode": mode, "waves": waves, "split_processes": true, "measurements": measurements}))
	server.capacity_done.rpc()
	for index in 30:
		await get_tree().process_frame
	# The isolated process owns ENet contexts until SceneTree shutdown.
	h.finish(get_tree())

func split_clients(count: int, rendezvous: String) -> void:
	var settings: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(rendezvous))
	port = settings.port
	target_host = arg("--host", "::1")
	var first := clampi(int(arg("--client-start", "0")), 0, count - 1)
	count = clampi(int(arg("--client-count", str(count))), 1, count - first)
	cert = X509Certificate.new()
	cert.load_from_string(settings.public_cert)
	for index in count:
		var client := add_client(index + first)
		client.server_round_index = 21
		client._set_current_replay_battle("%d:21:1" % client.team_room_id)
		client.team_replay_received.connect(func():
			client.team_replay = {}
			client.team_replay_rival = {})
		client.multiplayer.server_disconnected.connect(func(): client.disconnect_count += 1)
		clients.append(client)
		if index % 8 == 7:
			# Capacity measures established sessions. Bound connection ramp rather
			# than flooding the engine's pending DTLS handshake queue in one burst.
			var connect_deadline := Time.get_ticks_msec() + 15000
			while not clients.all(func(c): return c.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED) and Time.get_ticks_msec() < connect_deadline:
				await get_tree().process_frame
	var registered := {}
	var next_ping := 0
	var next_real_ping := 0
	var deadline := Time.get_ticks_msec() + clampi(int(arg("--waves", "1")), 1, 100) * 190000 + 90000
	while Time.get_ticks_msec() < deadline:
		var now := Time.get_ticks_usec()
		for index in clients.size():
			var client: Node = clients[index]
			if client.multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
				continue
			if not registered.has(index):
				client._tune_peer_timeout(1)
				client.capacity_register.rpc_id(1, index + first)
				registered[index] = true
				client._last_pong_at = client._now()
				client.real_last_pong_usec = now
			if client._now() - client._last_pong_at > client.HEARTBEAT_TIMEOUT_SEC:
				client.heartbeat_timeout_count += 1
				client.multiplayer.multiplayer_peer.close()
				continue
			if now >= next_real_ping:
				client._ping_sent_at = Time.get_ticks_msec()
				client._rpc_ping.rpc_id(1)
			if now >= next_ping:
				client.test_ping.rpc_id(1, now)
		if now >= next_real_ping:
			next_real_ping = now + int(NetworkService.HEARTBEAT_INTERVAL_SEC * 1000000)
		if now >= next_ping:
			next_ping = now + 250000
		if clients.all(func(c): return c.phase_name == "done"):
			break
		await get_tree().process_frame
	h.expect(clients.all(func(c): return c.phase_name == "done"), "server_finished", "Server finished every requested phase")
	# The isolated process owns ENet contexts until SceneTree shutdown.
	h.finish(get_tree())

func split_phase(label: String, rooms: Array, mode: String, count: int, idle_ms: int, sequence: int = 1) -> void:
	var expected_reports: int = server.reports.size() + count
	server.capacity_begin.rpc(label, sequence)
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
		server._tick_heartbeat_timeouts(server._now())
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
	while server.reports.size() < expected_reports and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var pongs: Array = []
	var delivery: Array = []
	var received := 0
	var failed := 0
	var reports := 0
	var pong_gap := 0
	var missing_pongs := 0
	var client_disconnects := 0
	var real_gap := 0
	var real_timeouts := 0
	var missing_real_pongs := 0
	var lifetime_gap := 0
	for peer_id in server.registrations:
		var report: Dictionary = server.reports.get("%s/%d" % [label, peer_id], {})
		if report.is_empty():
			continue
		reports += 1
		pong_gap = maxi(pong_gap, int(report.get("max_pong_gap_usec", 0)))
		missing_pongs += int(int(report.get("pong_count", 0)) == 0)
		client_disconnects += int(report.get("disconnects", 0))
		real_gap = maxi(real_gap, int(report.get("real_gap_usec", 0)))
		real_timeouts += int(report.get("heartbeat_timeouts", 0))
		missing_real_pongs += int(int(report.get("real_pongs", 0)) == 0)
		lifetime_gap = maxi(lifetime_gap, int(report.get("lifetime_gap_usec", 0)))
		pongs.append_array(report.pongs)
		received += int(report.received)
		failed += int(report.failed)
		if report.received > 0:
			delivery.append(report.delivery_ms)
	var stats := {"phase": label, "wall_ms": host_wall_ms, "heartbeat_gap_max_ms": pong_gap / 1000.0,
		"real_heartbeat_gap_max_ms": real_gap / 1000.0, "heartbeat_timeouts": real_timeouts,
		"probe_lifetime_gap_max_ms": lifetime_gap / 1000.0, "disconnects": disconnected_peers, "client_disconnects": client_disconnects, "peers_without_pong": missing_pongs, "connected": server.multiplayer.get_peers().size(),
		"heartbeat_p95_ms": percentile(pongs, 0.95) / 1000.0, "heartbeat_max_ms": percentile(pongs, 1.0) / 1000.0,
		"server_frame_max_ms": percentile(frames, 1.0) / 1000.0, "server_gap_max_ms": percentile(gaps, 1.0) / 1000.0,
		"ready_p95_ms": percentile(ready_ms, 0.95), "delivery_p95_ms": percentile(delivery, 0.95),
		"delivered": received, "expected_deliveries": rooms.size() * 4, "failed_replays": failed,
		"replay_bytes": total_bytes, "server_static_memory_peak_bytes": peak_memory, "reports": reports}
	measurements.append(stats)
	print("CAPACITY_PHASE " + JSON.stringify(stats))
	h.expect(reports == count and stats.connected == count, label + "_peers", "Every peer stayed connected and reported")
	h.expect(disconnected_peers == 0 and client_disconnects == 0, label + "_no_disconnects", "No transient or lasting disconnects")
	h.expect(missing_pongs == 0 and pong_gap < 2500000, label + "_heartbeat_gap", "Every peer receives heartbeats with less than 2.5s silence")
	h.expect(real_timeouts == 0 and missing_real_pongs == 0 and real_gap < 9500000, label + "_production_heartbeat", "Real production ping/pong cadence stays below half the timeout window")
	h.expect(failed == 0 and received == rooms.size() * 4, label + "_replays", "All real replays decoded, validated and acknowledged")
	NetworkService._rooms.clear()
