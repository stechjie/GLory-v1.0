extends Node3D

const ARCHANGEL := preload("res://assets/models/units/god_archangel_animated/god_archangel_animated.tscn")
const SIGLA := preload("res://assets/models/units/god_archangel_animated/god_archangel_covenant_sigla.png")
const RIBBON := preload("res://assets/models/units/god_archangel_animated/god_archangel_mercy_ribbon.png")

const GOLD := Color("#ffd98a")
const WHITE := Color("#fffdf2")
const BLUE := Color("#cfefff")

var archangel: Node3D
var target: MeshInstance3D
var sigla: MeshInstance3D
var ribbons: Array[MeshInstance3D] = []
var feather_particles: GPUParticles3D
var mote_particles: GPUParticles3D
var time := 0.0


func _ready() -> void:
	_clear()
	_add_world()
	_build()
	_loop()


func _process(delta: float) -> void:
	time += delta
	if sigla:
		sigla.position.y = 1.95 + sin(time * 2.1) * 0.06
		sigla.rotation.y += delta * 0.75
	for i in ribbons.size():
		var ribbon := ribbons[i]
		var phase := time * (0.7 + i * 0.11) + i * TAU / 3.0
		ribbon.position = target.position + Vector3(sin(phase) * 0.46, 0.78 + i * 0.16 + sin(phase * 1.7) * 0.05, cos(phase) * 0.22)
		ribbon.rotation.y = phase + PI * 0.5
		ribbon.rotation.z = sin(phase * 1.3) * 0.18


func _build() -> void:
	archangel = ARCHANGEL.instantiate()
	archangel.position = Vector3(-1.35, 0.0, 0.0)
	archangel.rotation.y = deg_to_rad(25.0)
	add_child(archangel)

	target = _dummy(Vector3(1.35, 0.5, 0.0), "ProtectedAlly", Color("#4f5f7a"))
	sigla = _quad("CovenantSigla", SIGLA, Vector2(0.58, 0.58), WHITE)
	sigla.position = target.position + Vector3(0.0, 1.42, 0.0)

	for i in 3:
		var ribbon := _quad("MercyRibbon%d" % i, RIBBON, Vector2(1.15, 0.28), Color(GOLD.r, GOLD.g, GOLD.b, 0.0))
		ribbon.position = target.position + Vector3(0.0, 0.75 + i * 0.16, 0.0)
		ribbon.visible = false
		ribbons.append(ribbon)

	feather_particles = _particles("FeatherDustParticles", Vector3(1.35, 1.05, 0.0), 32, 0.55, 1.2, Color("#fff4c8"))
	mote_particles = _particles("GoldMoteParticles", Vector3(1.35, 1.35, 0.0), 42, 0.18, 1.8, GOLD)
	_hide_vfx()


func _loop() -> void:
	while is_inside_tree():
		await _cast()
		await get_tree().create_timer(0.7).timeout


func _cast() -> void:
	_hide_vfx()
	if archangel.has_method("play_attack"):
		archangel.call("play_attack")
	await get_tree().create_timer(0.18).timeout

	mote_particles.emitting = true
	await get_tree().create_timer(0.17).timeout

	sigla.visible = true
	sigla.scale = Vector3(0.25, 0.25, 0.25)
	sigla.position = target.position + Vector3(0.0, 2.25, 0.0)
	_alpha(sigla, 0.0)
	var drop := create_tween().set_parallel()
	drop.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	drop.tween_property(sigla, "position:y", 1.95, 0.38)
	drop.tween_property(sigla, "scale", Vector3.ONE, 0.38)
	drop.tween_method(func(v: float): _alpha(sigla, v), 0.0, 0.95, 0.24)
	await get_tree().create_timer(0.18).timeout

	for i in ribbons.size():
		var ribbon := ribbons[i]
		ribbon.visible = true
		ribbon.scale = Vector3(0.25, 0.65, 1.0)
		_alpha(ribbon, 0.0)
		var flow := create_tween().set_parallel()
		flow.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		flow.tween_property(ribbon, "scale", Vector3.ONE, 0.5)
		flow.tween_method(func(v: float): _alpha(ribbon, v), 0.0, 0.62, 0.34)
		await get_tree().create_timer(0.08).timeout

	feather_particles.emitting = true
	await get_tree().create_timer(4.9).timeout

	for ribbon in ribbons:
		var fade_ribbon := create_tween().set_parallel()
		fade_ribbon.tween_property(ribbon, "scale", Vector3(1.25, 0.55, 1.0), 0.28)
		fade_ribbon.tween_method(func(v: float): _alpha(ribbon, v), 0.62, 0.0, 0.28)
	var fade_sigla := create_tween().set_parallel()
	fade_sigla.tween_property(sigla, "position:y", 2.12, 0.35)
	fade_sigla.tween_method(func(v: float): _alpha(sigla, v), 0.95, 0.0, 0.35)
	await get_tree().create_timer(0.4).timeout


func _hide_vfx() -> void:
	sigla.visible = false
	for ribbon in ribbons:
		ribbon.visible = false
	feather_particles.emitting = false
	mote_particles.emitting = false


func _quad(node_name: String, texture: Texture2D, size: Vector2, color: Color) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.albedo_texture = texture
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 1.8
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.material_override = material
	add_child(node)
	return node


func _particles(node_name: String, at: Vector3, amount: int, size: float, speed: float, color: Color) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = node_name
	p.amount = amount
	p.lifetime = 1.6
	p.one_shot = false
	p.explosiveness = 0.18
	p.randomness = 0.65
	p.position = at
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0.0, 1.0, 0.0)
	mat.spread = 55.0
	mat.initial_velocity_min = speed * 0.35
	mat.initial_velocity_max = speed
	mat.gravity = Vector3(0.0, 0.22, 0.0)
	mat.scale_min = size * 0.035
	mat.scale_max = size * 0.075
	mat.color = color
	p.process_material = mat
	var mesh := SphereMesh.new()
	mesh.radius = 0.035
	mesh.height = 0.07
	p.draw_pass_1 = mesh
	add_child(p)
	return p


func _dummy(at: Vector3, node_name: String, color: Color) -> MeshInstance3D:
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.24
	mesh.height = 1.0
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	mesh.material = material
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.position = at
	add_child(node)
	return node


func _alpha(node: MeshInstance3D, value: float) -> void:
	var material := node.material_override as StandardMaterial3D
	var color := material.albedo_color
	color.a = value
	material.albedo_color = color


func _add_world() -> void:
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(7.0, 5.0)
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color("#20283b")
	floor_mesh.material = floor_material
	var floor := MeshInstance3D.new()
	floor.name = "PreviewFloor"
	floor.mesh = floor_mesh
	add_child(floor)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("#101421")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("#c6d3e8")
	environment.ambient_light_energy = 0.78
	environment.glow_enabled = true
	var world := WorldEnvironment.new()
	world.name = "PreviewWorld"
	world.environment = environment
	add_child(world)

	var light := DirectionalLight3D.new()
	light.name = "PreviewLight"
	light.position = Vector3(0.0, 4.0, 2.0)
	light.rotation_degrees = Vector3(-55.0, 35.0, 0.0)
	light.light_energy = 1.8
	add_child(light)

	var camera := Camera3D.new()
	camera.name = "PreviewCamera"
	camera.position = Vector3(5.2, 3.4, 6.2)
	camera.fov = 40.0
	add_child(camera)
	camera.look_at(Vector3(0.65, 0.9, 0.0))
	camera.current = true


func _clear() -> void:
	for child in get_children():
		remove_child(child)
		child.free()
