extends Control
## Offline art preview. Formal BattleVfx lifecycle is separately regression tested.
## Android automation: write user://guardian_pilot_request.json before launch.
const GUARDIAN := preload("res://effects/vfx3d/modules/VFXGuardianSanctuary3D.gd")
const LEGACY := preload("res://effects/vfx3d/modules/VFXPackSkill3D.gd")
const BUDGET := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
const MODEL := preload("res://assets/models/units/god_guard_crystalbound/god_guard_crystalbound_animated.tscn")
# Frozen baseline from OgaSkillVFXCatalog on 2026-10-02. Keep the closure small.
const OLD_SPEC := {"layers": [
	{"name":"GuardianBlueShield", "path":"res://assets/vfx/oga/skills/angel_shield_event_frame.tres", "columns":1, "rows":1, "frame_count":1, "fps":1.0, "duration":1.10, "anchor":"origin_body", "size":Vector2(0.92,0.84), "start_scale":0.30, "peak_scale":1.0, "end_scale":0.96, "color":Color(0.54,0.76,1.0,0.88), "fade_out":0.22, "emission_scale":0.58},
	{"name":"GuardianTauntPulse", "path":"res://assets/vfx/oga/skill_packs/holy_burst.png", "columns":5, "rows":1, "frame_count":5, "fps":14.0, "duration":0.52, "delay":0.10, "anchor":"origin_ground", "ground":true, "billboard":false, "size":Vector2(1.46,1.46), "color":Color(0.30,0.58,1.0,0.78)}]}

var _viewport: SubViewport
var _world: Node3D
var _actors: Node3D
var _effects: Node3D
var _camera: Camera3D
var _units: Array[Node3D] = []
var _active: Array[Node3D] = []
var _title: Label
var _status: Label
var _detail: Label
var _mode := "new"
var _count := 1
var _star4 := false
var _paused := false
var _clock := 0.0
var _broken := false
var _dead := false
var _capture_dir := ""
var _captured := {}
var _perf := false
var _cases: Array = []
var _case_index := -1
var _case_clock := 0.0
var _samples: Array[float] = []
var _results: Array = []
var _peak_draws := 0
var _node_samples: Array[int] = []
var _peak_memory := 0
var _case_started_usec := 0
var _last_usec := 0

func _ready() -> void:
	BUDGET.tier = 1
	_build_stage()
	_build_ui()
	var args := OS.get_cmdline_user_args()
	var request: Dictionary = {}
	if FileAccess.file_exists("user://guardian_pilot_request.json"):
		var value: Variant = JSON.parse_string(FileAccess.get_file_as_string("user://guardian_pilot_request.json"))
		if value is Dictionary:
			request = value
		DirAccess.remove_absolute("user://guardian_pilot_request.json")
	for i in args.size():
		if args[i] == "--capture-dir" and i + 1 < args.size():
			_capture_dir = args[i + 1]
		if args[i] == "--old":
			_mode = "old"
		if args[i] == "--close":
			_camera.size = 4.1
		if args[i] == "--low":
			BUDGET.tier = 0
		if args[i] == "--high":
			BUDGET.tier = 2
		if args[i] == "--star4":
			_star4 = true
	if not _capture_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(_capture_dir)
	_mode = str(request.get("mode", _mode))
	_count = int(request.get("count", 1))
	_rebuild_units()
	await get_tree().process_frame
	if bool(request.get("perf", false)) or "--perf" in args:
		_start_perf(request.get("cases", []))
	else:
		_restart()
	_last_usec = Time.get_ticks_usec()
	print("GUARDIAN_PREVIEW_READY renderer=%s user=%s" % [RenderingServer.get_current_rendering_method(), OS.get_user_data_dir()])

func _build_stage() -> void:
	var back := ColorRect.new()
	back.color = Color("131d1b")
	back.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(back)
	var container := SubViewportContainer.new()
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(container)
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(960, 540)
	_viewport.transparent_bg = true
	_viewport.own_world_3d = true
	container.add_child(_viewport)
	_world = Node3D.new()
	_viewport.add_child(_world)
	var floor_node := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(22, 18)
	floor_node.mesh = plane
	floor_node.position.y = -0.14
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.19, 0.21, 0.18)
	floor_mat.roughness = 1.0
	floor_node.material_override = floor_mat
	_world.add_child(floor_node)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.34, 0.42, 0.34)
	env.ambient_light_energy = 0.42
	env_node.environment = env
	_world.add_child(env_node)
	var light := DirectionalLight3D.new()
	light.light_color = Color(1.0, 0.84, 0.62)
	light.light_energy = 1.55
	light.rotation_degrees = Vector3(-55, 35, 0)
	_world.add_child(light)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 7.2
	_world.add_child(_camera)
	_camera.look_at_from_position(Vector3(0, 7.4, 7), Vector3.ZERO, Vector3.UP)
	_camera.current = true
	_actors = Node3D.new()
	_world.add_child(_actors)
	_effects = Node3D.new()
	_world.add_child(_effects)

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 28)
	column.add_child(_title)
	_detail = Label.new()
	_detail.add_theme_font_size_override("font_size", 18)
	_detail.modulate = Color("bec8bc")
	column.add_child(_detail)
	var space := Control.new()
	space.size_flags_vertical = Control.SIZE_EXPAND_FILL
	space.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(space)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 23)
	column.add_child(_status)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 12)
	column.add_child(bar)
	_button(bar, "新版 / New", func(): _select_mode("new"))
	_button(bar, "原版 / Before", func(): _select_mode("old"))
	_button(bar, "重播", _restart)
	_button(bar, "暂停 / 继续", func():
		_paused = not _paused
		_world.process_mode = Node.PROCESS_MODE_DISABLED if _paused else Node.PROCESS_MODE_INHERIT)
	_button(bar, "战斗 / 近景", func(): _camera.size = 4.1 if _camera.size > 5 else 7.2)
	_button(bar, "低 / 中 / 高", func(): BUDGET.tier = (BUDGET.tier + 1) % 3; _restart())
	_button(bar, "1 / 6 / 12 人", func():
		_count = 6 if _count == 1 else (12 if _count == 6 else 1)
		_rebuild_units()
		_restart())
	_button(bar, "普通 / 四星", func(): _star4 = not _star4; _restart())

func _button(parent: Node, text: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(125, 50)
	button.add_theme_font_size_override("font_size", 19)
	button.pressed.connect(func():
		if not _perf:
			action.call())
	parent.add_child(button)

func _select_mode(mode: String) -> void:
	_mode = mode
	_restart()

func _rebuild_units() -> void:
	for child in _actors.get_children():
		child.free()
	_units.clear()
	for i in _count:
		var unit := Node3D.new()
		var at := Vector3.ZERO if _count == 1 else Vector3((i % 4 - 1.5) * 1.5, 0, (i / 4 - 1) * 1.6)
		unit.position = at + Vector3(0, -0.14, 0)
		unit.rotation.y = PI
		unit.set_meta("start", unit.position)
		var model := MODEL.instantiate() as Node3D
		model.scale = Vector3.ONE * 0.42
		unit.add_child(model)
		# Match BattleRenderer: center before the actor enters the tree and its
		# idle animation changes skinned bounds. Root rotation belongs to actor.
		var bounds := _bounds(model, Transform3D.IDENTITY)
		model.position -= Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)
		if i == 0:
			print("GUARDIAN_MODEL position=%s bounds=%s" % [model.position, bounds])
		var anchor := Node3D.new()
		anchor.name = "CastAnchor"
		anchor.position = Vector3(0.0, 0.98 * 0.60, -0.04)
		unit.add_child(anchor)
		_actors.add_child(unit)
		_freeze_after_pose(model)
		_units.append(unit)

func _freeze_after_pose(model: Node3D) -> void:
	await get_tree().process_frame
	if not is_instance_valid(model):
		return
	_freeze(model)

func _bounds(node: Node3D, parent: Transform3D) -> AABB:
	var xform := parent * node.transform
	var result := AABB()
	if node is MeshInstance3D:
		result = xform * (node as MeshInstance3D).get_aabb()
	for child in node.get_children():
		if child is Node3D:
			var child_bounds := _bounds(child, xform)
			if child_bounds.size != Vector3.ZERO:
				result = child_bounds if result.size == Vector3.ZERO else result.merge(child_bounds)
	return result

func _freeze(node: Node) -> void:
	if node is AnimationPlayer:
		# stop() restores the imported rest pose, which displaces this skinned
		# character from its gameplay anchors. Freeze the evaluated idle pose.
		(node as AnimationPlayer).advance(0.0)
		(node as AnimationPlayer).pause()
		(node as AnimationPlayer).active = false
	if node is AnimationTree:
		(node as AnimationTree).active = false
	for child in node.get_children():
		_freeze(child)

func _radius() -> Vector2:
	var radius := 240.0 if _star4 else 180.0
	return Vector2(radius * 14.5 * 0.88 / 1000.0, radius * 10.0 * 0.88 / 520.0)

func _restart() -> void:
	_viewport.msaa_3d = Viewport.MSAA_2X if BUDGET.tier == 2 else Viewport.MSAA_DISABLED
	for child in _effects.get_children():
		child.queue_free()
	_active.clear()
	_clock = 0.0
	_broken = false
	_dead = false
	for unit in _units:
		unit.visible = true
		unit.position = unit.get_meta("start")
		var anchor := unit.get_node("CastAnchor") as Node3D
		if _mode == "new":
			var effect := GUARDIAN.new()
			_effects.add_child(effect)
			effect.play_guardian(anchor.global_position, {"origin_node":anchor, "origin_height":0.98, "persistent":true, "taunt_world_radius":_radius()})
			_active.append(effect)
		elif _mode == "old":
			var effect := LEGACY.new()
			_effects.add_child(effect)
			effect.play_spec({"origin_body":anchor.global_position, "origin_ground":unit.global_position}, OLD_SPEC)
	_title.text = "光之卫士 · 白晶守护   /   " + {"new":"新版", "old":"原版", "off":"无特效"}[_mode]
	_detail.text = "%s画质  ·  %d 单位  ·  %s  ·  自身护盾 + 周围嘲讽，无范围伤害" % [["低", "中", "高"][BUDGET.tier], _count, "四星 / 范围240" if _star4 else "普通 / 范围180"]

func _process(delta: float) -> void:
	if _world == null or _paused:
		return
	var now := Time.get_ticks_usec()
	var wall_ms := float(now - _last_usec) / 1000.0 if _last_usec > 0 else 0.0
	_last_usec = now
	_clock += delta
	if _clock > 1.5 and _clock < 3.1:
		for unit in _units:
			unit.position.x = (unit.get_meta("start") as Vector3).x + sin((_clock - 1.5) * PI / 1.6) * 0.6
	if _clock >= 3.2 and not _broken:
		_broken = true
		for effect in _active:
			if is_instance_valid(effect):
				effect.update_guardian_state(false, true, _radius())
	if _clock >= 5.0 and not _dead:
		_dead = true
		for effect in _active:
			if is_instance_valid(effect):
				effect.stop_vfx()
		for unit in _units:
			unit.visible = false
	_status.text = "%.1fs  ·  %s" % [_clock, "离场：清理全部效果" if _dead else ("护盾已破：嘲讽仍然有效" if _broken else ("移动：护盾与范围跟随" if _clock > 1.5 else "开场：建立护盾与嘲讽"))]
	if not _capture_dir.is_empty():
		for point in [0.8, 2.0, 4.1, 5.6]:
			if _clock >= point and not _captured.has(point):
				_captured[point] = true
				_save_frame("%s-%.1fs.png" % [_mode, point])
		if _clock >= 6.1:
			get_tree().quit()
	if _perf:
		_measure_perf(wall_ms)
	if _clock >= 6.4:
		if _perf:
			_node_samples.append(int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)))
		_restart()

func _save_frame(filename: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_capture_dir.path_join(filename))

func _start_perf(cases: Array) -> void:
	_cases = cases
	if _cases.is_empty():
		for mode in ["off", "old", "new"]:
			_cases.append({"mode":mode, "count":6, "tier":1, "seconds":30})
		_cases.append({"mode":"new", "count":12, "tier":2, "seconds":180})
	_perf = true
	_next_case()

func _next_case() -> void:
	_case_index += 1
	if _case_index >= _cases.size():
		_perf = false
		print("GUARDIAN_PERF_COMPLETE user://guardian_pilot_perf.json")
		_mode = "new"
		_count = 1
		BUDGET.tier = 1
		_rebuild_units()
		_restart()
		return
	var item: Dictionary = _cases[_case_index]
	_mode = str(item.get("mode", "new"))
	_count = int(item.get("count", 6))
	BUDGET.tier = int(item.get("tier", 1))
	_samples.clear()
	_node_samples.clear()
	_peak_draws = 0
	_peak_memory = 0
	_case_clock = 0.0
	_rebuild_units()
	_restart()
	_case_started_usec = Time.get_ticks_usec()
	print("GUARDIAN_PERF_CASE " + JSON.stringify(item))

func _measure_perf(wall_ms: float) -> void:
	_case_clock = float(Time.get_ticks_usec() - _case_started_usec) / 1000000.0
	if _case_clock > 2.0:
		_samples.append(wall_ms)
		_peak_draws = maxi(_peak_draws, int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
		_peak_memory = maxi(_peak_memory, int(Performance.get_monitor(Performance.MEMORY_STATIC)))
	if _case_clock < float(_cases[_case_index].get("seconds", 30)) + 2.0:
		return
	_samples.sort()
	var long_frames := 0
	for value in _samples:
		if value > 100.0:
			long_frames += 1
	var record: Dictionary = _cases[_case_index].duplicate()
	record.merge({"frames":_samples.size(), "p50_ms":_percentile(0.50), "p95_ms":_percentile(0.95), "p99_ms":_percentile(0.99), "over_100ms":long_frames, "peak_draw_calls":_peak_draws, "peak_static_bytes":_peak_memory, "loop_end_node_counts":_node_samples.duplicate()})
	_results.append(record)
	var file := FileAccess.open("user://guardian_pilot_perf.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"scope":"isolated real-model VFX scene, not whole-game benchmark", "renderer":RenderingServer.get_current_rendering_method(), "os":OS.get_name(), "model":OS.get_model_name(), "gpu":RenderingServer.get_video_adapter_name(), "viewport":_viewport.size, "results":_results}, "\t"))
	file.close()
	print("GUARDIAN_PERF_RESULT " + JSON.stringify(record))
	_next_case()

func _percentile(q: float) -> float:
	return _samples[clampi(int(ceil(float(_samples.size()) * q)) - 1, 0, _samples.size() - 1)] if not _samples.is_empty() else 0.0
