extends Node3D

const ANGEL := preload("res://assets/models/units/god_angel_animated/god_angel_animated.tscn")
const WING := preload("res://assets/models/units/god_angel_animated/god_angel_shelter_wing.png")
const IMMUNITY := preload("res://assets/models/units/god_angel_animated/god_angel_immunity_feathers.png")

const WARM := Color("#fff2c9")
const BLUE := Color("#9de5ff")

var angel: Node3D
var wing_root: Node3D
var wings: Array[MeshInstance3D] = []
var warm_volume: MeshInstance3D
var immunity_marks: Array[MeshInstance3D] = []


func _ready() -> void:
	_build()
	while is_inside_tree():
		await _cast()
		await get_tree().create_timer(1.0).timeout


func _build() -> void:
	_add_world()
	angel = ANGEL.instantiate()
	add_child(angel)

	wing_root = Node3D.new()
	wing_root.name = "WingDome"
	wing_root.position.y = 0.65
	add_child(wing_root)
	for i in 6:
		var angle := TAU * i / 6.0
		var wing := _quad("ShelterWing%d" % i, WING, WARM, Vector2(1.45, 1.45), wing_root)
		wing.position = Vector3(sin(angle) * 0.82, 0.45, cos(angle) * 0.82)
		wing.rotation.y = angle
		wing.rotation.z = -0.9
		wings.append(wing)

	warm_volume = _sphere()
	warm_volume.position.y = 0.72

	for position in [Vector3(1.7, 0.0, -0.75), Vector3(2.3, 0.0, 0.0), Vector3(1.7, 0.0, 0.75)]:
		_dummy(position)
		var mark := _quad("ImmunityFeathers", IMMUNITY, BLUE, Vector2(0.5, 0.5))
		mark.position = position + Vector3(0.0, 1.32, 0.0)
		immunity_marks.append(mark)
	_hide()


func _cast() -> void:
	_hide()
	if angel.has_method("play_attack"):
		angel.call("play_attack")
	await get_tree().create_timer(0.15).timeout

	wing_root.visible = true
	for i in wings.size():
		var wing := wings[i]
		wing.visible = true
		wing.scale = Vector3(0.1, 0.1, 0.1)
		wing.rotation.z = -1.35
		_alpha(wing, 0.0)
		var appear := create_tween().set_parallel()
		appear.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		appear.tween_property(wing, "scale", Vector3.ONE, 0.3)
		appear.tween_property(wing, "rotation:z", -0.35, 0.35)
		appear.tween_method(func(v: float): _alpha(wing, v), 0.0, 0.88, 0.22)
		await get_tree().create_timer(0.04).timeout

	warm_volume.visible = true
	warm_volume.scale = Vector3(0.2, 0.2, 0.2)
	_alpha(warm_volume, 0.0)
	var shelter := create_tween().set_parallel()
	shelter.tween_property(warm_volume, "scale", Vector3(1.35, 0.95, 1.35), 0.22)
	shelter.tween_method(func(v: float): _alpha(warm_volume, v), 0.0, 0.34, 0.18)
	await get_tree().create_timer(0.20).timeout

	for wing in wings:
		var burst := create_tween().set_parallel()
		burst.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		burst.tween_property(wing, "rotation:z", -1.15, 0.22)
		burst.tween_property(wing, "scale", Vector3(1.2, 1.2, 1.2), 0.22)

	for mark in immunity_marks:
		mark.visible = true
		mark.scale = Vector3(0.12, 0.12, 0.12)
		_alpha(mark, 0.0)
		var stamp := create_tween().set_parallel()
		stamp.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		stamp.tween_property(mark, "scale", Vector3.ONE, 0.2)
		stamp.tween_method(func(v: float): _alpha(mark, v), 0.0, 0.92, 0.14)

	await get_tree().create_timer(0.32).timeout
	for wing in wings:
		var fade_wing := create_tween()
		fade_wing.tween_method(func(v: float): _alpha(wing, v), 0.88, 0.0, 0.25)
	var fade_volume := create_tween()
	fade_volume.tween_method(func(v: float): _alpha(warm_volume, v), 0.34, 0.0, 0.22)

	await get_tree().create_timer(1.68).timeout
	for mark in immunity_marks:
		var fade_mark := create_tween().set_parallel()
		fade_mark.tween_property(mark, "scale", Vector3(0.2, 0.2, 0.2), 0.22)
		fade_mark.tween_method(func(v: float): _alpha(mark, v), 0.92, 0.0, 0.22)
	await get_tree().create_timer(0.24).timeout


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


func _sphere() -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = 0.75
	mesh.height = 1.3
	mesh.radial_segments = 24
	mesh.rings = 12
	mesh.material = _material(null, WARM, 0.34)
	var node := MeshInstance3D.new()
	node.name = "WarmVolume"
	node.mesh = mesh
	add_child(node)
	return node


func _material(texture: Texture2D, color: Color, alpha := 1.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_texture = texture
	material.albedo_color = Color(color, alpha)
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
	wing_root.visible = false
	warm_volume.visible = false
	for wing in wings:
		wing.visible = false
	for mark in immunity_marks:
		mark.visible = false


func _add_world() -> void:
	if has_node("PreviewCamera"):
		return
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
	environment.ambient_light_color = Color("#c6d3e8")
	environment.ambient_light_energy = 0.78
	environment.glow_enabled = true
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)

	var camera := Camera3D.new()
	camera.position = Vector3(5.2, 3.5, 6.2)
	camera.fov = 40.0
	add_child(camera)
	camera.look_at(Vector3(1.0, 0.85, 0.0))
	camera.current = true
