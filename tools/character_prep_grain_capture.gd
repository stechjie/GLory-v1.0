extends Node

# Run only in a disposable project with application/config/use_custom_user_dir
# and custom_user_dir_name="glory-grain-capture-<label>" in override.cfg.
# GLORY_GRAIN_CAPTURE_DIR is the output folder; GLORY_GRAIN_CAPTURE_LABEL is
# "baseline" or "fixed". No saved run is loaded into this fixture.
# Add -- --compare-msaa to capture the same frozen pose at 0x and 2x as well.
const UNIT_PLACEMENTS := [
	{"id": "human_archer", "zone": "board", "slot": 9},
	{"id": "dark_fear", "zone": "board", "slot": 2},
	{"id": "human_swordsman", "zone": "bench", "slot": 3},
	{"id": "dark_queen", "zone": "bench", "slot": 5},
]


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var output := OS.get_environment("GLORY_GRAIN_CAPTURE_DIR")
	if not OS.get_user_data_dir().contains("glory-grain-capture-") or output.is_empty():
		push_error("Capture requires an isolated glory-grain-capture-* user directory and GLORY_GRAIN_CAPTURE_DIR.")
		get_tree().quit(1)
		return
	if DisplayServer.get_name() == "headless":
		push_error("This capture requires a real renderer.")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	get_window().size = Vector2i(1600, 720)
	seed(20260913)
	GameState.reset_run()
	GameState.round_index = 7
	GameState.gold = 1043
	GameState.player_formation_hp = 49
	GameState.enemy_formation_hp = 15
	GameState.carrots = 12
	GameState.last_harvest_round = 7
	VFXManager.set_quality_tier(VFXQualityBudget.Tier.HIGH)
	var definitions := {}
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	for unit in units:
		definitions[str(unit.get("id", ""))] = unit
	for placement in UNIT_PLACEMENTS:
		var definition: Dictionary = definitions[str(placement.id)].duplicate(true)
		var cell := {"uid": "grain_" + str(placement.id), "id": str(placement.id), "star": 1, "def": definition}
		if placement.zone == "board":
			GameState.board_slots[int(placement.slot)] = cell
		else:
			GameState.bench_slots[int(placement.slot)] = cell
	for i in GameState.shop_offers.size():
		GameState.shop_offers[i] = definitions[str(UNIT_PLACEMENTS[i % UNIT_PLACEMENTS.size()].id)].duplicate(true)
	var prep := (load("res://scenes/prep/PrepScreen.tscn") as PackedScene).instantiate()
	add_child(prep)
	for frame in 25:
		await get_tree().process_frame
	var poses := []
	for models in [prep.get("_prep_board_model_nodes"), prep.get("_prep_standby_model_nodes")]:
		for actor in (models as Dictionary).values():
			var visual := (actor as Node).get("visual_root") as Node3D
			if visual != null and visual.has_method("play_idle"):
				visual.call("play_idle")
				var constants: Dictionary = visual.get_script().get_script_constant_map()
				var starts: Dictionary = constants.get("ACTION_START_FRAMES", {})
				var start_sec := float(starts.get("idle", 0.0)) / float(constants.get("ANIMATION_SOURCE_FPS", 30.0))
				var proxy := visual.get_node_or_null("AnimationPlayer") as AnimationPlayer
				if proxy != null:
					proxy.seek(0.0, true)
				var players: Variant = visual.get("action_players")
				if players is Dictionary:
					var player := players.get("idle") as AnimationPlayer
					if player != null:
						player.seek(start_sec, true)
						player.advance(0.001)
						poses.append({"wrapper": visual.get_script().resource_path,
							"animation": player.current_animation, "position_sec": player.current_animation_position})
	# Freeze immediately after each wrapper selected its own configured idle start
	# (e.g. the original queen starts at 7 s). Internal and proxy players stop
	# processing together; no re-skinning or camera changes are introduced here.
	prep.process_mode = Node.PROCESS_MODE_DISABLED
	var viewport := prep.get("_prep_river_viewport") as SubViewport
	var container := viewport.get_parent() as SubViewportContainer
	var label := OS.get_environment("GLORY_GRAIN_CAPTURE_LABEL")
	if label.is_empty():
		label = "capture"
	var metadata := {"window_px": str(get_window().size), "viewport_px": str(viewport.size),
		"container_size": str(container.size), "stretch_shrink": container.stretch_shrink,
		"scaling_3d_scale": viewport.scaling_3d_scale, "msaa_3d": viewport.msaa_3d,
		"quality_tier": VFXManager.get_quality_tier(), "round": GameState.round_index,
		"gold": GameState.gold, "poses": poses, "placements": UNIT_PLACEMENTS}
	print("CHARACTER_PREP_CAPTURE ", JSON.stringify(metadata))
	var file := FileAccess.open(output.path_join(label + "_prep_metadata.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(metadata, "\t") + "\n")
	await _capture(prep, viewport, output.path_join(label + "_prep"))
	if OS.get_cmdline_user_args().has("--compare-msaa"):
		for setting in [Viewport.MSAA_DISABLED, Viewport.MSAA_2X]:
			viewport.msaa_3d = setting
			await _capture(prep, viewport, output.path_join(label + "_prep_msaa%d" % (2 if setting == Viewport.MSAA_2X else 0)))
	prep.queue_free()
	for frame in 3:
		await get_tree().process_frame
	get_tree().quit()


func _capture(prep: Node, viewport: SubViewport, path: String) -> void:
	for frame in 4:
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	var screenshot := prep.get_viewport().get_texture().get_image()
	assert(screenshot != null and not screenshot.is_empty())
	assert(screenshot.save_png(path + "_1600x720.png") == OK)
	screenshot.resize(800, 360, Image.INTERPOLATE_LANCZOS)
	assert(screenshot.save_png(path + "_800x360.png") == OK)
	print("CHARACTER_PREP_IMAGE ", path)
