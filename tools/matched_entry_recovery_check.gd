extends Node
const H := preload("res://tools/CheckHarness.gd")
const Menu := preload("res://scenes/menu/MainMenu.gd")

class MenuProbe extends "res://scenes/menu/MainMenu.gd":
	var response: Dictionary = {}
	func _ready() -> void:
		set_process(false)
	func _query_pending_match() -> Dictionary:
		return response

class MainProbe extends "res://scenes/main/Main.gd":
	var connects := 0
	var seats := 0
	var starts := 0
	var menus := 0
	var synchronous := true
	var listener_ready := false
	func _ready() -> void:
		set_process(false)
	func _show_matched_entering() -> void:
		pass
	func _show_menu() -> void:
		menus += 1
	func _watch_matched_start() -> void:
		starts += 1
	func _request_matched_seat() -> void:
		seats += 1
	func _connect_matched_transport() -> bool:
		connects += 1
		listener_ready = NetworkService.session_changed.is_connected(_on_matched_session_changed)
		NetworkService.team_active = true
		NetworkService.state = NetworkService.SessionState.READY if synchronous else NetworkService.SessionState.JOINING
		NetworkService.session_changed.emit()
		return true

func _ready() -> void:
	call_deferred("run")

func run() -> void:
	var h := H.new("matched_entry_recovery")
	NetworkService.set_process(false)
	NetworkService.team_active = false
	NetworkService.team_local_slot = -1
	var main := MainProbe.new()
	add_child(main)
	main._on_match_ready()
	h.expect(main.listener_ready and main.seats == 1, "synchronous_ready", "Bind listener before connection; synchronous READY reaches seat request")
	main._on_match_ready()
	h.expect(main.connects == 1, "duplicate_ready", "HTTP and WS ready do not reset an ongoing connection")
	NetworkService.team_local_slot = 0
	NetworkService.team_lobby_changed.emit()
	h.expect(main.starts == 1 and not main._matched_connect_active, "seat_success", "Successful seating cancels connection watchdog")
	main.queue_free()
	await get_tree().process_frame
	NetworkService.team_active = false
	NetworkService.team_local_slot = -1
	var stalled := MainProbe.new()
	stalled.synchronous = false
	add_child(stalled)
	stalled._on_match_ready()
	for attempt in 2:
		stalled._fail_matched_connect("match_entry_timeout")
		await get_tree().create_timer(1.1).timeout
	h.expect(stalled.connects == 3, "bounded_retry", "Timeout retries at most three total connections")
	stalled._fail_matched_connect("match_entry_timeout")
	h.expect(not stalled._matched_connect_active and stalled.menus == 1, "retry_exhausted", "Exhausted attempts return to a usable menu")
	stalled.queue_free()
	var ready := {"code": 200, "body": {"state": {"state": "ready", "mode": "ranked", "match_uid": "12345678901234567890123456789012"}}}
	h.expect(not Menu.pending_match_from_response(ready).is_empty(), "pending_assignment", "Ready server allocation offers reconnect without a disk seat token")
	for status in ["idle", "queued", "found"]:
		var response: Dictionary = ready.duplicate(true)
		response.body.state.state = status
		h.expect(Menu.pending_match_from_response(response).is_empty(), "not_ready_" + status, "No reconnect action for an unallocated or expired match")
	ready.code = 500
	h.expect(Menu.pending_match_from_response(ready).is_empty(), "query_failure", "Failed background queries do not advertise a stale assignment")
	ready.code = 200
	var menu := MenuProbe.new()
	menu.response = ready
	add_child(menu)
	var button := Button.new()
	button.visible = false
	button.pressed.connect(menu._emit_reconnect)
	menu.add_child(button)
	var selected: Array = []
	menu.pending_match_reconnect_requested.connect(func(mode: String, uid: String) -> void: selected.assign([mode, uid]))
	var player_before := AccountManager.player_id
	AccountManager.player_id = "fixture-player"
	menu._refresh_saved_match()
	await get_tree().process_frame
	h.expect(button.visible and selected.is_empty(), "silent_query", "Background discovery only reveals the button; no automatic connection")
	button.pressed.emit()
	h.expect(selected.size() == 2 and selected[0] == "ranked", "click_to_recover", "Player click requests recovery of the discovered match")
	AccountManager.player_id = "different-player"
	menu._apply_saved_match_status("clear", "")
	h.expect(not button.visible, "account_changed", "A result for a previous account cannot offer reconnect")
	AccountManager.player_id = player_before
	menu.queue_free()
	NetworkService.team_active = false
	h.finish(get_tree())
