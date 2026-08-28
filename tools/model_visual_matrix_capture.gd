extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const UnitVisualResolverScript := preload("res://effects/runtime/presentation/UnitVisualResolver.gd")
const UnitActor3DScript := preload("res://effects/runtime/presentation/UnitActor3D.gd")
const VFXQualityBudgetScript := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
const ImageMetricsScript := preload("res://tools/model_visual_image_metrics.gd")

const CHECK_NAME := "model_visual_matrix"
const POLICY_PATH := "res://data/qa/model_visual_matrix_policy.json"
const DEFAULT_OUTPUT := "res://reports/model_visual_matrix"
const BACKGROUND := Color(0.18, 0.18, 0.18, 1.0)
const CAMERA_FOV := 39.0

var _h: CheckHarness
var _policy: Dictionary = {}
var _output_dir := ""
var _viewport: SubViewport
var _stage: Node3D
var _camera: Camera3D
var _label_plate: ColorRect
var _label: Label
var _report_models: Array[Dictionary] = []
var _tier_image_paths: Dictionary = {}
var _manual_ids: Array[String] = []
var _summary := {
	"model_entries": 0,
	"model_3d_success": 0,
	"fallback_portrait_success": 0,
	"fallback_failed": 0,
	"images_expected": 0,
	"images_written": 0,
	"image_failures": 0,
	"action_missing": 0,
	"white_material_suspect": 0,
	"contact_sheet_pages": 0,
}


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	if not _load_policy():
		_h.finish(get_tree())
		return
	DataRegistry.load_all()
	_output_dir = _resolve_output_dir()
	DirAccess.make_dir_recursive_absolute(_output_dir)
	_ensure_reports_gdignore()
	_build_stage()
	await get_tree().process_frame

	var entries := _collect_entries()
	entries = _apply_entry_filter(entries)
	entries = _apply_entry_limit(entries)
	var tiers := _requested_tiers()
	var states := _string_array(_policy.get("states", []))
	_summary.model_entries = entries.size()
	_summary.images_expected = entries.size() * tiers.size() * states.size()
	_h.expect(not entries.is_empty(), "combat_entries_empty", "没有枚举到任何可战斗模型")
	_h.expect(states == ["idle", "attack", "hit", "death"], "state_policy_invalid",
		"截图状态必须严格为 idle/attack/hit/death，当前：%s" % str(states))
	_h.expect(Vector2i(int(_policy.resolution[0]), int(_policy.resolution[1])) == Vector2i(1280, 720),
		"resolution_invalid", "模型矩阵必须使用 1280x720")
	var renderer_method := str(ProjectSettings.get_setting("rendering/renderer/rendering_method", ""))
	_h.expect(renderer_method == "mobile", "renderer_not_forward_mobile",
		"项目 renderer method 不是 mobile：%s" % renderer_method)

	_manual_ids = _select_manual_sample(entries)
	for tier in tiers:
		_tier_image_paths[tier] = []
	for entry in entries:
		var model_row := await _capture_entry(entry, tiers, states)
		_report_models.append(model_row)

	var contact_pages := _write_contact_sheets(tiers)
	_summary.contact_sheet_pages = contact_pages.size()
	_write_manual_sample(tiers, contact_pages)
	_write_report(tiers, states, contact_pages, renderer_method)
	print("MODEL_VISUAL_MATRIX models=%d images=%d/%d 3d=%d fallback_ok=%d fallback_failed=%d image_failures=%d action_missing=%d white_material_suspect=%d sheets=%d report=%s" % [
		int(_summary.model_entries), int(_summary.images_written), int(_summary.images_expected),
		int(_summary.model_3d_success), int(_summary.fallback_portrait_success), int(_summary.fallback_failed),
		int(_summary.image_failures), int(_summary.action_missing), int(_summary.white_material_suspect),
		int(_summary.contact_sheet_pages), _report_path(_output_dir.path_join("model_visual_matrix.json")),
	])
	_h.finish(get_tree())


func _load_policy() -> bool:
	if not FileAccess.file_exists(POLICY_PATH):
		_h.fail("policy_missing", "策略文件不存在：%s" % POLICY_PATH)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(POLICY_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		_h.fail("policy_parse_failed", "策略文件不是合法 JSON object：%s" % POLICY_PATH)
		return false
	_policy = parsed as Dictionary
	for key in ["seed", "resolution", "quality_tiers", "states", "manual_sample_count"]:
		if not _policy.has(key):
			_h.fail("policy_field_missing", "%s 缺字段：%s" % [POLICY_PATH, key])
	return _h.failure_count() == 0


func _build_stage() -> void:
	var resolution := Vector2i(int(_policy.resolution[0]), int(_policy.resolution[1]))
	_viewport = SubViewport.new()
	_viewport.name = "ModelMatrixViewport"
	_viewport.size = resolution
	_viewport.own_world_3d = true
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.msaa_3d = Viewport.MSAA_2X
	add_child(_viewport)

	var environment_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = BACKGROUND
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.54, 0.55, 0.58)
	environment.ambient_light_energy = 0.46
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment_node.environment = environment
	_viewport.add_child(environment_node)

	_add_directional_light("KeyLight", Color(1.0, 0.86, 0.70), 1.18, Vector3(-48.0, 34.0, 0.0))
	_add_directional_light("FillLight", Color(0.66, 0.78, 1.0), 0.46, Vector3(-22.0, -58.0, 0.0))
	_add_directional_light("RimLight", Color(1.0, 0.94, 0.80), 0.72, Vector3(-34.0, 152.0, 0.0))

	_camera = Camera3D.new()
	_camera.name = "FixedCamera"
	_camera.fov = CAMERA_FOV
	_camera.near = 0.02
	_camera.far = 200.0
	_camera.current = true
	_viewport.add_child(_camera)
	_stage = Node3D.new()
	_stage.name = "Stage"
	_viewport.add_child(_stage)
	_build_label_overlay(resolution)


func _add_directional_light(name_value: String, color: Color, energy: float, rotation: Vector3) -> void:
	var light := DirectionalLight3D.new()
	light.name = name_value
	light.light_color = color
	light.light_energy = energy
	light.rotation_degrees = rotation
	light.shadow_enabled = false
	_viewport.add_child(light)


func _build_label_overlay(resolution: Vector2i) -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 20
	_viewport.add_child(canvas)
	_label_plate = ColorRect.new()
	_label_plate.position = Vector2.ZERO
	_label_plate.size = Vector2(resolution.x, int(_policy.get("label_height_px", 72)))
	_label_plate.color = Color(0.015, 0.018, 0.022, 0.90)
	_label_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(_label_plate)
	_label = Label.new()
	_label.position = Vector2(18, 7)
	_label.size = Vector2(resolution.x - 36, _label_plate.size.y - 10)
	_label.add_theme_font_size_override("font_size", 22)
	_label.add_theme_color_override("font_color", Color(0.96, 0.96, 0.94))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	_label.add_theme_constant_override("outline_size", 4)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(_label)


func _collect_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var path_to_index: Dictionary = {}
	for definition_value in UnitVisualResolverScript.all_combat_entries():
		var definition: Dictionary = definition_value
		var unit_id := str(definition.get("id", ""))
		var paths := UnitVisualResolverScript.all_model_paths(definition)
		if paths.is_empty():
			out.append(_entry_from_definition(definition, "", ""))
			continue
		for model_path in paths:
			if path_to_index.has(model_path):
				var existing_index := int(path_to_index[model_path])
				var existing: Dictionary = out[existing_index]
				var consumers: Array = existing.get("consumer_unit_ids", [])
				if not consumers.has(unit_id):
					consumers.append(unit_id)
				existing.consumer_unit_ids = consumers
				out[existing_index] = existing
				continue
			var variant := _variant_for_path(definition, model_path)
			path_to_index[model_path] = out.size()
			out.append(_entry_from_definition(definition, model_path, variant))
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.capture_id) < str(b.capture_id))
	return out


func _entry_from_definition(definition: Dictionary, model_path: String, variant: String) -> Dictionary:
	var unit_id := str(definition.get("id", "missing_id"))
	var capture_id := unit_id
	if not variant.is_empty():
		capture_id += "__" + variant
	return {
		"capture_id": capture_id,
		"unit_id": unit_id,
		"consumer_unit_ids": [unit_id],
		"name": str(definition.get("name", unit_id)),
		"visual_kind": str(definition.get("visual_kind", "unit")),
		"variant": variant,
		"source_scene": model_path,
		"portrait": str(definition.get("portrait", "")),
		"fallback_frame": str(definition.get("fallback_frame", "")),
		"model_visual_scale": float(definition.get("model_visual_scale", 1.0)),
		"model_base_yaw": float(definition.get("model_base_yaw", 180.0)),
		"model_idle_animation_name": str(definition.get("model_idle_animation_name", "")),
		"model_attack_animation_name": str(definition.get("model_attack_animation_name", "")),
		"model_run_animation_name": str(definition.get("model_run_animation_name", "")),
		"required_3d": true,
	}


func _variant_for_path(definition: Dictionary, model_path: String) -> String:
	var variants_value: Variant = definition.get("model_by_element", {})
	if typeof(variants_value) == TYPE_DICTIONARY:
		for key in (variants_value as Dictionary).keys():
			if str((variants_value as Dictionary)[key]) == model_path:
				return str(key)
	return ""


func _capture_entry(entry: Dictionary, tiers: Array[String], states: Array[String]) -> Dictionary:
	var frame := await _measure_entry(entry)
	var row := entry.duplicate(true)
	row["camera_frame"] = frame
	row["captures"] = []
	row["model_3d_success"] = true
	row["fallback_portrait_success"] = false
	row["fallback_reasons"] = []
	for tier in tiers:
		_set_quality_tier(tier)
		for state in states:
			var capture := await _capture_one(entry, frame, tier, state)
			(row.captures as Array).append(capture)
			(_tier_image_paths[tier] as Array).append(str(capture.get("image_absolute", "")))
			if str(capture.get("visual_result", "")) != "MODEL_3D":
				row.model_3d_success = false
				if str(capture.get("visual_result", "")) == "FALLBACK_PORTRAIT":
					row.fallback_portrait_success = true
				var reason := str(capture.get("fallback_reason", ""))
				if not reason.is_empty() and not (row.fallback_reasons as Array).has(reason):
					(row.fallback_reasons as Array).append(reason)
	if bool(row.model_3d_success):
		_summary.model_3d_success = int(_summary.model_3d_success) + 1
	elif bool(row.fallback_portrait_success):
		_summary.fallback_portrait_success = int(_summary.fallback_portrait_success) + 1
	else:
		_summary.fallback_failed = int(_summary.fallback_failed) + 1
	row.erase("model_idle_animation_name")
	row.erase("model_attack_animation_name")
	row.erase("model_run_animation_name")
	return row


func _measure_entry(entry: Dictionary) -> Dictionary:
	_clear_stage()
	var spawned := await _spawn_visual(entry)
	var root := spawned.get("root") as Node3D
	if root != null and str(spawned.get("visual_result", "")) == "MODEL_3D":
		_play_model_action(root, entry, "idle")
		for _frame in 4:
			await get_tree().process_frame
	var bounds := _node3d_bounds(root) if root != null else AABB()
	var frame := _camera_frame_for_bounds(bounds, str(spawned.get("visual_result", "")))
	_set_label(entry, "FRAME", "idle", str(spawned.get("visual_result", "")),
		str(spawned.get("fallback_reason", "")), "camera calibration")
	frame = await _calibrate_camera_frame(frame)
	_clear_stage()
	return frame


func _capture_one(entry: Dictionary, frame: Dictionary, tier: String, state: String) -> Dictionary:
	_clear_stage()
	var spawned := await _spawn_visual(entry)
	var root := spawned.get("root") as Node3D
	var visual_result := str(spawned.get("visual_result", "FALLBACK_FAILED"))
	var fallback_reason := str(spawned.get("fallback_reason", ""))
	var action_source := "FALLBACK_STATIC"
	if root != null and visual_result == "MODEL_3D":
		action_source = _play_model_action(root, entry, state)
		for _frame in 6:
			await get_tree().process_frame
		if _visible_mesh_count(root) == 0:
			fallback_reason = "model_has_no_visible_mesh_for_%s" % state
			_clear_stage()
			spawned = await _spawn_portrait(entry, fallback_reason)
			root = spawned.get("root") as Node3D
			visual_result = str(spawned.get("visual_result", "FALLBACK_FAILED"))
			action_source = "FALLBACK_STATIC"
	if root != null and state == "death" and visual_result == "MODEL_3D":
		_apply_death_midpoint(root)
	_apply_camera_frame(frame)
	_set_label(entry, tier, state, visual_result, fallback_reason, action_source)
	for _frame in 3:
		await RenderingServer.frame_post_draw

	var image := _viewport.get_texture().get_image()
	var material_facts := _collect_material_facts(root) if root != null else {
		"active_surface_count": 0, "final_material_paths": [], "texture_count": 0,
		"white_material_suspect_count": 0,
	}
	var metrics := ImageMetricsScript.analyze(image, BACKGROUND, _policy)
	var image_dir := _output_dir.path_join(tier).path_join(_safe_name(str(entry.capture_id)))
	DirAccess.make_dir_recursive_absolute(image_dir)
	var image_path := image_dir.path_join("%s.png" % state)
	var save_error := image.save_png(image_path) if image != null else ERR_CANT_CREATE
	_h.item()
	if save_error != OK:
		_h.fail("capture_save_failed", "%s/%s/%s 保存失败：%d" % [entry.capture_id, tier, state, save_error])
	else:
		_summary.images_written = int(_summary.images_written) + 1
	if bool(entry.required_3d) and visual_result != "MODEL_3D":
		_h.fail("required_3d_fallback", "%s/%s/%s -> %s (%s)" % [entry.capture_id, tier, state, visual_result, fallback_reason])
	if action_source == "MISSING_ACTION":
		_summary.action_missing = int(_summary.action_missing) + 1
		_h.fail("model_action_missing", "%s/%s 没有可用动作：%s" % [entry.capture_id, state, entry.source_scene])
	for failure in (metrics.get("failures", []) as Array):
		_summary.image_failures = int(_summary.image_failures) + 1
		_h.fail("image_%s" % str(failure), "%s/%s/%s 图像粗筛失败" % [entry.capture_id, tier, state])
	var white_count := int(material_facts.get("white_material_suspect_count", 0))
	if white_count > 0:
		_summary.white_material_suspect = int(_summary.white_material_suspect) + white_count
		_h.fail("active_white_material_suspect", "%s/%s/%s 有 %d 个活动白材质 surface" % [entry.capture_id, tier, state, white_count])
	return {
		"tier": tier,
		"state": state,
		"visual_result": visual_result,
		"fallback_reason": fallback_reason,
		"action_source": action_source,
		"source_scene": str(entry.source_scene),
		"image": _report_path(image_path),
		"image_absolute": image_path,
		"save_error": save_error,
		"material": material_facts,
		"metrics": metrics,
	}


func _spawn_visual(entry: Dictionary) -> Dictionary:
	var model_path := str(entry.source_scene)
	if model_path.is_empty():
		return await _spawn_portrait(entry, "model_path_empty")
	if not ResourceLoader.exists(model_path):
		return await _spawn_portrait(entry, "model_path_missing")
	var scene := ResourceLoader.load(model_path) as PackedScene
	if scene == null:
		return await _spawn_portrait(entry, "model_scene_load_failed")
	var instance := scene.instantiate()
	if not (instance is Node3D):
		if instance != null:
			instance.free()
		return await _spawn_portrait(entry, "model_root_not_node3d")
	var model := instance as Node3D
	_stage.add_child(model)
	_cleanup_imported_visuals(model)
	model.position = Vector3.ZERO
	model.rotation_degrees = Vector3(0.0, float(entry.model_base_yaw), 0.0)
	model.scale = Vector3.ONE * float(entry.model_visual_scale)
	for _frame in 3:
		await get_tree().process_frame
	return {"root": model, "visual_result": "MODEL_3D", "fallback_reason": ""}


func _spawn_portrait(entry: Dictionary, reason: String) -> Dictionary:
	var actor = UnitActor3DScript.new()
	actor.name = "FallbackActor"
	actor.configure_contract(0.98)
	_stage.add_child(actor)
	var success := actor.attach_portrait_fallback(
		str(entry.portrait), str(entry.fallback_frame), Color(0.30, 0.78, 1.0, 0.72), 0.98)
	for _frame in 2:
		await get_tree().process_frame
	return {
		"root": actor,
		"visual_result": "FALLBACK_PORTRAIT" if success else "FALLBACK_FAILED",
		"fallback_reason": reason,
	}


func _play_model_action(model: Node3D, entry: Dictionary, state: String) -> String:
	var requested := state if state in ["idle", "attack"] else "idle"
	var method_name := "play_%s" % requested
	if model.has_method(method_name):
		model.call(method_name)
		if state == "hit":
			return "%s(); STATIC_RUNTIME_HIT_MODEL" % method_name
		if state == "death":
			return "%s(); BATTLE_DEATH_MIDPOINT" % method_name
		return "%s()" % method_name
	var player := _find_animation_player(model)
	var animation_name := _resolve_animation(player, entry, requested)
	if player != null and not animation_name.is_empty():
		player.stop()
		player.play(animation_name)
		player.seek(0.18 if requested == "idle" else 0.24, true)
		player.advance(0.001)
		if state == "hit":
			return "%s; STATIC_RUNTIME_HIT_MODEL" % animation_name
		if state == "death":
			return "%s; BATTLE_DEATH_MIDPOINT" % animation_name
		return animation_name
	return "MISSING_ACTION"


func _resolve_animation(player: AnimationPlayer, entry: Dictionary, action: String) -> String:
	if player == null:
		return ""
	var explicit_name := str(entry.get("model_%s_animation_name" % action, ""))
	if not explicit_name.is_empty() and player.has_animation(explicit_name):
		return explicit_name
	var candidates := ["idle", "breath", "stand", "mixamo_com"] if action == "idle" else ["attack", "punch", "slash", "hit"]
	for animation in player.get_animation_list():
		var lower := str(animation).to_lower()
		for candidate in candidates:
			if lower.contains(candidate):
				return str(animation)
	return ""


func _find_animation_player(root: Node) -> AnimationPlayer:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is AnimationPlayer:
			return node as AnimationPlayer
		for child in node.get_children():
			stack.append(child)
	return null


func _apply_death_midpoint(root: Node3D) -> void:
	# Mirrors BattleVfx.cue_play_death at approximately half of its shipping fade.
	root.position += Vector3(0.0, -0.175, 0.0)
	root.scale *= 0.86
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is GeometryInstance3D:
			(node as GeometryInstance3D).transparency = 0.50


func _camera_frame_for_bounds(bounds: AABB, visual_result: String) -> Dictionary:
	if bounds.size.length() <= 0.001:
		return {
			"target": [0.0, 0.52, 0.0],
			"distance": 3.15 if visual_result == "FALLBACK_PORTRAIT" else 4.2,
			"yaw_deg": 28.0,
			"pitch_deg": 12.0,
			"fov": CAMERA_FOV,
			"bounds": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
		}
	var center := bounds.get_center()
	var span := maxf(bounds.size.y, maxf(bounds.size.x, bounds.size.z)) * 1.42
	var distance := maxf(1.0, span / (2.0 * tan(deg_to_rad(CAMERA_FOV * 0.5))) * 1.18)
	return {
		"target": [center.x, center.y, center.z],
		"distance": distance,
		"yaw_deg": 28.0,
		"pitch_deg": 12.0,
		"fov": CAMERA_FOV,
		"bounds": [bounds.position.x, bounds.position.y, bounds.position.z, bounds.size.x, bounds.size.y, bounds.size.z],
	}


func _apply_camera_frame(frame: Dictionary) -> void:
	var target_values: Array = frame.get("target", [0.0, 0.52, 0.0])
	var target := Vector3(float(target_values[0]), float(target_values[1]), float(target_values[2]))
	var yaw := deg_to_rad(float(frame.get("yaw_deg", 28.0)))
	var pitch := deg_to_rad(float(frame.get("pitch_deg", 12.0)))
	var direction := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	_camera.fov = float(frame.get("fov", CAMERA_FOV))
	_camera.look_at_from_position(target + direction * float(frame.get("distance", 4.2)), target, Vector3.UP)


func _calibrate_camera_frame(initial_frame: Dictionary) -> Dictionary:
	# Imported skinned-mesh AABBs may describe the bind pose rather than the current
	# animation. A small raster feedback loop catches crowns, wings and raised arms
	# without introducing per-model framing exceptions.
	var frame := initial_frame.duplicate(true)
	var resolution := Vector2i(int(_policy.resolution[0]), int(_policy.resolution[1]))
	var safe_rect := Rect2i(64, int(_policy.get("label_height_px", 72)) + 24,
		resolution.x - 128, resolution.y - int(_policy.get("label_height_px", 72)) - 54)
	for _iteration in 3:
		_apply_camera_frame(frame)
		for _draw in 2:
			await RenderingServer.frame_post_draw
		var image := _viewport.get_texture().get_image()
		var metrics: Dictionary = ImageMetricsScript.analyze(image, BACKGROUND, _policy)
		var bounds_value: Array = metrics.get("foreground_bounds", [0, 0, 0, 0])
		if bounds_value.size() < 4 or int(bounds_value[2]) <= 0 or int(bounds_value[3]) <= 0:
			break
		var observed := Rect2i(int(bounds_value[0]), int(bounds_value[1]), int(bounds_value[2]), int(bounds_value[3]))
		var observed_center := observed.get_center()
		var desired_center := safe_rect.get_center()
		var distance := float(frame.get("distance", 4.2))
		var world_height := 2.0 * distance * tan(deg_to_rad(float(frame.get("fov", CAMERA_FOV)) * 0.5))
		var target_values: Array = frame.get("target", [0.0, 0.52, 0.0])
		target_values[1] = float(target_values[1]) + (desired_center.y - observed_center.y) \
			/ float(resolution.y) * world_height
		frame.target = target_values
		var scale_needed := maxf(
			float(observed.size.x) / float(safe_rect.size.x),
			float(observed.size.y) / float(safe_rect.size.y))
		var touches_edge := observed.position.x <= safe_rect.position.x \
			or observed.position.y <= safe_rect.position.y \
			or observed.end.x >= safe_rect.end.x or observed.end.y >= safe_rect.end.y
		if touches_edge:
			scale_needed = maxf(scale_needed, 1.16)
		if scale_needed > 0.92:
			frame.distance = distance * maxf(1.0, scale_needed / 0.88)
	return frame


func _node3d_bounds(root: Node3D) -> AABB:
	if root == null:
		return AABB()
	var bounds := AABB()
	var has_bounds := false
	var root_inverse := root.global_transform.affine_inverse()
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not (node is VisualInstance3D) or not (node as VisualInstance3D).is_visible_in_tree():
			continue
		var visual := node as VisualInstance3D
		var local_box := visual.get_aabb()
		if local_box.size.length() <= 0.0001:
			continue
		var transform := root_inverse * visual.global_transform
		for point in _aabb_corners(local_box):
			var transformed := transform * point
			if not has_bounds:
				bounds = AABB(transformed, Vector3.ZERO)
				has_bounds = true
			else:
				bounds = bounds.expand(transformed)
	return bounds if has_bounds else AABB()


func _aabb_corners(box: AABB) -> Array[Vector3]:
	var p := box.position
	var s := box.size
	return [p, p + Vector3(s.x, 0, 0), p + Vector3(0, s.y, 0), p + Vector3(0, 0, s.z),
		p + Vector3(s.x, s.y, 0), p + Vector3(s.x, 0, s.z), p + Vector3(0, s.y, s.z), p + s]


func _visible_mesh_count(root: Node) -> int:
	var count := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is MeshInstance3D and (node as MeshInstance3D).is_visible_in_tree() \
				and (node as MeshInstance3D).mesh != null:
			count += 1
	return count


func _collect_material_facts(root: Node) -> Dictionary:
	var surfaces := 0
	var texture_paths: Dictionary = {}
	var material_paths: Dictionary = {}
	var white_suspects := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not (node is MeshInstance3D):
			continue
		var mesh_instance := node as MeshInstance3D
		if not mesh_instance.is_visible_in_tree() or mesh_instance.mesh == null:
			continue
		for surface_index in mesh_instance.mesh.get_surface_count():
			surfaces += 1
			var material := _final_material(mesh_instance, surface_index)
			if material == null:
				continue
			var material_path := material.resource_path
			if material_path.is_empty():
				material_path = "<embedded:%s::%s::surface=%d>" % [
					material.get_class(), str(root.get_path_to(mesh_instance)), surface_index]
			material_paths[material_path] = true
			var has_texture := false
			for property_value in material.get_property_list():
				var property: Dictionary = property_value
				if int(property.get("type", TYPE_NIL)) != TYPE_OBJECT:
					continue
				var value: Variant = material.get(str(property.get("name", "")))
				if value is Texture2D:
					has_texture = true
					var texture := value as Texture2D
					var texture_path := texture.resource_path
					texture_paths[texture_path if not texture_path.is_empty() else "<embedded_texture>"] = true
			if material is BaseMaterial3D:
				var base := material as BaseMaterial3D
				if not has_texture and base.albedo_color.r >= 0.97 and base.albedo_color.g >= 0.97 \
						and base.albedo_color.b >= 0.97:
					white_suspects += 1
	return {
		"active_surface_count": surfaces,
		"final_material_paths": material_paths.keys(),
		"texture_paths": texture_paths.keys(),
		"texture_count": texture_paths.size(),
		"white_material_suspect_count": white_suspects,
	}


func _final_material(mesh_instance: MeshInstance3D, surface_index: int) -> Material:
	if mesh_instance.material_override != null:
		return mesh_instance.material_override
	var override := mesh_instance.get_surface_override_material(surface_index)
	if override != null:
		return override
	return mesh_instance.mesh.surface_get_material(surface_index)


func _cleanup_imported_visuals(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node != root and (node is Light3D or node is Camera3D):
			node.free()


func _set_label(entry: Dictionary, tier: String, state: String, visual_result: String,
		fallback_reason: String, action_source: String) -> void:
	var is_fallback := visual_result != "MODEL_3D"
	_label_plate.color = Color(0.42, 0.045, 0.035, 0.94) if is_fallback else Color(0.015, 0.018, 0.022, 0.90)
	var status := visual_result
	if is_fallback and not fallback_reason.is_empty():
		status += " · " + fallback_reason
	_label.text = "%s · %s · %s · %s\n%s · %s" % [
		str(entry.capture_id), tier, state.to_upper(), status,
		str(entry.source_scene), action_source,
	]


func _clear_stage() -> void:
	if _stage == null:
		return
	for child in _stage.get_children():
		_stage.remove_child(child)
		child.free()


func _set_quality_tier(tier: String) -> void:
	match tier:
		"LOW":
			VFXQualityBudgetScript.tier = VFXQualityBudgetScript.Tier.LOW
		"HIGH":
			VFXQualityBudgetScript.tier = VFXQualityBudgetScript.Tier.HIGH
		_:
			VFXQualityBudgetScript.tier = VFXQualityBudgetScript.Tier.MEDIUM


func _requested_tiers() -> Array[String]:
	var tiers := _string_array(_policy.get("quality_tiers", []))
	var requested := _arg_value("--matrix-tier=", "").to_upper()
	if not requested.is_empty():
		if requested in tiers:
			return [requested]
		_h.fail("tier_argument_invalid", "未知质量档：%s" % requested)
	return tiers


func _apply_entry_limit(entries: Array[Dictionary]) -> Array[Dictionary]:
	var raw := _arg_value("--matrix-limit=", "")
	if raw.is_empty() or not raw.is_valid_int():
		return entries
	var limit := clampi(int(raw), 1, entries.size())
	return entries.slice(0, limit)


func _apply_entry_filter(entries: Array[Dictionary]) -> Array[Dictionary]:
	var raw := _arg_value("--matrix-ids=", "")
	if raw.is_empty():
		return entries
	var requested: Array[String] = []
	for value in raw.split(",", false):
		requested.append(str(value).strip_edges())
	var filtered: Array[Dictionary] = []
	for entry in entries:
		if requested.has(str(entry.capture_id)) or requested.has(str(entry.unit_id)):
			filtered.append(entry)
	return filtered


func _resolve_output_dir() -> String:
	var requested := _arg_value("--matrix-output=", "")
	if requested.is_empty():
		requested = DEFAULT_OUTPUT
	return ProjectSettings.globalize_path(requested) if requested.begins_with("res://") or requested.begins_with("user://") else requested


func _ensure_reports_gdignore() -> void:
	var reports_root := ProjectSettings.globalize_path("res://reports")
	if not _output_dir.begins_with(reports_root):
		return
	DirAccess.make_dir_recursive_absolute(reports_root)
	var ignore_path := reports_root.path_join(".gdignore")
	if FileAccess.file_exists(ignore_path):
		return
	var file := FileAccess.open(ignore_path, FileAccess.WRITE)
	if file != null:
		file.store_string("# Generated QA artifacts; do not import into the Godot editor.\n")
		file.close()


func _arg_value(prefix: String, fallback: String) -> String:
	for argument in OS.get_cmdline_user_args():
		var text := str(argument)
		if text.begins_with(prefix):
			return text.substr(prefix.length())
	return fallback


func _select_manual_sample(entries: Array[Dictionary]) -> Array[String]:
	var pool := entries.duplicate(true)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(_policy.get("seed", 20260822))
	var out: Array[String] = []
	var count := mini(int(_policy.get("manual_sample_count", 10)), pool.size())
	while out.size() < count and not pool.is_empty():
		var index := rng.randi_range(0, pool.size() - 1)
		var entry: Dictionary = pool.pop_at(index)
		out.append(str(entry.capture_id))
	out.sort()
	return out


func _write_contact_sheets(tiers: Array[String]) -> Array[Dictionary]:
	var all_pages: Array[Dictionary] = []
	var rows := int(_policy.get("contact_sheet_rows", 4))
	for tier in tiers:
		var tier_paths: Array[String] = []
		for value in (_tier_image_paths.get(tier, []) as Array):
			if not str(value).is_empty():
				tier_paths.append(str(value))
		var output := _output_dir.path_join("contact_sheets").path_join(tier)
		var pages := ImageMetricsScript.write_contact_sheets(tier_paths, output, "models_%s" % tier.to_lower(), rows)
		for page in pages:
			all_pages.append({"tier": tier, "page": _report_path(page)})

		var manual_paths: Array[String] = []
		for model_row in _report_models:
			if not _manual_ids.has(str(model_row.capture_id)):
				continue
			for capture_value in (model_row.captures as Array):
				var capture: Dictionary = capture_value
				if str(capture.tier) == tier:
					manual_paths.append(str(capture.image_absolute))
		var manual_output := _output_dir.path_join("manual_sample_10").path_join(tier)
		var manual_pages := ImageMetricsScript.write_contact_sheets(
			manual_paths, manual_output, "manual_%s" % tier.to_lower(), rows)
		for page in manual_pages:
			all_pages.append({"tier": tier, "manual_sample": true, "page": _report_path(page)})
	return all_pages


func _write_manual_sample(tiers: Array[String], contact_pages: Array[Dictionary]) -> void:
	var rows: Array[Dictionary] = []
	for model_row in _report_models:
		if not _manual_ids.has(str(model_row.capture_id)):
			continue
		var captures: Array[Dictionary] = []
		for capture_value in (model_row.captures as Array):
			var capture: Dictionary = capture_value
			var clean := capture.duplicate(true)
			clean.erase("image_absolute")
			captures.append(clean)
		rows.append({
			"capture_id": str(model_row.capture_id),
			"unit_id": str(model_row.unit_id),
			"source_scene": str(model_row.source_scene),
			"captures": captures,
		})
	var pages: Array = []
	for page in contact_pages:
		if bool(page.get("manual_sample", false)):
			pages.append(page)
	_write_json(_output_dir.path_join("manual_sample_10.json"), {
		"schema_version": 1,
		"seed": int(_policy.seed),
		"requested_count": int(_policy.manual_sample_count),
		"quality_tiers": tiers,
		"capture_ids": _manual_ids,
		"contact_sheets": pages,
		"models": rows,
		"human_validation_status": "PENDING_REVIEW",
	})


func _write_report(tiers: Array[String], states: Array[String], contact_pages: Array[Dictionary], renderer_method: String) -> void:
	var clean_models: Array[Dictionary] = []
	for model_value in _report_models:
		var model: Dictionary = model_value.duplicate(true)
		var clean_captures: Array[Dictionary] = []
		for capture_value in (model.captures as Array):
			var capture: Dictionary = capture_value
			var clean := capture.duplicate(true)
			clean.erase("image_absolute")
			clean_captures.append(clean)
		model.captures = clean_captures
		clean_models.append(model)
	_write_json(_output_dir.path_join("model_visual_matrix.json"), {
		"schema_version": 1,
		"generated_utc": Time.get_datetime_string_from_system(true, false),
		"godot_version": Engine.get_version_info(),
		"renderer_method": renderer_method,
		"display_driver": DisplayServer.get_name(),
		"policy": POLICY_PATH,
		"seed": int(_policy.seed),
		"resolution": _policy.resolution,
		"quality_tiers": tiers,
		"states": states,
		"summary": _summary,
		"manual_sample_ids": _manual_ids,
		"contact_sheets": contact_pages,
		"models": clean_models,
	})


func _write_json(path: String, value: Variant) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_h.fail("report_write_failed", "无法写入：%s" % path)
		return
	file.store_string(JSON.stringify(value, "  "))
	file.close()


func _report_path(absolute_path: String) -> String:
	var localized := ProjectSettings.localize_path(absolute_path)
	return localized if localized.begins_with("res://") or localized.begins_with("user://") else absolute_path


func _safe_name(value: String) -> String:
	var out := value.to_lower()
	for character in ["/", "\\", ":", " ", "|", "?", "*", "<", ">", "\""]:
		out = out.replace(character, "_")
	return out


func _string_array(value: Variant) -> Array[String]:
	var out: Array[String] = []
	if typeof(value) != TYPE_ARRAY:
		return out
	for item in (value as Array):
		out.append(str(item))
	return out
