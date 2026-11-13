extends SceneTree

var out_dir := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join("output/perf_20261113_live/asset_audit/ready_orbit/")
var assertions := 0
var failures: Array[String] = []
var compared_commands := 0
var compared_cases := 0
var lifecycle_result := {}
var benchmark_result := {}
var cache_result := {}

class RecordingLayer extends Control:
	var commands: Array = []
	var record := true
	func capture_line(a: Vector2, b: Vector2, color: Color, width := -1.0, aa := false) -> void:
		if record: commands.append(["line", a, b, color, width, aa])
	func capture_circle(center: Vector2, radius: float, color: Color, filled := true, width := -1.0, aa := false) -> void:
		if record: commands.append(["circle", center, radius, color, filled, width, aa])
	func capture_colored_polygon(points: PackedVector2Array, color: Color) -> void:
		if record: commands.append(["polygon", points.duplicate(), color])
	func capture_polyline(points: PackedVector2Array, color: Color, width := -1.0, aa := false) -> void:
		if record: commands.append(["polyline", points.duplicate(), color, width, aa])
	func capture_set_transform(offset: Vector2, rotation := 0.0, scale_value := Vector2.ONE) -> void:
		if record: commands.append(["transform", offset, rotation, scale_value])
	func capture_texture_rect(texture: Texture2D, rect: Rect2, tile: bool, color := Color.WHITE) -> void:
		if record: commands.append(["texture", texture.resource_path, rect, tile, color])

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--fixture-dir" and i + 1 < args.size():
			out_dir = args[i + 1].trim_suffix("/") + "/"
	call_deferred("_run")

func _expect(ok: bool, message: String) -> void:
	assertions += 1
	if not ok:
		failures.append(message)

func _configure(effect: Control, dimensions: Vector2, phase: float, loading: float, opacity: float) -> void:
	effect.size = dimensions
	effect.set("_mode", 1 if loading == 0.0 else 2)
	effect.set("_phase", phase)
	effect.set("_elapsed", 2.35)
	effect.set("_loading", loading)
	effect.set("_opacity", opacity)

func _paint(effect: Control, sink: RecordingLayer) -> void:
	for layer in [[false, false], [false, true], [true, false], [true, true]]:
		effect.call("paint_layer", sink, layer[0], layer[1])

func _run() -> void:
	var before_script := load(out_dir + "baseline_recording.gd") as Script
	var after_script := load(out_dir + "cached_recording.gd") as Script
	_expect(before_script != null and after_script != null, "recording fixtures must load")
	if before_script == null or after_script == null:
		_finish()
		return
	var before = before_script.new()
	var after = after_script.new()
	var sink_before := RecordingLayer.new()
	var sink_after := RecordingLayer.new()
	for dimensions in [Vector2(236, 48), Vector2(472, 96), Vector2(310, 82)]:
		for phase in [0.0, 0.37, 1.2, 3.3, 5.8]:
			for loading in [0.0, 0.4, 1.0]:
				for opacity in [0.0, 0.45, 1.0]:
					_configure(before, dimensions, phase, loading, opacity)
					_configure(after, dimensions, phase, loading, opacity)
					sink_before.commands.clear()
					sink_after.commands.clear()
					_paint(before, sink_before)
					_paint(after, sink_after)
					compared_cases += 1
					compared_commands += sink_before.commands.size()
					_expect(sink_before.commands == sink_after.commands,
						"ordered native draw arguments differ at size=%s phase=%.2f loading=%.2f opacity=%.2f" % [dimensions, phase, loading, opacity])
	# Cache membership must keep 64 segments, 32 in each front/back half.
	_expect((after.get("_front_segments") as PackedInt32Array).size() == 32, "front keeps all 32 segments")
	_expect((after.get("_rear_segments") as PackedInt32Array).size() == 32, "rear keeps all 32 segments")
	_expect((after.get("_orbit_points") as PackedVector2Array).size() == 130, "two complete 65-endpoint rails retained")
	_expect((after_script.get_script_constant_map().SEGMENTS as int) == 64, "segment count unchanged")
	_expect(is_equal_approx(float(after_script.get_script_constant_map().FRAME_STEP), 1.0 / 30.0), "update cadence remains 30Hz")
	var geometry_before := int(after.get("_test_geometry_rebuilds"))
	var colors_before := int(after.get("_test_color_rebuilds"))
	_configure(after, Vector2(236, 48), 0.7, 0.0, 0.8)
	_paint(after, sink_after)
	_expect(int(after.get("_test_geometry_rebuilds")) == geometry_before + 1, "four layers share one geometry rebuild on resize")
	_expect(int(after.get("_test_color_rebuilds")) == colors_before + 1, "four layers share one color rebuild for the same phase")
	geometry_before = int(after.get("_test_geometry_rebuilds"))
	colors_before = int(after.get("_test_color_rebuilds"))
	_paint(after, sink_after)
	_expect(int(after.get("_test_geometry_rebuilds")) == geometry_before and int(after.get("_test_color_rebuilds")) == colors_before,
		"repainting the same state reuses both caches")
	_configure(after, Vector2(472, 96), 0.7, 0.6, 0.8)
	_paint(after, sink_after)
	_expect(int(after.get("_test_geometry_rebuilds")) == geometry_before + 1 and int(after.get("_test_color_rebuilds")) == colors_before,
		"resize rebuilds geometry while loading width change keeps color cache")
	_configure(after, Vector2(472, 96), 0.8, 0.6, 0.8)
	_paint(after, sink_after)
	_expect(int(after.get("_test_color_rebuilds")) == colors_before + 1, "phase change refreshes shared colors")
	cache_result = {"geometry_rebuilds_per_four_layers_on_resize": 1, "color_rebuilds_per_four_layers_on_phase_change": 1, "same_state_rebuilds": 0}

	# Same mock sink on both sides isolates script-side arithmetic, not GLES work.
	sink_before.record = false
	sink_after.record = false
	var timings_before: Array[int] = []
	var timings_after: Array[int] = []
	for pass_index in 5:
		for pair in [[before, sink_before, timings_before], [after, sink_after, timings_after]]:
			var started := Time.get_ticks_usec()
			for tick in 100:
				_configure(pair[0], Vector2(236, 48), fposmod(float(tick) * 0.034, TAU), 0.6, 1.0)
				_paint(pair[0], pair[1])
			(pair[2] as Array[int]).append(Time.get_ticks_usec() - started)
	timings_before.sort()
	timings_after.sort()
	benchmark_result = {"scope": "100 four-layer paints per run, mock no-op draw sink; script arithmetic/dispatch only, not iPhone/GLES/energy", "runs": 5, "baseline_median_usec": timings_before[2], "cached_median_usec": timings_after[2]}
	before.free()
	after.free()
	sink_before.free()
	sink_after.free()
	await _check_lifecycle()
	_finish()

func _check_lifecycle() -> void:
	var holder := Control.new()
	root.add_child(holder)
	var old = load(out_dir + "baseline_lifecycle.gd").new()
	var current = load(out_dir + "cached_lifecycle.gd").new()
	for effect in [old, current]:
		effect.size = Vector2(236, 48)
		holder.add_child(effect)
		effect.set_mode(1)
		effect.set_process(false)
	await process_frame
	for effect in [old, current]:
		_configure(effect, Vector2(236, 48), 0.7, 0.2, 0.5)
		# Keep ready rather than loading so state convergence can be compared.
		effect.set("_mode", 1)
	holder.hide()
	var old_start := int(old.get("_test_redraw_batches"))
	var current_start := int(current.get("_test_redraw_batches"))
	for i in 12:
		old.call("_process", 1.0 / 30.0)
		current.call("_process", 1.0 / 30.0)
	_expect(int(current.get("_test_redraw_batches")) == current_start, "hidden effect must not request redraw batches")
	_expect(int(old.get("_test_redraw_batches")) > old_start, "baseline fixture must reproduce hidden redraw requests")
	for field in ["_elapsed", "_phase", "_loading", "_opacity", "_draw_elapsed"]:
		_expect(is_equal_approx(float(old.get(field)), float(current.get(field))), "hidden clock semantics unchanged: " + field)
	var prior_phase := float(current.get("_phase"))
	current.set_mode(2)
	current.set_process(false)
	_expect(is_equal_approx(float(current.get("_phase")), prior_phase), "ready-to-loading must preserve phase")
	holder.show()
	_expect(int(current.get("_test_redraw_batches")) > current_start, "showing parent must refresh current effect state")
	current.set_mode(0)
	_expect(not current.visible and not current.is_processing(), "idle mode must stop processing and hide")
	lifecycle_result = {"hidden_manual_ticks": 12, "baseline_hidden_redraw_batches": int(old.get("_test_redraw_batches")) - old_start, "cached_hidden_redraw_batches": 0, "clock_state_matches": true}
	holder.queue_free()
	await process_frame

func _finish() -> void:
	var report := {"assertions": assertions, "failures": failures, "exact_ordered_argument_cases": compared_cases, "compared_native_commands": compared_commands, "cache_reuse": cache_result, "lifecycle": lifecycle_result, "script_benchmark": benchmark_result, "underlying_line_commands_removed": 0, "note": "64 segments, widths, colors, AA, draw order and 30Hz cadence retained. Positive-width draw_multiline uses per-line backend commands in this Godot version, so it was intentionally not used."}
	FileAccess.open(out_dir + "ready_orbit_cache_check.json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("READY_ORBIT_CACHE_CHECK ", JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)
