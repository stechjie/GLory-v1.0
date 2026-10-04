extends Node
## Isolated visual review. Does not alter combat routing or model resources.

const DEFAULT_MODEL := "res://assets/models/units/crimson_race/crimson.glb"
const RESOLUTION := Vector2i(1024, 1024)

var viewport: SubViewport
var camera: Camera3D
var actor: Node3D
var player: AnimationPlayer
var center := Vector3.ZERO
var height := 1.0
var width := 1.0
var capture_dir := ""
var model_path := DEFAULT_MODEL
var unit_id := "crimson"
var focus := "full"


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="):
			capture_dir = arg.trim_prefix("--capture-dir=")
		elif arg.begins_with("--model="):
			model_path = arg.trim_prefix("--model=")
		elif arg.begins_with("--unit="):
			unit_id = arg.trim_prefix("--unit=")
		elif arg.begins_with("--focus="):
			focus = arg.trim_prefix("--focus=")
	if capture_dir.is_empty() or not model_path.begins_with("res://"):
		_fail("capture-dir and res:// model are required")
		return
	if DisplayServer.get_name() == "headless":
		_fail("graphics display required")
		return
	if DirAccess.make_dir_recursive_absolute(capture_dir) != OK:
		_fail("cannot create capture directory")
		return
	var scene := load(model_path) as PackedScene
	if scene == null:
		_fail("cannot load " + model_path)
		return
	viewport = SubViewport.new()
	viewport.size = RESOLUTION
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	add_child(viewport)
	var world := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.17, 0.19)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.46, 0.49, 0.55)
	env.ambient_light_energy = 0.55
	world.environment = env
	viewport.add_child(world)
	_add_light(Color(1.0, 0.85, 0.73), 1.3, Vector3(-45, 35, 0))
	_add_light(Color(0.65, 0.74, 0.9), 0.65, Vector3(-30, -70, 0))
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.01
	camera.far = 200.0
	camera.current = true
	viewport.add_child(camera)
	actor = scene.instantiate() as Node3D
	if actor == null:
		_fail("model root is not Node3D")
		return
	actor.scale = Vector3.ONE * (1.09 if unit_id == "crimson" else 1.0)
	viewport.add_child(actor)
	player = _find_player(actor)
	var bounds := _find_bounds(actor)
	center = bounds.get_center()
	height = maxf(bounds.size.y, 0.01)
	width = maxf(bounds.size.x, bounds.size.z)
	# Some imported skinned meshes report bind-pose/root-scale bounds that do
	# not enclose the rendered animation. Use the authored GLB accessor extents
	# for these Crimson assets; this changes review framing only.
	match unit_id:
		"dancer":
			center = Vector3(0, 0.96, 0)
			height = 1.96
			width = 1.63
		"Icey":
			center = Vector3(0, 0.95, 0)
			height = 1.90
			width = 1.76
		"lattern":
			center = Vector3(0, 1.33, 0)
			height = 2.68
			width = 1.82
		"hunter":
			center.x = 0.0
			width = 2.3
	if unit_id == "crimson" and focus == "head":
		center = Vector3(0.0, 1.69, 0.0)
		height = 0.76
		width = 0.76
	print("CRIMSON_PILOT unit=%s model=%s bounds=%s animations=%s" % [unit_id, model_path, str(bounds), str(player.get_animation_list() if player != null else [])])
	for action in ["idle", "run", "attack"]:
		if player == null or not player.has_animation(action):
			_fail("missing animation " + action)
			return
		player.play(action)
		var pose_seconds := 0.45 if action != "attack" else 0.25
		player.advance(pose_seconds)
		player.pause()
		for view in ["front", "side", "back", "battle"]:
			_set_camera(view)
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var path := capture_dir.path_join("%s_%s_%s.png" % [unit_id, action, view])
			var error := viewport.get_texture().get_image().save_png(path)
			if error != OK:
				_fail("save failed " + path)
				return
			print("CRIMSON_CAPTURE path=%s pose_seconds=%.2f model=%s" % [path, pose_seconds, model_path])
	get_tree().quit(0)


func _add_light(color: Color, energy: float, rotation: Vector3) -> void:
	var light := DirectionalLight3D.new()
	light.light_color = color
	light.light_energy = energy
	light.rotation_degrees = rotation
	viewport.add_child(light)


func _find_player(root: Node) -> AnimationPlayer:
	if root is AnimationPlayer:
		return root as AnimationPlayer
	for child in root.get_children():
		var found := _find_player(child)
		if found != null:
			return found
	return null


func _find_bounds(root: Node3D) -> AABB:
	var points: Array[Vector3] = []
	_collect_points(root, points)
	if points.is_empty():
		return AABB(Vector3(-0.5, 0, -0.5), Vector3.ONE)
	var lo := points[0]
	var hi := points[0]
	for point in points:
		lo = lo.min(point)
		hi = hi.max(point)
	return AABB(lo, hi - lo)


func _collect_points(root: Node, points: Array[Vector3]) -> void:
	if root is MeshInstance3D:
		var mesh_node := root as MeshInstance3D
		if mesh_node.mesh != null:
			var box := mesh_node.mesh.get_aabb()
			for x in [box.position.x, box.end.x]:
				for y in [box.position.y, box.end.y]:
					for z in [box.position.z, box.end.z]:
						points.append(mesh_node.global_transform * Vector3(x, y, z))
	for child in root.get_children():
		_collect_points(child, points)


func _set_camera(view: String) -> void:
	var span := maxf(height * 1.2, width * 1.4)
	if view == "battle":
		span *= 4.5
	camera.size = span
	var direction := Vector3(0, 0, 1)
	match view:
		"side": direction = Vector3(1, 0, 0)
		"back": direction = Vector3(0, 0, -1)
		"battle": direction = Vector3(1.0, 0.75, 1.5).normalized()
	camera.position = center + direction * maxf(span * 1.6, 2.0)
	camera.look_at(center)


func _fail(message: String) -> void:
	push_error("CRIMSON_PILOT " + message)
	get_tree().quit(2)
