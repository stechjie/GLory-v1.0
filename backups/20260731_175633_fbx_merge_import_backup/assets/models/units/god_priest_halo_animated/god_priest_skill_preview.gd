extends Node3D

const PRIEST_SCENE := preload("res://assets/models/units/god_priest_halo_animated/god_priest_animated.tscn")
const RING_TEXTURE := preload("res://assets/models/units/god_priest_halo_animated/god_priest_holy_ring.png")
const SPARK_TEXTURE := preload("res://assets/models/units/god_priest_halo_animated/god_priest_soft_spark.png")

const WHITE := Color("#fffdf2")
const GOLD := Color("#ffd978")
const BLUE := Color("#a9dcff")

var priest: Node3D
var ground_ring: MeshInstance3D
var hand_orb: MeshInstance3D
var beam: MeshInstance3D
var target_ring: MeshInstance3D
var light_column: MeshInstance3D
var source_sparks: GPUParticles3D
var target_sparks: GPUParticles3D


func _ready() -> void:
	_build_preview()
	while is_inside_tree():
		await _play_skill()
		await get_tree().create_timer(1.25).timeout


func _build_preview() -> void:
	priest = PRIEST_SCENE.instantiate()
	add_child(priest)

	_add_camera()
	_add_environment()
	_add_floor()
	_add_target_dummy()

	ground_ring = _make_quad("GroundRing", RING_TEXTURE, GOLD, 1.7)
	ground_ring.rotation_degrees.x = -90.0
	ground_ring.position.y = 0.025

	hand_orb = _make_sphere("HandOrb", WHITE, 0.12)
	hand_orb.position = Vector3(0.22, 1.32, 0.0)

	beam = _make_cylinder("HealBeam", GOLD, 0.035, 1.0)
	target_ring = _make_quad("TargetRing", RING_TEXTURE, GOLD, 1.35)
	target_ring.rotation_degrees.x = -90.0
	target_ring.position = Vector3(2.1, 0.03, 0.0)

	light_column = _make_cylinder("LightColumn", WHITE, 0.42, 1.8)
	light_column.position = Vector3(2.1, 0.9, 0.0)

	source_sparks = _make_particles("SourceSparks", SPARK_TEXTURE, WHITE, Vector3(0.22, 1.15, 0.0), 12)
	target_sparks = _make_particles("TargetSparks", SPARK_TEXTURE, BLUE, Vector3(2.1, 0.15, 0.0), 18)
	_hide_all()


func _play_skill() -> void:
	_hide_all()
	if priest.has_method("play_attack"):
		priest.call("play_attack")

	_show_scaled(ground_ring, Vector3.ZERO)
	_tween_scale_and_alpha(ground_ring, Vector3.ONE, 0.34, 0.75)
	await get_tree().create_timer(0.10).timeout

	source_sparks.restart()
	source_sparks.emitting = true
	await get_tree().create_timer(0.22).timeout

	_show_scaled(hand_orb, Vector3.ZERO)
	_tween_scale_and_alpha(hand_orb, Vector3.ONE, 0.16, 1.0)
	await get_tree().create_timer(0.16).timeout

	_place_cylinder_between(beam, hand_orb.global_position, Vector3(2.1, 0.82, 0.0))
	_show_scaled(beam, Vector3(0.05, 0.05, 0.05))
	_tween_scale_and_alpha(beam, Vector3.ONE, 0.12, 0.85)
	await get_tree().create_timer(0.14).timeout

	_show_scaled(target_ring, Vector3(0.2, 0.2, 0.2))
	_show_scaled(light_column, Vector3(0.35, 0.05, 0.35))
	_tween_scale_and_alpha(target_ring, Vector3.ONE, 0.22, 0.9)
	_tween_scale_and_alpha(light_column, Vector3.ONE, 0.20, 0.65)
	target_sparks.restart()
	target_sparks.emitting = true

	await get_tree().create_timer(0.18).timeout
	_fade_out(beam, 0.14)
	_fade_out(hand_orb, 0.14)
	await get_tree().create_timer(0.20).timeout
	_fade_out(ground_ring, 0.34)
	_fade_out(target_ring, 0.34)
	_fade_out(light_column, 0.28)
	await get_tree().create_timer(0.38).timeout


func _make_quad(node_name: String, texture: Texture2D, color: Color, size: float) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_texture = texture
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 2.2
	quad.material = material
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = quad
	add_child(node)
	return node


func _make_sphere(node_name: String, color: Color, radius: float) -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	sphere.material = _glow_material(color, 3.0)
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = sphere
	add_child(node)
	return node


func _make_cylinder(node_name: String, color: Color, radius: float, height: float) -> MeshInstance3D:
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = height
	cylinder.radial_segments = 12
	cylinder.material = _glow_material(color, 2.4, 0.72)
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = cylinder
	add_child(node)
	return node


func _make_particles(
	node_name: String,
	texture: Texture2D,
	color: Color,
	at: Vector3,
	count: int
) -> GPUParticles3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.albedo_texture = texture
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 2.5

	var quad := QuadMesh.new()
	quad.size = Vector2(0.16, 0.16)
	quad.material = material

	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.28
	process.direction = Vector3.UP
	process.spread = 35.0
	process.initial_velocity_min = 0.35
	process.initial_velocity_max = 0.8
	process.gravity = Vector3.ZERO
	process.scale_min = 0.45
	process.scale_max = 1.15
	process.color = color

	var particles := GPUParticles3D.new()
	particles.name = node_name
	particles.amount = count
	particles.lifetime = 0.72
	particles.one_shot = true
	particles.explosiveness = 0.85
	particles.draw_pass_1 = quad
	particles.process_material = process
	particles.position = at
	add_child(particles)
	return particles


func _glow_material(color: Color, energy: float, alpha := 1.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(color, alpha)
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = energy
	return material


func _show_scaled(node: MeshInstance3D, start_scale: Vector3) -> void:
	node.visible = true
	node.scale = start_scale
	_set_alpha(node, 0.0)


func _tween_scale_and_alpha(node: MeshInstance3D, end_scale: Vector3, duration: float, alpha: float) -> void:
	var tween := create_tween().set_parallel()
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(node, "scale", end_scale, duration)
	tween.tween_method(func(value: float): _set_alpha(node, value), 0.0, alpha, duration)


func _fade_out(node: MeshInstance3D, duration: float) -> void:
	var material := _material_of(node)
	if material == null:
		return
	var start_alpha := material.albedo_color.a
	var tween := create_tween()
	tween.tween_method(func(value: float): _set_alpha(node, value), start_alpha, 0.0, duration)
	tween.tween_callback(func(): node.visible = false)


func _set_alpha(node: MeshInstance3D, alpha: float) -> void:
	var material := _material_of(node)
	if material == null:
		return
	var color := material.albedo_color
	color.a = alpha
	material.albedo_color = color


func _material_of(node: MeshInstance3D) -> StandardMaterial3D:
	if node.mesh == null:
		return null
	return node.mesh.material as StandardMaterial3D


func _place_cylinder_between(node: MeshInstance3D, from: Vector3, to: Vector3) -> void:
	var delta := to - from
	var cylinder := node.mesh as CylinderMesh
	cylinder.height = delta.length()
	node.position = (from + to) * 0.5
	node.basis = Basis(Quaternion(Vector3.UP, delta.normalized()))


func _hide_all() -> void:
	for node in [ground_ring, hand_orb, beam, target_ring, light_column]:
		if node != null:
			node.visible = false
	if source_sparks != null:
		source_sparks.emitting = false
	if target_sparks != null:
		target_sparks.emitting = false


func _add_camera() -> void:
	var camera := Camera3D.new()
	camera.position = Vector3(5.2, 3.7, 6.2)
	camera.fov = 42.0
	add_child(camera)
	camera.look_at(Vector3(0.85, 0.85, 0.0))
	camera.current = true


func _add_environment() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("#101421")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("#aab8d6")
	environment.ambient_light_energy = 0.72
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.glow_enabled = true
	environment.glow_intensity = 1.15
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)


func _add_floor() -> void:
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(7.0, 5.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#20283b")
	material.metallic = 0.15
	material.roughness = 0.72
	floor_mesh.material = material
	var floor_node := MeshInstance3D.new()
	floor_node.mesh = floor_mesh
	floor_node.position.y = -0.015
	add_child(floor_node)


func _add_target_dummy() -> void:
	var body := CapsuleMesh.new()
	body.radius = 0.26
	body.height = 1.05
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#52627e")
	material.roughness = 0.65
	body.material = material
	var dummy := MeshInstance3D.new()
	dummy.name = "HealingTarget"
	dummy.mesh = body
	dummy.position = Vector3(2.1, 0.52, 0.0)
	add_child(dummy)
