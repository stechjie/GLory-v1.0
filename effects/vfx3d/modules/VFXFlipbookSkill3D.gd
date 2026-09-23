extends VFXBlockRoot
class_name VFXFlipbookSkill3D

const FLIPBOOK := preload("res://effects/vfx3d/modules/VFXSpriteFlipbook3D.gd")

var _anchor_ref: WeakRef
var _anchor_offset := Vector3.ZERO

func play_spec(anchor: Vector3, spec: Dictionary, context: Dictionary = {}) -> void:
	begin()
	var texture := vfx_texture(str(spec.get("path", "")))
	if texture == null:
		push_warning("OGA skill texture missing: %s" % str(spec.get("path", "")))
		finish()
		return
	_bind_anchor(context.get("track_node"), anchor)
	var effect := FLIPBOOK.new() as VFXSpriteFlipbook3D
	effect.name = "OgaFormalSkill"
	add_child(effect)
	var ground := bool(spec.get("ground", false))
	var duration := maxf(0.12, float(spec.get("duration", 0.8)))
	effect.play_flipbook_advanced(anchor + vfx_toward_camera(0.10 if not ground else 0.025), texture, {
		"columns":int(spec.get("columns", 1)),
		"rows":int(spec.get("rows", 1)),
		"frame_count":int(spec.get("frame_count", 1)),
		"loop":bool(spec.get("loop", false)),
		"random_start":false,
		"speed_min":float(spec.get("fps", 14.0)),
		"speed_max":float(spec.get("fps", 14.0)),
		"billboard":bool(spec.get("billboard", not ground)),
		"duration":duration,
		"color":spec.get("color", Color.WHITE),
		"size":spec.get("size", Vector2.ONE),
		"position_offset":Vector3.ZERO,
	})
	if ground:
		effect.rotation.x = -PI * 0.5
	var elapsed := 0.0
	while elapsed < duration:
		await get_tree().process_frame
		if _finished:
			return
		elapsed += get_process_delta_time()
		if bool(spec.get("track_target", false)) and is_instance_valid(effect):
			effect.position = _tracked_anchor(anchor) + vfx_toward_camera(0.10)
	if is_instance_valid(effect):
		effect.finish()
	if not _finished:
		finish()

func _bind_anchor(node_value: Variant, anchor: Vector3) -> void:
	_anchor_ref = null
	if not (is_instance_valid(node_value) and node_value is Node3D):
		return
	_anchor_ref = weakref(node_value)
	_anchor_offset = anchor - (node_value as Node3D).global_position

func _tracked_anchor(fallback: Vector3) -> Vector3:
	if _anchor_ref == null:
		return fallback
	var node: Variant = _anchor_ref.get_ref()
	if not (is_instance_valid(node) and node is Node3D):
		return fallback
	return (node as Node3D).global_position + _anchor_offset
