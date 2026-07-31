extends Node3D

const UNIT_SCENE := preload("res://assets/models/units/human_swordsman_animated/human_swordsman_animated.tscn")
const TEX_ARC := preload("res://assets/models/units/human_swordsman_animated/human_swordsman_arc_180.png")
const TEX_IMPACT := preload("res://assets/models/units/human_swordsman_animated/human_swordsman_front_impact.png")
const TEX_STUN := preload("res://assets/models/units/human_swordsman_animated/human_swordsman_stun_ring.png")
const TEX_SHARDS := preload("res://assets/models/units/human_swordsman_animated/human_swordsman_after_shards.png")

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
	cards.append(_make_card(root, "Arc180", TEX_ARC, Vector3(0, 0.72, -0.70), Vector2(2.15, 1.05)))
	cards.append(_make_card(root, "FrontImpact", TEX_IMPACT, Vector3(0, 0.82, -1.12), Vector2(1.05, 1.05)))
	cards.append(_make_card(root, "StunRing", TEX_STUN, Vector3(0, 1.25, -1.12), Vector2(0.62, 0.62)))
	cards.append(_make_card(root, "AfterShards", TEX_SHARDS, Vector3(0, 0.82, -1.12), Vector2(1.05, 1.05)))
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
	mat.emission = Color(0.70, 0.88, 1.0)
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
	# ponytail: 正确技能是前排 180° 晕眩斩，不做多余连斩。
	_pop_card($SkillVFX/Arc180, 0.85, Vector3(0.30, 0.30, 0.30), Vector3.ONE, 0.22)
	_pop_card($SkillVFX/FrontImpact, 1.05, Vector3.ONE * 0.20, Vector3.ONE * 0.95, 0.24)
	_pop_card($SkillVFX/StunRing, 1.12, Vector3.ONE * 0.25, Vector3.ONE * 0.85, 1.00)
	_pop_card($SkillVFX/AfterShards, 1.28, Vector3.ONE * 0.35, Vector3.ONE * 1.05, 0.45)

func reset_vfx() -> void:
	for card in cards:
		card.visible = false
		card.scale = Vector3.ONE
		card.rotation_degrees = Vector3.ZERO
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

func _set_alpha(card: MeshInstance3D, alpha: float) -> void:
	var mat := card.get_surface_override_material(0) as StandardMaterial3D
	if mat == null:
		return
	var color := mat.albedo_color
	color.a = alpha
	mat.albedo_color = color
