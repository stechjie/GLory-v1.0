extends "res://tools/replay_transport_check.gd"
const MobilePeer := preload("res://tools/mobile_reconnect_peer.gd")

func endpoint(label: String, peer: ENetMultiplayerPeer) -> Node:
	var branch := Node.new()
	branch.name = label
	add_child(branch)
	branches.append(branch)
	var api := SceneMultiplayer.new()
	get_tree().set_multiplayer(api, branch.get_path())
	api.multiplayer_peer = peer
	api.server_relay = false
	var node := MobilePeer.new()
	node.name = "Network"
	branch.add_child(node)
	return node

func run() -> void:
	h = H.new("mobile_reconnect")
	Engine.max_fps = 60
	var crypto := Crypto.new()
	var generated_key := crypto.generate_rsa(2048)
	var generated_cert := crypto.generate_self_signed_certificate(generated_key, "CN=localhost,O=MobileReconnectQA")
	key = CryptoKey.new()
	key.load_from_string(generated_key.save_to_string())
	cert = X509Certificate.new()
	cert.load_from_string(generated_cert.save_to_string())
	for mode in [false, true]:
		encrypted = mode
		await exercise_resume()
		await get_tree().create_timer(1.0).timeout
		await cleanup()
	h.finish(get_tree())

func exercise_resume() -> void:
	var transport := ENetMultiplayerPeer.new()
	transport.set_bind_ip("::1")
	h.expect(transport.create_server(0, 8) == OK, "server_socket", "Loopback server opens")
	if encrypted:
		h.expect(transport.host.dtls_server_setup(TLSOptions.server(key, cert)) == OK, "server_tls", "DTLS server starts")
	port = transport.host.get_local_port()
	server = endpoint("Server", transport)
	server.enter_test_server_mode()
	server.multiplayer.peer_disconnected.connect(server._on_peer_disconnected)
	var old := add_client(0)
	var fresh := add_client(1)
	clients.append(old)
	clients.append(fresh)
	var deadline := Time.get_ticks_msec() + 5000
	while server.multiplayer.get_peers().size() < 2 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if not h.expect(server.multiplayer.get_peers().size() == 2, "both_connected", "Old and replacement connections coexist"):
		return
	var old_id: int = old.multiplayer.get_unique_id()
	var new_id: int = fresh.multiplayer.get_unique_id()
	var room: Dictionary = server._new_room()
	room.state = server.ROOM_PREP
	room.peer_slot = {old_id: 0}
	room.slot_states = ["player", "dummy", "dummy", "dummy", "dummy", "dummy"]
	room.seat_tokens = {0: "mobile_test_token"}
	server._token_seat["mobile_test_token"] = {"room_id": int(room.id), "slot": 0}
	server._peer_room[old_id] = int(room.id)
	server._peer_last_ping[old_id] = server._now()
	fresh._rpc_resume_request.rpc_id(1, "invalid_token")
	await wait_reply(fresh, 1, 0)
	h.expect(fresh.resume_errors == ["token_unknown"], "invalid_credential", "Wrong credential cannot replace holder")
	fresh._rpc_resume_request.rpc_id(1, "mobile_test_token")
	await wait_reply(fresh, 2, 0)
	h.expect(fresh.resume_errors == ["token_unknown", "seat_busy"], "fresh_holder", "Healthy holder stays protected")
	h.expect(room.peer_slot.has(old_id), "holder_retained", "Failed replacement preserves seat")
	server._peer_last_ping[old_id] = server._now() - server.ConnectionHealth.RESUME_STALE_SEC - 0.1
	fresh._rpc_resume_request.rpc_id(1, "mobile_test_token")
	await wait_reply(fresh, 2, 1)
	h.expect(fresh.room_snapshots.size() == 1, "snapshot_received", "Authenticated replacement receives production room snapshot")
	h.expect(room.peer_slot.get(new_id, -1) == 0 and not room.peer_slot.has(old_id), "seat_transferred", "Half-open peer releases exact seat")
	h.expect(not server._peer_room.has(old_id) and not server._peer_last_ping.has(old_id), "old_maps_cleared", "Old peer state removed")
	h.expect(not server._peer_connected(old_id), "old_transport_closed", "Old live socket is explicitly disconnected")
	server._on_peer_disconnected(old_id)
	h.expect(room.peer_slot.get(new_id, -1) == 0 and not room.reserved.has(0), "late_disconnect", "Delayed old disconnect cannot reserve replacement seat")

func wait_reply(client: Node, errors: int, snapshots: int) -> void:
	var deadline := Time.get_ticks_msec() + 3000
	while (client.resume_errors.size() < errors or client.room_snapshots.size() < snapshots) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
