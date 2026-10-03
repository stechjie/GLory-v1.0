extends Control
## Isolated model art review. Captures and performance here are not whole-game QA.
## Android: one-shot user://model_pilot_request.json -> model_pilot_perf.json.
const OLD_MODEL_PATH := "res://assets/models/units/god_priest_halo_animated/god_priest_animated.tscn"
# Replace only this path when the approved refinement scene is available.
const NEW_MODEL_PATH := "res://assets/models/units/god_priest_refined/god_priest_refined.tscn"
const PRIEST_PATH := "res://assets/models/units/god_priestess_animated/god_priestess_animated.tscn"
const ARBITER_PATH := "res://assets/models/units/god_angel_animated/god_angel_animated.tscn"
const TARGET_UNIT_ID := "god_priest"
const LOOP_SECONDS := 7.2
const MODEL_SCALE := 0.42
const CAPTURE_POINTS := [0.8, 3.0, 5.3, 6.9]
# Per-asset art front, independent from gameplay model_base_yaw. Verified at
# idle 0.8: eye midpoint is +Z from head for guard/priest/arbiter, and guard
# front/back captures confirm the visor/chest versus rear helmet/backplate.
# Keep entries explicit: future assets may use a different authored forward.
const ART_FRONT_YAWS := {
	OLD_MODEL_PATH: 0.0,
	PRIEST_PATH: 0.0,
	ARBITER_PATH: 0.0,
}

var _viewport: SubViewport
var _world: Node3D
var _actors: Node3D
var _camera: Camera3D
var _floor_material: StandardMaterial3D
var _environment: Environment
var _title: Label
var _detail: Label
var _status: Label
var _models: Array[Node3D] = []
var _players: Array[AnimationPlayer] = []
var _units: Array[Node3D] = []
var _paths: Array[String] = []
var _variant := "new"
var _layout := "single"
var _count := 1
var _view := "battle"
var _close := false
var _background := "gray"
var _pose := "cycle"
var _active_pose := ""
var _paused := false
var _animate := true
var _clock := 0.0
var _last_usec := 0
var _ready_done := false
var _capture_dir := ""
var _captured: Dictionary = {}
var _capture_busy := false
var _pending_captures := 0
var _capture_metadata: Array = []
var _smoke := false
var _smoke_report := ""
var _smoke_poses: Array[String] = []
var _run_id := ""
var _source_fingerprint := ""
var _perf := false
var _cases: Array = []
var _case_index := -1
var _case_started_usec := 0
var _samples: Array[float] = []
var _node_samples: Array[int] = []
var _results: Array = []
var _peak_draws := 0
var _peak_memory := 0

func _ready() -> void:
	var request: Dictionary = {}
	if FileAccess.file_exists("user://model_pilot_request.json"):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("user://model_pilot_request.json"))
		DirAccess.remove_absolute("user://model_pilot_request.json")
		if not parsed is Dictionary:
			_error("request must be a JSON object")
			return
		request = parsed
	var args := OS.get_cmdline_user_args()
	var problem := validate_request(request, "--perf" in args)
	if not problem.is_empty():
		_error(problem)
		return
	var perf_requested := bool(request.get("perf", false)) or "--perf" in args
	_variant = str(request.get("variant", "new"))
	_count = int(request.get("count", 1))
	_animate = bool(request.get("animate", true))
	_run_id = str(request.get("run_id", ""))
	var build_path := "res://" + "model_build_info.json"
	if FileAccess.file_exists(build_path):
		var build: Variant = JSON.parse_string(FileAccess.get_file_as_string(build_path))
		if not build is Dictionary or build.is_empty():
			_error("build info must be a non-empty JSON object")
			return
		_source_fingerprint = str(build.get("source_fingerprint", ""))
		var identity_error := validate_request(build, true)
		if not identity_error.is_empty():
			_error("build identity: " + identity_error)
			return
	elif perf_requested:
		_error("performance requests require model_build_info.json")
		return
	if perf_requested and _source_fingerprint.is_empty():
		_error("performance requests require a non-empty build source_fingerprint")
		return
	for i in args.size():
		var arg := args[i]
		if arg in ["--capture-dir", "--view", "--pose", "--background", "--smoke-report", "--unit"] and i + 1 >= args.size():
			_error("missing value for " + arg)
			return
		match arg:
			"--unit":
				if args[i + 1] != TARGET_UNIT_ID:
					_error("This preview is configured for " + TARGET_UNIT_ID + "; configure a target-specific old/new scene before testing another unit")
					return
			"--capture-dir": _capture_dir = args[i + 1]
			"--view": _view = args[i + 1]
			"--pose": _pose = args[i + 1]
			"--background": _background = args[i + 1]
			"--old": _variant = "old"
			"--compare": _layout = "compare"
			"--lineup": _layout = "lineup"
			"--close": _close = true
			"--freeze-model": _animate = false
			"--smoke": _smoke = true
			"--smoke-report": _smoke_report = args[i + 1]
	if _view not in ["front", "side", "back", "battle"] or _pose not in ["cycle", "idle", "run", "attack"] or _background not in ["gray", "grass", "snow"]:
		_error("invalid view, pose, or background")
		return
	if _close and _view == "battle":
		_view = "front"
	if not _capture_dir.is_empty():
		if DisplayServer.get_name() == "headless":
			_error("rendered captures require a graphics display")
			return
		if DirAccess.make_dir_recursive_absolute(_capture_dir) != OK:
			_error("cannot create capture directory")
			return
	_build_stage()
	_build_ui()
	_apply_background()
	_rebuild()
	if not _ready_done:
		return
	if bool(request.get("perf", false)) or "--perf" in args:
		_start_perf(request.get("cases", []))
	_last_usec = Time.get_ticks_usec()
	print("MODEL_PREVIEW_READY unit=god_priest renderer=%s user=%s variant=%s paths=%s" % [RenderingServer.get_current_rendering_method(), OS.get_user_data_dir(), _variant, JSON.stringify(_paths)])

static func validate_request(request: Dictionary, require_identity: bool = false) -> String:
	for key in ["perf", "animate"]:
		if request.has(key) and not request[key] is bool:
			return "%s must be boolean" % key
	if require_identity or bool(request.get("perf", false)):
		for key in ["unit_id", "old_model_path", "new_model_path"]:
			if not request.has(key) or not request[key] is String or str(request[key]).is_empty():
				return "%s is required for performance/build identity" % key
	if request.has("unit_id") and str(request.unit_id) != TARGET_UNIT_ID:
		return "unit_id does not match this preview target " + TARGET_UNIT_ID
	for key in ["old_model_path", "new_model_path"]:
		var expected := OLD_MODEL_PATH if key == "old_model_path" else NEW_MODEL_PATH
		if request.has(key) and str(request[key]) != expected:
			return key + " does not match this preview model"
	if request.has("run_id") and (not request.run_id is String or str(request.run_id).length() > 128):
		return "run_id must be a string of at most 128 characters"
	var cases: Variant = request.get("cases", [])
	if not cases is Array or cases.size() > 12:
		return "cases must be an array with at most 12 entries"
	var entries: Array = [request]
	entries.append_array(cases)
	for item in entries:
		if not item is Dictionary:
			return "each case must be an object"
		if str(item.get("variant", "new")) not in ["old", "new"]:
			return "variant must be old or new"
		for key in ["count", "seconds"]:
			if item.has(key) and not (item[key] is int or item[key] is float):
				return "%s must be numeric" % key
		if float(item.get("count", 1)) not in [1.0, 6.0, 12.0]:
			return "count must be 1, 6, or 12"
		if float(item.get("seconds", 30)) < 1.0 or float(item.get("seconds", 30)) > 600.0:
			return "seconds must be between 1 and 600"
	return ""

func _error(message: String) -> void:
	_ready_done = false
	push_error("MODEL_PREVIEW_ERROR " + message)
	get_tree().quit(2)

func _build_stage() -> void:
	var container := SubViewportContainer.new()
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(container)
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(1280, 720)
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Medium matches the previous phone baseline. Do not quietly add MSAA.
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	container.add_child(_viewport)
	_world = Node3D.new()
	_viewport.add_child(_world)
	var floor_node := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(28, 24)
	floor_node.mesh = plane
	floor_node.position.y = -0.14
	_floor_material = StandardMaterial3D.new()
	_floor_material.roughness = 1.0
	floor_node.material_override = _floor_material
	_world.add_child(floor_node)
	_environment = Environment.new()
	_environment.background_mode = Environment.BG_COLOR
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_environment.ambient_light_color = Color(0.34, 0.42, 0.34)
	_environment.ambient_light_energy = 0.42
	var environment_node := WorldEnvironment.new()
	environment_node.environment = _environment
	_world.add_child(environment_node)
	var key := DirectionalLight3D.new()
	key.light_color = Color(1.0, 0.84, 0.62)
	key.light_energy = 1.55
	key.rotation_degrees = Vector3(-55, 35, 0)
	key.shadow_enabled = false
	_world.add_child(key)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.near = 0.03
	_camera.far = 80.0
	_camera.current = true
	_world.add_child(_camera)
	_actors = Node3D.new()
	_world.add_child(_actors)

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 22)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(column)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 25)
	column.add_child(_title)
	_detail = Label.new()
	_detail.add_theme_font_size_override("font_size", 17)
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_detail)
	var spacer := Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(spacer)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 19)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	var bar := HFlowContainer.new()
	bar.add_theme_constant_override("h_separation", 9)
	bar.add_theme_constant_override("v_separation", 8)
	column.add_child(bar)
	_button(bar, "原版", func(): _variant = "old"; _layout = "single"; _rebuild())
	_button(bar, "新版", func(): _variant = "new"; _layout = "single"; _rebuild())
	_button(bar, "左右对照", func(): _layout = "compare"; _rebuild())
	_button(bar, "神族同框", func(): _layout = "lineup"; _rebuild())
	_button(bar, "战斗 / 近景", func(): _close = not _close; _view = "front" if _close else "battle"; _apply_camera())
	_button(bar, "前 / 侧 / 后", func(): _view = {"battle":"front", "front":"side", "side":"back", "back":"front"}[_view]; _apply_camera())
	_button(bar, "循环 / 待机 / 跑 / 攻", func(): _pose = {"cycle":"idle", "idle":"run", "run":"attack", "attack":"cycle"}[_pose]; _reset_cycle())
	_button(bar, "暂停 / 继续", func(): _paused = not _paused; _last_usec = Time.get_ticks_usec())
	_button(bar, "灰 / 草 / 雪", func(): _background = {"gray":"grass", "grass":"snow", "snow":"gray"}[_background]; _apply_background())
	_button(bar, "1 / 6 / 12 人", func(): _layout = "single"; _count = 6 if _count == 1 else (12 if _count == 6 else 1); _rebuild())
	_button(bar, "重播", func(): _paused = false; _reset_cycle())

func _button(parent: Node, label: String, action: Callable) -> void:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(96, 43)
	button.add_theme_font_size_override("font_size", 17)
	button.pressed.connect(func():
		if not _perf:
			action.call())
	parent.add_child(button)

func _apply_background() -> void:
	var colors := {"gray":Color("343b45"), "grass":Color("304836"), "snow":Color("c2ccd5")}
	_floor_material.albedo_color = colors[_background]
	_environment.background_color = colors[_background]

func _apply_camera() -> void:
	_camera.size = 7.2
	if _close:
		_camera.size = 2.2 if _layout == "single" and _count == 1 else (2.4 if _layout == "compare" else 5.3)
	var turn: float = {"battle":0.0, "front":0.0, "side":PI * 0.5, "back":PI}[_view]
	for unit in _units:
		# Gameplay facing stays 180 degrees. Art front is separately calibrated.
		unit.rotation.y = PI if _view == "battle" else float(unit.get_meta("art_front_yaw", 0.0)) + turn
	if _view == "battle":
		_camera.look_at_from_position(Vector3(0, 7.4, 7.0), Vector3.ZERO, Vector3.UP)
	else:
		# Rotate actors rather than orbiting the camera: compare and lineup
		# remain side by side instead of overlapping in the side view.
		var target := Vector3(0, 0.60, 0)
		_camera.look_at_from_position(target + Vector3(0, 0.75, 6), target, Vector3.UP)
	_update_labels()

func _rebuild() -> void:
	_ready_done = false
	for child in _actors.get_children():
		child.free()
	_models.clear()
	_players.clear()
	_units.clear()
	_paths.clear()
	var placements: Array = []
	if _layout == "compare":
		placements = [{"path":OLD_MODEL_PATH,"x":-0.95,"z":0.0}, {"path":NEW_MODEL_PATH,"x":0.95,"z":0.0}]
	elif _layout == "lineup":
		placements = [{"path":PRIEST_PATH,"x":-1.75,"z":0.0}, {"path":NEW_MODEL_PATH,"x":0.0,"z":0.0}, {"path":ARBITER_PATH,"x":1.75,"z":0.0}]
	else:
		var columns := 3 if _count == 6 else 4
		var rows := int(ceil(float(_count) / columns))
		for i in _count:
			placements.append({"path":OLD_MODEL_PATH if _variant == "old" else NEW_MODEL_PATH,"x":0.0 if _count == 1 else (float(i % columns) - (columns-1)*0.5)*1.35,"z":0.0 if _count == 1 else (float(i / columns) - (rows-1)*0.5)*1.45})
	for item in placements:
		var packed := load(str(item.path)) as PackedScene
		if packed == null:
			_error("model cannot load: " + str(item.path))
			return
		var model := packed.instantiate() as Node3D
		if model == null:
			_error("model root must be Node3D")
			return
		var actor := Node3D.new()
		actor.position = Vector3(float(item.x), -0.14, float(item.z))
		actor.rotation.y = PI
		# Refined guardian inherits the original guardian's authored orientation.
		var calibration_path: String = OLD_MODEL_PATH if str(item.path) == NEW_MODEL_PATH else str(item.path)
		actor.set_meta("art_front_yaw", float(ART_FRONT_YAWS.get(calibration_path, 0.0)))
		model.scale = Vector3.ONE * MODEL_SCALE
		actor.add_child(model)
		# Same pre-tree scaled mesh centering as BattleRenderer. Animated FBX
		# wrappers create children in _ready; source behavior is intentionally kept.
		var bounds := _bounds(model, Transform3D.IDENTITY)
		if bounds.size != Vector3.ZERO:
			model.position -= Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)
		_actors.add_child(actor)
		_models.append(model)
		_units.append(actor)
		_paths.append(str(item.path))
		for found in model.find_children("*", "AnimationPlayer", true, false):
			var player := found as AnimationPlayer
			player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
			_players.append(player)
	_ready_done = true
	_reset_cycle()
	_apply_camera()

func _bounds(node: Node3D, parent: Transform3D) -> AABB:
	var transform_value := parent * node.transform
	var bounds := AABB()
	if node is MeshInstance3D:
		bounds = transform_value * node.get_aabb()
	for child in node.get_children():
		if child is Node3D:
			var next := _bounds(child, transform_value)
			if next.size != Vector3.ZERO:
				bounds = next if bounds.size == Vector3.ZERO else bounds.merge(next)
	return bounds

func _reset_cycle() -> void:
	_clock = 0.0
	_active_pose = ""
	_set_pose(_pose if _pose != "cycle" else "idle")
	for player in _players:
		if not player.current_animation.is_empty():
			player.seek(0.0, true)
			player.advance(0.0)
	_update_labels()

func _pose_at(clock_value: float) -> String:
	if not _animate:
		return "idle"
	if _pose != "cycle":
		return _pose
	return "idle" if clock_value < 2.4 or clock_value >= 6.4 else ("run" if clock_value < 4.6 else "attack")

func _set_pose(pose_value: String) -> void:
	if _active_pose == pose_value:
		return
	_active_pose = pose_value
	for model in _models:
		var method := "play_" + pose_value
		if model.has_method(method):
			model.call(method)
		else:
			var found := model.find_children("*", "AnimationPlayer", true, false)
			if not found.is_empty() and found[0].has_animation(pose_value):
				found[0].play(pose_value)
	if not _smoke_poses.has(pose_value):
		_smoke_poses.append(pose_value)

func _update_labels() -> void:
	if _title == null:
		return
	var layout_name: String = {"single":"原版" if _variant == "old" else "新版", "compare":"左：原版    右：新版", "lineup":"左：大祭司    中：神侍新版    右：天使"}[_layout]
	_title.text = "神族模型精修 · 神侍  /  " + str(layout_name)
	_detail.text = "真实比例 ×0.42 · 正交 %.1f · %s · %s · %d 模型 · 三动作同相位" % [_camera.size, _view, _background, _models.size()]

func _process(delta: float) -> void:
	if not _ready_done or _capture_busy:
		return
	var now := Time.get_ticks_usec()
	var wall_ms := float(now - _last_usec) / 1000.0 if _last_usec > 0 else 0.0
	_last_usec = now
	if _paused:
		return
	var step := 0.25 if _smoke else delta
	_clock += step
	_set_pose(_pose_at(_clock))
	if _pose != "cycle" and _animate:
		for model in _models:
			var proxy := model.get_node_or_null("AnimationPlayer") as AnimationPlayer
			if proxy != null and (str(proxy.current_animation) != _pose or not proxy.is_playing()):
				if model.has_method("play_" + _pose):
					model.call("play_" + _pose)
	if _animate:
		# Manual advancement gives old/new exactly the same animation delta.
		for player in _players:
			player.advance(step)
	_status.text = "%.1f / %.1fs · %s%s%s" % [_clock, LOOP_SECONDS, _active_pose, " · 定帧" if not _animate else "", " · 真机测量中，按钮锁定" if _perf else ""]
	if not _capture_dir.is_empty():
		for point in CAPTURE_POINTS:
			if _clock >= point and not _captured.has(point):
				_captured[point] = true
				_capture_at(point)
				return
		if _captured.size() == CAPTURE_POINTS.size() and _pending_captures == 0 and _clock >= LOOP_SECONDS:
			print("MODEL_CAPTURE_COMPLETE " + _capture_dir)
			get_tree().quit()
			return
	if _perf:
		_measure_perf(wall_ms)
	if _clock >= LOOP_SECONDS:
		if _smoke:
			_finish_smoke()
			return
		if _perf:
			_node_samples.append(int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)))
		_reset_cycle()

func _capture_at(point: float) -> void:
	_capture_busy = true
	_pending_captures += 1
	_active_pose = ""
	_set_pose(_pose_at(point))
	var phase := point
	if _pose == "cycle":
		phase = point - (4.6 if point >= 4.6 and point < 6.4 else (2.4 if point >= 2.4 and point < 4.6 else (6.4 if point >= 6.4 else 0.0)))
	var sampled_animations: Array = []
	for player in _players:
		if not player.current_animation.is_empty():
			var clip := player.get_animation(player.current_animation)
			# A non-looping attack is sampled on its real timeline. Later capture
			# points hold its final pose; never wrap them into an invented hit.
			# Stay just before the clip end so animation_finished cannot switch
			# the wrapper to idle while this attack screenshot is being drawn.
			var clip_time := fmod(phase, clip.length) if clip.loop_mode != Animation.LOOP_NONE else minf(phase, maxf(0.0,clip.length-0.0001))
			player.seek(clip_time, true)
			player.advance(0.0)
			sampled_animations.append({"player":str(player.get_path()),"animation":str(player.current_animation),"sample_time":player.current_animation_position,"clip_length":clip.length})
	await RenderingServer.frame_post_draw
	var filename := "%s-%s-%s-%s-%.1fs.png" % [_layout if _layout != "single" else _variant, _view, _background, _active_pose, point]
	var error := get_viewport().get_texture().get_image().save_png(_capture_dir.path_join(filename))
	if error != OK:
		_error("PNG write failed: " + filename)
	var yaw_values: Array = []
	for unit in _units:
		yaw_values.append(unit.rotation_degrees.y)
	_capture_metadata.append({"file":filename,"cycle_time":point,"requested_pose":_pose,"sampled_pose":_active_pose,"view":_view,"actor_yaw_degrees":yaw_values,"models":_paths.duplicate(),"animation_samples":sampled_animations})
	var metadata_file := FileAccess.open(_capture_dir.path_join("capture-metadata.json"), FileAccess.WRITE)
	if metadata_file != null:
		metadata_file.store_string(JSON.stringify({"renderer":RenderingServer.get_current_rendering_method(),"viewport":_viewport.size,"captures":_capture_metadata},"\t"))
	_pending_captures -= 1
	_capture_busy = false
	_last_usec = Time.get_ticks_usec()

func _finish_smoke() -> void:
	var animations: Array = []
	for player in _players:
		animations.append({"path":str(player.get_path()),"animations":Array(player.get_animation_list()),"current":str(player.current_animation),"position":player.current_animation_position})
	var yaw_values: Array = []
	for unit in _units:
		yaw_values.append(unit.rotation_degrees.y)
	var report := {"scope":"headless scene/animation smoke, no rendered pixels", "models":_paths,"model_count":_models.size(),"visited_poses":_smoke_poses,"animation_players":animations,"view":_view,"camera_size":_camera.size,"variant":_variant,"layout":_layout,"actor_yaw_degrees":yaw_values}
	if not _smoke_report.is_empty():
		var file := FileAccess.open(_smoke_report, FileAccess.WRITE)
		if file == null:
			_error("cannot write smoke report")
			return
		file.store_string(JSON.stringify(report,"\t"))
	print("MODEL_SMOKE_COMPLETE " + JSON.stringify(report))
	get_tree().quit()

func _start_perf(cases: Array) -> void:
	_cases = cases.duplicate(true)
	if _cases.is_empty():
		_cases = [{"variant":"old","count":6,"seconds":30}, {"variant":"new","count":6,"seconds":30}, {"variant":"old","count":12,"seconds":30}, {"variant":"new","count":12,"seconds":30}]
	_layout = "single"
	_view = "battle"
	_close = false
	_pose = "cycle"
	_background = "gray"
	_apply_background()
	_results.clear()
	_case_index = -1
	_perf = true
	_next_case()

func _next_case() -> void:
	_case_index += 1
	if _case_index >= _cases.size():
		_perf = false
		print("MODEL_PERF_COMPLETE user://model_pilot_perf.json")
		if "--perf" in OS.get_cmdline_user_args():
			get_tree().quit()
			return
		_variant = "new"
		_count = 1
		_animate = true
		_rebuild()
		return
	var item: Dictionary = _cases[_case_index]
	item = {"variant":str(item.get("variant", "new")), "count":int(item.get("count", 6)), "seconds":float(item.get("seconds", 30))}
	_cases[_case_index] = item
	_variant = item.variant
	_count = item.count
	_samples.clear()
	_node_samples.clear()
	_peak_draws = 0
	_peak_memory = 0
	_rebuild()
	_case_started_usec = Time.get_ticks_usec()
	_last_usec = _case_started_usec
	print("MODEL_PERF_CASE " + JSON.stringify(item))

func _measure_perf(wall_ms: float) -> void:
	var elapsed := float(Time.get_ticks_usec() - _case_started_usec) / 1000000.0
	if elapsed > 2.0:
		_samples.append(wall_ms)
		_peak_draws = maxi(_peak_draws, int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
		_peak_memory = maxi(_peak_memory, int(Performance.get_monitor(Performance.MEMORY_STATIC)))
	if elapsed < float(_cases[_case_index].get("seconds", 30)) + 2.0:
		return
	_samples.sort()
	var long_frames := 0
	for value in _samples:
		if value > 100.0:
			long_frames += 1
	var record: Dictionary = _cases[_case_index].duplicate()
	record.merge({"frames":_samples.size(), "warmup_seconds":2.0, "sampled_seconds":elapsed-2.0, "p50_ms":_percentile(0.50), "p95_ms":_percentile(0.95), "p99_ms":_percentile(0.99), "over_100ms":long_frames, "peak_draw_calls":_peak_draws, "peak_static_bytes":_peak_memory, "loop_end_node_counts":_node_samples.duplicate()},true)
	_results.append(record)
	var file := FileAccess.open("user://model_pilot_perf.json",FileAccess.WRITE)
	if file == null:
		_error("cannot write performance report")
		return
	file.store_string(JSON.stringify({"schema_version":1,"unit_id":TARGET_UNIT_ID,"old_model_path":OLD_MODEL_PATH,"new_model_path":NEW_MODEL_PATH,"run_id":_run_id,"source_fingerprint":_source_fingerprint,"completed":_results.size()==_cases.size(),"animation_mode":"animated" if _animate else "frozen","scope":"isolated model scene, not whole-game benchmark","renderer":RenderingServer.get_current_rendering_method(),"os":OS.get_name(),"model":OS.get_model_name(),"gpu":RenderingServer.get_video_adapter_name(),"viewport":_viewport.size,"results":_results},"\t"))
	file.close()
	print("MODEL_PERF_RESULT " + JSON.stringify(record))
	_next_case()

func _percentile(q: float) -> float:
	return _samples[clampi(int(ceil(_samples.size()*q))-1,0,_samples.size()-1)] if not _samples.is_empty() else 0.0
