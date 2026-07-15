extends "res://scenes/battle/BattleUI.gd"

var _3v3_lines: Array[ColorRect] = []

func _build() -> void:
	var screen_bg := ColorRect.new()
	screen_bg.color = Color(0.018, 0.026, 0.022)
	screen_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(screen_bg)
	screen_bg.z_index = -20

	# Arena fills the entire screen (full-screen battlefield).
	var arena_wrap := Control.new()
	arena_wrap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	arena_wrap.clip_contents = true
	add_child(arena_wrap)

	var arena_bg := TextureRect.new()
	arena_bg.texture = _load_battle_background()
	arena_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	arena_bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	arena_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	arena_wrap.add_child(arena_bg)
	arena_bg.z_index = -20
	arena_bg.visible = not BATTLE_USE_3D_ARENA

	var arena_tint := ColorRect.new()
	arena_tint.color = Color(0.012, 0.030, 0.022, 0.22)
	arena_tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	arena_wrap.add_child(arena_tint)
	arena_tint.z_index = -10

	_add_battle_grid_overlay(arena_wrap)

	_setup_battle_3d_view(arena_wrap)
	_arena = arena_wrap
	_add_battle_3v3_dividers(arena_wrap)
	_add_result_overlay(arena_wrap)

	# Title / state / summary kept alive (other code updates their text) but hidden.
	_title_lbl = Label.new()
	_title_lbl.visible = false
	add_child(_title_lbl)

	_battle_state_lbl = Label.new()
	_battle_state_lbl.visible = false
	add_child(_battle_state_lbl)

	_summary_lbl = RichTextLabel.new()
	_summary_lbl.bbcode_enabled = true
	_summary_lbl.fit_content = true
	_summary_lbl.visible = false
	add_child(_summary_lbl)

	# Floating skip button (top-right corner, above the full-screen arena).
	var skip := Button.new()
	skip.text = "跳过画面"
	skip.custom_minimum_size = Vector2(120, 36)
	skip.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	skip.offset_left = -136
	skip.offset_top = 12
	skip.offset_right = -16
	skip.offset_bottom = 48
	skip.pressed.connect(_skip_animation)
	add_child(skip)
	skip.z_index = 100

	if GameState.team_mode:
		var team_hp_lbl := Label.new()
		team_hp_lbl.text = "团队法阵 HP  %d / %d" % [GameState.team_hp, GameState.START_FORMATION_HP]
		team_hp_lbl.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
		team_hp_lbl.offset_left = -150
		team_hp_lbl.offset_right = 150
		team_hp_lbl.offset_top = 10
		team_hp_lbl.offset_bottom = 42
		team_hp_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		team_hp_lbl.add_theme_font_size_override("font_size", 22)
		team_hp_lbl.add_theme_color_override("font_color", Color(0.5, 1.0, 0.62))
		team_hp_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		team_hp_lbl.add_theme_constant_override("outline_size", 4)
		team_hp_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		team_hp_lbl.z_index = 100
		add_child(team_hp_lbl)

const BATTLE_3V3_BOUNDS := [0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0]

func _add_battle_3v3_dividers(arena_wrap: Control) -> void:
	# Four straight vertical lines: the 2 outer ones mark the standable edges,
	# the 2 inner ones split the standable field into 3 equal columns (3v3 prep).
	# Positioned dynamically in _update_3v3_dividers so they only span the
	# playable area (not the forest border / circles).
	_3v3_lines.clear()
	for i in BATTLE_3V3_BOUNDS.size():
		var is_edge := i == 0 or i == BATTLE_3V3_BOUNDS.size() - 1
		var line := ColorRect.new()
		line.color = Color(1.0, 0.85, 0.4, 0.30) if is_edge else Color(1.0, 1.0, 1.0, 0.34)
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.z_index = 40
		arena_wrap.add_child(line)
		_3v3_lines.append(line)

func _update_3v3_dividers() -> void:
	if _3v3_lines.is_empty() or _arena == null or _battle_3d_camera == null:
		return
	var x0 := BATTLE_VISUAL_MIN.x
	var x1 := BATTLE_VISUAL_MAX.x
	for i in _3v3_lines.size():
		var sx := lerpf(x0, x1, BATTLE_3V3_BOUNDS[i])
		var p_top := _world_to_arena(_sim_to_world_pos(Vector2(sx, BATTLE_VISUAL_MIN.y)))
		var p_bot := _world_to_arena(_sim_to_world_pos(Vector2(sx, BATTLE_VISUAL_MAX.y)))
		var top_y := minf(p_top.y, p_bot.y)
		var bot_y := maxf(p_top.y, p_bot.y)
		var mid_x := (p_top.x + p_bot.x) * 0.5
		var line: ColorRect = _3v3_lines[i]
		line.position = Vector2(mid_x - 2.0, top_y)
		line.size = Vector2(4.0, bot_y - top_y)

func _add_result_overlay(arena_wrap: Control) -> void:
	_result_overlay_lbl = Label.new()
	_result_overlay_lbl.visible = false
	_result_overlay_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_result_overlay_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_overlay_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_result_overlay_lbl.add_theme_font_size_override("font_size", 58)
	_result_overlay_lbl.add_theme_color_override("font_color", Color(1.0, 0.94, 0.62))
	_result_overlay_lbl.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	_result_overlay_lbl.add_theme_constant_override("shadow_offset_x", 3)
	_result_overlay_lbl.add_theme_constant_override("shadow_offset_y", 3)
	_result_overlay_lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_result_overlay_lbl.z_index = 200
	arena_wrap.add_child(_result_overlay_lbl)

func _add_battle_grid_overlay(arena_wrap: Control) -> void:
	# Placement remains grid-based, but the combat arena no longer draws debug lines.
	pass

func _add_battle_3d_arena(world: Node3D) -> void:
	if not BATTLE_USE_3D_ARENA:
		return
	var scene := load(BATTLE_ARENA_MODEL_PATH)
	if scene == null or not (scene is PackedScene):
		push_warning("战斗 3D 场景模型加载失败：%s" % BATTLE_ARENA_MODEL_PATH)
		return
	var arena: Node3D = (scene as PackedScene).instantiate()
	arena.name = "BattleArenaBoard"
	arena.rotation_degrees.y = BATTLE_ARENA_YAW
	world.add_child(arena)
	_fit_battle_3d_arena(arena)
	_apply_forest_arena_style(arena)

func _apply_forest_arena_style(root: Node3D) -> void:
	if not BATTLE_ARENA_FOREST_TINT:
		return
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			var mesh_instance := node as MeshInstance3D
			var mesh := mesh_instance.mesh
			if mesh != null:
				for surface in mesh.get_surface_count():
					var source_mat := mesh_instance.get_surface_override_material(surface)
					if source_mat == null:
						source_mat = mesh.surface_get_material(surface)
					var forest_mat := _forest_material_variant(source_mat)
					if forest_mat != null:
						mesh_instance.set_surface_override_material(surface, forest_mat)
		for child in node.get_children():
			stack.append(child)

func _forest_material_variant(source_mat: Material) -> Material:
	if source_mat == null or not (source_mat is BaseMaterial3D):
		return null
	var src := source_mat as BaseMaterial3D
	var mat := StandardMaterial3D.new()
	var toon_texture := load(BATTLE_ARENA_TOON_TEXTURE_PATH)
	if toon_texture is Texture2D:
		mat.albedo_texture = toon_texture
		mat.albedo_color = Color(1, 1, 1)
	else:
		mat.albedo_texture = src.albedo_texture
		mat.albedo_color = src.albedo_color.lerp(BATTLE_ARENA_FOREST_ALBEDO, BATTLE_ARENA_FOREST_BLEND)
	mat.diffuse_mode = 3
	mat.specular_mode = 1
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.transparency = src.transparency
	return mat
func _fit_battle_3d_arena(arena: Node3D) -> void:
	var bounds := _node3d_bounds(arena)
	if bounds.size == Vector3.ZERO:
		return
	var scale_x := BATTLE_ARENA_TARGET_WIDTH / maxf(bounds.size.x, 0.01)
	var scale_z := BATTLE_ARENA_TARGET_DEPTH / maxf(bounds.size.z, 0.01)
	var scale_factor := minf(scale_x, scale_z)
	arena.scale = Vector3.ONE * scale_factor
	var fitted_bounds := _node3d_bounds(arena)
	var center := fitted_bounds.get_center()
	arena.position += Vector3(-center.x, BATTLE_ARENA_GROUND_Y - fitted_bounds.position.y, -center.z)

func _setup_battle_3d_view(arena_wrap: Control) -> void:
	var container := SubViewportContainer.new()
	container.name = "Battle3DLayer"
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.z_index = -5
	arena_wrap.add_child(container)

	_battle_3d_viewport = SubViewport.new()
	_battle_3d_viewport.size = Vector2i(1280, 720)
	_battle_3d_viewport.transparent_bg = true
	_battle_3d_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(_battle_3d_viewport)

	var world := Node3D.new()
	_battle_3d_viewport.add_child(world)
	_add_battle_3d_arena(world)
	_battle_3d_root = Node3D.new()
	_battle_3d_root.name = "BattleModelRoot"
	world.add_child(_battle_3d_root)

	var light := DirectionalLight3D.new()
	light.light_color = Color(1.0, 0.84, 0.62)
	light.light_energy = 1.55
	light.rotation_degrees = Vector3(-55, 35, 0)
	world.add_child(light)
	var ambient := WorldEnvironment.new()
	var env := Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.34, 0.42, 0.34)
	env.ambient_light_energy = 0.42
	ambient.environment = env
	world.add_child(ambient)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = BATTLE_CAMERA_SIZE
	camera.look_at_from_position(BATTLE_CAMERA_POS, Vector3(0.0, 0.0, 0.0), Vector3.UP)
	camera.current = true
	_battle_3d_camera = camera
	_battle_3d_viewport.add_child(camera)

func _load_battle_background() -> Texture2D:
	var texture := load(BATTLE_BG_PATH)
	if texture is Texture2D:
		return texture
	var image := Image.new()
	if image.load(BATTLE_BG_PATH) == OK:
		return ImageTexture.create_from_image(image)
	push_warning("战斗背景加载失败：%s" % BATTLE_BG_PATH)
	return null

func _world_to_arena(world_pos: Vector3) -> Vector2:
	if _battle_3d_camera == null or _battle_3d_viewport == null or _arena == null:
		return Vector2.ZERO
	var viewport_pos := _battle_3d_camera.unproject_position(world_pos)
	var viewport_size := Vector2(_battle_3d_viewport.size)
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return viewport_pos
	var arena_size := _arena.size
	if arena_size.x <= 0.0 or arena_size.y <= 0.0:
		arena_size = viewport_size
	return Vector2(
		viewport_pos.x / viewport_size.x * arena_size.x,
		viewport_pos.y / viewport_size.y * arena_size.y
	)

func _sim_to_arena(sim_pos: Vector2) -> Vector2:
	sim_pos = _clamp_visual_sim_pos(sim_pos)
	# Map simulator coordinate space (SIM_W x SIM_H) to actual arena pixel size
	var arena_size := _arena.size
	if arena_size.x <= 0 or arena_size.y <= 0:
		arena_size = Vector2(SIM_W, SIM_H)
	return Vector2(
		sim_pos.x / SIM_W * arena_size.x,
		sim_pos.y / SIM_H * arena_size.y
	)

func _clamp_visual_sim_pos(sim_pos: Vector2) -> Vector2:
	return Vector2(
		clampf(sim_pos.x, BATTLE_VISUAL_MIN.x, BATTLE_VISUAL_MAX.x),
		clampf(sim_pos.y, BATTLE_VISUAL_MIN.y, BATTLE_VISUAL_MAX.y)
	)

func _sim_to_world_pos(sim_pos: Vector2) -> Vector3:
	sim_pos = _clamp_visual_sim_pos(sim_pos)
	var x := (sim_pos.x / SIM_W - 0.5) * BATTLE_PLAYABLE_WIDTH + BATTLE_PLAYABLE_OFFSET.x
	var z := (sim_pos.y / SIM_H - 0.5) * BATTLE_PLAYABLE_DEPTH + BATTLE_PLAYABLE_OFFSET.z
	return Vector3(x, 0.0, z)

func _node3d_bounds(root: Node3D) -> AABB:
	var bounds := AABB()
	var has_bounds := false
	var stack: Array[Dictionary] = [{"node": root, "transform": Transform3D.IDENTITY}]
	while not stack.is_empty():
		var item: Dictionary = stack.pop_back()
		var node: Node = item.get("node")
		var node_transform: Transform3D = item.get("transform", Transform3D.IDENTITY)
		if node is MeshInstance3D:
			var mesh_node := node as MeshInstance3D
			var mesh_bounds := _transformed_aabb(mesh_node.get_aabb(), node_transform)
			if not has_bounds:
				bounds = mesh_bounds
				has_bounds = true
			else:
				bounds = bounds.merge(mesh_bounds)
		for child in node.get_children():
			var child_transform := node_transform
			if child is Node3D:
				child_transform = node_transform * (child as Node3D).transform
			stack.append({"node": child, "transform": child_transform})
	return bounds if has_bounds else AABB()

func _transformed_aabb(box: AABB, transform: Transform3D) -> AABB:
	if box.size == Vector3.ZERO:
		return box
	var corners := [
		box.position,
		box.position + Vector3(box.size.x, 0, 0),
		box.position + Vector3(0, box.size.y, 0),
		box.position + Vector3(0, 0, box.size.z),
		box.position + Vector3(box.size.x, box.size.y, 0),
		box.position + Vector3(box.size.x, 0, box.size.z),
		box.position + Vector3(0, box.size.y, box.size.z),
		box.position + box.size,
	]
	var out := AABB(transform * corners[0], Vector3.ZERO)
	for i in range(1, corners.size()):
		out = out.expand(transform * corners[i])
	return out



