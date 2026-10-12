extends SceneTree
# Authors idle / run / attack skeletal clips for 焰爪魔灵 (ally_flame_claw).
# The source FBX (idle == attack == run, same file hash) ships a 17-bone
# quadruped rig but NO animation, so the unit stood frozen in every action.
#
# Clips are keyed as bone-local rotations derived from model-space intent
# (pitch about the model's right axis, yaw about up), conjugated into each
# bone's rest frame, so the parameters below read in model terms:
#   +pitch = nose / limb tip toward the ground-forward, see _pitch().
# Re-run:  godot --headless --path <proj> --script \
#   res://tools/model_refinement/allies/gen_flame_claw_anims.gd -- [--out res://...tres] [--dump]

const SRC := "res://assets/models/allies/formation_ally_1_animated/idle.fbx"
const OUT := "res://assets/models/allies_refined/ally_flame_claw/ally_flame_claw_anims.tres"
const FPS := 30.0

var skel: Skeleton3D
var skel_path := ""
var model_to_skel := Basis()   # rotates model-space vectors into skeleton space

func _initialize() -> void:
	var out := OUT
	var dump := false
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--out":
			out = args[i + 1]
		if args[i] == "--dump":
			dump = true
	var root := (load(SRC) as PackedScene).instantiate() as Node3D
	get_root().add_child(root)
	skel = root.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	skel_path = String(root.get_path_to(skel))
	# skeleton global basis relative to the FBX root (Armature carries -90 X, x100)
	var xf := _rel_xf(root, skel)
	model_to_skel = xf.basis.orthonormalized().inverse()
	if dump:
		for b in skel.get_bone_count():
			var g := skel.get_bone_global_rest(b)
			print("BONE %d %s parent=%d model_pos=%s" % [b, skel.get_bone_name(b), skel.get_bone_parent(b), xf * g.origin])
	var lib := AnimationLibrary.new()
	lib.add_animation("idle", _idle())
	lib.add_animation("run", _run())
	lib.add_animation("attack", _attack())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out.get_base_dir()))
	var err := ResourceSaver.save(lib, out)
	print("ANIMS_SAVED ", out, " err=", err, " skel_path=", skel_path)
	quit(0 if err == OK else 1)

# ---- helpers -------------------------------------------------------------

# transform of `node` relative to `root` (works before entering the tree)
func _rel_xf(root: Node, node: Node) -> Transform3D:
	var xf := Transform3D()
	var n := node
	while n != null and n != root:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf

func _bone(name: String) -> int:
	var b := skel.find_bone(name)
	assert(b >= 0, name)
	return b

# Local rotation for bone `b` after applying a model-space delta rotation
# (axis in model space, degrees) around the bone's own pivot.
func _local_rot(b: int, deltas: Array) -> Quaternion:
	var rest_local := skel.get_bone_rest(b).basis.get_rotation_quaternion()
	var rest_global := skel.get_bone_global_rest(b).basis.orthonormalized()
	var d := Basis()
	for item in deltas:
		var axis_model: Vector3 = item[0]
		var deg: float = item[1]
		if absf(deg) < 0.0001:
			continue
		var axis_skel := (model_to_skel * axis_model).normalized()
		d = Basis(axis_skel, deg_to_rad(deg)) * d
	# conjugate the skeleton-space delta into the bone's global rest frame
	var local_delta := (rest_global.inverse() * d * rest_global).get_rotation_quaternion()
	return (rest_local * local_delta).normalized()

func _pitch(deg: float) -> Array:
	return [Vector3.RIGHT, deg]   # +deg: forward(+Z) end dips toward -Y

func _yaw(deg: float) -> Array:
	return [Vector3.UP, deg]

func _roll(deg: float) -> Array:
	return [Vector3.BACK, deg]

# keys: Array of [time, Array(deltas)]
func _rot_track(anim: Animation, bone_name: String, keys: Array) -> void:
	var b := _bone(bone_name)
	var t := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(t, NodePath("%s:%s" % [skel_path, bone_name]))
	anim.track_set_interpolation_type(t, Animation.INTERPOLATION_CUBIC)
	for k in keys:
		anim.rotation_track_insert_key(t, float(k[0]), _local_rot(b, k[1]))

func _pos_track(anim: Animation, bone_name: String, keys: Array) -> void:
	# keys: [time, model-space offset in model units]
	var b := _bone(bone_name)
	var t := anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(t, NodePath("%s:%s" % [skel_path, bone_name]))
	anim.track_set_interpolation_type(t, Animation.INTERPOLATION_CUBIC)
	var rest_pos := skel.get_bone_rest(b).origin
	var parent := skel.get_bone_parent(b)
	var parent_basis := skel.get_bone_global_rest(parent).basis if parent >= 0 else Basis()
	var xf: Transform3D = _rel_xf(skel.owner if skel.owner else skel.get_parent().get_parent(), skel)
	for k in keys:
		var off_model: Vector3 = k[1]
		# model units -> skeleton units (undo Armature scale/rotation) -> parent-local
		var off_skel: Vector3 = xf.basis.inverse() * off_model
		anim.position_track_insert_key(t, float(k[0]), rest_pos + parent_basis.inverse() * off_skel)

func _cycle(length: float, fn: Callable, steps: int = 8) -> Array:
	# sample a periodic function fn(phase 0..1) -> deltas into `steps` keys + closing key
	var keys := []
	for i in steps + 1:
		var ph := float(i) / steps
		keys.append([length * ph, fn.call(ph)])
	return keys

# ---- clips ---------------------------------------------------------------

func _idle() -> Animation:
	var a := Animation.new()
	a.length = 2.4
	a.loop_mode = Animation.LOOP_LINEAR
	var L := a.length
	_rot_track(a, "spine", _cycle(L, func(p): return [_pitch(1.6 * sin(TAU * p))]))
	_rot_track(a, "chest", _cycle(L, func(p): return [_pitch(-2.4 * sin(TAU * p)), _roll(1.2 * sin(TAU * p * 1.0 + 0.6))]))
	_rot_track(a, "neck", _cycle(L, func(p): return [_pitch(2.0 * sin(TAU * p + 0.5))]))
	_rot_track(a, "head", _cycle(L, func(p): return [_pitch(-3.0 * sin(TAU * p + 0.9)), _yaw(5.0 * sin(TAU * p * 1.0 + 1.7))]))
	for side in ["L", "R"]:
		var s := 1.0 if side == "L" else -1.0
		_rot_track(a, "front_leg_upper." + side, _cycle(L, func(p): return [_pitch(1.5 * sin(TAU * p) * s)]))
	_pos_track(a, "root", _cycle(L, func(p): return Vector3(0, -0.012 * (0.5 - 0.5 * cos(TAU * p)), 0)))
	return a

func _run() -> Animation:
	var a := Animation.new()
	a.length = 0.6
	a.loop_mode = Animation.LOOP_LINEAR
	var L := a.length
	# bounding gallop: front pair and hind pair alternate, slight L/R offset
	var swing := 22.0
	for side in ["L", "R"]:
		var off := 0.0 if side == "L" else 0.08
		_rot_track(a, "front_leg_upper." + side, _cycle(L, func(p): return [_pitch(-swing * sin(TAU * (p + off)))], 12))
		_rot_track(a, "front_leg_lower." + side, _cycle(L, func(p): return [_pitch(-18.0 * maxf(0.0, sin(TAU * (p + off) + 1.2)))], 12))
		_rot_track(a, "back_leg_upper." + side, _cycle(L, func(p): return [_pitch(swing * sin(TAU * (p + off)))], 12))
		_rot_track(a, "back_leg_lower." + side, _cycle(L, func(p): return [_pitch(20.0 * maxf(0.0, sin(TAU * (p + off) - 1.2)))], 12))
	_rot_track(a, "spine", _cycle(L, func(p): return [_pitch(6.0 * sin(TAU * p + 0.4))], 12))
	_rot_track(a, "chest", _cycle(L, func(p): return [_pitch(-5.0 * sin(TAU * p + 0.4))], 12))
	_rot_track(a, "head", _cycle(L, func(p): return [_pitch(-6.0 * sin(TAU * p + 1.0))], 12))
	_pos_track(a, "root", _cycle(L, func(p): return Vector3(0, 0.05 + 0.05 * absf(sin(TAU * p)), 0), 12))
	return a

func _attack() -> Animation:
	# 1.0 s; data: model_attack_sync_seek 0.2, model_attack_lock_time 0.45
	# -> wind-up 0..0.22, strike lands ~0.32, hold, recover by 0.9.
	var a := Animation.new()
	a.length = 1.0
	a.loop_mode = Animation.LOOP_NONE
	var k := func(t: float, d) -> Array: return [t, d]
	_rot_track(a, "chest", [k.call(0.0, []), k.call(0.22, [_pitch(-14.0)]), k.call(0.34, [_pitch(8.0)]), k.call(0.5, [_pitch(6.0)]), k.call(0.9, []), k.call(1.0, [])])
	_rot_track(a, "spine", [k.call(0.0, []), k.call(0.22, [_pitch(-6.0)]), k.call(0.34, [_pitch(8.0)]), k.call(0.5, [_pitch(6.0)]), k.call(0.9, []), k.call(1.0, [])])
	_rot_track(a, "neck", [k.call(0.0, []), k.call(0.22, [_pitch(-10.0)]), k.call(0.34, [_pitch(4.0)]), k.call(0.55, [_pitch(3.0)]), k.call(0.9, []), k.call(1.0, [])])
	_rot_track(a, "head", [k.call(0.0, []), k.call(0.22, [_pitch(-16.0)]), k.call(0.34, [_pitch(10.0), _roll(6.0)]), k.call(0.55, [_pitch(6.0)]), k.call(0.9, []), k.call(1.0, [])])
	# claw swipe: right fore-leg rakes forward-down, left braces
	_rot_track(a, "front_leg_upper.R", [k.call(0.0, []), k.call(0.22, [_pitch(30.0), _roll(-10.0)]), k.call(0.34, [_pitch(-26.0)]), k.call(0.55, [_pitch(-14.0)]), k.call(0.9, []), k.call(1.0, [])])
	_rot_track(a, "front_leg_lower.R", [k.call(0.0, []), k.call(0.22, [_pitch(-30.0)]), k.call(0.34, [_pitch(10.0)]), k.call(0.55, [_pitch(4.0)]), k.call(0.9, []), k.call(1.0, [])])
	_rot_track(a, "front_leg_upper.L", [k.call(0.0, []), k.call(0.22, [_pitch(-6.0)]), k.call(0.34, [_pitch(-12.0)]), k.call(0.9, []), k.call(1.0, [])])
	_rot_track(a, "back_leg_upper.L", [k.call(0.0, []), k.call(0.22, [_pitch(8.0)]), k.call(0.34, [_pitch(-10.0)]), k.call(0.9, []), k.call(1.0, [])])
	_rot_track(a, "back_leg_upper.R", [k.call(0.0, []), k.call(0.22, [_pitch(8.0)]), k.call(0.34, [_pitch(-10.0)]), k.call(0.9, []), k.call(1.0, [])])
	_pos_track(a, "root", [k.call(0.0, Vector3.ZERO), k.call(0.22, Vector3(0, -0.03, -0.05)), k.call(0.34, Vector3(0, 0.10, 0.16)), k.call(0.55, Vector3(0, 0.05, 0.10)), k.call(0.9, Vector3.ZERO), k.call(1.0, Vector3.ZERO)])
	return a
