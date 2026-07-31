extends Node3D

const UNIT_SCENE := preload("res://assets/models/units/human_cleric_animated/human_cleric_animated.tscn")
const TEX_WISP := preload("res://assets/models/units/human_cleric_animated/human_cleric_prayer_wisp.png")
const TEX_RIBBON := preload("res://assets/models/units/human_cleric_animated/human_cleric_heal_ribbon.png")
const TEX_MARK := preload("res://assets/models/units/human_cleric_animated/human_cleric_life_mark.png")
const HEAL_COLOR := Color(0.82, 1.0, 0.58, 1.0)

var unit: Node3D
var wisp: MeshInstance3D
var ribbons: Array[MeshInstance3D] = []
var marks: Array[MeshInstance3D] = []

@onready var vfx: Node3D = $VFX


func _ready() -> void:
	unit = UNIT_SCENE.instantiate()
	add_child(unit)
	unit.rotation_degrees.y = 180.0

	wisp = _make_card("PrayerWisp", TEX_WISP, Vector2(1.0, 1.0), true)
	for i in 3:
		var ribbon := _make_card("HealRibbon%s" % i, TEX_RIBBON, Vector2(1.7, 0.42), true)
		ribbons.append(ribbon)
	for i in 3:
		var mark := _make_card("LifeMark%s" % i, TEX_MARK, Vector2(1.15, 1.15), false)
		mark.rotation_degrees.x = -90.0
		marks.append(mark)

	_add_preview_camera()
	call_deferred("_loop")


func _loop() -> void:
	while is_inside_tree():
		await play_skill()
		await get_tree().create_timer(0.8).timeout


func play_skill() -> void:
	reset_vfx()
	if unit and unit.has_method("play_attack"):
		unit.play_attack()

	await get_tree().create_timer(0.25).timeout
	_pop(wisp, Vector3(0.0, 1.45, 0.50), 0.45, 0.72)

	await get_tree().create_timer(0.30).timeout
	_fly(ribbons[0], Vector3(0.05, 1.18, 0.35), Vector3(1.45, 0.72, 0.10), 0.34, 0.75, -0.30)
	_fly(ribbons[1], Vector3(0.05, 1.18, 0.35), Vector3(0.10, 0.72, -1.15), 0.34, 0.75, 0.08)
	_fly(ribbons[2], Vector3(0.05, 1.18, 0.35), Vector3(-1.25, 0.72, 0.05), 0.34, 0.75, 0.34)

	await get_tree().create_timer(0.28).timeout
	_life_mark(marks[0], Vector3(1.55, 0.04, 0.12), 1.05, 1.25)
	_life_mark(marks[1], Vector3(0.10, 0.04, -1.20), 1.05, 1.25)
	_life_mark(marks[2], Vector3(-1.35, 0.04, 0.02), 1.05, 1.25)

	await get_tree().create_timer(2.70).timeout
	if unit and unit.has_method("play_idle"):
		unit.play_idle()


func reset_vfx() -> void:
	for card in [wisp] + ribbons + marks:
		if card:
			card.visible = false
			_set_alpha(0.0, card)


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
	mat.emission = HEAL_COLOR
	if billboard:
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED

	var card := MeshInstance3D.new()
	card.name = name
	card.mesh = mesh
	card.material_override = mat
	card.visible = false
	vfx.add_child(card)
	return card


func _pop(card: MeshInstance3D, pos: Vector3, scale_to: float, life: float) -> void:
	card.position = pos
	card.rotation.z = 0.0
	card.scale = Vector3.ONE * 0.15
	card.visible = true

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "scale", Vector3.ONE * scale_to, life).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "rotation:z", 0.55, life)
	tween.tween_method(_set_alpha.bind(card), 0.0, 1.0, life * 0.25)
	tween.tween_method(_set_alpha.bind(card), 1.0, 0.0, life * 0.55).set_delay(life * 0.45)
	tween.chain().tween_callback(_hide_card.bind(card))


func _fly(card: MeshInstance3D, from: Vector3, to: Vector3, scale_to: float, life: float, rot_z: float) -> void:
	card.position = from
	card.rotation.z = rot_z
	card.scale = Vector3.ONE * scale_to
	card.visible = true

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "position", to, life).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "scale", Vector3.ONE * (scale_to * 1.2), life)
	tween.tween_method(_set_alpha.bind(card), 0.0, 0.95, life * 0.18)
	tween.tween_method(_set_alpha.bind(card), 0.95, 0.0, life * 0.52).set_delay(life * 0.48)
	tween.chain().tween_callback(_hide_card.bind(card))


func _life_mark(card: MeshInstance3D, pos: Vector3, scale_to: float, life: float) -> void:
	card.position = pos
	card.scale = Vector3.ONE * 0.28
	card.visible = true

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "scale", Vector3.ONE * scale_to, life).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "position:y", 0.28, life)
	tween.tween_property(card, "rotation:y", TAU, life)
	tween.tween_method(_set_alpha.bind(card), 0.0, 0.82, 0.16)
	tween.tween_method(_set_alpha.bind(card), 0.82, 0.0, life * 0.82).set_delay(0.20)
	tween.chain().tween_callback(_hide_card.bind(card))


func _set_alpha(alpha: float, card: MeshInstance3D) -> void:
	var mat := card.material_override as StandardMaterial3D
	mat.albedo_color = Color(1.0, 0.96, 0.70, alpha)
	mat.emission = HEAL_COLOR


func _hide_card(card: MeshInstance3D) -> void:
	card.visible = false


func _add_preview_camera() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, 35, 0)
	light.light_energy = 2.1
	add_child(light)

	var camera := Camera3D.new()
	camera.position = Vector3(0.25, 3.15, 5.35)
	camera.rotation_degrees = Vector3(-31, 2, 0)
	camera.current = true
	add_child(camera)
