extends VFXBlockRoot
class_name VFXGroundDecalLayer3D

const CURVES := preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")

const DECAL_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 shadow_color : source_color;
uniform vec4 main_color : source_color;
uniform vec4 core_color : source_color;
uniform float reveal = 0.0;
uniform float dissolve = 0.0;
uniform float opacity = 1.0;
uniform float phase = 0.0;
uniform float seed = 0.0;
float hash11(float p) { return fract(sin(p * 127.1 + seed) * 43758.5453); }
void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float a = atan(p.y, p.x);
	float r = length(p);
	float warp = sin(a * 5.0 + seed) * 0.025 + sin(a * 11.0 - seed * 0.3) * 0.014;
	float sector = floor((a + 3.14159265) / 6.2831853 * 12.0);
	float gate = step(0.28, hash11(sector * 4.31));
	float outer = smoothstep(0.085, 0.018, abs(r - 0.79 - warp)) * gate;
	float broken_inner = smoothstep(0.070, 0.014, abs(r - 0.53 + warp * 0.55)) * step(0.18, hash11(sector * 8.7 + 3.0));
	float wedge_angle = abs(fract((a + 3.14159265) / 6.2831853 * 6.0 + 0.5) - 0.5);
	float wedges = smoothstep(0.14, 0.035, wedge_angle) * smoothstep(0.76, 0.63, r) * smoothstep(0.31, 0.45, r);
	float center = smoothstep(0.34, 0.04, r) * (0.42 + 0.18 * sin(a * 4.0 + phase));
	float radial_reveal = 1.0 - smoothstep(reveal - 0.08, reveal + 0.16, r);
	float erosion = step(dissolve, hash11(floor(a * 23.0) + floor(r * 21.0) * 9.1) * 0.62 + (1.0 - r) * 0.22);
	float mask = (outer + broken_inner * 0.84 + wedges * 0.82 + center * 0.34) * radial_reveal * erosion;
	float hot = clamp(broken_inner + wedges + center * 0.45, 0.0, 1.0);
	vec3 color = mix(shadow_color.rgb, main_color.rgb, clamp(mask * 1.2, 0.0, 1.0));
	color = mix(color, core_color.rgb, hot * 0.48);
	ALBEDO = color;
	EMISSION = color * (0.72 + hot * 2.15);
	ALPHA = clamp(mask * opacity * mix(0.90, 0.58, dissolve), 0.0, 0.92);
}
"""

var _material: ShaderMaterial

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	play_decal(context.get("target", Vector3.ZERO), profile, float(context.get("seed", randf_range(0.0, 80.0))))

func play_decal(at: Vector3, profile: VFXProfile3D, seed := 0.0) -> void:
	begin()
	var active := profile if profile != null else _fallback_profile()
	position = at + Vector3(0.0, 0.022, 0.0)
	var quad := QuadMesh.new()
	quad.size = Vector2(active.size * 2.25, active.size * 1.55)
	var node := MeshInstance3D.new()
	node.name = "BrokenGroundDecal"
	node.mesh = quad
	node.rotation_degrees.x = -90.0
	_material = ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = DECAL_SHADER
	_material.shader = shader
	_material.set_shader_parameter("shadow_color", active.dark_color)
	_material.set_shader_parameter("main_color", active.main_color)
	_material.set_shader_parameter("core_color", active.core_color)
	_material.set_shader_parameter("reveal", 0.0)
	_material.set_shader_parameter("dissolve", 0.0)
	_material.set_shader_parameter("opacity", vfx_alpha)
	_material.set_shader_parameter("phase", seed * 0.1)
	_material.set_shader_parameter("seed", seed)
	node.material_override = _material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.scale = Vector3.ONE * 0.10
	add_child(node)
	CURVES.tween_method(self, func(v: float) -> void:
		if is_instance_valid(node): node.scale = Vector3.ONE * v,
		0.10, 1.0, active.duration * 0.22, "ease_out_back")
	CURVES.tween_method(self, _set_reveal, 0.0, 1.0, active.duration * 0.30, "explosive_out")
	var motion := track_tween(create_tween())
	motion.tween_method(_set_phase, seed * 0.1, seed * 0.1 + 0.72, active.duration * 0.72).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var fade := track_tween(create_tween())
	fade.tween_interval(active.duration * 0.62)
	fade.tween_method(_set_dissolve, 0.0, 1.0, active.duration * 0.34).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await get_tree().create_timer(active.duration + 0.04).timeout
	finish()

func _set_reveal(value: float) -> void:
	if _material != null: _material.set_shader_parameter("reveal", value)

func _set_phase(value: float) -> void:
	if _material != null: _material.set_shader_parameter("phase", value)

func _set_dissolve(value: float) -> void:
	if _material != null: _material.set_shader_parameter("dissolve", value)

func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	if _material != null: _material.set_shader_parameter("opacity", vfx_alpha)

func _fallback_profile() -> VFXProfile3D:
	var profile := VFXProfile3D.new()
	profile.dark_color = Color(0.045, 0.012, 0.10)
	profile.main_color = Color(0.42, 0.08, 0.76)
	profile.core_color = Color(0.86, 0.48, 0.96)
	profile.size = 1.0
	profile.duration = 1.20
	return profile
