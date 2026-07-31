extends Node3D

const AURORA := preload("res://assets/models/units/god_aurora_animated/god_aurora_animated.tscn")
const TRAIL := preload("res://assets/models/units/god_aurora_animated/god_aurora_arrow_trail.png")
const HIT := preload("res://assets/models/units/god_aurora_animated/god_aurora_true_hit.png")

const CYAN := Color("#75deff")
const VIOLET := Color("#b39aff")

var archer: Node3D
var projectile: Node3D
var core: MeshInstance3D
var trail: MeshInstance3D
var hit: MeshInstance3D


func _ready() -> void:
	_build()
	while is_inside_tree():
		await _shoot()
		await get_tree().create_timer(0.8).timeout


func _build() -> void:
	archer = AURORA.instantiate()
	add_child(archer)
	_add_world()

	projectile = Node3D.new()
	projectile.name = "ProjectileGlow"
	add_child(projectile)

	core = _sphere(CYAN)
	projectile.add_child(core)
	trail = _quad("ArrowTrail", TRAIL, CYAN, Vector2(1.4, 0.34), projectile)
	trail.position.x = -0.62
	hit = _quad("TrueHit", HIT, VIOLET, Vector2(0.85, 0.85))
	hit.position = Vector3(2.35, 0.9, 0.0)
	_hide()


func _shoot() -> void:
	_hide()
	if archer.has_method("play_attack"):
		archer.call("play_attack")
	await get_tree().create_timer(0.28).timeout

	projectile.position = Vector3(0.28, 1.18, 0.0)
	projectile.visible = true
	_alpha(trail, 0.82)
	_alpha(core, 1.0)
	var flight := create_tween()
	flight.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	flight.tween_property(projectile, "position", Vector3(2.35, 0.9, 0.0), 0.42)
	await flight.finished

	projectile.visible = false
	hit.visible = true
	hit.scale = Vector3(0.15, 0.15, 0.15)
	_alpha(hit, 0.0)
	var impact := create_tween().set_parallel()
	impact.tween_property(hit, "scale", Vector3.ONE, 0.10)
	impact.tween_method(func(v: float): _alpha(hit, v), 0.0, 1.0, 0.07)
	await get_tree().create_timer(0.08).timeout
	var fade := create_tween().set_parallel()
	fade.tween_property(hit, "scale", Vector3(1.25, 1.25, 1.25), 0.14)
	fade.tween_method(func(v: float): _alpha(hit, v), 1.0, 0.0, 0.14)
	await get_tree().create_timer(0.16).timeout


func _quad(
	node_name: String,
	texture: Texture2D,
	color: Color,
	size: Vector2,
	parent: Node = null
) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = size
	var material := _material(texture, color)
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mesh.material = material
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	if parent == null:
		parent = self
	parent.add_child(node)
	return node


func _sphere(color: Color) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = 0.055
	mesh.height = 0.11
	mesh.radial_segments = 12
	mesh.rings = 6
	mesh.material = _material(null, color)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	return node


func _material(texture: Texture2D, color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_texture = texture
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 2.8
	return material


func _alpha(node: MeshInstance3D, value: float) -> void:
	var material := node.mesh.material as StandardMaterial3D
	var color := material.albedo_color
	color.a = value
	material.albedo_color = color


func _hide() -> void:
	projectile.visible = false
	hit.visible = false


func _add_world() -> void:
	var target_mesh := CapsuleMesh.new()
	target_mesh.radius = 0.25
	target_mesh.height = 1.1
	target_mesh.material = _material(null, Color("#53627c"))
	var target := MeshInstance3D.new()
	target.mesh = target_mesh
	target.position = Vector3(2.35, 0.55, 0.0)
	add_child(target)

	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(6.0, 4.0)
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color("#20283b")
	floor_mesh.material = floor_material
	var floor := MeshInstance3D.new()
	floor.mesh = floor_mesh
	add_child(floor)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("#101421")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("#b8c9e6")
	environment.ambient_light_energy = 0.75
	environment.glow_enabled = true
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)

	var camera := Camera3D.new()
	camera.position = Vector3(4.5, 2.8, 5.4)
	camera.fov = 38.0
	add_child(camera)
	camera.look_at(Vector3(1.0, 0.85, 0.0))
	camera.current = true
