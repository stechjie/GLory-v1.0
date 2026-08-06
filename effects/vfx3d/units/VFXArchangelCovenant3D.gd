extends Node3D

# Isolated Archangel preview module. It is intentionally not wired into the
# formal UnitSkillVFXComposer until the visual pass is approved.
const VFX_LAYER := preload("res://effects/vfx3d/modules/VFXBossTextureLayer3D.gd")

const DROP_TEXTURE := "res://assets/vfx/skills/god_archangel/god_archangel_drop_v4.png"
const LEFT_TEXTURE := "res://assets/vfx/skills/god_archangel/god_archangel_side_left_v4.png"
const RIGHT_TEXTURE := "res://assets/vfx/skills/god_archangel/god_archangel_side_right_v4.png"
const HIT_TEXTURE := "res://assets/vfx/skills/god_archangel/god_archangel_hit_v4.png"

var _target_node: Node3D
var _target_anchor: Node3D
var _target_offset := Vector3.ZERO

var _dark_tint := Color(.12, .20, .58, 1.0)
var _body_tint := Color(.82, 1.0, 1.28, 1.0)
var _core_tint := Color(1.0, .99, .92, 1.0)

func _process(_delta: float) -> void:
	if is_instance_valid(_target_node) and is_instance_valid(_target_anchor):
		_target_anchor.global_position = _target_node.global_position + _target_offset

func play_covenant(origin: Vector3, target: Vector3, target_node: Node3D = null, demo_hit := true) -> void:
	_clear_previous()
	_target_node = target_node
	_target_anchor = Node3D.new()
	_target_anchor.name = "ArchangelTargetAnchor"
	add_child(_target_anchor)
	_target_offset = target - (target_node.global_position if is_instance_valid(target_node) else target)
	_target_anchor.global_position = target

	var release_from := to_local(origin + Vector3(0.0, 1.82, 0.0))
	var release_to := to_local(target + Vector3(0.0, 0.72, 0.0))
	_make_layer(self, DROP_TEXTURE, {
		"from": release_from,
		"to": release_to,
		"size": Vector2(.30, .86),
		"duration": .42,
		"start_scale": .10,
		"peak_scale": .62,
		"end_scale": .78,
		"travel_ratio": .62,
		"dark_tint": _dark_tint,
		"body_tint": _body_tint,
		"core_tint": _core_tint,
		"seed": 201.0,
		"flow_strength": .028,
		"opacity": .94,
	})

	# The two side strokes stay behind the unit's front silhouette and leave
	# the face, weapon and health bar open. They are target-bound, not caster-bound.
	_make_layer(_target_anchor, LEFT_TEXTURE, {
		"position": Vector3(-.22, .62, .035),
		"size": Vector2(.24, .68),
		"duration": 5.95,
		"start_scale": .08,
		"peak_scale": .62,
		"end_scale": .78,
		"rise": .025,
		"dark_tint": _dark_tint,
		"body_tint": _body_tint,
		"core_tint": _core_tint,
		"seed": 202.0,
		"flow_strength": .018,
		"opacity": .78,
	})
	_make_layer(_target_anchor, RIGHT_TEXTURE, {
		"position": Vector3(.22, .60, .04),
		"size": Vector2(.25, .68),
		"duration": 6.15,
		"start_scale": .08,
		"peak_scale": .58,
		"end_scale": .76,
		"rise": .03,
		"dark_tint": _dark_tint,
		"body_tint": _body_tint,
		"core_tint": _core_tint,
		"seed": 203.0,
		"flow_strength": .016,
		"opacity": .74,
	})

	if demo_hit:
		_demo_hit_pulse()

func pulse_guard() -> void:
	if not is_instance_valid(_target_anchor):
		return
	_make_layer(_target_anchor, HIT_TEXTURE, {
		"position": Vector3(0.0, .60, .055),
		"size": Vector2(.48, .22),
		"duration": .30,
		"start_scale": .12,
		"peak_scale": .72,
		"end_scale": .96,
		"dark_tint": _dark_tint,
		"body_tint": _body_tint,
		"core_tint": _core_tint,
		"seed": 204.0,
		"flow_strength": .024,
		"opacity": .92,
	})

func _demo_hit_pulse() -> void:
	await get_tree().create_timer(.98).timeout
	if is_inside_tree():
		pulse_guard()

func _make_layer(parent: Node3D, texture_path: String, params: Dictionary) -> Node3D:
	var layer: Node3D = VFX_LAYER.new() as Node3D
	if layer == null or parent == null:
		return null
	parent.add_child(layer)
	layer.call("play_layer", texture_path, params)
	return layer

func _clear_previous() -> void:
	for child in get_children():
		if is_instance_valid(child):
			child.queue_free()
	_target_anchor = null
