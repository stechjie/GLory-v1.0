extends VFXBlockRoot
class_name VFXGroundResidue3D

const RESIDUE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 main_color : source_color = vec4(0.2, 0.7, 1.0, 1.0);
uniform float progress = 0.0;
uniform float opacity = 1.0;
float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
void fragment() {
    vec2 p = UV - vec2(0.5);
    float r = length(p) * 2.0;
    float angle = atan(p.y, p.x);
    float cracks = pow(max(0.0, cos(angle * 7.0 + sin(r * 13.0) * 1.2)), 18.0);
    cracks *= smoothstep(0.10, 0.34, r) * smoothstep(1.0, 0.44, r);
    float broken_ring = smoothstep(0.12, 0.025, abs(r - 0.62 - sin(angle * 5.0) * 0.06));
    float noise = hash21(floor((p + 0.5) * 18.0));
    float mask = (cracks + broken_ring * 0.48) * mix(0.62, 1.0, noise);
    float fade = 1.0 - smoothstep(0.25, 1.0, progress);
    ALBEDO = main_color.rgb;
    EMISSION = main_color.rgb * (2.0 + cracks * 2.2);
    ALPHA = clamp(mask * fade * opacity, 0.0, 0.84);
}
"""

var _material: ShaderMaterial

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	play_residue(context.get("target", Vector3.ZERO), profile.main_color, profile.size, profile.duration)

func play_residue(at: Vector3, color: Color, size := 1.25, duration := 1.15) -> void:
	begin()
	position = at + Vector3(0.0, 0.022, 0.0)
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var node := MeshInstance3D.new()
	node.name = "GroundResidue"
	node.mesh = quad
	node.rotation_degrees.x = -90.0
	_material = ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = RESIDUE_SHADER
	_material.shader = shader
	_material.set_shader_parameter("main_color", color)
	_material.set_shader_parameter("progress", 0.0)
	_material.set_shader_parameter("opacity", vfx_alpha)
	node.material_override = _material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	var tween := track_tween(create_tween())
	tween.tween_interval(duration * 0.22)
	tween.tween_property(_material, "shader_parameter/progress", 1.0, duration * 0.78)
	await get_tree().create_timer(duration + 0.05).timeout
	finish()

func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	if _material != null:
		_material.set_shader_parameter("opacity", vfx_alpha)
