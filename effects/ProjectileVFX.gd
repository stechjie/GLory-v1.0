extends Node2D
class_name ProjectileVFX

var target_node: Node
var target_position := Vector2.ZERO
var speed := 980.0
var effect_id := "PROJECTILE_ARROW"
var impact_id := "HIT_RANGED"
var color := Color(0.78, 0.92, 1.0, 1.0)
var size := 1.0
var texture_path := ""
var texture_scale := 0.5
var impact_textures: Array = []
var head_textures: Array = []
var foot_textures: Array = []
var _trail: Line2D

func play(config: Dictionary = {}) -> void:
	target_node = config.get("target_node", null)
	target_position = config.get("target_position", target_position)
	speed = float(config.get("speed", speed))
	effect_id = str(config.get("effect_id", effect_id))
	impact_id = str(config.get("impact_id", impact_id))
	color = config.get("color", Color(0.78, 0.92, 1.0, 1.0))
	size = float(config.get("size", 1.0))
	texture_path = str(config.get("texture_path", texture_path))
	texture_scale = float(config.get("texture_scale", texture_scale))
	impact_textures = config.get("impact_textures", [])
	head_textures = config.get("head_textures", [])
	foot_textures = config.get("foot_textures", [])
	_build()
	set_process(true)

func _build() -> void:
	_trail = Line2D.new()
	_trail.name = "Trail"
	_trail.width = 5.0 * size
	_trail.default_color = Color(color.r, color.g, color.b, 0.72)
	_trail.points = PackedVector2Array([Vector2(-28.0, 0.0), Vector2(8.0, 0.0)])
	_trail.material = _add_material()
	add_child(_trail)

	if not texture_path.is_empty():
		var texture := VFXManager.get_texture(texture_path)
		if texture != null:
			var glow := Sprite2D.new()
			glow.texture = texture
			glow.scale = Vector2.ONE * texture_scale * 1.45
			glow.modulate = Color(color.r, color.g, color.b, 0.34)
			glow.z_index = 29
			glow.material = _add_material()
			add_child(glow)

			var sprite := Sprite2D.new()
			sprite.texture = texture
			sprite.scale = Vector2.ONE * texture_scale
			sprite.modulate = color
			sprite.z_index = 30
			sprite.material = _add_material()
			add_child(sprite)
			return

	var head := Polygon2D.new()
	head.name = "Head"
	head.color = color
	if effect_id == "PROJECTILE_ARROW":
		head.polygon = PackedVector2Array([Vector2(16.0, 0.0), Vector2(-6.0, -6.0), Vector2(-1.0, 0.0), Vector2(-6.0, 6.0)])
	else:
		head.polygon = _circle_polygon(9.0, 18)
	add_child(head)

func _process(delta: float) -> void:
	var target := _target_position()
	var diff := target - global_position
	var dist := diff.length()
	if dist <= maxf(12.0, speed * delta):
		global_position = target
		_impact()
		return
	rotation = diff.angle()
	global_position += diff.normalized() * speed * delta

func _target_position() -> Vector2:
	if target_node != null and is_instance_valid(target_node):
		if target_node is Node2D:
			return (target_node as Node2D).global_position
		if target_node is Control:
			var c := target_node as Control
			return c.global_position + c.size * 0.5
	return target_position

func _impact() -> void:
	if has_node("/root/VFXManager"):
		get_node("/root/VFXManager").spawn_vfx(impact_id, global_position)
		if not impact_textures.is_empty():
			get_node("/root/VFXManager").spawn_vfx("SKILL_TEXTURE", global_position, {"textures": impact_textures})
		if not head_textures.is_empty():
			get_node("/root/VFXManager").spawn_vfx("SKILL_TEXTURE", _target_anchor_position("HeadAnchor", global_position), {"textures": head_textures})
		if not foot_textures.is_empty():
			get_node("/root/VFXManager").spawn_vfx("SKILL_TEXTURE", _target_anchor_position("FootAnchor", global_position), {"textures": foot_textures})
	queue_free()

func _target_anchor_position(anchor_name: String, fallback: Vector2) -> Vector2:
	if target_node == null or not is_instance_valid(target_node):
		return fallback
	var parent := target_node.get_parent()
	if parent == null:
		return fallback
	var anchor := parent.get_node_or_null(anchor_name)
	if anchor is Node2D:
		return (anchor as Node2D).global_position
	if anchor is Control:
		var c := anchor as Control
		return c.global_position + c.size * 0.5
	return fallback

func _add_material() -> CanvasItemMaterial:
	# 共享材质：按混合模式二选一，不再每个精灵 new 一份。
	return VFXManager.MAT_MIX if color.r + color.g + color.b < 0.18 else VFXManager.MAT_ADD

func _circle_polygon(radius: float, segments: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in segments:
		var angle := TAU * float(i) / float(segments)
		points.append(Vector2(cos(angle), sin(angle)) * radius)
	return points
