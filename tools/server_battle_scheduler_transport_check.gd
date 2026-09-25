extends Node

# Two real SceneMultiplayer/ENet endpoints, localhost only. Both are polled by
# the real SceneTree while the server's production scheduler computes 16 rooms.
# This proves control/heartbeat service under load, not production DTLS/auth.
const Harness := preload("res://tools/CheckHarness.gd")
const Pulse := preload("res://tools/server_scheduler_heartbeat_peer.gd")
const Fixture := preload("res://tools/server_battle_scheduler_check.gd")
var _h := Harness.new("server_battle_scheduler_transport")
var _latencies := {"heartbeat": [], "control": []}
var _heartbeat_received_at: Array = []
var _heartbeat_requests: Array = []
var _heartbeat_replies: Array = []

func _ready() -> void:
	NetworkService.set_process(false)
	NetworkService.enter_test_server_mode()
	DataRegistry.load_all()
	Engine.max_fps = 60
	var server_peer := ENetMultiplayerPeer.new()
	server_peer.set_bind_ip("::1")
	if not _h.expect(server_peer.create_server(0, 2, 2) == OK, "listen_failed", "Cannot bind localhost test ENet socket"):
		_h.finish(get_tree())
		return
	var port := server_peer.host.get_local_port()
	var client_peer := ENetMultiplayerPeer.new()
	client_peer.set_bind_ip("::1")
	if not _h.expect(client_peer.create_client("::1", port, 2) == OK, "connect_failed", "Cannot connect localhost test ENet socket"):
		server_peer.close()
		_h.finish(get_tree())
		return
	var host_branch := Node.new()
	host_branch.name = "Host"
	add_child(host_branch)
	var client_branch := Node.new()
	client_branch.name = "Client"
	add_child(client_branch)
	var host_api := SceneMultiplayer.new()
	var client_api := SceneMultiplayer.new()
	get_tree().set_multiplayer(host_api, host_branch.get_path())
	get_tree().set_multiplayer(client_api, client_branch.get_path())
	host_api.multiplayer_peer = server_peer
	client_api.multiplayer_peer = client_peer
	var host_pulse := Pulse.new()
	host_pulse.name = "Pulse"
	host_branch.add_child(host_pulse)
	var client_pulse := Pulse.new()
	client_pulse.name = "Pulse"
	client_branch.add_child(client_pulse)
	host_pulse.request_received.connect(func(peer_id: int, sent_at: int):
		NetworkService._peer_last_ping[peer_id] = NetworkService._now()
		_heartbeat_requests.append(sent_at))
	client_pulse.reply_received.connect(func(kind: String, elapsed: int, sent_at: int):
		(_latencies[kind] as Array).append(elapsed)
		if kind == "heartbeat":
			_heartbeat_received_at.append(Time.get_ticks_usec())
			_heartbeat_replies.append(sent_at))
	var connect_deadline := Time.get_ticks_msec() + 5000
	while (client_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED or host_api.get_peers().is_empty()) and Time.get_ticks_msec() < connect_deadline:
		await get_tree().process_frame
	if not _h.expect(client_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED, "connect_timeout", "ENet did not establish localhost connection"):
		client_peer.close()
		server_peer.close()
		_h.finish(get_tree())
		return
	var fixture := Fixture.new()
	var peer_id := client_peer.get_unique_id()
	await _exercise("idle_before", client_pulse, server_peer, client_peer, fixture, 3500000)
	for index in 16:
		var room: Dictionary = fixture._fixture(730000 + index, 21, true)
		NetworkService._rooms[room.id] = room
		NetworkService._enqueue_finalize(room)
	await _exercise("loaded_16_rooms", client_pulse, server_peer, client_peer, fixture, 0)
	await _exercise("idle_after", client_pulse, server_peer, client_peer, fixture, 3500000)
	NetworkService._peer_last_ping.erase(peer_id)
	NetworkService._rooms.clear()
	client_peer.close()
	server_peer.close()
	get_tree().set_multiplayer(null, host_branch.get_path())
	get_tree().set_multiplayer(null, client_branch.get_path())
	fixture.free()
	_h.finish(get_tree())


func _exercise(label: String, client_pulse: Node, server_peer: ENetMultiplayerPeer, client_peer: ENetMultiplayerPeer, fixture: Node, idle_usec: int) -> void:
	_latencies = {"heartbeat": [], "control": []}
	_heartbeat_received_at.clear()
	_heartbeat_requests.clear()
	_heartbeat_replies.clear()
	var started := Time.get_ticks_usec()
	var deadline := started + 60000000
	var next_send := 0
	var sent_stamps: Array = []
	var replies_while_busy := 0
	var frames := 0
	var max_frame := 0
	var peer_id := client_peer.get_unique_id()
	NetworkService._peer_last_ping[peer_id] = NetworkService._now()
	var stayed_healthy := true
	var client_throttle_min := 32
	var server_throttle_min := 32
	while Time.get_ticks_usec() < deadline:
		var frame_start := Time.get_ticks_usec()
		var pending := not NetworkService._finalize_queue.is_empty() or not NetworkService._simulation_jobs.is_empty()
		if (idle_usec > 0 and frame_start - started >= idle_usec) or (idle_usec == 0 and not pending):
			break
		if frame_start >= next_send:
			client_pulse.heartbeat.rpc_id(1, frame_start)
			client_pulse.control.rpc_id(1, frame_start)
			sent_stamps.append(frame_start)
			next_send = frame_start + 50000
		NetworkService._tick_heartbeat_timeouts(NetworkService._now())
		stayed_healthy = stayed_healthy and NetworkService._peer_last_ping.has(peer_id)
		if idle_usec == 0:
			NetworkService._drain_finalize_queue()
		client_throttle_min = mini(client_throttle_min, int(client_peer.get_peer(1).get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE)))
		server_throttle_min = mini(server_throttle_min, int(server_peer.get_peer(peer_id).get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE)))
		max_frame = maxi(max_frame, Time.get_ticks_usec() - frame_start)
		frames += 1
		replies_while_busy = (_latencies.heartbeat as Array).size() + (_latencies.control as Array).size()
		await get_tree().process_frame
	var finished := Time.get_ticks_usec()
	for index in 30:
		await get_tree().process_frame
	var last_heartbeat := started
	var max_heartbeat_gap := 0
	for received_at in _heartbeat_received_at:
		max_heartbeat_gap = maxi(max_heartbeat_gap, int(received_at) - last_heartbeat)
		last_heartbeat = int(received_at)
	max_heartbeat_gap = maxi(max_heartbeat_gap, finished - last_heartbeat)
	var missing_request_ms: Array = []
	var missing_reply_ms: Array = []
	for stamp in sent_stamps:
		if not _heartbeat_requests.has(stamp):
			missing_request_ms.append(snappedf((int(stamp) - started) / 1000.0, 0.1))
		if not _heartbeat_replies.has(stamp):
			missing_reply_ms.append(snappedf((int(stamp) - started) / 1000.0, 0.1))
	_h.expect(NetworkService._finalize_queue.is_empty() and NetworkService._simulation_jobs.is_empty(), label + "_simulation_timeout", "16 rooms failed to complete")
	_h.expect(stayed_healthy, label + "_heartbeat_disconnected", "Heartbeat was falsely timed out while simulation ran")
	_h.expect(replies_while_busy > 20, label + "_rpc_starved", "RPC replies did not progress during loaded simulation")
	_h.expect((_latencies.control as Array).size() == sent_stamps.size(), label + "_control_loss", "Reliable control RPC replies were lost")
	# Cold ENet connections can briefly throttle unreliable packets even during
	# the no-work control. Preserve the evidence; loading must still meet 250 ms.
	var gap_limit := int(NetworkService.HEARTBEAT_TIMEOUT_SEC * 1000000.0) if label == "idle_before" else 250000
	_h.expect(max_heartbeat_gap < gap_limit, label + "_heartbeat_gap", "Heartbeat service gap exceeded %d usec" % gap_limit)
	_h.expect(fixture._percentile(_latencies.control, 1.0) < 250000, label + "_control_latency", "Control RPC response exceeded 250 ms on loopback")
	_h.expect(fixture._percentile(_latencies.heartbeat, 1.0) < 250000, label + "_heartbeat_latency", "Heartbeat response exceeded 250 ms on loopback")
	_h.note("phase=%s wall_ms=%.1f frames=%d max_frame_usec=%d sent=%d heartbeat_received=%d heartbeat_p95_usec=%d heartbeat_max_gap_usec=%d control_received=%d control_p95_usec=%d client_throttle_min=%d server_throttle_min=%d missing_request_ms=%s missing_reply_ms=%s" % [
		label, (finished - started) / 1000.0, frames, max_frame, sent_stamps.size(), (_latencies.heartbeat as Array).size(), fixture._percentile(_latencies.heartbeat, 0.95),
		max_heartbeat_gap, (_latencies.control as Array).size(), fixture._percentile(_latencies.control, 0.95), client_throttle_min, server_throttle_min, str(missing_request_ms), str(missing_reply_ms)])
