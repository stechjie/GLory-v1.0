extends "res://tools/replay_test_peer.gd"

# Test-only RPCs. This class never enters a production bundle's startup path.
var registrations: Dictionary = {}
var reports: Dictionary = {}
var phase_name := ""
var phase_started := 0
var last_pong_usec := 0
var max_pong_gap_usec := 0
var pong_count := 0
var disconnect_count := 0
var lifetime_last_pong_usec := 0
var lifetime_gap_usec := 0
var real_last_pong_usec := 0
var real_gap_usec := 0
var real_pongs := 0
var heartbeat_timeout_count := 0

@rpc("any_peer", "call_remote", "reliable", 0)
func capacity_register(index: int) -> void:
	_tune_peer_timeout(multiplayer.get_remote_sender_id())
	registrations[multiplayer.get_remote_sender_id()] = index
	_peer_last_ping[multiplayer.get_remote_sender_id()] = _now()

@rpc("authority", "call_remote", "reliable", 0)
func capacity_begin(label: String, sequence: int = 1) -> void:
	phase_name = label
	phase_started = Time.get_ticks_usec()
	last_pong_usec = phase_started
	max_pong_gap_usec = 0
	pong_count = 0
	if label.begins_with("battle"):
		server_round_index = 21
		_set_current_replay_battle("%d:21:%d" % [team_room_id, sequence])
	pongs.clear()
	received_count = 0
	failed_count = 0
	completed_usec = 0

@rpc("authority", "call_remote", "reliable", 0)
func capacity_collect(label: String) -> void:
	capacity_report.rpc_id(1, label, {"pongs": pongs.duplicate(), "received": received_count,
		"failed": failed_count, "disconnects": disconnect_count, "pong_count": pong_count,
		"lifetime_gap_usec": lifetime_gap_usec, "real_pongs": real_pongs,
		"real_gap_usec": real_gap_usec, "heartbeat_timeouts": heartbeat_timeout_count,
		"max_pong_gap_usec": maxi(max_pong_gap_usec, Time.get_ticks_usec() - last_pong_usec), "delivery_ms": (completed_usec - phase_started) / 1000.0 if completed_usec > 0 else 0.0})

@rpc("any_peer", "call_remote", "reliable", 0)
func capacity_report(label: String, data: Dictionary) -> void:
	reports["%s/%d" % [label, multiplayer.get_remote_sender_id()]] = data

@rpc("authority", "call_remote", "reliable", 0)
func capacity_done() -> void:
	phase_name = "done"


@rpc("authority", "call_remote", "unreliable", 0)
func test_pong(sent_usec: int) -> void:
	var now := Time.get_ticks_usec()
	if lifetime_last_pong_usec > 0:
		lifetime_gap_usec = maxi(lifetime_gap_usec, now - lifetime_last_pong_usec)
	lifetime_last_pong_usec = now
	if last_pong_usec > 0:
		max_pong_gap_usec = maxi(max_pong_gap_usec, now - last_pong_usec)
	last_pong_usec = now
	pong_count += 1
	pongs.append(now - sent_usec)


@rpc("authority", "call_remote", "unreliable")
func _rpc_pong() -> void:
	var now := Time.get_ticks_usec()
	if real_last_pong_usec > 0:
		real_gap_usec = maxi(real_gap_usec, now - real_last_pong_usec)
	real_last_pong_usec = now
	real_pongs += 1
	super._rpc_pong()
