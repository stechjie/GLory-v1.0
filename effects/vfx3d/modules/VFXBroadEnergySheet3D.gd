extends VFXBlockRoot
class_name VFXBroadEnergySheet3D
const SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")

const CURVES := preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")

const SHEET_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 shadow_color : source_color;
uniform vec4 main_color : source_color;
uniform vec4 core_color : source_color;
uniform float reveal = 0.0;
uniform float dissolve = 0.0;
uniform float opacity = 1.0;
uniform float energy = 2.6;
uniform float seed = 0.0;
uniform float halo = 0.0;
float hash21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7)) + seed) * 43758.5453); }
void fragment() {
	vec2 p = UV;
	float across = abs(p.y * 2.0 - 1.0);
	float longitudinal = sin(clamp(p.x, 0.0, 1.0) * 3.14159265);
	float ragged = hash21(floor(vec2(p.x * 19.0, p.y * 9.0))) * 0.18;
	float width_mask = smoothstep(0.98 + ragged, 0.48 + ragged * 0.22, across);
	float broken = smoothstep(dissolve - 0.16, dissolve + 0.20, hash21(floor(p * vec2(23.0, 11.0))) + (1.0 - p.x) * 0.34);
	float head = 1.0 - smoothstep(reveal, reveal + 0.10, p.x);
	float tip = smoothstep(0.0, 0.06, p.x) * smoothstep(1.0, 0.78, p.x);
	float body = width_mask * pow(max(longitudinal, 0.0), 0.42) * tip * head * broken;
	float hot = (1.0 - smoothstep(0.08, 0.42, across)) * body;
	float edge = smoothstep(0.92, 0.48, across) * body;
	vec3 color = mix(shadow_color.rgb, main_color.rgb, edge);
	color = mix(color, core_color.rgb, hot * (1.0 - halo));
	float alpha = body * opacity * mix(0.90, 0.26, halo);
	ALBEDO = color;
	EMISSION = color * energy * mix(0.76 + hot * 0.82, 0.48, halo);
	ALPHA = clamp(alpha, 0.0, 0.96);
}
"""

var _materials: Array[ShaderMaterial] = []

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	play_sheet(
		context.get("target", Vector3.ZERO),
		context.get("direction", Vector3.RIGHT),
		profile,
		float(context.get("length_scale", 1.0)),
		float(context.get("width_scale", 1.0)),
		float(context.get("seed", randf_range(0.0, 90.0)))
	)

func play_sheet(at: Vector3, direction: Vector3, profile: VFXProfile3D, length_scale := 1.0, width_scale := 1.0, seed := 0.0) -> void:
	begin()
	position = at
	var active := profile if profile != null else _fallback_profile()
	var params := active.parameters
	var length := active.size * float(params.get("length", 1.35)) * length_scale
	var width := active.size * float(params.get("width", 0.48)) * width_scale
	var duration := active.duration
	var mesh := _make_sheet_mesh(direction, length, width, seed)
	var shadow := MeshInstance3D.new()
	shadow.name = "BroadEnergyShadow"
	shadow.mesh = mesh
	shadow.scale = Vector3(1.03, 1.16, 1.0)
	shadow.material_override = _make_material(active, seed, true)
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(shadow)
	var body := MeshInstance3D.new()
	body.name = "BroadEnergyBody"
	body.mesh = mesh
	body.material_override = _make_material(active, seed, false)
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(body)
	var scale_setter := func(value: float) -> void:
		if is_instance_valid(body): body.scale = Vector3(value, value, 1.0)
		if is_instance_valid(shadow): shadow.scale = Vector3(value * 1.03, value * 1.16, 1.0)
	CURVES.tween_method(self, scale_setter, 0.18, 1.0, duration * 0.20, "ease_out_back")
	CURVES.tween_method(self, _set_reveal, 0.0, 1.0, duration * 0.24, "explosive_out")
	var fade := track_tween(create_tween())
	fade.tween_interval(duration * 0.46)
	fade.tween_method(_set_dissolve, 0.0, 1.0, duration * 0.48).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await get_tree().create_timer(duration + 0.04).timeout
	finish()

func _make_sheet_mesh(direction: Vector3, length: float, width: float, seed: float) -> ArrayMesh:
	var forward := Vector3(direction.x, direction.y, 0.0).normalized()
	if forward.length_squared() < 0.001: forward = Vector3.RIGHT
	var side := Vector3(-forward.y, forward.x, 0.0)
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var sections := 9
	for i in range(sections):
		var t := float(i) / float(sections - 1)
		var envelope := pow(maxf(sin(t * PI), 0.0), 0.48)
		var center_wobble := sin(seed * 0.71 + float(i) * 1.83) * width * 0.10 * envelope
		var half_width := maxf(width * envelope * (0.74 + 0.18 * sin(seed + float(i) * 2.31)), width * 0.018)
		var center := forward * length * t + side * center_wobble
		vertices.append(center - side * half_width * (0.88 + 0.10 * sin(float(i) * 1.7)))
		vertices.append(center + side * half_width * (1.04 + 0.12 * cos(float(i) * 2.1)))
		uvs.append(Vector2(t, 0.0))
		uvs.append(Vector2(t, 1.0))
		if i < sections - 1:
			var base := i * 2
			indices.append_array(PackedInt32Array([base, base + 1, base + 3, base, base + 3, base + 2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _make_material(profile: VFXProfile3D, seed: float, halo: bool) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SHADER_CACHE.get_shader(SHEET_SHADER)
	material.set_shader_parameter("shadow_color", profile.dark_color.darkened(0.24) if halo else profile.dark_color)
	material.set_shader_parameter("main_color", profile.main_color.darkened(0.34) if halo else profile.main_color)
	material.set_shader_parameter("core_color", profile.main_color if halo else profile.core_color)
	material.set_shader_parameter("reveal", 0.0)
	material.set_shader_parameter("dissolve", 0.0)
	material.set_shader_parameter("opacity", vfx_alpha)
	material.set_shader_parameter("energy", profile.emission_energy * (0.38 if halo else 0.82))
	material.set_shader_parameter("seed", seed)
	material.set_shader_parameter("halo", 1.0 if halo else 0.0)
	_materials.append(material)
	return material

func _set_reveal(value: float) -> void:
	for material in _materials:
		if is_instance_valid(material): material.set_shader_parameter("reveal", value)

func _set_dissolve(value: float) -> void:
	for material in _materials:
		if is_instance_valid(material):
			material.set_shader_parameter("dissolve", value)
			material.set_shader_parameter("opacity", vfx_alpha * (1.0 - value * 0.64))

func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	for material in _materials:
		if is_instance_valid(material): material.set_shader_parameter("opacity", vfx_alpha)

func _fallback_profile() -> VFXProfile3D:
	var profile := VFXProfile3D.new()
	profile.dark_color = Color(0.10, 0.01, 0.018)
	profile.main_color = Color(0.92, 0.12, 0.025)
	profile.core_color = Color(1.0, 0.72, 0.26)
	profile.size = 1.0
	profile.duration = 0.52
	profile.emission_energy = 3.2
	profile.parameters = {"length": 1.35, "width": 0.48}
	return profile
