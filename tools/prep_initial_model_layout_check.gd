extends Node

func _ready() -> void:
	GameState.reset_run()
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	assert(units.size() >= 2)
	var board_def: Dictionary = (units[0] as Dictionary).duplicate(true)
	var bench_def: Dictionary = (units[1] as Dictionary).duplicate(true)
	GameState.board_slots[0] = {
		"id": board_def.get("id", "unit"),
		"star": 1,
		"def": board_def,
	}
	GameState.bench_slots[1] = {
		"id": bench_def.get("id", "unit"),
		"star": 1,
		"def": bench_def,
	}
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	assert(packed != null)
	var prep := packed.instantiate()
	add_child(prep)
	await get_tree().process_frame
	var board_root := prep.get("_prep_model_root") as Node3D
	var bench_root := prep.get("_prep_standby_model_root") as Node3D
	assert(board_root != null and bench_root != null)
	assert(not board_root.visible and not bench_root.visible)
	for _frame in 4:
		await get_tree().process_frame
	assert(board_root.visible and bench_root.visible)
	var board_model := (prep.get("_prep_board_model_nodes") as Dictionary).get(0) as Node3D
	var bench_model := (prep.get("_prep_standby_model_nodes") as Dictionary).get(1) as Node3D
	assert(board_model != null and bench_model != null)
	var camera := prep.get("_prep_river_camera") as Camera3D
	var river_viewport := prep.get("_prep_river_viewport") as SubViewport
	var main_size := prep.get_viewport().get_visible_rect().size
	var board_frame := prep.get("_prep_board_frame") as Control
	var board_quad: PackedVector2Array = prep.call("_board_cell_quad", 0, board_frame.size)
	var board_target_main := (board_quad[0] + board_quad[1] + board_quad[2] + board_quad[3]) * 0.25 + board_frame.global_position
	var board_target_river := Vector2(
		board_target_main.x / main_size.x * float(river_viewport.size.x),
		board_target_main.y / main_size.y * float(river_viewport.size.y)
	)
	var bench_frame := prep.get("_standby_frame") as Control
	var bench_quad: PackedVector2Array = prep.call("_standby_cell_quad", 1, bench_frame.size)
	var bench_target_main := (bench_quad[0] + bench_quad[1] + bench_quad[2] + bench_quad[3]) * 0.25 + bench_frame.global_position
	var bench_target_river := Vector2(
		bench_target_main.x / main_size.x * float(river_viewport.size.x),
		bench_target_main.y / main_size.y * float(river_viewport.size.y)
	)
	var board_error := camera.unproject_position(board_model.global_position).distance_to(board_target_river)
	var bench_error := camera.unproject_position(bench_model.global_position).distance_to(bench_target_river)
	assert(board_error <= 0.5)
	assert(bench_error <= 0.5)
	var capture_path := OS.get_environment("PREP_INITIAL_LAYOUT_CAPTURE_PATH")
	if not capture_path.is_empty():
		var image := get_viewport().get_texture().get_image()
		assert(image != null)
		assert(image.save_png(capture_path) == OK)
	print("PREP_INITIAL_MODEL_LAYOUT_OK board_error=%.3f bench_error=%.3f" % [
		board_error,
		bench_error,
	])
	get_tree().quit()
