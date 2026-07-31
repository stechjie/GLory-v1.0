extends Node

# 贴图分辨率对比截图。
#
# 参数和 BattleArena 完全一致，否则对比没有意义：
#   viewport 960x540（战斗 3D 是渲进这个固定尺寸的 SubViewport 再拉伸铺屏的）
#   Camera3D  PROJECTION_ORTHOGONAL, size = BATTLE_CAMERA_SIZE(7.2)
#   模型缩放  battle_unit_visual_scale(0.42) * model_visual_scale
# 所以 540px / 7.2 世界单位 = 75 像素每单位。
#
# 每个单位出两张：
#   *_battle.png  战斗原样（整个 960x540），看它在游戏里到底长什么样
#   *_zoom.png    相机拉近到棋子占满画面高度，看贴图本身还剩多少细节
# 顺便把量到的真实像素高度打出来。
#
# 运行：Godot --path . tools/texres_shot.tscn -- --tag=4096

const VIEWPORT_SIZE := Vector2i(960, 540)
const BATTLE_CAMERA_SIZE := 7.2
const BATTLE_UNIT_VISUAL_SCALE := 0.42

# 覆盖各个族 + 佣兵 + Boss + 那个结构不同的 crystalbound（贴图挂在场景里而不是
# 材质常量里），确保验证不是只测到一种材质形态。
const UNITS := {
	"undead_titan": "res://assets/models/units/undead_titan_animated/undead_titan_animated.tscn",
	"human_archer": "res://assets/models/units/human_archer_animated/human_archer_animated.tscn",
	"dark_dragon": "res://assets/models/units/dark_dragon_animated/dark_dragon_animated.tscn",
	"dark_fear": "res://assets/models/units/dark_fear_animated/dark_fear_animated.tscn",
	"god_priest": "res://assets/models/units/god_priest_halo_animated/god_priest_animated.tscn",
	"god_arbiter": "res://assets/models/units/god_arbiter_animated/god_arbiter_animated.tscn",
	"god_guard_crystalbound": "res://assets/models/units/god_guard_crystalbound/god_guard_crystalbound_animated.tscn",
	"human_swordsman": "res://assets/models/units/human_swordsman_animated/human_swordsman_animated.tscn",
	"human_king": "res://assets/models/units/human_king_animated/human_king_animated.tscn",
	"merc_leo_sun": "res://assets/models/mercenaries/merc_leo_sun_animated/merc_leo_sun_animated.tscn",
	"merc_cancer_shell": "res://assets/models/mercenaries/merc_cancer_shell_animated/merc_cancer_shell_animated.tscn",
	"boss_apocalypse": "res://assets/models/bosses/boss_apocalypse_animated/boss_apocalypse_animated.tscn",
	"boss_meteor_caster": "res://assets/models/bosses/boss_meteor_caster_animated/boss_meteor_caster_animated.tscn",
}

var _out_dir := ""
var _tag := "untagged"
var viewport: SubViewport
var camera: Camera3D
var stage: Node3D

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--tag="):
			_tag = a.split("=", true, 1)[1]
		elif a.begins_with("--out="):
			_out_dir = a.split("=", true, 1)[1]
	if _out_dir.is_empty():
		_out_dir = "user://texres_shots"
	DirAccess.make_dir_recursive_absolute(_out_dir)
	_build_stage()
	for id in UNITS:
		await _shoot(str(id), str(UNITS[id]))
	print("TEXRES_DONE tag=%s dir=%s" % [_tag, _out_dir])
	get_tree().quit()

func _build_stage() -> void:
	viewport = SubViewport.new()
	viewport.size = VIEWPORT_SIZE
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# 战斗视口没开 MSAA（项目 msaa_3d=0），这里也别开，否则等于给对比加了滤镜。
	viewport.msaa_3d = Viewport.MSAA_DISABLED
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

	var light := DirectionalLight3D.new()
	light.light_color = Color(1.0, 0.84, 0.62)
	light.light_energy = 1.55
	light.rotation_degrees = Vector3(-55.0, 35.0, 0.0)
	viewport.add_child(light)

	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.current = true
	viewport.add_child(camera)

	stage = Node3D.new()
	viewport.add_child(stage)

func _shoot(id: String, path: String) -> void:
	var scene := ResourceLoader.load(path) as PackedScene
	if scene == null:
		print("MISSING %s" % path); return
	var model := scene.instantiate() as Node3D
	if model == null:
		print("NOT_NODE3D %s" % path); return
	model.set_meta("load_idle_only", true)
	model.scale = Vector3.ONE * BATTLE_UNIT_VISUAL_SCALE
	stage.add_child(model)
	# 蒙皮网格要等 idle pose 落下来才有可用的 AABB。
	for _i in 30:
		await get_tree().process_frame
	# 冻结姿势。不冻的话两次运行的动画相位不同，对比出来的 RMSE 全是动画差异 ——
	# 实测未改动的对照组都能差出 RMSE 8，比要测的改动本身还大。
	_freeze_pose(model)
	for _i in 4:
		await get_tree().process_frame

	var bounds := _bounds(model)
	if bounds.size.length() <= 0.001:
		print("NO_MESH %s" % id); model.queue_free(); return

	var center := bounds.position + bounds.size * 0.5
	var px_per_unit := float(VIEWPORT_SIZE.y) / BATTLE_CAMERA_SIZE
	var on_screen_px := bounds.size.y * px_per_unit

	# --- 战斗原样 ---
	camera.size = BATTLE_CAMERA_SIZE
	_place_camera(center, 12.0)
	await _capture("%s/%s_%s_battle.png" % [_out_dir, id, _tag])

	# --- 拉近：让棋子占满 540 高 ---
	camera.size = bounds.size.y * 1.15
	_place_camera(center, 12.0)
	await _capture("%s/%s_%s_zoom.png" % [_out_dir, id, _tag])

	# --- prep 棋盘取景：透视 FOV 44、相机 (0,3.8,2.0)、单位缩放 1.0（不乘 0.42）---
	model.scale = Vector3.ONE
	for _i in 6:
		await get_tree().process_frame
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.fov = 44.0
	camera.position = Vector3(0.0, 3.8, 2.0)
	camera.look_at(Vector3(0.0, -0.07, -0.03), Vector3.UP)
	await _capture("%s/%s_%s_prep.png" % [_out_dir, id, _tag])
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL

	print("SHOT %s tag=%s 世界高度=%.2f 战斗中像素高度=%.0f px" % [id, _tag, bounds.size.y, on_screen_px])
	model.queue_free()
	await get_tree().process_frame

# 把模型钉在动画第 0 帧：先停掉 *Animated 包装脚本的 _process（它每帧都会
# 重新 play），再把所有 AnimationPlayer seek 到 0 并暂停。
func _freeze_pose(model: Node) -> void:
	for n in _all_descendants(model):
		n.set_process(false)
		n.set_physics_process(false)
		var player := n as AnimationPlayer
		if player != null:
			player.speed_scale = 0.0
			if not player.current_animation.is_empty():
				player.seek(0.0, true)
			player.pause()

func _place_camera(center: Vector3, distance: float) -> void:
	var yaw := deg_to_rad(28.0)
	var pitch := deg_to_rad(14.0)
	var dir := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	camera.position = center + dir * distance
	camera.look_at(center, Vector3.UP)

func _capture(file_path: String) -> void:
	for _i in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.save_png(file_path)

func _bounds(node: Node) -> AABB:
	var out := AABB()
	var seeded := false
	for child in _all_descendants(node):
		var mesh_instance := child as VisualInstance3D
		if mesh_instance == null or not mesh_instance.visible:
			continue
		var box := mesh_instance.get_aabb()
		if box.size.length() <= 0.0001:
			continue
		box = mesh_instance.global_transform * box
		if not seeded:
			out = box; seeded = true
		else:
			out = out.merge(box)
	return out

func _all_descendants(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out
