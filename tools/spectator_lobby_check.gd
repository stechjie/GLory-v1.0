extends Node

# 门禁：观战大厅界面（协议 44，2026-10-22）。真图在 tools/spectator_lobby_capture。
#
#   * 观战列表在用户圈的位置（左侧，语音键上方），行数跟服务器给的一致；
#   * 只有房主有 X 和「关闭 / 开启观战」—— 非房主有这两样等于误导（服务器会丢掉请求）；
#   * 观战者看到的是同一个房间：自己没有座位（_my_slot = -1，不能被当成红队 0 号），
#     右下角「观战中」且按不动；
#   * 房间列表：观战行接在可加入的房间后面，观战席满了的那行点不了。
#   * 好友列表：好友在对局里给「观战」（不给「加入」，必被拒）；在大厅给「加入」；不在房间都不给。

const Harness := preload("res://tools/CheckHarness.gd")
const LobbyScene := preload("res://scenes/menu/Team3v3Lobby.tscn")
const MainMenuScene := preload("res://scenes/menu/MainMenu.tscn")

var h := Harness.new("spectator_lobby")
var _saved := {}
const KEYS := ["team_active", "team_room_id", "team_slot_states", "team_ready", "team_leader_slot",
	"team_local_slot", "team_seat_profiles", "team_room_spectators", "spectating",
	"spectate_room_id", "spectate_sid", "spectate_state"]


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	NetworkService.set_process(false)
	for key in KEYS:
		_saved[key] = NetworkService.get(key)
	await _case_host()
	await _case_player()
	await _case_spectator()
	await _case_room_list()
	await _case_friend_rows()
	for key in _saved:
		NetworkService.set(key, _saved[key])
	h.finish(get_tree())


func _list(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append({"sid": i + 1, "guest": i % 2 == 1, "identity": {} if i % 2 == 1 else {"player_name": "S%d" % i}})
	return out


func _setup(my_slot: int, spectator: bool, open: bool = true) -> void:
	var states := ["player", "empty", "dummy", "player", "empty", "empty"]
	NetworkService.team_active = true
	NetworkService.team_room_id = 251537
	NetworkService.team_slot_states = states.duplicate()
	NetworkService.team_ready = [false, false, true, true, false, false]
	NetworkService.team_leader_slot = 0
	NetworkService.team_local_slot = my_slot
	NetworkService.team_seat_profiles = {}
	NetworkService.team_room_spectators = {"spectators": _list(7), "spectate_open": open, "spectate_max": 10}
	NetworkService.spectating = spectator
	NetworkService.spectate_room_id = 251537 if spectator else 0
	NetworkService.spectate_sid = 2 if spectator else -1
	NetworkService.spectate_state = {} if not spectator else {"phase": "lobby", "slot_states": states.duplicate(),
		"ready": [false, false, true, true, false, false], "leader_slot": 0, "seat_profiles": {},
		"spectators": _list(7), "spectate_open": open, "spectate_max": 10, "my_sid": 2, "can_chat": true}


func _open_lobby() -> Control:
	var lobby: Control = LobbyScene.instantiate()
	add_child(lobby)
	await get_tree().process_frame
	lobby._refresh()
	await get_tree().process_frame
	return lobby


func _kick_count(panel: Node) -> int:
	var n := 0
	for row in panel._rows.get_children():
		if row.get_node_or_null("kick") != null:
			n += 1
	return n


func _case_host() -> void:
	_setup(0, false)
	var lobby := await _open_lobby()
	var panel: Control = lobby._spectator_panel
	h.expect(panel != null and panel.visible, "panel_missing", "联机房间里要有观战列表")
	if panel == null:
		lobby.queue_free()
		return
	h.expect(panel.row_count() == 7, "row_count", "观战列表行数应与服务器给的一致（7），实际 %d" % panel.row_count())
	h.expect(_kick_count(panel) == 7 and panel._toggle.visible, "host_controls_missing", "房主每行要有 X，并有「关闭观战」")
	# 位置：用户圈的那块 —— 左侧、在语音键（y=636）上方、不压到 A/1 号座位（x=447）。
	var placed: Dictionary = {}
	for item in lobby._placed:
		if item.node == panel:
			placed = item
	var pos: Vector2 = placed.get("pos", Vector2(-1, -1))
	var size: Vector2 = placed.get("size", Vector2.ZERO)
	h.expect(str(placed.get("edge", "")) == "left" and pos.x < 120 and pos.x + size.x <= 447
		and pos.y + size.y <= 636, "panel_misplaced", "观战列表要在左侧红框：不压座位、不压语音键（%s %s）" % [pos, size])
	lobby.queue_free()
	await get_tree().process_frame


func _case_player() -> void:
	_setup(3, false)
	var lobby := await _open_lobby()
	var panel: Control = lobby._spectator_panel
	h.expect(_kick_count(panel) == 0 and not panel._toggle.visible, "non_host_controls",
		"非房主不该有 X 和「关闭观战」")
	lobby.queue_free()
	await get_tree().process_frame


func _case_spectator() -> void:
	_setup(-1, true)
	# 上一个房间留下的座位号（真实会出现）：观战界面绝不能读它，否则会被当成红队 0 号。
	NetworkService.team_local_slot = 0
	var lobby := await _open_lobby()
	h.expect(lobby._my_slot() == -1, "spectator_has_seat", "观战者没有座位（_my_slot 必须是 -1，不能落回红队 0 号）")
	h.expect(lobby._start_btn.disabled and lobby._start_lbl.text == lobby._room_text("观战中", "Spectating"),
		"spectator_start_enabled", "观战者右下角应是「观战中」且按不动")
	var panel: Control = lobby._spectator_panel
	h.expect(panel.row_count() == 7 and _kick_count(panel) == 0, "spectator_list", "观战者能看到列表、但没有 X")
	var me_marked := false
	for row in panel._rows.get_children():
		var label := row.get_node_or_null("name") as Label
		me_marked = me_marked or (label != null and label.text.ends_with(lobby._room_text("（我）", " (Me)")))
	h.expect(me_marked, "spectator_me_missing", "观战者在列表里应能认出自己（我）")
	var x_visible := false
	for btn in lobby._slot_x_btns + lobby._slot_ai_btns:
		x_visible = x_visible or (btn as Control).visible
	h.expect(not x_visible, "spectator_seat_controls", "观战者不该看到座位上的 X / ±AI")
	lobby.queue_free()
	await get_tree().process_frame


func _case_room_list() -> void:
	NetworkService.team_active = false
	NetworkService.spectating = false
	var menu: Control = MainMenuScene.instantiate()
	add_child(menu)
	await get_tree().process_frame
	var panel: Control = menu._build_room_panel()
	add_child(panel)
	menu.show_room_list([{"id": 102345, "players": 2, "max": 6}])
	menu.show_spectate_rooms([{"id": 251537, "players": 6, "max": 6, "spectators": 3},
		{"id": 377001, "players": 4, "max": 6, "spectators": 10}])
	var box: VBoxContainer = menu._room_list_box
	var ok_row := box.get_node_or_null("spectate_row_251537") as Button
	var full_row := box.get_node_or_null("spectate_row_377001") as Button
	h.expect(box.get_child_count() == 3 and ok_row != null and full_row != null, "spectate_rows_missing",
		"观战行要接在可加入的房间后面（共 3 行）")
	if ok_row != null and full_row != null:
		h.expect(not ok_row.disabled and full_row.disabled, "full_spectate_clickable", "观战席满了的房间那行应点不了")
	panel.queue_free()
	menu.queue_free()
	await get_tree().process_frame


func _find(node: Node, name: String) -> Node:
	for child in node.find_children(name, "", true, false):
		return child
	return null


func _case_friend_rows() -> void:
	var screen: Control = load("res://scenes/menu/FriendsScreen.tscn").instantiate()
	add_child(screen)
	await get_tree().process_frame
	var watching: Control = screen._friend_row({"friend_code": "WATCH001", "player_name": "打着呢", "online": true,
		"room_id": 251537, "in_match": true})
	var lobby: Control = screen._friend_row({"friend_code": "LOBBY001", "player_name": "等人中", "online": true,
		"room_id": 102345, "in_match": false})
	var idle: Control = screen._friend_row({"friend_code": "IDLE0001", "player_name": "闲着", "online": true})
	h.expect(_find(watching, "spectate") != null and _find(watching, "join") == null, "in_match_friend_no_watch",
		"好友在对局里：要有「观战」、不要「加入」（加入必被拒 room_started）")
	h.expect(_find(lobby, "join") != null and _find(lobby, "spectate") == null, "lobby_friend_wrong_button",
		"好友在房间大厅：照旧给「加入」")
	h.expect(_find(idle, "join") == null and _find(idle, "spectate") == null, "idle_friend_has_button",
		"好友不在任何房间：两个都不给")
	var got := [0]
	screen.spectate_room_requested.connect(func(rid: int) -> void: got[0] = rid)
	var btn := _find(watching, "spectate") as Button
	if btn != null:
		btn.pressed.emit()
	h.expect(got[0] == 251537, "watch_wrong_room", "点「观战」要带上好友所在的房间号")
	for row in [watching, lobby, idle]:
		row.queue_free()
	screen.queue_free()
	await get_tree().process_frame
