extends Node3D

const KING := preload("res://assets/models/units/god_king_animated/god_king_animated.tscn")
const LINE := preload("res://assets/models/units/god_king_animated/god_king_judgement_line.png")
const IMPACT := preload("res://assets/models/units/god_king_animated/god_king_royal_impact.png")

const GOLD := Color("#ffd36a")
const WHITE := Color("#fffdf2")
const PINK := Color("#f6b5ff")
const BLUE := Color("#cfefff")

var king: Node3D
var lines: Array[MeshInstance3D] = []
var impacts: Array[MeshInstance3D] = []
var shard_particles: Array[GPUParticles3D] = []
var dimmer: MeshInstance3D
var time := 0.0


func _ready() -> void:
	_clear()
	_add_world()
	_build()
	_loop()


func _process(delta: float) -> void:
	time += delta
	for i in impacts.size():
		var impact := impacts[i]
		if impact.visible:
			impact.rotation.y += delta * (0.7 + i * 0.1)
			impact.position.y = 0.055 + sin(time * 3.0 + i) * 0.018


func _build() -> void:
	king = KING.instantiate()
	king.position = Vector3(-1.55, 0.0, 0.0)
	king.rotation.y = deg_to_rad(25.0)
	add_child(king)

	dimmer = _dimmer()

	for i in 4:
		var line := _quad("JudgementLine%d" % i, LINE, Vector2(3.4, 0.42), Color(WHITE.r, WHITE.g, WHITE.b, 0.0), true)
		line.position = Vector3(0.35, 0.035, -1.2 + i * 0.78)
		line.rotation.x = deg_to_rad(-90.0)
		line.rotation.z = deg_to_rad([-6.0, 4.0, -2.0, 7.0][i])
		line.visible = false
		lines.append(line)

	var positions := [Vector3(1.15, 0.5, -0.95), Vector3(2.05, 0.5, -0.3), Vector3(1.55, 0.5, 0.52), Vector3(2.45, 0.5, 1.05)]
	for i in positions.size():
		_dummy(positions[i], "Enemy%d" % i)
		var impact := _quad("RoyalImpact%d" % i, IMPACT, Vector2(0.78, 0.78), Color(WHITE.r, WHITE.g, WHITE.b, 0.0), true)
		impact.position = Vector3(positions[i].x, 0.055, positions[i].z)
		impact.rotation.x = deg_to_rad(-90.0)
		impact.visible = false
		impacts.append(impact)
		var particles := _particles("RoyalShardParticles%d" % i, positions[i] + Vector3(0.0, 0.25, 0.0), 46, 0.95, Color(GOLD.r, GOLD.g, GOLD.b, 1.0))
		shard_particles.append(particles)
	_hide_vfx()


func _loop() -> void:
	while is_inside_tree():
		await _cast()
		await get_tree().create_timer(0.75).timeout


func _cast() -> void:
	_hide_vfx()
	if king.has_method("play_attack"):
		king.call("play_attack")

	dimmer.visible = true
	_alpha(dimmer, 0.0)
	var darken := create_tween()
	darken.tween_method(func(v: float): _alpha(dimmer, v), 0.0, 0.22, 0.16)
	await get_tree().create_timer(0.12).timeout

	for i in lines.size():
		var line := lines[i]
		line.visible = true
		line.scale = Vector3(0.18, 1.0, 1.0)
		_alpha(line, 0.0)
		var sweep := create_tween().set_parallel()
		sweep.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		sweep.tween_property(line, "scale", Vector3.ONE, 0.42)
		sweep.tween_method(func(v: float): _alpha(line, v), 0.0, 0.86, 0.22)
		await get_tree().create_timer(0.08).timeout

	await get_tree().create_timer(0.08).timeout
	for i in impacts.size():
		var impact := impacts[i]
		impact.visible = true
		impact.scale = Vector3(0.18, 0.18, 0.18)
		_alpha(impact, 0.0)
		var pop := create_tween().set_parallel()
		pop.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		pop.tween_property(impact, "scale", Vector3.ONE, 0.28)
		pop.tween_method(func(v: float): _alpha(impact, v), 0.0, 0.94, 0.14)
		shard_particles[i].emitting = true
		await get_tree().create_timer(0.035).timeout

	await get_tree().create_timer(0.32).timeout
	for impact in impacts:
		var fade_impact := create_tween().set_parallel()
		fade_impact.tween_property(impact, "scale", Vector3(1.18, 1.18, 1.18), 0.34)
		fade_impact.tween_method(func(v: float): _alpha(impact, v), 0.94, 0.0, 0.34)
	for line in lines:
		var fade_line := create_tween()
		fade_line.tween_method(func(v: float): _alpha(line, v), 0.86, 0.0, 0.45)
	var brighten := create_tween()
	brighten.tween_method(func(v: float): _alpha(dimmer, v), 0.22, 0.0, 0.35)
	await get_tree().create_timer(0.55).timeout


func _hide_vfx() -> void:
	dimmer.visible = false
	for line in lines:
		line.visible = false
	for impact in impacts:
		impact.visible = false
	for particles in shard_particles:
		particles.emitting = false


func _quad(node_name: String, texture: Texture2D, size: Vector2, color: Color, ground := false) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED if ground else BaseMaterial3D.BILLBOARD_ENABLED
	material.albedo_texture = texture
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = Color(1.0, 0.86, 0.58)
	material.emission_energy_multiplier = 2.0
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.material_override = material
	add_child(node)
	return node


func _dimmer() -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(7.0, 5.0)
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.09, 0.07, 0.13, 0.0)
	var node := MeshInstance3D.new()
	node.name = "FieldDimmer"
	node.mesh = mesh
	node.material_override = material
	node.rotation.x = deg_to_rad(-90.0)
	node.position.y = 0.015
	add_child(node)
	return node


func _particles(node_name: String, at: Vector3, amount: int, speed: float, color: Color) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = node_name
	p.amount = amount
	p.lifetime = 1.15
	p.one_shot = false
	p.explosiveness = 0.7
	p.randomness = 0.85
	p.position = at
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0.0, 1.0, 0.0)
	mat.spread = 72.0
	mat.initial_velocity_min = speed * 0.35
	mat.initial_velocity_max = speed
	mat.gravity = Vector3(0.0, -0.18, 0.0)
	mat.scale_min = 0.035
	mat.scale_max = 0.09
	mat.color = color
	p.process_material = mat
	var mesh := SphereMesh.new()
	mesh.radius = 0.035
	mesh.height = 0.07
	p.draw_pass_1 = mesh
	add_child(p)
	return p


func _dummy(at: Vector3, node_name: String) -> MeshInstance3D:
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.23
	mesh.height = 1.0
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#586174")
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
	camera.position = Vector3(5.8, 3.7, 6.4)
	camera.fov = 42.0
	add_child(camera)
	camera.look_at(Vector3(0.55, 0.85, 0.0))
	camera.current = true


func _clear() -> void:
	for child in get_children():
		remove_child(child)
		child.free()
