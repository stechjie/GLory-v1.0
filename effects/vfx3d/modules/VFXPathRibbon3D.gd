extends VFXBlockRoot
class_name VFXPathRibbon3D

const CURVES := preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")
const BLADE_MASK: Texture2D = preload("res://assets/vfx/textures/slash/slash_blade_mask.png")
const EROSION_MASK: Texture2D = preload("res://assets/vfx/textures/slash/slash_erosion_mask.png")
const SPARK_MASK: Texture2D = preload("res://assets/vfx/textures/slash/slash_spark_mask.png")

const PATH_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 shadow_color : source_color = vec4(0.08, 0.02, 0.18, 1.0);
uniform vec4 main_color : source_color = vec4(0.65, 0.12, 1.0, 1.0);
uniform vec4 core_color : source_color = vec4(1.0, 0.78, 1.0, 1.0);
uniform sampler2D blade_mask : filter_linear_mipmap;
uniform sampler2D erosion_mask : filter_linear_mipmap;
uniform float reveal = 0.0;
uniform float dissolve = 0.0;
uniform float opacity = 1.0;
uniform float energy = 3.4;
uniform float edge_seed = 0.0;
uniform float layer_alpha = 1.0;
uniform float core_strength = 1.0;

void fragment() {
	vec2 blade_uv = vec2(1.0 - UV.x, UV.y);
	float painted = texture(blade_mask, blade_uv).a;
	float across = abs(UV.y * 2.0 - 1.0);
	vec2 erosion_uv = vec2(fract(UV.x * 0.82 + edge_seed * 0.017), clamp(UV.y * 0.74 + 0.13, 0.0, 1.0));
	float fracture = texture(erosion_mask, erosion_uv).a;
	float body = smoothstep(0.12, 0.62, painted);
	float hot_core = (1.0 - smoothstep(0.08, 0.42, across)) * body * core_strength;
	float revealed = 1.0 - smoothstep(reveal, reveal + 0.045, UV.x);
	float directional_fade = 1.0 - smoothstep(0.0, 0.18, dissolve + UV.x - 0.96);
	float crack_cut = 1.0 - fracture * smoothstep(0.08, 0.76, dissolve) * 0.78;
	float fragment_break = 0.78 + 0.22 * step(0.18, sin(UV.x * 89.0 + edge_seed) + sin(UV.x * 37.0));
	float pulse = 0.92 + 0.08 * sin(TIME * 22.0 - UV.x * 28.0);
	float mask = painted * revealed * directional_fade * crack_cut * mix(1.0, fragment_break, smoothstep(0.32, 0.9, dissolve));
	vec3 color = mix(shadow_color.rgb, main_color.rgb, body);
	color = mix(color, core_color.rgb, hot_core);
	ALBEDO = color;
	EMISSION = color * energy * (0.46 + body * 0.78 + hot_core * 1.18) * pulse;
	ALPHA = clamp(mask * opacity * layer_alpha * (0.26 + body * 0.60 + hot_core * 0.22), 0.0, 0.99);
}
"""

const SPARK_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform sampler2D spark_mask : filter_linear_mipmap;
uniform vec4 spark_color : source_color = vec4(1.0, 0.7, 1.0, 1.0);
uniform float opacity = 0.0;
void fragment() {
	float mask = texture(spark_mask, UV).a;
	ALBEDO = spark_color.rgb;
	EMISSION = spark_color.rgb * 5.4;
	ALPHA = mask * opacity;
}
"""

var _materials: Array[ShaderMaterial] = []

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	var points: PackedVector3Array = context.get("points", PackedVector3Array())
	var normal: Vector3 = context.get("plane_normal", Vector3.FORWARD)
	play_path(points, normal, profile)

func play_path(points: PackedVector3Array, plane_normal: Vector3, profile: VFXProfile3D = null) -> void:
	begin()
	if points.size() < 2:
		finish()
		return
	var params: Dictionary = profile.parameters if profile != null else {}
	var duration: float = profile.duration if profile != null else 0.52
	var width: float = float(params.get("width", 0.34)) * (profile.size if profile != null else 1.0)
	var taper_both := bool(params.get("taper_both_ends", true))
	var curve_bias := float(params.get("curve_bias", 1.0))
	var halo_node := _make_path_mesh(points, plane_normal, width * float(params.get("halo_width", 1.52)), taper_both, curve_bias)
	var halo_material := _make_material(profile, 0.34, true)
	halo_node.material_override = halo_material
	add_child(halo_node)
	var mesh_node := _make_path_mesh(points, plane_normal, width, taper_both, curve_bias)
	var material := _make_material(profile, 1.0, false)
	mesh_node.material_override = material
	add_child(mesh_node)
	var local_materials: Array[ShaderMaterial] = [halo_material, material]
	_spawn_sparks(points, plane_normal, profile, duration)
	var reveal_time := duration * float(params.get("reveal_ratio", 0.28))
	var hold_time := duration * float(params.get("hold_ratio", 0.25))
	var dissolve_time := maxf(duration - reveal_time - hold_time, 0.08)
	var reveal_setter := func(value: float) -> void:
		for active_material in local_materials:
			if is_instance_valid(active_material):
				active_material.set_shader_parameter("reveal", value)
	CURVES.tween_method(self, reveal_setter, 0.0, 1.0, reveal_time, "explosive_out")
	var fade := track_tween(create_tween())
	fade.tween_interval(reveal_time + hold_time)
	var dissolve_setter := func(value: float) -> void:
		for active_material in local_materials:
			if is_instance_valid(active_material):
				active_material.set_shader_parameter("dissolve", value)
				active_material.set_shader_parameter("opacity", vfx_alpha * (1.0 - value * 0.82))
	fade.tween_method(dissolve_setter, 0.0, 1.0, dissolve_time).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await get_tree().create_timer(duration + 0.05).timeout
	finish()

func _make_path_mesh(points: PackedVector3Array, plane_normal: Vector3, width: float, taper_both_ends: bool, curve_bias: float) -> MeshInstance3D:
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var normal := plane_normal.normalized()
	if normal.length_squared() < 0.001:
		normal = Vector3.FORWARD
	for i in range(points.size()):
		var t := float(i) / float(points.size() - 1)
		var before: Vector3 = points[maxi(i - 1, 0)]
		var after: Vector3 = points[mini(i + 1, points.size() - 1)]
		var tangent := (after - before).normalized()
		var side := tangent.cross(normal).normalized()
		if side.length_squared() < 0.001:
			side = Vector3.UP
		var taper := pow(sin(t * PI), maxf(curve_bias, 0.15)) if taper_both_ends else pow(t, 0.48)
		var asymmetric := 0.74 + 0.26 * sin(t * PI)
		var half_width := maxf(width * taper * asymmetric, width * 0.018)
		vertices.append(points[i] - side * half_width)
		vertices.append(points[i] + side * half_width)
		uvs.append(Vector2(t, 0.0))
		uvs.append(Vector2(t, 1.0))
		if i < points.size() - 1:
			var base := i * 2
			indices.append_array(PackedInt32Array([base, base + 1, base + 3, base, base + 3, base + 2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

func _make_material(profile: VFXProfile3D, layer_alpha := 1.0, halo_layer := false) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = PATH_SHADER
	material.shader = shader
	var main := profile.main_color if profile != null else Color(0.58, 0.16, 1.0)
	var core := profile.core_color if profile != null else Color(1.0, 0.78, 1.0)
	var dark := profile.dark_color if profile != null else Color(0.08, 0.015, 0.16)
	material.set_shader_parameter("shadow_color", dark.darkened(0.22) if halo_layer else dark)
	material.set_shader_parameter("main_color", main.darkened(0.30) if halo_layer else main)
	material.set_shader_parameter("core_color", main if halo_layer else core)
	material.set_shader_parameter("blade_mask", BLADE_MASK)
	material.set_shader_parameter("erosion_mask", EROSION_MASK)
	material.set_shader_parameter("energy", (profile.emission_energy * 0.46 if halo_layer else profile.emission_energy) if profile != null else (1.55 if halo_layer else 3.4))
	material.set_shader_parameter("reveal", 0.0)
	material.set_shader_parameter("dissolve", 0.0)
	material.set_shader_parameter("opacity", vfx_alpha)
	material.set_shader_parameter("edge_seed", randf_range(0.0, 12.0))
	material.set_shader_parameter("layer_alpha", layer_alpha)
	material.set_shader_parameter("core_strength", 0.0 if halo_layer else 1.0)
	_materials.append(material)
	return material

func _spawn_sparks(points: PackedVector3Array, plane_normal: Vector3, profile: VFXProfile3D, duration: float) -> void:
	if profile == null:
		return
	var count := int(profile.parameters.get("spark_count", 0))
	if count <= 0:
		return
	var normal := plane_normal.normalized()
	if normal.length_squared() < 0.001:
		normal = Vector3.FORWARD
	for i in range(count):
		var t := clampf((float(i) + randf_range(0.45, 1.0)) / float(count + 1), 0.08, 0.92)
		var index := clampi(roundi(t * float(points.size() - 1)), 1, points.size() - 2)
		var tangent := (points[index + 1] - points[index - 1]).normalized()
		var side := tangent.cross(normal).normalized()
		if side.length_squared() < 0.001:
			side = Vector3.UP
		var outward := (side * (-1.0 if i % 2 == 0 else 1.0) + tangent * randf_range(-0.24, 0.24)).normalized()
		var spark_length := randf_range(0.48, 0.82) * profile.size
		var spark_width := randf_range(0.12, 0.22) * profile.size
		var spark := _make_spark_mesh(outward, normal, spark_length, spark_width)
		spark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material := ShaderMaterial.new()
		var shader := Shader.new()
		shader.code = SPARK_SHADER
		material.shader = shader
		material.set_shader_parameter("spark_mask", SPARK_MASK)
		material.set_shader_parameter("spark_color", profile.core_color)
		material.set_shader_parameter("opacity", 0.0)
		spark.material_override = material
		spark.position = points[index]
		add_child(spark)
		var delay := duration * randf_range(0.03, 0.16)
		var life := duration * randf_range(0.30, 0.46)
		var travel := randf_range(0.42, 0.78) * profile.size
		var tween := track_tween(create_tween())
		tween.tween_interval(delay)
		tween.tween_property(material, "shader_parameter/opacity", vfx_alpha, minf(life * 0.18, 0.035))
		tween.set_parallel(true)
		tween.tween_property(spark, "position", points[index] + outward * travel, life).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_property(material, "shader_parameter/opacity", 0.0, life).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.set_parallel(false)
		tween.tween_callback(spark.queue_free)

func _make_spark_mesh(direction: Vector3, plane_normal: Vector3, length: float, width: float) -> MeshInstance3D:
	var forward := direction.normalized()
	var side := forward.cross(plane_normal).normalized()
	if side.length_squared() < 0.001:
		side = Vector3.UP
	var vertices := PackedVector3Array([
		-side * width * 0.52,
		side * width * 0.52,
		forward * length + side * width * 0.035,
		forward * length - side * width * 0.035,
	])
	var uvs := PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(0.0, 1.0),
		Vector2(1.0, 1.0),
		Vector2(1.0, 0.0),
	])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	return node

func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	for material in _materials:
		if material != null:
			material.set_shader_parameter("opacity", vfx_alpha)
