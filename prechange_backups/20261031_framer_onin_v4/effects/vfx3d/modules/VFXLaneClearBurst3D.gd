extends VFXBlockRoot
## One ground quad clips the entire shockwave to the actual local lane.
## Bounds use VFX-root X/Z coordinates, including the arena's replay flip.
const PRESENTATION := preload("res://effects/runtime/presentation/PresentationSettings.gd")

func play_clear(origin: Vector3, bounds: Rect2) -> void:
	begin()
	var plane := MeshInstance3D.new()
	plane.name = "LaneClippedWave"
	plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = bounds.size
	plane.mesh = quad
	plane.rotation.x = -PI * 0.5
	plane.position = Vector3(bounds.get_center().x, origin.y + 0.035, bounds.get_center().y)
	var material := ShaderMaterial.new()
	material.shader = preload("res://shaders/lane_clear_wave.gdshader")
	material.set_shader_parameter("progress", 0.0)
	material.set_shader_parameter("world_size", bounds.size)
	var uv := (Vector2(origin.x, origin.z) - bounds.position) / bounds.size
	material.set_shader_parameter("origin_uv", uv.clamp(Vector2.ZERO, Vector2.ONE))
	material.set_shader_parameter("opacity", 1.0 if PRESENTATION.flash_allowed() else 0.35)
	plane.material_override = material
	add_child(plane)
	var tween := track_tween(create_tween())
	tween.tween_property(material, "shader_parameter/progress", 1.0, 0.68).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_callback(finish)
