extends SceneTree

const Harness := preload("res://tools/CheckHarness.gd")
const Recorder := preload("res://scripts/autoload/PerfLog.gd")
var _directory := "user://resource_perf_check_%d" % Time.get_ticks_usec()

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var h := Harness.new("resource_perf_log")
	var recorder := Recorder.new()
	recorder.resource_trigger_path = _directory.path_join("enabled")
	recorder.resource_log_path = _directory.path_join("resource.jsonl")
	root.add_child(recorder)
	recorder._configure_diagnostics([], false)
	h.expect(not recorder.is_processing() and not recorder._resource_enabled,
		"default_frame_work", "ordinary play must have no per-frame diagnostic work")
	h.expect(not recorder._resource_poll_timer.is_stopped() and recorder._resource_poll_timer.wait_time == 5.0,
		"poll_interval", "disabled recorder must only poll the switch every five seconds")
	h.expect(not FileAccess.file_exists(recorder.resource_log_path), "default_log", "default mode must not create a recording")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_directory))
	var marker := FileAccess.open(recorder.resource_trigger_path, FileAccess.WRITE)
	marker.close()
	recorder._poll_resource_switch()
	h.expect(recorder.is_processing() and recorder._resource_enabled, "hot_enable", "marker must enable recording without restarting")
	_check_marker_content(h, recorder)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(recorder.resource_trigger_path))
	recorder._poll_resource_switch()
	h.expect(not recorder.is_processing() and not recorder._resource_enabled, "hot_disable", "removing marker must stop frame work")
	recorder._configure_diagnostics(["--resource-perf-log"], false)
	h.expect(recorder._resource_enabled and not recorder._legacy_enabled, "independent_flag", "resource flag must not enable legacy full-tree scans")
	recorder._configure_diagnostics(["--server", "--resource-perf-log", "--perf-log"], true)
	h.expect(not recorder.is_processing() and recorder._resource_poll_timer.is_stopped(), "server_work", "server must not poll or sample")
	recorder._configure_diagnostics([], false)
	h.expect(Recorder.diagnostics_enabled(["--perf-log"], false) and Recorder.diagnostics_enabled([], true),
		"legacy_opt_in", "legacy diagnostic modes must remain available")
	_check_frame_distribution(h, recorder)
	_check_census(h, recorder)
	_check_monitor_availability(h)
	_check_live_sample(h, recorder)
	_check_rotation(h, recorder)
	recorder.free()
	for name in DirAccess.get_files_at(_directory):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_directory.path_join(name)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_directory))
	h.finish(self)

func _check_marker_content(h: RefCounted, recorder: Node) -> void:
	for text in ["off", " \nFaLsE\t ", " 0\n"]:
		var marker := FileAccess.open(recorder.resource_trigger_path, FileAccess.WRITE)
		marker.store_string(text)
		marker.close()
		recorder._poll_resource_switch()
		h.expect(not recorder._resource_enabled and not recorder.is_processing(),
			"marker_text_off", "overwriting the existing marker with %s must stop per-frame recording" % text.strip_edges())
		marker = FileAccess.open(recorder.resource_trigger_path, FileAccess.WRITE)
		marker.store_string("on")
		marker.close()
		recorder._poll_resource_switch()
		h.expect(recorder._resource_enabled and recorder.is_processing(),
			"marker_text_on", "overwriting the same marker must allow hot re-enabling")
	var marker := FileAccess.open(recorder.resource_trigger_path, FileAccess.WRITE)
	marker.store_string(" OFF ")
	marker.close()
	recorder._configure_diagnostics(["--resource-perf-log"], false)
	h.expect(recorder._resource_enabled and recorder.is_processing(),
		"forced_flag_over_off", "explicit command-line resource recording must override an off marker")
	recorder._configure_diagnostics([], false)
	h.expect(not recorder._resource_enabled and not recorder.is_processing(),
		"off_after_forced_flag", "off marker must take effect when no explicit force flag applies")
	marker = FileAccess.open(recorder.resource_trigger_path, FileAccess.WRITE)
	marker.close()
	recorder._poll_resource_switch()
	h.expect(recorder._resource_enabled, "empty_marker_compatibility", "an empty rewritten marker must retain the original enabling behavior")

func _check_frame_distribution(h: RefCounted, recorder: Node) -> void:
	recorder._reset_resource_window(Time.get_ticks_usec())
	for pair in [[16.0, 10.0], [34.0, 20.0], [51.0, 30.0], [120.0, 40.0]]:
		recorder._record_resource_frame(pair[0], pair[1])
	var wall: Dictionary = recorder._resource_frame_distribution(true)
	var delta: Dictionary = recorder._resource_frame_distribution(false)
	h.expect(wall.count == 4 and wall.p50 == 34.0 and wall.p95 == 120.0 and wall.p99 == 120.0,
		"wall_percentiles", "known frame intervals must produce the expected percentiles")
	h.expect(wall.over_33_ms == 3 and wall.over_50_ms == 2 and wall.over_100_ms == 1,
		"slow_counts", "slow-frame thresholds must count the actual observed intervals")
	h.expect(delta.max == 40.0 and delta.over_33_ms == 1 and wall.max == 120.0,
		"wall_not_engine_delta", "wall stalls must not be hidden by capped engine delta")
	recorder._reset_resource_window(Time.get_ticks_usec())
	for i in 5000:
		recorder._record_resource_frame(16.0, 16.0)
	wall = recorder._resource_frame_distribution(true)
	h.expect(wall.count == 5000 and wall.percentile_samples == Recorder.RESOURCE_MAX_FRAME_SAMPLES,
		"frame_capacity", "bounded percentile storage must still count every frame")

func _check_census(h: RefCounted, recorder: Node) -> void:
	var fixture := Node3D.new()
	root.add_child(fixture)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var visible := MeshInstance3D.new()
	visible.mesh = mesh
	fixture.add_child(visible)
	var hidden_root := Node3D.new()
	hidden_root.visible = false
	fixture.add_child(hidden_root)
	var hidden := MeshInstance3D.new()
	hidden.mesh = mesh
	hidden_root.add_child(hidden)
	var multi := MultiMeshInstance3D.new()
	multi.multimesh = MultiMesh.new()
	multi.multimesh.mesh = mesh
	multi.multimesh.instance_count = 2
	multi.multimesh.visible_instance_count = 1
	fixture.add_child(multi)
	var skeleton := Skeleton3D.new()
	skeleton.add_bone("first")
	skeleton.add_bone("second")
	fixture.add_child(skeleton)
	var animation := Animation.new()
	animation.length = 1.0
	animation.loop_mode = Animation.LOOP_LINEAR
	var library := AnimationLibrary.new()
	library.add_animation("loop", animation)
	var player := AnimationPlayer.new()
	player.add_animation_library("", library)
	hidden_root.add_child(player)
	player.play("loop")
	var visible_control := Control.new()
	fixture.add_child(visible_control)
	var hidden_control := Control.new()
	hidden_control.visible = false
	visible_control.add_child(hidden_control)
	var gpu := GPUParticles3D.new()
	gpu.amount = 40
	gpu.amount_ratio = 0.25
	gpu.emitting = true
	fixture.add_child(gpu)
	var hidden_gpu := GPUParticles3D.new()
	hidden_gpu.amount = 12
	hidden_gpu.amount_ratio = 0.5
	hidden_gpu.emitting = true
	hidden_root.add_child(hidden_gpu)
	var cpu := CPUParticles2D.new()
	cpu.amount = 10
	cpu.emitting = false
	fixture.add_child(cpu)
	var census: Dictionary = recorder._resource_census(fixture)
	h.expect(census.resident_mesh_instances == 4 and census.tree_visible_mesh_instances == 2,
		"instance_visibility", "hidden parents and MultiMesh visible-instance limits must affect configured visibility")
	h.expect(census.resident_triangles_configured == 4 and census.tree_visible_triangles_configured == 2
		and census.resident_vertices_configured == 12 and census.tree_visible_vertices_configured == 6,
		"geometry_counts", "shared meshes must be counted once per configured instance")
	h.expect(census.resident_material_surfaces == 4 and census.tree_visible_material_surfaces == 2,
		"surface_counts", "surfaces must follow instance and tree visibility semantics")
	h.expect(census.bones == 2 and census.playing_animations == 1 and census.hidden_playing_animations == 1,
		"hidden_animation", "a playing animation below a hidden model must be observable")
	var ui_player := AnimationPlayer.new()
	ui_player.add_animation_library("", library)
	visible_control.add_child(ui_player)
	ui_player.play("loop")
	var ui_census: Dictionary = recorder._resource_census(fixture)
	h.expect(visible_control.is_visible_in_tree() and ui_census.hidden_playing_animations == 2,
		"visible_ui_heuristic", "the no-visible-3D-mesh heuristic can also count visible UI animation")
	h.expect(ui_census.hidden_animation_scope.contains("heuristic") and ui_census.hidden_animation_scope.contains("2D/UI"),
		"hidden_animation_scope", "census must disclose the heuristic and possible 2D/UI false positives")
	h.expect(census.canvas_items == 3 and census.tree_visible_canvas_items == 2,
		"canvas_visibility", "CanvasItem visibility must include inherited hiding")
	var counts: Dictionary = census.particles.gpu_3d
	h.expect(counts.nodes == 2 and counts.emitting_amount_capacity == 52
		and counts.tree_visible_emitting_amount_capacity == 40 and counts.emitting_ratio_scaled_capacity == 16.0
		and counts.amount_ratio_min == 0.25 and counts.amount_ratio_max == 0.5,
		"gpu_capacity", "GPU emitting capacity and amount_ratio must not be presented as live particles")
	h.expect(census.particles.cpu_2d.nodes == 1 and census.particles.cpu_2d.resident_amount_capacity == 10
		and census.particles.cpu_2d.emitting_amount_capacity == 0,
		"cpu_not_emitting", "inactive CPU particle capacity must remain separate from emitting capacity")
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	h.expect(recorder._resource_mesh_counts(mesh).triangles == 2,
		"mesh_mutation", "changing a mesh must invalidate cached geometry estimates")
	var primitive := BoxMesh.new()
	h.expect(recorder._resource_mesh_counts(primitive).triangles == 12,
		"primitive_mesh", "procedural PrimitiveMesh geometry must also be counted")
	var mesh_id := mesh.get_instance_id()
	fixture.free()
	mesh = null
	recorder._resource_census(root)
	h.expect(not recorder._resource_mesh_cache.has(mesh_id), "mesh_cache_retention", "metadata cache must not retain freed meshes")

func _check_monitor_availability(h: RefCounted) -> void:
	var measured := {"static_mb": 12.0, "orphans": 3, "objects": 40, "resources": 20,
		"nodes": 10, "engine_fps": 60, "draw_calls": 8, "rendered_primitives": 120}
	var release_sample: Dictionary = Recorder._resource_apply_monitor_availability(measured.duplicate(), false)
	h.expect(release_sample.static_mb == null and release_sample.orphans == null,
		"release_unavailable_values", "release-only placeholder zeros must be represented as unavailable, not measured zero")
	h.expect(not release_sample.monitor_availability.static_mb.available
		and not release_sample.monitor_availability.orphans.available
		and not release_sample.monitor_availability.debug_build,
		"release_availability", "release records must identify which debug monitors are unavailable")
	h.expect(release_sample.monitor_availability.static_mb.reason.contains("DEBUG_ENABLED")
		and release_sample.monitor_availability.orphans.reason.contains("DEBUG_ENABLED"),
		"unavailable_reason", "unavailable counters must explain the engine build restriction")
	h.expect(release_sample.objects == 40 and release_sample.resources == 20 and release_sample.nodes == 10,
		"release_object_counts", "release-supported object/resource/node counts must retain their measured values")
	h.expect(release_sample.engine_fps == 60 and release_sample.draw_calls == 8 and release_sample.rendered_primitives == 120,
		"release_render_counts", "release-supported FPS and rendering counters must retain their measured values")
	var debug_sample: Dictionary = Recorder._resource_apply_monitor_availability(measured.duplicate(), true)
	h.expect(debug_sample.static_mb == 12.0 and debug_sample.orphans == 3
		and debug_sample.monitor_availability.static_mb.available and debug_sample.monitor_availability.orphans.available,
		"debug_monitors", "debug builds must preserve supported memory/orphan measurements")
	var measured_zero: Dictionary = Recorder._resource_apply_monitor_availability({"static_mb": 0.0, "orphans": 0}, true)
	h.expect(measured_zero.static_mb == 0.0 and measured_zero.orphans == 0,
		"debug_measured_zero", "a supported measured zero must remain distinct from an unavailable null")


func _check_live_sample(h: RefCounted, recorder: Node) -> void:
	var sample: Dictionary = recorder._resource_engine_sample()
	for key in ["engine_fps", "process_ms", "physics_ms", "rendered_primitives", "draw_calls",
			"rendered_objects", "video_mb", "texture_mb", "buffer_mb", "static_mb", "network"]:
		h.expect(sample.has(key), "sample_field", "missing engine sample field: %s" % key)
	h.expect(not sample.network.available, "offline_network", "offline state must not claim zero measured network latency")
	h.expect(sample.monitor_availability.debug_build == OS.is_debug_build(),
		"runtime_build_availability", "actual engine samples must apply the current engine build's availability")
	recorder._configure_diagnostics(["--resource-perf-log"], false)
	recorder._resource_window_start_usec = Time.get_ticks_usec() - 1100000
	recorder._resource_last_census_usec = Time.get_ticks_usec() - 5100000
	recorder._resource_tick(0.016)
	var kinds := {}
	for line in FileAccess.get_file_as_string(recorder.resource_log_path).split("\n", false):
		var record: Variant = JSON.parse_string(line)
		h.expect(record is Dictionary and record.has("utc") and record.has("ticks_ms"),
			"jsonl_shape", "each line must be independently parseable and timestamped")
		if record is Dictionary:
			kinds[record.kind] = true
			if record.kind == "sample":
				h.expect(record.has("recorder_overhead") and record.recorder_overhead.has("frame_collection_us"),
					"collection_cost", "enabled recording must report its own frame collection overhead")
			if record.kind == "census":
				h.expect(record.has("scan_ms") and record.scan_ms >= 0.0,
					"census_cost", "resource traversal must report its own elapsed cost")
	h.expect(kinds.has("sample") and kinds.has("census"), "scheduled_records", "elapsed intervals must emit a frame sample and resource census")
	recorder._configure_diagnostics([], false)

func _check_rotation(h: RefCounted, recorder: Node) -> void:
	recorder.resource_max_bytes = 1024
	for i in 30:
		h.expect(recorder._write_resource_record({"kind": "rotation_probe", "index": i, "padding": "x".repeat(100)}),
			"rotation_write", "rotating writes must succeed")
	var names := DirAccess.get_files_at(_directory)
	h.expect(names.size() == 2 and FileAccess.file_exists(recorder.resource_log_path + ".1"),
		"rotation_files", "recording must retain at most one previous generation")
	for path in [recorder.resource_log_path, recorder.resource_log_path + ".1"]:
		var file := FileAccess.open(path, FileAccess.READ)
		h.expect(file.get_length() <= recorder.resource_max_bytes, "rotation_bound", "each generation must obey its byte cap")
		file.close()
		for line in FileAccess.get_file_as_string(path).split("\n", false):
			h.expect(JSON.parse_string(line) is Dictionary, "rotation_partial_line", "rotation must retain complete JSON records")
