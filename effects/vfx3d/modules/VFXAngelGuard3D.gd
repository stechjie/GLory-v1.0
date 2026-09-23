extends VFXBlockRoot
class_name VFXAngelGuard3D

const SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")
const ANGEL_SHIELD_ATLAS := "res://assets/vfx/oga/skills/angel_shield.png"

# The downloaded atlas is a sheet of shield variants, not a conventional
# frame-by-frame animation.  The production effect deliberately selects two
# authored cells from that new sheet and animates their reveal; cycling all
# twenty cells would flash through unrelated colours in the battle camera.
const CREST_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform sampler2D atlas_texture : source_color;
uniform vec2 atlas_grid = vec2(5.0, 4.0);
uniform float atlas_frame = 16.0;
uniform vec4 tint : source_color = vec4(1.0);
uniform float opacity = 0.0;
uniform float reveal = 0.0;
void vertex() {
    MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}
void fragment() {
    float column = mod(atlas_frame, atlas_grid.x);
    float row = floor(atlas_frame / atlas_grid.x);
    vec2 atlas_uv = (clamp(UV, vec2(0.002), vec2(0.998)) + vec2(column, row)) / atlas_grid;
    vec4 tex = texture(atlas_texture, atlas_uv);
    float radial = length((UV - vec2(0.5)) * vec2(1.0, 0.86));
    float open = 1.0 - smoothstep(reveal - 0.05, reveal + 0.16, radial);
    float edge = 1.0 - smoothstep(0.018, 0.072, abs(radial - reveal));
    float alpha = tex.a * max(open, edge) * opacity;
    ALBEDO = tex.rgb * tint.rgb;
    EMISSION = ALBEDO * (1.15 + edge * 1.55);
    ALPHA = alpha * tint.a;
}
"""

const FRAGMENT_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 dark_color : source_color;
uniform vec4 main_color : source_color;
uniform vec4 core_color : source_color;
uniform float opacity = 0.0;
uniform float phase = 0.0;
uniform float seed = 0.0;
void vertex() {
    MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}
void fragment() {
    float across = abs(UV.y * 2.0 - 1.0);
    float rough = 0.90 + 0.10 * sin(UV.x * 29.0 + seed) + 0.055 * sin(UV.x * 61.0 - seed * 1.7);
    float ends = smoothstep(0.0, 0.11, UV.x) * (1.0 - smoothstep(0.84, 1.0, UV.x));
    float silhouette = (1.0 - smoothstep(0.64, rough, across)) * ends;
    float body = 1.0 - smoothstep(0.22, 0.70, across);
    float core = 1.0 - smoothstep(0.03, 0.20, across);
    float brush = 0.78 + 0.22 * sin(UV.x * 17.0 + TIME * 1.2 + phase);
    vec3 color = mix(dark_color.rgb, main_color.rgb, body);
    color = mix(color, core_color.rgb, core * 0.68);
    ALBEDO = color;
    EMISSION = color * (0.72 + body * 0.58 + core * 1.35);
    ALPHA = silhouette * brush * opacity * (0.72 + core * 0.24);
}
"""

var _target_ref: WeakRef
var _target_offset := Vector3.ZERO
var _duration := 6.0
var _elapsed := 0.0
var _fade_time := 0.48
var _form_time := 0.32
var _pulse_speed := 1.35
var _fragment_nodes: Array[MeshInstance3D] = []
var _fragment_materials: Array[ShaderMaterial] = []
var _persistent_crest: MeshInstance3D = null
var _persistent_crest_material: ShaderMaterial = null

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	play_guard(context.get("target", Vector3.ZERO), profile, context)

func play_guard(anchor: Vector3, profile: VFXProfile3D, context: Dictionary = {}) -> void:
	begin()
	position = anchor
	_bind_target(context.get("target_node"), anchor)
	_duration = maxf(0.9, float(context.get("status_duration", profile.duration)))
	_fade_time = minf(float(profile.parameters.get("fade_time", 0.48)), _duration * 0.35)
	_form_time = minf(float(profile.parameters.get("form_time", 0.32)), _duration * 0.25)
	_pulse_speed = float(profile.parameters.get("pulse_speed", 1.35))
	_spawn_activation_crests(profile)
	_spawn_persistent_crest(profile)
	_spawn_guard_fragments(profile)
	_spawn_feather_strokes(profile)
	_elapsed = 0.0
	set_process(true)

func _process(delta: float) -> void:
	if _finished:
		return
	_elapsed += delta
	_track_target()
	var formed := _ease_out_back(clampf(_elapsed / maxf(_form_time, 0.01), 0.0, 1.0))
	var fade := 1.0
	if _elapsed > _duration - _fade_time:
		fade = 1.0 - _smooth01((_elapsed - (_duration - _fade_time)) / maxf(_fade_time, 0.01))
	var breathe := 0.965 + 0.035 * sin(_elapsed * TAU * _pulse_speed)
	if is_instance_valid(_persistent_crest) and _persistent_crest_material != null:
		_persistent_crest.scale = Vector3.ONE * formed * breathe
		_persistent_crest_material.set_shader_parameter("opacity", fade * (0.43 + 0.045 * sin(_elapsed * TAU * _pulse_speed)))
	for index in range(_fragment_nodes.size()):
		var node := _fragment_nodes[index]
		if not is_instance_valid(node):
			continue
		var stagger := clampf((_elapsed - float(index) * 0.055) / maxf(_form_time, 0.01), 0.0, 1.0)
		var local_form := _ease_out_back(stagger)
		node.scale = Vector3.ONE * local_form * breathe
		node.position.y = sin(_elapsed * (1.15 + float(index) * 0.09) + float(index) * 1.8) * 0.018
		var material := _fragment_materials[index]
		material.set_shader_parameter("opacity", fade * minf(1.0, formed) * (0.86 + 0.06 * sin(_elapsed * 2.1 + float(index))))
	if _elapsed >= _duration:
		set_process(false)
		finish()

func _spawn_activation_crests(profile: VFXProfile3D) -> void:
	var texture := vfx_texture(ANGEL_SHIELD_ATLAS)
	if texture == null:
		push_warning("Angel Guard atlas missing: %s" % ANGEL_SHIELD_ATLAS)
		return
	var white_frame := int(profile.parameters.get("crest_white_frame", 16))
	_spawn_crest("AngelGuardWhiteCross", texture, white_frame, profile.size * Vector2(0.94, 0.94), Color(1.0, 1.0, 1.0), 0.0, 0.72)
	_spawn_crest("AngelGuardWhiteCrossEcho", texture, white_frame, profile.size * Vector2(0.86, 0.88), Color(0.66, 0.84, 1.0), 0.10, 0.90)

func _spawn_persistent_crest(profile: VFXProfile3D) -> void:
	var texture := vfx_texture(ANGEL_SHIELD_ATLAS)
	if texture == null:
		return
	var quad := QuadMesh.new()
	quad.size = profile.size * Vector2(0.96, 0.92)
	var node := MeshInstance3D.new()
	node.name = "AngelGuardPersistentWingShield"
	node.mesh = quad
	node.position = VFXBlockRoot.vfx_toward_camera(0.024)
	node.scale = Vector3.ONE * 0.04
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := ShaderMaterial.new()
	material.shader = SHADER_CACHE.get_shader(CREST_SHADER)
	material.set_shader_parameter("atlas_texture", texture)
	material.set_shader_parameter("atlas_frame", float(profile.parameters.get("crest_white_frame", 16)))
	material.set_shader_parameter("tint", Color(0.94, 0.98, 1.0, 1.0))
	material.set_shader_parameter("opacity", 0.0)
	material.set_shader_parameter("reveal", 0.94)
	node.material_override = material
	add_child(node)
	_persistent_crest = node
	_persistent_crest_material = material

func _spawn_crest(node_name: String, texture: Texture2D, frame: int, size: Vector2, tint: Color, delay: float, lifetime: float) -> void:
	var quad := QuadMesh.new()
	quad.size = size
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = quad
	node.position = VFXBlockRoot.vfx_toward_camera(0.055)
	node.scale = Vector3.ONE * 0.08
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := ShaderMaterial.new()
	material.shader = SHADER_CACHE.get_shader(CREST_SHADER)
	material.set_shader_parameter("atlas_texture", texture)
	material.set_shader_parameter("atlas_frame", float(frame))
	material.set_shader_parameter("tint", tint)
	material.set_shader_parameter("opacity", 0.0)
	material.set_shader_parameter("reveal", 0.10)
	node.material_override = material
	add_child(node)
	var tween := track_tween(create_tween())
	tween.tween_interval(delay)
	tween.set_parallel(true)
	tween.tween_property(node, "scale", Vector3.ONE * 1.08, 0.20).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_method(func(value: float) -> void:
		if is_instance_valid(material): material.set_shader_parameter("opacity", value), 0.0, 0.92, 0.13)
	tween.tween_method(func(value: float) -> void:
		if is_instance_valid(material): material.set_shader_parameter("reveal", value), 0.10, 0.82, 0.24)
	tween.set_parallel(false)
	tween.tween_interval(maxf(0.02, lifetime - 0.31))
	tween.set_parallel(true)
	tween.tween_property(node, "scale", Vector3.ONE * 0.82, 0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_method(func(value: float) -> void:
		if is_instance_valid(material): material.set_shader_parameter("opacity", value), 0.92, 0.0, 0.20)
	tween.set_parallel(false)
	tween.tween_callback(node.queue_free)

func _spawn_guard_fragments(profile: VFXProfile3D) -> void:
	var ranges := [Vector2(2.28, 3.72), Vector2(-0.58, 0.83), Vector2(0.92, 2.16)]
	for index in range(ranges.size()):
		var span: Vector2 = ranges[index]
		var node := _make_fragment(profile.size * 0.57, profile.size * 0.70, profile.size * 0.090, span.x, span.y, 20, float(index) * 7.7)
		node.name = "AngelGuardFragment_%d" % index
		node.position = VFXBlockRoot.vfx_toward_camera(0.028 + float(index) * 0.006)
		node.scale = Vector3.ONE * 0.04
		add_child(node)
		_fragment_nodes.append(node)

func _make_fragment(radius_x: float, radius_y: float, thickness: float, start: float, end: float, segments: int, seed: float) -> MeshInstance3D:
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for index in range(segments + 1):
		var t := float(index) / float(segments)
		var angle := lerpf(start, end, t)
		var wobble := sin(t * PI * 5.0 + seed) * thickness * 0.32 + sin(t * PI * 11.0 - seed) * thickness * 0.12
		var normal := Vector2(cos(angle), sin(angle)).normalized()
		var centre := Vector2(cos(angle) * radius_x, sin(angle) * radius_y)
		var inner := centre - normal * (thickness + wobble)
		var outer := centre + normal * (thickness * 0.48 + wobble)
		vertices.append(Vector3(inner.x, inner.y, 0.0))
		vertices.append(Vector3(outer.x, outer.y, 0.0))
		uvs.append(Vector2(t, 0.0))
		uvs.append(Vector2(t, 1.0))
		if index < segments:
			var base := index * 2
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
	var material := ShaderMaterial.new()
	material.shader = SHADER_CACHE.get_shader(FRAGMENT_SHADER)
	material.set_shader_parameter("dark_color", Color(0.025, 0.070, 0.18, 1.0))
	material.set_shader_parameter("main_color", Color(0.38, 0.68, 1.0, 1.0))
	material.set_shader_parameter("core_color", Color(0.98, 1.0, 1.0, 1.0))
	material.set_shader_parameter("opacity", 0.0)
	material.set_shader_parameter("phase", seed * 0.13)
	material.set_shader_parameter("seed", seed)
	node.material_override = material
	_fragment_materials.append(material)
	return node

func _spawn_feather_strokes(profile: VFXProfile3D) -> void:
	var count := mini(8, maxi(4, profile.particle_count))
	for index in range(count):
		var side := -1.0 if index % 2 == 0 else 1.0
		var row := float(index / 2)
		var node := _make_feather(profile, side, row, index)
		add_child(node)
		var start := Vector3(side * profile.size * (0.20 + row * 0.035), profile.size * (-0.08 + row * 0.08), 0.02)
		var finish_at := start + Vector3(side * profile.size * (0.22 + row * 0.025), profile.size * (0.18 + row * 0.035), 0.0)
		node.position = start
		node.scale = Vector3.ONE * 0.10
		var delay := 0.10 + row * 0.045
		var tween := track_tween(create_tween())
		tween.tween_interval(delay)
		tween.set_parallel(true)
		tween.tween_property(node, "position", finish_at, 0.52).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_property(node, "scale", Vector3.ONE * (0.72 + row * 0.04), 0.20).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tween.set_parallel(false)
		tween.tween_property(node, "scale", Vector3(0.12, 0.26, 1.0), 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.tween_callback(node.queue_free)

func _make_feather(profile: VFXProfile3D, side: float, row: float, index: int) -> MeshInstance3D:
	var width := profile.size * (0.025 + row * 0.004)
	var length := profile.size * (0.16 + row * 0.018)
	var vertices := PackedVector3Array([
		Vector3(0.0, -length * 0.52, 0.0),
		Vector3(-width, -length * 0.06, 0.0),
		Vector3(0.0, length * 0.56, 0.0),
		Vector3(width * 0.72, -length * 0.02, 0.0),
	])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := MeshInstance3D.new()
	node.name = "AngelGuardFeather_%d" % index
	node.mesh = mesh
	node.rotation.z = side * (0.22 + row * 0.08)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(0.90, 0.96, 1.0, 0.88)
	material.emission_enabled = true
	material.emission = Color(0.70, 0.88, 1.0)
	material.emission_energy_multiplier = minf(profile.emission_energy, 2.2)
	node.material_override = material
	return node

func _bind_target(node_value: Variant, anchor: Vector3) -> void:
	_target_ref = null
	if not (is_instance_valid(node_value) and node_value is Node3D):
		return
	_target_ref = weakref(node_value)
	_target_offset = anchor - (node_value as Node3D).global_position

func _track_target() -> void:
	if _target_ref == null:
		return
	var target: Variant = _target_ref.get_ref()
	if not (is_instance_valid(target) and target is Node3D):
		return
	global_position = (target as Node3D).global_position + _target_offset

func _smooth01(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

func _ease_out_back(value: float) -> float:
	var t := clampf(value, 0.0, 1.0) - 1.0
	return 1.0 + 2.70158 * t * t * t + 1.70158 * t * t
