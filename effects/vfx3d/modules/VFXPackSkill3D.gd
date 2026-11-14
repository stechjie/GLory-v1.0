extends VFXBlockRoot
class_name VFXPackSkill3D

const FLIPBOOK := preload("res://effects/vfx3d/modules/VFXSpriteFlipbook3D.gd")

var _tracked: Array[Dictionary] = []
var _rotating: Array[Dictionary] = []


func play_spec(points: Dictionary, spec: Dictionary, context: Dictionary = {}) -> void:
	begin()
	_tracked.clear()
	_rotating.clear()
	var layers: Array = spec.get("layers", [])
	var lifetime := 0.2
	for layer_value: Variant in layers:
		if not layer_value is Dictionary:
			continue
		var layer := layer_value as Dictionary
		lifetime = maxf(lifetime, float(layer.get("delay", 0.0)) + float(layer.get("duration", 0.7)))
		_spawn_layer_after(points, layer, context)
	set_process(true)
	if not is_inside_tree() or is_queued_for_deletion():
		return
	await get_tree().create_timer(lifetime + 0.08).timeout
	if not is_inside_tree() or is_queued_for_deletion():
		return
	if not _finished:
		finish()


func _spawn_layer_after(points: Dictionary, layer: Dictionary, context: Dictionary) -> void:
	var delay := maxf(0.0, float(layer.get("delay", 0.0)))
	if delay > 0.0:
		if not is_inside_tree() or is_queued_for_deletion():
			return
		await get_tree().create_timer(delay).timeout
		if not is_inside_tree() or is_queued_for_deletion():
			return
	if _finished:
		return
	var path := str(layer.get("path", ""))
	var texture := vfx_texture(path)
	if texture == null:
		push_warning("OGA pack layer missing: %s" % path)
		return
	var anchor_name := str(layer.get("anchor", "target_body"))
	var at: Vector3 = points.get(anchor_name, points.get("target_body", Vector3.ZERO))
	var ground := bool(layer.get("ground", anchor_name.ends_with("ground")))
	# toward_camera：往镜头方向挪多少（世界单位）。立着的大面片和棋子模型重叠时会被模型挡住，
	# 平滑序列帧图层给 0.45 左右；不写就是原来的默认值。
	at += vfx_toward_camera(float(layer.get("toward_camera", 0.025 if ground else 0.11)))
	var effect := FLIPBOOK.new() as VFXSpriteFlipbook3D
	effect.name = str(layer.get("name", "OgaPackLayer"))
	add_child(effect)
	var duration := maxf(0.12, float(layer.get("duration", 0.7)))
	effect.play_flipbook_advanced(at, texture, {
		"columns": int(layer.get("columns", 1)),
		"rows": int(layer.get("rows", 1)),
		"frame_count": int(layer.get("frame_count", 1)),
		"loop": bool(layer.get("loop", false)),
		"random_start": false,
		"speed_min": float(layer.get("fps", 14.0)),
		"speed_max": float(layer.get("fps", 14.0)),
		"billboard": bool(layer.get("billboard", not ground)),
		"duration": duration,
		"color": layer.get("color", Color.WHITE),
		"size": layer.get("size", Vector2.ONE),
		# lift：竖直抬高（世界单位）。pixelfx 平滑序列帧的轴心常在单格下部（脚底），
		# 立着播放时靠它把轴心对到锚点上；旧图层不写这个键，行为不变。
		"position_offset": Vector3(0.0, float(layer.get("lift", 0.0)), 0.0),
		"rotation_radians": float(layer.get("rotation", 0.0)),
		"fade_in": float(layer.get("fade_in", 0.035)),
		"fade_out": float(layer.get("fade_out", 0.14)),
		"emission_scale": float(layer.get("emission_scale", 0.72)),
	})
	if ground:
		effect.rotation.x = -PI * 0.5
	var rotation_speed := float(layer.get("rotation_speed", 0.0))
	if absf(rotation_speed) > 0.001:
		_rotating.append({"effect":effect, "speed":rotation_speed, "angle":float(layer.get("rotation", 0.0))})
	var start_scale := maxf(0.01, float(layer.get("start_scale", 0.36)))
	var peak_scale := maxf(0.01, float(layer.get("peak_scale", 1.0)))
	var end_scale := maxf(0.01, float(layer.get("end_scale", 1.08)))
	effect.scale = Vector3.ONE * start_scale
	var tween := effect.create_tween()
	tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(effect, "scale", Vector3.ONE * peak_scale, duration * 0.34)
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(effect, "scale", Vector3.ONE * end_scale, duration * 0.66)
	# track_target 跟目标走；track_origin 跟施法者走（如巨甲灵套在自己身上的毒甲）。
	var follow_key := ""
	if bool(layer.get("track_target", false)):
		follow_key = "target_node"
	elif bool(layer.get("track_origin", false)):
		follow_key = "origin_node"
	if not follow_key.is_empty():
		var node_value: Variant = context.get(follow_key)
		if is_instance_valid(node_value) and node_value is Node3D:
			# 用图层播放后的实际位置算偏移（含 lift），否则跟随时每帧都会把 lift 冲掉。
			_tracked.append({"effect": effect, "node": weakref(node_value), "offset": effect.position - (node_value as Node3D).global_position})


func _process(delta: float) -> void:
	for entry: Dictionary in _tracked:
		var effect: Variant = entry.get("effect")
		var node_ref: Variant = entry.get("node")
		if not is_instance_valid(effect) or node_ref == null:
			continue
		var node: Variant = node_ref.get_ref()
		if is_instance_valid(node) and node is Node3D:
			(effect as Node3D).position = (node as Node3D).global_position + entry.get("offset", Vector3.ZERO)
	for entry: Dictionary in _rotating:
		var effect: Variant = entry.get("effect")
		if not is_instance_valid(effect):
			continue
		var angle := float(entry.get("angle", 0.0)) + float(entry.get("speed", 0.0)) * delta
		entry["angle"] = angle
		(effect as VFXSpriteFlipbook3D).set_uv_rotation(angle)
