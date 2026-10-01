extends Node

const H := preload("res://tools/CheckHarness.gd")
const Rooms := preload("res://scripts/multiplayer/RoomService.gd")
const Tokens := preload("res://scripts/multiplayer/ReconnectService.gd")
var clock := 1000.0
var closed: Array = []

class ReconnectProbe extends "res://scripts/autoload/NetworkService.gd":
	var resets := 0
	func reset_peer_only() -> void:
		resets += 1
	func _net_log(_message: String) -> void:
		pass

class DisconnectProbe extends "res://scripts/autoload/NetworkService.gd":
	var test_time := 1000.0
	func _now() -> float:
		return test_time
	func _ready() -> void:
		_reconnect_service.configure(_now, _net_log, {})
		_room_service.configure(_now, _wall_now, _net_log, func(): return 0, {}, _reconnect_service)
	func _process(_delta: float) -> void:
		pass
	func _peer_connected(_pid: int) -> bool:
		return false
	func _broadcast_room_lobby(_room: Dictionary) -> void:
		pass
	func _voice_seat_released(_room: Dictionary, _slot: int, _identity: String) -> void:
		pass
	func _net_log(_message: String) -> void:
		pass

func _ready() -> void:
	var h := H.new("mobile_session_retention")
	NetworkService.set_process(false)
	h.expect(NetworkService.ROOM_SUSPEND_GRACE_SEC >= 600.0, "ten_minutes", "Production room recovery retains ten minutes")
	var tokens := Tokens.new()
	var rooms := Rooms.new()
	rooms.configure(func(): return clock, func(): return 0.0, Callable(), func(): return 0,
		{"room_suspend_grace_sec": NetworkService.ROOM_SUSPEND_GRACE_SEC}, tokens)
	for phase in ["lobby", "prep", "battle", "result"]:
		clock = 1000.0
		closed.clear()
		rooms.rooms.clear()
		var room: Dictionary = rooms.new_room()
		room.state = phase
		room.run_over = phase == "result"
		room.seat_tokens = {0: "retention_fixture"}
		tokens.token_seat["retention_fixture"] = {"room_id": room.id, "slot": 0}
		rooms.cleanup_rooms(_close_room, Callable())
		clock = 1599.0
		rooms.cleanup_rooms(_close_room, Callable())
		h.expect(closed.is_empty() and room.suspended, phase + "_retained", "Background room and final settlement remain recoverable before ten minutes")
		clock = 1601.0
		rooms.cleanup_rooms(_close_room, Callable())
		h.expect(closed.size() == 1, phase + "_bounded", "Expired empty rooms still release capacity")
	clock = 1000.0
	closed.clear()
	rooms.rooms.clear()
	var active: Dictionary = rooms.new_room()
	active.state = "battle"
	active.seat_tokens = {0: "retention_fixture"}
	tokens.token_seat["retention_fixture"] = {"room_id": active.id, "slot": 0}
	rooms.cleanup_rooms(_close_room, Callable())
	clock = 1590.0
	active.peer_slot = {17: 0}
	rooms.peer_room[17] = active.id
	rooms.resume_suspended_room(active)
	rooms.cleanup_rooms(_close_room, Callable())
	h.expect(closed.is_empty() and not active.suspended and active.state_started_at == 1590.0,
		"resume_pauses_phase_clock", "Returning after 590 seconds must not trip the 300-second battle watchdog")
	var probe := ReconnectProbe.new()
	probe.session_token = "retention_fixture"
	probe.reconnect_address = "127.0.0.1"
	probe.state = probe.SessionState.RECONNECTING
	probe._reconnect_phase = probe.ReconnectPhase.WAITING_RESUME
	probe._begin_reconnect("duplicate_timeout")
	h.expect(probe.resets == 0 and probe._reconnect_phase == probe.ReconnectPhase.WAITING_RESUME,
		"duplicate_recovery", "Duplicate failure must not destroy a connection awaiting its resume response")
	probe.free()
	var disconnected := DisconnectProbe.new()
	add_child(disconnected)
	for phase in ["lobby", "prep", "battle", "result"]:
		var retained: Dictionary = disconnected._new_room()
		retained.state = phase
		retained.peer_slot = {71: 0}
		retained.slot_states[0] = "player"
		retained.seat_tokens = {0: "zombie_" + phase}
		disconnected._token_seat["zombie_" + phase] = {"room_id": retained.id, "slot": 0}
		disconnected._peer_room[71] = retained.id
		disconnected._peer_last_ping[71] = disconnected._now() - 40.0
		disconnected._reap_zombie_peers()
		h.expect(disconnected._token_seat.has("zombie_" + phase) and retained.reserved.has(0),
			phase + "_silent_disconnect_retained", "Missing disconnect signal must retain the authenticated seat")
		h.expect(not disconnected._peer_room.has(71) and not retained.peer_slot.has(71),
			phase + "_silent_disconnect_detached", "Dead transport must no longer own the reserved seat")
		if phase == "lobby":
			h.expect(float(retained.reserve_deadline.get(0, 0.0)) - disconnected._now() > 599.0,
				"lobby_silent_disconnect_ten_minutes", "Lobby background recovery retains ten minutes")
			disconnected._reap_zombie_peers()
			h.expect(disconnected._token_seat.has("zombie_" + phase), "reap_idempotent", "A repeated sweep preserves credentials")
			retained.peer_slot[72] = 0
			disconnected._peer_room[72] = retained.id
			disconnected._apply_peer_leave(retained, 72)
			h.expect(not disconnected._token_seat.has("zombie_" + phase), "explicit_leave_releases", "Explicit lobby leave still invalidates the credential")
		elif phase == "prep":
			h.expect(is_equal_approx(float(retained.reserve_deadline[0]) - disconnected._now(), 120.0),
				"unready_prep_two_minutes", "Unready preparation seats wait two minutes before AI takeover")
		else:
			h.expect(is_equal_approx(float(retained.reserve_deadline[0]) - disconnected._now(), 20.0),
				phase + "_unchanged_grace", "Battle and result retain their existing short takeover grace")
	var prep: Dictionary = disconnected._new_room()
	prep.state = "prep"
	prep.peer_slot = {81: 0, 82: 3}
	prep.slot_states[0] = "player"
	prep.slot_states[3] = "player"
	prep.ready[3] = true
	disconnected._room_reserve_peer(prep, 81)
	var takeovers: Array = []
	disconnected.test_time += 119.0
	disconnected._reconnect_service.tick_reserved_seats({prep.id: prep}, func(_r, slot): takeovers.append(slot))
	h.expect(takeovers.is_empty() and not disconnected._room_all_ready(prep),
		"unready_wait_before_deadline", "Ready opponents still wait at 119 seconds")
	disconnected.test_time += 1.0
	disconnected._reconnect_service.tick_reserved_seats({prep.id: prep}, func(_r, slot): takeovers.append(slot))
	h.expect(takeovers == [0], "takeover_at_deadline", "Two-minute expiry releases the waiting round")
	prep.peer_slot[81] = 0
	prep.ready[0] = true
	disconnected._room_reserve_peer(prep, 81)
	h.expect(is_equal_approx(float(prep.reserve_deadline[0]) - disconnected._now(), 20.0),
		"ready_prep_short_grace", "Already-ready players do not gain a new preparation wait")
	disconnected.free()
	h.finish(get_tree())

func _close_room(room: Dictionary, reason: String) -> void:
	closed.append(reason)
	room.state = "closed"
