extends Node3D

# New mercenary visual runtime. It uses only Godot Sprite3D and newly authored
# textures; no retired skill composer or shared visual block is instantiated.
const TEXTURE_ROOT := "res://assets/vfx/skills/mercenary_rework/"
const QUALITY_BUDGET := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")

var _duration := 1.0
var _age := 0.0
var _follows: Array[Dictionary] = []

func _process(delta: float) -> void:
	_age += delta
	for entry in _follows:
		var sprite_value: Variant = entry.get("sprite")
		var anchor_value: Variant = entry.get("anchor")
		if not is_instance_valid(sprite_value):
			continue
		var sprite := sprite_value as Sprite3D
		if not is_instance_valid(anchor_value):
			sprite.visible = false
			continue
		var anchor := anchor_value as Node3D
		if not anchor.is_visible_in_tree():
			sprite.visible = false
			continue
		sprite.visible = not bool(sprite.get_meta("status_suppressed", false))
		sprite.global_position = anchor.global_position + entry.get("offset", Vector3.ZERO)
	if _duration >= 0.0 and _age >= _duration:
		queue_free()

func _sprite(texture_name: String, world: Vector3, width: float, alpha: float = 1.0, anchor: Node3D = null, offset: Vector3 = Vector3.ZERO) -> Sprite3D:
	var tex := load(TEXTURE_ROOT + texture_name) as Texture2D
	if tex == null:
		push_warning("Missing mercenary VFX texture: " + texture_name)
		return null
	var sprite := Sprite3D.new()
	sprite.texture = tex
	# These effects use no particles or dynamic lights. Low quality slightly
	# reduces transparent coverage while retaining every gameplay cue.
	var quality_scale := 0.92 if QUALITY_BUDGET.tier == QUALITY_BUDGET.Tier.LOW else 1.0
	sprite.pixel_size = width * quality_scale / maxf(1.0, float(tex.get_width()))
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.shaded = false
	sprite.double_sided = true
	sprite.modulate = Color(1.0, 1.0, 1.0, alpha)
	add_child(sprite)
	sprite.global_position = world
	if is_instance_valid(anchor):
		_follows.append({"sprite": sprite, "anchor": anchor, "offset": offset})
	return sprite

func _fade(sprite: Sprite3D, seconds: float, from_scale: float = 0.8, to_scale: float = 1.2) -> void:
	if sprite == null:
		return
	var tween := create_tween().set_parallel(true)
	tween.tween_property(sprite, "scale", Vector3.ONE * to_scale, seconds).from(Vector3.ONE * from_scale)
	tween.tween_property(sprite, "modulate", Color(1.0, 1.0, 1.0, 0.0), seconds)

func _target_anchor(context: Dictionary) -> Node3D:
	var value: Variant = context.get("target_node")
	return value as Node3D if is_instance_valid(value) and value is Node3D else null

func _origin_anchor(context: Dictionary) -> Node3D:
	var value: Variant = context.get("origin_node")
	return value as Node3D if is_instance_valid(value) and value is Node3D else null

func _group_anchor(context: Dictionary, index: int) -> Node3D:
	var nodes: Array = context.get("target_nodes", [])
	if index < 0 or index >= nodes.size():
		return null
	var value: Variant = nodes[index]
	return value as Node3D if is_instance_valid(value) and value is Node3D else null
