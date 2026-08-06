extends VFXBlockRoot
class_name VFXArbiterGroundBrush3D

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 dark_color : source_color;
uniform vec4 core_color : source_color;
uniform float progress = 0.0;
uniform float opacity = 1.0;
uniform float seed = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float brush_segment(vec2 p, vec2 a, vec2 b, float width) {
	vec2 ab = b - a;
	float h = clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0);
	vec2 q = p - (a + ab * h);
	float rough = (hash21(floor((p + seed) * 28.0)) - 0.5) * 0.035;
	float taper = smoothstep(0.02, 0.16, h) * (1.0 - smoothstep(0.84, 0.99, h));
	return (1.0 - smoothstep(width - 0.025 + rough, width + 0.055 + rough, length(q))) * taper;
}

void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float s1 = brush_segment(p, vec2(-0.78, -0.30), vec2(-0.38, -0.08), 0.125);
	float s2 = brush_segment(p, vec2(-0.18, 0.08), vec2(0.18, 0.24), 0.155);
	float s3 = brush_segment(p, vec2(0.40, -0.24), vec2(0.68, -0.02), 0.095);
	float s1_core = brush_segment(p, vec2(-0.74, -0.29), vec2(-0.40, -0.09), 0.065);
	float s2_core = brush_segment(p, vec2(-0.14, 0.09), vec2(0.15, 0.23), 0.082);
	float s3_core = brush_segment(p, vec2(0.43, -0.23), vec2(0.65, -0.03), 0.048);
	float body = max(s1, max(s2, s3));
	float core = max(s1_core, max(s2_core, s3_core));
	float chips = smoothstep(0.040, 0.0, length(p - vec2(-0.36, -0.30))) + smoothstep(0.032, 0.0, length(p - vec2(0.18, 0.34))) + smoothstep(0.026, 0.0, length(p - vec2(0.63, -0.02)));
	float birth = smoothstep(0.0, 0.16, progress);
	float fade = 1.0 - smoothstep(0.62, 1.0, progress);
	float life = birth * fade;
	vec3 color = mix(dark_color.rgb, core_color.rgb, core);
	color = mix(color, vec3(1.0, 0.98, 0.86), core * 0.72);
	float alpha = clamp((body * 0.82 + core * 0.28 + chips * 0.42) * life * opacity, 0.0, 0.94);
	ALBEDO = color;
	EMISSION = color * (0.72 + core * 2.6);
	ALPHA = alpha;
}
"""

var _material: ShaderMaterial

func play_brush(at: Vector3, duration := 0.92) -> void:
	begin()
	position = at + Vector3(0.0, 0.028, 0.0)
	var quad := QuadMesh.new()
	quad.size = Vector2(1.72, 0.92)
	var art := MeshInstance3D.new()
	art.name = "ArbiterBrokenGroundBrush"
	art.mesh = quad
	art.rotation_degrees.x = -90.0
	art.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_material = ShaderMaterial.new()
	_material.shader = Shader.new()
	_material.shader.code = SHADER_CODE
	_material.set_shader_parameter("dark_color", Color(0.34, 0.16, 0.025, 1.0))
	_material.set_shader_parameter("core_color", Color(0.98, 0.66, 0.16, 1.0))
	_material.set_shader_parameter("seed", 23.7)
	_material.set_shader_parameter("opacity", vfx_alpha)
	art.material_override = _material
	add_child(art)
	art.scale = Vector3.ONE * 0.78
	var reveal := track_tween(create_tween())
	reveal.tween_property(art, "scale", Vector3.ONE, duration * 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	var progress := track_tween(create_tween())
	progress.tween_method(func(value: float) -> void:
		if is_instance_valid(_material): _material.set_shader_parameter("progress", value), 0.0, 1.0, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await get_tree().create_timer(duration + 0.04).timeout
	if not _finished: finish()

func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	if is_instance_valid(_material): _material.set_shader_parameter("opacity", vfx_alpha)
