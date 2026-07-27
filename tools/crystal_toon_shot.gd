extends Node

# Renders the two battle crystals through the real BattleArena spawn path so the
# cel-shading pass can be eyeballed without launching a match. When a "before"
# shader is present at BEFORE_SHADER_PATH it also renders a comparison shot with
# the outline pass stripped, which is how the style change was reviewed.
# Run with a real window (not --headless), the capture needs a rendering device.

const BattleArenaScript := preload("res://scenes/battle/BattleArena.gd")

const OUTPUT_DIR := "C:/Users/Leno/AppData/Local/Temp/claude/C--Users-Leno-Desktop-Beta-0-04/7de75bf1-25b7-4c1d-a073-d44547060368/scratchpad/crystal_shots"
const BEFORE_SHADER_PATH := "res://shaders/battle_crystal_toon_before.gdshader"
const SHOT_SIZE := Vector2i(900, 700)

var viewport: SubViewport
var camera: Camera3D
var stage: Node3D
var arena: Control

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
	_build_stage()
	arena = BattleArenaScript.new()
	# _spawn_demo_crystal 挂在 _battle_3d_world 下、固定落在场地中心，所以借用 stage
	# 当世界根，再把两座水晶左右分开摆好取景。
	arena._battle_3d_world = stage
	var blue: Node3D = arena._spawn_demo_crystal(GameConstants.TEAM_BLUE, 1.0)
	if blue != null:
		blue.position += Vector3(-1.15, 0.0, 0.0)
	var red: Node3D = arena._spawn_demo_crystal(GameConstants.TEAM_RED, 1.0)
	if red != null:
		red.position += Vector3(1.15, 0.0, 0.0)
	for _i in 5:
		await get_tree().process_frame
	_frame_camera(_node3d_bounds(stage))

	await _capture("%s/crystals_after.png" % OUTPUT_DIR)
	if ResourceLoader.exists(BEFORE_SHADER_PATH):
		_apply_before_look()
		await _capture("%s/crystals_before.png" % OUTPUT_DIR)
	print("CRYSTAL_SHOTS_DONE dir=%s" % OUTPUT_DIR)
	get_tree().quit()

func _build_stage() -> void:
	viewport = SubViewport.new()
	viewport.size = SHOT_SIZE
	viewport.own_world_3d = true
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

# Restores the pre-change look: original toon shader, no outline pass.
func _apply_before_look() -> void:
	var before_shader := load(BEFORE_SHADER_PATH) as Shader
	for found in stage.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := found as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		for surface_index in mesh_instance.mesh.get_surface_count():
			var current := mesh_instance.mesh.surface_get_material(surface_index) as ShaderMaterial
			if current == null:
				continue
			current.shader = before_shader
			current.set_shader_parameter("texture_influence", 0.22)
			current.next_pass = null

func _frame_camera(bounds: AABB) -> void:
	var center := bounds.position + bounds.size * 0.5
	var span := maxf(bounds.size.y, maxf(bounds.size.x, bounds.size.z)) * 1.25
	var distance := span * 1.75 + 0.6
	var offset := Vector3(
		sin(deg_to_rad(18.0)) * cos(deg_to_rad(10.0)),
		sin(deg_to_rad(10.0)),
		cos(deg_to_rad(18.0)) * cos(deg_to_rad(10.0))) * distance
	camera.look_at_from_position(center + offset, center, Vector3.UP)

func _capture(file_path: String) -> void:
	for _i in 3:
		await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(file_path)

func _node3d_bounds(root: Node3D) -> AABB:
	var bounds := AABB()
	var has_bounds := false
	for found in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := found as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var mesh_aabb := mesh_instance.global_transform * mesh_instance.mesh.get_aabb()
		if has_bounds:
			bounds = bounds.merge(mesh_aabb)
		else:
			bounds = mesh_aabb
			has_bounds = true
	return bounds
