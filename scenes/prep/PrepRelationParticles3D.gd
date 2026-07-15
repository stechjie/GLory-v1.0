extends Node3D

const MAX_PROGRESS := 4
const MAX_LIGHT_POINTS := 18
# 18 个 multimesh 变换 × 每对羁绊 × 每帧太贵；20Hz 足够平滑。
const UPDATE_INTERVAL := 1.0 / 20.0

var _progress := 0
var _effect_color := Color.WHITE
var _radius_scale := 1.0
var _flow_time := 0.0
var _update_accum := 0.0
var _orbit_speed := 0.22
var _pulse_speed := 0.70
var _base_alpha := 0.24
var _active_count := 0
var _orbit_radius := 0.50
var _multimesh: MultiMesh
var _point_material: StandardMaterial3D

func configure(next_progress: int, color: Color, radius_scale: float) -> void:
	_progress = clampi(next_progress, 0, MAX_PROGRESS)
	_effect_color = color
	_radius_scale = radius_scale
	if _progress <= 0:
		visible = false
		set_process(false)
		return
	_ensure_light_points()
	_apply_tier_settings()
	visible = true
	set_process(true)
	_multimesh.visible_instance_count = _active_count
	_update_light_points()

func _process(delta: float) -> void:
	if _progress <= 0:
		return
	_flow_time += delta
	_update_accum += delta
	if _update_accum >= UPDATE_INTERVAL:
		_update_accum = 0.0
		_update_light_points()

func _apply_tier_settings() -> void:
	match _progress:
		1:
			_active_count = 7
			_orbit_radius = 0.46
			_base_alpha = 0.24
			_orbit_speed = 0.22
			_pulse_speed = 0.70
		2:
			_active_count = 14
			_orbit_radius = 0.56
			_base_alpha = 0.34
			_orbit_speed = 0.32
			_pulse_speed = 0.92
		3:
			_active_count = 18
			_orbit_radius = 0.68
			_base_alpha = 0.58
			_orbit_speed = 0.52
			_pulse_speed = 1.45
		4:
			_active_count = 18
			_orbit_radius = 0.72
			_base_alpha = 0.68
			_orbit_speed = 0.60
			_pulse_speed = 1.70

# All light points share ONE MultiMesh: a single draw call per unit instead of
# 18 separate MeshInstance3D nodes each.
func _ensure_light_points() -> void:
	if _multimesh != null:
		return
	_point_material = StandardMaterial3D.new()
	_point_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_point_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_point_material.emission_enabled = true
	_point_material.emission_energy_multiplier = 2.2
	var sphere := SphereMesh.new()
	sphere.radius = 0.052
	sphere.height = 0.104
	sphere.radial_segments = 8
	sphere.rings = 5
	sphere.material = _point_material
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.mesh = sphere
	_multimesh.instance_count = MAX_LIGHT_POINTS
	_multimesh.visible_instance_count = 0
	var points := MultiMeshInstance3D.new()
	points.name = "RelationLightPoints"
	points.multimesh = _multimesh
	points.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(points)

func _update_light_points() -> void:
	if _point_material == null or _multimesh == null:
		return
	var pulse := 0.84 + sin(_flow_time * _pulse_speed) * 0.16
	_point_material.albedo_color = Color(
		_effect_color.r,
		_effect_color.g,
		_effect_color.b,
		_base_alpha * pulse
	)
	_point_material.emission = Color(_effect_color.r, _effect_color.g, _effect_color.b, 1.0)
	for index in _active_count:
		var ratio := float(index) / float(maxi(1, _active_count))
		var phase := ratio * TAU + _flow_time * _orbit_speed * (1.0 + float(index % 3) * 0.16)
		var radius := _orbit_radius * _radius_scale * (0.84 + float(index % 4) * 0.055)
		var height_phase := phase * 1.7 + float(index) * 0.83
		var height := 0.54 + sin(height_phase) * 0.42 + float(index % 3) * 0.10
		var point_pulse := 0.78 + sin(_flow_time * _pulse_speed + float(index) * 0.72) * 0.22
		var xform := Transform3D(
			Basis.from_scale(Vector3.ONE * point_pulse),
			Vector3(cos(phase) * radius, height, sin(phase) * radius)
		)
		_multimesh.set_instance_transform(index, xform)
