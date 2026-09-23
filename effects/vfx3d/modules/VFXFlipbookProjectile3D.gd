extends VFXBlockRoot
class_name VFXFlipbookProjectile3D

const FLIPBOOK := preload("res://effects/vfx3d/modules/VFXSpriteFlipbook3D.gd")

const MIN_TRAVEL_TIME := 0.24
const MAX_TRAVEL_TIME := 0.82

var _target_ref: WeakRef
var _target_offset := Vector3.ZERO

func play_spec(origin: Vector3, target: Vector3, spec: Dictionary, context: Dictionary = {}) -> void:
	begin()
	var texture := vfx_texture(str(spec.get("path", "")))
	if texture == null:
		push_warning("OGA projectile texture missing: %s" % str(spec.get("path", "")))
		finish()
		return
	var speed := maxf(0.5, float(spec.get("speed", 7.0)))
	var travel_time := clampf(origin.distance_to(target) / speed, MIN_TRAVEL_TIME, MAX_TRAVEL_TIME)
	_bind_target(context.get("target_node"), target)
	var body := FLIPBOOK.new() as VFXSpriteFlipbook3D
	body.name = "OgaProjectileBody"
	add_child(body)
	body.play_flipbook_advanced(origin, texture, {
		"columns":int(spec.get("columns", 1)),
		"rows":int(spec.get("rows", 1)),
		"frame_count":int(spec.get("frame_count", 1)),
		"loop":true,
		"random_start":false,
		"speed_min":float(spec.get("fps", 14.0)),
		"speed_max":float(spec.get("fps", 14.0)),
		"billboard":true,
		"duration":travel_time + 0.16,
		"color":spec.get("color", Color.WHITE),
		"size":spec.get("size", Vector2(0.72, 0.72)),
		"position_offset":Vector3.ZERO,
		"rotation_radians":_screen_facing(origin, target),
	})
	var elapsed := 0.0
	var arc_height := maxf(0.0, float(spec.get("arc_height", 0.0)))
	var wobble := maxf(0.0, float(spec.get("wobble", 0.0)))
	while elapsed < travel_time:
		await get_tree().process_frame
		if _finished or not is_instance_valid(body):
			return
		elapsed += get_process_delta_time()
		var destination := _tracked_target(target)
		var ratio := clampf(elapsed / travel_time, 0.0, 1.0)
		var lift := arc_height * sin(ratio * PI)
		var flutter := wobble * sin(ratio * TAU * 2.0)
		body.position = origin.lerp(destination, ratio) + Vector3(0.0, lift + flutter, 0.0) + vfx_toward_camera(0.10)
		body.set_uv_rotation(_screen_facing(body.position, destination))
	if is_instance_valid(body):
		body.finish()
	_play_impact(_tracked_target(target), spec)
	var impact_duration := maxf(0.18, float(spec.get("impact_duration", 0.46)))
	await get_tree().create_timer(impact_duration).timeout
	if not _finished:
		finish()

func _play_impact(at: Vector3, spec: Dictionary) -> void:
	var impact_texture := vfx_texture(str(spec.get("impact_path", "")))
	if impact_texture == null:
		return
	var impact := FLIPBOOK.new() as VFXSpriteFlipbook3D
	impact.name = "OgaProjectileImpact"
	add_child(impact)
	var duration := maxf(0.18, float(spec.get("impact_duration", 0.46)))
	impact.play_flipbook_advanced(at + vfx_toward_camera(0.12), impact_texture, {
		"columns":int(spec.get("impact_columns", 1)),
		"rows":int(spec.get("impact_rows", 1)),
		"frame_count":int(spec.get("impact_frames", 1)),
		"loop":false,
		"random_start":false,
		"speed_min":float(spec.get("impact_fps", 16.0)),
		"speed_max":float(spec.get("impact_fps", 16.0)),
		"billboard":true,
		"duration":duration,
		"color":spec.get("impact_color", spec.get("color", Color.WHITE)),
		"size":spec.get("impact_size", Vector2(0.82, 0.82)),
		"position_offset":Vector3.ZERO,
	})

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
		return PI * 0.5
	return atan2(screen_y, direction.x)
