extends Node

func _ready() -> void:
	var server := "--match-test-server" in OS.get_cmdline_user_args()
	var peer := ENetMultiplayerPeer.new()
	NetworkService.set_process(false)
	NetworkService.team_active = true
	NetworkService.is_host = server
	NetworkService._dedicated_server = server
	if server:
		if peer.create_server(19876) != OK:
			get_tree().quit(2)
			return
		NetworkService.state = NetworkService.SessionState.READY
		NetworkService._rooms = {1: {"id": 1, "state": "prep", "peer_slot": {999: 0}, "state_started_at": NetworkService._now(), "run_over": false}}
		NetworkService._peer_room = {999: 1}
		NetworkService._token_seat = {"LOCAL-TEST": {"room_id": 1, "slot": 1}}
		multiplayer.multiplayer_peer = peer
		await get_tree().create_timer(20.0).timeout
		get_tree().quit()
		return
	var saved := {}
	for suffix in ["", ".bak", ".tmp"]:
		var path: String = SaveManager.RECONNECT_PATH + suffix
		if FileAccess.file_exists(path): saved[path] = FileAccess.get_file_as_bytes(path)
	NetworkService.remote_address = "127.0.0.1"
	NetworkService.remote_port = 19876
	NetworkService.state = NetworkService.SessionState.JOINING
	peer.create_client("127.0.0.1", 19876)
	multiplayer.multiplayer_peer = peer
	var deadline := Time.get_ticks_msec() + 5000
	while NetworkService.state == NetworkService.SessionState.JOINING and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.1).timeout
	SaveManager.save_reconnect("LOCAL-TEST", "127.0.0.1", 19876)
	var active := await NetworkService.check_saved_match()
	SaveManager.save_reconnect("MISSING-TEST", "127.0.0.1", 19876)
	var gone := await NetworkService.check_saved_match()
	var cleared := SaveManager.load_reconnect().is_empty()
	NetworkService.reset()
	SaveManager.clear_reconnect()
	for path in saved:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(saved[path])
		f.close()
	var ok := active == "active" and gone == "clear" and cleared
	print("MATCH_TRANSPORT_RESULT ", "PASS" if ok else "FAIL", " active=", active, " gone=", gone, " cleared=", cleared)
	get_tree().quit(0 if ok else 1)
