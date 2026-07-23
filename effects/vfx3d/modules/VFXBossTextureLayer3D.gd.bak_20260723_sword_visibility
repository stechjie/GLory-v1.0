extends VFXBlockRoot
class_name VFXBossTextureLayer3D

const CURVES := preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")

const TEXTURE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform sampler2D art_texture : source_color, filter_linear_mipmap_anisotropic;
uniform vec4 dark_tint : source_color = vec4(0.08, 0.04, 0.12, 1.0);
uniform vec4 body_tint : source_color = vec4(1.0);
uniform vec4 core_tint : source_color = vec4(1.0);
uniform float reveal = 0.0;
uniform float dissolve = 0.0;
uniform float opacity = 1.0;
uniform float flow_strength = 0.018;
uniform float seed = 0.0;
uniform float billboard_mode = 1.0;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

void vertex() {
	if (billboard_mode > 0.5) {
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	}
	float bend = sin(UV.y * 8.0 + TIME * 4.0 + seed) * flow_strength;
	VERTEX.x += bend * (1.0 - abs(UV.y * 2.0 - 1.0));
}

void fragment() {
	vec2 centered = UV - vec2(0.5);
	vec2 warped_uv = UV + vec2(
		sin(UV.y * 19.0 + TIME * 2.4 + seed),
		cos(UV.x * 17.0 - TIME * 1.8 + seed)
	) * flow_strength;
	vec4 tex = texture(art_texture, warped_uv);
	float source_alpha = tex.a;
	float noise = hash21(floor(warped_uv * vec2(96.0, 96.0)) + seed);
	float radial = 1.0 - smoothstep(0.15, 0.78, length(centered));
	float reveal_mask = smoothstep(reveal - 0.16, reveal + 0.03, radial + noise * 0.12);
	float dissolve_value = noise * 0.68 + source_alpha * 0.32;
	float dissolve_mask = 1.0 - smoothstep(1.0 - dissolve - 0.12, 1.0 - dissolve + 0.06, dissolve_value);
	float edge = smoothstep(0.06, 0.34, source_alpha) - smoothstep(0.42, 0.82, source_alpha);
	float hot = smoothstep(0.62, 1.0, max(tex.r, max(tex.g, tex.b)));
	vec3 color = mix(tex.rgb * dark_tint.rgb, tex.rgb * body_tint.rgb, smoothstep(0.08, 0.58, source_alpha));
	color = mix(color, core_tint.rgb, hot * 0.34 + edge * 0.12);
	float alpha = source_alpha * reveal_mask * dissolve_mask * opacity;
	if (alpha < 0.018) { discard; }
	ALBEDO = color;
	EMISSION = color * (0.35 + hot * 1.8 + edge * 0.32);
	ALPHA = alpha;
}
"""

var _material: ShaderMaterial

func play_layer(texture_path: String, params: Dictionary = {}) -> void:
	begin()
	var texture := load(texture_path) as Texture2D
	if texture == null:
		push_warning("Boss VFX texture missing: %s" % texture_path)
		finish()
		return
	var delay := maxf(0.0, float(params.get("delay", 0.0)))
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
		if _finished:
			return
	var duration := maxf(0.18, float(params.get("duration", 0.9)))
	var size: Vector2 = params.get("size", Vector2(1.4, 1.4))
	var ground := bool(params.get("ground", false))
	position = params.get("from", params.get("position", Vector3.ZERO))
	var quad := QuadMesh.new()
	quad.size = size
	var art := MeshInstance3D.new()
	art.name = str(params.get("name", "BossPaintedLayer"))
	art.mesh = quad
	art.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	art.rotation_degrees.x = -90.0 if ground else 0.0
	art.rotation_degrees.z = float(params.get("rotation_z", 0.0))
	_material = ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = TEXTURE_SHADER
	_material.shader = shader
	_material.set_shader_parameter("art_texture", texture)
	_material.set_shader_parameter("dark_tint", params.get("dark_tint", Color(0.12, 0.08, 0.16, 1.0)))
	_material.set_shader_parameter("body_tint", params.get("body_tint", Color.WHITE))
	_material.set_shader_parameter("core_tint", params.get("core_tint", Color(1.0, 0.88, 0.62, 1.0)))
	_material.set_shader_parameter("flow_strength", float(params.get("flow_strength", 0.014)))
	_material.set_shader_parameter("seed", float(params.get("seed", 0.0)))
	_material.set_shader_parameter("billboard_mode", 0.0 if ground else 1.0)
	_material.set_shader_parameter("reveal", 0.0)
	_material.set_shader_parameter("dissolve", 0.0)
	_material.set_shader_parameter("opacity", vfx_alpha * float(params.get("opacity", 0.94)))
	art.material_override = _material
	add_child(art)
	art.scale = Vector3.ONE * float(params.get("start_scale", 0.18))
	var peak_scale := float(params.get("peak_scale", 1.0))
	CURVES.tween_method(self, func(value: float) -> void:
		if is_instance_valid(art):
			art.scale = Vector3.ONE * value,
		float(params.get("start_scale", 0.18)), peak_scale, duration * 0.28, str(params.get("curve", "ease_out_back")))
	_tween_shader("reveal", 0.0, 1.0, duration * 0.26)
	if params.has("to"):
		var travel := track_tween(create_tween())
		travel.tween_property(self, "position", params["to"], duration * float(params.get("travel_ratio", 0.62))).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await get_tree().create_timer(duration * 0.56).timeout
	if _finished:
		return
	_tween_shader("dissolve", 0.0, 1.0, duration * 0.40)
	var breakup := track_tween(create_tween())
	breakup.set_parallel(true)
	breakup.tween_property(art, "scale", Vector3.ONE * peak_scale * float(params.get("end_scale", 1.12)), duration * 0.40).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	breakup.tween_property(art, "position:y", art.position.y + float(params.get("rise", 0.08)), duration * 0.40)
	await get_tree().create_timer(duration * 0.44).timeout
	finish()

func _tween_shader(param: String, from: float, to: float, duration: float) -> void:
	var tween := track_tween(create_tween())
	tween.tween_method(func(value: float) -> void:
		if is_instance_valid(_material):
			_material.set_shader_parameter(param, value), from, to, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	if is_instance_valid(_material):
		_material.set_shader_parameter("opacity", vfx_alpha)
