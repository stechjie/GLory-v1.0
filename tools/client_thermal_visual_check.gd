extends Node

const ViewBudget := preload("res://ui/components/Budgeted3DView.gd")
const PrepFlow := preload("res://scenes/prep/PrepFlowController.gd")
const PrepController := preload("res://scenes/prep/PrepBoardController.gd")
const PrepScene := preload("res://scenes/prep/PrepScreen.tscn")

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred("_capture")

func _capture() -> void:
	var destination := OS.get_environment("THERMAL_VISUAL_OUTPUT")
	if destination.is_empty():
		push_error("THERMAL_VISUAL_OUTPUT must name a capture directory")
		get_tree().quit(1)
		return
	VFXManager.set_quality_tier(VFXQualityBudget.Tier.MEDIUM)
	GameState.reset_run()
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	for i in mini(8, units.size()):
		var definition: Dictionary = units[i]
		GameState.board_slots[i] = {"id": definition.get("id", "unit"), "star": 1, "def": definition}
	var prep = PrepScene.instantiate()
	if prep.get_script() == null:
		push_error("Preparation scene did not load its script")
		get_tree().quit(1)
		return
	prep.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(prep)
	for i in 20:
		await get_tree().process_frame
	get_tree().paused = true
	var viewport: SubViewport = prep._prep_river_viewport
	var layer := viewport.get_parent() as Control
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var full_size := viewport.size
	var full := get_viewport().get_texture().get_image()
	assert(full.save_png(destination.path_join("prep_full.png")) == OK)
	ViewBudget._resize(layer, viewport, Vector2i(1280, 720), false)
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var limited := get_viewport().get_texture().get_image()
	assert(limited.save_png(destination.path_join("prep_balanced.png")) == OK)
	print("THERMAL_VISUAL_OK full=%s balanced=%s ui=%s" % [full_size, viewport.size, full.get_size()])
	get_tree().paused = false
	prep.queue_free()
	await get_tree().process_frame
	get_tree().quit()
