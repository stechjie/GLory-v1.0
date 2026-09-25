extends Node

# A single, unseated real NetworkService client. No account/login/card, create,
# join, resume, ready, board or match RPC is invoked by this probe.
const TLS := preload("res://scripts/multiplayer/NetTLS.gd")
const Cert := preload("res://scripts/multiplayer/NetTLSCert.gd")
const CONNECT_TIMEOUT_SEC := 25.0
const LIST_TIMEOUT_SEC := 8.0
const HOLD_SEC := 30.0

var _done := false
var _connected_at := 0.0
var _connect_deadline := 0.0
var _list_requested := false
var _rooms_seen := -1
var _last_observed_pong := 0.0
var _last_observed_ping := 0
var _pong_count := 0
var _ping_count := 0
var _max_pong_gap := 0.0
var _host := ""
var _port := 0

func _ready() -> void:
	Engine.max_fps = 60
	_host = _arg("--probe-host")
	_port = int(_arg("--probe-port"))
	var expected_dir := _arg("--probe-user-dir")
	if expected_dir.is_empty() or OS.get_user_data_dir() != expected_dir \
			or not expected_dir.get_file().begins_with("GloryLiveReadOnly-"):
		_finish(false, "independent_user_dir_required")
		return
	if not _host.is_valid_ip_address() or _port <= 0 or _port > 65535:
		_finish(false, "explicit_ip_and_port_required")
		return
	if NetworkConfig.NETWORK_PROTOCOL_VERSION != 32 or not NetworkConfig.USE_DTLS or TLS.pinned_cert() == null:
		_finish(false, "production_protocol32_dtls_pin_required")
		return
	if not _unseated() or AccountManager.is_logged_in() \
			or FileAccess.file_exists(SaveManager.ACCOUNT_PATH) \
			or FileAccess.file_exists(SaveManager.RECONNECT_PATH) \
			or FileAccess.file_exists(SaveManager.PUBLIC_TOKEN_PATH) \
			or FileAccess.file_exists("user://device_harness.json"):
		_finish(false, "fresh_accountless_state_required")
		return
	print("LIVE_READONLY_CONFIGURATION " + JSON.stringify({"host": _host, "port": _port,
		"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION, "dtls": NetworkConfig.USE_DTLS,
		"certificate_pem_sha256": str(Cert.PEM).sha256_text(), "user_data_dir": OS.get_user_data_dir(),
		"hold_seconds": HOLD_SEC, "room_requests": 1, "heartbeat_interval_seconds": NetworkService.HEARTBEAT_INTERVAL_SEC}))
	if _arg("--probe-dry-run") == "1":
		print("LIVE_READONLY_PREPARED {\"connected\":false,\"network_attempted\":false}")
		get_tree().quit(0)
		return
	if _arg("--probe-arm") != "readonly":
		_finish(false, "explicit_readonly_arm_required")
		return
	NetworkService.team_room_list_received.connect(_on_room_list)
	_connect_deadline = _now() + CONNECT_TIMEOUT_SEC
	if not NetworkService.team_join(_host, _port):
		_finish(false, "connect_setup_failed")
		return
	# team_join resets the previous session synchronously before entering JOINING.
	# Subscribe after setup so that initial OFFLINE reset is not a disconnect.
	NetworkService.session_changed.connect(_on_session_changed)
	_on_session_changed()

func _process(_delta: float) -> void:
	if _done or _connect_deadline == 0.0:
		return
	if not _unseated() or AccountManager.is_logged_in():
		_finish(false, "unexpected_seat_or_account")
		return
	var now := _now()
	if _connected_at == 0.0:
		if now >= _connect_deadline:
			_finish(false, "handshake_timeout")
		return
	if NetworkService.state != NetworkService.SessionState.READY:
		_finish(false, "session_not_ready")
		return
	if not _list_requested:
		_list_requested = true
		NetworkService.team_request_room_list()
	if _rooms_seen < 0 and now - _connected_at >= LIST_TIMEOUT_SEC:
		_finish(false, "room_list_not_received")
		return
	var ping_at := int(NetworkService._ping_sent_at)
	if ping_at > 0 and ping_at != _last_observed_ping:
		_last_observed_ping = ping_at
		_ping_count += 1
	var pong_at := float(NetworkService._last_pong_at)
	if pong_at > _last_observed_pong:
		_max_pong_gap = maxf(_max_pong_gap, pong_at - _last_observed_pong)
		_last_observed_pong = pong_at
		_pong_count += 1
	if now - _connected_at >= HOLD_SEC:
		var silence := now - _last_observed_pong
		_max_pong_gap = maxf(_max_pong_gap, silence)
		var healthy := _rooms_seen >= 0 and _pong_count >= 3 \
			and silence < 2.0 * NetworkService.HEARTBEAT_INTERVAL_SEC + 1.0 \
			and _max_pong_gap < NetworkService.HEARTBEAT_TIMEOUT_SEC
		_finish(healthy, "completed" if healthy else "heartbeat_or_list_missing")

func _on_session_changed() -> void:
	if _done:
		return
	if NetworkService.state == NetworkService.SessionState.READY:
		if _connected_at == 0.0:
			_connected_at = _now()
			_last_observed_pong = float(NetworkService._last_pong_at)
	elif NetworkService.state in [NetworkService.SessionState.FAILED, NetworkService.SessionState.OFFLINE, NetworkService.SessionState.RECONNECTING]:
		_finish(false, "session_failed_or_disconnected")

func _on_room_list(rooms: Array) -> void:
	_rooms_seen = rooms.size() # A zero-sized response is valid; no response is -1.

func _unseated() -> bool:
	return NetworkService.team_room_id == 0 and NetworkService.team_local_slot == -1 \
		and str(NetworkService.session_token).is_empty() \
		and str(NetworkService.pending_abandon_token).is_empty() \
		and str(NetworkService._pending_leave_id).is_empty()

func _finish(ok: bool, reason: String) -> void:
	if _done:
		return
	_done = true
	set_process(false)
	# Network callbacks execute inside ENet poll. Close only after that returns.
	_close_and_report.call_deferred(ok, reason)

func _close_and_report(ok: bool, reason: String) -> void:
	var report := {"passed": ok, "reason": reason, "host": _host, "port": _port,
		"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION, "dtls": NetworkConfig.USE_DTLS,
		"user_data_dir": OS.get_user_data_dir(), "connected": _connected_at > 0.0,
		"connected_seconds": _now() - _connected_at if _connected_at > 0.0 else 0.0,
		"public_room_count": _rooms_seen, "list_requested": _list_requested,
		"observed_pings": _ping_count, "observed_pongs": _pong_count,
		"max_pong_gap_seconds": _max_pong_gap, "unseated": _unseated(),
		"account_logged_in": AccountManager.is_logged_in(), "error": str(NetworkService.last_error)}
	NetworkService.reset() # Transport close only; no leave/resume/account RPC.
	report.transport_closed = multiplayer.multiplayer_peer == null
	print("LIVE_READONLY_RESULT " + JSON.stringify(report))
	get_tree().quit(0 if ok else 3)

func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0

func _arg(key: String) -> String:
	for arg in OS.get_cmdline_user_args():
		if str(arg).begins_with(key + "="):
			return str(arg).substr(key.length() + 1)
	return ""
