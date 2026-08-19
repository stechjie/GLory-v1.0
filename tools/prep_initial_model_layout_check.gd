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
	var board_projected := camera.unproject_position(board_model.global_position)
	var bench_projected := camera.unproject_position(bench_model.global_position)
	var viewport_rect := Rect2(Vector2.ZERO, Vector2(river_viewport.size))
	assert(viewport_rect.has_point(board_projected))
	assert(viewport_rect.has_point(bench_projected))
	assert(board_projected.distance_to(bench_projected) > 24.0)
	# Both preparation consumers now use the same production actor contract.
	for actor in [board_model, bench_model]:
		for required in ["ActorRoot", "FootAnchor", "HeadAnchor", "CastAnchor", "HitAnchor", "Shadow"]:
			assert(actor.get_node_or_null(required) != null)
	var capture_path := OS.get_environment("PREP_INITIAL_LAYOUT_CAPTURE_PATH")
	if not capture_path.is_empty():
		var image := get_viewport().get_texture().get_image()
		assert(image != null)
		assert(image.save_png(capture_path) == OK)
	print("PREP_INITIAL_MODEL_LAYOUT_OK board=%s bench=%s separation=%.3f" % [
		str(board_projected),
		str(bench_projected),
		board_projected.distance_to(bench_projected),
	])
	get_tree().quit()
