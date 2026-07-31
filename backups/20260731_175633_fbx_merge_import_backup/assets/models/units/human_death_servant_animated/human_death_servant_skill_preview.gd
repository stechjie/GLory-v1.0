extends Node3D

const UNIT_SCENE := preload("res://assets/models/units/human_death_servant_animated/human_death_servant_animated.tscn")
const TEX_CRACK := preload("res://assets/models/units/human_death_servant_animated/human_death_servant_oath_crack.png")
const TEX_CHAIN := preload("res://assets/models/units/human_death_servant_animated/human_death_servant_blood_chain.png")
const TEX_GUARD := preload("res://assets/models/units/human_death_servant_animated/human_death_servant_guard_sigils.png")
const TEX_BURST := preload("res://assets/models/units/human_death_servant_animated/human_death_servant_sacrifice_burst.png")
const BLOOD := Color(1.0, 0.05, 0.03, 1.0)

var unit: Node3D
var ally_marker: MeshInstance3D
var crack: MeshInstance3D
var chain: MeshInstance3D
var guard: MeshInstance3D
var burst: MeshInstance3D

@onready var vfx: Node3D = $VFX


func _ready() -> void:
	unit = UNIT_SCENE.instantiate()
	add_child(unit)
	unit.rotation_degrees.y = 180.0

	ally_marker = _make_ally_marker()
	crack = _make_card("OathCrack", TEX_CRACK, Vector2(1.55, 1.55), false)
	chain = _make_card("BloodChain", TEX_CHAIN, Vector2(2.55, 0.55), true)
	guard = _make_card("GuardSigils", TEX_GUARD, Vector2(1.85, 1.85), false)
	burst = _make_card("SacrificeBurst", TEX_BURST, Vector2(1.45, 1.45), true)

	crack.rotation_degrees.x = -90.0
	guard.rotation_degrees.x = -90.0

	_add_preview_camera()
	call_deferred("_loop")


func _loop() -> void:
	while is_inside_tree():
		await play_skill()
		await get_tree().create_timer(0.7).timeout


func play_skill() -> void:
	reset_vfx()
	if unit and unit.has_method("play_idle"):
		unit.play_idle()

	await get_tree().create_timer(0.20).timeout
	_ground_pop(crack, Vector3(0.0, 0.04, 0.0), 1.0, 0.85)

	await get_tree().create_timer(0.25).timeout
	_connect_chain()

	await get_tree().create_timer(0.25).timeout
	_ground_pop(guard, Vector3(0.0, 0.09, 0.0), 1.0, 1.35)

	await get_tree().create_timer(1.10).timeout
	_sacrifice_burst()

	await get_tree().create_timer(1.25).timeout


func reset_vfx() -> void:
	for card in [crack, chain, guard, burst]:
		if card:
			card.visible = false
			_set_alpha(0.0, card)
	ally_marker.position = Vector3(2.05, 0.16, -0.75)
	ally_marker.scale = Vector3.ONE


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
	mat.emission = BLOOD
	if billboard:
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED

	var card := MeshInstance3D.new()
	card.name = name
	card.mesh = mesh
	card.material_override = mat
	card.visible = false
	vfx.add_child(card)
	return card


func _make_ally_marker() -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = 0.12
	mesh.height = 0.24

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.15, 0.18, 0.75)
	mat.emission_enabled = true
	mat.emission = Color(0.35, 0.0, 0.0)

	var marker := MeshInstance3D.new()
	marker.name = "ProtectedAllyMarker"
	marker.mesh = mesh
	marker.material_override = mat
	add_child(marker)
	return marker


func _ground_pop(card: MeshInstance3D, pos: Vector3, scale_to: float, life: float) -> void:
	card.position = pos
	card.scale = Vector3.ONE * 0.2
	card.visible = true

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "scale", Vector3.ONE * scale_to, life).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "rotation:y", TAU, life)
	tween.tween_method(_set_alpha.bind(card), 0.0, 0.95, life * 0.25)
	tween.tween_method(_set_alpha.bind(card), 0.95, 0.0, life * 0.55).set_delay(life * 0.55)
	tween.chain().tween_callback(_hide_card.bind(card))


func _connect_chain() -> void:
	chain.position = Vector3(1.05, 0.95, -0.36)
	chain.rotation_degrees.z = -12.0
	chain.scale = Vector3(0.18, 0.18, 0.18)
	chain.visible = true

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(chain, "scale", Vector3.ONE * 0.55, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_method(_set_alpha.bind(chain), 0.0, 1.0, 0.16)
	tween.tween_property(ally_marker, "scale", Vector3.ONE * 1.45, 0.20).set_delay(0.25)
	tween.tween_property(ally_marker, "scale", Vector3.ONE, 0.22).set_delay(0.48)
	tween.tween_method(_set_alpha.bind(chain), 1.0, 0.25, 0.75).set_delay(0.45)


func _sacrifice_burst() -> void:
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(chain, "position", Vector3(0.15, 1.05, -0.05), 0.22).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	tween.tween_property(chain, "scale", Vector3.ONE * 0.22, 0.22)
	tween.tween_method(_set_alpha.bind(chain), 0.8, 0.0, 0.22)

	burst.position = Vector3(0.0, 1.0, 0.22)
	burst.rotation.z = 0.0
	burst.scale = Vector3.ONE * 0.12
	burst.visible = true

	tween.tween_property(burst, "scale", Vector3.ONE * 0.78, 0.40).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(burst, "rotation:z", -0.85, 0.40)
	tween.tween_method(_set_alpha.bind(burst), 0.0, 1.0, 0.08)
	tween.tween_method(_set_alpha.bind(burst), 1.0, 0.0, 0.50).set_delay(0.32)
	tween.chain().tween_callback(_hide_card.bind(chain))
	tween.chain().tween_callback(_hide_card.bind(burst))


func _set_alpha(alpha: float, card: MeshInstance3D) -> void:
	var mat := card.material_override as StandardMaterial3D
	mat.albedo_color = Color(1.0, 0.08, 0.04, alpha)
	mat.emission = BLOOD


func _hide_card(card: MeshInstance3D) -> void:
	card.visible = false


func _add_preview_camera() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, 35, 0)
	light.light_energy = 2.0
	add_child(light)

	var camera := Camera3D.new()
	camera.position = Vector3(0.35, 3.25, 5.45)
	camera.rotation_degrees = Vector3(-31, 3, 0)
	camera.current = true
	add_child(camera)
