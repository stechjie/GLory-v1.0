extends Node
## Persistent protocol consumer; full snapshots heal missed pushes and reconnects.

const Runtime = preload("res://patcher/HotfixRuntime.gd")
var _runtime: Node
var _http: HTTPRequest
var _boot: Dictionary
var _sequence := 0
var _revision := -1
var _seen_revision := -1
var _deployment := ""
var _pending := false
var _busy := false
var _blocked := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_boot = JSON.parse_string(FileAccess.get_file_as_string("res://patcher/boot.json"))
	_runtime = Runtime.new()
	add_child(_runtime)
	_http = HTTPRequest.new()
	_http.timeout = 20
	_http.body_size_limit = 2 * 1024 * 1024
	add_child(_http)
	var snapshot: Dictionary = ProjectSettings.get_meta("glory_patch_snapshot", {})
	_sequence = int(snapshot.get("required_patch_seq", 0))
	_apply(snapshot)
	var realtime := get_tree().root.get_node_or_null("RealtimeService")
	if realtime != null:
		realtime.connect("message_received", _message)
		realtime.connect("connection_changed", _connection)
	var timer := Timer.new()
	timer.wait_time = 30
	timer.autostart = true
	timer.timeout.connect(refresh)
	add_child(timer)
	refresh()


func _message(payload: Dictionary) -> void:
	if payload.get("t") == "patch_catalogue_changed":
		refresh()
	elif payload.get("t") == "patch_hotfix_snapshot" and payload.get("channel") == _boot.channel:
		var snapshot := payload.duplicate(true)
		snapshot["base_id"] = _boot.base_id
		snapshot["platform"] = _boot.platform
		snapshot["action"] = "none" if int(snapshot.get("required_patch_seq", -1)) == _sequence else "download"
		_apply(snapshot)


func _connection(state: int) -> void:
	if state == 2: # RealtimeService.State.ONLINE
		refresh()


func refresh() -> void:
	if _blocked:
		return
	if _busy:
		_pending = true
		return
	_busy = true
	var url := str(_boot.backend_url) + "/v1/patches/check?channel=%s&platform=%s&base_id=%s&installed_seq=%d" % [
		str(_boot.channel).uri_encode(), str(_boot.platform).uri_encode(), str(_boot.base_id).uri_encode(), _sequence]
	if _http.request(url) == OK:
		var response: Array = await _http.request_completed
		if response[0] == HTTPRequest.RESULT_SUCCESS and response[1] == 200:
			var parsed = JSON.parse_string(response[3].get_string_from_utf8())
			if parsed is Dictionary:
				_apply(parsed)
	_busy = false
	if _pending:
		_pending = false
		refresh.call_deferred()


func _apply(snapshot: Dictionary) -> void:
	if _blocked:
		return
	if (snapshot.get("protocol") != 1 or snapshot.get("channel") != _boot.channel
		or snapshot.get("base_id") != _boot.base_id or snapshot.get("platform") != _boot.platform):
		return
	var revision := int(snapshot.get("revision", -1))
	if revision <= _revision or revision < _seen_revision:
		return
	if str(snapshot.get("deployment_id", "")).is_empty():
		return
	# Fence delayed HTTP replies even when applying this new revision fails.
	# Equal revisions may retry; lower revisions must never restore an old epoch.
	_seen_revision = revision
	var deployment := str(snapshot.deployment_id) + ":" + str(snapshot.get("hotfix_epoch", 0))
	if deployment != _deployment:
		_runtime.clear()
		_deployment = deployment
	if snapshot.get("action") != "none" or int(snapshot.get("required_patch_seq", -1)) != _sequence:
		_runtime.clear()
		_block_for_patch()
		return
	var items = snapshot.get("hotfixes", [])
	if not items is Array:
		return
	if _runtime.replace(items):
		_revision = revision
		ProjectSettings.set_meta("glory_patch_snapshot", snapshot)


func _block_for_patch() -> void:
	if _blocked:
		return
	_blocked = true
	get_tree().paused = true
	var layer := CanvasLayer.new()
	layer.layer = 1000
	add_child(layer)
	var shade := ColorRect.new()
	shade.color = Color("101923")
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.add_child(center)
	var message := Label.new()
	if ResourceLoader.exists("res://patcher/LauncherFont.otf"):
		message.add_theme_font_override("font", load("res://patcher/LauncherFont.otf"))
	message.text = "新的远征已经准备就绪\n请重新启动游戏，完成更新后继续。"
	message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message.add_theme_font_size_override("font_size", 28)
	center.add_child(message)
