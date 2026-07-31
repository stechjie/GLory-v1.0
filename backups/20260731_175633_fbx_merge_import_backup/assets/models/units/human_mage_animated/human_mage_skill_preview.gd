extends Node3D

const UNIT_SCENE := preload("res://assets/models/units/human_mage_animated/human_mage_animated.tscn")
const TEX_ORB := preload("res://assets/models/units/human_mage_animated/human_mage_element_orb.png")
const TEX_TRAIL := preload("res://assets/models/units/human_mage_animated/human_mage_element_trail.png")
const TEX_BURST := preload("res://assets/models/units/human_mage_animated/human_mage_element_burst.png")
const TEX_RESIDUE := preload("res://assets/models/units/human_mage_animated/human_mage_element_residue.png")

const ELEMENT_COLORS := [
	Color(1.0, 0.38, 0.10, 1.0), # fire
	Color(0.36, 0.82, 1.0, 1.0), # ice
	Color(0.78, 0.38, 1.0, 1.0), # lightning
]

var unit: Node3D
var element_index := 0
var orb: MeshInstance3D
var trail: MeshInstance3D
var burst: MeshInstance3D
var residue: MeshInstance3D

@onready var vfx: Node3D = $VFX


func _ready() -> void:
	unit = UNIT_SCENE.instantiate()
	add_child(unit)
	unit.rotation_degrees.y = 180.0

	orb = _make_card("Orb", TEX_ORB, Vector2(1.0, 1.0), true)
	trail = _make_card("Trail", TEX_TRAIL, Vector2(2.0, 0.5), true)
	burst = _make_card("Burst", TEX_BURST, Vector2(1.25, 1.25), true)
	residue = _make_card("Residue", TEX_RESIDUE, Vector2(1.8, 1.8), false)
	residue.rotation_degrees.x = -90.0

	_add_preview_camera()
	call_deferred("_loop")


func _loop() -> void:
	while is_inside_tree():
		await play_skill()
		await get_tree().create_timer(0.65).timeout


func play_skill() -> void:
	reset_vfx()
	var color: Color = ELEMENT_COLORS[element_index % ELEMENT_COLORS.size()]
	element_index += 1

	if unit and unit.has_method("set_action"):
		unit.set_action("attack")

	await get_tree().create_timer(0.20).timeout
	_pop(orb, Vector3(0.0, 1.45, 0.55), 0.42, 0.55, color, 1.1)

	await get_tree().create_timer(0.42).timeout
	_fly(trail, Vector3(0.15, 1.25, 0.45), Vector3(1.85, 1.15, 0.20), 0.52, 0.34, color)

	await get_tree().create_timer(0.26).timeout
	_pop(burst, Vector3(2.05, 1.18, 0.16), 0.62, 0.48, color, -0.8)
	_linger(residue, Vector3(2.05, 0.05, 0.16), 0.95, 2.50, color)

	await get_tree().create_timer(2.65).timeout
	if unit and unit.has_method("set_action"):
		unit.set_action("idle")


func reset_vfx() -> void:
	for card in [orb, trail, burst, residue]:
		if card:
			card.visible = false
			_set_alpha(0.0, card, Color.WHITE)


func _make_card(name: String, tex: Texture2D, size: Vector2, billboard: bool) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = size

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_texture = tex
	mat.emission_enabled = true
	mat.emission_texture = tex
	mat.emission = Color.WHITE
	if billboard:
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED

	var card := MeshInstance3D.new()
	card.name = name
	card.mesh = mesh
	card.material_override = mat
	card.visible = false
	vfx.add_child(card)
	return card


func _pop(card: MeshInstance3D, pos: Vector3, scale_to: float, life: float, color: Color, spin: float) -> void:
	card.position = pos
	card.rotation.z = 0.0
	card.scale = Vector3.ONE * 0.12
	card.visible = true

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "scale", Vector3.ONE * scale_to, life).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "rotation:z", spin, life)
	tween.tween_method(_set_alpha.bind(card, color), 0.0, 1.0, life * 0.22)
	tween.tween_method(_set_alpha.bind(card, color), 1.0, 0.0, life * 0.55).set_delay(life * 0.45)
	tween.chain().tween_callback(_hide_card.bind(card))


func _fly(card: MeshInstance3D, from: Vector3, to: Vector3, scale_to: float, life: float, color: Color) -> void:
	card.position = from
	card.scale = Vector3.ONE * scale_to
	card.visible = true

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "position", to, life).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "scale", Vector3.ONE * (scale_to * 1.18), life)
	tween.tween_method(_set_alpha.bind(card, color), 0.0, 1.0, life * 0.20)
	tween.tween_method(_set_alpha.bind(card, color), 1.0, 0.0, life * 0.55).set_delay(life * 0.42)
	tween.chain().tween_callback(_hide_card.bind(card))


func _linger(card: MeshInstance3D, pos: Vector3, scale_to: float, life: float, color: Color) -> void:
	card.position = pos
	card.scale = Vector3.ONE * 0.35
	card.visible = true

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "scale", Vector3.ONE * scale_to, life).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "rotation:y", TAU, life)
	tween.tween_method(_set_alpha.bind(card, color), 0.0, 0.72, 0.18)
	tween.tween_method(_set_alpha.bind(card, color), 0.72, 0.0, life).set_delay(0.18)
	tween.chain().tween_callback(_hide_card.bind(card))


func _set_alpha(alpha: float, card: MeshInstance3D, color: Color) -> void:
	var mat := card.material_override as StandardMaterial3D
	mat.albedo_color = Color(color.r, color.g, color.b, alpha)
	mat.emission = Color(color.r, color.g, color.b, 1.0)


func _hide_card(card: MeshInstance3D) -> void:
	card.visible = false


func _add_preview_camera() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, 35, 0)
	light.light_energy = 2.2
	add_child(light)

	var camera := Camera3D.new()
	camera.position = Vector3(0.3, 3.2, 5.2)
	camera.rotation_degrees = Vector3(-31, 3, 0)
	camera.current = true
	add_child(camera)
