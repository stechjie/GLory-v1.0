extends Node

const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")

func _ready() -> void:
	GameState.reset_run()
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	assert(packed != null)
	var prep := packed.instantiate()
	add_child(prep)
	await get_tree().process_frame
	await get_tree().process_frame
	assert(GameState.board_slots.size() == GameConstants.CELL_COUNT)
	assert(GameConstants.BOARD_ROWS == 4)
	assert(GameConstants.BOARD_COLUMNS == 4)
	var buttons: Array = prep.get("_board_buttons")
	assert(buttons.size() == GameConstants.CELL_COUNT)
	var standby_buttons: Array = prep.get("_bench_buttons")
	assert(standby_buttons.size() == GameState.BENCH_SLOTS)
	for standby_button in standby_buttons:
		assert((standby_button as Control).has_method("_has_point"))
	assert(not prep.call("_can_drop_on_board", -1, {"kind": "bench", "index": 0}))
	assert(not prep.call("_can_drop_on_board", GameConstants.CELL_COUNT, {"kind": "bench", "index": 0}))
	for index in GameConstants.CELL_COUNT:
		assert(prep.call("_can_drop_on_board", index, {"kind": "bench", "index": 0}))
	var legacy_board: Array = []
	legacy_board.resize(25)
	legacy_board.fill(null)
	legacy_board[0] = {"id": "legacy_first", "star": 1, "def": {"id": "legacy_first"}}
	legacy_board[24] = {"id": "legacy_last", "star": 1, "def": {"id": "legacy_last"}}
	var migrated: Array = SaveManager.call("_normalize_board_slots", legacy_board)
	assert(migrated.size() == GameConstants.CELL_COUNT)
	assert(migrated.filter(func(cell): return cell != null).size() == 2)
	var network_migrated := NetProtocol.sanitize_board(legacy_board)
	assert(network_migrated.size() == GameConstants.CELL_COUNT)
	assert(network_migrated.filter(func(cell): return cell != null).size() == 2)
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	assert(not units.is_empty())
	var first_def: Dictionary = units[0].duplicate(true)
	for index in GameState.BENCH_SLOTS:
		GameState.bench_slots[index] = {
			"id": first_def.get("id", "unit"),
			"star": 1,
			"def": first_def.duplicate(true),
		}
	for index in GameConstants.CELL_COUNT:
		GameState.board_slots[index] = {
			"id": first_def.get("id", "unit"),
			"star": 1,
			"def": first_def.duplicate(true),
		}
	prep.call("_refresh_board")
	prep.call("_refresh_bench")
	await get_tree().process_frame
	var fighters := BattleSim.build_player_fighters("pve")
	assert(fighters.size() == GameConstants.CELL_COUNT)
	var positions: Dictionary = {}
	for fighter in fighters:
		positions[str(Vector2(fighter.pos))] = true
	assert(positions.size() == GameConstants.CELL_COUNT)
	var first_button := buttons[0] as Control
	var last_button := buttons[GameConstants.CELL_COUNT - 1] as Control
	assert(first_button.size.x > 0.0 and first_button.size.y > 0.0)
	assert(last_button.size.x > 0.0 and last_button.size.y > 0.0)
	GameState.board_slots.fill(null)
	prep.call("_refresh_board")
	prep.call("_on_drag_started", {"kind": "board", "index": 0})
	prep.call("_set_standby_drop_hover", 5)
	assert(bool(prep.get("_standby_drop_highlight_active")))
	assert(int(prep.get("_standby_drop_hover_index")) == 5)
	for button in buttons:
		assert((button as Control).has_method("_has_point"))
	prep.call("_on_drag_started", {"kind": "bench", "index": 0})
	prep.call("_set_board_drop_hover", 10)
	assert(bool(prep.get("_board_drop_highlight_active")))
	assert(int(prep.get("_board_drop_hover_index")) == 10)
	var capture_path := OS.get_environment("BOARD_4X4_CAPTURE_PATH")
	if not capture_path.is_empty():
		for _frame in 20:
			await get_tree().process_frame
		var image := get_viewport().get_texture().get_image()
		assert(image.save_png(capture_path) == OK)
	print("BOARD_4X4_SMOKE_OK cells=%d unique_positions=%d first=%s last=%s" % [
		buttons.size(),
		positions.size(),
		str(fighters[0].pos),
		str(fighters[GameConstants.CELL_COUNT - 1].pos),
	])
	get_tree().quit()
