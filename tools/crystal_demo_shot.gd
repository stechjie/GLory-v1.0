extends Node

# 驱动真实的 BattleArena._play_crystal_attack_sequence，按时间轴连续截帧，用来肉眼
# 检查召唤/光带/收场这段编排。搭的是和 BattleArena._build() 同款的 3D 世界与相机。
# Run with a real window (not --headless), the capture needs a rendering device.

const BattleArenaScript := preload("res://scenes/battle/BattleResult.gd")

const OUTPUT_DIR := "C:/Users/Leno/AppData/Local/Temp/claude/C--Users-Leno-Desktop-Beta-0-04/7de75bf1-25b7-4c1d-a073-d44547060368/scratchpad/crystal_shots"
const SHOT_SIZE := Vector2i(640, 480)
# 覆盖召唤(0~0.85)、光带(0.85~1.7)、掉血(~2.0)、收场(~2.4) 的采样点
# 总时长 ≈ 0.22 起手 + 0.62 升起 + 0.18 + 2.0 齐射预算 + 0.73 收尾飞行 + 收场
const SHOT_TIMES := [1.00, 1.45, 1.95, 2.35, 2.75, 3.05, 3.45, 3.90]

var arena: Control
var viewport: SubViewport

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
	arena = BattleArenaScript.new()
	add_child(arena)
	_build_world()
	_seed_battle_state()

	GameState.round_index = 5
	NetworkService.team_local_slot = 0
	var result := {"kind": "pvp", "player_wins": true, "player_alive": 3, "enemy_alive": 0}
	print("losing_team=%d (期望 1 = 蓝队)" % int(arena._crystal_demo_losing_team(result)))
	# 不 await：序列在后台跑，这边按时间轴截帧。
	arena._play_crystal_attack_sequence(result)

	var elapsed := 0.0
	for i in SHOT_TIMES.size():
		var wait: float = float(SHOT_TIMES[i]) - elapsed
		if wait > 0.0:
			await get_tree().create_timer(wait).timeout
		elapsed = float(SHOT_TIMES[i])
		await _capture("%s/demo_%d_%03dms.png" % [OUTPUT_DIR, i, int(elapsed * 1000.0)])
		var ribbons := 0
		var units := 0
		for child in (arena._battle_3d_world as Node3D).get_children():
			if child.name.begins_with("CrystalRibbon"):
				ribbons += 1
		units = (arena._battle_3d_models as Dictionary).size()
		var hp_text := "-"
		if arena._crystal_hp_label != null and is_instance_valid(arena._crystal_hp_label):
			hp_text = str((arena._crystal_hp_label as Label).text)
		print("t=%.2fs 水晶=%s 飘带=%d 棋子剩余=%d 血条=%s" % [
			elapsed, str(arena._demo_crystal != null), ribbons, units, hp_text])
	print("CRYSTAL_DEMO_SHOTS_DONE dir=%s" % OUTPUT_DIR)
	get_tree().quit()

func _build_world() -> void:
	# 和真机同样的层次：3D 世界在 SubViewport 里，血量是叠在上面的 2D 控件。
	# 截的是整个窗口而不是 SubViewport，否则血量根本不在画面里。
	# 项目用的是固定基准分辨率的 canvas 拉伸，根视口尺寸不等于窗口尺寸，所以三层
	# （arena 控件 / 容器 / SubViewport）全部对齐到根视口，_world_to_arena 才是 1:1。
	var root_size := get_viewport().get_visible_rect().size
	print("root viewport = %s" % str(root_size))
	var arena_control := Control.new()
	arena_control.position = Vector2.ZERO
	arena_control.size = root_size
	add_child(arena_control)
	arena._arena = arena_control

	var container := SubViewportContainer.new()
	container.stretch = true
	container.position = Vector2.ZERO
	container.size = root_size
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	arena_control.add_child(container)

	viewport = SubViewport.new()
	viewport.size = Vector2i(root_size)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	container.add_child(viewport)

	var world := Node3D.new()
	world.name = "Battle3DWorld"
	viewport.add_child(world)
	arena._battle_3d_world = world
	arena._battle_3d_root = Node3D.new()
	world.add_child(arena._battle_3d_root)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.13, 0.09)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.34, 0.42, 0.34)
	env.ambient_light_energy = 0.42
	env_node.environment = env
	viewport.add_child(env_node)

	var light := DirectionalLight3D.new()
	light.light_color = Color(1.0, 0.84, 0.62)
	light.light_energy = 1.55
	light.rotation_degrees = Vector3(-55.0, 35.0, 0.0)
	viewport.add_child(light)

	# 与 BattleArena._build() 同款的正交相机。
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = arena.BATTLE_CAMERA_SIZE
	camera.look_at_from_position(arena.BATTLE_CAMERA_POS, Vector3.ZERO, Vector3.UP)
	camera.current = true
	viewport.add_child(camera)
	arena._battle_3d_camera = camera
	arena._battle_3d_viewport = viewport

	# 一块地面代理：真机没有 3D 地面，这里加一块只是为了让截图能看出地平线在哪。
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(14.0, 14.0)
	ground.mesh = plane
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.24, 0.34, 0.20)
	ground.material_override = ground_mat
	ground.position = Vector3(0.0, 0.0, 0.0)
	world.add_child(ground)

func _seed_battle_state() -> void:
	# 三个存活的赢方棋子，散在场地一侧；输方全灭。
	var players: Array = []
	for i in 3:
		players.append({
			"uid": "p%d" % i,
			"alive": true,
			"pos": Vector2(340.0 + float(i) * 150.0, 390.0),
		})
	var enemies: Array = []
	for i in 3:
		enemies.append({"uid": "e%d" % i, "alive": false, "pos": Vector2(500.0, 120.0)})
	arena._state = {"kind": "pvp", "player": players, "enemy": enemies}

func _capture(file_path: String) -> void:
	for _i in 3:
		await RenderingServer.frame_post_draw
	# 整窗截图：SubViewport 里的 3D + 叠在上面的 2D 血量一起进来。
	get_viewport().get_texture().get_image().save_png(file_path)
