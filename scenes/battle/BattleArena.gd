extends "res://scenes/battle/BattleUI.gd"

const BossProceduralVFX3D := preload("res://effects/BossProceduralVFX3D.gd")
const CrystalRibbon3D := preload("res://effects/CrystalRibbon3D.gd")
const CRYSTAL_TOON_SHADER := preload("res://shaders/battle_crystal_toon_preview.gdshader")
const CRYSTAL_OUTLINE_SHADER := preload("res://shaders/battle_crystal_outline.gdshader")
const BattleLaneBarrier2D := preload("res://scenes/battle/BattleLaneBarrier2D.gd")
const FinalLaneLightWall2D := preload("res://scenes/battle/FinalLaneLightWall2D.gd")
const CRYSTAL_OUTLINE_WIDTH := 0.008

const FIRE_GLOW_TEXTURE_PATH := "res://assets/vfx/battlefield/fire_glow_soft.png"
const FIRE_SPARK_TEXTURE_PATH := "res://assets/vfx/battlefield/fire_spark_dot.png"
const BATTLE_2_5D_BASE_PATH := "res://assets/board/2_5d/battlefield_jungle_pve.png"
const BATTLE_2_5D_PVP_BASE_PATH := "res://assets/board/2_5d/battlefield_snow_pvp.png"
const BATTLE_2_5D_FINAL_BASE_PATH := "res://assets/board/2_5d/battlefield_final_round.png"
const BATTLE_2_5D_FRONT_PATH := "res://assets/board/2_5d/battlefield_front_occlusion_full.png"
const BATTLE_2_5D_FIRE_PATH := "res://assets/board/2_5d/fire_single_source.png"
const FIRE_FLAME_SOURCE_RECT := Rect2(555.0, 20.0, 125.0, 120.0)
const FIRE_FLAME_POINTS := [Vector2(526.0, 82.0), Vector2(1162.0, 82.0)]
const BATTLE_PVP_BACKGROUND_SCALE := 1.0
const BATTLE_VISUAL_SPACE_SCALE := 0.88
const BATTLE_VISUAL_DOWN_SHIFT_RATIO := 0.1
const BLUE_CRYSTAL_MODEL_PATH := "res://assets/models/battle_crystals/blue/Meshy_AI_Blue_Crystal_Spire_0717152101_texture_fbx/Meshy_AI_Blue_Crystal_Spire_0717152101_texture.fbx"
const RED_CRYSTAL_MODEL_PATH := "res://assets/models/battle_crystals/red/Meshy_AI_Crimson_Prism_0717152324_texture_fbx/Meshy_AI_Crimson_Prism_0717152324_texture.fbx"
const BATTLE_CRYSTAL_TARGET_HEIGHT := 1.55
# 水晶不常驻战场：棋子分出胜负后才在场地正中央召唤一座，演完就收。
const BATTLE_CRYSTAL_DEMO_POSITION := Vector3(0.0, 0.04, 0.0)
const CRYSTAL_RISE_SEC := 0.62
# 整段攻击的总时长预算：间隔 = 预算 / 彩带数量，并有下限。人少时一发一发看得清，
# 人多时自动变成连射，血量像计数器往下滚，总时长恒定。
const CRYSTAL_VOLLEY_BUDGET_SEC := 2.0
const CRYSTAL_VOLLEY_MIN_GAP_SEC := 0.07
const CRYSTAL_RIBBON_FLIGHT_SEC := 0.38
const CRYSTAL_SHAKE_IMPULSE := 0.07
const CRYSTAL_SHAKE_DECAY := 0.42
const CRYSTAL_HP_LABEL_SIZE := Vector2(210.0, 56.0)
# 水晶原点就在底面，所以锚点直接用它，再在屏幕空间往下推固定像素。相机是正交且
# 俯视的，只挪世界 Y 在画面上位移很小，用屏幕偏移才好控制。
const CRYSTAL_HP_LABEL_SCREEN_DROP := 46.0
const CRYSTAL_UNIT_VANISH_SEC := 0.15
const CRYSTAL_FADE_SEC := 0.34
const CRYSTAL_SHATTER_PUNCH_SEC := 0.12
const CRYSTAL_SHATTER_SEC := 0.28
const CRYSTAL_GLOW_POINTS := [
	Vector3(165.0, 155.0, 1.0),
	Vector3(1505.0, 155.0, 1.0),
]

var _3v3_barriers: Array[BattleLaneBarrier2D] = []
var _final_lane_walls: Array[FinalLaneLightWall2D] = []
var _battlefield_2_5d_root: Node2D
var _battlefield_2_5d_size := Vector2(1672.0, 941.0)
var _looping_tweens: Array[Tween] = []
var _demo_crystal: Node3D
var _demo_crystal_base_position := Vector3.ZERO
# 升起动画期间不要让漂浮逻辑抢 position，等落位后才开始飘。
var _demo_crystal_floating := false
var _crystal_attack_running := false
var _crystal_motion_time := 0.0
# 命中后的抖动量，每帧衰减。
var _crystal_shake := 0.0
var _crystal_hp_label: Label
var _crystal_hp_current := 0
var _crystal_hp_max := 0

func _exit_tree() -> void:
	# Infinite set_loops() tweens must be killed explicitly so none survive
	# the battle scene and keep ticking in the tween manager.
	for tween in _looping_tweens:
		if tween != null and tween.is_valid():
			tween.kill()
	_looping_tweens.clear()

# 千万不要把这段放回 _process。BattleScreen（继承链最末端，实际被实例化的那个类）
# 自己定义了 _process，而 GDScript 不会自动往上调父类的同名回调——本类的 _process
# 会被整个覆盖，一帧都不会执行。必须由 BattleScreen._process 显式调用，跟
# _update_vfx_camera_shake 同一个套路。
func _update_crystal_demo(delta: float) -> void:
	_crystal_motion_time += delta
	_crystal_shake = maxf(0.0, _crystal_shake - delta * CRYSTAL_SHAKE_DECAY)
	_animate_battle_crystals()
	_update_crystal_hp_label()

func _animate_battle_crystals() -> void:
	if not _demo_crystal_floating:
		return
	var crystal := _demo_crystal
	if crystal == null or not is_instance_valid(crystal):
		return
	var shake := Vector3.ZERO
	if _crystal_shake > 0.0:
		shake = Vector3(
			sin(_crystal_motion_time * 78.0) * _crystal_shake,
			sin(_crystal_motion_time * 61.0) * _crystal_shake * 0.6,
			0.0)
	crystal.position = _demo_crystal_base_position + Vector3(0.0, sin(_crystal_motion_time * TAU / 2.6) * 0.12, 0.0) + shake
	crystal.rotation_degrees.y = sin(_crystal_motion_time * TAU / 5.2) * 4.0
	crystal.rotation_degrees.z = sin(_crystal_motion_time * TAU / 4.1) * 1.6

func _build() -> void:
	if _battle_arena_ready:
		return
	_battle_arena_ready = true
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
	_arena = arena_wrap

	_add_layered_battle_background(arena_wrap)

	var arena_tint := ColorRect.new()
	var battlefield_kind := _battlefield_kind()
	if battlefield_kind == "final":
		arena_tint.color = Color(0.055, 0.035, 0.060, 0.08)
	elif battlefield_kind == "pvp":
		arena_tint.color = Color(0.045, 0.070, 0.110, 0.08)
	else:
		arena_tint.color = Color(0.012, 0.030, 0.022, 0.08)
	arena_tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	arena_wrap.add_child(arena_tint)
	arena_tint.z_index = -10

	_add_battle_grid_overlay(arena_wrap)

	_setup_battle_3d_view(arena_wrap)
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

	# (8) Live "top ATK" leaderboard on the left-middle: top 5 units by attack,
	# each name in its owner/team color, plus its dealt damage.
	_top5_atk_lbl = RichTextLabel.new()
	_top5_atk_lbl.bbcode_enabled = true
	_top5_atk_lbl.fit_content = true
	_top5_atk_lbl.scroll_active = false
	_top5_atk_lbl.anchor_left = 0.0
	_top5_atk_lbl.anchor_right = 0.0
	_top5_atk_lbl.anchor_top = 0.5
	_top5_atk_lbl.anchor_bottom = 0.5
	_top5_atk_lbl.offset_left = 12
	_top5_atk_lbl.offset_right = 232
	_top5_atk_lbl.offset_top = -96
	_top5_atk_lbl.offset_bottom = 96
	_top5_atk_lbl.add_theme_font_size_override("normal_font_size", 15)
	_top5_atk_lbl.add_theme_font_size_override("bold_font_size", 16)
	_top5_atk_lbl.add_theme_color_override("default_color", Color(0.95, 0.95, 0.98))
	_top5_atk_lbl.add_theme_constant_override("outline_size", 4)
	_top5_atk_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.92))
	_top5_atk_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top5_atk_lbl.z_index = 90
	add_child(_top5_atk_lbl)

	# Floating skip button (top-right corner, above the full-screen arena).
	var skip := Button.new()
	skip.text = tr("battle_skip")
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
		team_hp_lbl.text = tr("battle_team_hp") % [GameState.team_hp, GameState.START_FORMATION_HP]
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

const BATTLE_3V3_BOUNDS := [1.0 / 3.0, 2.0 / 3.0]


func _add_layered_battle_background(arena_wrap: Control) -> void:
	if BATTLE_USE_3D_ARENA:
		return
	_battlefield_2_5d_root = Node2D.new()
	_battlefield_2_5d_root.name = "Battlefield2_5D"
	arena_wrap.add_child(_battlefield_2_5d_root)
	_add_battlefield_sprite("BaseBackground", _battlefield_base_path(), 0)
	_fit_battlefield_2_5d()
	arena_wrap.resized.connect(_fit_battlefield_2_5d)


func _battlefield_kind() -> String:
	var kind := str(_state.get("kind", _kind))
	# 3v3 组队：首次 _build() 时服务器 replay 还没到，_state 为空、_kind 只是 "team"，
	# 拿不到真实回合类型。_build() 只建一次（有 _battle_arena_ready 守卫），所以必须在
	# 这里用赛程表提前判断真实回合类型，确保 PVE、PVP 和 final 各自使用正确战场。
	if kind == "team" or kind == "":
		kind = RoundService.schedule_kind_for_round(GameState.round_index)
	return kind


func _uses_pvp_battlefield() -> bool:
	return _battlefield_kind() == "pvp"


func _battlefield_base_path() -> String:
	match _battlefield_kind():
		"final":
			return BATTLE_2_5D_FINAL_BASE_PATH
		"pvp":
			return BATTLE_2_5D_PVP_BASE_PATH
		_:
			return BATTLE_2_5D_BASE_PATH

func _add_battlefield_sprite(sprite_name: String, texture_path: String, layer_z: int) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.name = sprite_name
	sprite.texture = load(texture_path) as Texture2D
	if sprite_name == "BaseBackground" and sprite.texture != null:
		_battlefield_2_5d_size = Vector2(sprite.texture.get_width(), sprite.texture.get_height())
	sprite.centered = false
	sprite.position = Vector2.ZERO
	sprite.z_index = layer_z
	_battlefield_2_5d_root.add_child(sprite)
	return sprite


func _fit_battlefield_2_5d() -> void:
	if _battlefield_2_5d_root == null or _arena == null:
		return
	var arena_size := _arena.size
	if arena_size.x <= 0.0 or arena_size.y <= 0.0:
		return
	var fit_scale := maxf(arena_size.x / _battlefield_2_5d_size.x, arena_size.y / _battlefield_2_5d_size.y)
	if _battlefield_kind() == "pvp":
		fit_scale *= BATTLE_PVP_BACKGROUND_SCALE
	_battlefield_2_5d_root.scale = Vector2.ONE * fit_scale
	_battlefield_2_5d_root.position = (arena_size - _battlefield_2_5d_size * fit_scale) * 0.5


func _add_fire_layer() -> void:
	var texture := load(BATTLE_2_5D_FIRE_PATH) as Texture2D
	if texture == null:
		return
	var fire_scale := Vector2(
		_battlefield_2_5d_size.x / float(texture.get_width()),
		_battlefield_2_5d_size.y / float(texture.get_height())
	)
	var flame_size := FIRE_FLAME_SOURCE_RECT.size * fire_scale
	for i in FIRE_FLAME_POINTS.size():
		var flame := Sprite2D.new()
		flame.name = "FireEffects%d" % i
		flame.texture = texture
		flame.region_enabled = true
		flame.region_rect = FIRE_FLAME_SOURCE_RECT
		flame.centered = false
		flame.position = FIRE_FLAME_POINTS[i] - flame_size * 0.5
		flame.scale = fire_scale
		flame.z_index = 25
		_battlefield_2_5d_root.add_child(flame)
		var tween := flame.create_tween()
		_looping_tweens.append(tween)
		tween.set_loops()
		tween.tween_property(flame, "modulate:a", 0.72, 0.22 + float(i) * 0.03)
		tween.parallel().tween_property(flame, "scale", fire_scale * 1.04, 0.22 + float(i) * 0.03)
		tween.tween_property(flame, "modulate:a", 1.0, 0.28 + float(i) * 0.03)
		tween.parallel().tween_property(flame, "scale", fire_scale, 0.28 + float(i) * 0.03)
	for point in FIRE_FLAME_POINTS:
		_add_fire_spark_particles(point)


func _add_fire_spark_particles(point: Vector2) -> void:
	var sparks := GPUParticles2D.new()
	sparks.name = "FireSparks"
	sparks.position = point
	sparks.z_index = 26
	sparks.amount = 10
	sparks.lifetime = 0.75
	sparks.preprocess = 0.75
	sparks.texture = load(FIRE_SPARK_TEXTURE_PATH) as Texture2D
	var material := ParticleProcessMaterial.new()
	material.direction = Vector3(0.0, -1.0, 0.0)
	material.spread = 22.0
	material.gravity = Vector3(0.0, -24.0, 0.0)
	material.initial_velocity_min = 12.0
	material.initial_velocity_max = 34.0
	material.scale_min = 0.18
	material.scale_max = 0.38
	material.color = Color(1.0, 0.62, 0.14, 0.75)
	sparks.process_material = material
	_battlefield_2_5d_root.add_child(sparks)


func _add_crystal_glows() -> void:
	for i in CRYSTAL_GLOW_POINTS.size():
		var data: Vector3 = CRYSTAL_GLOW_POINTS[i]
		_add_crystal_particles(Vector2(data.x, data.y), data.z, i)


func _add_crystal_particles(point: Vector2, size_mul: float, index: int) -> void:
	var particles := GPUParticles2D.new()
	particles.name = "CrystalGlow%d" % index
	particles.position = point
	particles.z_index = 22
	particles.amount = int(26.0 * size_mul)
	particles.lifetime = 1.4
	particles.preprocess = 1.4
	particles.texture = load(FIRE_SPARK_TEXTURE_PATH) as Texture2D
	var add_mat := CanvasItemMaterial.new()
	add_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	particles.material = add_mat
	var material := ParticleProcessMaterial.new()
	material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	material.emission_sphere_radius = 28.0 * size_mul
	material.spread = 180.0
	material.gravity = Vector3.ZERO
	material.initial_velocity_min = 2.0
	material.initial_velocity_max = 10.0
	material.scale_min = 0.18 * size_mul
	material.scale_max = 0.52 * size_mul
	material.color = Color(0.25, 0.85, 1.0, 0.58)
	particles.process_material = material
	_battlefield_2_5d_root.add_child(particles)
	var tween := particles.create_tween()
	_looping_tweens.append(tween)
	tween.set_loops()
	tween.tween_property(particles, "modulate:a", 0.95, 0.9 + float(index) * 0.05)
	tween.tween_property(particles, "modulate:a", 0.38, 1.0 + float(index) * 0.05)


func _add_front_occlusion() -> void:
	for offset in [Vector2(-2.0, 0.0), Vector2(2.0, 0.0), Vector2(0.0, -2.0), Vector2(0.0, 2.0)]:
		_add_front_copy("FrontOcclusionOutline", offset, 58, Color(0.0, 0.0, 0.0, 0.46))
	_add_battlefield_sprite("FrontOcclusion", BATTLE_2_5D_FRONT_PATH, 60)


func _add_front_copy(sprite_name: String, offset: Vector2, layer_z: int, color: Color) -> void:
	var sprite := _add_battlefield_sprite(sprite_name, BATTLE_2_5D_FRONT_PATH, layer_z)
	sprite.position = offset
	sprite.modulate = color


func _add_battle_3v3_dividers(arena_wrap: Control) -> void:
	_3v3_barriers.clear()
	_final_lane_walls.clear()
	if _battlefield_kind() == "final" or GameState.round_index == GameState.FINAL_ROUND:
		for i in BATTLE_3V3_BOUNDS.size():
			var wall := FinalLaneLightWall2D.new()
			wall.name = "FinalLaneLightWall%d" % i
			wall.z_index = 40
			arena_wrap.add_child(wall)
			wall.play_loop()
			_final_lane_walls.append(wall)
		return
	for i in BATTLE_3V3_BOUNDS.size():
		var barrier := BattleLaneBarrier2D.new()
		barrier.name = "Battle3v3LaneBarrier%d" % i
		barrier.z_index = 40
		arena_wrap.add_child(barrier)
		barrier.play_loop(i * 7)
		_3v3_barriers.append(barrier)

func _update_3v3_dividers() -> void:
	if _arena == null or _battle_3d_camera == null:
		return
	if _battlefield_kind() == "final" or GameState.round_index == GameState.FINAL_ROUND:
		var visual_min := _battle_visual_min()
		var visual_max := _battle_visual_max()
		for i in _final_lane_walls.size():
			var sy := lerpf(visual_min.y, visual_max.y, BATTLE_3V3_BOUNDS[i])
			var p_left := _world_to_arena(_sim_to_world_pos(Vector2(visual_min.x, sy), false))
			var p_right := _world_to_arena(_sim_to_world_pos(Vector2(visual_max.x, sy), false))
			var wall := _final_lane_walls[i]
			wall.position = (p_left + p_right) * 0.5
			wall.rotation = (p_right - p_left).angle()
			wall.scale = Vector2(maxf(0.1, p_left.distance_to(p_right) / 1024.0), 0.20)
			if not wall.is_released() and _should_release_3v3_boundary(i):
				wall.play_release()
		return
	if _3v3_barriers.is_empty():
		return
	var visual_min := _battle_visual_min()
	var visual_max := _battle_visual_max()
	var x0 := visual_min.x
	var x1 := visual_max.x
	for i in _3v3_barriers.size():
		var sx := lerpf(x0, x1, BATTLE_3V3_BOUNDS[i])
		var p_top := _world_to_arena(_sim_to_world_pos(Vector2(sx, visual_min.y), false))
		var p_bot := _world_to_arena(_sim_to_world_pos(Vector2(sx, visual_max.y), false))
		var top_y := minf(p_top.y, p_bot.y)
		var bot_y := maxf(p_top.y, p_bot.y)
		var mid_x := (p_top.x + p_bot.x) * 0.5
		var barrier := _3v3_barriers[i]
		barrier.position = Vector2(mid_x, (top_y + bot_y) * 0.5)
		barrier.scale = Vector2(0.42, maxf(0.1, (bot_y - top_y) / 512.0))
		if not barrier.is_released() and _should_release_3v3_boundary(i):
			barrier.play_release()


func _should_release_3v3_boundary(boundary_index: int) -> bool:
	var left_lane := boundary_index
	var right_lane := boundary_index + 1
	return (
		_lane_cleared_by("player", left_lane)
		or _lane_cleared_by("enemy", left_lane)
		or _lane_cleared_by("player", right_lane)
		or _lane_cleared_by("enemy", right_lane)
	)


func _lane_cleared_by(team: String, lane: int) -> bool:
	var own_side: Array = _state.get(team, [])
	var opposing_team := "enemy" if team == "player" else "player"
	var opposing_side: Array = _state.get(opposing_team, [])
	var own_survivor := false
	for fighter in own_side:
		if bool(fighter.get("alive", false)) and int(fighter.get("lane", -1)) == lane:
			own_survivor = true
			break
	if not own_survivor:
		return false
	for fighter in opposing_side:
		if bool(fighter.get("alive", false)) and int(fighter.get("lane", -1)) == lane:
			return false
	return true

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
	container.name = "UnitsLayer"
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.z_index = 40
	arena_wrap.add_child(container)

	_battle_3d_viewport = SubViewport.new()
	_battle_3d_viewport.size = Vector2i(960, 540)
	_battle_3d_viewport.transparent_bg = true
	_battle_3d_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(_battle_3d_viewport)

	var world := Node3D.new()
	world.name = "Battle3DWorld"
	_battle_3d_viewport.add_child(world)
	# 水晶演出（召唤 / 光带 / 光环）都往这个根上挂。以前这个引用一直是 null，
	# 于是 _play_crystal_attack_sequence 每次都在开头的空值守卫里直接返回。
	_battle_3d_world = world
	_add_battle_3d_arena(world)
	_battle_3d_root = Node3D.new()
	_battle_3d_root.name = "BattleModelRoot"
	world.add_child(_battle_3d_root)
	_battle_3d_vfx_root = BossProceduralVFX3D.new()
	_battle_3d_vfx_root.name = "BossProceduralVFX3D"
	_battle_3d_root.add_child(_battle_3d_vfx_root)

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


# 结算演出用的水晶：红队一座红晶、蓝队一座蓝晶，颜色是队伍的绝对属性，六个
# 玩家看到的是同一个颜色（跟观看者是谁无关）。返回 null 表示模型加载失败。
func _spawn_demo_crystal(losing_team: int, ratio: float) -> Node3D:
	if _battle_3d_world == null:
		return null
	var is_red_team := losing_team == GameConstants.TEAM_RED
	var model_path := RED_CRYSTAL_MODEL_PATH if is_red_team else BLUE_CRYSTAL_MODEL_PATH
	var packed := load(model_path) as PackedScene
	if packed == null:
		push_warning("Battle crystal model failed to load: %s" % model_path)
		return null
	var crystal := packed.instantiate() as Node3D
	if crystal == null:
		push_warning("Battle crystal model is not a Node3D: %s" % model_path)
		return null
	crystal.name = "DemoCrystal"
	_battle_3d_world.add_child(crystal)
	_clamp_crystal_material_emission(crystal)
	_apply_battle_crystal_toon(crystal, is_red_team, ratio)
	var bounds := _node3d_bounds(crystal)
	var scale_factor := 1.0
	if bounds.size.y > 0.001:
		scale_factor = BATTLE_CRYSTAL_TARGET_HEIGHT / bounds.size.y
	var base_center := Vector3(
		bounds.position.x + bounds.size.x * 0.5,
		bounds.position.y,
		bounds.position.z + bounds.size.z * 0.5
	)
	crystal.scale = Vector3.ONE * scale_factor
	crystal.position = BATTLE_CRYSTAL_DEMO_POSITION - base_center * scale_factor
	_demo_crystal = crystal
	_demo_crystal_base_position = crystal.position
	_add_crystal_cluster_parts(crystal, packed, is_red_team, ratio)
	return crystal

func _add_crystal_cluster_parts(cluster_root: Node3D, packed: PackedScene, is_red: bool, ratio: float) -> void:
	var offsets := [
		Vector3(-0.34, 0.05, 0.02),
		Vector3(0.36, 0.10, -0.04),
		Vector3(-0.18, 0.26, 0.18),
		Vector3(0.20, 0.32, 0.14),
		Vector3(-0.60, 0.72, 0.02),
		Vector3(0.58, 0.82, -0.08)
	]
	var scales := [0.62, 0.54, 0.46, 0.39, 0.20, 0.16]
	var yaws := [-24.0, 22.0, -14.0, 18.0, -30.0, 28.0]
	for i in offsets.size():
		var part := packed.instantiate() as Node3D
		if part == null:
			continue
		part.name = "CrystalClusterPart_%d" % i
		cluster_root.add_child(part)
		part.position = offsets[i]
		part.rotation_degrees = Vector3(0.0, yaws[i], 0.0)
		part.scale = Vector3.ONE * float(scales[i])
		_clamp_crystal_material_emission(part)
		_apply_battle_crystal_toon(part, is_red, ratio)


func _clamp_crystal_material_emission(root: Node) -> void:
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var safe_mesh := mesh_instance.mesh.duplicate() as Mesh
		if safe_mesh == null:
			continue
		mesh_instance.mesh = safe_mesh
		for surface_index in safe_mesh.get_surface_count():
			var source_material := safe_mesh.surface_get_material(surface_index)
			if source_material is BaseMaterial3D:
				var safe_material := source_material.duplicate() as BaseMaterial3D
				safe_material.emission_energy_multiplier = minf(safe_material.emission_energy_multiplier, 0.45)
				safe_mesh.surface_set_material(surface_index, safe_material)

# losing_team 是绝对队伍（GameConstants.TEAM_RED / TEAM_BLUE），而 GameState 的血量
# 是以本地玩家为中心存的（team_hp = 我队，enemy_team_hp = 对面），所以先把绝对队伍
# 翻译成"是不是我这一队"再取数。
func _crystal_hp_ratio(losing_team: int, result: Dictionary = {}) -> float:
	var local_team := GameConstants.team_of_slot(NetworkService.team_local_slot)
	var loser_is_local := losing_team == local_team
	var hp := float(GameState.team_hp if loser_is_local else GameState.enemy_team_hp) if GameState.team_mode else float(GameState.player_formation_hp if loser_is_local else GameState.enemy_formation_hp)
	if not result.is_empty():
		var damage_key := "team_damage_self" if loser_is_local else "team_damage_rival"
		if result.has(damage_key):
			hp -= float(result.get(damage_key, 0))
		else:
			# 没盖伤害戳时退回"赢家存活数"，跟 stamp_team_round_damages 的 PvP 口径一致。
			var winner_alive_key := "player_alive" if bool(result.get("player_wins", false)) else "enemy_alive"
			hp -= float(result.get(winner_alive_key, 1))
	return clampf(hp / maxf(1.0, float(GameState.START_FORMATION_HP)), 0.0, 1.0)

func _apply_battle_crystal_toon(root: Node3D, is_red: bool, ratio: float) -> void:
	var shade_color := Color(0.24, 0.012, 0.028) if is_red else Color(0.012, 0.10, 0.31)
	var body_color := Color(0.76, 0.025, 0.055) if is_red else Color(0.018, 0.42, 0.82)
	var light_color := Color(1.0, 0.16, 0.10) if is_red else Color(0.035, 0.82, 0.96)
	var glint_color := Color(1.0, 0.80, 0.62) if is_red else Color(0.78, 0.98, 1.0)
	var rim_color := Color(0.90, 0.06, 0.08) if is_red else Color(0.08, 0.64, 0.96)
	var tip_color := Color(1.0, 0.45, 0.28) if is_red else Color(0.55, 0.95, 1.0)
	var outline_color := Color(0.13, 0.012, 0.035) if is_red else Color(0.018, 0.045, 0.16)
	# The gradient runs over the crystal's world-space height. Both crystals share
	# the same base height, so the constants are enough and this stays correct even
	# though the toon pass is applied before the crystal is moved into place.
	var gradient_base_y := BATTLE_CRYSTAL_DEMO_POSITION.y
	var gradient_height := BATTLE_CRYSTAL_TARGET_HEIGHT * 1.15
	for found in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := found as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var source_mesh := mesh_instance.mesh
		var toon_mesh := source_mesh.duplicate() as Mesh
		if toon_mesh == null:
			continue
		var outline := ShaderMaterial.new()
		outline.shader = CRYSTAL_OUTLINE_SHADER
		outline.set_shader_parameter("outline_color", outline_color)
		outline.set_shader_parameter("outline_width", CRYSTAL_OUTLINE_WIDTH)
		for surface_index in toon_mesh.get_surface_count():
			var source := source_mesh.surface_get_material(surface_index) as BaseMaterial3D
			var toon := ShaderMaterial.new()
			toon.shader = CRYSTAL_TOON_SHADER
			toon.set_shader_parameter("shade_color", shade_color)
			toon.set_shader_parameter("body_color", body_color)
			toon.set_shader_parameter("light_color", light_color)
			toon.set_shader_parameter("glint_color", glint_color)
			toon.set_shader_parameter("rim_color", rim_color)
			toon.set_shader_parameter("tip_color", tip_color)
			toon.set_shader_parameter("hp_ratio", ratio)
			toon.set_shader_parameter("texture_influence", 0.0)
			toon.set_shader_parameter("gradient_base_y", gradient_base_y)
			toon.set_shader_parameter("gradient_height", gradient_height)
			if source != null and source.albedo_texture != null:
				toon.set_shader_parameter("albedo_texture", source.albedo_texture)
				toon.set_shader_parameter("has_albedo_texture", true)
			toon.next_pass = outline
			toon_mesh.surface_set_material(surface_index, toon)
		mesh_instance.mesh = toon_mesh

# 发射一条飘带。命中时回调 on_hit（扣血 / 闪光 / 抖动都挂在那里）。
func _make_crystal_attack_ribbon(start: Vector3, target: Vector3, color: Color, on_hit: Callable) -> void:
	if _battle_3d_world == null:
		return
	var ribbon := CrystalRibbon3D.new()
	ribbon.name = "CrystalRibbon"
	ribbon.start_point = start
	ribbon.end_point = target
	ribbon.ribbon_color = color
	ribbon.flight_sec = CRYSTAL_RIBBON_FLIGHT_SEC
	# 出手点比水晶高，弧线压低一点才不会飞出画面顶。
	ribbon.arc_height = 0.42
	if on_hit.is_valid():
		ribbon.hit.connect(on_hit)
	_battle_3d_world.add_child(ribbon)

# 水晶脚下的血量条。跟单位血条一样是 2D 控件，靠 _world_to_arena 每帧贴到 3D 位置上，
# 这样字始终清晰、也和其余 UI 同一套层级。格式是「上限 / 当前」。
func _make_crystal_hp_label(current: int, maximum: int, color: Color) -> void:
	_crystal_hp_current = current
	_crystal_hp_max = maximum
	if _arena == null:
		return
	_clear_crystal_hp_label()
	var label := Label.new()
	label.name = "CrystalHpLabel"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.custom_minimum_size = Vector2(CRYSTAL_HP_LABEL_SIZE.x, CRYSTAL_HP_LABEL_SIZE.y)
	label.size = CRYSTAL_HP_LABEL_SIZE
	label.add_theme_font_size_override("font_size", 38)
	label.add_theme_color_override("font_color", color.lightened(0.62))
	label.add_theme_color_override("font_outline_color", Color(0.03, 0.02, 0.05, 0.95))
	label.add_theme_constant_override("outline_size", 10)
	# 不垫底板，就是水晶下面一行裸字。可读性全靠这圈粗描边扛。
	# 结算面板是 200，前景遮挡层是 60，血量要压在遮挡层之上才不会被前景草石盖住。
	label.z_index = 80
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arena.add_child(label)
	_crystal_hp_label = label
	_refresh_crystal_hp_text()

func _refresh_crystal_hp_text() -> void:
	if _crystal_hp_label == null or not is_instance_valid(_crystal_hp_label):
		return
	_crystal_hp_label.text = "%d / %d" % [_crystal_hp_max, _crystal_hp_current]

func _update_crystal_hp_label() -> void:
	if _crystal_hp_label == null or not is_instance_valid(_crystal_hp_label):
		return
	if _demo_crystal == null or not is_instance_valid(_demo_crystal):
		return
	# 锚点用固定的落地点，不用 _demo_crystal.global_position——后者是节点原点，被
	# 建模时的 AABB 偏移抬到了半山腰，数字会压在水晶身上。用落地点还有个好处：
	# 水晶漂浮和被击中抖动时，数字稳稳待在原地不跟着晃。
	var screen := _world_to_arena(BATTLE_CRYSTAL_DEMO_POSITION)
	screen.y += CRYSTAL_HP_LABEL_SCREEN_DROP
	# pivot 设在中心，命中时的弹跳才是从中间放大而不是往右下角撑。
	_crystal_hp_label.pivot_offset = CRYSTAL_HP_LABEL_SIZE * 0.5
	_crystal_hp_label.position = screen - CRYSTAL_HP_LABEL_SIZE * 0.5

func _clear_crystal_hp_label() -> void:
	if _crystal_hp_label != null and is_instance_valid(_crystal_hp_label):
		_crystal_hp_label.queue_free()
	_crystal_hp_label = null

# 一发彩带命中：扣 1 点血、抖一下、闪一下。
func _apply_crystal_hit(is_red_team: bool) -> void:
	_crystal_hp_current = maxi(0, _crystal_hp_current - 1)
	_refresh_crystal_hp_text()
	_crystal_shake = CRYSTAL_SHAKE_IMPULSE
	if _crystal_hp_label != null and is_instance_valid(_crystal_hp_label):
		var pop := create_tween()
		pop.tween_property(_crystal_hp_label, "scale", Vector2(1.22, 1.22), 0.06)
		pop.tween_property(_crystal_hp_label, "scale", Vector2.ONE, 0.12)
	var crystal := _demo_crystal
	if crystal == null or not is_instance_valid(crystal):
		return
	# 用 hp_ratio 瞬间打亮再回落，做出被击中的闪光。
	var ratio := clampf(float(_crystal_hp_current) / maxf(1.0, float(_crystal_hp_max)), 0.0, 1.0)
	_set_crystal_flash(crystal, 1.0)
	var flash := create_tween()
	flash.tween_interval(0.06)
	flash.tween_callback(_set_crystal_flash.bind(crystal, 0.0))
	flash.tween_callback(_apply_battle_crystal_toon.bind(crystal, is_red_team, ratio))

func _set_crystal_flash(root: Node3D, amount: float) -> void:
	if root == null or not is_instance_valid(root):
		return
	for found in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := found as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		for surface_index in mesh_instance.mesh.get_surface_count():
			var mat := mesh_instance.mesh.surface_get_material(surface_index) as ShaderMaterial
			if mat != null:
				mat.set_shader_parameter("hit_flash", amount)

# 召唤时地面扩散的一圈光环，纯演出，播完自己回收。
func _make_crystal_summon_ring(color: Color) -> void:
	var ring := MeshInstance3D.new()
	ring.name = "CrystalSummonRing"
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.62
	mesh.outer_radius = 0.78
	ring.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(color.r, color.g, color.b, 0.0)
	ring.material_override = mat
	ring.position = BATTLE_CRYSTAL_DEMO_POSITION + Vector3(0.0, 0.02, 0.0)
	ring.scale = Vector3(0.35, 1.0, 0.35)
	_battle_3d_world.add_child(ring)
	var tween := create_tween()
	tween.tween_property(mat, "albedo_color:a", 0.85, 0.14)
	tween.parallel().tween_property(ring, "scale", Vector3(1.7, 1.0, 1.7), 0.62).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.34)
	tween.tween_callback(ring.queue_free)

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

func _battle_visual_min() -> Vector2:
	return BATTLE_VISUAL_MIN


func _battle_visual_max() -> Vector2:
	return BATTLE_VISUAL_MAX


func _clamp_visual_sim_pos(sim_pos: Vector2) -> Vector2:
	var visual_min := _battle_visual_min()
	var visual_max := _battle_visual_max()
	return Vector2(
		clampf(sim_pos.x, visual_min.x, visual_max.x),
		clampf(sim_pos.y, visual_min.y, visual_max.y)
	)

func _sim_to_world_pos(sim_pos: Vector2, apply_down_shift: bool = true) -> Vector3:
	sim_pos = _clamp_visual_sim_pos(sim_pos)
	var ny := sim_pos.y / SIM_H
	if _arena_flip_y:
		ny = 1.0 - ny
	var x := (sim_pos.x / SIM_W - 0.5) * BATTLE_PLAYABLE_WIDTH * BATTLE_VISUAL_SPACE_SCALE + BATTLE_PLAYABLE_OFFSET.x
	var z := (ny - 0.5) * BATTLE_PLAYABLE_DEPTH * BATTLE_VISUAL_SPACE_SCALE + BATTLE_PLAYABLE_OFFSET.z
	if apply_down_shift:
		z += BATTLE_PLAYABLE_DEPTH * BATTLE_VISUAL_DOWN_SHIFT_RATIO
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
