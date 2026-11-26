extends Node
# Explicit QA entry only. A fresh Simulator bundle owns its local data.
# No network chat callback is connected; text submissions are recorded locally.
# External capture driver writes {"page":"chat"} to user://duo-control.json.
const CONTROL := "user://duo-control.json"
const LOG := "user://duo-live-log.jsonl"
const PAGES := {
	"menu": "res://scenes/menu/MainMenu.tscn",
	"lobby": "res://scenes/menu/Team3v3Lobby.tscn",
	"party": "res://scenes/menu/PartyLobby.tscn",
	"profile": "res://scenes/menu/ProfileScreen.tscn",
	"nickname": "res://scenes/menu/NicknameSetupScreen.gd",
	"prep": "res://scenes/prep/PrepScreen.tscn",
	"battle": "res://scenes/battle/BattleScreen.tscn",
	"boot": "res://scenes/bootstrap/Bootstrap.tscn",
}
var _page: Control
var _page_name := ""
var _elapsed := 0.0
var _last := ""
var _seq := 0
var _page_loading := false
var _page_generation := 0

func _ready() -> void:
	var f := FileAccess.open(LOG, FileAccess.WRITE)
	if f != null:
		f.close()
	_switch("menu")

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < 0.25:
		return
	_elapsed = 0.0
	var capture_reason := "poll"
	if FileAccess.file_exists(CONTROL):
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONTROL))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CONTROL))
		if data is Dictionary:
			if data.has("page"):
				_switch(str(data.page))
			if data.get("capture", false):
				_last = ""
				capture_reason = "explicit"
	_capture(capture_reason)

func _page_error(page: String, path: String, reason: String, actual_type := "") -> void:
	_write({"event": "page_load_failed", "page": page, "path": path,
		"reason": reason, "actual_type": actual_type, "current_page": _page_name})

func _instantiate_control(page: String, path: String) -> Control:
	if not ResourceLoader.exists(path):
		_page_error(page, path, "resource_missing")
		return null
	var resource: Resource = load(path)
	if resource == null:
		_page_error(page, path, "resource_load_failed")
		return null
	var instance: Variant = null
	if resource is PackedScene:
		instance = resource.instantiate()
	elif resource is Script:
		if not resource.can_instantiate():
			_page_error(page, path, "script_cannot_instantiate", resource.get_class())
			return null
		var base_type: String = resource.get_instance_base_type()
		if base_type != "Control" and not ClassDB.is_parent_class(base_type, "Control"):
			_page_error(page, path, "script_base_is_not_control", base_type)
			return null
		instance = resource.new()
	else:
		_page_error(page, path, "expected_scene_or_script", resource.get_class())
		return null
	if not instance is Control:
		var actual_type: String = instance.get_class() if instance is Object else type_string(typeof(instance))
		_page_error(page, path, "instance_is_not_control", actual_type)
		if instance is Node:
			instance.free()
		return null
	return instance as Control

func _switch(page: String) -> void:
	var path := ""
	if page == "chat":
		path = "res://ui/components/ChatInputBar.gd"
	elif PAGES.has(page):
		path = str(PAGES[page])
	else:
		_write({"event": "unknown_page", "page": page})
		return
	if page in ["prep", "battle"]:
		GameState.reset_run()
		GameState.team_mode = false
	var candidate := _instantiate_control(page, path)
	if candidate == null:
		return
	if page == "chat" and not candidate.has_method("present"):
		_page_error(page, path, "chat_present_method_missing", candidate.get_class())
		candidate.free()
		return
	if is_instance_valid(_page):
		_page.hide()
		_page.queue_free()
	# Switching pages is an explicit QA action; fold/resize never calls this.
	_page_generation += 1
	_page_loading = true
	_page_name = page
	_page = candidate
	if page == "chat":
		_page.present(self, func(value: String):
			_write({"event": "local_submit", "text": value})
			return ""
		)
	else:
		if page == "boot":
			_page.set("auto_start", false)
			_page.set("entry_gate", false)
		add_child(_page)
		_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_last = ""
	_write({"event": "page_loading", "page": page,
		"node": _page.get_instance_id(), "switch_id": _page_generation})
	_finish_page_switch.call_deferred(_page_generation)

func _finish_page_switch(generation: int) -> void:
	# queue_free and deferred Control/container layout must finish before capture.
	# This is process readiness; the driver also waits for two new rendered frames.
	await get_tree().process_frame
	await get_tree().process_frame
	if generation != _page_generation:
		return
	_page_loading = false
	if not is_instance_valid(_page) or _page.is_queued_for_deletion():
		_page_error(_page_name, "", "page_disappeared_before_ready")
		return
	_write({"event": "page", "page": _page_name, "state": "ready",
		"node": _page.get_instance_id(), "switch_id": generation,
		"frames_drawn": Engine.get_frames_drawn(),
		"process_frames": Engine.get_process_frames()})
	_capture("page_ready")

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_write({"event": "touch", "pressed": event.pressed, "canceled": event.canceled,
			"index": event.index, "position": str(event.position)})

func _capture(reason: String) -> void:
	if _page_loading:
		return
	var fields: Array[Dictionary] = []
	var todo: Array[Node] = [get_tree().root]
	while not todo.is_empty():
		var node: Node = todo.pop_back()
		if node.is_queued_for_deletion():
			continue
		if node is LineEdit and node.is_visible_in_tree():
			fields.append({"id": node.get_instance_id(), "name": str(node.name),
				"text": node.text, "caret": node.caret_column,
				"selection": [node.get_selection_from_column(), node.get_selection_to_column()],
				"focus": node.has_focus(), "ime": node.has_ime_text(),
				"rect": str(node.get_global_rect())})
		for child in node.get_children():
			todo.append(child)
	var data := {"event": "snapshot", "page": _page_name,
		"page_node": _page.get_instance_id() if is_instance_valid(_page) else 0,
		"switch_id": _page_generation, "page_ready": is_instance_valid(_page) and not _page.is_queued_for_deletion(),
		"window_px": str(DisplayServer.window_get_size()),
		"viewport": str(get_viewport().get_visible_rect()),
		"native_safe_px": str(DisplayServer.get_display_safe_area()),
		"safe": str(SafeArea.rect()),
		"keyboard_px": DisplayServer.virtual_keyboard_get_height(),
		"fields": fields}
	var encoded := JSON.stringify(data)
	if encoded != _last:
		_last = encoded
		data["reason"] = reason
		# Frame counters are added after deduplication, not compared on every poll.
		data["frames_drawn"] = Engine.get_frames_drawn()
		data["process_frames"] = Engine.get_process_frames()
		_write(data)

func _write(data: Dictionary) -> void:
	_seq += 1
	data["seq"] = _seq
	data["ticks_ms"] = Time.get_ticks_msec()
	var encoded := JSON.stringify(data)
	var f := FileAccess.open(LOG, FileAccess.READ_WRITE)
	if f != null:
		f.seek_end()
		f.store_line(encoded)
	print("[GLORY_DUO_LIVE] ", encoded)
