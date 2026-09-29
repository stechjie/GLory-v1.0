extends Node

# Local ENet check: real NetworkService RPCs, two independent client processes.
const PORT := 19929
var _server := false
var _slot := 0
var _old: Dictionary = {}
var _clients: Dictionary = {}
var _reports: Dictionary = {}
var _saved: Dictionary = {}
var _finished := false

func _ready() -> void:
	_server = OS.get_cmdline_user_args().has("--final-server")
	_slot = 1 if OS.get_cmdline_user_args().has("--final-client-one") else 0
	NetworkService.set_process(false)
	NetworkService.team_active = true
	NetworkService.is_host = _server
	NetworkService._dedicated_server = _server
	multiplayer.peer_connected.disconnect(NetworkService._on_peer_connected)
	var peer := ENetMultiplayerPeer.new()
	if _server:
		if peer.create_server(PORT) != OK:
			get_tree().quit(2)
			return
		_old = NetworkService._new_room()
		_old["state"] = "result"
		_old["run_over"] = true
		_old["initial_seats"] = ["player", "player", "dummy", "dummy", "dummy", "dummy"]
		_old["slot_states"] = _old.initial_seats.duplicate()
		_old["initial_leader"] = 0
	else:
		for suffix in ["", ".bak", ".tmp"]:
			var path: String = SaveManager.RECONNECT_PATH + suffix
			if FileAccess.file_exists(path):
				_saved[path] = FileAccess.get_file_as_bytes(path)
		NetworkService.state = NetworkService.SessionState.JOINING
		NetworkService.remote_address = "127.0.0.1"
		NetworkService.remote_port = PORT
		NetworkService.settlement_returned.connect(_returned)
		multiplayer.connected_to_server.connect(func(): _register.rpc_id(1, _slot))
		peer.create_client("127.0.0.1", PORT)
	multiplayer.multiplayer_peer = peer
	await get_tree().create_timer(18.0).timeout
	if not _finished:
		print("FINAL_TRANSPORT TIMEOUT")
		_finish(false)

@rpc("any_peer", "call_remote", "reliable")
func _register(slot: int) -> void:
	if not _server or slot not in [0, 1]:
		return
	var pid := multiplayer.get_remote_sender_id()
	_clients[slot] = pid
	_old.peer_slot[pid] = slot
	_old.join_seq[slot] = slot
	NetworkService._peer_room[pid] = int(_old.id)
	if _clients.size() == 2:
		for s in _clients:
			_begin.rpc_id(int(_clients[s]), int(_old.id), int(s))

@rpc("authority", "call_remote", "reliable")
func _begin(old_id: int, slot: int) -> void:
	NetworkService.team_room_id = old_id
	NetworkService.team_local_slot = slot
	NetworkService._applied_epoch = 0
	NetworkService._applied_seq = 99999
	NetworkService.latest_match_state = {"final_settlement": {"sentinel": true}}
	# Non-host returns first; the original host is still looking at the result.
	if slot == 0:
		await get_tree().create_timer(1.0).timeout
	NetworkService.request_settlement_return()

func _returned(ok: bool) -> void:
	var valid := ok and NetworkService.server_phase == "lobby" and NetworkService.team_local_slot == _slot and NetworkService.team_leader_slot == 0
	valid = valid and bool(NetworkService.latest_match_state.get("final_settlement", {}).get("sentinel", false))
	_report.rpc_id(1, valid, NetworkService.team_room_id)

@rpc("any_peer", "call_remote", "reliable")
func _report(ok: bool, room_id: int) -> void:
	if not _server:
		return
	_reports[multiplayer.get_remote_sender_id()] = {"ok": ok, "room": room_id}
	if _reports.size() < 2:
		return
	var values := _reports.values()
	var valid := bool(values[0].ok) and bool(values[1].ok) and int(values[0].room) == int(values[1].room) and int(values[0].room) != int(_old.id)
	print("FINAL_TRANSPORT_RESULT ", "PASS" if valid else "FAIL", " reports=", _reports)
	for pid in _reports:
		_finish.rpc_id(int(pid), valid)
	_finished = true
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(0 if valid else 1)

@rpc("authority", "call_remote", "reliable")
func _finish(ok: bool) -> void:
	_finished = true
	if not _server:
		SaveManager.clear_reconnect()
		for path in _saved:
			var file := FileAccess.open(path, FileAccess.WRITE)
			file.store_buffer(_saved[path])
			file.close()
	print("FINAL_TRANSPORT_CLIENT ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)
