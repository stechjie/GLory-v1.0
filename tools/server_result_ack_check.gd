extends Node
const H := preload("res://tools/CheckHarness.gd")
var h := H.new("server_result_ack")

class DeadlineProbe extends "res://scripts/autoload/NetworkService.gd":
	var advanced: Array[int] = []
	func _now() -> float:
		return 1000.0
	func _room_begin_next_prep(room: Dictionary) -> void:
		advanced.append(int(room.id))
		room.state = "prep"

func fixture() -> Dictionary:
	return {"id": 100001, "battle_id": "100001:20:1", "state": "result",
		"state_started_at": NetworkService._now() - 1000.0, "last_match_state": {},
		"slot_states": ["player", "dummy", "empty", "player", "empty", "empty"],
		"peer_slot": {11: 0, 12: 3}, "result_acks": {}}

func advance_clock(room: Dictionary, seconds: float) -> void:
	for key in ["state_started_at", "result_ack_deadline", "result_ack_hard_deadline"]:
		if room.has(key):
			room[key] = float(room[key]) - seconds

func _ready() -> void:
	NetworkService.set_process(false)
	var room := fixture()
	h.expect(not NetworkService._room_result_acks_complete(room), "pending_never_times_out", "Queued/empty simulation does not consume playback ACK time")
	room.last_match_state = {0: {"completed_round": 20}}
	NetworkService._room_start_result_ack_wait(room, 900, 1400, true)
	h.expect(is_equal_approx(float(room.result_playback_sec), 140.0), "longer_side", "Longer rival replay determines playback grace")
	h.expect(is_equal_approx(float(room.result_ack_window_sec), 338.0), "bounded_budgets", "140s playback + 120s total prepare + 60s receive + 18s presentation/ACK")
	advance_clock(room, 61.0)
	h.expect(not NetworkService._room_result_acks_complete(room), "old_60s_regression", "Still-playing client is not advanced by the old 60-second cutoff")
	advance_clock(room, 260.0)
	h.expect(not NetworkService._room_result_acks_complete(room), "cold_prepare_then_long_battle", "Full preparation plus long playback fits before deadline")
	room.result_acks = {0: room.battle_id, 3: room.battle_id}
	h.expect(NetworkService._room_result_acks_complete(room), "acked_immediately", "Both ACKs advance without waiting for generous safety deadline")
	room.result_acks.erase(3)
	room.peer_slot.erase(12)
	h.expect(NetworkService._room_result_acks_complete(room), "offline_not_waited", "Offline human seat cannot delay online ACKed seat")
	room.peer_slot[12] = 3
	advance_clock(room, 18.0)
	h.expect(NetworkService._room_result_acks_complete(room) and room.result_ack_timeout_logged,
		"zombie_bounded", "Unresponsive online human eventually reaches explicit bounded timeout")
	h.expect(NetworkService._room_result_acks_complete(room), "timeout_idempotent", "Repeated timeout query remains safe and logs only once")
	room = fixture()
	room.last_match_state = {0: {"completed_round": 20}}
	room.replay_packed = {"a": PackedByteArray([1]), "b": PackedByteArray([2])}
	NetworkService._room_start_result_ack_wait(room, 1801, 1801, true)
	advance_clock(room, 200.0)
	var before := float(room.result_ack_deadline)
	NetworkService._room_extend_result_ack_for_resume(room)
	h.expect(float(room.result_ack_deadline) > before and is_equal_approx(float(room.result_ack_deadline), float(room.result_ack_hard_deadline)),
		"resume_grace", "Cold resume gets grace bounded by original absolute hard deadline")
	advance_clock(room, 20.0)
	before = float(room.result_ack_deadline)
	NetworkService._room_extend_result_ack_for_resume(room)
	h.expect(is_equal_approx(float(room.result_ack_deadline), before), "resume_not_renewable", "Repeated reconnect never renews the room deadline")
	advance_clock(room, 261.0)
	h.expect(NetworkService._room_result_acks_complete(room), "absolute_hard_limit", "Even resumed zombie cannot hold RESULT beyond 480s from publication")
	room = fixture()
	room.last_match_state = {0: {"completed_round": 20}}
	NetworkService._room_start_result_ack_wait(room, 20, 30, true)
	h.expect(room.result_playback_sec == 8.0, "short_readable", "Short fight includes readable presentation duration")
	NetworkService._room_start_result_ack_wait(room, 4000, 4000, true)
	h.expect(room.result_ack_window_sec == NetworkService.RESULT_ACK_HARD_LIMIT_SEC, "outer_sim_guard", "Outer 4000-step safety limit cannot create unbounded wait")
	NetworkService._room_start_result_ack_wait(room, 0, 0, false)
	h.expect(room.result_playback_sec == 0.0 and room.result_ack_window_sec == 78.0,
		"no_replay", "Explicit empty/failed replay retains bounded control ACK grace without fictitious playback")
	before = room.result_ack_deadline
	NetworkService._room_extend_result_ack_for_resume(room)
	h.expect(room.result_ack_deadline == before and not room.result_resume_grace_used,
		"no_product_resume", "Missing replay never grants repeated playback extension")
	var probe := DeadlineProbe.new()
	room = fixture()
	room.state_started_at = probe._now()
	room.result_ack_deadline = probe._now() - 1.0
	room.last_match_state = {0: {"completed_round": 20}}
	probe._rooms[room.id] = room
	probe._tick_result_ack_deadlines()
	h.expect(probe.advanced == [100001] and room.state == "prep",
		"idle_expired_advances", "Maintenance advances an expired published RESULT with no incoming client RPC")
	probe._tick_result_ack_deadlines()
	h.expect(probe.advanced.size() == 1, "idle_advance_once", "Maintenance never advances the same result twice")
	room.state = "result"
	room.last_match_state = {}
	probe._tick_result_ack_deadlines()
	h.expect(room.state == "result", "idle_pending_waits", "Even an expired deadline cannot advance unpublished simulation")
	room.last_match_state = {0: {"completed_round": 20}}
	room.suspended = true
	probe._tick_result_ack_deadlines()
	h.expect(room.state == "result", "idle_suspended_waits", "Empty suspended rooms keep their existing recovery lifecycle")
	room.suspended = false
	room.run_over = true
	probe._tick_result_ack_deadlines()
	h.expect(room.state == "result", "final_no_extra_round", "Final result never starts an extra round")
	probe.free()
	h.finish(get_tree())
