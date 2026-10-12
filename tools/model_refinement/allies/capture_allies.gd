extends SceneTree
const SkinUtil := preload("res://tools/model_refinement/allies/skin_util.gd")
# Fixed-condition captures of formation-ally wrappers.
# Lighting = BattleArena rig (warm key 1.0/0.84/0.62 x1.55 at -55/35, ambient
# 0.34/0.42/0.34 x0.42). Battle view = BattleUI ortho camera (0,7.4,7) size 7.2,
# model scale = model_visual_scale * 0.42, feet centered like BattleRenderer.
#
# godot --path <proj> --rendering-method gl_compatibility --resolution 1600x720 \
#   --script res://tools/capture_allies.gd -- --out <dir> [--set old|new]
#   [--view battle|close|lineup] [--units 1,2,3]

const OLD := {
	1: "res://assets/models/allies/formation_ally_1_animated/formation_ally_1_animated.tscn",
	2: "res://assets/models/allies/formation_ally_2_animated/formation_ally_2_animated.tscn",
	3: "res://assets/models/allies/formation_ally_3_animated/formation_ally_3_animated.tscn",
	4: "res://assets/models/allies/formation_ally_4_animated/formation_ally_4_animated.tscn",
	5: "res://assets/models/allies/formation_ally_5_animated/formation_ally_5_animated.tscn",
}
const NEW := {
	1: "res://assets/models/allies_refined/ally_flame_claw/ally_flame_claw_refined.tscn",
	2: "res://assets/models/allies_refined/ally_soul_chain/ally_soul_chain_refined.tscn",
	3: "res://assets/models/allies_refined/ally_abyss_beast/ally_abyss_beast_refined.tscn",
	4: "res://assets/models/allies_refined/ally_hell_inferno/ally_hell_inferno_refined.tscn",
	5: "res://assets/models/allies_refined/ally_eternal_night/ally_eternal_night_refined.tscn",
}
const NAMES := {1: "flame_claw", 2: "soul_chain", 3: "abyss_beast", 4: "hell_inferno", 5: "eternal_night"}
const VISUAL_SCALE := {1: 3.0, 2: 3.0, 3: 3.0, 4: 4.0, 5: 3.0}
const BATTLE_SCALE := 0.42
const ACTIONS := ["idle", "run", "attack"]
var SAMPLE_FRACTIONS := [0.25, 0.6]
var ACTION_FILTER := []

var out_dir := "user://captures"
var set_name := "old"
var view := "close"
var units := [1, 2, 3, 4, 5]
var cam: Camera3D
var world: Node3D

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		match args[i]:
			"--out": out_dir = args[i + 1]
			"--set": set_name = args[i + 1]
			"--view": view = args[i + 1]
			"--fracs":
				SAMPLE_FRACTIONS = []
				for s in args[i + 1].split(","):
					SAMPLE_FRACTIONS.append(float(s))
			"--actions":
				ACTION_FILTER = Array(args[i + 1].split(","))
			"--units":
				units = []
				for s in args[i + 1].split(","):
					units.append(int(s))
	DirAccess.make_dir_recursive_absolute(out_dir)
	_build_world()
	await process_frame
	if view == "lineup":
		await _capture_lineup()
	else:
		for u in units:
			await _capture_unit(u)
	var f := FileAccess.open(out_dir.path_join("metrics_%s_%s.json" % [set_name, view]), FileAccess.WRITE)
	f.store_string(JSON.stringify(metrics, " "))
	f.close()
	print("CAPTURE_DONE ", out_dir)
	quit(0)

func _build_world() -> void:
	world = Node3D.new()
	get_root().add_child(world)
	var light := DirectionalLight3D.new()
	light.light_color = Color(1.0, 0.84, 0.62)
	light.light_energy = 1.55
	light.rotation_degrees = Vector3(-55, 35, 0)
	light.shadow_enabled = true
	world.add_child(light)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.30, 0.33, 0.30)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.34, 0.42, 0.34)
	env.ambient_light_energy = 0.42
	we.environment = env
	world.add_child(we)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.42, 0.45, 0.36)
	ground.material_override = gm
	world.add_child(ground)
	cam = Camera3D.new()
	world.add_child(cam)
	cam.current = true

func _spawn(u: int) -> Node3D:
	var path: String = NEW[u] if set_name == "new" else OLD[u]
	var scene := load(path) as PackedScene
	if scene == null:
		push_error("missing " + path)
		return null
	var holder := Node3D.new()
	world.add_child(holder)
	var model := scene.instantiate() as Node3D
	var s: float = VISUAL_SCALE[u] * BATTLE_SCALE
	model.scale = Vector3(s, s, s)
	holder.add_child(model)
	holder.rotation_degrees.y = 180.0  # model_base_yaw for player side
	return holder

func _model_of(holder: Node3D) -> Node3D:
	return holder.get_child(0) as Node3D

func _set_action(model: Node3D, action: String, frac: float) -> void:
	model.set_process(false)  # sample a frozen pose; the wrapper's _process would resume players
	match action:
		"idle": model.call("play_idle")
		"run": model.call("play_run")
		"attack": model.call("play_attack")
	var players: Dictionary = model.get("action_players")
	var p := players.get(action) as AnimationPlayer
	if p != null and p.current_animation != "":
		var anim := p.get_animation(p.current_animation)
		p.pause()
		p.seek(anim.length * frac, true)
	var proxy := model.get_node("AnimationPlayer") as AnimationPlayer
	proxy.pause()

func _renderer_bounds(root: Node3D) -> AABB:
	# Mirrors BattleArena/BattleRenderer._node3d_bounds: every MeshInstance3D
	# (hidden action models included), stored mesh AABB, node transforms only.
	var bounds := AABB()
	var has := false
	var stack: Array = [[root, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var node: Node = item[0]
		var xf: Transform3D = item[1]
		if node is MeshInstance3D:
			var b: AABB = xf * (node as MeshInstance3D).get_aabb()
			bounds = b if not has else bounds.merge(b)
			has = true
		for c in node.get_children():
			stack.append([c, xf * (c as Node3D).transform if c is Node3D else xf])
	return bounds

func _posed_bounds(node: Node3D, step: int = 5) -> AABB:
	return SkinUtil.posed_bounds(node, step)

var metrics := []

func _ground(holder: Node3D) -> void:
	# BattleRenderer._center_model_for_full_body_view runs before the actor enters
	# the tree, i.e. before the wrapper's _ready loads any action FBX, so it finds
	# no meshes and leaves the model at its native origin. Reproduce that.
	var m := _model_of(holder)
	m.position = Vector3.ZERO
	if true:
		return
	m.position = Vector3.ZERO
	var b := _renderer_bounds(m)
	var c := b.get_center()
	m.position -= m.transform.basis * Vector3(c.x, b.position.y, c.z)

func _capture_unit(u: int) -> void:
	var holder := _spawn(u)
	if holder == null:
		return
	await process_frame
	await process_frame
	var model := _model_of(holder)
	_set_action(model, "idle", 0.0)
	await process_frame
	_ground(holder)
	await process_frame
	var b0 := _posed_bounds(holder)
	var h := maxf(b0.end.y, 0.4)
	for action in ACTIONS:
		if not ACTION_FILTER.is_empty() and not ACTION_FILTER.has(action):
			continue
		for frac in SAMPLE_FRACTIONS:
			_set_action(model, action, frac)
			await process_frame
			await process_frame
			var pb := _posed_bounds(holder)
			metrics.append({"set": set_name, "unit": u, "action": action, "frac": frac,
				"foot_y": snappedf(pb.position.y, 0.001), "top_y": snappedf(pb.end.y, 0.001),
				"width": snappedf(maxf(pb.size.x, pb.size.z), 0.001), "empty": pb.size == Vector3.ZERO})
			if view == "battle":
				cam.projection = Camera3D.PROJECTION_ORTHOGONAL
				cam.size = 7.2 * 0.5
				cam.look_at_from_position(Vector3(0, 7.4, 7.0) * 0.5 + Vector3(0, h * 0.4, 0), Vector3(0, h * 0.4, 0), Vector3.UP)
				await _shot("%s_%d_%s_battle_%s_%02d" % [set_name, u, NAMES[u], action, int(frac * 100)])
			else:
				for dir in [["front", 0.0], ["side", 90.0], ["back", 180.0], ["top", -1.0]]:
					cam.projection = Camera3D.PROJECTION_PERSPECTIVE
					cam.fov = 35.0
					var dist := h * 2.0 + 0.4
					var target := Vector3(0, h * 0.5, 0)
					var pos: Vector3
					if dir[1] < 0.0:
						pos = target + Vector3(0, 7.4, 7.0).normalized() * dist  # own-side battle angle (sees back + top)
					else:
						var yaw := deg_to_rad(float(dir[1]))
						# model faces -Z after the 180 holder yaw, so "front" camera sits on -Z
						pos = target + Vector3(sin(yaw) * dist, h * 0.3, -cos(yaw) * dist)
					cam.look_at_from_position(pos, target, Vector3.UP)
					await _shot("%s_%d_%s_%s_%s_%02d" % [set_name, u, NAMES[u], dir[0], action, int(frac * 100)])
	holder.queue_free()
	await process_frame

func _capture_lineup() -> void:
	var holders := []
	var i := 0
	for u in units:
		var holder := _spawn(u)
		if holder == null:
			continue
		holder.position = Vector3((i - (units.size() - 1) * 0.5) * 1.6, 0, 0)
		holders.append([u, holder])
		i += 1
	await process_frame
	await process_frame
	for pair in holders:
		_set_action(_model_of(pair[1]), "idle", 0.0)
	await process_frame
	for pair in holders:
		_ground(pair[1])
	await process_frame
	for action in ACTIONS:
		for pair in holders:
			_set_action(_model_of(pair[1]), action, 0.4)
		await process_frame
		await process_frame
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = 5.0
		cam.look_at_from_position(Vector3(0, 7.4, 7.0) + Vector3(0, 0.5, 0), Vector3(0, 0.5, 0), Vector3.UP)
		await _shot("%s_lineup_ownside_%s" % [set_name, action])
		# enemy view: camera in front of the units (they face -Z)
		cam.look_at_from_position(Vector3(0, 7.4, -7.0) + Vector3(0, 0.5, 0), Vector3(0, 0.5, 0), Vector3.UP)
		await _shot("%s_lineup_enemyside_%s" % [set_name, action])

func _shot(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var img := get_root().get_texture().get_image()
	img.save_png(out_dir.path_join(name + ".png"))
