extends "res://assets/models/allies/FormationAllyAnimated.gd"
# Refined formation-ally wrapper (CODEX_MODEL_WORKFLOW, allies batch 2026-10-12).
#
# Keeps the original wrapper contract (play_idle/play_run/play_attack, proxy
# AnimationPlayer, ModelRoot, load_idle_only meta) and only adds:
#   - action_scales: per-action uniform scale for action FBX that were exported
#     in a different unit (soul_chain / hell_inferno run.fbx are re-rigged at
#     1/100 scale and vanished while running),
#   - action_yaw_degrees: per-action heading fix for the same re-rigged run.fbx
#     (soul_chain ran ~30 degrees off its idle/attack facing),
#   - action_lift: per-action vertical offset in wrapper units (the same run
#     sank 0.1-0.3 below the ground through its whole cycle),
#   - authored_animations: an AnimationLibrary attached to action models whose
#     FBX ships no AnimationPlayer (flame_claw),
#   - flame_points / flame_material: bone-attached body fire in the unit's
#     signature colour (see bottom of file).
# Original FBX files are referenced in place and never modified.

@export var action_scales: Dictionary = {}
@export var action_yaw_degrees: Dictionary = {}
@export var action_lift: Dictionary = {}
@export var authored_animations: AnimationLibrary

func _load_action_models() -> void:
	super._load_action_models()
	for action in action_nodes.keys():
		var node := action_nodes[action] as Node3D
		if node == null:
			continue
		var s := float(action_scales.get(action, 1.0))
		if not is_equal_approx(s, 1.0):
			node.scale *= s
		var yaw := float(action_yaw_degrees.get(action, 0.0))
		if not is_zero_approx(yaw):
			node.rotation_degrees.y += yaw
		var lift := float(action_lift.get(action, 0.0))
		if not is_zero_approx(lift):
			node.position.y += lift
		if authored_animations != null and action_players.get(action) == null:
			var player := AnimationPlayer.new()
			player.name = "AuthoredAnimationPlayer"
			player.add_animation_library("", authored_animations)
			node.add_child(player)
			action_players[action] = player

# ---- body fire ---------------------------------------------------------------
# flame_points: Array of Dictionary
#   bones   : Array[String]  candidate bone names, first one found on each action
#             skeleton is used (action FBX may use different rigs)
#   size    : float          flame sprite height in wrapper units
#   amount  : int            particles alive per emitter
#   lifetime: float          seconds
#   rise    : float          upward acceleration in wrapper units / s^2
#   radius  : float          emission sphere radius in wrapper units
#   lift    : float          emitter raised along world-up (wrapper units, at
#                            rest pose) so it sits on the surface, not inside
# Emitters run in world space (local_coords off) so flames trail while moving.
# Only the visible action model's emitters run.
@export var flame_points: Array = []
@export var flame_material: Material

const FLAME_NODE_PREFIX := "AllyFlame_"
var _flame_emitters: Dictionary = {}   # action -> Array[CPUParticles3D]
static var _flame_quad: QuadMesh
static var _flame_ramp: Gradient
static var _flame_scale_curve: Curve

func _ready() -> void:
	super._ready()
	_build_flames()
	_sync_flames()

func _activate_action(action: String, restart: bool) -> void:
	super._activate_action(action, restart)
	_sync_flames()

func _sync_flames() -> void:
	for key in _flame_emitters.keys():
		var on := str(key) == current_action
		for e in _flame_emitters[key]:
			var p := e as CPUParticles3D
			if p != null and p.emitting != on:
				p.emitting = on

func _build_flames() -> void:
	if flame_points.is_empty() or flame_material == null:
		return
	_ensure_flame_shared()
	var wrapper_scale := global_transform.basis.get_scale().x if is_inside_tree() else scale.x
	for action in action_nodes.keys():
		var node := action_nodes[action] as Node3D
		if node == null:
			continue
		var skels := node.find_children("*", "Skeleton3D", true, false)
		if skels.is_empty():
			continue
		var skel := skels[0] as Skeleton3D
		var list: Array = []
		for i in flame_points.size():
			var spec: Dictionary = flame_points[i]
			var bone := ""
			for candidate in spec.get("bones", []):
				if skel.find_bone(str(candidate)) >= 0:
					bone = str(candidate)
					break
			if bone.is_empty():
				continue
			var anchor := BoneAttachment3D.new()
			anchor.name = "%s%d" % [FLAME_NODE_PREFIX, i]
			anchor.bone_name = bone
			skel.add_child(anchor)
			var p := _make_emitter(spec, wrapper_scale)
			anchor.add_child(p)
			# undo the action-model / armature scale so every action's fire has
			# the same size in wrapper units (run.fbx of some units is x580)
			var rel := global_transform.affine_inverse() * anchor.global_transform if is_inside_tree() else Transform3D()
			var s := rel.basis.get_scale().x
			if s > 0.000001:
				p.scale = Vector3.ONE / s
			var lift := float(spec.get("lift", 0.0))
			if not is_zero_approx(lift) and is_inside_tree():
				p.position = anchor.global_transform.basis.inverse() * (Vector3.UP * lift * wrapper_scale)
			list.append(p)
		_flame_emitters[action] = list

func _make_emitter(spec: Dictionary, wrapper_scale: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.name = "Flame"
	p.emitting = false
	p.local_coords = false
	p.amount = int(spec.get("amount", 10))
	p.lifetime = float(spec.get("lifetime", 0.55))
	p.preprocess = p.lifetime
	p.randomness = 0.4
	p.fixed_fps = 30
	p.mesh = _flame_quad
	p.material_override = flame_material
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = float(spec.get("radius", 0.06))
	p.direction = Vector3.UP
	p.spread = 20.0
	var rise := float(spec.get("rise", 1.6)) * wrapper_scale
	p.gravity = Vector3(0.0, rise, 0.0)
	p.initial_velocity_min = 0.05 * rise
	p.initial_velocity_max = 0.15 * rise
	p.damping_min = 0.5
	p.damping_max = 1.0
	var size := float(spec.get("size", 0.25))
	p.scale_amount_min = size * 0.75
	p.scale_amount_max = size * 1.15
	p.scale_amount_curve = _flame_scale_curve
	p.angle_min = -8.0
	p.angle_max = 8.0
	p.color_ramp = _flame_ramp
	return p

static func _ensure_flame_shared() -> void:
	if _flame_quad == null:
		_flame_quad = QuadMesh.new()
		_flame_quad.size = Vector2(0.62, 1.0)
		_flame_quad.center_offset = Vector3(0.0, 0.32, 0.0)
	if _flame_ramp == null:
		_flame_ramp = Gradient.new()
		_flame_ramp.offsets = PackedFloat32Array([0.0, 0.18, 0.6, 1.0])
		_flame_ramp.colors = PackedColorArray([Color(1, 1, 1, 0.0), Color(1, 1, 1, 1.0), Color(1, 1, 1, 0.75), Color(1, 1, 1, 0.0)])
	if _flame_scale_curve == null:
		_flame_scale_curve = Curve.new()
		_flame_scale_curve.add_point(Vector2(0.0, 0.55))
		_flame_scale_curve.add_point(Vector2(0.3, 1.0))
		_flame_scale_curve.add_point(Vector2(1.0, 0.35))
