extends VFXBlockRoot
class_name VFXRibbonTrail3D
const SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")

const RIBBON_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 head_color : source_color = vec4(0.7, 0.98, 1.0, 1.0);
uniform vec4 tail_color : source_color = vec4(0.05, 0.3, 0.9, 1.0);
uniform float strength = 1.0;
uniform float opacity = 1.0;
void fragment() {
    float center = smoothstep(0.50, 0.06, abs(UV.y - 0.5));
    float fade = pow(clamp(1.0 - UV.x, 0.0, 1.0), 1.42);
    float flow = 0.66 + 0.34 * sin(UV.x * 18.0 - TIME * 8.0 + UV.y * 4.0);
    float torn = smoothstep(0.18, 0.56, flow + fade * 0.20);
    vec3 color = mix(tail_color.rgb, head_color.rgb, pow(fade, 0.72));
    float alpha = center * fade * torn * strength * opacity;
    ALBEDO = color;
    EMISSION = color * (2.2 + fade * 2.8);
    ALPHA = clamp(alpha, 0.0, 0.95);
}
"""

var _material: ShaderMaterial

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	play_trail(context.get("target", Vector3.ZERO), context.get("direction", Vector3.RIGHT),
		profile.main_color, profile.trail_length, profile.duration)

func play_trail(origin: Vector3, direction: Vector3, color: Color, length := 1.1, duration := 0.72) -> void:
	begin()
	position = origin
	var normalized := direction.normalized()
	if normalized.length_squared() < 0.001:
		normalized = Vector3.RIGHT
	var ribbon := _make_ribbon(normalized, color, length)
	add_child(ribbon)
	var tween := track_tween(create_tween())
	tween.tween_interval(duration * 0.38)
	tween.tween_property(ribbon.material_override, "shader_parameter/strength", 0.0, duration * 0.62)
	await get_tree().create_timer(duration + 0.05).timeout
	finish()

func _make_ribbon(direction: Vector3, color: Color, length: float) -> MeshInstance3D:
	var side := direction.cross(Vector3.FORWARD)
	if side.length_squared() < 0.001:
		side = direction.cross(Vector3.UP)
	side = side.normalized()
	var vertical := direction.cross(side).normalized()
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var segments := 9
	for i in range(segments + 1):
		var t := float(i) / float(segments)
		var width := lerpf(0.25, 0.012, pow(t, 0.72))
		var point := -direction * length * t
		point += side * sin(t * PI) * 0.12
		point += vertical * sin(t * PI * 1.35) * 0.045
		vertices.append(point - side * width)
		vertices.append(point + side * width)
		uvs.append(Vector2(t, 0.0))
		uvs.append(Vector2(t, 1.0))
		if i < segments:
			var base := i * 2
			indices.append_array(PackedInt32Array([base, base + 1, base + 3, base, base + 3, base + 2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	_material = ShaderMaterial.new()
	_material.shader = SHADER_CACHE.get_shader(RIBBON_SHADER)
	_material.set_shader_parameter("head_color", color.lightened(0.35))
	_material.set_shader_parameter("tail_color", color.darkened(0.36))
	_material.set_shader_parameter("strength", 1.0)
	_material.set_shader_parameter("opacity", vfx_alpha)
	node.material_override = _material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	if _material != null:
		_material.set_shader_parameter("opacity", vfx_alpha)
