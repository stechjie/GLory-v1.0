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
#
# 2026-11-05 restyle (layered flat fire after pixelfx, see ally_flame.gdshader):
# the scene specs were tuned for small additive sprites floating above the
# body; the FLAME_* multipliers below turn them into fewer, larger tongues
# rooted on the surface without touching the five scene files. Each point also
# gets a puff emitter (round blobs that break off and cool down the palette)
# and, on the bigger points, a few embers.
@export var flame_points: Array = []
@export var flame_material: Material

const FLAME_NODE_PREFIX := "AllyFlame_"
const FLAME_SIZE_MUL := 1.3
const FLAME_AMOUNT_MUL := 0.6
const FLAME_LIFETIME_MUL := 1.35
const FLAME_RISE_MUL := 0.55
const FLAME_RADIUS_MUL := 0.7
const FLAME_LIFT_MUL := 0.5
# Follow-through: emitter velocity (smoothed, so it lags like inertia) pushes
# live tongues backwards; align_y then leans each tongue along its velocity.
const FLAME_DRAG := 2.6
const FLAME_VEL_SMOOTH := 7.0
const FLAME_DRAG_MAX := 6.0
# Body emission breathes with the fire so the glow reads as coming from inside.
const BODY_PULSE_AMOUNT := 0.22
const BODY_PULSE_SPEED := 2.4
# puffs / embers relative to the point's tongue emitter
const PUFF_AMOUNT_MUL := 0.2
const PUFF_SIZE_MUL := 0.28
const PUFF_LIFETIME_MUL := 1.1
const EMBER_MIN_SPEC_SIZE := 0.4   # only points at least this big (scene units) get embers
const EMBER_AMOUNT := 2
const EMBER_SIZE_MUL := 0.09
var _flame_emitters: Dictionary = {}   # action -> Array[CPUParticles3D], one tongue emitter per flame point
var _flame_extra_emitters: Dictionary = {}   # action -> Array[CPUParticles3D], puffs + embers
var _flame_rise: Dictionary = {}       # CPUParticles3D -> base rise (world units / s^2)
var _flame_last_pos: Dictionary = {}   # CPUParticles3D -> Vector3
var _flame_vel: Dictionary = {}        # CPUParticles3D -> smoothed Vector3
var _body_material: ShaderMaterial
var _body_emission_base := 0.0
var _pulse_time := 0.0
static var _flame_quad: QuadMesh
static var _flame_ramp: Gradient
static var _flame_scale_curve: Curve
static var _puff_quad: QuadMesh
static var _puff_ramp: Gradient
static var _puff_scale_curve: Curve
var _puff_material: ShaderMaterial
var _tongue_material: Material

func _ready() -> void:
	super._ready()
	_build_flames()
	# The wrapper is usually positioned by its parent after _ready; starting
	# world-space emitters (with preprocess) now would leave a burst of tongues
	# at the spawn origin.
	_sync_flames.call_deferred()

func _activate_action(action: String, restart: bool) -> void:
	super._activate_action(action, restart)
	_sync_flames()

func _apply_material_override(root: Node, material: Material) -> void:
	# per-instance copy so the emission pulse never touches the shared .tres
	if material is ShaderMaterial and (material as ShaderMaterial).get_shader_parameter("emission_energy") != null:
		if _body_material == null:
			_body_material = material.duplicate() as ShaderMaterial
			# the copy has no resource_path; keep where it came from for checks / debugging
			_body_material.set_meta("source_material_path", material.resource_path)
			_body_emission_base = float(_body_material.get_shader_parameter("emission_energy"))
		material = _body_material
	super._apply_material_override(root, material)

func _process(delta: float) -> void:
	super._process(delta)
	_pulse_time += delta
	if _body_material != null and _body_emission_base > 0.0:
		var w := 0.65 * sin(_pulse_time * BODY_PULSE_SPEED) + 0.35 * sin(_pulse_time * BODY_PULSE_SPEED * 2.7 + 1.3)
		var k := 1.0 + BODY_PULSE_AMOUNT * w
		_body_material.set_shader_parameter("emission_energy", _body_emission_base * k)
	if delta <= 0.0:
		return
	var list: Array = _all_flame_emitters(current_action)
	var a := 1.0 - exp(-FLAME_VEL_SMOOTH * delta)
	for e in list:
		var p := e as CPUParticles3D
		if p == null or not p.is_inside_tree():
			continue
		var pos := p.global_position
		var last: Vector3 = _flame_last_pos.get(p, pos)
		_flame_last_pos[p] = pos
		var raw := (pos - last) / delta
		var rise := float(_flame_rise.get(p, 0.0))
		# a jump this fast is a teleport / re-placement, not motion
		if raw.length() > 12.0 * maxf(rise, 0.001):
			raw = Vector3.ZERO
		var vel: Vector3 = _flame_vel.get(p, Vector3.ZERO)
		vel = vel.lerp(raw, a)
		_flame_vel[p] = vel
		var drag := -vel * FLAME_DRAG
		if drag.length() > FLAME_DRAG_MAX * maxf(rise, 0.001):
			drag = drag.normalized() * FLAME_DRAG_MAX * rise
		_aim_flame(p, Vector3(drag.x, rise + minf(drag.y, 0.0) * 0.3, drag.z))

# Sets a world-space acceleration; local-space emitters get it (and "up")
# converted into the bone's frame.
func _aim_flame(p: CPUParticles3D, world_gravity: Vector3) -> void:
	if not p.local_coords:
		p.gravity = world_gravity
		return
	if not p.is_inside_tree():
		return
	var inv := p.global_transform.basis.inverse()
	p.gravity = inv * world_gravity
	var up := inv * Vector3.UP
	if up.length() > 0.000001:
		p.direction = up.normalized()

func _sync_flames() -> void:
	for key in _flame_emitters.keys():
		var on := str(key) == current_action
		for e in _all_flame_emitters(str(key)):
			var p := e as CPUParticles3D
			if p == null or p.emitting == on:
				continue
			if on:
				_flame_last_pos.erase(p)
				_flame_vel.erase(p)
				_aim_flame(p, Vector3(0.0, float(_flame_rise.get(p, 0.0)), 0.0))
				if p.is_inside_tree():
					p.restart()   # preprocess at the current position
				p.emitting = true
			else:
				p.emitting = false

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
		var extra_list: Array = []
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
			var lift := float(spec.get("lift", 0.0)) * FLAME_LIFT_MUL
			if not is_zero_approx(lift) and is_inside_tree():
				p.position = anchor.global_transform.basis.inverse() * (Vector3.UP * lift * wrapper_scale)
			list.append(p)
			var extras: Array = [_make_puff_emitter(spec, wrapper_scale)]
			if float(spec.get("size", 0.25)) >= EMBER_MIN_SPEC_SIZE:
				extras.append(_make_ember_emitter(spec, wrapper_scale))
			for q in extras:
				var ep := q as CPUParticles3D
				if ep == null:
					continue
				anchor.add_child(ep)
				ep.scale = p.scale
				ep.position = p.position
				extra_list.append(ep)
		_flame_emitters[action] = list
		_flame_extra_emitters[action] = extra_list

# tongue emitters (one per flame point) + their puff / ember emitters
func _all_flame_emitters(action: String) -> Array:
	return (_flame_emitters.get(action, []) as Array) + (_flame_extra_emitters.get(action, []) as Array)

func _make_emitter(spec: Dictionary, wrapper_scale: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.name = "Flame"
	p.emitting = false
	# Tongues ride on the body (local space): in world space a lunge or a run
	# left whole rows of tongues behind as a spray of spikes. The lean comes
	# from the drag in _process instead; gravity / direction are re-aimed at
	# world up every frame because the bone rotates under them.
	p.local_coords = true
	p.amount = maxi(3, int(round(float(spec.get("amount", 10)) * FLAME_AMOUNT_MUL)))
	p.lifetime = float(spec.get("lifetime", 0.55)) * FLAME_LIFETIME_MUL
	p.preprocess = p.lifetime
	p.randomness = 0.4
	p.draw_order = CPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	p.particle_flag_align_y = true
	p.fixed_fps = 30
	p.mesh = _flame_quad
	p.material_override = _get_tongue_material()
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = float(spec.get("radius", 0.06)) * FLAME_RADIUS_MUL
	p.direction = Vector3.UP
	p.spread = 12.0
	var rise := float(spec.get("rise", 1.6)) * wrapper_scale * FLAME_RISE_MUL
	_flame_rise[p] = rise
	p.gravity = Vector3(0.0, rise, 0.0)
	# local space is scaled by the wrapper; keep velocities and sizes in the
	# same world units the world-space version used
	var k := maxf(wrapper_scale, 0.001)
	p.initial_velocity_min = 0.05 * rise / k
	p.initial_velocity_max = 0.15 * rise / k
	p.damping_min = 0.5 / k
	p.damping_max = 1.0 / k
	var size := float(spec.get("size", 0.25)) * FLAME_SIZE_MUL
	p.scale_amount_min = size * 0.75 / k
	p.scale_amount_max = size * 1.15 / k
	p.scale_amount_curve = _flame_scale_curve
	p.color_ramp = _flame_ramp
	return p

# Tongues draw in three passes (rim, main, hot core) with rising render
# priority, so every tongue's rim is drawn before any core and neighbouring
# tongues merge into one fire instead of a stack of outlines.
func _get_tongue_material() -> Material:
	if _tongue_material != null:
		return _tongue_material
	if not (flame_material is ShaderMaterial):
		_tongue_material = flame_material
		return _tongue_material
	var base := flame_material.render_priority
	var passes: Array = [[0, 0], [1, 1], [2, 3]]
	var prev: ShaderMaterial = null
	for i in passes.size():
		var m := flame_material.duplicate() as ShaderMaterial
		m.render_priority = base + i
		m.set_shader_parameter("layer_from", passes[i][0])
		m.set_shader_parameter("layer_to", passes[i][1])
		if prev == null:
			_tongue_material = m
		else:
			prev.next_pass = m
		prev = m
	return _tongue_material

func _get_puff_material() -> ShaderMaterial:
	if _puff_material == null and flame_material is ShaderMaterial:
		_puff_material = flame_material.duplicate() as ShaderMaterial
		_puff_material.set_shader_parameter("puff", true)
		_puff_material.render_priority = flame_material.render_priority + 2
	return _puff_material

# Round blobs that break off the tongues, rise faster and cool down the palette.
func _make_puff_emitter(spec: Dictionary, wrapper_scale: float) -> CPUParticles3D:
	var mat := _get_puff_material()
	if mat == null:
		return null
	var p := CPUParticles3D.new()
	p.name = "FlamePuff"
	p.emitting = false
	p.local_coords = false
	p.amount = maxi(2, int(round(float(spec.get("amount", 10)) * PUFF_AMOUNT_MUL)))
	p.lifetime = float(spec.get("lifetime", 0.55)) * FLAME_LIFETIME_MUL * PUFF_LIFETIME_MUL
	p.preprocess = p.lifetime
	p.randomness = 0.6
	p.fixed_fps = 30
	p.draw_order = CPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	p.mesh = _puff_quad
	p.material_override = mat
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = float(spec.get("radius", 0.06)) * FLAME_RADIUS_MUL
	p.direction = Vector3.UP
	p.spread = 22.0
	var rise := float(spec.get("rise", 1.6)) * wrapper_scale * FLAME_RISE_MUL
	_flame_rise[p] = rise
	p.gravity = Vector3(0.0, rise, 0.0)
	var size := float(spec.get("size", 0.25)) * FLAME_SIZE_MUL
	# start roughly at the middle of a tongue
	p.initial_velocity_min = 0.6 * rise * maxf(size, 0.1)
	p.initial_velocity_max = 1.1 * rise * maxf(size, 0.1)
	p.damping_min = 0.2
	p.damping_max = 0.6
	p.scale_amount_min = size * PUFF_SIZE_MUL * 0.7
	p.scale_amount_max = size * PUFF_SIZE_MUL * 1.2
	p.scale_amount_curve = _puff_scale_curve
	p.color_ramp = _puff_ramp
	return p

# A couple of tiny sparks per big point, flung higher with a wider spread.
func _make_ember_emitter(spec: Dictionary, wrapper_scale: float) -> CPUParticles3D:
	var p := _make_puff_emitter(spec, wrapper_scale)
	if p == null:
		return null
	p.name = "FlameEmber"
	p.amount = EMBER_AMOUNT
	p.lifetime *= 1.4
	p.preprocess = p.lifetime
	p.spread = 40.0
	var size := float(spec.get("size", 0.25)) * FLAME_SIZE_MUL
	p.initial_velocity_min *= 1.6
	p.initial_velocity_max *= 2.2
	p.scale_amount_min = size * EMBER_SIZE_MUL * 0.7
	p.scale_amount_max = size * EMBER_SIZE_MUL * 1.3
	return p

static func _ensure_flame_shared() -> void:
	if _flame_quad == null:
		_flame_quad = QuadMesh.new()
		_flame_quad.size = Vector2(0.62, 1.0)
		_flame_quad.center_offset = Vector3(0.0, 0.32, 0.0)
	if _flame_ramp == null:
		_flame_ramp = Gradient.new()
		# alpha = tongue fullness (the shader shrinks the shape, it never fades)
		_flame_ramp.offsets = PackedFloat32Array([0.0, 0.14, 0.55, 1.0])
		_flame_ramp.colors = PackedColorArray([Color(1, 1, 1, 0.45), Color(1, 1, 1, 1.0), Color(1, 1, 1, 0.85), Color(1, 1, 1, 0.0)])
	if _puff_quad == null:
		_puff_quad = QuadMesh.new()
		_puff_quad.size = Vector2(1.0, 1.0)
	if _puff_ramp == null:
		# alpha = heat; the shader steps the colour down the palette as it cools
		_puff_ramp = Gradient.new()
		_puff_ramp.offsets = PackedFloat32Array([0.0, 1.0])
		_puff_ramp.colors = PackedColorArray([Color(1, 1, 1, 1.0), Color(1, 1, 1, 0.0)])
	if _puff_scale_curve == null:
		_puff_scale_curve = Curve.new()
		_puff_scale_curve.max_value = 1.2
		_puff_scale_curve.add_point(Vector2(0.0, 0.6))
		_puff_scale_curve.add_point(Vector2(0.12, 1.1))
		_puff_scale_curve.add_point(Vector2(0.3, 1.0))
		_puff_scale_curve.add_point(Vector2(1.0, 0.15))
	if _flame_scale_curve == null:
		_flame_scale_curve = Curve.new()
		# quick pop with a small overshoot, then settle and shrink
		_flame_scale_curve.max_value = 1.2
		_flame_scale_curve.add_point(Vector2(0.0, 0.5))
		_flame_scale_curve.add_point(Vector2(0.14, 1.1))
		_flame_scale_curve.add_point(Vector2(0.32, 1.0))
		_flame_scale_curve.add_point(Vector2(1.0, 0.55))
