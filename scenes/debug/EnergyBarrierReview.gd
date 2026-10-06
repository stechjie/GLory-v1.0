extends Control

# 魔法能量护栏（effects/battlefield/energy_barrier/EnergyBarrierSegment.tscn）的预览：
# 在编辑器里打开本场景（双击这个 .tscn）再按 F6。F6 跑的是当前打开的那个场景页签。
#
# 看到的就是 EnergyBarrierSegment.tscn 存盘后的样子：这里只摆位置，不改颜色、亮度、高度。
# 在护栏场景里改完要先存盘（运行时编辑器默认会自动存），再在这里按 F6。
# 例外：模式 2 为了对比四种颜色、模式 3 / 4 照战斗里按队伍上色，会勾上 unify_color 并设颜色。
#
#   1  方框：四段围成一圈（参考图那种斜俯视）
#   2  四色：蓝 / 红 / 金 / 紫各一段，侧面平视
#   3  战斗视角（PvP，红队玩家看）：和 BattleArena 同一台正交相机、同样的透明 3D 层叠在
#      战场背景图上；每条分路边界上下两段，按所在半场涂队伍色（只看墙，没有单位）
#   4  同上，蓝队玩家看（整张上下翻，自己的蓝色半场在下方）
#   L  低画质开关    空格  重播开场强调    R  解除边界（1.5 秒后恢复）
#
# 只预览，不改任何玩家设置。

const SEGMENT_SCENE := preload("res://effects/battlefield/energy_barrier/EnergyBarrierSegment.tscn")
const Arena := preload("res://scenes/battle/BattleArena.gd")
const BattleUI := preload("res://scenes/battle/BattleUI.gd")
const BATTLE_BG_PATH := "res://assets/board/2_5d/battlefield_jungle_pve.png"
# 和 BattleArena._sim_to_world_pos 同一套换算（BATTLE_VISUAL_SPACE_SCALE = 0.88）。
const VISUAL_SPACE_SCALE := 0.88
const LANE_BOUNDS := [1.0 / 3.0, 2.0 / 3.0]

const COLORS := {
	"蓝": Color(0.30, 0.62, 1.0),
	"红": Color(1.0, 0.27, 0.22),
	"金": Color(1.0, 0.72, 0.25),
	"紫": Color(0.68, 0.36, 1.0),
}

var _viewport: SubViewport
var _world: Node3D
var _camera: Camera3D
var _env: Environment
var _ground: MeshInstance3D
var _battle_bg: TextureRect
var _hint: Label
var _walls: Array[Node3D] = []
var _low_quality := false
var _mode := 1


func _ready() -> void:
	_battle_bg = TextureRect.new()
	_battle_bg.texture = load(BATTLE_BG_PATH) as Texture2D
	_battle_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_battle_bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_battle_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_battle_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_battle_bg)

	var container := SubViewportContainer.new()
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(container)
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	# 和战斗的 3D 层一样：透明底、不开 MSAA（中低画质档就是这样）。
	_viewport.transparent_bg = true
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	container.add_child(_viewport)

	_world = Node3D.new()
	_viewport.add_child(_world)
	var light := DirectionalLight3D.new()
	light.light_color = Color(1.0, 0.84, 0.62)
	light.light_energy = 1.55
	light.rotation_degrees = Vector3(-55, 35, 0)
	_world.add_child(light)
	var env_node := WorldEnvironment.new()
	_env = Environment.new()
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.34, 0.42, 0.34)
	_env.ambient_light_energy = 0.42
	env_node.environment = _env
	_world.add_child(env_node)
	_ground = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40.0, 40.0)
	_ground.mesh = plane
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.17, 0.23, 0.15)
	ground_mat.roughness = 1.0
	_ground.material_override = ground_mat
	_world.add_child(_ground)
	_camera = Camera3D.new()
	_camera.current = true
	_viewport.add_child(_camera)

	_hint = Label.new()
	_hint.position = Vector2(16.0, 10.0)
	_hint.add_theme_font_size_override("font_size", 18)
	_hint.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_hint.add_theme_constant_override("shadow_offset_x", 2)
	_hint.add_theme_constant_override("shadow_offset_y", 2)
	add_child(_hint)
	show_mode(1)


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_1, KEY_2, KEY_3, KEY_4:
			show_mode(key.keycode - KEY_0)
		KEY_L:
			_low_quality = not _low_quality
			for wall in _walls:
				wall.set_low_quality(_low_quality)
			_update_hint()
		KEY_SPACE:
			_replay_walls()
		KEY_R:
			for wall in _walls:
				wall.play_release()
			await get_tree().create_timer(1.5).timeout
			_replay_walls()


func show_mode(mode: int) -> void:
	_mode = mode
	for wall in _walls:
		wall.queue_free()
	_walls.clear()
	var battle := mode >= 3
	_battle_bg.visible = battle
	_ground.visible = not battle
	_env.background_mode = Environment.BG_CLEAR_COLOR if battle else Environment.BG_COLOR
	_env.background_color = Color(0.07, 0.09, 0.08)
	match mode:
		1:
			_show_ring()
		2:
			_show_colors()
		_:
			_show_battle(mode == 4)
	for i in _walls.size():
		_walls[i].set_low_quality(_low_quality)
	_replay_walls()
	_update_hint()


func _show_ring() -> void:
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.fov = 40.0
	_camera.look_at_from_position(Vector3(0.0, 4.3, 7.4), Vector3(0.0, 0.2, 0.3), Vector3.UP)
	var w := 2.6
	var d := 1.8
	var corners := [Vector3(-w, 0, -d), Vector3(w, 0, -d), Vector3(w, 0, d), Vector3(-w, 0, d)]
	for i in 4:
		# 长边两头都有柱子；短边两头关掉，借用长边的转角柱。
		var long_side := i % 2 == 0
		var wall := _add_segment()
		wall.get_node("LeftAnchor").visible = long_side
		wall.get_node("RightAnchor").visible = long_side
		wall.fit_between(corners[i], corners[(i + 1) % 4])


func _show_colors() -> void:
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.fov = 38.0
	_camera.look_at_from_position(Vector3(0.0, 2.1, 7.6), Vector3(0.0, 0.55, 0.0), Vector3.UP)
	var names := COLORS.keys()
	for i in names.size():
		var x0 := -4.1 + float(i % 2) * 4.4
		var z := -1.6 + floorf(i / 2.0) * 3.0
		var wall := _add_segment()
		wall.unify_color = true
		wall.color = COLORS[names[i]]
		wall.fit_between(Vector3(x0, 0, z), Vector3(x0 + 3.6, 0, z))


func _show_battle(blue_viewer: bool) -> void:
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = BattleUI.BATTLE_CAMERA_SIZE
	_camera.look_at_from_position(BattleUI.BATTLE_CAMERA_POS, Vector3.ZERO, Vector3.UP)
	var min_v: Vector2 = BattleUI.BATTLE_VISUAL_MIN
	var max_v: Vector2 = BattleUI.BATTLE_VISUAL_MAX
	# 和 BattleArena 同一套：上下两段在敌我半场分界线交接，按所在半场涂队伍色。
	var split_y := clampf(BattleUI.SIM_H * 0.5, min_v.y, max_v.y)
	var colors := Arena.lane_barrier_half_colors(true, GameConstants.TEAM_BLUE if blue_viewer else GameConstants.TEAM_RED)
	for i in LANE_BOUNDS.size():
		var sx := lerpf(min_v.x, max_v.x, LANE_BOUNDS[i])
		var points := [
			_sim_to_world(Vector2(sx, min_v.y), blue_viewer),
			_sim_to_world(Vector2(sx, split_y), blue_viewer),
			_sim_to_world(Vector2(sx, max_v.y), blue_viewer),
		]
		for half in 2:
			var wall := _add_segment()
			wall.unify_color = true
			wall.color = colors[half]
			wall.fit_between(points[half], points[half + 1])


# flipped 对应 BattleArena._arena_flip_y：蓝队玩家看 PvP 时只上下翻、左右不翻（10-06 起，
# 原来是整张转 180°，见 BattleArena._sim_to_world_pos）。
func _sim_to_world(sim_pos: Vector2, flipped: bool) -> Vector3:
	var nx := sim_pos.x / BattleUI.SIM_W
	var ny := sim_pos.y / BattleUI.SIM_H
	if flipped:
		ny = 1.0 - ny
	return Vector3(
		(nx - 0.5) * BattleUI.BATTLE_PLAYABLE_WIDTH * VISUAL_SPACE_SCALE,
		0.0,
		(ny - 0.5) * BattleUI.BATTLE_PLAYABLE_DEPTH * VISUAL_SPACE_SCALE)


func _add_segment() -> Node3D:
	var wall := SEGMENT_SCENE.instantiate() as Node3D
	_world.add_child(wall)
	_walls.append(wall)
	return wall


func _replay_walls() -> void:
	for i in _walls.size():
		_walls[i].play_loop(i * 7)


func _update_hint() -> void:
	var names := ["", "方框", "四色：蓝 红 / 金 紫", "战斗视角 PvP（红队玩家看）", "战斗视角 PvP（蓝队玩家看）"]
	_hint.text = "%s   画质：%s   （显示的是护栏场景存盘后的样子）\n1 方框  2 四色  3 战斗·红队看  4 战斗·蓝队看  L 低画质  空格 重播开场  R 解除边界" % [
		names[_mode], "低" if _low_quality else "正常"]
