extends SceneTree

const OUTPUT_DIR := "C:/Users/Leno/Documents/Glory prep screen/vfx_reference_rebuild_checks"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
	change_scene_to_file("res://scenes/debug/ModelBattlePreview.tscn")
	for _frame in range(30):
		await process_frame
	var preview := current_scene
	preview.set("auto_fight_enabled", false)
	var selector: OptionButton = preview.get("vfx_select")
	var entries := [
		{"id": 22, "name": "energy_burst", "shots": [{"suffix": "01_start", "time": 0.07}, {"suffix": "02_peak", "time": 0.31}, {"suffix": "03_decay", "time": 0.62}]},
		{"id": 23, "name": "ground_explosion", "shots": [{"suffix": "01_start", "time": 0.08}, {"suffix": "02_peak", "time": 0.34}, {"suffix": "03_residue", "time": 0.72}]},
		{"id": 24, "name": "teleport_pillar", "shots": [{"suffix": "01_pool", "time": 0.08}, {"suffix": "02_pillar", "time": 0.38}, {"suffix": "03_fade", "time": 1.18}]},
	]
	for entry in entries:
		for shot in entry.shots:
			preview.call("_clear_vfx_preview")
			await create_timer(0.08).timeout
			selector.select(int(entry.id))
			preview.call("_on_vfx_play_pressed")
			await _capture_after(preview, "%s_%s.png" % [str(entry.name), str(shot.suffix)], float(shot.time))
	preview.call("_clear_vfx_preview")
	quit()

func _capture_after(preview: Node, file_name: String, delay: float) -> void:
	await create_timer(delay).timeout
	await RenderingServer.frame_post_draw
	var image := preview.get_viewport().get_texture().get_image()
	var error := image.save_png(OUTPUT_DIR.path_join(file_name))
	if error != OK:
		push_error("Phase 3 VFX capture failed: %s (%d)" % [file_name, error])
