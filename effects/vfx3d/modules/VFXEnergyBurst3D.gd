extends VFXBlockRoot
class_name VFXEnergyBurst3D

const CURVES := preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")

const BURST_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 shadow_color : source_color;
uniform vec4 main_color : source_color;
uniform vec4 core_color : source_color;
uniform float progress = 0.0;
uniform float opacity = 1.0;
uniform float seed = 0.0;
void vertex() { MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]); }
void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float r = length(p);
	float a = atan(p.y, p.x);
	float jag = sin(a * 7.0 + seed) * 0.075 + sin(a * 13.0 - seed * 0.73) * 0.04;
	float body = smoothstep(0.91 + jag, 0.18, r);
	float core = smoothstep(0.36, 0.015, r);
	float rays = pow(max(0.0, cos(a * 6.0 + seed)), 20.0) * smoothstep(1.12, 0.16, r);
	float broken = smoothstep(0.16, 0.74, sin(a * 11.0 + seed * 1.9) * 0.5 + 0.5 + body);
	float life = sin(clamp(progress, 0.0, 1.0) * 3.14159);
	float mask = clamp(body * broken + rays * 0.82, 0.0, 1.0) * life;
	vec3 color = mix(shadow_color.rgb, main_color.rgb, smoothstep(0.94, 0.28, r));
	color = mix(color, core_color.rgb, core + rays * 0.32);
	ALBEDO = color;
	EMISSION = color * (2.2 + core * 3.8 + rays * 1.9);
	ALPHA = clamp(mask * opacity, 0.0, 0.96);
}
"""

const RING_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
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
	float radius = 0.22 + progress * 0.68;
	float wobble = sin(a * 8.0 + seed) * 0.035 + sin(a * 15.0 - seed) * 0.018;
	float thick = mix(0.16, 0.055, progress);
	float ring = smoothstep(thick, 0.006, abs(r + wobble - radius));
	float inner = smoothstep(thick * 0.55, 0.006, abs(r - radius * 0.66 - wobble * 0.45));
	float chunks = smoothstep(-0.18, 0.16, sin(a * 9.0 + seed) + sin(a * 17.0 - seed * 0.4));
	float fade = 1.0 - smoothstep(0.64, 1.0, progress);
	float alpha = (ring * chunks + inner * 0.46) * fade * opacity;
	vec3 color = mix(dark_color.rgb, main_color.rgb, ring);
	color = mix(color, core_color.rgb, inner * 0.65);
	ALBEDO = color;
	EMISSION = color * (2.0 + ring * 2.2);
	ALPHA = clamp(alpha, 0.0, 0.92);
}
"""

const SMOKE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 smoke_color : source_color;
uniform vec4 rim_color : source_color;
uniform float progress = 0.0;
uniform float opacity = 1.0;
uniform float seed = 0.0;
void vertex() { MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]); }
float blob(vec2 p, vec2 c, float s) { return 1.0 - smoothstep(s * 0.58, s, length(p - c)); }
void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float cloud = blob(p, vec2(-0.34, -0.05), 0.62) + blob(p, vec2(0.18, -0.18), 0.72) + blob(p, vec2(0.42, 0.20), 0.52) + blob(p, vec2(-0.08, 0.32), 0.68);
	cloud = clamp(cloud, 0.0, 1.0);
	float edge = cloud - smoothstep(0.30, 0.94, cloud);
	float fade = 1.0 - smoothstep(0.52, 1.0, progress);
	vec3 color = mix(smoke_color.rgb, rim_color.rgb, edge * 0.45);
	ALBEDO = color;
	EMISSION = rim_color.rgb * edge * 0.42;
	ALPHA = cloud * fade * opacity * 0.72;
}
"""

var _materials: Array[ShaderMaterial] = []

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	play_burst(context.get("target", Vector3.ZERO), context.get("direction", Vector3.RIGHT), profile)

func play_burst(at: Vector3, direction: Vector3, profile: VFXProfile3D = null) -> void:
	begin()
	position = at + Vector3(0.0, 0.36, 0.0)
	var active := profile if profile != null else _fallback_profile()
	var facing := Vector3(direction.x, direction.y, 0.0).normalized()
	if facing.length_squared() < 0.001:
		facing = Vector3.RIGHT
	var core := _spawn_billboard("VioletHotCore", active.size * Vector2(1.28, 1.12), BURST_SHADER, {
		"shadow_color": active.dark_color, "main_color": active.main_color,
		"core_color": active.core_color, "seed": 4.7
	})
	core.scale = Vector3.ONE * 0.18
	CURVES.tween_method(self, func(v: float) -> void:
		if is_instance_valid(core): core.scale = Vector3.ONE * v,
		0.18, 1.08, active.duration * 0.18, "ease_out_back")
	_tween_progress(core.material_override as ShaderMaterial, active.duration * 0.70)
	await get_tree().create_timer(active.duration * 0.08).timeout
	if _finished: return
	_spawn_broken_ring(active)
	_spawn_sparks(facing, active)
	await get_tree().create_timer(active.duration * 0.12).timeout
	if _finished: return
	_spawn_smoke(active)
	await get_tree().create_timer(active.duration * 0.86).timeout
	finish()

func _spawn_billboard(node_name: String, size: Vector2, shader_code: String, params: Dictionary) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = size
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = quad
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = shader_code
	material.shader = shader
	for key in params:
		material.set_shader_parameter(key, params[key])
	material.set_shader_parameter("opacity", vfx_alpha)
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	_materials.append(material)
	return node

func _spawn_broken_ring(profile: VFXProfile3D) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(profile.size * 2.15, profile.size * 1.50)
	var node := MeshInstance3D.new()
	node.name = "BrokenVioletShockRing"
	node.mesh = quad
	node.position = Vector3(0.0, -0.325, 0.0)
	node.rotation_degrees.x = -90.0
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = RING_SHADER
	material.shader = shader
	material.set_shader_parameter("dark_color", profile.dark_color)
	material.set_shader_parameter("main_color", profile.main_color)
	material.set_shader_parameter("core_color", profile.core_color)
	material.set_shader_parameter("seed", 9.3)
	material.set_shader_parameter("opacity", vfx_alpha)
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	_materials.append(material)
	_tween_progress(material, profile.duration * 0.74)

func _spawn_smoke(profile: VFXProfile3D) -> void:
	for i in range(3):
		var node := _spawn_billboard("VioletSmoke_%d" % i, profile.size * Vector2(1.08 + i * 0.18, 0.76 + i * 0.11), SMOKE_SHADER, {
			"smoke_color": profile.dark_color.darkened(0.25),
			"rim_color": profile.main_color.darkened(0.20), "seed": float(i) * 7.1
		})
		node.position = Vector3((-0.30 + i * 0.30) * profile.size, -0.02 + i * 0.07, -0.02 - i * 0.012)
		node.scale = Vector3.ONE * 0.58
		var material := node.material_override as ShaderMaterial
		var tween := track_tween(create_tween())
		tween.set_parallel(true)
		tween.tween_property(node, "scale", Vector3.ONE * (1.14 + i * 0.08), profile.duration * 0.68).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_property(node, "position:y", node.position.y + 0.32, profile.duration * 0.68).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_tween_progress(material, profile.duration * 0.68)

func _spawn_sparks(facing: Vector3, profile: VFXProfile3D) -> void:
	var count := clampi(profile.particle_count, 8, 12)
	for i in range(count):
		var angle := -1.42 + (2.84 * float(i) / maxf(float(count - 1), 1.0)) + sin(float(i) * 4.1) * 0.10
		var out := facing.rotated(Vector3.FORWARD, angle).normalized()
		var spark := _make_spark(out, profile.size * (0.48 + float(i % 3) * 0.16), profile.size * (0.034 + float(i % 2) * 0.018), profile)
		spark.position = out * profile.size * 0.12
		add_child(spark)
		var tween := track_tween(create_tween())
		tween.set_parallel(true)
		tween.tween_property(spark, "position", spark.position + out * profile.size * (0.72 + float(i % 4) * 0.10), profile.duration * 0.42).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_property(spark, "scale", Vector3(0.08, 0.12, 1.0), profile.duration * 0.42).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.set_parallel(false)
		tween.tween_callback(spark.queue_free)

func _make_spark(direction: Vector3, length: float, width: float, profile: VFXProfile3D) -> MeshInstance3D:
	var side := Vector3(-direction.y, direction.x, 0.0).normalized()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([-side * width, side * width, direction * length])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = profile.core_color
	material.emission_enabled = true
	material.emission = profile.core_color
	material.emission_energy_multiplier = minf(profile.emission_energy, 4.0)
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
	profile.dark_color = Color(0.075, 0.008, 0.16)
	profile.main_color = Color(0.50, 0.055, 0.94)
	profile.core_color = Color(0.96, 0.74, 1.0)
	profile.size = 1.08
	profile.duration = 1.0
	profile.particle_count = 10
	profile.emission_energy = 3.8
	return profile
