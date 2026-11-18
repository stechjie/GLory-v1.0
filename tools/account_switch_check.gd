extends Node

# Actual HTTPRequest integration with a loopback-only delayed HTTP server. No
# provider SDK, remote account service or real identity proof is used.
const Harness := preload("res://tools/CheckHarness.gd")
const FILES := ["profile.json", "glory_account.json", "glory_beta_004.save",
	"glory_reconnect.json", "glory_tutorial.json", "glory_device.json", "glory_public_token.txt"]

class ProbeAccount extends "res://scripts/autoload/AccountManager.gd":
	var loopback := ""
	var completed_logins := 0
	var local_logouts := 0
	var received_session: Dictionary = {}
	func _ready() -> void:
		pass
	func _account_endpoint(path: String) -> String:
		return loopback + path
	func logout() -> void:
		# Preserve the real user files. Only the transport/generation behavior is
		# relevant here; a successful provider exchange is a controlled fixture.
		local_logouts += 1
		_session_generation += 1
		_access_token = ""
		_login_session_id = ""
		player_id = ""
		state = State.IDLE
	func _finish_success(body: Dictionary) -> void:
		completed_logins += 1
		received_session = body.duplicate(true)
		_login_session_id = str(body.get("session_id", ""))
		player_id = str(body.get("player_id", ""))
		_access_token = str(body.get("access_token", ""))
		state = State.LOGGED_IN
		_busy = false

var _h: Harness
var _server := TCPServer.new()
var _connections: Array[Dictionary] = []
var _requests: Array[Dictionary] = []
var _backup: Dictionary = {}
var _realtime_before: Dictionary = {}
var _account_before: Dictionary = {}
var _port := 0

func _ready() -> void:
	_h = Harness.new("account_switch")
	_h.note("Loopback HTTP fixture ready; user files will be restored")
	_backup_files()
	_snapshot_realtime()
	if not _h.expect(_server.listen(0, "127.0.0.1") == OK, "loopback_server", "Loopback HTTP server listens"):
		_finish()
		return
	_port = _server.get_local_port()
	await _case_stale_http_before_provider_success()
	await _case_http_failure_restores_same_session(true)
	await _case_http_failure_restores_same_session(false)
	await _case_kicked_failure_stays_offline()
	await _case_existing_refresh_finishes_before_fence()
	await _case_stale_open_cannot_change_restarted_attempt()
	_case_realtime_restore_never_clears_kick()
	_finish()

func _process(_delta: float) -> void:
	while _server.is_connection_available():
		_connections.append({"peer": _server.take_connection(), "buffer": "", "received": false})
	for connection in _connections:
		var peer: StreamPeerTCP = connection.peer
		peer.poll()
		if connection.received:
			continue
		var count := peer.get_available_bytes()
		if count <= 0:
			continue
		var bytes := peer.get_data(count)
		if int(bytes[0]) != OK:
			continue
		connection.buffer += (bytes[1] as PackedByteArray).get_string_from_utf8()
		var raw: String = connection.buffer
		var header_end := raw.find("\r\n\r\n")
		if header_end < 0:
			continue
		var content_length := 0
		for line in raw.substr(0, header_end).split("\r\n"):
			if line.to_lower().begins_with("content-length:"):
				content_length = int(line.get_slice(":", 1).strip_edges())
		if raw.substr(header_end + 4).to_utf8_buffer().size() < content_length:
			continue
		connection.received = true
		# Retain only the request path and peer, never authorization headers.
		_requests.append({"path": raw.get_slice("\r\n", 0).get_slice(" ", 1), "peer": peer, "sent": false})
		connection.buffer = ""

func _probe(wanted: bool = true) -> ProbeAccount:
	RealtimeService.stop()
	RealtimeService._kicked = false
	RealtimeService._want_connection = wanted
	RealtimeService.set_process(false)
	var probe := ProbeAccount.new()
	probe.loopback = "http://127.0.0.1:%d" % _port
	probe.player_id = "fixture-same-player"
	probe.player_name = "Fixture"
	probe._login_session_id = "fixture-old-session"
	probe._access_token = "fixture-access-token"
	probe._token_expires_at = Time.get_unix_time_from_system() + 3600.0
	probe.state = probe.State.LOGGED_IN
	add_child(probe)
	return probe

func _capture_http(probe: ProbeAccount, path: String, out: Dictionary, key: String) -> void:
	out[key] = await probe._request(HTTPClient.METHOD_GET, path, null, true, false)

func _capture_switch(probe: ProbeAccount, out: Dictionary) -> void:
	out["switch"] = await probe.switch_with_provider("apple", "fixture-provider-proof", "fixture-raw-nonce")

func _capture_refresh(probe: ProbeAccount, out: Dictionary) -> void:
	out["refresh"] = await probe.refresh_session()

func _wait_request(path: String) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline:
		for request in _requests:
			if request.path == path and not request.sent:
				return request
		await get_tree().process_frame
	_h.fail("request_timeout", "Loopback request did not arrive: " + path)
	return {}

func _wait_result(out: Dictionary, key: String) -> void:
	var deadline := Time.get_ticks_msec() + 4000
	while not out.has(key) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_h.expect(out.has(key), "result_timeout_" + key, "Local request returned a result")

func _reply(request: Dictionary, code: int, body: Dictionary) -> void:
	if request.is_empty():
		return
	var json := JSON.stringify(body)
	var response := "HTTP/1.1 %d Fixture\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [code, json.to_utf8_buffer().size(), json]
	var peer: StreamPeerTCP = request.peer
	_h.expect(peer.put_data(response.to_utf8_buffer()) == OK, "reply_write", "Delayed loopback response was delivered")
	request.sent = true

func _session(refresh := "fixture-new-refresh") -> Dictionary:
	return {"player_id": "fixture-same-player", "player_name": "Fixture", "session_id": "fixture-new-session",
		"access_token": "fixture-new-access", "refresh_token": refresh, "expires_in": 3600, "onboarded": true}

func _case_stale_http_before_provider_success() -> void:
	_h.note("Old HTTP 409 before provider 200")
	var probe := _probe()
	var result: Dictionary = {}
	var profile_before := PlayerProfile.player_id
	_capture_http(probe, "/fixture/old-profile", result, "old")
	var old := await _wait_request("/fixture/old-profile")
	_capture_switch(probe, result)
	var provider := await _wait_request("/v1/auth/provider")
	_h.expect(probe.is_switching_account() and not RealtimeService._want_connection and not RealtimeService.is_processing(),
		"provider_pauses_transport", "Existing realtime connection stays paused while provider exchange is in flight")
	var request_count := _requests.size()
	var blocked := await probe._request(HTTPClient.METHOD_GET, "/fixture/must-not-send", null, true)
	_h.expect(int(blocked.get("code", -1)) == 0 and _requests.size() == request_count,
		"old_session_requests_blocked", "No old-session authenticated traffic is sent during the exchange")
	_h.expect(not await probe.refresh_session(), "new_refresh_blocked", "No new refresh starts during the exchange")
	_reply(old, 409, {"detail": "session_replaced"})
	await _wait_result(result, "old")
	_h.expect(int((result.get("old", {}) as Dictionary).get("code", -1)) == 0 and not RealtimeService.is_kicked(),
		"stale_http_409_ignored", "An actual old HTTP 409 is discarded without invalidating provider exchange")
	_reply(provider, 200, _session())
	await _wait_result(result, "switch")
	_h.expect(int((result.get("switch", {}) as Dictionary).get("code", 0)) == 200 and probe.completed_logins == 1,
		"provider_200_survives", "Provider HTTP 200 remains usable after old HTTP 409")
	_h.expect(not probe.is_switching_account() and probe.player_id == "fixture-same-player" and probe.local_logouts == 1,
		"successful_switch_completed", "Successful explicit login commits exactly once")
	_h.expect(PlayerProfile.player_id == profile_before, "same_player_profile_preserved", "Same-player login does not reset the profile identity")
	probe.free()

func _case_http_failure_restores_same_session(wanted: bool) -> void:
	_h.note("Provider failure; prior realtime intent=" + str(wanted))
	var probe := _probe(wanted)
	var result: Dictionary = {}
	_capture_switch(probe, result)
	var provider := await _wait_request("/v1/auth/provider")
	_reply(provider, 503, {"detail": "fixture unavailable"})
	await _wait_result(result, "switch")
	# Disable automatic processing before the next frame; the fixture never opens
	# an actual realtime socket or calls the configured remote service.
	RealtimeService.set_process(false)
	_h.expect(probe._login_session_id == "fixture-old-session" and probe._access_token == "fixture-access-token"
		and probe.player_id == "fixture-same-player" and probe.local_logouts == 0,
		"failed_switch_preserves_session_" + str(wanted), "Provider failure preserves the prior local session")
	_h.expect(RealtimeService._want_connection == wanted and not RealtimeService.is_kicked(),
		"failure_resumes_only_previous_want_" + str(wanted), "Failure restores only the prior realtime intent")
	_h.expect(not probe.is_switching_account() and not probe._busy, "failure_releases_gate_" + str(wanted),
		"Failed exchange releases the temporary request gate")
	probe.free()

func _case_kicked_failure_stays_offline() -> void:
	_h.note("A genuine kick supersedes provider exchange")
	var probe := _probe()
	var result: Dictionary = {}
	_capture_switch(probe, result)
	var provider := await _wait_request("/v1/auth/provider")
	RealtimeService._kicked = true
	probe.invalidate_login_session()
	_reply(provider, 200, _session())
	await _wait_result(result, "switch")
	_h.expect(probe.completed_logins == 0 and probe.local_logouts == 0 and RealtimeService.is_kicked()
		and not RealtimeService._want_connection, "genuine_kick_wins", "A genuine later session invalidation cannot be overwritten by provider success")
	probe.free()

func _case_existing_refresh_finishes_before_fence() -> void:
	_h.note("Existing refresh completes before provider failure")
	var probe := _probe()
	# The sole real refresh implementation reads a harmless fixture from disk.
	# All original credential/profile files (including .bak/.tmp) are restored.
	SaveManager.save_account_credentials("fixture-old-refresh", "fixture-same-player")
	var result: Dictionary = {}
	_capture_refresh(probe, result)
	var refresh := await _wait_request("/v1/auth/refresh")
	var generation_before := probe._session_generation
	var provider_count := _count_path("/v1/auth/provider")
	_capture_switch(probe, result)
	_h.expect(probe.is_switching_account() and probe._session_generation == generation_before
		and _count_path("/v1/auth/provider") == provider_count, "refresh_drains_before_fence", "Existing refresh completes before generation fencing or provider request")
	var refreshed := _session("fixture-rotated-refresh")
	refreshed["session_id"] = "fixture-old-session"
	_reply(refresh, 200, refreshed)
	await _wait_result(result, "refresh")
	var provider := await _wait_request("/v1/auth/provider")
	_h.expect(bool(result.get("refresh", false)) and str(SaveManager.load_account_credentials().get("refresh_token", "")) == "fixture-rotated-refresh",
		"rotated_refresh_saved", "Actual refresh applies the rotated credential before provider exchange")
	_reply(provider, 503, {"detail": "fixture unavailable"})
	await _wait_result(result, "switch")
	RealtimeService.set_process(false)
	_h.expect(str(SaveManager.load_account_credentials().get("refresh_token", "")) == "fixture-rotated-refresh"
		and probe._login_session_id == "fixture-old-session" and probe.local_logouts == 0,
		"failed_provider_keeps_rotated_refresh", "Provider failure retains the safely rotated old-session credential")
	probe.free()

func _case_realtime_restore_never_clears_kick() -> void:
	RealtimeService.stop()
	RealtimeService._kicked = true
	var epoch: int = RealtimeService._open_generation
	_h.expect(not RealtimeService.pause_for_account_switch() and RealtimeService._open_generation > epoch,
		"pause_fences_stale_open", "Pausing invalidates an older asynchronous open attempt")
	RealtimeService.resume_after_account_switch(true)
	_h.expect(RealtimeService.is_kicked() and not RealtimeService._want_connection
		and not RealtimeService.is_processing(), "resume_does_not_reclaim", "Failure restoration never clears a real kick or reclaims another device's session")
	AccountManager._switching_account = true
	RealtimeService.start()
	_h.expect(not RealtimeService._want_connection and RealtimeService.is_kicked(),
		"automatic_start_blocked_during_switch", "Another caller cannot reopen the old session or clear a kick during switching")
	AccountManager._switching_account = false

func _case_stale_open_cannot_change_restarted_attempt() -> void:
	# Both production _open coroutines join a deliberately suspended refresh.
	# No HTTP is issued and the empty access token prevents any socket dial.
	RealtimeService.stop()
	RealtimeService._kicked = false
	AccountManager._switching_account = false
	AccountManager.state = AccountManager.State.LOGGED_IN
	AccountManager.player_id = "fixture-open-player"
	AccountManager._access_token = ""
	AccountManager._token_expires_at = Time.get_unix_time_from_system() - 1.0
	AccountManager._refreshing = true
	RealtimeService._want_connection = true
	RealtimeService._open()
	_h.expect(RealtimeService._opening, "old_open_waits", "The original open attempt is awaiting refresh")
	RealtimeService.pause_for_account_switch()
	var observed: Dictionary = {}
	# Signal connection order places this observer after the old continuation
	# and before the newly restarted one.
	var between := func(_ok: bool) -> void: observed["new_attempt_still_opening"] = RealtimeService._opening
	AccountManager._refresh_finished.connect(between, CONNECT_ONE_SHOT)
	RealtimeService._want_connection = true
	RealtimeService._open()
	_h.expect(RealtimeService._opening, "replacement_open_waits", "A replacement open attempt can wait independently")
	AccountManager._refresh_finished.emit(false)
	AccountManager._refreshing = false
	_h.expect(bool(observed.get("new_attempt_still_opening", false)), "stale_open_cannot_clear_new_opening",
		"The older continuation cannot clear the replacement attempt's opening state")
	_h.expect(not RealtimeService._opening and RealtimeService._socket == null,
		"only_current_open_finishes", "Only the current open attempt finishes; empty credentials never dial a socket")
	RealtimeService.stop()
	AccountManager.state = AccountManager.State.IDLE
	AccountManager.player_id = ""

func _count_path(path: String) -> int:
	var count := 0
	for request in _requests:
		if request.path == path:
			count += 1
	return count

func _backup_files() -> void:
	for base in FILES:
		for suffix in ["", ".bak", ".tmp"]:
			var path: String = "user://" + str(base) + str(suffix)
			_backup[path] = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else null

func _snapshot_realtime() -> void:
	for field in ["state", "player_id", "_access_token", "_token_expires_at", "_refreshing", "_switching_account"]:
		_account_before[field] = AccountManager.get(field)
	for field in ["_want_connection", "_kicked", "_opening", "_open_generation", "state", "_admitted", "queue_position", "_reconnect_timer"]:
		_realtime_before[field] = RealtimeService.get(field)
	_realtime_before["processing"] = RealtimeService.is_processing()
	RealtimeService.set_process(false)

func _finish() -> void:
	_server.stop()
	for connection in _connections:
		(connection.peer as StreamPeerTCP).disconnect_from_host()
	RealtimeService.stop()
	for field in _realtime_before:
		if field != "processing":
			RealtimeService.set(field, _realtime_before[field])
	RealtimeService.set_process(bool(_realtime_before.get("processing", false)))
	for field in _account_before:
		AccountManager.set(field, _account_before[field])
	for path in _backup:
		if _backup[path] == null:
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(path)
		else:
			var file := FileAccess.open(path, FileAccess.WRITE)
			if _h.expect(file != null, "restore_open", "Original user file can be restored"):
				file.store_buffer(_backup[path])
				file = null
				_h.expect(FileAccess.get_file_as_bytes(path) == _backup[path], "restore_bytes", "Original user file restored byte-for-byte")
	_h.finish(get_tree())
