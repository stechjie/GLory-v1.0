extends Node
const H := preload("res://tools/CheckHarness.gd")
class Server extends "res://scripts/autoload/NetworkService.gd":
	var clock := 1000.0
	var live := {11: true}
	var sent: Array = []
	var signed_count := 0
	func _ready() -> void:
		_reconnect_service.configure(_now, _net_log, {})
		_room_service.configure(_now, _wall_now, _net_log, func(): return 0, {}, _reconnect_service)
		_match_state.configure(_now)
	func _process(_delta: float) -> void:
		pass
	func _now() -> float:
		return clock
	func _peer_connected(pid: int) -> bool:
		return live.has(pid)
	func _broadcast_room_lobby(_r: Dictionary) -> void:
		pass
	func _resend_result_state(pid: int, ms: Dictionary) -> void:
		sent.append([pid, ms])
	func _room_sign_report(_r: Dictionary, _n: int, _o: int, _a: int, _b: int, _f: Dictionary) -> String:
		signed_count += 1
		return "signed_fixture"
	func _voice_seat_released(_r: Dictionary, _s: int, _i: String) -> void:
		pass
class Client extends "res://scenes/main/Main.gd":
	var shown := 0
	var applied: Dictionary = {}
	func _ready() -> void:
		pass
	func _apply_team_match_state_payload(ms: Dictionary, _result: Dictionary = {}) -> void:
		applied = ms
	func _show_game_over(_data: Dictionary = {}) -> void:
		shown += 1
		_clear()
func _ready() -> void:
	NetworkService.set_process(false)
	var h := H.new("last_human_online")
	var s := Server.new()
	add_child(s)
	for phase in ["prep", "battle", "result"]:
		for survivor in [0, 3]:
			s.clock = 1000.0
			s.live = {11: true}
			var r: Dictionary = s._new_room()
			r.state = phase
			r.round_index = 3
			r.peer_slot = {11: survivor}
			r.initial_seats = ["player", "player", "dummy", "player", "dummy", "empty"]
			r.slot_states = r.initial_seats.duplicate()
			r.battle_id = "%d:3:1" % int(r.id)
			r.human_offline_since = {0: 1000.0, 1: 1000.0, 3: 1000.0}
			r.human_offline_since.erase(survivor)
			s.clock = 1119.0
			h.expect(s._last_online_human_winner(r) == -1, phase + str(survivor) + "_119", "No early victory")
			s.clock = 1120.0
			h.expect(s._last_online_human_winner(r) == survivor, phase + str(survivor) + "_120", "Last survivor after grace")
			s.live[12] = true
			r.peer_slot[12] = 1
			h.expect(s._last_online_human_winner(r) == -1, "two_online", "Any second human blocks victory")
			r.peer_slot.erase(12)
			s.live.erase(12)
			r.slot_states[1] = "dummy"
			h.expect(s._last_online_human_winner(r) == survivor, "ai_preserves_human_history", "AI replacement is not an original bot")
			var old_id: String = r.battle_id
			var gold: Array = r.slot_gold.duplicate()
			var hp: Array = r.team_hp.duplicate()
			s._replay_out[11] = {"battle_id": old_id}
			var before := s.signed_count
			s._tick_reserved_seats()
			h.expect(not s._replay_out.has(11), "cancel_old_delivery", "No stale replay retransmit after terminal result")
			h.expect(r.run_over and r.state == "result", "terminal", "Tick ends entire match")
			h.expect(r.last_match_state[survivor].team_run_won and not r.last_match_state[3 if survivor == 0 else 0].team_run_won, "perspective", "Winner is correct on both teams")
			h.expect(r.slot_gold == gold and r.team_hp == hp, "no_rewards", "No invented round rewards or damage")
			h.expect(not s._simulation_is_current(r.id, old_id), "cancel_old_simulation", "Late simulation cannot overwrite result")
			s._finish_abandoned_match(r, survivor)
			h.expect(s.signed_count == before + 1, "idempotent", "Only one signed terminal result")
	var solo: Dictionary = s._new_room()
	solo.state = "prep"
	solo.initial_seats = ["player", "dummy", "dummy", "dummy", "dummy", "dummy"]
	solo.peer_slot = {11: 0}
	h.expect(s._last_online_human_winner(solo) == -1, "solo_ai", "Solo practice does not auto-win")
	solo.initial_seats[3] = "player"
	solo.human_offline_since = {3: 0.0}
	solo.peer_slot = {}
	h.expect(s._last_online_human_winner(solo) == -1, "zero_online", "No winner with zero online")
	solo.peer_slot = {11: 0}
	solo.state = "lobby"
	h.expect(s._last_online_human_winner(solo) == -1, "lobby", "Lobby not a match")
	# A reconnect cancels abandonment; another disconnect receives a new clock.
	solo.state = "prep"
	solo.slot_states = solo.initial_seats.duplicate()
	solo.peer_slot[12] = 3
	s.live[12] = true
	s._room_reserve_peer(solo, 12)
	s.live.erase(12)
	h.expect(s._last_online_human_winner(solo) == -1, "fresh_disconnect", "A second outage starts a fresh grace")
	s.clock += 119.0
	h.expect(s._last_online_human_winner(solo) == -1, "fresh_119", "Earlier outage does not shorten new grace")
	s.clock += 1.0
	h.expect(s._last_online_human_winner(solo) == 0, "fresh_120", "New outage eventually expires")
	solo.peer_slot[12] = 3
	s.live[12] = true
	s._reconnect_service.release_reservation(solo, 3)
	h.expect(s._last_online_human_winner(solo) == -1, "returned_peer", "Returned player cancels forfeit")
	# Last arriving disconnect controls the grace, not the first departure.
	solo.peer_slot.erase(12)
	s.live.erase(12)
	solo.initial_seats[1] = "player"
	solo.human_offline_since[1] = s.clock - 1.0
	h.expect(s._last_online_human_winner(solo) == -1, "staggered_outages", "Every absent human receives full grace")
	GameState.team_mode = true
	var c := Client.new()
	add_child(c)
	c._resume_replay_pending = {"waiting": true}
	var ms: Dictionary = s.sent[0][1]
	c._on_network_match_state_received(ms)
	h.expect(c.shown == 1 and c.applied.run_over and c._resume_replay_pending.is_empty(), "client_interrupt", "Terminal result interrupts replay recovery")
	c._on_network_match_state_received(ms)
	h.expect(c.shown == 1, "client_duplicate", "Duplicate delivery does not reopen panel")
	# Exercise active battle and preparation owners as well as replay recovery.
	for field in ["_battle", "_prep"]:
		var screen := Control.new()
		c.add_child(screen)
		c.set(field, screen)
		var next := ms.duplicate(true)
		next.battle_id = str(ms.battle_id) + field
		var count := c.shown
		c._on_network_match_state_received(next)
		h.expect(c.shown == count + 1 and not screen.is_inside_tree(), field + "_interrupted", "No lingering battle/loading owner after termination")
	c.queue_free()
	s.queue_free()
	h.finish(get_tree())
