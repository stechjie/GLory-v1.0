extends VFXBlockRoot
class_name VFXShapeDistortion3D

const CURVES := preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")

const DISTORTION_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 dark_color : source_color = vec4(0.02, 0.05, 0.25, 1.0);
uniform vec4 edge_color : source_color = vec4(0.35, 0.9, 1.0, 1.0);
uniform float distortion = 0.14;
uniform float dissolve = 0.0;
uniform vec3 stretch_direction = vec3(1.0, 0.0, 0.0);
uniform float stretch = 0.22;
uniform float opacity = 1.0;
varying float vertex_noise;
void vertex() {
    float n = sin(VERTEX.x * 13.0 + TIME * 5.0) * cos(VERTEX.y * 11.0 - TIME * 4.0) * sin(VERTEX.z * 9.0 + TIME * 3.0);
    VERTEX += NORMAL * n * distortion;
    VERTEX += stretch_direction * dot(VERTEX, stretch_direction) * stretch;
    vertex_noise = n * 0.5 + 0.5;
}
void fragment() {
    vec2 p = UV - vec2(0.5);
    float uv_noise = sin(p.x * 24.0 + TIME * 6.0) * cos(p.y * 19.0 - TIME * 5.0) * 0.5 + 0.5;
    float rim = pow(1.0 - abs(dot(NORMAL, VIEW)), 2.4);
    float dissolve_mask = smoothstep(dissolve - 0.12, dissolve + 0.12, uv_noise * 0.68 + vertex_noise * 0.32);
    vec3 color = mix(dark_color.rgb, edge_color.rgb, rim + uv_noise * 0.26);
    ALBEDO = color;
    EMISSION = color * (2.0 + rim * 3.4);
    ALPHA = clamp((0.34 + rim * 0.72) * dissolve_mask * opacity, 0.0, 0.94);
}
"""

var _material: ShaderMaterial

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	var direction: Vector3 = context.get("direction", Vector3.RIGHT)
	play_distortion(context.get("target", Vector3.ZERO), direction, profile)

func play_distortion(at: Vector3, direction: Vector3, profile: VFXProfile3D = null) -> void:
	begin()
	position = at + Vector3(0.0, 0.38, 0.0)
	var params: Dictionary = profile.parameters if profile != null else {}
	var sphere := SphereMesh.new()
	sphere.radius = (profile.size if profile != null else 0.5) * 0.5
	sphere.height = profile.size if profile != null else 1.0
	sphere.radial_segments = 10
	sphere.rings = 6
	var node := MeshInstance3D.new()
	node.name = "DistortedShape"
	node.mesh = sphere
	_material = ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = DISTORTION_SHADER
	_material.shader = shader
	_material.set_shader_parameter("dark_color", profile.dark_color if profile != null else Color(0.02, 0.05, 0.25))
	_material.set_shader_parameter("edge_color", profile.core_color if profile != null else Color(0.35, 0.9, 1.0))
	_material.set_shader_parameter("distortion", float(params.get("distortion", 0.16)))
	_material.set_shader_parameter("dissolve", 0.0)
	_material.set_shader_parameter("stretch_direction", direction.normalized())
	_material.set_shader_parameter("stretch", float(params.get("stretch", 0.24)))
	_material.set_shader_parameter("opacity", vfx_alpha)
	node.material_override = _material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	var duration := profile.duration if profile != null else 0.9
	CURVES.tween_method(self, _set_dissolve, 0.0, 0.86, duration, "delayed_fade")
	await get_tree().create_timer(duration + 0.05).timeout
	finish()

func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	if _material != null:
		_material.set_shader_parameter("opacity", vfx_alpha)

func _set_dissolve(value: float) -> void:
	if _material != null:
		_material.set_shader_parameter("dissolve", value)
