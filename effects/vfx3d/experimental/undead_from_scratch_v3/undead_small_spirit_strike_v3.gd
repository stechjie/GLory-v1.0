extends Node3D
class_name UndeadSmallSpiritStrikeV3

## V3 is intentionally separate from UndeadSmallStrikeExperimentV2.
## Blender owns the asymmetric claws; this controller only supplies real battle
## anchors, an authored reveal timeline, material cleanup and mesh-shard motion.

@export var autoplay := false
@export var cycle_time := 0.42
@export var effekseer_effect: EffekseerEffect

const CAST_OFFSET := 0.16
const CAST_HEIGHT := 0.38
const IMPACT_TIME := 0.18
const RELEASE_A_START := 0.06
const RELEASE_B_START := 0.085
const RELEASE_A_END := 0.145
const RELEASE_B_END := 0.165
const DISSIPATE_START := 0.26

const DARK := Color("160917")
const BODY_A := Color("3E8F6B")
const BODY_B := Color("5AB982")
const CORE := Color("DCFFA8")
const SHARD := Color("69C18F")

@onready var art: Node3D = $Art
@onready var effekseer_emitter: EffekseerEmitter3D = get_node_or_null("EffekseerEmitter3D") as EffekseerEmitter3D

var _time := 0.0
var _playing := false
var _layer_materials: Dictionary = {}
var _shards: Array[MeshInstance3D] = []
var _shard_rest_positions: Dictionary = {}
var _impact_emitted := false

func _ready() -> void:
	_bind_blender_geometry()
	if effekseer_emitter != null:
		effekseer_emitter.effect = effekseer_effect
		effekseer_emitter.stop()
	visible = false
	if autoplay:
		play(global_position, global_position + Vector3.FORWARD)

func play(caster_world: Vector3, target_world: Vector3) -> void:
	var attack_direction := target_world - caster_world
	attack_direction.y = 0.0
	if attack_direction.length_squared() <= 0.0001:
		attack_direction = Vector3.FORWARD
	attack_direction = attack_direction.normalized()
	global_position = caster_world + attack_direction * CAST_OFFSET + Vector3.UP * CAST_HEIGHT
	look_at(global_position + attack_direction, Vector3.UP)
	if effekseer_emitter != null:
		# The emitter is target-local, not a cosmetic cloud at the caster.
		effekseer_emitter.global_position = target_world - attack_direction * 0.18 + Vector3.UP * 0.34
		effekseer_emitter.stop()
	_time = 0.0
	_playing = true
	_impact_emitted = false
	visible = true
	_reset_visual_state()

func stop() -> void:
	_playing = false
	visible = false
	if effekseer_emitter != null:
		effekseer_emitter.stop()
	_reset_visual_state()

func _process(delta: float) -> void:
	if not _playing:
		return
	_time += delta
	_update_timeline(_time)
	if _time >= cycle_time:
		stop()

func _bind_blender_geometry() -> void:
	var shader := load("res://effects/vfx3d/experimental/undead_from_scratch_v3/undead_small_spirit_claw_v3.gdshader") as Shader
	if shader == null:
		push_error("V3 claw shader missing.")
		return
	for node in _descendants(art):
		if not node is MeshInstance3D:
			continue
		var mesh_node := node as MeshInstance3D
		var material := ShaderMaterial.new()
		material.shader = shader
		var role := mesh_node.name
		material.render_priority = -1 if role.contains("Dark") else (2 if role.contains("Core") else 0)
		material.set_shader_parameter("layer_color", _color_for_role(role))
		material.set_shader_parameter("reveal", 0.0)
		material.set_shader_parameter("opacity", 0.0)
		material.set_shader_parameter("core_energy", 1.8 if role.contains("Core") else 0.12)
		mesh_node.material_override = material
		_layer_materials[mesh_node] = material
		if role.begins_with("Shard"):
			_shards.append(mesh_node)
			_shard_rest_positions[mesh_node] = mesh_node.position

func _update_timeline(time: float) -> void:
	var release_a := _ease_window(time, RELEASE_A_START, RELEASE_A_END)
	var release_b := _ease_window(time, RELEASE_B_START, RELEASE_B_END)
	var fade := 1.0 - _ease_window(time, DISSIPATE_START, cycle_time)
	for mesh_node_variant in _layer_materials.keys():
		var mesh_node := mesh_node_variant as MeshInstance3D
		var material := _layer_materials[mesh_node_variant] as ShaderMaterial
		if mesh_node == null or material == null:
			continue
		var role := mesh_node.name
		var release := release_b if role.begins_with("ClawB") else release_a
		if role.begins_with("Shard"):
			_update_shard(mesh_node, material, time, fade)
			continue
		var local_reveal := release
		if role.contains("Core"):
			local_reveal = maxf(0.0, (release - 0.34) / 0.66)
		material.set_shader_parameter("reveal", local_reveal * 1.12)
		material.set_shader_parameter("opacity", fade * (0.96 if role.contains("Dark") else 1.0))
		material.set_shader_parameter("core_energy", (2.1 if time >= IMPACT_TIME and time < DISSIPATE_START else 1.3) if role.contains("Core") else 0.10)
	if time >= IMPACT_TIME and not _impact_emitted and effekseer_emitter != null and effekseer_effect != null:
		_impact_emitted = true
		effekseer_emitter.play()

func _update_shard(mesh_node: MeshInstance3D, material: ShaderMaterial, time: float, fade: float) -> void:
	var burst := clampf((time - IMPACT_TIME) / 0.12, 0.0, 1.0)
	mesh_node.visible = burst > 0.0
	material.set_shader_parameter("reveal", 1.12)
	material.set_shader_parameter("opacity", burst * fade)
	material.set_shader_parameter("core_energy", 0.55)
	var rest := _shard_rest_positions.get(mesh_node, Vector3.ZERO) as Vector3
	var ordinal := float(_shards.find(mesh_node) + 1)
	mesh_node.position = rest + Vector3(0.07 * ordinal, 0.16 + 0.045 * ordinal, -0.20 - 0.055 * ordinal) * burst
	mesh_node.rotation = Vector3(0.8 * ordinal, 1.1 * ordinal, -0.6 * ordinal) * burst

func _reset_visual_state() -> void:
	for mesh_node_variant in _layer_materials.keys():
		var mesh_node := mesh_node_variant as MeshInstance3D
		var material := _layer_materials[mesh_node_variant] as ShaderMaterial
		if mesh_node == null or material == null:
			continue
		material.set_shader_parameter("reveal", 0.0)
		material.set_shader_parameter("opacity", 0.0)
		if mesh_node.name.begins_with("Shard"):
			mesh_node.visible = false
			mesh_node.position = _shard_rest_positions.get(mesh_node, Vector3.ZERO) as Vector3
			mesh_node.rotation = Vector3.ZERO

func _color_for_role(role: String) -> Color:
	if role.contains("Dark"):
		return DARK
	if role.contains("Core"):
		return CORE
	if role.begins_with("Shard"):
		return SHARD
	return BODY_A if role.begins_with("ClawA") else BODY_B

func _ease_window(time: float, start_time: float, end_time: float) -> float:
	var t := clampf((time - start_time) / maxf(0.001, end_time - start_time), 0.0, 1.0)
	return 1.0 - pow(1.0 - t, 3.0)

func _descendants(root: Node) -> Array[Node]:
	var result: Array[Node] = []
	for child in root.get_children():
		result.append(child)
		result.append_array(_descendants(child))
	return result
