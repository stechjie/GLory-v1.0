extends VFXBlockRoot
class_name VFXGuardianSanctuary3D
## Lightguard: self shield and non-damaging taunt. Geometry is authored in world
## units, not the legacy 1.7-unit VFX space. No native plugins or screen buffers.

const SHIELD_SHADER := preload("res://effects/vfx3d/shaders/guardian_sanctuary.gdshader")
const RANGE_SHADER := preload("res://effects/vfx3d/shaders/guardian_range.gdshader")
const DEFAULT_WORLD_RADIUS := Vector2(180.0 * 14.5 * 0.88 / 1000.0, 180.0 * 10.0 * 0.88 / 520.0)

var _shield_active := true
var _taunt_active := true
var _world_radius := DEFAULT_WORLD_RADIUS
var _persistent := false
var _owner: WeakRef
var _height := 0.98
var _age := 0.0
var _shield_fade := 0.0
var _range_fade := 0.0
var _spark_count := 18
var _main_color := Color(1.0, 0.98, 0.93)
var _shell: MeshInstance3D
var _range: MeshInstance3D
var _seal: MeshInstance3D
var _sparks: MultiMeshInstance3D
var _shell_material: ShaderMaterial
var _range_material: ShaderMaterial
var _seal_material: ShaderMaterial

func play_guardian(origin: Vector3, context: Dictionary = {}) -> void:
	begin()
	global_position = origin
	_height = maxf(0.3, float(context.get("origin_height", 0.98)))
	_persistent = bool(context.get("persistent", false))
	_shield_active = bool(context.get("shield_active", true))
	_taunt_active = bool(context.get("taunt_active", true))
	_world_radius = context.get("taunt_world_radius", DEFAULT_WORLD_RADIUS)
	_main_color = context.get("main_color", Color(1.0, 0.98, 0.93))
	var owner_node: Variant = context.get("origin_node")
	if is_instance_valid(owner_node) and owner_node is Node3D:
		_owner = weakref(owner_node)
		global_position = owner_node.global_position
	_spark_count = [10, 18, 28][clampi(QUALITY_BUDGET.tier, 0, 2)]
	_build()
	set_process(true)
	_update_visuals(0.0)

func update_guardian_state(shield_active: bool, taunt_active: bool, world_radius: Vector2) -> void:
	_shield_active = shield_active
	_taunt_active = taunt_active
	_world_radius = Vector2(maxf(0.01, world_radius.x), maxf(0.01, world_radius.y))

func get_debug_state() -> Dictionary:
	return {"shield_active": _shield_active, "taunt_active": _taunt_active,
		"world_radius": _world_radius, "spark_count": _spark_count,
		"persistent": _persistent, "shield_fade": _shield_fade,
		"range_fade": _range_fade, "age": _age}

func _process(delta: float) -> void:
	if _finished:
		return
	if _owner != null:
		var actor: Variant = _owner.get_ref()
		if not is_instance_valid(actor) or not actor.is_inside_tree():
			finish()
			return
		global_position = actor.global_position
	_age += delta
	if not _persistent and _age > 1.25:
		_shield_active = false
		_taunt_active = false
	_update_visuals(delta)
	if not _shield_active and not _taunt_active and _shield_fade < 0.001 and _range_fade < 0.001:
		finish()

func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	_update_visuals(0.0)

func _build() -> void:
	_shell_material = _material(SHIELD_SHADER)
	_shell = _mesh_node("WhiteCrystalShield", _shield_mesh(), _shell_material)
	_shell.position.y = -_height * 0.55
	_range_material = _material(RANGE_SHADER)
	_range = _mesh_node("TauntRange_NoDamage", _ring_mesh(0.994, 1.0), _range_material)
	_range.position.y = -_height * 0.55 + 0.018
	_seal_material = _material(RANGE_SHADER)
	_seal_material.set_shader_parameter("seal", true)
	_seal = _mesh_node("ShieldFootSeal", _ring_mesh(0.975, 1.0), _seal_material)
	_seal.position.y = -_height * 0.55 + 0.024
	_seal.scale = Vector3.ONE * _height * 0.43
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_colors = true
	var shard := PrismMesh.new()
	shard.size = Vector3(0.018, 0.07, 0.012) * _height
	multi.mesh = shard
	multi.instance_count = _spark_count
	_sparks = MultiMeshInstance3D.new()
	_sparks.name = "ActivationShards"
	_sparks.multimesh = multi
	_sparks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.albedo_color = _main_color
	material.emission_enabled = true
	material.emission = _main_color
	material.emission_energy_multiplier = 0.7
	_sparks.material_override = material
	add_child(_sparks)

func _update_visuals(delta: float) -> void:
	if _shell == null:
		return
	_shield_fade = move_toward(_shield_fade, 1.0 if _shield_active else 0.0, delta * (4.5 if _shield_active else 5.0))
	_range_fade = move_toward(_range_fade, 1.0 if _taunt_active else 0.0, delta * 3.5)
	var opening := smoothstep(0.0, 0.48, _age)
	var emphasis := 1.0 - smoothstep(0.4, 1.4, _age)
	# This unit's 0.98 gameplay height includes its anchor allowance; its scaled
	# crystalbound mesh is about 0.51 tall. Fit the shell to that silhouette.
	_shell.scale = Vector3(lerpf(0.60, 1.0, opening), 0.60 * lerpf(0.78, 1.0, opening), lerpf(0.60, 1.0, opening))
	_shell_material.set_shader_parameter("opacity", _shield_fade * vfx_alpha)
	_shell_material.set_shader_parameter("activation", emphasis)
	_shell_material.set_shader_parameter("age", _age)
	_shell.visible = _shield_fade > 0.001
	# Taunt is active immediately: a quiet, full-radius boundary, never a damage wave.
	_range.scale = Vector3(_world_radius.x, 1.0, _world_radius.y)
	_range_material.set_shader_parameter("opacity", _range_fade * vfx_alpha * (0.10 + 0.16 * emphasis))
	_range_material.set_shader_parameter("age", _age)
	_range.visible = _range_fade > 0.001
	_seal_material.set_shader_parameter("opacity", _shield_fade * vfx_alpha * (0.40 + 0.28 * emphasis))
	_seal_material.set_shader_parameter("age", _age)
	_seal.visible = _shield_fade > 0.001
	_sparks.visible = _age < 1.15 and _shield_active
	if _sparks.visible:
		for i in _spark_count:
			var phase := float(i) / float(_spark_count)
			var progress := clampf((_age - phase * 0.17) / 0.92, 0.0, 1.0)
			var angle := phase * TAU * 2.618
			var radius := _height * (0.34 + progress * 0.36)
			var point := Vector3(cos(angle) * radius, _height * (-0.44 + progress * (0.54 + phase * 0.27)), sin(angle) * radius)
			var transform := Transform3D(Basis(Vector3.FORWARD, angle * 0.3), point)
			_sparks.multimesh.set_instance_transform(i, transform)
			_sparks.multimesh.set_instance_color(i, Color(1.0, 1.0, 1.0, sin(progress * PI) * vfx_alpha))

func _material(shader: Shader) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("main_color", _main_color)
	return material

func _mesh_node(label: String, mesh: ArrayMesh, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = label
	node.mesh = mesh
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node

func _shield_mesh() -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var outline := PackedVector2Array([Vector2(0, 1.10), Vector2(0.18, 0.88), Vector2(0.15, 0.31), Vector2(0, 0.16), Vector2(-0.15, 0.31), Vector2(-0.18, 0.88)])
	for panel in 6:
		var angle := TAU * float(panel) / 6.0 + PI / 6.0
		var normal := Vector3(sin(angle), 0, cos(angle))
		var tangent := Vector3(cos(angle), 0, -sin(angle))
		var base := normal * 0.39 * _height
		var center := base + Vector3.UP * 0.63 * _height
		for edge in outline.size():
			var a := base + (tangent * outline[edge].x + Vector3.UP * outline[edge].y) * _height
			var next := outline[(edge + 1) % outline.size()]
			var b := base + (tangent * next.x + Vector3.UP * next.y) * _height
			_triangle(surface, center, a, b, Color(1, 1, 1, 0.07), normal)
			_line(surface, a, b, normal, 0.014 * _height, Color(1, 1, 1, 0.72))
		var diamond := [Vector2(0, 0.87), Vector2(0.075, 0.70), Vector2(0, 0.54), Vector2(-0.075, 0.70)]
		for edge in 4:
			var a: Vector2 = diamond[edge]
			var b: Vector2 = diamond[(edge + 1) % 4]
			_line(surface, base + (tangent * a.x + Vector3.UP * a.y) * _height, base + (tangent * b.x + Vector3.UP * b.y) * _height, normal, 0.006 * _height, Color(1, 1, 1, 0.50))
	return surface.commit()

func _triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color, normal: Vector3) -> void:
	for point in [a, b, c]:
		surface.set_uv(Vector2(0.5, 0.0))
		surface.set_color(color)
		surface.set_normal(normal)
		surface.add_vertex(point)

func _line(surface: SurfaceTool, a: Vector3, b: Vector3, normal: Vector3, width: float, color: Color) -> void:
	var side := (b - a).cross(normal).normalized() * width
	var points := [a - side, b - side, b + side, a - side, b + side, a + side]
	var uvs := [Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(1, 0)]
	for i in 6:
		surface.set_color(color)
		surface.set_normal(normal)
		surface.set_uv(uvs[i])
		surface.add_vertex(points[i])

func _ring_mesh(inner: float, outer: float) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segments: int = [48, 64, 96][clampi(QUALITY_BUDGET.tier, 0, 2)]
	for i in segments:
		for corner in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)]:
			var u: float = (float(i) + corner.x) / float(segments)
			var radius := lerpf(inner, outer, corner.y)
			surface.set_uv(Vector2(u, corner.y))
			surface.set_normal(Vector3.UP)
			surface.add_vertex(Vector3(cos(u * TAU) * radius, 0, sin(u * TAU) * radius))
	return surface.commit()
