extends SceneTree

var out_dir := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join("output/perf_20261113_live/asset_audit/ready_orbit/")
var rows: Array = []

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--fixture-dir" and i + 1 < args.size():
			out_dir = args[i + 1].trim_suffix("/") + "/"
	call_deferred("_run")

func _build(script_path: String) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(640, 180)
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var background := ColorRect.new()
	background.color = Color(0.035, 0.055, 0.03)
	background.size = Vector2(viewport.size)
	viewport.add_child(background)
	var holder := Control.new()
	holder.position = Vector2(202, 66)
	holder.size = Vector2(236, 48)
	viewport.add_child(holder)
	var effect = load(script_path).new()
	effect.size = holder.size
	holder.add_child(effect)
	effect.set_mode(1)
	effect.set_process(false)
	var button := ColorRect.new()
	button.color = Color(0.18, 0.105, 0.035)
	button.size = holder.size
	holder.add_child(button)
	return {"viewport": viewport, "effect": effect}

func _run() -> void:
	var before := _build(out_dir + "baseline_lifecycle.gd")
	var after := _build(out_dir + "cached_lifecycle.gd")
	for preset in [{"name": "ready", "phase": 0.0, "loading": 0.0, "opacity": 1.0}, {"name": "transition", "phase": 0.37, "loading": 0.4, "opacity": 0.45}, {"name": "loading", "phase": 3.3, "loading": 1.0, "opacity": 1.0}]:
		for entry in [before, after]:
			var effect: Control = entry.effect
			effect.set("_mode", 1 if preset.loading == 0.0 else 2)
			effect.set("_phase", preset.phase)
			effect.set("_elapsed", 2.35)
			effect.set("_loading", preset.loading)
			effect.set("_opacity", preset.opacity)
			effect.call("_redraw")
		for frame in 4:
			await process_frame
		await RenderingServer.frame_post_draw
		var image_before: Image = before.viewport.get_texture().get_image()
		var image_after: Image = after.viewport.get_texture().get_image()
		image_before.convert(Image.FORMAT_RGBA8)
		image_after.convert(Image.FORMAT_RGBA8)
		var a := image_before.get_data()
		var b := image_after.get_data()
		var varied := false
		for i in range(4, a.size(), 4):
			if a[i] != a[0] or a[i + 1] != a[1] or a[i + 2] != a[2] or a[i + 3] != a[3]:
				varied = true
				break
		var different_pixels := 0
		var maximum_channel_delta := 0
		for i in range(0, a.size(), 4):
			var differs := false
			for channel in 4:
				var delta := absi(int(a[i + channel]) - int(b[i + channel]))
				maximum_channel_delta = maxi(maximum_channel_delta, delta)
				differs = differs or delta != 0
			if differs:
				different_pixels += 1
		image_before.save_png(out_dir + preset.name + "_baseline.png")
		image_after.save_png(out_dir + preset.name + "_cached.png")
		rows.append({"case": preset.name, "dimensions": [image_before.get_width(), image_before.get_height()], "nonuniform_render": varied, "pixel_equal": a == b, "different_pixels": different_pixels, "maximum_channel_delta_8bit": maximum_channel_delta})
	var ok := true
	for row in rows:
		ok = ok and row.nonuniform_render and row.pixel_equal
	FileAccess.open(out_dir + "ready_orbit_pixel_check.json", FileAccess.WRITE).store_string(JSON.stringify({"cases": rows, "renderer": RenderingServer.get_current_rendering_driver_name(), "pass": ok}, "\t"))
	print("READY_ORBIT_PIXEL_CHECK ", JSON.stringify(rows))
	before.viewport.queue_free()
	after.viewport.queue_free()
	await process_frame
	quit(0 if ok else 1)
