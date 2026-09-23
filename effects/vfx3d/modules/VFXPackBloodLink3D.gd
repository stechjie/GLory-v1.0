extends VFXBlockRoot
class_name VFXPackBloodLink3D

const FLIPBOOK := preload("res://effects/vfx3d/modules/VFXSpriteFlipbook3D.gd")
const LINK_TEXTURE := "res://assets/vfx/oga/skill_packs/blood_link.png"
const BLOOM_TEXTURE := "res://assets/vfx/oga/skill_packs/blood_bloom.png"

var _origin_ref: WeakRef
var _target_ref: WeakRef
var _origin_fallback := Vector3.ZERO
var _target_fallback := Vector3.ZERO
var _body: VFXSpriteFlipbook3D
var _target_bloom: VFXSpriteFlipbook3D
var _persistent := false


func play_link(origin: Vector3, target: Vector3, context: Dictionary = {}) -> void:
	begin()
	_origin_fallback = origin
	_target_fallback = target
	_origin_ref = _weak_node(context.get("origin_node"))
	_target_ref = _weak_node(context.get("target_node"))
	_persistent = bool(context.get("persistent", false))
	_body = FLIPBOOK.new() as VFXSpriteFlipbook3D
	_body.name = "OgaBloodLinkBody"
	add_child(_body)
	_body.play_flipbook_advanced(Vector3.ZERO, vfx_texture(LINK_TEXTURE), {
		"columns":5, "rows":1, "frame_count":5, "loop":true,
		"speed_min":12.0, "speed_max":12.0, "billboard":true,
		"duration":8.0 if _persistent else 1.35,
		"color":Color(1.0,0.72,0.76,0.94), "size":Vector2(1.0,0.34),
		"position_offset":Vector3.ZERO,
	})
	_target_bloom = FLIPBOOK.new() as VFXSpriteFlipbook3D
	_target_bloom.name = "OgaBloodLinkTarget"
	add_child(_target_bloom)
	_target_bloom.play_flipbook_advanced(target, vfx_texture(BLOOM_TEXTURE), {
		"columns":5, "rows":1, "frame_count":5, "loop":true,
		"speed_min":9.0, "speed_max":9.0, "billboard":true,
		"duration":8.0 if _persistent else 1.35,
		"color":Color(0.92,0.32,0.44,0.82), "size":Vector2(0.62,0.62),
		"position_offset":Vector3.ZERO,
	})
	set_process(true)
	_update_link()
	if not _persistent:
		await get_tree().create_timer(1.35).timeout
		if not _finished:
			finish()


func release_link() -> void:
	if _finished:
		return
	if is_instance_valid(_body):
		_body.finish()
	if is_instance_valid(_target_bloom):
		_target_bloom.finish()
	finish()


func _process(_delta: float) -> void:
	_update_link()


func _update_link() -> void:
	if not is_instance_valid(_body):
		return
	var origin := _node_position(_origin_ref, _origin_fallback)
	var target := _node_position(_target_ref, _target_fallback)
	var midpoint := origin.lerp(target, 0.5) + vfx_toward_camera(0.13)
	var distance := maxf(0.35, origin.distance_to(target))
	_body.position = midpoint
	_body.scale = Vector3(distance, 1.0, 1.0)
	_body.set_uv_rotation(_screen_facing(origin, target))
	if is_instance_valid(_target_bloom):
		_target_bloom.position = target + vfx_toward_camera(0.14)


func _weak_node(value: Variant) -> WeakRef:
	if is_instance_valid(value) and value is Node3D:
		return weakref(value)
	return null


func _node_position(ref: WeakRef, fallback: Vector3) -> Vector3:
	if ref == null:
		return fallback
	var node: Variant = ref.get_ref()
	if is_instance_valid(node) and node is Node3D:
		return (node as Node3D).global_position + Vector3(0.0, 0.55, 0.0)
	return fallback


func _screen_facing(from: Vector3, to: Vector3) -> float:
	var direction := to - from
	var screen_y := direction.y * 0.688 - direction.z * 0.726
	return atan2(screen_y, direction.x)

