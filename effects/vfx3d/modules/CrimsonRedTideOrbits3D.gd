extends Node3D
class_name CrimsonRedTideOrbits3D

# Presentation only. One persistent torso orbit per Crimson 7 stack, capped at five.
# The battle simulator owns crimson_pulse_stacks; this module never changes stats.
const CURVES := preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")
const ORBIT_SHADER := preload("res://effects/vfx3d/shaders/crimson_red_tide_orbit.gdshader")
const GLOW_SHADER := preload("res://effects/vfx3d/shaders/crimson_red_tide_glow.gdshader")
const DEFAULT_PROFILE := preload("res://effects/vfx3d/profiles/examples/crimson_red_tide_orbits.tres")
const MAX_STACKS := 5
const SEGMENTS := 80

# Distinct heights, tilt directions and radii make all five counts legible.
const HEIGHTS := [0.40, 0.52, 0.57, 0.46, 0.63]
const TILTS := [0.035, 0.20, -0.21, 0.12, -0.11]
const TILT_PHASES := [0.25, 1.05, 2.10, 2.70, 4.05]
const RADII := [0.89, 1.00, 1.08, 0.94, 1.15]
const SPIN_RATIOS := [1.00, -0.83, 0.72, -1.10, 0.89]

static var _body_meshes: Array[ArrayMesh] = []
static var _filament_meshes: Array[ArrayMesh] = []
static var _halo_meshes: Array[ArrayMesh] = []

var _profile: VFXProfile3D
var _rings: Array[Node3D] = []
var _bodies: Array[MeshInstance3D] = []
var _filaments: Array[MeshInstance3D] = []
var _halos: Array[MeshInstance3D] = []
var _body_materials: Array[ShaderMaterial] = []
var _filament_materials: Array[ShaderMaterial] = []
var _halo_materials: Array[ShaderMaterial] = []
var _ages: Array[float] = []
var _alphas: Array[float] = []
var _stacks := 0


func _ready() -> void:
	if _profile == null:
		_profile = DEFAULT_PROFILE
	_build_once()
	_apply_profile()
	set_process(false)


func configure(profile: VFXProfile3D, actor_height: float = 1.0) -> void:
	_profile = profile if profile != null else DEFAULT_PROFILE
	scale = Vector3.ONE * maxf(0.15, actor_height) * _profile.size
	if is_inside_tree():
		_apply_profile()


func set_stacks(value: int) -> void:
	var next_count := clampi(value, 0, MAX_STACKS)
	if next_count == _stacks:
		return
	var previous := _stacks
	_stacks = next_count
	if _stacks > previous:
		for i in range(previous, _stacks):
			_ages[i] = -0.055 * float(i - previous)
	set_process(true)


func _process(delta: float) -> void:
	var any_visible := false
	var spin_speed := float(_profile.parameters.get("spin_speed", 1.75))
	var base_opacity := float(_profile.parameters.get("opacity", 0.91))
	for i in MAX_STACKS:
		var active := i < _stacks
		if active:
			_ages[i] += delta
		var age: float = _ages[i]
		var arrival := CURVES.sample("explosive_out", age / 0.28) if active and age > 0.0 else 0.0
		var target_alpha := base_opacity if active and age > 0.0 else 0.0
		var follow := 1.0 - exp(-delta * (16.0 if active else 10.0 + float(i) * 1.4))
		_alphas[i] = lerpf(_alphas[i], target_alpha, follow)
		var flare := CURVES.sample("pulse", age / 0.38) if active and age >= 0.0 and age < 0.38 else 0.0
		var visible_now := _alphas[i] > 0.008
		_halos[i].visible = visible_now
		_bodies[i].visible = visible_now
		_filaments[i].visible = visible_now
		if visible_now:
			any_visible = true
			_rings[i].rotate_y(delta * spin_speed * float(SPIN_RATIOS[i]))
		for material in [_halo_materials[i], _body_materials[i], _filament_materials[i]]:
			material.set_shader_parameter("opacity", _alphas[i])
			material.set_shader_parameter("reveal", arrival if active else 1.0)
			material.set_shader_parameter("flare", flare)
	if _stacks == 0 and not any_visible:
		set_process(false)


func _build_once() -> void:
	if _body_meshes.is_empty():
		for i in MAX_STACKS:
			_halo_meshes.append(_make_orbit_mesh(i, 0.115))
			_body_meshes.append(_make_orbit_mesh(i, 0.042))
			_filament_meshes.append(_make_orbit_mesh(i, 0.026))
	for i in MAX_STACKS:
		var orbit := Node3D.new()
		orbit.name = "Orbit%d" % (i + 1)
		add_child(orbit)
		_rings.append(orbit)
		for layer in 3:
			var ribbon := MeshInstance3D.new()
			ribbon.name = ["SoftRedHalo", "CrimsonEnergyBody", "MovingHotFilament"][layer]
			ribbon.mesh = [_halo_meshes[i], _body_meshes[i], _filament_meshes[i]][layer]
			ribbon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			ribbon.visible = false
			var material := ShaderMaterial.new()
			material.shader = ORBIT_SHADER if layer == 1 else GLOW_SHADER
			material.render_priority = layer - 1
			material.set_shader_parameter("phase", float(i) * 1.17 + 0.12)
			material.set_shader_parameter("filament", float(layer - 1))
			ribbon.material_override = material
			orbit.add_child(ribbon)
			if layer == 0:
				_halos.append(ribbon)
				_halo_materials.append(material)
			elif layer == 1:
				_bodies.append(ribbon)
				_body_materials.append(material)
			else:
				_filaments.append(ribbon)
				_filament_materials.append(material)
		_ages.append(0.0)
		_alphas.append(0.0)


func _apply_profile() -> void:
	if _profile == null or _body_materials.is_empty():
		return
	var radius_scale := float(_profile.parameters.get("radius_scale", 1.0))
	var flow_speed := float(_profile.parameters.get("flow_speed", 0.64))
	for i in MAX_STACKS:
		_rings[i].scale = Vector3(radius_scale, 1.0, radius_scale)
		_body_materials[i].set_shader_parameter("dark_color", _profile.dark_color)
		for material in [_halo_materials[i], _body_materials[i], _filament_materials[i]]:
			material.set_shader_parameter("main_color", _profile.main_color)
			material.set_shader_parameter("core_color", _profile.core_color)
			material.set_shader_parameter("flow_speed", flow_speed * (0.85 + float(i) * 0.08))
			material.set_shader_parameter("emission_energy", _profile.emission_energy)


static func _make_orbit_mesh(index: int, base_width: float) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for step in SEGMENTS + 1:
		var t := float(step) / float(SEGMENTS)
		var angle := t * TAU
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		var radius := float(RADII[index])
		var wobble := 1.0 + 0.018 * sin(angle * 7.0 + float(index) * 1.7)
		var center := Vector3(0.43 * radius * wobble * cos(angle),
			float(HEIGHTS[index]) + float(TILTS[index]) * sin(angle + float(TILT_PHASES[index]))
				+ 0.008 * sin(angle * 9.0 + float(index)),
			0.31 * radius * wobble * sin(angle))
		var width := base_width * (0.79 + 0.21 * sin(angle * 13.0 + float(index)))
		vertices.append(center - Vector3.UP * width)
		vertices.append(center + Vector3.UP * width)
		vertices.append(center - radial * width * 0.72)
		vertices.append(center + radial * width * 0.72)
		for _k in 2:
			normals.append(radial)
		for _k in 2:
			normals.append(Vector3.UP)
		colors.append(Color(1, 1, 1, 0.94))
		colors.append(Color(1, 1, 1, 0.94))
		colors.append(Color(1, 1, 1, 0.42))
		colors.append(Color(1, 1, 1, 0.42))
		uvs.append(Vector2(t, 0.0))
		uvs.append(Vector2(t, 1.0))
		uvs.append(Vector2(t, 0.0))
		uvs.append(Vector2(t, 1.0))
		if step == SEGMENTS:
			continue
		var a := step * 4
		var b := (step + 1) * 4
		for offset in [0, 2]:
			indices.append_array(PackedInt32Array([a + offset, a + offset + 1, b + offset,
				b + offset, a + offset + 1, b + offset + 1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
