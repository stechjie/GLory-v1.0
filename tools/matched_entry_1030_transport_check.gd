extends Node
const Keys := preload("res://tools/battle_card_test_keys.gd")
const MATCH := "10301030103010301030103010301030"
var role := ""
var port := 19950
var late := false
var entry_race := false
var race_resumed := false
var ids := {}
var key: CryptoKey
var room: Dictionary = {}
var sent := false
var dropped := false
var old_token := ""
var reports := {}
var finished := false
var signed_card := ""
var b_issued := false
func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="): role = arg.trim_prefix("--role=")
		if arg.begins_with("--port="): port = int(arg.trim_prefix("--port="))
	late = OS.get_cmdline_user_args().has("--late")
	entry_race = OS.get_cmdline_user_args().has("--entry-race")
	NetworkService.set_process(false)
	NetworkService.team_active = true
	NetworkService._dedicated_server = role == "server"
	NetworkService.is_host = role == "server"
	NetworkService._setup_auth()
	if role == "server":
		key = Keys.generate()
		NetworkService._battle_card_public_key = Keys.public_pem(key)
		var peer := ENetMultiplayerPeer.new()
		if peer.create_server(port) != OK: get_tree().quit(2); return
		multiplayer.multiplayer_peer = peer
	else:
		multiplayer.connected_to_server.connect(func(): register.rpc_id(1, role))
		connect_client()
	await get_tree().create_timer(25).timeout
	if not finished:
		print("ENTRY_TRANSPORT TIMEOUT role=", role)
		get_tree().quit(2)
func connect_client() -> void:
	NetworkService.state = NetworkService.SessionState.OFFLINE
	var peer := ENetMultiplayerPeer.new()
	peer.create_client("127.0.0.1", port)
	multiplayer.multiplayer_peer = peer
@rpc("any_peer", "call_remote", "reliable")
func register(who: String) -> void:
	if role != "server": return
	if sent and who == "a": ids["a_reconnected"] = true
	var returning_b := sent and who == "b" and entry_race
	ids[who] = multiplayer.get_remote_sender_id()
	if returning_b: issue("b")
	if ids.size() < 2: return
	if not sent:
		sent = true
		if late: issue("b")
		else: issue("a")
func issue(who: String) -> void:
	var card := Keys.card("11111111-1111-1111-1111-" + ("111111111111" if who == "a" else "222222222222"))
	card["match"] = MATCH; card["team"] = 0; card["seat"] = 0 if who == "a" else 1
	card["mode"] = "ranked"; card["ruleset"] = "normal"
	card["ai"] = [[2,"Bot2",""],[3,"Bot3",""],[4,"Bot4",""],[5,"Bot5",""]]
	join.rpc_id(int(ids[who]), Keys.sign(key, card))
@rpc("authority", "call_remote", "reliable")
func join(card: String) -> void:
	signed_card = card
	NetworkService._rpc_team_join_matched.rpc_id(1, "", card)
func _process(_delta: float) -> void:
	if role != "server" or not sent or finished: return
	room = NetworkService._rooms.get(int(NetworkService._matched_rooms.get(MATCH, 0)), {})
	if room.is_empty(): return
	if entry_race and not dropped and room.seat_pid.size() == 1:
		dropped = true
		old_token = str(room.seat_tokens.get(1, ""))
		drop_connection.rpc_id(int(ids.b))
	elif entry_race and dropped and not b_issued and not NetworkService._peer_connected(int(ids.b)):
		room.created_at = NetworkService._now() - NetworkService.MATCHED_FILL_TIMEOUT_SEC - 1
		NetworkService._cleanup_matched_rooms()
		NetworkService._tick_void_watchdog()
		if str(room.state) != "lobby" or bool(room.get("run_over", false)):
			fail("90s recovery disconnected the last entrant and voided the match"); return
		if not NetworkService._token_seat.has(old_token): fail("entry recovery lost token"); return
		b_issued = true
	elif entry_race and b_issued and not race_resumed and room.peer_slot.has(int(ids.b)):
		NetworkService._cleanup_matched_rooms()
		NetworkService._tick_void_watchdog()
		if str(room.state) != "prep" or bool(room.get("run_over", false)):
			fail("reconnected entrant did not start a playable match"); return
		race_resumed = true
		issue("a")
	elif late and not entry_race and not dropped and room.seat_pid.size() == 1:
		dropped = true
		room.created_at = NetworkService._now() - NetworkService.MATCHED_FILL_TIMEOUT_SEC - 1
		NetworkService._cleanup_matched_rooms()
		if str(room.state) != "prep": fail("missing entrant still blocks ranked start"); return
		issue("a")
	elif not late and not dropped and room.seat_pid.size() == 1:
		dropped = true
		old_token = str(room.seat_tokens.get(0, ""))
		drop_connection.rpc_id(int(ids.a))
	elif not late and dropped and not b_issued and str(room.state) == "lobby" and str(room.slot_states[0]) == "dummy":
		if not NetworkService._token_seat.has(old_token): fail("disconnect revoked token"); return
		b_issued = true
		issue("b")
	if not late and dropped and str(room.state) == "prep" and str(room.slot_states[0]) == "dummy" and ids.has("a_reconnected"):
		ids.erase("a_reconnected")
		issue("a")
	if str(room.state) == "prep" and room.peer_slot.size() == 2 and reports.is_empty():
		reports["pending"] = true
		verify.rpc_id(int(ids.a))
		verify.rpc_id(int(ids.b))
@rpc("authority", "call_remote", "reliable")
func drop_connection() -> void:
	multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	await get_tree().create_timer(0.8).timeout
	connect_client()
@rpc("authority", "call_remote", "reliable")
func verify() -> void:
	await get_tree().create_timer(0.3).timeout
	report.rpc_id(1, role, NetworkService.server_phase == "prep" and NetworkService.team_local_slot == (0 if role == "a" else 1), NetworkService.session_token)
@rpc("any_peer", "call_remote", "reliable")
func report(who: String, ok: bool, token: String) -> void:
	if role != "server": return
	if not ok or (who == "a" and not late and token != old_token) or (entry_race and who == "b" and token != old_token): fail("client resume state or token incorrect"); return
	reports[who] = true
	if reports.has("a") and reports.has("b"):
		print("ENTRY_TRANSPORT_RESULT PASS late=", late, " entry_race=", entry_race, " signed_cards=true independent_clients=2")
		finish.rpc_id(int(ids.a), true); finish.rpc_id(int(ids.b), true)
		finished = true
		await get_tree().create_timer(0.3).timeout
		get_tree().quit()
func fail(reason: String) -> void:
	print("ENTRY_TRANSPORT_RESULT FAIL ", reason)
	finished = true
	get_tree().quit(1)
@rpc("authority", "call_remote", "reliable")
func finish(ok: bool) -> void:
	finished = true
	print("ENTRY_TRANSPORT_CLIENT ", role, " ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)
