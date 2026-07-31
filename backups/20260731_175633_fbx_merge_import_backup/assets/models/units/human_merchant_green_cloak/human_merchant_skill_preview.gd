extends Node3D

const UNIT_SCENE := preload("res://assets/models/units/human_merchant_green_cloak/human_merchant_animated.tscn")
const TEX_PURSE := preload("res://assets/models/units/human_merchant_green_cloak/human_merchant_purse_puff.png")
const TEX_COINS := preload("res://assets/models/units/human_merchant_green_cloak/human_merchant_coin_trail.png")
const TEX_CONTRACT := preload("res://assets/models/units/human_merchant_green_cloak/human_merchant_contract_slip.png")
const TEX_MARK := preload("res://assets/models/units/human_merchant_green_cloak/human_merchant_bounty_mark.png")
const TEX_SPARK := preload("res://assets/models/units/human_merchant_green_cloak/human_merchant_coin_spark.png")

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

	cards.append(_make_card(root, "PursePuff", TEX_PURSE, Vector3(0.20, 0.88, -0.25), Vector2(0.85, 0.42)))
	cards.append(_make_card(root, "CoinTrailA", TEX_COINS, Vector3(0.10, 0.95, -0.45), Vector2(1.20, 0.60)))
	cards.append(_make_card(root, "ContractSlip", TEX_CONTRACT, Vector3(0.00, 1.02, -0.62), Vector2(0.92, 0.46)))
	cards.append(_make_card(root, "CoinTrailB", TEX_COINS, Vector3(-0.03, 0.98, -0.75), Vector2(1.05, 0.52)))
	cards.append(_make_card(root, "BountyMark", TEX_MARK, Vector3(0, 1.05, -1.05), Vector2(0.62, 0.62)))
	cards.append(_make_card(root, "CoinSpark", TEX_SPARK, Vector3(0, 0.82, -1.05), Vector2(0.90, 0.90)))
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
	mat.emission = Color(1, 0.86, 0.45)
	mat.emission_energy_multiplier = 0.75
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
	# ponytail: 商人靠卡片飞行和弹出衔接，不做粒子系统。
	_pop_card($SkillVFX/PursePuff, 0.06, Vector3.ONE * 0.35, Vector3.ONE * 0.70, 0.24)
	_fly_card($SkillVFX/CoinTrailA, 0.14, Vector3(0.15, 0.92, -0.34), Vector3(0.00, 0.98, -0.72), 0.20)
	_fly_card($SkillVFX/ContractSlip, 0.20, Vector3(0.12, 1.00, -0.42), Vector3(0.00, 1.04, -0.88), 0.24, 55.0)
	_fly_card($SkillVFX/CoinTrailB, 0.28, Vector3(0.06, 0.94, -0.64), Vector3(0.00, 1.00, -1.00), 0.16)
	_pop_card($SkillVFX/BountyMark, 0.38, Vector3.ONE * 0.20, Vector3.ONE * 0.72, 0.34)
	_pop_card($SkillVFX/CoinSpark, 0.46, Vector3.ONE * 0.28, Vector3.ONE * 0.78, 0.22)

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
	tween.tween_property(card, "scale", to_scale, duration).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_method(func(a: float) -> void: _set_alpha(card, a), 1.0, 0.0, duration)
	tween.tween_callback(card.hide)

func _fly_card(card: MeshInstance3D, delay: float, from_pos: Vector3, to_pos: Vector3, duration: float, spin: float = 0.0) -> void:
	await get_tree().create_timer(delay).timeout
	if not is_instance_valid(card):
		return
	card.visible = true
	card.position = from_pos
	card.scale = Vector3.ONE * 0.55
	_set_alpha(card, 1.0)
	var tween := create_tween()
	tween.tween_property(card, "position", to_pos, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(card, "rotation_degrees:z", spin, duration)
	tween.parallel().tween_method(func(a: float) -> void: _set_alpha(card, a), 1.0, 0.0, duration)
	tween.tween_callback(card.hide)

func _set_alpha(card: MeshInstance3D, alpha: float) -> void:
	var mat := card.get_surface_override_material(0) as StandardMaterial3D
	if mat == null:
		return
	var color := mat.albedo_color
	color.a = alpha
	mat.albedo_color = color
