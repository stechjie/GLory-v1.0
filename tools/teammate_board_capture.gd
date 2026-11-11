extends SceneTree

# 「查看棋盘」真渲染回归（2026-11-07）：自己的棋盘 → 点队友 → 看到队友的棋子 → 回到自己的棋盘。
# 要带渲染跑（不能 --headless）：
#   godot --path . -s tools/teammate_board_capture.gd
# 截图在 reports/teammate_board/（不进仓库）。
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
	print("[teammate_board] %s %s" % ["PASS" if ok else "FAIL", message])


func _settle() -> void:
	for i in 45:
		await process_frame
	await RenderingServer.frame_post_draw


func _cell(state: Object, unit_id: String, star: int, uid: String) -> Dictionary:
	var registry = root.get_node("DataRegistry")
	var definition: Dictionary = registry.canonical_unit_def(unit_id).duplicate(true)
	return {"id": unit_id, "uid": uid, "star": star, "def": definition, "is_mercenary": false}


# 左栏（羁绊 / 宝藏）里所有字拼起来。
func _left_panel_text(prep: Node) -> String:
	var panel: Node = prep.get("_synergy")._left_panel
	var parts: Array[String] = []
	for label in panel.find_children("*", "Label", true, false):
		if not (label as Node).is_queued_for_deletion():
			parts.append((label as Label).text)
	return " | ".join(parts)


func _run() -> void:
	var state = root.get_node("GameState")
	var network = root.get_node("NetworkService")
	root.get_node("DataRegistry").load_all()
	state.reset_run()
	state.tutorial_mode = false
	state.round_index = 7
	network.team_active = true
	network.is_host = false
	network.team_local_slot = 0
	network.team_slot_states = ["player", "player", "dummy", "player", "dummy", "dummy"]
	network.team_seat_profiles = {1: {"player_name": "队友甲", "friend_code": "BBBB2222"}}
	network.server_phase = network.ROOM_PREP
	# 自己：两只人族近战。
	state.board_slots[1] = _cell(state, "human_militia", 2, "me_1")
	state.board_slots[2] = _cell(state, "human_swordsman", 1, "me_2")
	var own_before: Array = state.board_slots.duplicate(true)
	var prep = load("res://scenes/prep/PrepScreen.tscn").instantiate()
	root.add_child(prep)
	var out := ProjectSettings.globalize_path("res://reports/teammate_board")
	DirAccess.make_dir_recursive_absolute(out)
	DisplayServer.window_set_size(Vector2i(1600, 720))
	await _settle()
	root.get_texture().get_image().save_png(out.path_join("1_own.png"))
	var own_models := (prep.get("_prep_board_model_nodes") as Dictionary).size()
	_check(own_models == 2, "own board shows 2 models (got %d)" % own_models)

	# 队友：服务器转来的那一份（这里直接塞进 NetworkService，和 _rpc_team_prep_board 收到之后一样）。
	var board: Array = []
	board.resize(16)
	board[0] = _cell(state, "dark_imp", 3, "t_1")
	board[5] = _cell(state, "dark_queen", 2, "t_2")
	board[13] = _cell(state, "dark_mage", 2, "t_3")
	board[14] = _cell(state, "dark_dragon", 1, "t_4")
	var bench: Array = []
	bench.resize(state.BENCH_SLOTS)
	bench[0] = _cell(state, "dark_fear", 1, "t_5")
	network.team_prep_boards[1] = {"round": 7, "board": board, "bench": bench, "mercenaries": [],
		"treasures": ["atk_fury_roster", "money_compound"]}
	prep.enter_teammate_view(1)
	await _settle()
	root.get_texture().get_image().save_png(out.path_join("2_teammate.png"))
	var banner: Control = prep.find_child("TeammateViewBanner", true, false)
	_check(banner != null and banner.visible, "banner visible")
	_check(prep.find_child("TeammateViewShield", true, false) != null, "input shield present")
	var shown := (prep.get("_prep_board_model_nodes") as Dictionary).size()
	_check(shown == 4, "teammate board shows 4 models (got %d)" % shown)
	_check(var_to_bytes(state.board_slots) == var_to_bytes(own_before), "own GameState untouched while viewing")
	# 左上角羁绊栏：数的是队友的（暗 4），自己的人族和出售提示不在。
	var synergy_text := _left_panel_text(prep)
	_check(synergy_text.contains("4/") and not synergy_text.contains("2/"), "left panel counts teammate races (%s)" % synergy_text)
	_check(not synergy_text.contains(TranslationServer.translate("ui_sell_hint")), "own sell hint hidden while viewing")
	var back: Button = banner.find_child("Back", true, false) if banner != null else null
	_check(back != null, "back button exists")
	if back != null:
		back.pressed.emit()
	await _settle()
	root.get_texture().get_image().save_png(out.path_join("3_back.png"))
	_check(prep.find_child("TeammateViewBanner", true, false) == null or not is_instance_valid(banner) or banner.is_queued_for_deletion(), "banner gone after back")
	var back_models := (prep.get("_prep_board_model_nodes") as Dictionary).size()
	_check(back_models == 2, "own board restored (got %d models)" % back_models)
	var own_text := _left_panel_text(prep)
	_check(own_text.contains("2/") and not own_text.contains("4/"), "left panel back to own races (%s)" % own_text)
	# 对手的座位不能看。
	prep.enter_teammate_view(3)
	await process_frame
	_check(not prep.viewing_teammate(), "opponent board cannot be viewed")
	print("[teammate_board] failures=%d screenshots=%s" % [failures, out])
	quit(1 if failures > 0 else 0)
