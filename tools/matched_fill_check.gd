extends SceneTree

const H := preload("res://tools/CheckHarness.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var h := H.new("matched_fill")
	var net = root.get_node("NetworkService")
	net.set_process(false)
	net.enter_test_server_mode()
	var room: Dictionary = net._new_room()
	room.matched = true
	room.match_uid = "missing_one"
	room.created_at = net._now() - 91.0
	room.slot_states = ["player", "player", "player", "player", "player", "empty"]
	room.ready = [false, false, false, false, false, false]
	net._matched_rooms[room.match_uid] = int(room.id)
	net._matched_try_start(room)
	h.expect(room.state == "lobby" and room.ready == [false, false, false, false, false, false],
		"waiting_atomic", "Missing seat waits without partially changing readiness")
	net._cleanup_matched_rooms()
	h.expect(room.state == "prep" and room.slot_states[5] == "dummy",
		"timeout_starts", "Five players and timeout AI enter preparation")
	room.ready[0] = true
	net._matched_try_start(room)
	h.expect(room.state == "prep" and room.ready[0] and not room.ready[1],
		"no_restart", "Repeated start cannot reset a running round or ready other players")
	var full: Dictionary = net._new_room()
	full.slot_states.fill("player")
	net._matched_try_start(full)
	h.expect(full.state == "prep", "full_starts", "Six human seats still start")
	var ranked: Dictionary = net._new_room()
	ranked.matched = true
	ranked.mode = "ranked"
	ranked.match_uid = "ranked_missing"
	ranked.created_at = net._now() - 91.0
	ranked.slot_states = ["player", "player", "player", "player", "player", "empty"]
	net._matched_rooms[ranked.match_uid] = int(ranked.id)
	net._cleanup_matched_rooms()
	h.expect(ranked.state == "closed" and ranked.finished_reason == "ranked_entry_timeout" and not ranked.slot_states.has("dummy"),
		"ranked_timeout", "Incomplete ranked entry ends explicitly without an AI or battle report")
	var custom: Dictionary = net._new_room()
	custom.slot_states = ["player", "empty", "empty", "player", "empty", "empty"]
	custom.ready = [true, false, false, false, false, false]
	net._room_start_authoritative(custom)
	h.expect(custom.state == "lobby" and "start_blocked" in str(custom.get("progress_log_snapshot", "")),
		"blocked_logged", "Unready human prevents custom start with diagnostic reason")
	custom.ready[3] = true
	net._room_start_authoritative(custom)
	h.expect(custom.state == "prep", "custom_starts", "Ready custom room still starts")
	h.finish(self)
