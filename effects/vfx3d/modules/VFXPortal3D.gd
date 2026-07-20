extends VFXBlockRoot
class_name VFXPortal3D

const CURVES := preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")

# Pre-baked soft textures (assets/vfx_textures, generated offline). Shapes and
# soft falloff come from textures; shaders only tint, animate, and erode them.
const TEX_SWIRL := preload("res://assets/vfx_textures/swirl_arms.png")
const TEX_RING := preload("res://assets/vfx_textures/ragged_ring.png")
const TEX_FLARE := preload("res://assets/vfx_textures/flare_star.png")
const TEX_WISP := preload("res://assets/vfx_textures/smoke_wisp.png")
const TEX_DOT := preload("res://assets/vfx_textures/soft_dot.png")
const TEX_NOISE := preload("res://assets/vfx_textures/noise_tile.png")

# Billboard that keeps node scale so collapse/expansion animations stay visible.
const BILLBOARD_GLSL := """
void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3])
		* mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0), vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
}
"""

const ROTATE_GLSL := """
vec2 vfx_rotate(vec2 p, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec2(c * p.x - s * p.y, s * p.x + c * p.y);
}
"""

# Swirling aperture disc: two counter-parallax samples of the baked swirl
# texture, noise-eroded edge, dark outer band kept dominant via blend_mix.
const VORTEX_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 dark_color : source_color;
uniform vec4 main_color : source_color;
uniform vec4 core_color : source_color;
uniform sampler2D swirl_tex : filter_linear_mipmap, repeat_disable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float reveal = 0.0;
uniform float dissolve = 0.0;
uniform float opacity = 1.0;
uniform float seed = 0.0;
uniform float energy = 3.0;
uniform float twist = 1.4;
uniform float spin = 0.9;
""" + ROTATE_GLSL + BILLBOARD_GLSL + """
void fragment() {
	vec2 p = UV - vec2(0.5);
	float r = length(p) * 2.0;
	float arms = texture(swirl_tex, vfx_rotate(p, TIME * spin + seed + (1.0 - r) * twist * 0.5) + vec2(0.5)).a;
	float arms2 = texture(swirl_tex, vfx_rotate(p * 1.22, -TIME * spin * 0.55 + seed * 1.7) + vec2(0.5)).a;
	float n = texture(noise_tex, UV * 1.7 + vec2(TIME * 0.04 + seed, -TIME * 0.07)).r;
	float edge = r + (n - 0.5) * 0.24;
	float open_r = reveal * 1.1;
	float mask = smoothstep(open_r, open_r - 0.24, edge);
	mask *= smoothstep(dissolve - 0.09, dissolve + 0.09, n * 0.85 + (1.0 - r) * 0.15);
	float core_band = smoothstep(0.30, 0.03, edge);
	float arm_mix = clamp(max(arms, arms2 * 0.75), 0.0, 1.0);
	float main_band = smoothstep(0.80, 0.22, edge) * arm_mix;
	float dark_body = smoothstep(1.06, 0.42, edge);
	vec3 col = dark_color.rgb;
	col = mix(col, main_color.rgb, main_band * 0.85);
	col = mix(col, core_color.rgb, core_band);
	ALBEDO = col;
	EMISSION = col * energy * (0.10 + main_band * 0.50 + core_band * 1.45);
	ALPHA = clamp((dark_body * 0.80 + main_band * 0.16 + core_band * 0.22) * mask * opacity, 0.0, 0.96);
}
"""

# Torn rim: baked ragged ring texture, slow rotation, noise erode-in/out.
const RIM_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 shadow_color : source_color;
uniform vec4 main_color : source_color;
uniform vec4 core_color : source_color;
uniform sampler2D ring_tex : filter_linear_mipmap, repeat_disable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float reveal = 0.0;
uniform float dissolve = 0.0;
uniform float opacity = 1.0;
uniform float seed = 0.0;
uniform float energy = 3.0;
""" + ROTATE_GLSL + BILLBOARD_GLSL + """
void fragment() {
	vec2 p = UV - vec2(0.5);
	float ring = texture(ring_tex, vfx_rotate(p, TIME * 0.22 + seed) + vec2(0.5)).a;
	float n2 = texture(noise_tex, UV * 2.3 + vec2(seed)).g;
	float appear = smoothstep(n2 - 0.10, n2 + 0.10, reveal);
	float keep = 1.0 - smoothstep(n2 - 0.09, n2 + 0.09, dissolve);
	float hot = pow(ring, 2.4);
	float pulse = 0.86 + 0.14 * sin(TIME * 5.5 + seed);
	vec3 col = mix(shadow_color.rgb, main_color.rgb, clamp(ring * 1.15, 0.0, 1.0));
	col = mix(col, core_color.rgb, hot * 0.85);
	ALBEDO = col;
	EMISSION = col * energy * (0.40 + hot * 1.55) * pulse;
	ALPHA = clamp(ring * appear * keep * opacity * 0.95, 0.0, 0.95);
}
"""

# Hot core / flash: baked star flare. Additive is fine — this IS the hot core.
const FLARE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 main_color : source_color;
uniform vec4 core_color : source_color;
uniform sampler2D flare_tex : filter_linear_mipmap, repeat_disable;
uniform float strength = 0.0;
uniform float opacity = 1.0;
uniform float seed = 0.0;
uniform float energy = 3.0;
""" + BILLBOARD_GLSL + """
void fragment() {
	float fl = texture(flare_tex, UV).a;
	float pulse = 0.88 + 0.12 * sin(TIME * 6.5 + seed);
	float intensity = fl * pulse * strength;
	vec3 col = mix(main_color.rgb, core_color.rgb, clamp(fl * 1.8, 0.0, 1.0));
	ALBEDO = vec3(0.0);
	EMISSION = col * energy * intensity;
	ALPHA = clamp(intensity, 0.0, 1.0) * opacity;
}
"""

# Rising wisp: baked ragged streak, noise flicker, sin-shaped life fade.
const WISP_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 main_color : source_color;
uniform vec4 core_color : source_color;
uniform sampler2D wisp_tex : filter_linear_mipmap, repeat_disable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float life = 0.0;
uniform float opacity = 1.0;
uniform float seed = 0.0;
uniform float energy = 3.0;
""" + BILLBOARD_GLSL + """
void fragment() {
	float body = texture(wisp_tex, UV).a;
	float n = texture(noise_tex, UV * vec2(1.4, 2.2) + vec2(seed, -TIME * 0.9)).r;
	float fade = sin(clamp(life, 0.0, 1.0) * 3.14159);
	vec3 col = mix(main_color.rgb, core_color.rgb, pow(body, 2.0));
	ALBEDO = col;
	EMISSION = col * energy * (0.45 + body * 0.85);
	ALPHA = clamp(body * (0.60 + n * 0.40) * fade * opacity, 0.0, 0.92);
}
"""

# Spark mote: baked soft dot pulled into the aperture.
const SPARK_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 main_color : source_color;
uniform vec4 core_color : source_color;
uniform sampler2D dot_tex : filter_linear_mipmap, repeat_disable;
uniform float life = 0.0;
uniform float opacity = 1.0;
uniform float energy = 3.0;
""" + BILLBOARD_GLSL + """
void fragment() {
	float dot_a = texture(dot_tex, UV).a;
	float fade = sin(clamp(life, 0.0, 1.0) * 3.14159);
	vec3 col = mix(main_color.rgb, core_color.rgb, dot_a);
	ALBEDO = vec3(0.0);
	EMISSION = col * energy * dot_a * fade;
	ALPHA = clamp(dot_a * fade, 0.0, 1.0) * opacity;
}
"""

# Ground anchor: soft dark pool + baked ring, gentle noise shimmer.
const POOL_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 dark_color : source_color;
uniform vec4 main_color : source_color;
uniform sampler2D dot_tex : filter_linear_mipmap, repeat_disable;
uniform sampler2D ring_tex : filter_linear_mipmap, repeat_disable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float life = 0.0;
uniform float opacity = 1.0;
uniform float seed = 0.0;
""" + ROTATE_GLSL + """
void fragment() {
	vec2 p = UV - vec2(0.5);
	float base = texture(dot_tex, UV).a;
	float ring = texture(ring_tex, vfx_rotate(p, -TIME * 0.18 + seed) + vec2(0.5)).a;
	float n = texture(noise_tex, UV * 2.0 + vec2(TIME * 0.05, seed)).r;
	float fade = sin(clamp(life, 0.0, 1.0) * 3.14159);
	vec3 col = mix(dark_color.rgb, main_color.rgb, ring * 0.55);
	ALBEDO = col;
	EMISSION = col * (0.25 + ring * 1.0) * (0.8 + n * 0.3);
	ALPHA = clamp((base * 0.55 + ring * 0.32) * fade * opacity, 0.0, 0.85);
}
"""

var _materials: Array[ShaderMaterial] = []

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	play_portal(context.get("target", Vector3.ZERO), profile)

func play_portal(at: Vector3, profile: VFXProfile3D = null) -> void:
	begin()
	position = at
	_face_battle_camera()
	var active := profile if profile != null else _fallback_profile()
	var d := active.duration
	var s := active.size
	var center_y := s * 1.12

	# Layer 0 — ground anchor pool, first in, last out.
	var pool := _spawn_quad("PortalGroundPool", Vector2(s * 1.9, s * 1.3), POOL_SHADER, {
		"dark_color": active.dark_color.darkened(0.25), "main_color": active.main_color,
		"dot_tex": TEX_DOT, "ring_tex": TEX_RING, "noise_tex": TEX_NOISE, "seed": 3.1
	}, -2)
	pool.rotation_degrees.x = -90.0
	pool.position.y = 0.03
	_tween_param(pool, "life", 0.0, 1.0, d * 1.05, "delayed_fade_life", 0.0)

	# Layer 1 — anticipation seed flash at the future aperture center.
	var seed_flare := _spawn_quad("PortalSeedFlare", Vector2(s * 1.25, s * 1.25), FLARE_SHADER, {
		"main_color": active.main_color, "core_color": active.core_color,
		"flare_tex": TEX_FLARE, "seed": 8.4, "energy": active.emission_energy
	}, 3)
	seed_flare.position.y = center_y
	seed_flare.scale = Vector3.ONE * 0.28
	var seed_tw := track_tween(create_tween())
	seed_tw.tween_method(_param_setter(seed_flare, "strength"), 0.0, 1.0, d * 0.07).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	seed_tw.parallel().tween_property(seed_flare, "scale", Vector3.ONE * 0.55, d * 0.07).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	seed_tw.tween_method(_param_setter(seed_flare, "strength"), 1.0, 0.35, d * 0.10)

	# Layer 2 — torn rim ring rips open with overshoot.
	var rim := _spawn_quad("PortalRimRing", Vector2(s * 2.55, s * 2.75), RIM_SHADER, {
		"shadow_color": active.dark_color, "main_color": active.main_color,
		"core_color": active.core_color, "ring_tex": TEX_RING, "noise_tex": TEX_NOISE,
		"seed": 6.0, "energy": active.emission_energy
	}, 1)
	rim.position.y = center_y
	rim.scale = Vector3.ONE * 0.15
	var rim_tw := track_tween(create_tween())
	rim_tw.tween_interval(d * 0.05)
	rim_tw.tween_property(rim, "scale", Vector3.ONE, d * 0.20).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween_param(rim, "reveal", 0.0, 1.0, d * 0.22, "explosive_out", d * 0.05)
	_tween_param(rim, "dissolve", 0.0, 1.0, d * 0.18, "ease_in", d * 0.80)

	# Layer 3 — swirling vortex disc, the readable body of the effect.
	var vortex := _spawn_quad("PortalVortexDisc", Vector2(s * 2.35, s * 2.35), VORTEX_SHADER, {
		"dark_color": active.dark_color, "main_color": active.main_color,
		"core_color": active.core_color, "swirl_tex": TEX_SWIRL, "noise_tex": TEX_NOISE,
		"seed": 2.2, "energy": active.emission_energy, "twist": 1.4, "spin": 0.9
	}, 0)
	vortex.position.y = center_y
	_tween_param(vortex, "reveal", 0.0, 1.0, d * 0.30, "explosive_out", d * 0.10)
	_tween_param(vortex, "dissolve", 0.0, 1.0, d * 0.16, "ease_in", d * 0.78)
	var collapse_tw := track_tween(create_tween())
	collapse_tw.tween_interval(d * 0.78)
	collapse_tw.tween_property(vortex, "scale", Vector3.ONE * 0.14, d * 0.17).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)

	# Layer 4 — persistent hot core inside the aperture.
	var core := _spawn_quad("PortalCoreFlare", Vector2(s * 1.05, s * 1.05), FLARE_SHADER, {
		"main_color": active.main_color, "core_color": active.core_color,
		"flare_tex": TEX_FLARE, "seed": 4.6, "energy": active.emission_energy
	}, 2)
	core.position.y = center_y
	_tween_param(core, "strength", 0.0, 0.85, d * 0.20, "explosive_out", d * 0.12)
	_tween_param(core, "strength", 0.85, 0.0, d * 0.14, "ease_in", d * 0.76)

	# Layer 5 — rising eroded wisps around the rim.
	_spawn_wisps(active, center_y)

	# Layer 6 — large spark motes pulled into the aperture.
	_spawn_suction_sparks(active, center_y)

	# Layer 7 — collapse pop flash + drifting ember residue.
	var pop := _spawn_quad("PortalCollapseFlash", Vector2(s * 1.7, s * 1.7), FLARE_SHADER, {
		"main_color": active.main_color, "core_color": active.core_color,
		"flare_tex": TEX_FLARE, "seed": 11.3, "energy": active.emission_energy * 1.25
	}, 3)
	pop.position.y = center_y
	pop.scale = Vector3.ONE * 0.35
	var pop_tw := track_tween(create_tween())
	pop_tw.tween_interval(d * 0.86)
	pop_tw.tween_property(pop, "scale", Vector3.ONE * 1.35, d * 0.11).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	_tween_param(pop, "strength", 0.0, 1.0, d * 0.045, "snap_in", d * 0.86)
	_tween_param(pop, "strength", 1.0, 0.0, d * 0.13, "ease_in", d * 0.905)
	_spawn_embers(active, center_y, d * 0.87)

	await get_tree().create_timer(d * 1.08 + 0.25).timeout
	finish()

func _face_battle_camera() -> void:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return
	var flat := camera.global_position - global_position
	flat.y = 0.0
	if flat.length_squared() > 0.001:
		look_at(global_position - flat, Vector3.UP)

func _spawn_wisps(profile: VFXProfile3D, center_y: float) -> void:
	var s := profile.size
	for i in range(7):
		var side := -1.0 if i % 2 == 0 else 1.0
		var wisp := _spawn_quad("PortalWisp_%d" % i, Vector2(s * (0.16 + 0.05 * float(i % 3)), s * (0.55 + 0.16 * float(i % 3))), WISP_SHADER, {
			"main_color": profile.main_color, "core_color": profile.core_color,
			"wisp_tex": TEX_WISP, "noise_tex": TEX_NOISE,
			"seed": 1.7 * float(i), "energy": profile.emission_energy * 0.9
		}, 1)
		var rx := side * s * (0.55 + 0.28 * float(i % 3))
		wisp.position = Vector3(rx, center_y - s * 0.75 + s * 0.2 * float(i % 2), 0.02)
		var delay := profile.duration * (0.12 + 0.065 * float(i))
		var rise := profile.duration * 0.42
		var tw := track_tween(create_tween())
		tw.tween_interval(delay)
		tw.set_parallel(true)
		tw.tween_property(wisp, "position:y", wisp.position.y + s * (1.05 + 0.2 * float(i % 3)), rise).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(wisp, "position:x", rx * 0.55, rise).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_tween_param(wisp, "life", 0.0, 1.0, rise, "linear", delay)
		tw.set_parallel(false)
		tw.tween_callback(wisp.queue_free)

func _spawn_suction_sparks(profile: VFXProfile3D, center_y: float) -> void:
	var s := profile.size
	var count := clampi(profile.particle_count + 3, 8, 16)
	for i in range(count):
		var spark := _spawn_quad("PortalSpark_%d" % i, Vector2(s * (0.10 + 0.06 * randf()), s * (0.10 + 0.06 * randf())), SPARK_SHADER, {
			"main_color": profile.main_color, "core_color": profile.core_color,
			"dot_tex": TEX_DOT, "energy": profile.emission_energy
		}, 2)
		var a0 := randf() * TAU
		var r0 := s * (1.25 + randf() * 0.55)
		var swirl := 2.0 + randf() * 1.4
		var delay := profile.duration * (0.14 + 0.045 * float(i))
		var travel := profile.duration * (0.30 + randf() * 0.14)
		spark.position = Vector3(cos(a0) * r0, center_y + sin(a0) * r0 * 0.82, 0.04)
		spark.visible = false
		var tw := track_tween(create_tween())
		tw.tween_interval(delay)
		tw.tween_callback(func() -> void: spark.visible = true)
		tw.tween_method(func(t: float) -> void:
			if not is_instance_valid(spark):
				return
			var eased := t * t * (3.0 - 2.0 * t)
			var ang := a0 + eased * swirl
			var rad := lerpf(r0, s * 0.12, eased)
			spark.position = Vector3(cos(ang) * rad, center_y + sin(ang) * rad * 0.82, 0.04)
			(spark.material_override as ShaderMaterial).set_shader_parameter("life", t),
			0.0, 1.0, travel)
		tw.tween_callback(spark.queue_free)

func _spawn_embers(profile: VFXProfile3D, center_y: float, start_delay: float) -> void:
	var s := profile.size
	for i in range(5):
		var ember := _spawn_quad("PortalEmber_%d" % i, Vector2(s * 0.09, s * 0.09), SPARK_SHADER, {
			"main_color": profile.main_color, "core_color": profile.core_color,
			"dot_tex": TEX_DOT, "energy": profile.emission_energy * 0.8
		}, 2)
		var ang := randf() * TAU
		var dist := s * (0.45 + randf() * 0.5)
		ember.position = Vector3(0.0, center_y, 0.05)
		ember.visible = false
		var dur := profile.duration * 0.22
		var tw := track_tween(create_tween())
		tw.tween_interval(start_delay)
		tw.tween_callback(func() -> void: ember.visible = true)
		tw.set_parallel(true)
		tw.tween_property(ember, "position", Vector3(cos(ang) * dist, center_y + sin(ang) * dist * 0.7 - s * 0.15, 0.05), dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.set_parallel(false)
		_tween_param(ember, "life", 0.0, 1.0, dur, "linear", start_delay)
		tw.tween_callback(ember.queue_free)

func _spawn_quad(node_name: String, quad_size: Vector2, shader_code: String, params: Dictionary, priority: int) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = quad_size
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = quad
	node.material_override = _make_material(shader_code, params, priority)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node

func _make_material(shader_code: String, params: Dictionary, priority: int) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = shader_code
	material.shader = shader
	for key in params:
		material.set_shader_parameter(key, params[key])
	material.set_shader_parameter("opacity", vfx_alpha)
	material.render_priority = priority
	_materials.append(material)
	return material

func _param_setter(node: MeshInstance3D, param: String) -> Callable:
	return func(value: float) -> void:
		if is_instance_valid(node):
			(node.material_override as ShaderMaterial).set_shader_parameter(param, value)

func _tween_param(node: MeshInstance3D, param: String, from_value: float, to_value: float, duration: float, curve_name: String, delay: float) -> void:
	var setter := _param_setter(node, param)
	var tw := track_tween(create_tween())
	if delay > 0.0:
		tw.tween_interval(delay)
	tw.tween_method(func(t: float) -> void:
		setter.call(lerpf(from_value, to_value, _sample_curve(curve_name, t))), 0.0, 1.0, duration)

func _sample_curve(curve_name: String, t: float) -> float:
	match curve_name:
		"linear":
			return clampf(t, 0.0, 1.0)
		"ease_in":
			return t * t
		"snap_in":
			return 1.0 - pow(1.0 - clampf(t, 0.0, 1.0), 6.0)
		"delayed_fade_life":
			# Rise fast to mid-life, hold, then complete: maps onto sin(pi*life)
			# shaders so layers appear quickly and linger before fading.
			var x := clampf(t, 0.0, 1.0)
			if x < 0.12:
				return x / 0.12 * 0.5
			if x < 0.72:
				return 0.5
			return 0.5 + (x - 0.72) / 0.28 * 0.5
		_:
			return CURVES.sample(curve_name, t)

func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	for material in _materials:
		if is_instance_valid(material):
			material.set_shader_parameter("opacity", vfx_alpha)

func _fallback_profile() -> VFXProfile3D:
	var profile := VFXProfile3D.new()
	profile.dark_color = Color(0.012, 0.05, 0.032)
	profile.main_color = Color(0.10, 0.64, 0.36)
	profile.core_color = Color(0.80, 1.0, 0.86)
	profile.size = 1.1
	profile.duration = 2.0
	profile.particle_count = 12
	profile.emission_energy = 3.4
	return profile
