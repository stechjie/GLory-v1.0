extends "res://tools/mobile_reconnect_check.gd"
const TimedPeer := preload("res://tools/empty_match_expiry_peer.gd")

func endpoint(label: String, peer: ENetMultiplayerPeer) -> Node:
	var branch := Node.new()
	branch.name = label
	add_child(branch)
	branches.append(branch)
	var api := SceneMultiplayer.new()
	get_tree().set_multiplayer(api, branch.get_path())
	api.multiplayer_peer = peer
	api.server_relay = false
	var node := TimedPeer.new()
	node.name = "Network"
	branch.add_child(node)
	return node

func fixture(client: Node) -> Dictionary:
	server.test_time += 1000.0
	var room: Dictionary = server._new_room()
	room.state = server.ROOM_BATTLE
	room.slot_states = ["player", "dummy", "dummy", "dummy", "dummy", "dummy"]
	var pid: int = client.multiplayer.get_unique_id()
	room.peer_slot = {pid: 0}
	room.empty_since = 0.0
	server._peer_room[pid] = room.id
	room.seat_tokens = {0: "expiry_token"}
	room.seat_public_id = {0: "ABCDEFGHJK"}
	server._token_seat["expiry_token"] = {"room_id": room.id, "slot": 0}
	server._public_token_seat["ABCDEFGHJK"] = "expiry_token"
	# The production leave path starts the timer and retains the credential.
	server._apply_peer_leave(room, pid)
	return room

func run() -> void:
	h = H.new("empty_match_expiry")
	NetworkService.set_process(false)
	Engine.max_fps = 120
	var transport := ENetMultiplayerPeer.new()
	transport.set_bind_ip("::1")
	h.expect(transport.create_server(0, 8) == OK, "server_socket", "Loopback server opens")
	port = transport.host.get_local_port()
	server = endpoint("Server", transport)
	server.enter_test_server_mode()
	var client := add_client(0)
	clients.append(client)
	var deadline := Time.get_ticks_msec() + 5000
	while server.multiplayer.get_peers().is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if not h.expect(not server.multiplayer.get_peers().is_empty(), "connected", "Real ENet client connected"):
		await cleanup()
		h.finish(get_tree())
		return
	for public_code in [false, true]:
		for elapsed in [119.999, 120.0, 120.001]:
			var room := fixture(client)
			var since: float = room.empty_since
			server._cleanup_rooms()
			h.expect(room.suspended and server._token_seat.has("expiry_token"), "suspend", "Five AI seats do not keep the room online")
			server.test_time = since + elapsed
			var eligible: bool = elapsed < 120.0
			h.expect(not server._active_match_for_token("expiry_token").is_empty() == eligible,
				"status_deadline", "Active-match lookup uses the same exact deadline")
			var errors: int = client.resume_errors.size()
			var snapshots: int = client.room_snapshots.size()
			# No periodic cleanup here: the real RPC must reject an expired room itself.
			if public_code:
				client._rpc_public_resume_request.rpc_id(1, "ABCDEFGHJK")
			else:
				client._rpc_resume_request.rpc_id(1, "expiry_token")
			await wait_reply(client, errors + (0 if eligible else 1), snapshots + (1 if eligible else 0))
			if eligible:
				h.expect(client.room_snapshots.size() == snapshots + 1 and not room.suspended and room.empty_since == 0.0,
					"resume_before_deadline", "119.999 seconds: real resume succeeds and clears empty timer")
				var pid: int = client.multiplayer.get_unique_id()
				server._apply_peer_leave(room, pid)
				h.expect(room.empty_since == server.test_time, "restart_timer", "A second last-player departure starts a fresh window")
				server.test_time += 119.999
				server._cleanup_rooms()
				h.expect(server._rooms.has(room.id), "second_window", "Old deadline cannot close the newly empty room")
				server.test_time = float(room.empty_since) + 120.0
				server._cleanup_rooms()
			else:
				h.expect(client.resume_errors.size() == errors + 1 and client.room_snapshots.size() == snapshots,
					"expired_rpc_rejected", "At/after 120 seconds neither token nor short code can revive a room")
			h.expect(not server._rooms.has(room.id) and not server._token_seat.has("expiry_token")
				and not server._public_token_seat.has("ABCDEFGHJK"),
				"closed_and_revoked", "Expired room and both credential indexes are removed")
	# One remaining human prevents expiry, regardless of another player's absence.
	var alive := fixture(client)
	var pid: int = client.multiplayer.get_unique_id()
	alive.peer_slot[pid] = 3
	server._peer_room[pid] = alive.id
	server.test_time += 121.0
	server._cleanup_rooms()
	h.expect(server._rooms.has(alive.id) and not alive.suspended and alive.empty_since == 0.0,
		"one_human_keeps_room", "Room expiry requires zero humans, not just one offline seat")
	server._apply_peer_leave(alive, pid)
	server.test_time += 120.0
	server._cleanup_rooms()
	h.expect(not server._rooms.has(alive.id), "periodic_cleanup", "Periodic cleanup closes the empty room without any resume RPC")
	# AI seats never extend room lifetime, including a departed human already
	# replaced by AI. Exercise the periodic path in every started-match phase.
	for phase in [server.ROOM_PREP, server.ROOM_BATTLE, server.ROOM_RESULT]:
		var ai_room := fixture(client)
		ai_room.state = phase
		ai_room.slot_states = ["dummy", "dummy", "dummy", "dummy", "dummy", "dummy"]
		var departed_at: float = ai_room.empty_since
		server._cleanup_rooms()
		h.expect(server._room_online_count(ai_room) == 0 and ai_room.suspended,
			"ai_only_suspended_%s" % phase, "Six AI seats count as zero online humans")
		server.test_time = departed_at + 119.999
		server._cleanup_rooms()
		h.expect(server._rooms.has(ai_room.id) and ai_room.state == phase,
			"ai_only_grace_%s" % phase, "The room remains recoverable without advancing AI rounds before 120 seconds")
		server.test_time = departed_at + 120.0
		server._cleanup_rooms()
		h.expect(not server._rooms.has(ai_room.id) and not server._token_seat.has("expiry_token")
			and not server._public_token_seat.has("ABCDEFGHJK"),
			"ai_only_expired_%s" % phase, "At 120 seconds the AI-only room and recovery credentials are reclaimed")
	await cleanup()
	h.finish(get_tree())
