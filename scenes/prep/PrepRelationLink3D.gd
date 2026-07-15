extends Node3D

const POINT_COUNT := 30
const STRAND_COUNT := 2
const HELIX_TURNS := 1.55
const HELIX_RADIUS := 0.035
const LINE_WIDTH := 0.007
# ImmediateMesh 全量重建开销大；20Hz 在备战视口 30Hz 采样下肉眼无差。
const UPDATE_INTERVAL := 1.0 / 20.0

var _start_point := Vector3.ZERO
var _end_point := Vector3.ZERO
var _line_color := Color.WHITE
var _flow_time := 0.0
var _update_accum := 0.0
var _pulse_speed := 2.2
var _strand_meshes: Array[ImmediateMesh] = []
var _strand_materials: Array[StandardMaterial3D] = []

func configure(start_point: Vector3, end_point: Vector3, color: Color) -> void:
	_start_point = start_point
	_end_point = end_point
	_line_color = color
	_ensure_strands()
	_update_strands()

func _process(delta: float) -> void:
	_flow_time += delta
	_update_accum += delta
	if _update_accum >= UPDATE_INTERVAL:
		_update_accum = 0.0
		_update_strands()

func _ensure_strands() -> void:
	if not _strand_meshes.is_empty():
		return
	for index in STRAND_COUNT:
		var mesh := ImmediateMesh.new()
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.name = "RelationHelix%d" % (index + 1)
		mesh_instance.mesh = mesh
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material := StandardMaterial3D.new()
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.emission_enabled = true
		material.emission_energy_multiplier = 2.4
		mesh_instance.material_override = material
		add_child(mesh_instance)
		_strand_meshes.append(mesh)
		_strand_materials.append(material)

func _update_strands() -> void:
	var axis := _end_point - _start_point
	var distance := axis.length()
	if distance <= 0.01:
		visible = false
		return
	visible = true
	var direction := axis / distance
	var horizontal_perpendicular := Vector3(-direction.z, 0.0, direction.x)
	if horizontal_perpendicular.length_squared() <= 0.001:
		horizontal_perpendicular = Vector3.RIGHT
	else:
		horizontal_perpendicular = horizontal_perpendicular.normalized()
	var ribbon_side := direction.cross(Vector3(0.0, -0.72, -0.69)).normalized()
	if ribbon_side.length_squared() <= 0.001:
		ribbon_side = Vector3.RIGHT
	var pulse := 0.82 + sin(_flow_time * _pulse_speed) * 0.18
	var is_friendly := _line_color.r > 0.8 and _line_color.g > 0.5
	for strand_index in STRAND_COUNT:
		var mesh := _strand_meshes[strand_index]
		var material := _strand_materials[strand_index]
		var alpha := (
			(0.98 if strand_index == 0 else 0.76)
			if is_friendly
			else (0.82 if strand_index == 0 else 0.56)
		) * pulse
		material.albedo_color = Color(_line_color.r, _line_color.g, _line_color.b, alpha)
		material.emission = Color(_line_color.r, _line_color.g, _line_color.b, 1.0)
		material.emission_energy_multiplier = 3.8 if is_friendly else 2.4
		mesh.clear_surfaces()
		mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
		for point_index in POINT_COUNT:
			var ratio := float(point_index) / float(POINT_COUNT - 1)
			var envelope := sin(PI * ratio)
			var phase := (
				ratio * TAU * HELIX_TURNS
				- _flow_time * (2.4 + float(strand_index) * 0.35)
				+ float(strand_index) * PI
			)
			var offset := (
				horizontal_perpendicular * cos(phase)
				+ Vector3.UP * sin(phase)
			) * HELIX_RADIUS * envelope
			var center := _start_point.lerp(_end_point, ratio) + offset
			var width := LINE_WIDTH * (1.0 + 0.18 * sin(phase))
			mesh.surface_add_vertex(center - ribbon_side * width)
			mesh.surface_add_vertex(center + ribbon_side * width)
		mesh.surface_end()
