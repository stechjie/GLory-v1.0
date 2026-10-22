extends Node

# 观战对局内的真图（第三步，2026-10-22）：
#   loading      第 1 回合等待页（宠物跑进度条）+ 右上角 6 头像
#   prep_red     备战只读：看红队 A 座上一回合的阵容
#   prep_blue    切到蓝队 1 号座
#
# 按生产代码渲染：Main 的 _spectate_show_* 那几步（SpectatorSeat.apply + PrepScreen.spectator_view）。
# 必须**不带** --headless：
#   godot --path . res://tools/spectator_match_capture.tscn
# 输出：reports/spectator/match_*.png

const PrepScene := preload("res://scenes/prep/PrepScreen.tscn")
const SpectatorSeat := preload("res://scripts/multiplayer/SpectatorSeat.gd")
const SpectatorHud := preload("res://ui/components/SpectatorHud.gd")
const SpectatorLoading := preload("res://scenes/spectate/SpectatorLoading.gd")

const OUT_DIR := "res://reports/spectator"
const VIEWPORT_SIZE := Vector2i(1600, 900)

var _saved := {}
const KEYS := ["team_active", "spectating", "spectate_state", "spectate_view", "spectate_view_slot",
	"team_local_slot", "team_slot_states", "team_seat_profiles", "team_room_id"]


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("spectator_match_capture 需要真实渲染后端，请去掉 --headless")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	get_window().size = VIEWPORT_SIZE
	NetworkService.set_process(false)
	for key in KEYS:
		_saved[key] = NetworkService.get(key)
	var saved_game := {"board": GameState.board_slots.duplicate(true), "bench": GameState.bench_slots.duplicate(true),
		"mercs": GameState.mercenary_slots.duplicate(true), "gold": GameState.gold, "round": GameState.round_index,
		"team_mode": GameState.team_mode}
	LocaleManager.set_locale("zh")
	_setup_state()
	await _shot_loading()
	await _shot_prep(0, "prep_red")
	await _shot_prep(3, "prep_blue")
	for key in _saved:
		NetworkService.set(key, _saved[key])
	GameState.board_slots = saved_game.board
	GameState.bench_slots = saved_game.bench
	GameState.mercenary_slots = saved_game.mercs
	GameState.gold = saved_game.gold
	GameState.round_index = saved_game.round
	GameState.team_mode = saved_game.team_mode
	print("SPECTATOR_MATCH_CAPTURE dir=%s" % OUT_DIR)
	get_tree().quit(0)


func _units(n: int, offset: int) -> Array:
	var rows: Array = DataRegistry.get_table("race_units").get("units", [])
	var out: Array = []
	for i in n:
		var row: Dictionary = rows[(i * 3 + offset) % rows.size()]
		out.append({"id": str(row.get("id", "")), "uid": "cap-%d-%d" % [offset, i], "star": 1 + (i % 3)})
	return out


func _setup_state() -> void:
	var states := ["player", "player", "dummy", "player", "dummy", "player"]
	var profiles := {0: {"player_name": "红队队长"}, 1: {"player_name": "Archer_Lee"},
		3: {"player_name": "蓝队一号"}, 5: {"player_name": "MoonWatcher"}}
	var red_board := []
	red_board.resize(GameConstants.CELL_COUNT)
	var blue_board := []
	blue_board.resize(GameConstants.CELL_COUNT)
	var red_units := _units(6, 0)
	var blue_units := _units(6, 5)
	for i in 6:
		red_board[[0, 1, 5, 6, 9, 13][i]] = red_units[i]
		blue_board[[2, 3, 6, 7, 10, 14][i]] = blue_units[i]
	var view := {"round": 4, "battle_id": "251537:4:9", "seats": {
		0: {"board": red_board, "bench": _units(3, 11), "mercenaries": [], "treasures": [], "gold": 23, "is_ai": false},
		3: {"board": blue_board, "bench": _units(2, 17), "mercenaries": [], "treasures": [], "gold": 9, "is_ai": false},
	}}
	NetworkService.team_active = true
	NetworkService.spectating = true
	NetworkService.team_room_id = 251537
	NetworkService.spectate_view = view
	NetworkService.spectate_state = {"phase": "prep", "round_id": 5, "battle_round": 4, "final_round": 21,
		"prep_seconds_left": 21.0, "slot_states": states, "seat_profiles": profiles, "leader_slot": 0,
		"team_hp": [38, 27], "spectators": [], "spectate_open": true, "spectate_max": 10, "my_sid": 1}
	NetworkService.team_slot_states = states
	NetworkService.team_seat_profiles = profiles


func _hud(slot: int) -> CanvasLayer:
	NetworkService.spectate_select_slot(slot)
	var hud: CanvasLayer = SpectatorHud.new()
	add_child(hud)
	return hud


func _shot_loading() -> void:
	var loading: Control = SpectatorLoading.new()
	loading.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(loading)
	var hud := _hud(0)
	await _settle(30)
	_save("match_loading")
	loading.queue_free()
	hud.queue_free()
	await _settle(2)


func _shot_prep(slot: int, name: String) -> void:
	NetworkService.spectate_select_slot(slot)
	SpectatorSeat.apply(NetworkService.spectate_view, NetworkService.spectate_state, slot)
	var prep: Control = PrepScene.instantiate()
	prep.spectator_view = true
	add_child(prep)
	var hud := _hud(slot)
	await _settle(90)
	_save("match_" + name)
	prep.queue_free()
	hud.queue_free()
	await _settle(4)


func _save(name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, name]))
	print("shot ", name)


func _settle(frames: int) -> void:
	for _i in frames:
		await get_tree().process_frame
