extends Node3D

const UNIT_SCENE := preload("res://assets/models/units/human_archer_animated/human_archer_animated.tscn")
const TEX_CHARGE := preload("res://assets/models/units/human_archer_animated/human_archer_charge_wind.png")
const TEX_TRAIL := preload("res://assets/models/units/human_archer_animated/human_archer_arrow_trail.png")
const TEX_FLASH := preload("res://assets/models/units/human_archer_animated/human_archer_pierce_flash.png")
const TEX_CRACK := preload("res://assets/models/units/human_archer_animated/human_archer_star_crack.png")
const TEX_LEAF := preload("res://assets/models/units/human_archer_animated/human_archer_leaf_spark.png")

var unit: Node3D
var cards: Array[MeshInstance3D] = []

func _ready() -> void:
	_setup_scene()
	_setup_vfx()
	play_skill()

func _setup_scene() -> void:
	unit = UNIT_SCENE.instantiate()
	add_child(unit)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, 35, 0)
	light.light_energy = 2.0
	add_child(light)
	var camera := Camera3D.new()
	camera.position = Vector3(0, 2.1, 4.4)
	camera.rotation_degrees = Vector3(-23, 0, 0)
	camera.current = true
	add_child(camera)

func _setup_vfx() -> void:
	var root := Node3D.new()
	root.name = "SkillVFX"
	add_child(root)
	cards.append(_make_card(root, "ChargeWind", TEX_CHARGE, Vector3(0.16, 1.05, -0.35), Vector2(0.75, 0.75)))
	cards.append(_make_card(root, "ArrowTrail", TEX_TRAIL, Vector3(0.0, 1.02, -0.78), Vector2(1.70, 0.42)))
	cards.append(_make_card(root, "PierceFlash", TEX_FLASH, Vector3(0, 1.0, -1.25), Vector2(0.85, 0.85)))
	cards.append(_make_card(root, "StarCrack", TEX_CRACK, Vector3(0, 0.92, -1.35), Vector2(1.05, 1.05)))
	cards.append(_make_card(root, "LeafSpark", TEX_LEAF, Vector3(0, 0.84, -1.35), Vector2(1.05, 1.05)))
	reset_vfx()

func _make_card(parent: Node, node_name: String, texture: Texture2D, pos: Vector3, size: Vector2) -> MeshInstance3D:
	var card := MeshInstance3D.new()
	card.name = node_name
	card.position = pos
	var mesh := QuadMesh.new()
	mesh.size = size
	card.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_texture = texture
	mat.albedo_color = Color(1, 1, 1, 0)
	mat.emission_enabled = true
	mat.emission_texture = texture
	mat.emission = Color(0.65, 1.0, 0.65)
	mat.emission_energy_multiplier = 0.9
	card.set_surface_override_material(0, mat)
	parent.add_child(card)
	return card

func play_skill() -> void:
	if unit != null and unit.has_method("play_attack"):
		unit.play_attack()
	play_skill_vfx()
	await get_tree().create_timer(4.4).timeout
	play_skill()

func play_skill_vfx() -> void:
	reset_vfx()
	# ponytail: 5 张卡片完成蓄力-飞行-命中，不做粒子系统。
	_pop_card($SkillVFX/ChargeWind, 0.30, Vector3.ONE * 0.25, Vector3.ONE * 0.75, 0.55)
	_fly_card($SkillVFX/ArrowTrail, 1.05, Vector3(0.12, 1.02, -0.45), Vector3(0.0, 1.02, -1.18), 0.16)
	_pop_card($SkillVFX/PierceFlash, 1.16, Vector3.ONE * 0.20, Vector3.ONE * 0.70, 0.12)
	_pop_card($SkillVFX/StarCrack, 1.22, Vector3.ONE * 0.22, Vector3.ONE * 0.95, 0.28)
	_pop_card($SkillVFX/LeafSpark, 1.36, Vector3.ONE * 0.35, Vector3.ONE * 1.05, 0.55)

func reset_vfx() -> void:
	for card in cards:
		card.visible = false
		card.scale = Vector3.ONE
		card.position.x = card.position.x
		_set_alpha(card, 0.0)

func _pop_card(card: MeshInstance3D, delay: float, from_scale: Vector3, to_scale: Vector3, duration: float) -> void:
	await get_tree().create_timer(delay).timeout
	if not is_instance_valid(card):
		return
	card.visible = true
	card.scale = from_scale
	_set_alpha(card, 1.0)
	var tween := create_tween()
	tween.tween_property(card, "scale", to_scale, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_method(func(a: float) -> void: _set_alpha(card, a), 1.0, 0.0, duration)
	tween.tween_callback(card.hide)

func _fly_card(card: MeshInstance3D, delay: float, from_pos: Vector3, to_pos: Vector3, duration: float) -> void:
	await get_tree().create_timer(delay).timeout
	if not is_instance_valid(card):
		return
	card.visible = true
	card.position = from_pos
	card.scale = Vector3.ONE * 0.55
	_set_alpha(card, 1.0)
	var tween := create_tween()
	tween.tween_property(card, "position", to_pos, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(card, "scale", Vector3.ONE * 0.9, duration)
	tween.parallel().tween_method(func(a: float) -> void: _set_alpha(card, a), 1.0, 0.0, duration)
	tween.tween_callback(card.hide)

func _set_alpha(card: MeshInstance3D, alpha: float) -> void:
	var mat := card.get_surface_override_material(0) as StandardMaterial3D
	if mat == null:
		return
	var color := mat.albedo_color
	color.a = alpha
	mat.albedo_color = color
