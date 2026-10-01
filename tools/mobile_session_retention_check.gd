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
	h.finish(get_tree())

func _close_room(room: Dictionary, reason: String) -> void:
	closed.append(reason)
	room.state = "closed"
