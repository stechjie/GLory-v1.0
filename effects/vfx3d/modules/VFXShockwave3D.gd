extends VFXBlockRoot
class_name VFXShockwave3D

const CURVES := preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")

const SHOCKWAVE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 main_color : source_color = vec4(1.0, 0.35, 0.08, 1.0);
uniform float progress = 0.0;
uniform float secondary_delay = 0.18;
uniform float thickness = 0.075;
uniform float distortion = 0.08;
uniform float dissolve = 0.0;
uniform float opacity = 1.0;
float hash21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
void fragment() {
    vec2 p = UV - vec2(0.5);
    float angle = atan(p.y, p.x);
    float r = length(p) * 2.0;
    float wobble = sin(angle * 9.0 + TIME * 4.0) * distortion + sin(angle * 5.0 - TIME * 3.0) * distortion * 0.45;
    float main_radius = progress * 0.92;
    float secondary_progress = clamp((progress - secondary_delay) / max(1.0 - secondary_delay, 0.01), 0.0, 1.0);
    float secondary_radius = secondary_progress * 0.74;
    float main_ring = smoothstep(thickness, 0.008, abs(r + wobble - main_radius));
    float second_ring = smoothstep(thickness * 0.72, 0.009, abs(r - wobble * 0.55 - secondary_radius)) * secondary_progress;
    float front_weight = mix(0.72, 1.0, smoothstep(-0.45, 0.55, p.y));
    float noise = hash21(floor((p + 0.5) * 28.0) + floor(TIME * 12.0));
    float broken = smoothstep(dissolve, dissolve + 0.22, noise + main_ring * 0.62);
    float fade = 1.0 - smoothstep(0.68, 1.0, progress);
    float alpha = (main_ring + second_ring * 0.62) * broken * fade * opacity * front_weight;
    vec3 color = mix(main_color.rgb, vec3(1.0, 0.92, 0.72), main_ring * 0.52);
    ALBEDO = color;
    EMISSION = color * (2.8 + main_ring * 2.1);
    ALPHA = clamp(alpha, 0.0, 0.94);
}
"""

var _material: ShaderMaterial

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	var at: Vector3 = context.get("target", Vector3.ZERO)
	play_shockwave(at, profile)

func play_shockwave(at: Vector3, profile: VFXProfile3D = null) -> void:
	begin()
	var color := profile.main_color if profile != null else Color(1.0, 0.35, 0.08)
	var size := profile.size if profile != null else 1.45
	var duration := profile.duration if profile != null else 0.62
	var params: Dictionary = profile.parameters if profile != null else {}
	position = at + Vector3(0.0, 0.024, 0.0)
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size * 0.72)
	var node := MeshInstance3D.new()
	node.name = "LayeredShockwave"
	node.mesh = quad
	node.rotation_degrees.x = -90.0
	_material = ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SHOCKWAVE_SHADER
	_material.shader = shader
	_material.set_shader_parameter("main_color", color)
	_material.set_shader_parameter("progress", 0.0)
	_material.set_shader_parameter("secondary_delay", float(params.get("secondary_delay", 0.20)))
	_material.set_shader_parameter("thickness", float(params.get("thickness", 0.075)))
	_material.set_shader_parameter("distortion", float(params.get("distortion", 0.075)))
	_material.set_shader_parameter("dissolve", float(params.get("dissolve", 0.20)))
	_material.set_shader_parameter("opacity", vfx_alpha)
	node.material_override = _material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	CURVES.tween_method(self, _set_progress, 0.0, 1.0, duration, profile.curve_name if profile != null else "explosive_out")
	await get_tree().create_timer(duration + 0.06).timeout
	finish()

func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	if _material != null:
		_material.set_shader_parameter("opacity", vfx_alpha)

func _set_progress(value: float) -> void:
	if _material != null:
		_material.set_shader_parameter("progress", value)
