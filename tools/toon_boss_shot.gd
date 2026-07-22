extends Node

# Renders every boss model twice — once with whatever material it currently has
# (the cel shader) and once with an equivalent StandardMaterial3D rebuilt from the
# same textures — so the two looks can be compared side by side.
# Uses the battle arena light rig, since that is where bosses actually show up.
# Run with a real window (not --headless), the capture needs a rendering device.

const OUTPUT_DIR := "C:/Users/Leno/AppData/Local/Temp/claude/C--Users-Leno-Desktop-Beta-0-04/eb0f58d6-75cc-4cea-8444-c8d77c710d9f/scratchpad/boss_toon_shots"

const SHOT_SIZE := Vector2i(560, 700)

# Folders under res://assets/models to sweep for *_animated.tscn. Override with
# --shot-groups=allies,monsters on the command line.
const DEFAULT_GROUPS := ["bosses"]

var viewport: SubViewport
var camera: Camera3D
var stage: Node3D

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
	_build_stage()
	for scene_path in _collect_scenes(_requested_groups()):
		await _shoot(scene_path.get_file().get_basename(), scene_path)
	print("TOON_SHOTS_DONE dir=%s" % OUTPUT_DIR)
	get_tree().quit()

func _requested_groups() -> PackedStringArray:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--shot-groups="):
			return argument.split("=", true, 1)[1].split(",", false)
	return PackedStringArray(DEFAULT_GROUPS)

func _collect_scenes(groups: PackedStringArray) -> PackedStringArray:
	var found := PackedStringArray()
	for group in groups:
		var stack: Array[String] = ["res://assets/models/%s" % group]
		while not stack.is_empty():
			var dir_path: String = stack.pop_back()
			var dir := DirAccess.open(dir_path)
			if dir == null:
				push_warning("Cannot open %s" % dir_path)
				continue
			for name in dir.get_directories():
				stack.append("%s/%s" % [dir_path, name])
			for name in dir.get_files():
				if name.ends_with("_animated.tscn"):
					found.append("%s/%s" % [dir_path, name])
	found.sort()
	return found

func _build_stage() -> void:
	viewport = SubViewport.new()
	viewport.size = SHOT_SIZE
	viewport.own_world_3d = true
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	add_child(viewport)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.07, 0.08, 0.10)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.34, 0.42, 0.34)
	env.ambient_light_energy = 0.42
	env_node.environment = env
	viewport.add_child(env_node)

	# Same key light as BattleArena.
	var light := DirectionalLight3D.new()
	light.light_color = Color(1.0, 0.84, 0.62)
	light.light_energy = 1.55
	light.rotation_degrees = Vector3(-55.0, 35.0, 0.0)
	viewport.add_child(light)

	camera = Camera3D.new()
	camera.fov = 39.0
	camera.current = true
	viewport.add_child(camera)

	stage = Node3D.new()
	viewport.add_child(stage)

func _shoot(id: String, path: String) -> void:
	var scene := load(path) as PackedScene
	if scene == null:
		print("MISSING %s" % path)
		return
	var model := scene.instantiate() as Node3D
	if model == null:
		print("NOT_NODE3D %s" % path)
		return
	model.set_meta("load_idle_only", true)
	stage.add_child(model)
	# Skinned meshes only report a usable AABB once the idle pose has been applied.
	for _i in 30:
		await get_tree().process_frame

	var bounds := _node3d_bounds(model)
	if bounds.size.length() <= 0.001:
		print("NO_MESH %s" % id)
		model.queue_free()
		return
	_frame_camera(bounds)

	await _capture("%s/%s_toon.png" % [OUTPUT_DIR, id])

	var restore := _swap_to_standard(model)
	await _capture("%s/%s_pbr.png" % [OUTPUT_DIR, id])
	_restore_materials(restore)

	print("SHOT %s height=%.2f" % [id, bounds.size.y])
	model.queue_free()
	await get_tree().process_frame

func _frame_camera(bounds: AABB) -> void:
	# Bone bounds sit inside the silhouette, so pad for armor, wings and weapons.
	var center := bounds.position + bounds.size * 0.5
	var span := maxf(bounds.size.y, maxf(bounds.size.x, bounds.size.z)) * 1.45
	var distance := span * 1.75 + 0.6
	var yaw := deg_to_rad(28.0)
	var pitch := deg_to_rad(14.0)
	var offset := Vector3(
		sin(yaw) * cos(pitch),
		sin(pitch),
		cos(yaw) * cos(pitch)) * distance
	camera.look_at_from_position(center + offset, center, Vector3.UP)

func _capture(file_path: String) -> void:
	for _i in 3:
		await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.save_png(file_path)

# Rebuilds a StandardMaterial3D from the cel material's own parameters so the
# comparison uses identical textures, then hands back what was replaced.
func _swap_to_standard(root: Node) -> Array:
	var restore: Array = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not (node is MeshInstance3D):
			continue
		var mesh_instance := node as MeshInstance3D
		var surface_count := 1
		if mesh_instance.mesh != null:
			surface_count = maxi(1, mesh_instance.mesh.get_surface_count())
		for i in range(surface_count):
			var current := mesh_instance.get_surface_override_material(i)
			var shader_material := current as ShaderMaterial
			if shader_material == null:
				continue
			restore.append({"node": mesh_instance, "surface": i, "material": current})
			mesh_instance.set_surface_override_material(i, _standard_from_cel(shader_material))
	return restore

func _standard_from_cel(source: ShaderMaterial) -> StandardMaterial3D:
	var standard := StandardMaterial3D.new()
	# Matches what the boss materials used before the swap: diffuse_mode 3, specular_mode 1.
	standard.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	standard.specular_mode = BaseMaterial3D.SPECULAR_TOON
	standard.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	standard.albedo_texture = source.get_shader_parameter("albedo_texture") as Texture2D
	standard.metallic = 0.0
	standard.roughness = 0.6
	var normal_texture := source.get_shader_parameter("normal_map_texture") as Texture2D
	if normal_texture != null:
		standard.normal_enabled = true
		standard.normal_texture = normal_texture
		standard.normal_scale = float(source.get_shader_parameter("normal_map_depth"))
	standard.next_pass = source.next_pass
	return standard

func _restore_materials(restore: Array) -> void:
	for entry in restore:
		var mesh_instance := (entry as Dictionary).get("node") as MeshInstance3D
		if mesh_instance == null:
			continue
		mesh_instance.set_surface_override_material(
			int((entry as Dictionary).get("surface", 0)),
			(entry as Dictionary).get("material") as Material)

func _node3d_bounds(root_node: Node3D) -> AABB:
	var bounds := AABB()
	var has_bounds := false
	var stack: Array[Node] = [root_node]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		# Skinned meshes keep reporting their bind-pose AABB, which for these FBX
		# rigs is the character lying down. Bone positions follow the actual idle
		# pose, so they are what the framing is built from.
		if node is Skeleton3D:
			var skeleton := node as Skeleton3D
			if not skeleton.is_visible_in_tree():
				continue
			for bone in range(skeleton.get_bone_count()):
				var point: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin
				if not has_bounds:
					bounds = AABB(point, Vector3.ZERO)
					has_bounds = true
				else:
					bounds = bounds.expand(point)
		elif node is MeshInstance3D:
			var mesh_node := node as MeshInstance3D
			if mesh_node.mesh == null or not mesh_node.is_visible_in_tree() or mesh_node.skeleton != NodePath(""):
				continue
			var mesh_bounds := _transformed_aabb(mesh_node.get_aabb(), mesh_node.global_transform)
			if not has_bounds:
				bounds = mesh_bounds
				has_bounds = true
			else:
				bounds = bounds.merge(mesh_bounds)
	return bounds if has_bounds else AABB()

func _transformed_aabb(box: AABB, transform: Transform3D) -> AABB:
	var p := box.position
	var s := box.size
	var corners := [
		p,
		p + Vector3(s.x, 0.0, 0.0),
		p + Vector3(0.0, s.y, 0.0),
		p + Vector3(0.0, 0.0, s.z),
		p + Vector3(s.x, s.y, 0.0),
		p + Vector3(s.x, 0.0, s.z),
		p + Vector3(0.0, s.y, s.z),
		p + s,
	]
	var out := AABB(transform * corners[0], Vector3.ZERO)
	for i in range(1, corners.size()):
		out = out.expand(transform * corners[i])
	return out
