extends VFXBlockRoot
class_name VFXArbiterGuardFragments3D

const GUARD_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 edge_color : source_color;
uniform vec4 core_color : source_color;
uniform float progress = 0.0;
uniform float opacity = 1.0;
uniform float seed = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(127.1, 311.7));
	return fract(sin(dot(p, vec2(41.3, 17.7))) * 43758.5453);
}

float brush_segment(vec2 p, vec2 a, vec2 b, float width) {
	vec2 ab = b - a;
	float h = clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0);
	vec2 q = p - (a + ab * h);
	float rough = (hash21(floor((p + seed) * 36.0)) - 0.5) * 0.030;
	float taper = smoothstep(0.02, 0.16, h) * (1.0 - smoothstep(0.84, 0.99, h));
	return (1.0 - smoothstep(width - 0.020 + rough, width + 0.045 + rough, length(q))) * taper;
}

void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}

void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	// Three separated upper-body brush fragments. Their layout is deliberately not orbital.
	float left = max(brush_segment(p, vec2(-0.46, -0.10), vec2(-0.34, 0.18), 0.085), brush_segment(p, vec2(-0.34, 0.18), vec2(-0.20, 0.25), 0.070));
	float right = max(brush_segment(p, vec2(0.46, -0.02), vec2(0.34, 0.19), 0.082), brush_segment(p, vec2(0.34, 0.19), vec2(0.20, 0.24), 0.066));
	float crown = max(brush_segment(p, vec2(-0.10, 0.42), vec2(0.04, 0.54), 0.070), brush_segment(p, vec2(0.04, 0.54), vec2(0.17, 0.42), 0.055));
	float body = max(left, max(right, crown));
	float inner = max(brush_segment(p, vec2(-0.43, -0.09), vec2(-0.34, 0.15), 0.040), max(brush_segment(p, vec2(0.43, -0.01), vec2(0.34, 0.16), 0.038), brush_segment(p, vec2(-0.07, 0.43), vec2(0.04, 0.51), 0.032)));
	float birth = smoothstep(0.0, 0.14, progress);
	float fade = 1.0 - smoothstep(0.66, 1.0, progress);
	float pulse = 1.0 + smoothstep(0.10, 0.24, progress) * (1.0 - smoothstep(0.24, 0.42, progress)) * 0.32;
	float life = birth * fade;
	vec3 color = mix(edge_color.rgb, core_color.rgb, inner * 0.82);
	float alpha = clamp(body * life * opacity, 0.0, 0.90);
	ALBEDO = color;
	EMISSION = color * (0.55 + inner * 2.0) * pulse;
	ALPHA = alpha;
}
"""

var _material: ShaderMaterial

func play_guard(at: Vector3, duration := 0.74) -> void:
	begin()
	position = at
	var quad := QuadMesh.new()
	quad.size = Vector2(1.06, 1.18)
	var art := MeshInstance3D.new()
	art.name = "ArbiterGuardFragments"
	art.mesh = quad
	art.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_material = ShaderMaterial.new()
	_material.shader = Shader.new()
	_material.shader.code = GUARD_SHADER
	_material.set_shader_parameter("edge_color", Color(0.52, 0.28, 0.045, 1.0))
	_material.set_shader_parameter("core_color", Color(1.0, 0.98, 0.84, 1.0))
	_material.set_shader_parameter("seed", 47.0)
	_material.set_shader_parameter("opacity", vfx_alpha)
	art.material_override = _material
	add_child(art)
	art.scale = Vector3.ONE * 0.72
	var scale_tween := track_tween(create_tween())
	scale_tween.tween_property(art, "scale", Vector3.ONE, duration * 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	var progress_tween := track_tween(create_tween())
	progress_tween.tween_method(func(value: float) -> void:
		if is_instance_valid(_material): _material.set_shader_parameter("progress", value), 0.0, 1.0, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await get_tree().create_timer(duration + 0.04).timeout
	if not _finished: finish()

func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	if is_instance_valid(_material): _material.set_shader_parameter("opacity", vfx_alpha)
