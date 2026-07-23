extends VFXBlockRoot
class_name VFXGroundSigil3D
const SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")

const CURVES := preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")

const GROUND_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 dark_color : source_color;
uniform vec4 main_color : source_color;
uniform vec4 core_color : source_color;
uniform float progress = 0.0;
uniform float opacity = 1.0;
uniform float seed = 0.0;
void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float r = length(p);
	float a = atan(p.y, p.x);
	float radius = 0.13 + progress * 0.76;
	float wobble = sin(a * 9.0 + seed) * 0.038 + sin(a * 16.0 - seed) * 0.018;
	float shock = smoothstep(0.15, 0.008, abs(r + wobble - radius));
	float second = smoothstep(0.075, 0.008, abs(r - radius * 0.72 + wobble * 0.35));
	float crack_rays = pow(max(0.0, cos(a * 7.0 + seed + sin(r * 18.0) * 0.16)), 34.0);
	float crack_branches = pow(max(0.0, cos(a * 13.0 - seed * 0.4 + r * 4.0)), 48.0) * 0.52;
	float crack_range = smoothstep(0.12, 0.24, r) * (1.0 - smoothstep(0.46, 0.88, r));
	float crack_life = smoothstep(0.48, 0.70, progress) * (1.0 - smoothstep(0.93, 1.0, progress));
	float cracks = (crack_rays + crack_branches) * crack_range * crack_life;
	float broken = smoothstep(-0.42, 0.24, sin(a * 11.0 + seed) + sin(a * 5.0));
	float shock_life = 1.0 - smoothstep(0.48, 0.78, progress);
	float residue = smoothstep(0.68, 0.12, r) * smoothstep(0.16, 0.46, r) * crack_life * 0.28;
	float shock_mask = (shock * broken + second * 0.48) * shock_life;
	float alpha = (shock_mask + cracks * 0.72 + residue) * opacity;
	vec3 color = mix(dark_color.rgb, main_color.rgb, shock_mask + residue * 0.18 + cracks * 0.32);
	color = mix(color, core_color.rgb, second * shock_life * 0.75);
	ALBEDO = color;
	EMISSION = color * (1.05 + cracks * 0.72 + shock * shock_life * 3.1 + second * shock_life * 1.8);
	ALPHA = clamp(alpha, 0.0, 0.92);
}
"""

const FIRE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 main_color : source_color;
uniform vec4 core_color : source_color;
uniform float progress = 0.0;
uniform float opacity = 1.0;
void vertex() { MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]); }
void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float r = length(p * vec2(1.0, 0.78));
	float a = atan(p.y, p.x);
	float spikes = pow(max(0.0, cos(a * 8.0 + 0.7)), 16.0) * smoothstep(1.15, 0.12, r);
	float body = smoothstep(0.90 + sin(a * 9.0) * 0.08, 0.08, r);
	float core = smoothstep(0.34, 0.01, r);
	float life = sin(clamp(progress, 0.0, 1.0) * 3.14159);
	float alpha = clamp(body + spikes * 0.92, 0.0, 1.0) * life * opacity;
	vec3 color = mix(main_color.rgb, core_color.rgb, core + spikes * 0.42);
	ALBEDO = color;
	EMISSION = color * (2.8 + core * 4.4);
	ALPHA = clamp(alpha, 0.0, 0.98);
}
"""

const SMOKE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 smoke_color : source_color;
uniform vec4 ember_color : source_color;
uniform float progress = 0.0;
uniform float opacity = 1.0;
void vertex() { MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]); }
float blob(vec2 p, vec2 c, float s) { return 1.0 - smoothstep(s * 0.58, s, length(p - c)); }
void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float cloud = clamp(blob(p, vec2(-0.38,-0.12),0.58) + blob(p,vec2(0.08,-0.22),0.76) + blob(p,vec2(0.42,0.08),0.55) + blob(p,vec2(-0.08,0.34),0.66), 0.0, 1.0);
	float rim = cloud - smoothstep(0.36, 0.92, cloud);
	float fade = 1.0 - smoothstep(0.48, 1.0, progress);
	vec3 color = mix(smoke_color.rgb, ember_color.rgb, rim * (1.0 - progress) * 0.34);
	ALBEDO = color;
	EMISSION = ember_color.rgb * rim * (1.0 - progress) * 0.34;
	ALPHA = cloud * fade * opacity * 0.78;
}
"""

var _materials: Array[ShaderMaterial] = []

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	play_sigil(context.get("target", Vector3.ZERO), profile)

func play_sigil(at: Vector3, profile: VFXProfile3D = null) -> void:
	begin()
	position = at
	var active := profile if profile != null else _fallback_profile()
	_spawn_ground_front(active)
	var flash := _spawn_billboard("RedOrangeImpactBody", Vector2(active.size * 1.62, active.size * 1.48), FIRE_SHADER, {
		"main_color": active.main_color, "core_color": active.core_color
	})
	flash.position.y = active.size * 0.54
	flash.scale = Vector3.ONE * 0.16
	CURVES.tween_method(self, func(v: float) -> void:
		if is_instance_valid(flash): flash.scale = Vector3.ONE * v,
		0.16, 1.18, active.duration * 0.12, "ease_out_back")
	_tween_progress(flash.material_override as ShaderMaterial, active.duration * 0.62)
	var hot_core := _spawn_billboard("WhiteHotImpactCore", Vector2(active.size * 0.88, active.size * 0.82), FIRE_SHADER, {
		"main_color": active.core_color.lerp(Color.WHITE, 0.32), "core_color": Color(1.0, 0.96, 0.76)
	})
	hot_core.position = Vector3(0.0, active.size * 0.49, -0.025)
	hot_core.scale = Vector3.ONE * 0.10
	CURVES.tween_method(self, func(v: float) -> void:
		if is_instance_valid(hot_core): hot_core.scale = Vector3.ONE * v,
		0.10, 0.92, active.duration * 0.10, "explosive_out")
	_tween_progress(hot_core.material_override as ShaderMaterial, active.duration * 0.36)
	await get_tree().create_timer(active.duration * 0.055).timeout
	if _finished: return
	_spawn_debris(active)
	_spawn_smoke(active)
	await get_tree().create_timer(active.duration * 0.96).timeout
	finish()

func _spawn_ground_front(profile: VFXProfile3D) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(profile.size * 2.25, profile.size * 1.58)
	var node := MeshInstance3D.new()
	node.name = "GroundExplosionShockAndCracks"
	node.mesh = quad
	node.position.y = 0.025
	node.rotation_degrees.x = -90.0
	var material := ShaderMaterial.new()
	material.shader = SHADER_CACHE.get_shader(GROUND_SHADER)
	material.set_shader_parameter("dark_color", profile.dark_color)
	material.set_shader_parameter("main_color", profile.main_color)
	material.set_shader_parameter("core_color", profile.core_color)
	material.set_shader_parameter("seed", 8.6)
	material.set_shader_parameter("opacity", vfx_alpha)
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	_materials.append(material)
	_tween_progress(material, profile.duration * 0.86)

func _spawn_billboard(node_name: String, size: Vector2, shader_code: String, params: Dictionary) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = size
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = quad
	var material := ShaderMaterial.new()
	material.shader = SHADER_CACHE.get_shader(shader_code)
	for key in params:
		material.set_shader_parameter(key, params[key])
	material.set_shader_parameter("opacity", vfx_alpha)
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	_materials.append(material)
	return node

func _spawn_smoke(profile: VFXProfile3D) -> void:
	for i in range(4):
		var node := _spawn_billboard("RedSmoke_%d" % i, Vector2(profile.size * (1.12 + i * 0.14), profile.size * (0.84 + i * 0.10)), SMOKE_SHADER, {
			"smoke_color": profile.dark_color.darkened(0.30), "ember_color": profile.main_color.darkened(0.10)
		})
		node.position = Vector3((-0.42 + i * 0.28) * profile.size, profile.size * (0.30 + (i % 2) * 0.14), -0.04 - i * 0.012)
		node.scale = Vector3.ONE * 0.46
		var material := node.material_override as ShaderMaterial
		var tween := track_tween(create_tween())
		tween.set_parallel(true)
		tween.tween_property(node, "scale", Vector3.ONE * (1.18 + i * 0.05), profile.duration * 0.72).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_property(node, "position:y", node.position.y + profile.size * 0.34, profile.duration * 0.72).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_tween_progress(material, profile.duration * 0.72)

func _spawn_debris(profile: VFXProfile3D) -> void:
	var count := clampi(profile.particle_count, 7, 11)
	for i in range(count):
		var angle := float(i) / float(count) * TAU + sin(float(i) * 2.7) * 0.16
		var out := Vector3(cos(angle), 0.30 + float(i % 3) * 0.16, sin(angle)).normalized()
		var shard := _make_shard(profile, i)
		shard.position = Vector3(0.0, 0.12, 0.0) + out * profile.size * 0.10
		add_child(shard)
		var peak := shard.position + out * profile.size * (0.52 + float(i % 4) * 0.10)
		var end := Vector3(peak.x * 1.12, 0.03, peak.z * 1.12)
		var tween := track_tween(create_tween())
		tween.tween_property(shard, "position", peak, profile.duration * 0.24).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.set_parallel(true)
		tween.tween_property(shard, "position", end, profile.duration * 0.30).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.tween_property(shard, "scale", Vector3.ONE * 0.12, profile.duration * 0.30).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.set_parallel(false)
		tween.tween_callback(shard.queue_free)

func _make_shard(profile: VFXProfile3D, index: int) -> MeshInstance3D:
	var w := profile.size * (0.064 + float(index % 3) * 0.016)
	var h := profile.size * (0.16 + float(index % 2) * 0.052)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-w,0.0,0.0), Vector3(w,0.0,0.0), Vector3(0.0,h,0.0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0,1,2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.rotation_degrees.z = float(index) * 29.0
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = profile.dark_color.lerp(profile.main_color, 0.56)
	material.emission_enabled = true
	material.emission = profile.main_color.darkened(0.08)
	material.emission_energy_multiplier = 2.0
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

func _tween_progress(material: ShaderMaterial, duration: float) -> void:
	var tween := track_tween(create_tween())
	tween.tween_method(func(value: float) -> void:
		if is_instance_valid(material): material.set_shader_parameter("progress", value),
		0.0, 1.0, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	for material in _materials:
		if is_instance_valid(material): material.set_shader_parameter("opacity", vfx_alpha)

func _fallback_profile() -> VFXProfile3D:
	var profile := VFXProfile3D.new()
	profile.dark_color = Color(0.12, 0.012, 0.008)
	profile.main_color = Color(0.92, 0.12, 0.018)
	profile.core_color = Color(1.0, 0.78, 0.26)
	profile.size = 1.08
	profile.duration = 1.28
	profile.particle_count = 9
	profile.emission_energy = 3.6
	profile.ground_aligned = true
	return profile
