extends VFXBlockRoot
class_name VFXFlipbookMelee3D

const FLIPBOOK := preload("res://effects/vfx3d/modules/VFXSpriteFlipbook3D.gd")

var _target_ref: WeakRef
var _target_offset := Vector3.ZERO

func play_spec(origin: Vector3, target: Vector3, spec: Dictionary, context: Dictionary = {}) -> void:
	begin()
	var slash_texture := vfx_texture(str(spec.get("path", "")))
	if slash_texture == null:
		push_warning("OGA melee texture missing: %s" % str(spec.get("path", "")))
		finish()
		return
	var target_height := maxf(0.36, float(context.get("target_height", 0.72)))
	var height_ratio := clampf(float(spec.get("height_ratio", 0.40)), 0.28, 0.56)
	var target_foot: Vector3 = context.get("target_foot", target - Vector3(0.0, target_height * height_ratio, 0.0))
	var slash_anchor := target_foot + Vector3(0.0, target_height * height_ratio, 0.0)
	_bind_target(context.get("target_node"), slash_anchor)
	var slash := FLIPBOOK.new() as VFXSpriteFlipbook3D
	slash.name = "OgaMeleeSlash"
	add_child(slash)
	var slash_offset := vfx_toward_camera(0.10)
	var current_target := _tracked_target(slash_anchor)
	slash.play_flipbook_advanced(current_target + slash_offset, slash_texture, {
		"columns":int(spec.get("columns", 6)),
		"rows":int(spec.get("rows", 1)),
		"frame_count":int(spec.get("frame_count", 6)),
		"loop":false,
		"random_start":false,
		"speed_min":float(spec.get("fps", 18.0)),
		"speed_max":float(spec.get("fps", 18.0)),
		"billboard":true,
		"duration":float(spec.get("duration", 0.42)),
		"color":spec.get("color", Color.WHITE),
		"size":spec.get("size", Vector2(1.10, 1.06)),
		"position_offset":Vector3.ZERO,
		"rotation_radians":_screen_facing(origin, current_target),
		"fade_in":0.025,
		"fade_out":0.10,
		"emission_scale":float(spec.get("emission_scale", 0.82)),
	})
	var impact_delay := maxf(0.0, float(spec.get("impact_delay", 0.10)))
	var elapsed := 0.0
	while elapsed < impact_delay:
		await get_tree().process_frame
		if _finished:
			return
		elapsed += get_process_delta_time()
		if is_instance_valid(slash):
			current_target = _tracked_target(slash_anchor)
			slash.position = current_target + slash_offset
	var tracked_ground := _tracked_target(slash_anchor) - Vector3(0.0, target_height * height_ratio, 0.0)
	_play_impact(tracked_ground, spec)
	var total_duration := maxf(float(spec.get("duration", 0.42)), impact_delay + float(spec.get("impact_duration", 0.40)))
	await get_tree().create_timer(maxf(0.05, total_duration - impact_delay)).timeout
	if not _finished:
		finish()

func _play_impact(at: Vector3, spec: Dictionary) -> void:
	var texture := vfx_texture(str(spec.get("impact_path", "")))
	if texture == null:
		return
	var impact := FLIPBOOK.new() as VFXSpriteFlipbook3D
	impact.name = "OgaMeleeImpact"
	add_child(impact)
	impact.play_flipbook_advanced(at + vfx_toward_camera(0.025), texture, {
		"columns":int(spec.get("impact_columns", 1)),
		"rows":int(spec.get("impact_rows", 1)),
		"frame_count":int(spec.get("impact_frames", 1)),
		"loop":false,
		"random_start":false,
		"speed_min":float(spec.get("impact_fps", 16.0)),
		"speed_max":float(spec.get("impact_fps", 16.0)),
		"billboard":false,
		"duration":float(spec.get("impact_duration", 0.40)),
		"color":spec.get("impact_color", Color.WHITE),
		"size":spec.get("impact_size", Vector2(0.76, 0.76)),
		"position_offset":Vector3.ZERO,
		"fade_in":0.02,
		"fade_out":0.12,
		"emission_scale":float(spec.get("impact_emission_scale", 0.58)),
	})
	impact.rotation.x = -PI * 0.5

func _bind_target(node_value: Variant, target: Vector3) -> void:
	_target_ref = null
	if not (is_instance_valid(node_value) and node_value is Node3D):
		return
	_target_ref = weakref(node_value)
	_target_offset = target - (node_value as Node3D).global_position

func _tracked_target(fallback: Vector3) -> Vector3:
	if _target_ref == null:
		return fallback
	var node: Variant = _target_ref.get_ref()
	if not (is_instance_valid(node) and node is Node3D):
		return fallback
	return (node as Node3D).global_position + _target_offset

func _screen_facing(from: Vector3, to: Vector3) -> float:
	var direction := to - from
	var screen_y := direction.y * 0.688 - direction.z * 0.726
	if absf(direction.x) < 0.0001 and absf(screen_y) < 0.0001:
		return 0.0
	return atan2(screen_y, direction.x)
