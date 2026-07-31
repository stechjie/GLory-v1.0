extends Node3D

const PRIESTESS := preload("res://assets/models/units/god_priestess_animated/god_priestess_animated.tscn")
const DECREE := preload("res://assets/models/units/god_priestess_animated/god_priestess_decree.png")
const MARK := preload("res://assets/models/units/god_priestess_animated/god_priestess_decree_mark.png")

const BLUE := Color("#4daeff")
const GOLD := Color("#ffd56a")

var caster: Node3D
var decree: MeshInstance3D
var page_strips: Array[MeshInstance3D] = []
var marks: Array[MeshInstance3D] = []


func _ready() -> void:
	_build()
	while is_inside_tree():
		await _cast()
		await get_tree().create_timer(1.0).timeout


func _build() -> void:
	caster = PRIESTESS.instantiate()
	add_child(caster)
	_add_world()

	decree = _quad("CelestialDecree", DECREE, GOLD, Vector2(0.95, 1.55))
	decree.position = Vector3(0.0, 1.45, -0.28)

	for z in [-0.72, 0.0, 0.72]:
		var strip := _strip("PurifyPage", BLUE)
		strip.position = Vector3(-1.0, 0.42, z)
		page_strips.append(strip)

	for position in [Vector3(1.65, 0.0, -0.72), Vector3(2.25, 0.0, 0.0), Vector3(1.65, 0.0, 0.72)]:
		_dummy(position)
		var mark := _quad("DecreeMark", MARK, GOLD, Vector2(0.48, 0.48))
		mark.position = position + Vector3(0.0, 1.35, 0.0)
		marks.append(mark)
	_hide()


func _cast() -> void:
	_hide()
	if caster.has_method("play_attack"):
		caster.call("play_attack")

	decree.visible = true
	decree.scale = Vector3(0.08, 1.0, 1.0)
	_alpha(decree, 0.0)
	var open := create_tween().set_parallel()
	open.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	open.tween_property(decree, "scale", Vector3.ONE, 0.34)
	open.tween_method(func(v: float): _alpha(decree, v), 0.0, 0.95, 0.22)
	await get_tree().create_timer(0.38).timeout

	for i in page_strips.size():
		var strip := page_strips[i]
		strip.visible = true
		strip.position.x = -1.0
		strip.scale = Vector3(0.05, 1.0, 1.0)
		_alpha(strip, 0.78)
		var sweep := create_tween().set_parallel()
		sweep.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		sweep.tween_property(strip, "position:x", 2.7, 0.42)
		sweep.tween_property(strip, "scale:x", 1.0, 0.18)
		sweep.tween_method(func(v: float): _alpha(strip, v), 0.78, 0.0, 0.42)
		await get_tree().create_timer(0.07).timeout

	await get_tree().create_timer(0.12).timeout
	for mark in marks:
		mark.visible = true
		mark.scale = Vector3(0.12, 0.12, 0.12)
		mark.position.y -= 0.22
		_alpha(mark, 0.0)
		var stamp := create_tween().set_parallel()
		stamp.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		stamp.tween_property(mark, "scale", Vector3.ONE, 0.22)
		stamp.tween_property(mark, "position:y", mark.position.y + 0.22, 0.22)
		stamp.tween_method(func(v: float): _alpha(mark, v), 0.0, 0.92, 0.14)

	await get_tree().create_timer(1.15).timeout
	for mark in marks:
		var fade := create_tween()
		fade.tween_method(func(v: float): _alpha(mark, v), 0.92, 0.0, 0.22)
	var close := create_tween().set_parallel()
	close.tween_property(decree, "scale:x", 0.05, 0.25)
	close.tween_method(func(v: float): _alpha(decree, v), 0.95, 0.0, 0.22)
	await get_tree().create_timer(0.28).timeout


func _quad(node_name: String, texture: Texture2D, color: Color, size: Vector2) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = size
	var material := _material(texture, color)
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mesh.material = material
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	add_child(node)
	return node


func _strip(node_name: String, color: Color) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(2.6, 0.035, 0.16)
	mesh.material = _material(null, color)
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	add_child(node)
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
	material.emission_energy_multiplier = 2.4
	return material


func _dummy(at: Vector3) -> void:
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.23
	mesh.height = 1.0
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#51617d")
	mesh.material = material
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = at + Vector3(0.0, 0.5, 0.0)
	add_child(node)


func _alpha(node: MeshInstance3D, value: float) -> void:
	var material := node.mesh.material as StandardMaterial3D
	var color := material.albedo_color
	color.a = value
	material.albedo_color = color


func _hide() -> void:
	decree.visible = false
	for strip in page_strips:
		strip.visible = false
	for mark in marks:
		mark.visible = false


func _add_world() -> void:
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(7.0, 5.0)
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
	environment.ambient_light_color = Color("#b9c9e5")
	environment.ambient_light_energy = 0.75
	environment.glow_enabled = true
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)

	var camera := Camera3D.new()
	camera.position = Vector3(5.3, 3.4, 6.0)
	camera.fov = 40.0
	add_child(camera)
	camera.look_at(Vector3(1.0, 0.8, 0.0))
	camera.current = true
