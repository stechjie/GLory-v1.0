extends Node

const Harness := preload("res://tools/CheckHarness.gd")
const Rooms := preload("res://scripts/multiplayer/RoomService.gd")
const Tokens := preload("res://scripts/multiplayer/ReconnectService.gd")
var now := 100.0
var closed := 0

func _ready() -> void:
	var h := Harness.new("active_match")
	var tokens := Tokens.new()
	tokens.configure(func(): return now, func(_m): pass, {})
	var rooms := Rooms.new()
	rooms.configure(func(): return now, func(): return 1700000000.0, func(_m): pass, func(): return 0, {"room_suspend_grace_sec": NetworkService.ROOM_SUSPEND_GRACE_SEC}, tokens)
	var room := {"id": 1, "state": "prep", "run_over": false, "empty_since": 100.0, "peer_slot": {}, "slot_states": ["dummy", "dummy"], "seat_tokens": {0: "TEST"}, "state_started_at": 100.0}
	# RoomService counts seat_tokens via their live token index.
	tokens.token_seat["TEST"] = {"room_id": 1, "slot": 0}
	rooms.rooms[1] = room
	var close := func(r: Dictionary, _reason: String):
		closed += 1
		r.state = "closed"
	var advance := func(_r): pass
	now = 129.9
	rooms.cleanup_rooms(close, advance)
	h.expect(closed == 0, "grace", "Room closed before 30 seconds")
	h.expect(rooms.room_online_count(room) == 0, "ai_not_human", "AI counted as an online human")
	now = 130.0
	rooms.cleanup_rooms(close, advance)
	h.expect(closed == 1 and rooms.rooms.is_empty(), "expiry", "AI-only room survived 30 seconds")
	room.state = "prep"
	room.peer_slot = {7: 0}
	rooms.rooms[1] = room
	rooms.peer_room[7] = 1
	now = 200.0
	rooms.cleanup_rooms(close, advance)
	h.expect(closed == 1 and float(room.empty_since) == 0.0, "human_keeps_match", "Online human did not preserve match")
	room.peer_slot = {}
	rooms.peer_room.clear()
	rooms.cleanup_rooms(close, advance)
	h.expect(float(room.empty_since) == 200.0, "restart_timer", "Last human leaving did not restart grace")
	var saved := {}
	for suffix in ["", ".bak", ".tmp"]:
		var path: String = SaveManager.RECONNECT_PATH + suffix
		if FileAccess.file_exists(path): saved[path] = FileAccess.get_file_as_bytes(path)
	SaveManager.clear_reconnect()
	SaveManager.save_reconnect("TEST", "127.0.0.1", 8910)
	SaveManager.mark_match_started()
	SaveManager.save_reconnect("TEST", "127.0.0.1", 8910)
	h.expect(bool(SaveManager.load_reconnect().get("match_started", false)), "late_refresh", "Refresh erased started-match marker")
	h.expect(not SaveManager.load_resumable_reconnect().is_empty(), "can_resume", "Started match is not resumable")
	NetworkService.request_user_leave()
	h.expect(not SaveManager.load_resumable_reconnect().is_empty(), "explicit_leave", "Leaving a started match destroyed credentials")
	NetworkService.cancel_reconnect()
	h.expect(not SaveManager.load_resumable_reconnect().is_empty(), "cancel_resume", "Cancelling resume unlocked a started match")
	var old_rooms: Dictionary = NetworkService._rooms
	var old_tokens: Dictionary = NetworkService._token_seat
	var old_peers: Dictionary = NetworkService._peer_room
	NetworkService._rooms = {1: {"id": 1, "state": "prep", "peer_slot": {7: 0}, "run_over": false}}
	NetworkService._token_seat = {"TEST": {"room_id": 1, "slot": 1}}
	NetworkService._peer_room = {7: 1}
	h.expect(not NetworkService._active_match_for_token("TEST").is_empty(), "other_human_blocks", "Other online human did not block new match")
	NetworkService._rooms[1].run_over = true
	h.expect(NetworkService._active_match_for_token("TEST").is_empty(), "finished_unlocks", "Finished match still blocks new match")
	NetworkService._rooms[1].run_over = false
	NetworkService._rooms[1].state = "lobby"
	h.expect(NetworkService._active_match_for_token("TEST").is_empty(), "lobby_unlocks", "Unstarted lobby blocks new match")
	h.expect(NetworkService._active_match_for_token("MISSING").is_empty(), "gone_unlocks", "Missing match still blocks new match")
	NetworkService._rooms = old_rooms
	NetworkService._token_seat = old_tokens
	NetworkService._peer_room = old_peers
	SaveManager.save_reconnect("LOBBY", "127.0.0.1", 8910)
	SaveManager.mark_pending_leave("LEFT")
	h.expect(SaveManager.load_resumable_reconnect().is_empty(), "lobby_leave", "Lobby leave became resumable")
	SaveManager.clear_reconnect()
	for path in saved:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(saved[path])
		f.close()
	h.finish(get_tree())
