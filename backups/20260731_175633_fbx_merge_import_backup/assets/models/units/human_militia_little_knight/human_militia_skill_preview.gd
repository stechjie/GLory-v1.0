extends Node3D

const UNIT_SCENE := preload("res://assets/models/units/human_militia_little_knight/human_militia_animated.tscn")
const TEX_CHARGE_DUST := preload("res://assets/models/units/human_militia_little_knight/human_militia_charge_dust_start.png")
const TEX_DUST_PUFF := preload("res://assets/models/units/human_militia_little_knight/human_militia_dust_puff.png")
const TEX_AIR_STREAK := preload("res://assets/models/units/human_militia_little_knight/human_militia_shield_air_streak.png")
const TEX_IMPACT_RING := preload("res://assets/models/units/human_militia_little_knight/human_militia_impact_ring.png")
const TEX_HIT_DUST := preload("res://assets/models/units/human_militia_little_knight/human_militia_hit_dust_pop.png")

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
	camera.position = Vector3(0, 2.1, 4.2)
	camera.rotation_degrees = Vector3(-23, 0, 0)
	camera.current = true
	add_child(camera)

func _setup_vfx() -> void:
	var root := Node3D.new()
	root.name = "SkillVFX"
	add_child(root)

	cards.append(_make_card(root, "ChargeDustStart", TEX_CHARGE_DUST, Vector3(0, 0.25, -0.15), Vector2(1.25, 0.62)))
	cards.append(_make_card(root, "DustPuff", TEX_DUST_PUFF, Vector3(0, 0.25, -0.45), Vector2(1.55, 0.76)))
	cards.append(_make_card(root, "ShieldAirStreak", TEX_AIR_STREAK, Vector3(0, 0.88, -0.55), Vector2(1.05, 1.05)))
	cards.append(_make_card(root, "ImpactRing", TEX_IMPACT_RING, Vector3(0, 0.82, -0.95), Vector2(1.35, 1.35)))
	cards.append(_make_card(root, "HitDustPop", TEX_HIT_DUST, Vector3(0, 0.48, -0.95), Vector2(0.95, 0.95)))
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
	mat.emission = Color(1, 1, 1)
	mat.emission_energy_multiplier = 0.7
	card.set_surface_override_material(0, mat)
	parent.add_child(card)
	return card

func play_skill() -> void:
	if unit != null and unit.has_method("play_attack"):
		unit.play_attack()
	play_skill_vfx()
	await get_tree().create_timer(1.8).timeout
	play_skill()

func play_skill_vfx() -> void:
	reset_vfx()
	# ponytail: 5 张卡片靠时间差衔接；先不做粒子系统。
	_animate_card($SkillVFX/ChargeDustStart, 0.03, Vector3.ONE * 0.45, Vector3.ONE * 0.75, 0.25)
	_animate_card($SkillVFX/ShieldAirStreak, 0.10, Vector3.ONE * 0.22, Vector3.ONE * 0.55, 0.12)
	_animate_card($SkillVFX/DustPuff, 0.22, Vector3.ONE * 0.55, Vector3.ONE * 1.05, 0.38)
	_animate_card($SkillVFX/ImpactRing, 0.28, Vector3.ONE * 0.25, Vector3.ONE * 0.90, 0.18)
	_animate_card($SkillVFX/HitDustPop, 0.30, Vector3.ONE * 0.30, Vector3.ONE * 0.65, 0.14)

func reset_vfx() -> void:
	for card in cards:
		card.visible = false
		card.scale = Vector3.ONE
		_set_alpha(card, 0.0)

func _animate_card(card: MeshInstance3D, delay: float, from_scale: Vector3, to_scale: Vector3, duration: float) -> void:
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
