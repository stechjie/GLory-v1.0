extends VFXBlockRoot
class_name VFXPortalRim3D

const CURVES := preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")

const RIM_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 shadow_color : source_color;
uniform vec4 main_color : source_color;
uniform vec4 core_color : source_color;
uniform float reveal = 0.0;
uniform float dissolve = 0.0;
uniform float opacity = 1.0;
uniform float seed = 0.0;
uniform float energy = 3.0;
float hash21(vec2 p) { return fract(sin(dot(p, vec2(127.1,311.7)) + seed) * 43758.5453); }
void fragment() {
	float across = abs(UV.y * 2.0 - 1.0);
	float rough = hash21(floor(UV * vec2(29.0, 9.0))) * 0.20;
	float body = smoothstep(0.98 + rough, 0.38 + rough * 0.25, across);
	float head = 1.0 - smoothstep(reveal, reveal + 0.055, UV.x);
	float erode = step(dissolve, hash21(floor(UV * vec2(37.0, 13.0))) * 0.68 + (1.0 - UV.x) * 0.22);
	float hot = (1.0 - smoothstep(0.06, 0.38, across)) * body;
	float mask = body * head * erode;
	vec3 color = mix(shadow_color.rgb, main_color.rgb, body);
	color = mix(color, core_color.rgb, hot * 0.72);
	ALBEDO = color;
	EMISSION = color * energy * (0.54 + hot * 0.86);
	ALPHA = clamp(mask * opacity * (0.86 - dissolve * 0.28), 0.0, 0.95);
}
"""

var _material: ShaderMaterial

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	play_rim(context.get("target", Vector3.ZERO), profile, float(context.get("radius_scale", 1.0)), float(context.get("seed", randf_range(0.0, 90.0))))

func play_rim(at: Vector3, profile: VFXProfile3D, radius_scale := 1.0, seed := 0.0) -> void:
	begin()
	var active := profile if profile != null else _fallback_profile()
	position = at
	var mesh := _make_rim_mesh(active.size * 0.78 * radius_scale, active.size * 0.98 * radius_scale, active.size * 0.18, seed)
	var node := MeshInstance3D.new()
	node.name = "ThickIrregularPortalRim"
	node.mesh = mesh
	_material = ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = RIM_SHADER
	_material.shader = shader
	_material.set_shader_parameter("shadow_color", active.dark_color)
	_material.set_shader_parameter("main_color", active.main_color)
	_material.set_shader_parameter("core_color", active.core_color)
	_material.set_shader_parameter("reveal", 0.0)
	_material.set_shader_parameter("dissolve", 0.0)
	_material.set_shader_parameter("opacity", vfx_alpha)
	_material.set_shader_parameter("seed", seed)
	_material.set_shader_parameter("energy", active.emission_energy * 0.72)
	node.material_override = _material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.scale = Vector3(0.12, 0.18, 1.0)
	add_child(node)
	CURVES.tween_method(self, func(v: float) -> void:
		if is_instance_valid(node): node.scale = Vector3(v, lerpf(0.22, 1.0, v), 1.0),
		0.12, 1.0, active.duration * 0.20, "ease_out_back")
	CURVES.tween_method(self, _set_reveal, 0.0, 1.0, active.duration * 0.26, "explosive_out")
	var fade := track_tween(create_tween())
	fade.tween_interval(active.duration * 0.70)
	fade.tween_method(_set_dissolve, 0.0, 1.0, active.duration * 0.26).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await get_tree().create_timer(active.duration + 0.04).timeout
	finish()

func _make_rim_mesh(radius_x: float, radius_y: float, width: float, seed: float) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var segments := 52
	for i in range(segments + 1):
		var t := float(i) / float(segments)
		var angle := t * TAU
		var wobble := sin(angle * 5.0 + seed) * 0.055 + sin(angle * 11.0 - seed * 0.37) * 0.025
		var center := Vector3(cos(angle) * radius_x * (1.0 + wobble), sin(angle) * radius_y * (1.0 + wobble * 0.72), 0.0)
		var radial := Vector3(cos(angle), sin(angle), 0.0).normalized()
		var local_width := width * (0.76 + 0.24 * sin(angle * 7.0 + seed * 0.23))
		vertices.append(center - radial * local_width)
		vertices.append(center + radial * local_width)
		uvs.append(Vector2(t, 0.0))
		uvs.append(Vector2(t, 1.0))
		if i < segments:
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

func _set_reveal(value: float) -> void:
	if _material != null: _material.set_shader_parameter("reveal", value)

func _set_dissolve(value: float) -> void:
	if _material != null: _material.set_shader_parameter("dissolve", value)

func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	if _material != null: _material.set_shader_parameter("opacity", vfx_alpha)

func _fallback_profile() -> VFXProfile3D:
	var profile := VFXProfile3D.new()
	profile.dark_color = Color(0.012, 0.055, 0.064)
	profile.main_color = Color(0.02, 0.46, 0.48)
	profile.core_color = Color(0.52, 0.96, 0.80)
	profile.size = 1.0
	profile.duration = 1.36
	profile.emission_energy = 3.2
	return profile
