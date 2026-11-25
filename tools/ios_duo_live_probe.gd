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
	"nickname": "res://scenes/menu/NicknameSetupScreen.tscn",
	"prep": "res://scenes/prep/PrepScreen.tscn",
	"battle": "res://scenes/battle/BattleScreen.tscn",
	"boot": "res://scenes/bootstrap/Bootstrap.tscn",
}
var _page: Control
var _page_name := ""
var _elapsed := 0.0
var _last := ""
var _seq := 0

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
	if FileAccess.file_exists(CONTROL):
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONTROL))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CONTROL))
		if data is Dictionary:
			if data.has("page"):
				_switch(str(data.page))
			if data.get("capture", false):
				_last = ""
	_capture("poll")

func _switch(page: String) -> void:
	if is_instance_valid(_page):
		_page.queue_free()
		_page = null
	# Switching pages is an explicit QA action; fold/resize never calls this.
	_page_name = page
	if page == "chat":
		var script := load("res://ui/components/ChatInputBar.gd")
		_page = script.new() as Control
		_page.present(self, func(value: String):
			_write({"event": "local_submit", "text": value})
			return ""
		)
	elif PAGES.has(page):
		if page in ["prep", "battle"]:
			GameState.reset_run()
			GameState.team_mode = false
		_page = (load(PAGES[page]) as PackedScene).instantiate() as Control
		if page == "boot":
			_page.set("auto_start", false)
			_page.set("entry_gate", false)
		add_child(_page)
		_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	else:
		_write({"event": "unknown_page", "page": page})
		return
	_last = ""
	_write({"event": "page", "page": page, "node": _page.get_instance_id()})

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_write({"event": "touch", "pressed": event.pressed, "canceled": event.canceled,
			"index": event.index, "position": str(event.position)})

func _capture(reason: String) -> void:
	var fields: Array[Dictionary] = []
	var todo: Array[Node] = [get_tree().root]
	while not todo.is_empty():
		var node: Node = todo.pop_back()
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
