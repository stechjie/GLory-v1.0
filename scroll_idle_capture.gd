extends SceneTree

const OUTPUT_DIR := "C:/Users/Leno/Documents/Glory prep screen/river_scroll_work/captures"


func _initialize() -> void:
	call_deferred("_capture_sequence")


func _capture_sequence() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if packed == null:
		push_error("Unable to load PrepScreen.tscn")
		quit(1)
		return
	var prep := packed.instantiate()
	root.add_child(prep)
	await process_frame
	await process_frame
	await create_timer(0.15).timeout
	await _save_frame("scroll_idle_start.png")
	await create_timer(0.72).timeout
	await _save_frame("scroll_idle_body.png")
	await create_timer(0.72).timeout
	await _save_frame("scroll_idle_late.png")
	quit()


func _save_frame(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var error := image.save_png(OUTPUT_DIR.path_join(file_name))
	if error != OK:
		push_error("Unable to save %s: %s" % [file_name, error_string(error)])
