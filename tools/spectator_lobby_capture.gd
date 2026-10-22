extends Node

# 观战大厅的真图截图（协议 44，2026-10-22）。
#
# 门禁（tools/spectator_check）管规则对不对，回答不了「观战栏放在红框那里好不好看」。
# 这里按**生产代码**渲染几种视角，交给人眼对用户圈的位置：
#   host      房主：观战列表 + 每行 X + 「关闭观战」
#   player    普通选手：只有列表
#   spectator 观战者：同一个房间界面，右下角「观战中」，列表里自己带（我）
#   closed    房主关了观战
#   room_list 自定房间面板里接在后面的「观战」行
#   friends   好友列表：对局中的好友是「观战」，大厅里的好友是「加入」
#
# 必须**不带** --headless（dummy 渲染后端抓出来是空图）：
#   godot --path . res://tools/spectator_lobby_capture.tscn
# 输出：reports/spectator/*.png

const LobbyScene := preload("res://scenes/menu/Team3v3Lobby.tscn")
const MainMenuScene := preload("res://scenes/menu/MainMenu.tscn")
const MainMenuScript := preload("res://scenes/menu/MainMenu.gd")

const OUT_DIR := "res://reports/spectator"
const VIEWPORT_SIZE := Vector2i(1600, 900)
const SETTLE_FRAMES := 12

var _shots := 0
var _saved := {}


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("spectator_lobby_capture 需要真实渲染后端，请去掉 --headless")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	get_window().size = VIEWPORT_SIZE
	NetworkService.set_process(false)
	_save_state()
	LocaleManager.set_locale("zh")
	await _capture_lobby("host", false, 0, true)
	await _capture_lobby("player", false, 3, true)
	await _capture_lobby("spectator", true, -1, true)
	await _capture_lobby("closed", false, 0, false)
	await _capture_room_list()
	await _capture_friends()
	_restore_state()
	print("SPECTATOR_CAPTURE shots=%d dir=%s" % [_shots, OUT_DIR])
	get_tree().quit(0)


func _spectators(count: int) -> Array:
	var names := ["小红帽", "Archer_Lee", "", "风行者", "", "MoonWatcher", "老王观战中"]
	var out: Array = []
	for i in count:
		var name := str(names[i % names.size()])
		out.append({"sid": i + 1, "guest": name.is_empty(),
			"identity": {} if name.is_empty() else {"player_name": name, "friend_code": "AB%06d" % i}})
	return out


func _capture_lobby(tag: String, spectator: bool, my_slot: int, open: bool) -> void:
	var states := ["player", "empty", "dummy", "player", "empty", "empty"]
	var profiles := {0: {"player_name": "房主大人", "friend_code": "HOST0001"},
		3: {"player_name": "蓝队一号", "friend_code": "BLUE0001"}}
	var list := _spectators(7 if open else 0)
	NetworkService.team_active = true
	NetworkService.team_room_id = 251537
	NetworkService.team_slot_states = states.duplicate()
	NetworkService.team_ready = [false, false, true, true, false, false]
	NetworkService.team_leader_slot = 0
	NetworkService.team_local_slot = my_slot
	NetworkService.team_seat_profiles = profiles.duplicate(true)
	NetworkService.team_room_spectators = {"spectators": list, "spectate_open": open, "spectate_max": 10}
	NetworkService.spectating = spectator
	NetworkService.spectate_room_id = 251537 if spectator else 0
	NetworkService.spectate_sid = 4 if spectator else -1
	NetworkService.spectate_state = {} if not spectator else {
		"phase": "lobby", "slot_states": states.duplicate(), "ready": [false, false, true, true, false, false],
		"leader_slot": 0, "seat_profiles": profiles.duplicate(true), "spectators": list,
		"spectate_open": open, "spectate_max": 10, "my_sid": 4, "can_chat": true,
	}
	var lobby: Control = LobbyScene.instantiate()
	add_child(lobby)
	await _settle(SETTLE_FRAMES)
	lobby._refresh()
	await _settle(4)
	_shoot("lobby_" + tag)
	lobby.queue_free()
	await _settle(2)


func _capture_room_list() -> void:
	NetworkService.team_active = false
	NetworkService.spectating = false
	var menu: MainMenuScript = MainMenuScene.instantiate()
	add_child(menu)
	await _settle(SETTLE_FRAMES)
	var panel: Control = menu._build_room_panel()
	ModalStack.push(panel, {"id": MainMenuScript.ROOM_MODAL_ID, "owner": menu,
		"priority": MainMenuScript.ROOM_MODAL_PRIORITY, "dismiss_on_backdrop": true})
	await _settle(SETTLE_FRAMES)
	menu.show_room_list([{"id": 102345, "players": 2, "max": 6}])
	menu.show_spectate_rooms([{"id": 251537, "players": 6, "max": 6, "state": "prep", "spectators": 3},
		{"id": 377001, "players": 4, "max": 6, "state": "battle", "spectators": 10}])
	await _settle(6)
	_shoot("room_list")
	ModalStack.pop(MainMenuScript.ROOM_MODAL_ID)
	menu.queue_free()
	await _settle(2)


func _shoot(name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name]
	img.save_png(ProjectSettings.globalize_path(path))
	_shots += 1
	print("shot ", path)


func _settle(frames: int) -> void:
	for _i in frames:
		await get_tree().process_frame


func _save_state() -> void:
	for key in ["team_active", "team_room_id", "team_slot_states", "team_ready", "team_leader_slot",
			"team_local_slot", "team_seat_profiles", "team_room_spectators", "spectating",
			"spectate_room_id", "spectate_sid", "spectate_state"]:
		_saved[key] = NetworkService.get(key)


func _restore_state() -> void:
	for key in _saved:
		NetworkService.set(key, _saved[key])


func _capture_friends() -> void:
	var screen: Control = load("res://scenes/menu/FriendsScreen.tscn").instantiate()
	add_child(screen)
	await _settle(SETTLE_FRAMES)
	screen._friends = [
		{"friend_code": "WATCH001", "player_name": "正在打排位", "online": true, "room_id": 251537, "in_match": true},
		{"friend_code": "LOBBY001", "player_name": "房间里等人", "online": true, "room_id": 102345, "in_match": false},
		{"friend_code": "IDLE0001", "player_name": "在主界面", "online": true},
		{"friend_code": "OFFL0001", "player_name": "已下线", "online": false},
	]
	screen._render()
	await _settle(8)
	_shoot("friends")
	screen.queue_free()
	await _settle(2)
