extends "res://scenes/prep/PrepShared.gd"

const PREP_RELATION_PARTICLES_SCRIPT := preload("res://scenes/prep/PrepRelationParticles3D.gd")
const PREP_RELATION_LINK_SCRIPT := preload("res://scenes/prep/PrepRelationLink3D.gd")
const PREP_RIVER_ARENA_PATH := "res://assets/models/prep/river_arena/Meshy_AI_Verdant_River_Arena_0621085900_texture.fbx"
const PREP_RIVER_MATERIAL_PATH := "res://assets/models/prep/river_arena/prep_river_arena_material.tres"
# 2.5D 分层棋盘背景图（贴在 3D 平躺地面 quad 上，和棋子一起呈现 TFT 倾斜纵深）
const PREP_BOARD_BASE_PATH := "res://assets/board/prep_2_5d/glory_grass_base_2560x1440.png"
# 每个 4×4 格子上的站位图案（站位.png）——3D 地面 quad，模型在其上方不会被盖。
const PREP_CELL_MARK_PATH := "res://assets/board/prep_2_5d/board_cell_mark.png"
const PREP_CELL_MARK_SIZE := Vector2(0.6, 0.6)   # 每张站位图的世界尺寸（可调大小）
const PREP_CELL_MARK_Y_LIFT := 0.005             # 抬离地面高度（河流之上、模型之下）
const PREP_RIVER_TOP_PATH := "res://assets/board/prep_2_5d/prep20_river_top.png"        # 上河流（黑底，shader 键透明+流动）
const PREP_RIVER_BOTTOM_PATH := "res://assets/board/prep_2_5d/prep20_river_bottom.png"  # 下河流：恢复原始窄带高度
# ══════ 整块棋盘的「大小 / 位置」══════
#  改这两个会连 石台+格子+棋子+待命区+河流 一起动（它们都贴在这块地面上，不是只动棋盘）。
# 大小：x=宽、y=进深；调大 = 整个场地变大。
const PREP_BOARD_GROUND_SIZE := Vector2(8.0, 4.5)
# 位置：x=左右（负=左 / 正=右）、z=前后（负=远/靠上，正=近/靠下）、y=高度（一般不动）。
const PREP_BOARD_GROUND_CENTER := Vector3(-0.0, -0.10, -0.6)
const PREP_BOARD_GROUND_FLIP_V := false                  # 若图上下颠倒则改 true（翻转贴图 V）
# 河流流动高光层（贴在棋盘上方、横向滚动的波光）
const PREP_RIVER_FLOW_SHADER := "res://assets/shaders/prep_river_flow.gdshader"
const PREP_RIVER_TOP_EF_PATH := "res://assets/board/prep_2_5d/prep20_river_top_ef.png"
const PREP_RIVER_BOTTOM_EF_PATH := "res://assets/board/prep_2_5d/prep20_river_bottom_ef.png"
# ══════ 只调「4×4 格子」（发光圈 + 落子网格）在地面上的铺排 ══════
# ⚠️ 只动格子，不动画死的石台图；挪多了格子会跑出石台、对不上。
# UV 是贴图 0~1 占比：范围拉大 = 格子铺更开；两端同时加/减 = 格子整排平移。
const BOARD_STONE_U := Vector2(0.3, 0.64)             # 4×4 格子横向范围/位置
const BOARD_STONE_V := Vector2(0.26, 0.78)             # 4×4 格子纵向范围/位置
const BOARD_CELL_RADIUS := 0.22                         # 每个格子圆的大小（世界半径；地面上真圆，投影成椭圆）
const BOARD_CELL_SEGMENTS := 20                          # 圆的多边形段数
const BOARD_MODEL_SPREAD_U := 0.9  # 棋盘模型横向铺开缩放（不动圆圈）：1=和圆圈一样，<1=往中间收（治左右越偏），>1=更散
const BOARD_MODEL_SPREAD_V := 0.9  # 棋盘模型纵向铺开缩放（不动圆圈）：1=和圆圈一样，<1=往中间收（治上下越偏），>1=更散
# 待命区：横排 8 个，放在棋盘正下方（前景 v≈0.88，u 横跨 0.31~0.79）。
# 待命区 8 个格子的地面 UV 落点，参数化：改下面几个数就能整排调位置/间距/大小，
# 不用手编 8 个点。（格子和棋子模型都用这套值，改一处两个一起动。）
const STANDBY_SLOT_COUNT := 8
const STANDBY_ROW_V := 0.815        # 整排前后位置：0=远/靠上，1=近/靠下（越大越往屏幕下方）
const STANDBY_CENTER_U := 0.49     # 整排水平中心：0=左，1=右（整体左右移动改这个）
const STANDBY_STEP_U := 0.047      # 相邻两格的水平间距：越大越疏、越小越密
const STANDBY_SPOT_RADIUS := 0.16   # 每个格子圆的世界半径：越大格子越大
const STANDBY_MODEL_DX := 0.0   # 待命模型左右微调（不动圆圈）
const STANDBY_MODEL_DZ := -0.05  # 待命模型前后微调（不动圆圈）
const STANDBY_MODEL_SPREAD := 0.9  # 模型横向铺开缩放（不动圆圈）：1=和圆圈一样，<1=往中间收（治"越往两边越偏"），>1=更散
# 待命区背景平台：做成 3D 地面 quad（不是 2D 贴图），模型是地面上方的 3D 物体，自然盖在它上面。
const PREP_STANDBY_BG_PATH := "res://assets/board/prep_2_5d/standby_bg.png"
const PREP_STANDBY_BG_CENTER_UV := Vector2(0.49, 0.820)  # 平台中心 UV（默认对齐待命格子中心/前后）
const PREP_STANDBY_BG_WORLD_SIZE := Vector2(3.5, 1.58)     # 平台 quad 世界尺寸（宽 × 进深），可调
const PREP_STANDBY_BG_Y_LIFT := 0.006                     # 抬离地面高度（河流之上、模型之下）
const PREP_RIVER_VIEWPORT_SIZE := Vector2i(960, 540)
const PREP_RIVER_RENDER_HZ := 30.0  # 备战 3D 视口的渲染采样率（动画推进不受影响）
const PREP_RIVER_STAGE_SCALE := Vector3(3.5, 3.2, 3.2)
const PREP_RIVER_STAGE_POSITION := Vector3(0.5, 0.0, -0.5)
# ══════ 相机：整体拉近/拉远看（不改场地本身，只改观感）══════
const PREP_RIVER_CAMERA_POSITION := Vector3(0.0, 3.8, 2.0)    # 相机位置：y=高低俯角、z=远近
const PREP_RIVER_CAMERA_TARGET := Vector3(0.0, -0.07, -0.03)  # 相机看向的点（一般不动）
const PREP_RIVER_CAMERA_FOV := 44.0                           # 视野：小=拉近/放大，大=拉远/缩小
const PREP_MODEL_BASE_SCALE := 0.04

var _prep_model_root: Node3D
var _prep_standby_model_root: Node3D
var _prep_relation_link_root: Node3D
var _prep_river_viewport: SubViewport
var _prep_river_stage_root: Node3D
var _prep_river_camera: Camera3D
var _prep_board_frame: Control
var _prep_board_glow: CPUParticles2D
var _prep_standby_model_nodes: Dictionary = {}
var _prep_standby_model_signatures: Dictionary = {}
var _prep_river_background_ready := false
var _prep_board_model_nodes: Dictionary = {}
var _prep_board_model_signatures: Dictionary = {}
var _prep_relation_link_nodes: Dictionary = {}
var _prep_model_scene_cache: Dictionary = {}
var _prep_animation_scene_cache: Dictionary = {}
var _prep_layout_refresh_version := 0

func _on_prep_river_refresh_tick() -> void:
	if _prep_river_viewport != null and is_visible_in_tree():
		_prep_river_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func _setup_prep_river_background() -> void:
	var container := SubViewportContainer.new()
	container.name = "PrepRiverArenaLayer"
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.z_index = -19
	add_child(container)

	_prep_river_viewport = SubViewport.new()
	_prep_river_viewport.size = PREP_RIVER_VIEWPORT_SIZE
	# 透明：棋盘没盖到的角落露出后面的满屏 2D 背景（同一张 base 图，任何屏幕尺寸都铺满），不再露深色兜底
	_prep_river_viewport.transparent_bg = true
	# 手机上 UPDATE_ALWAYS 会让这块 3D 视口跟随主帧率全速重渲染（发热大户）。
	# 改为每次 UPDATE_ONCE 恰好渲染一帧，由下面的 30Hz Timer 重触发：
	# AnimationPlayer 照常每引擎帧推进，只是渲染采样降到 30Hz。
	_prep_river_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	container.add_child(_prep_river_viewport)

	var refresh_timer := Timer.new()
	refresh_timer.name = "PrepRiverRefreshTimer"
	refresh_timer.wait_time = 1.0 / PREP_RIVER_RENDER_HZ
	refresh_timer.autostart = true
	refresh_timer.timeout.connect(_on_prep_river_refresh_tick)
	container.add_child(refresh_timer)

	var world := Node3D.new()
	world.name = "PrepRiverArenaWorld"
	_prep_river_viewport.add_child(world)

	_prep_river_stage_root = Node3D.new()
	_prep_river_stage_root.name = "PrepRiverStageRoot"
	_prep_river_stage_root.position = PREP_RIVER_STAGE_POSITION
	_prep_river_stage_root.scale = Vector3.ONE * PREP_RIVER_STAGE_SCALE
	world.add_child(_prep_river_stage_root)
	# 不再加载 3D 河流场地；改用贴在平躺 quad 上的 2D 分层棋盘。
	# stage root 仍保留，用于在 3D 空间里定位三组棋子（主战/待命/佣兵）。
	_add_prep_art_layers(world)

	_prep_model_root = Node3D.new()
	_prep_model_root.name = "PrepBoardModelRoot"
	_prep_model_root.position = board_origin
	_prep_model_root.rotation_degrees = board_rotation
	_prep_model_root.scale = board_scale
	_prep_river_stage_root.add_child(_prep_model_root)

	_prep_standby_model_root = Node3D.new()
	_prep_standby_model_root.name = "PrepStandbyModelRoot"
	_prep_standby_model_root.position = board_origin + standby_origin
	_prep_standby_model_root.rotation_degrees = board_rotation + standby_rotation
	_prep_standby_model_root.scale = board_scale
	_prep_river_stage_root.add_child(_prep_standby_model_root)

	_prep_relation_link_root = Node3D.new()
	_prep_relation_link_root.name = "PrepRelationLinkRoot"
	_prep_relation_link_root.position = board_origin
	_prep_relation_link_root.rotation_degrees = board_rotation
	_prep_relation_link_root.scale = board_scale
	_prep_river_stage_root.add_child(_prep_relation_link_root)

	var key_light := DirectionalLight3D.new()
	key_light.name = "PrepRiverKeyLight"
	key_light.light_color = Color(1.0, 0.92, 0.76)
	key_light.light_energy = 0.64
	key_light.rotation_degrees = Vector3(-52.0, -28.0, 0.0)
	key_light.shadow_enabled = false
	world.add_child(key_light)

	var fill_light := DirectionalLight3D.new()
	fill_light.name = "PrepRiverFillLight"
	fill_light.light_color = Color(0.48, 0.68, 0.82)
	fill_light.light_energy = 0.18
	fill_light.rotation_degrees = Vector3(-38.0, 142.0, 0.0)
	fill_light.shadow_enabled = false
	world.add_child(fill_light)

	var ambient := WorldEnvironment.new()
	ambient.name = "PrepRiverEnvironment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.04, 0.07, 0.05)  # 深森林色兜底，杜绝天空
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.58, 0.68, 0.61)
	environment.ambient_light_energy = 0.40
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	ambient.environment = environment
	world.add_child(ambient)

	var camera := Camera3D.new()
	camera.name = "PrepRiverCamera"
	camera.fov = PREP_RIVER_CAMERA_FOV
	camera.look_at_from_position(PREP_RIVER_CAMERA_POSITION, PREP_RIVER_CAMERA_TARGET, Vector3.UP)
	camera.current = true
	world.add_child(camera)
	_prep_river_camera = camera

	_prep_river_background_ready = true

func _add_prep_art_layers(world: Node3D) -> void:
	# v4 横向竞技场，一层一层贴在平躺 3D 平面上（保留 2.5D 倾斜）
	_add_prep_texture_plane(world, "PrepBaseLayer", PREP_BOARD_BASE_PATH, 0.000, 0)
	# 下河流：黑底贴图，flow shader 键透明 + 横向滚动流动
	_add_prep_texture_plane(world, "PrepRiverBottomLayer", PREP_RIVER_BOTTOM_PATH, 0.002, 2)
	_add_prep_river_flow(world)
	# 主战场 4×4：每格一张站位图（3D 地面 quad）。发光环仍由代码画在上层。
	_add_prep_cell_marks(world)
	# 待命区背景平台：3D 地面 quad，模型是地面上方 3D 物体，自然盖在它上面（修好被 2D 背景压掉的问题）
	_add_prep_standby_bg_plane(world)
	# 氛围层：萤火虫/河面星光粒子
	_add_prep_ambient_particles(world)

func _add_prep_cell_marks(world: Node3D) -> void:
	# 16 个格子每格一张站位图，做成 3D 地面 quad（躺在地面上）。位置跟 BOARD_STONE_U/V 走，
	# 模型是地面上方的 3D 物体、靠深度盖在它上面（和之前待命台一个道理，不会被压掉）。
	var tex := ResourceLoader.load(PREP_CELL_MARK_PATH) as Texture2D
	if tex == null:
		push_warning("站位图加载失败：%s" % PREP_CELL_MARK_PATH)
		return
	var cols := GameConstants.BOARD_COLUMNS
	var rows := GameConstants.BOARD_ROWS
	for i in cols * rows:
		var col := i % cols
		var row := i / cols
		var u := lerpf(BOARD_STONE_U.x, BOARD_STONE_U.y, (float(col) + 0.5) / float(cols))
		var v := lerpf(BOARD_STONE_V.x, BOARD_STONE_V.y, (float(row) + 0.5) / float(rows))
		var layer := MeshInstance3D.new()
		layer.name = "PrepCellMark%d" % i
		var plane := PlaneMesh.new()
		plane.size = PREP_CELL_MARK_SIZE
		layer.mesh = plane
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = tex
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		mat.render_priority = 5
		layer.material_override = mat
		var pos := _board_plane_world_pos(u, v)
		pos.y = PREP_BOARD_GROUND_CENTER.y + PREP_CELL_MARK_Y_LIFT
		layer.position = pos
		world.add_child(layer)

func _add_prep_standby_bg_plane(world: Node3D) -> void:
	# 待命区背景做成 3D 地面 quad：躺在待命格子位置，被模型自然遮挡（模型在地面上方，深度更近）。
	var tex := ResourceLoader.load(PREP_STANDBY_BG_PATH) as Texture2D
	if tex == null:
		push_warning("待命区背景加载失败：%s" % PREP_STANDBY_BG_PATH)
		return
	var layer := MeshInstance3D.new()
	layer.name = "PrepStandbyBgLayer"
	var plane := PlaneMesh.new()
	plane.size = PREP_STANDBY_BG_WORLD_SIZE
	layer.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mat.render_priority = 7   # 在棋盘各贴图层(0-6)之上；模型是不透明 3D 物体，靠深度自然盖住它
	layer.material_override = mat
	var center := _board_plane_world_pos(PREP_STANDBY_BG_CENTER_UV.x, PREP_STANDBY_BG_CENTER_UV.y)
	center.y = PREP_BOARD_GROUND_CENTER.y + PREP_STANDBY_BG_Y_LIFT
	layer.position = center
	world.add_child(layer)

func _add_prep_texture_plane(world: Node3D, node_name: String, texture_path: String, y_lift: float, render_priority: int) -> void:
	var tex := ResourceLoader.load(texture_path) as Texture2D
	if tex == null:
		push_warning("Prep art layer failed to load: %s" % texture_path)
		return
	var layer := MeshInstance3D.new()
	layer.name = node_name
	var plane := PlaneMesh.new()
	plane.size = PREP_BOARD_GROUND_SIZE
	layer.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mat.render_priority = render_priority
	if PREP_BOARD_GROUND_FLIP_V:
		mat.uv1_scale = Vector3(1.0, -1.0, 1.0)
	layer.material_override = mat
	layer.position = PREP_BOARD_GROUND_CENTER + Vector3(0.0, y_lift, 0.0)
	world.add_child(layer)

func _add_prep_river_flow(world: Node3D) -> void:
	# 在棋盘上方叠两块流动波光 quad（上/下河流），横向滚动 + 呼吸发光
	var shader := ResourceLoader.load(PREP_RIVER_FLOW_SHADER) as Shader
	if shader == null:
		push_warning("河流流动 shader 加载失败：%s" % PREP_RIVER_FLOW_SHADER)
		return
	_add_one_river_flow_quad(world, "PrepRiverFlowBottom", PREP_RIVER_BOTTOM_EF_PATH, shader, 0.004, 4)

func _add_one_river_flow_quad(world: Node3D, node_name: String, ef_path: String, shader: Shader, y_lift: float, render_priority: int) -> void:
	var tex := ResourceLoader.load(ef_path) as Texture2D
	if tex == null:
		push_warning("河流高光图加载失败：%s" % ef_path)
		return
	var quad := MeshInstance3D.new()
	quad.name = node_name
	var plane := PlaneMesh.new()
	plane.size = PREP_BOARD_GROUND_SIZE
	quad.mesh = plane
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("river_tex", tex)
	var is_top := node_name == "PrepRiverFlowTop"
	# 流速提到肉眼明显（约为原来的 4 倍），波光更亮、水色偏青蓝
	mat.set_shader_parameter("flow_speed", 0.036 if is_top else 0.028)
	mat.set_shader_parameter("layer2_scale", 1.06)
	mat.set_shader_parameter("layer2_speed", 0.55 if is_top else 0.45)
	mat.set_shader_parameter("warp_amp", 0.006 if is_top else 0.005)
	mat.set_shader_parameter("bright", 1.12 if is_top else 0.92)
	mat.set_shader_parameter("alpha_gain", 1.30 if is_top else 1.00)
	mat.set_shader_parameter("tint", Vector3(0.80, 1.05, 1.22))
	mat.render_priority = render_priority
	quad.material_override = mat
	# 和棋盘同位置、略抬高避免 z-fighting（depth_draw_never 已基本免疫）
	quad.position = PREP_BOARD_GROUND_CENTER + Vector3(0.0, y_lift, 0.0)
	world.add_child(quad)

func _add_prep_ambient_particles(world: Node3D) -> void:
	# 魔法森林氛围：全场金色萤火虫缓慢飘浮 + 下河面青色星光闪烁
	var dot := _make_soft_dot_texture()
	var ground := PREP_BOARD_GROUND_CENTER
	world.add_child(_make_prep_drift_particles(
		"PrepFireflies", dot,
		ground + Vector3(0.0, 0.30, 0.0), Vector3(3.4, 0.26, 1.9),
		34, 7.0, Color(1.0, 0.85, 0.45), 0.5, 1.1, 0.05
	))
	var bottom_center := _board_plane_world_pos(0.5, 0.905) + Vector3(0.0, 0.05, 0.0)
	world.add_child(_make_prep_drift_particles(
		"PrepRiverSparkleBottom", dot,
		bottom_center, Vector3(3.2, 0.02, 0.22),
		26, 2.6, Color(0.55, 0.90, 1.0), 0.3, 0.8, 0.02
	))

func _make_prep_drift_particles(node_name: String, dot: Texture2D, center: Vector3, extents: Vector3, amount: int, lifetime: float, tint: Color, scale_min: float, scale_max: float, rise_speed: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.name = node_name
	p.amount = amount
	p.lifetime = lifetime
	p.preprocess = lifetime
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = extents
	p.direction = Vector3(0.0, 1.0, 0.0)
	p.spread = 180.0
	p.gravity = Vector3.ZERO
	p.initial_velocity_min = rise_speed * 0.4
	p.initial_velocity_max = rise_speed
	p.scale_amount_min = scale_min
	p.scale_amount_max = scale_max
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
	ramp.colors = PackedColorArray([
		Color(tint.r, tint.g, tint.b, 0.0),
		Color(tint.r, tint.g, tint.b, 0.85),
		Color(tint.r, tint.g, tint.b, 0.0),
	])
	p.color_ramp = ramp
	var quad := QuadMesh.new()
	quad.size = Vector2(0.06, 0.06)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.albedo_texture = dot
	mat.vertex_color_use_as_albedo = true
	mat.render_priority = 8
	quad.material = mat
	p.mesh = quad
	p.position = center
	return p

func _add_prep_river_layer(world: Node3D, node_name: String, texture_path: String, y_lift: float, render_priority: int) -> void:
	# 河流层：用流动 shader 让河水自身横移 + 波纹扭曲（blend_mix 替换、不叠加、不冲白）
	var tex := ResourceLoader.load(texture_path) as Texture2D
	if tex == null:
		push_warning("river texture load failed: %s" % texture_path)
		return
	var shader := ResourceLoader.load(PREP_RIVER_FLOW_SHADER) as Shader
	if shader == null:
		push_warning("river flow shader load failed, fallback to static: %s" % PREP_RIVER_FLOW_SHADER)
		_add_prep_texture_plane(world, node_name, texture_path, y_lift, render_priority)
		return
	var layer := MeshInstance3D.new()
	layer.name = node_name
	var plane := PlaneMesh.new()
	plane.size = PREP_BOARD_GROUND_SIZE
	layer.mesh = plane
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("river_tex", tex)
	mat.render_priority = render_priority
	layer.material_override = mat
	if PREP_BOARD_GROUND_FLIP_V:
		layer.scale = Vector3(1.0, 1.0, -1.0)
	layer.position = PREP_BOARD_GROUND_CENTER + Vector3(0.0, y_lift, 0.0)
	world.add_child(layer)

func _has_prep_river_background() -> bool:
	return _prep_river_background_ready

func _apply_prep_river_material(root: Node) -> void:
	var material := ResourceLoader.load(PREP_RIVER_MATERIAL_PATH) as Material
	if material == null:
		push_warning("准备界面河流材质加载失败：%s" % PREP_RIVER_MATERIAL_PATH)
		return
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			var mesh_node := node as MeshInstance3D
			var surface_count := mesh_node.mesh.get_surface_count() if mesh_node.mesh != null else 0
			for surface_index in surface_count:
				mesh_node.set_surface_override_material(surface_index, material)
		for child in node.get_children():
			stack.append(child)

func _setup_prep_board_model_view(board_frame: Control) -> void:
	# Board models now share the river arena viewport, camera, lights and depth.
	_prep_board_frame = board_frame
	if not board_frame.resized.is_connected(_queue_prep_model_layout_refresh):
		board_frame.resized.connect(_queue_prep_model_layout_refresh)
	if _standby_frame != null and not _standby_frame.resized.is_connected(_queue_prep_model_layout_refresh):
		_standby_frame.resized.connect(_queue_prep_model_layout_refresh)
	if not resized.is_connected(_queue_prep_model_layout_refresh):
		resized.connect(_queue_prep_model_layout_refresh)
	_queue_prep_model_layout_refresh()

func _queue_prep_model_layout_refresh() -> void:
	_prep_layout_refresh_version += 1
	if _prep_model_root != null:
		_prep_model_root.visible = false
	if _prep_standby_model_root != null:
		_prep_standby_model_root.visible = false
	_apply_prep_model_layout_after_frames.call_deferred(_prep_layout_refresh_version)

func _apply_prep_model_layout_after_frames(version: int) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if version != _prep_layout_refresh_version or not is_inside_tree():
		return
	_reposition_existing_prep_models()
	_realign_prep_board_cells()
	_realign_prep_standby_cells()
	_update_prep_board_glow()
	if _prep_model_root != null:
		_prep_model_root.visible = true
	if _prep_standby_model_root != null:
		_prep_standby_model_root.visible = true

func _reposition_existing_prep_models() -> void:
	for key in _prep_board_model_nodes.keys():
		var index := int(key)
		if index < 0 or index >= GameState.board_slots.size():
			continue
		var cell_value = GameState.board_slots[index]
		if typeof(cell_value) != TYPE_DICTIONARY:
			continue
		var model_node := _prep_board_model_nodes.get(key) as Node3D
		if model_node != null:
			_position_prep_board_model(model_node, index, _prep_display_unit_def(cell_value as Dictionary))
	for key in _prep_standby_model_nodes.keys():
		var index := int(key)
		if index < 0 or index >= GameState.bench_slots.size():
			continue
		var cell_value = GameState.bench_slots[index]
		if typeof(cell_value) != TYPE_DICTIONARY:
			continue
		var model_node := _prep_standby_model_nodes.get(key) as Node3D
		if model_node != null:
			_position_prep_standby_model(model_node, index, _prep_display_unit_def(cell_value as Dictionary))
	_refresh_prep_relation_links()

func _refresh_prep_board_models() -> void:
	if _prep_model_root == null:
		return
	var active_slots: Dictionary = {}
	for index in GameState.board_slots.size():
		var cell_value = GameState.board_slots[index]
		if typeof(cell_value) != TYPE_DICTIONARY:
			continue
		var cell: Dictionary = cell_value
		var unit_def := _prep_display_unit_def(cell)
		var model_path := str(unit_def.get("model", ""))
		if not _prep_model_path_available(model_path):
			continue
		var signature := "%s|%s|%s|%d" % [
			str(cell.get("id", unit_def.get("id", ""))),
			model_path,
			str(unit_def.get("element", "")),
			int(cell.get("star", 1)),
		]
		active_slots[index] = true
		var existing := _prep_board_model_nodes.get(index) as Node3D
		if existing == null or str(_prep_board_model_signatures.get(index, "")) != signature:
			if existing != null:
				existing.queue_free()
			_prep_board_model_nodes.erase(index)
			_prep_board_model_signatures.erase(index)
			var model_node := _make_prep_board_model(cell, unit_def)
			if model_node != null:
				_prep_model_root.add_child(model_node)
				_prep_board_model_nodes[index] = model_node
				_prep_board_model_signatures[index] = signature
				existing = model_node
		if existing != null:
			_position_prep_board_model(existing, index, unit_def)
			_request_prep_model_anchor_update(existing)
			_update_prep_relation_particles(existing, cell)

	for key in _prep_board_model_nodes.keys():
		if active_slots.has(key):
			continue
		var stale := _prep_board_model_nodes.get(key) as Node3D
		if stale != null:
			stale.queue_free()
		_prep_board_model_nodes.erase(key)
		_prep_board_model_signatures.erase(key)
	_refresh_prep_relation_links()

func _refresh_prep_standby_models() -> void:
	if _prep_standby_model_root == null:
		return
	var active_slots: Dictionary = {}
	for index in mini(GameState.bench_slots.size(), STANDBY_SLOT_COUNT):
		var cell_value = GameState.bench_slots[index]
		if typeof(cell_value) != TYPE_DICTIONARY:
			continue
		var cell: Dictionary = cell_value
		var unit_def := _prep_display_unit_def(cell)
		var model_path := str(unit_def.get("model", ""))
		if not _prep_model_path_available(model_path):
			continue
		var signature := "%s|%s|%s|%d" % [
			str(cell.get("id", unit_def.get("id", ""))),
			model_path,
			str(unit_def.get("element", "")),
			int(cell.get("star", 1)),
		]
		active_slots[index] = true
		var existing := _prep_standby_model_nodes.get(index) as Node3D
		if existing == null or str(_prep_standby_model_signatures.get(index, "")) != signature:
			if existing != null:
				existing.queue_free()
			_prep_standby_model_nodes.erase(index)
			_prep_standby_model_signatures.erase(index)
			var model_node := _make_prep_board_model(cell, unit_def)
			if model_node != null:
				model_node.name = "PrepStandby_%s" % str(cell.get("id", "unit"))
				_prep_standby_model_root.add_child(model_node)
				_prep_standby_model_nodes[index] = model_node
				_prep_standby_model_signatures[index] = signature
				existing = model_node
		if existing != null:
			_position_prep_standby_model(existing, index, unit_def)
			_request_prep_model_anchor_update(existing)

	for key in _prep_standby_model_nodes.keys():
		if active_slots.has(key):
			continue
		var stale := _prep_standby_model_nodes.get(key) as Node3D
		if stale != null:
			stale.queue_free()
		_prep_standby_model_nodes.erase(key)
		_prep_standby_model_signatures.erase(key)

func _request_prep_model_anchor_update(model_node: Node3D) -> void:
	if bool(model_node.get_meta("prep_anchor_update_pending", false)):
		return
	model_node.set_meta("prep_anchor_update_pending", true)
	_update_prep_model_anchors.call_deferred(model_node, 0)

func _update_prep_model_anchors(model_node: Node3D, attempt: int) -> void:
	if not is_instance_valid(model_node):
		return
	var visual_path := NodePath(str(model_node.get_meta("prep_visual_root", "")))
	var visual_root := model_node.get_node_or_null(visual_path) as Node3D
	if visual_root == null:
		model_node.set_meta("prep_anchor_update_pending", false)
		return
	if not bool(model_node.get_meta("prep_model_centered", false)):
		_center_prep_model(visual_root)
		model_node.set_meta("prep_model_centered", true)
	var bounds := _prep_node3d_bounds(visual_root)
	if bounds.size.y <= 0.001:
		if attempt < 4:
			get_tree().process_frame.connect(
				_update_prep_model_anchors.bind(model_node, attempt + 1),
				CONNECT_ONE_SHOT
			)
		else:
			model_node.set_meta("prep_anchor_update_pending", false)
		return
	_position_prep_foot_star(model_node)
	# 名字放到头顶：居中后脚在 pivot 原点，头约在本地高度 bounds.size.y，再抬高一点。
	var head_anchor := model_node.get_node_or_null("HeadNameAnchor3D") as Node3D
	if head_anchor != null:
		head_anchor.position = Vector3(0.0, bounds.size.y * 1.06, -0.56)
	_configure_prep_contact_shadow(model_node)
	model_node.set_meta("relation_waist_height", bounds.size.y * 0.52)
	model_node.set_meta("prep_anchor_update_pending", false)

func _make_prep_board_model(cell: Dictionary, unit_def: Dictionary) -> Node3D:
	var model_path := str(unit_def.get("model", ""))
	var scene := _prep_model_scene_for_path(model_path)
	if scene == null:
		return null
	var instance := scene.instantiate()
	if not (instance is Node3D):
		instance.queue_free()
		return null
	var model := instance as Node3D
	# 摆放界面永远只播 idle：*Animated 场景看到这个标记后跳过 attack/run 两份 FBX。
	model.set_meta("load_idle_only", true)
	var pivot := Node3D.new()
	pivot.name = "PrepModel_%s" % str(cell.get("id", "unit"))
	var visual_scale := float(unit_def.get("model_visual_scale", 1.0))
	model.scale = Vector3.ONE * visual_scale
	model.rotation_degrees = Vector3.ZERO
	pivot.add_child(model)
	var prep_scale_factor := 1.4 if int(unit_def.get("tier", 1)) >= 3 else 1.2
	pivot.scale = Vector3.ONE * PREP_MODEL_BASE_SCALE * prep_scale_factor
	pivot.set_meta("prep_visual_root", NodePath(model.name))
	pivot.set_meta("relation_waist_height", _prep_board_model_target_size() * 0.52)
	# Prep models are enlarged 20%; epic (tier 3) units 40%.
	_add_prep_contact_shadow(pivot)
	var star_anchor := Node3D.new()
	star_anchor.name = "FootStarAnchor3D"
	pivot.add_child(star_anchor)
	# 名字标签挂在独立的「头顶锚点」上（脚部星星仍在 FootStarAnchor3D），
	# 位置按模型实际高度移到头顶上方。
	var head_anchor := Node3D.new()
	head_anchor.name = "HeadNameAnchor3D"
	pivot.add_child(head_anchor)
	var name_label := Label3D.new()
	name_label.name = "NameLabel3D"
	var display_name := str(unit_def.get("name", cell.get("id", "")))
	if LocaleManager.get_locale() == "en":
		var english_name := str(unit_def.get("name_en", ""))
		if not english_name.is_empty():
			display_name = english_name
	name_label.text = display_name
	name_label.font_size = 44
	name_label.outline_size = 0
	name_label.modulate = Color.WHITE
	name_label.outline_modulate = Color.TRANSPARENT
	name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name_label.fixed_size = true
	name_label.no_depth_test = true
	name_label.pixel_size = 0.0024
	name_label.render_priority = 126
	name_label.outline_render_priority = 127
	name_label.offset = Vector2(0.0, -16.0)
	head_anchor.add_child(name_label)
	var star_label := Label3D.new()
	star_label.name = "StarLabel3D"
	star_label.text = "\u2605".repeat(clampi(int(cell.get("star", 1)), 1, GameState.MAX_UNIT_STAR))
	star_label.font_size = 60
	star_label.outline_size = 0
	star_label.modulate = Color(1.0, 0.82, 0.20)
	star_label.outline_modulate = Color.TRANSPARENT
	star_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	star_label.fixed_size = true
	star_label.no_depth_test = true
	star_label.pixel_size = 0.0030
	star_label.render_priority = 126
	star_label.outline_render_priority = 127
	star_label.offset = Vector2(0.0, 20.0)
	star_anchor.add_child(star_label)
	_play_prep_model_idle(model, unit_def)
	return pivot

func _add_prep_contact_shadow(pivot: Node3D) -> void:
	var shadow_mesh := PlaneMesh.new()
	shadow_mesh.size = Vector2.ONE
	var shadow_shader := Shader.new()
	shadow_shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

void fragment() {
	vec2 point = (UV - vec2(0.5)) * 2.0;
	float distance_squared = dot(point, point);
	ALBEDO = vec3(0.015, 0.02, 0.018);
	ALPHA = (1.0 - smoothstep(0.10, 1.0, distance_squared)) * 0.46;
}
"""
	var shadow_material := ShaderMaterial.new()
	shadow_material.shader = shadow_shader
	shadow_mesh.material = shadow_material
	var shadow := MeshInstance3D.new()
	shadow.name = "ContactShadow3D"
	shadow.mesh = shadow_mesh
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pivot.add_child(shadow)

func _position_prep_foot_star(model_node: Node3D) -> void:
	var visual_path := NodePath(str(model_node.get_meta("prep_visual_root", "")))
	var visual_root := model_node.get_node_or_null(visual_path) as Node3D
	if visual_root == null:
		return
	var star_anchor := model_node.get_node_or_null("FootStarAnchor3D") as Node3D
	if star_anchor == null:
		star_anchor = visual_root.get_node_or_null("FootStarAnchor3D") as Node3D
	if star_anchor == null:
		return
	var target_in_pivot := Vector3(0.0, 0.14, -0.56)
	if star_anchor.get_parent() == model_node:
		star_anchor.position = target_in_pivot
	else:
		star_anchor.position = visual_root.transform.affine_inverse() * target_in_pivot

func _configure_prep_contact_shadow(model_node: Node3D) -> void:
	var shadow := model_node.get_node_or_null("ContactShadow3D") as MeshInstance3D
	if shadow == null:
		return
	var shadow_mesh := shadow.mesh as PlaneMesh
	if shadow_mesh == null:
		return
	shadow_mesh.size = Vector2(1.2, 0.7)
	shadow.position = Vector3(0.0, 0.08, -0.56)

# 3D 世界点 → 主屏幕像素坐标（穿过 river 相机投影，再映射到全屏）
func _world_to_main_screen(world: Vector3) -> Vector2:
	var vp := _prep_river_camera.unproject_position(world)
	var main_size := get_viewport().get_visible_rect().size
	var river_size := Vector2(_prep_river_viewport.size)
	if river_size.x <= 0.0 or river_size.y <= 0.0:
		return vp
	return Vector2(vp.x / river_size.x * main_size.x, vp.y / river_size.y * main_size.y)

# 在 3D 地面上以 (u,v) 为圆心画一个真圆，投影到屏幕得到椭圆点集（跟着斜面）
func _plane_circle_screen_pts(u_center: float, v_center: float, world_radius: float) -> PackedVector2Array:
	var ru := world_radius / PREP_BOARD_GROUND_SIZE.x   # 世界半径换算成 U 方向占比
	var rv := world_radius / PREP_BOARD_GROUND_SIZE.y   # 换算成 V 方向占比
	var pts := PackedVector2Array()
	for i in BOARD_CELL_SEGMENTS:
		var a := TAU * float(i) / float(BOARD_CELL_SEGMENTS)
		var u := u_center + cos(a) * ru
		var v := v_center + sin(a) * rv
		pts.append(_world_to_main_screen(_board_plane_world_pos(u, v)))
	return pts

# 把某个 UI 卡片用一组屏幕点配置成多边形（圆/椭圆），并定位
func _fit_cell_to_screen_polygon(child: Object, screen_pts: PackedVector2Array, origin: Vector2) -> void:
	var pts := PackedVector2Array()
	for p in screen_pts:
		pts.append(p - origin)
	var bounds := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		bounds = bounds.expand(p)
	child.position = bounds.position
	child.size = bounds.size
	child.custom_minimum_size = bounds.size
	var local := PackedVector2Array()
	for p in pts:
		local.append(p - bounds.position)
	child.configure_polygon(local)

# 把 16 个主战格子用 3D 投影对齐到石台上，画成跟着斜面的椭圆圆圈
func _realign_prep_board_cells() -> void:
	if _board_grid == null or _prep_river_camera == null or _prep_river_viewport == null:
		return
	if not _board_grid.is_inside_tree():
		return
	var grid_origin := _board_grid.global_position
	var cols := GameConstants.BOARD_COLUMNS
	var rows := GameConstants.BOARD_ROWS
	for child in _board_grid.get_children():
		if not (child.has_method("configure_polygon") and "board_index" in child):
			continue
		var idx: int = int(child.board_index)
		if idx < 0 or idx >= cols * rows:
			continue
		var col := idx % cols
		var row := idx / cols
		# Placement stays 4x4, but the visible guide is the glowing circle on each slot.
		var u := lerpf(BOARD_STONE_U.x, BOARD_STONE_U.y, (float(col) + 0.5) / float(cols))
		var v := lerpf(BOARD_STONE_V.x, BOARD_STONE_V.y, (float(row) + 0.5) / float(rows))
		_fit_cell_to_screen_polygon(child, _plane_circle_screen_pts(u, v, BOARD_CELL_RADIUS), grid_origin)

# 把 8 个待命卡片用 3D 投影散落到左草地，画成跟着斜面的椭圆圆圈
func _realign_prep_standby_cells() -> void:
	if _standby_frame == null or _prep_river_camera == null or _prep_river_viewport == null:
		return
	if not _standby_frame.is_inside_tree():
		return
	var origin := _standby_frame.global_position
	for child in _standby_frame.get_children():
		if not (child.has_method("configure_polygon") and "bench_index" in child):
			continue
		var idx: int = int(child.bench_index)
		if idx < 0 or idx >= STANDBY_SLOT_COUNT:
			continue
		var spot: Vector2 = _standby_spot(idx)
		_fit_cell_to_screen_polygon(child, _plane_circle_screen_pts(spot.x, spot.y, STANDBY_SPOT_RADIUS), origin)

# ── 石台四周蓝光粒子 ─────────────────────────────────────────────
func _make_soft_dot_texture() -> ImageTexture:
	var s := 32
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var c := Vector2(float(s) * 0.5, float(s) * 0.5)
	for y in s:
		for x in s:
			var d := Vector2(float(x) + 0.5, float(y) + 0.5).distance_to(c) / (float(s) * 0.5)
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)

func _ensure_prep_board_glow() -> void:
	if _prep_board_glow != null and is_instance_valid(_prep_board_glow):
		return
	var p := CPUParticles2D.new()
	p.name = "PrepBoardGlow"
	p.amount = 90
	p.lifetime = 2.4
	p.preprocess = 1.2
	p.texture = _make_soft_dot_texture()
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_POINTS
	p.direction = Vector2(0.0, -1.0)
	p.spread = 30.0
	p.gravity = Vector2(0.0, -16.0)
	p.initial_velocity_min = 5.0
	p.initial_velocity_max = 15.0
	p.scale_amount_min = 0.35
	p.scale_amount_max = 0.9
	p.color = Color(0.45, 0.72, 1.0, 1.0)
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
	ramp.colors = PackedColorArray([
		Color(0.45, 0.72, 1.0, 0.0),
		Color(0.55, 0.82, 1.0, 0.9),
		Color(0.40, 0.66, 1.0, 0.0),
	])
	p.color_ramp = ramp
	var cmat := CanvasItemMaterial.new()
	cmat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	p.material = cmat
	p.z_index = -5
	add_child(p)
	_prep_board_glow = p

func _update_prep_board_glow() -> void:
	if _prep_river_camera == null or _prep_river_viewport == null or not is_inside_tree():
		return
	_ensure_prep_board_glow()
	# 沿石台 4 条边采样发光点（self-local 坐标）
	var origin := global_position
	var n := 14
	var su0 := BOARD_STONE_U.x
	var su1 := BOARD_STONE_U.y
	var sv0 := BOARD_STONE_V.x
	var sv1 := BOARD_STONE_V.y
	var pts := PackedVector2Array()
	for i in n:
		var t := float(i) / float(n - 1)
		pts.append(_world_to_main_screen(_board_plane_world_pos(lerpf(su0, su1, t), sv0)) - origin)
		pts.append(_world_to_main_screen(_board_plane_world_pos(lerpf(su0, su1, t), sv1)) - origin)
		pts.append(_world_to_main_screen(_board_plane_world_pos(su0, lerpf(sv0, sv1, t))) - origin)
		pts.append(_world_to_main_screen(_board_plane_world_pos(su1, lerpf(sv0, sv1, t))) - origin)
	_prep_board_glow.emission_points = pts
	_prep_board_glow.emitting = true

# 把棋盘图的 UV 坐标映射到 3D 平躺地面 quad 上的世界坐标
func _board_plane_world_pos(u: float, v: float) -> Vector3:
	var sx := PREP_BOARD_GROUND_SIZE.x
	var sz := PREP_BOARD_GROUND_SIZE.y
	var c := PREP_BOARD_GROUND_CENTER
	# U=0→左(-X)，V=0→图上方=远端(-Z)
	return Vector3(c.x - sx * 0.5 + u * sx, c.y, c.z - sz * 0.5 + v * sz)

func _position_prep_board_model(model_node: Node3D, index: int, unit_def: Dictionary) -> void:
	# 直接按石台 UV 区域把 16 格落到 3D 平面上（确定性，不靠 2D 投影）
	var column := index % GameConstants.BOARD_COLUMNS
	var row := floori(float(index) / float(GameConstants.BOARD_COLUMNS))
	var u := lerpf(BOARD_STONE_U.x, BOARD_STONE_U.y, (float(column) + 0.5) / float(GameConstants.BOARD_COLUMNS))
	var v := lerpf(BOARD_STONE_V.x, BOARD_STONE_V.y, (float(row) + 0.65) / float(GameConstants.BOARD_ROWS))
	# 模型"离棋盘中心的横/纵距离"按 SPREAD 缩放（圆圈不受影响）：治"中间对齐、越往边越偏"。
	var center_u := (BOARD_STONE_U.x + BOARD_STONE_U.y) * 0.5
	var center_v := (BOARD_STONE_V.x + BOARD_STONE_V.y) * 0.5
	u = center_u + (u - center_u) * BOARD_MODEL_SPREAD_U
	v = center_v + (v - center_v) * BOARD_MODEL_SPREAD_V
	var world_pos := _board_plane_world_pos(u, v)
	if _prep_model_root != null and _prep_model_root.is_inside_tree():
		model_node.position = _prep_model_root.to_local(world_pos)
	model_node.position.y = unit_y_offset
	model_node.rotation_degrees = Vector3(0.0, float(unit_def.get("model_base_yaw", 180.0)), 0.0)

func _prep_board_projected_ground_position(index: int) -> Variant:
	if _prep_board_frame == null or _prep_river_camera == null or _prep_river_viewport == null or _prep_model_root == null:
		return null
	if not _prep_board_frame.is_inside_tree() or not _prep_model_root.is_inside_tree():
		return null
	var quad := _board_cell_quad(index, _prep_board_frame.size)
	if quad.size() != 4:
		return null
	var screen_center := (quad[0] + quad[1] + quad[2] + quad[3]) * 0.25
	var quad_bounds := Rect2(quad[0], Vector2.ZERO)
	for point in quad:
		quad_bounds = quad_bounds.expand(point)
	screen_center += quad_bounds.size * unit_cell_anchor_offset
	screen_center += _prep_board_frame.global_position
	var main_viewport_size := get_viewport().get_visible_rect().size
	if main_viewport_size.x <= 0.0 or main_viewport_size.y <= 0.0:
		return null
	var river_viewport_size := Vector2(_prep_river_viewport.size)
	var river_point := Vector2(
		screen_center.x / main_viewport_size.x * river_viewport_size.x,
		screen_center.y / main_viewport_size.y * river_viewport_size.y
	)
	var ray_origin := _prep_river_camera.project_ray_origin(river_point)
	var ray_direction := _prep_river_camera.project_ray_normal(river_point)
	var plane_origin := _prep_model_root.to_global(Vector3(0.0, unit_y_offset, 0.0))
	var plane_normal := _prep_model_root.global_transform.basis.y.normalized()
	var ground_plane := Plane(plane_normal, plane_origin)
	var hit = ground_plane.intersects_ray(ray_origin, ray_direction)
	if hit == null:
		return null
	var local_hit := _prep_model_root.to_local(hit)
	local_hit.y = unit_y_offset
	return local_hit

func _standby_spot(index: int) -> Vector2:
	# 按参数算第 index 个待命格子的地面 UV 落点（整排水平居中于 STANDBY_CENTER_U）。
	var mid := float(STANDBY_SLOT_COUNT - 1) * 0.5
	return Vector2(STANDBY_CENTER_U + (float(index) - mid) * STANDBY_STEP_U, STANDBY_ROW_V)

func _position_prep_standby_model(model_node: Node3D, index: int, unit_def: Dictionary) -> void:
	# 落到待命区参数化落点上（和待命圆圈重合）
	if index >= 0 and index < STANDBY_SLOT_COUNT and _prep_standby_model_root != null and _prep_standby_model_root.is_inside_tree():
		var spot: Vector2 = _standby_spot(index)
		var world_pos := _board_plane_world_pos(spot.x, spot.y)
		# 模型"离整排中心的横向距离"按 SPREAD 缩放（圆圈不受影响）：治"中间对齐、越往两边越偏"。
		var center_wx := _board_plane_world_pos(STANDBY_CENTER_U, spot.y).x
		world_pos.x = center_wx + (world_pos.x - center_wx) * STANDBY_MODEL_SPREAD
		world_pos.x += STANDBY_MODEL_DX   # 微调左右：正=右移
		world_pos.z += STANDBY_MODEL_DZ   # 微调前后：正=近/下移，负=远/上移
		model_node.position = _prep_standby_model_root.to_local(world_pos)
		model_node.position.y = standby_unit_y_offset
	if standby_face_battlefield and _prep_model_root != null:
		var battlefield_center := _prep_standby_model_root.to_local(_prep_model_root.to_global(Vector3.ZERO))
		battlefield_center.y = model_node.position.y
		if model_node.position.distance_squared_to(battlefield_center) > 0.0001:
			model_node.look_at(battlefield_center, Vector3.UP)
			model_node.rotate_y(deg_to_rad(float(unit_def.get("model_base_yaw", 180.0)) + standby_facing_yaw_offset))
	else:
		model_node.rotation_degrees = Vector3(
			0.0,
			float(unit_def.get("model_base_yaw", 180.0)) + standby_facing_yaw_offset,
			0.0
		)

func _prep_board_model_target_size() -> float:
	return minf(board_cell_spacing.x, board_cell_spacing.y) * unit_visual_scale

func _prep_standby_model_target_size() -> float:
	return minf(board_cell_spacing.x, board_cell_spacing.y) * standby_unit_scale

func _update_prep_relation_particles(model_node: Node3D, cell: Dictionary) -> void:
	var friendly_progress := 0
	var hostile_progress := 0
	for state_value in RaceRelationService.visual_states_for_cell(cell):
		if typeof(state_value) != TYPE_DICTIONARY:
			continue
		var state: Dictionary = state_value
		var progress := clampi(int(state.get("progress", 0)), 0, RaceRelationService.MAX_PROGRESS)
		if str(state.get("kind", "")) == "friendly":
			friendly_progress = maxi(friendly_progress, progress)
		elif str(state.get("kind", "")) == "hostile":
			hostile_progress = maxi(hostile_progress, progress)
	_configure_prep_relation_particles(
		model_node,
		"FriendlyRelationParticles3D",
		friendly_progress,
		Color(1.0, 0.78, 0.18),
		1.0
	)
	_configure_prep_relation_particles(
		model_node,
		"HostileRelationParticles3D",
		hostile_progress,
		Color(0.24, 0.27, 0.32),
		0.92
	)

func _configure_prep_relation_particles(
	model_node: Node3D,
	node_name: String,
	progress: int,
	color: Color,
	radius_scale: float
) -> void:
	var particles := model_node.get_node_or_null(node_name) as Node3D
	if particles == null and progress > 0:
		particles = PREP_RELATION_PARTICLES_SCRIPT.new() as Node3D
		particles.name = node_name
		model_node.add_child(particles)
	if particles != null:
		particles.call("configure", progress, color, radius_scale)

func _refresh_prep_relation_links() -> void:
	if _prep_relation_link_root == null:
		return
	var active_links: Dictionary = {}
	for first_index in GameState.board_slots.size():
		var first_value = GameState.board_slots[first_index]
		if typeof(first_value) != TYPE_DICTIONARY or not _prep_board_model_nodes.has(first_index):
			continue
		var neighbor_indices: Array[int] = []
		if first_index % GameConstants.BOARD_COLUMNS < GameConstants.BOARD_COLUMNS - 1 and first_index + 1 < GameState.board_slots.size():
			neighbor_indices.append(first_index + 1)
		if first_index + GameConstants.BOARD_COLUMNS < GameState.board_slots.size():
			neighbor_indices.append(first_index + GameConstants.BOARD_COLUMNS)
		for second_index in neighbor_indices:
			var second_value = GameState.board_slots[second_index]
			if typeof(second_value) != TYPE_DICTIONARY or not _prep_board_model_nodes.has(second_index):
				continue
			var relation_states := _active_relation_states_between(first_value as Dictionary, second_value as Dictionary)
			for state_value in relation_states:
				var state: Dictionary = state_value
				var pair := str(state.get("pair", ""))
				var kind := str(state.get("kind", ""))
				var link_key := "%d:%d:%s" % [first_index, second_index, pair]
				active_links[link_key] = true
				var link := _prep_relation_link_nodes.get(link_key) as Node3D
				if link == null:
					link = PREP_RELATION_LINK_SCRIPT.new() as Node3D
					link.name = "RelationLink_%s" % link_key.replace(":", "_").replace("|", "_")
					_prep_relation_link_root.add_child(link)
					_prep_relation_link_nodes[link_key] = link
				var first_model := _prep_board_model_nodes[first_index] as Node3D
				var second_model := _prep_board_model_nodes[second_index] as Node3D
				var start_point := first_model.position + Vector3.UP * float(first_model.get_meta("relation_waist_height", 0.78))
				var end_point := second_model.position + Vector3.UP * float(second_model.get_meta("relation_waist_height", 0.78))
				var color := Color(1.0, 0.78, 0.18) if kind == "friendly" else Color(0.24, 0.27, 0.32)
				link.call("configure", start_point, end_point, color)
	for key in _prep_relation_link_nodes.keys():
		if active_links.has(key):
			continue
		var stale_link := _prep_relation_link_nodes.get(key) as Node3D
		if stale_link != null:
			stale_link.queue_free()
		_prep_relation_link_nodes.erase(key)

func _active_relation_states_between(first: Dictionary, second: Dictionary) -> Array:
	var out: Array = []
	var first_race := _prep_cell_race(first)
	var second_race := _prep_cell_race(second)
	if first_race.is_empty() or second_race.is_empty() or first_race == second_race:
		return out
	var second_relations: Dictionary = second.get("race_relations", {})
	for state_value in RaceRelationService.visual_states_for_cell(first):
		if typeof(state_value) != TYPE_DICTIONARY:
			continue
		var state: Dictionary = state_value
		var pair := str(state.get("pair", ""))
		var parts := pair.split("|")
		if parts.size() != 2:
			continue
		var races_match := (
			(first_race == str(parts[0]) and second_race == str(parts[1]))
			or (first_race == str(parts[1]) and second_race == str(parts[0]))
		)
		if not races_match or int(state.get("progress", 0)) < RaceRelationService.MAX_PROGRESS or not bool(state.get("active", false)):
			continue
		var second_state_value = second_relations.get(pair, {})
		if typeof(second_state_value) != TYPE_DICTIONARY or not bool((second_state_value as Dictionary).get("active", false)):
			continue
		out.append(state)
	return out

func _prep_cell_race(cell: Dictionary) -> String:
	if bool(cell.get("is_mercenary", false)):
		return ""
	return str(cell.get("def", {}).get("race", ""))

func _play_prep_model_idle(model: Node3D, unit_def: Dictionary) -> void:
	if model.has_method("play_idle"):
		model.call_deferred("play_idle")
		return
	var players := _find_prep_animation_players(model)
	if players.is_empty():
		return
	var player := _select_prep_animation_player(players, unit_def)
	if player == null:
		return
	var idle_name := str(unit_def.get("model_idle_animation_name", ""))
	var idle_source_path := str(unit_def.get("model_idle_animation", ""))
	if not idle_source_path.is_empty():
		_add_prep_idle_animation(player, idle_source_path, idle_name)
		idle_name = "idle"
	elif idle_name.is_empty():
		idle_name = "idle"
	if not player.has_animation(idle_name):
		return
	var idle_animation := player.get_animation(idle_name)
	if idle_animation != null:
		idle_animation.loop_mode = Animation.LOOP_LINEAR
	player.play(idle_name)

func _add_prep_idle_animation(player: AnimationPlayer, scene_path: String, source_name: String) -> void:
	if player.has_animation("idle"):
		return
	var source_scene := _prep_animation_scene_for_path(scene_path)
	if source_scene == null:
		return
	var source_root := source_scene.instantiate()
	var source_players := _find_prep_animation_players(source_root)
	for source_player in source_players:
		var animation_name := source_name
		if animation_name.is_empty() or not source_player.has_animation(animation_name):
			animation_name = _first_prep_animation_name(source_player)
		if animation_name.is_empty() or not source_player.has_animation(animation_name):
			continue
		var animation := source_player.get_animation(animation_name).duplicate(true) as Animation
		animation.loop_mode = Animation.LOOP_LINEAR
		var library := player.get_animation_library("")
		if library == null:
			library = AnimationLibrary.new()
			player.add_animation_library("", library)
		library.add_animation("idle", animation)
		break
	source_root.queue_free()

func _select_prep_animation_player(players: Array[AnimationPlayer], unit_def: Dictionary) -> AnimationPlayer:
	if players.is_empty():
		return null
	var desired := [
		str(unit_def.get("model_idle_animation_name", "")),
		"idle",
		str(unit_def.get("model_attack_animation_name", "")),
		str(unit_def.get("model_run_animation_name", "")),
	]
	var best := players[0]
	var best_score := -1
	for player in players:
		var score := 0
		for animation_name in desired:
			if not str(animation_name).is_empty() and player.has_animation(str(animation_name)):
				score += 1
		if score > best_score:
			best = player
			best_score = score
	return best

func _find_prep_animation_players(root: Node) -> Array[AnimationPlayer]:
	var out: Array[AnimationPlayer] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is AnimationPlayer:
			out.append(node as AnimationPlayer)
		for child in node.get_children():
			stack.append(child)
	return out

func _first_prep_animation_name(player: AnimationPlayer) -> String:
	var names := player.get_animation_list()
	for animation_name in names:
		if str(animation_name) != "RESET":
			return str(animation_name)
	return ""

func _prep_model_scene_for_path(model_path: String) -> PackedScene:
	if _prep_model_scene_cache.has(model_path):
		return _prep_model_scene_cache[model_path] as PackedScene
	var loaded := ResourceLoader.load(model_path)
	if loaded is PackedScene:
		_prep_model_scene_cache[model_path] = loaded
		return loaded as PackedScene
	return null

func _prep_animation_scene_for_path(scene_path: String) -> PackedScene:
	if _prep_animation_scene_cache.has(scene_path):
		return _prep_animation_scene_cache[scene_path] as PackedScene
	if not _prep_model_path_available(scene_path):
		return null
	var loaded := ResourceLoader.load(scene_path)
	if loaded is PackedScene:
		_prep_animation_scene_cache[scene_path] = loaded
		return loaded as PackedScene
	return null

func _prep_display_unit_def(cell: Dictionary) -> Dictionary:
	var raw_value = cell.get("def", {})
	var out: Dictionary = raw_value.duplicate(true) if typeof(raw_value) == TYPE_DICTIONARY else {}
	var unit_id := str(cell.get("id", out.get("id", "")))
	var latest := _prep_race_unit_def_by_id(unit_id)
	if not latest.is_empty():
		for key in [
			"model",
			"model_visual_scale",
			"model_base_yaw",
			"model_frame_fill",
			"model_idle_animation",
			"model_idle_animation_name",
			"model_attack_animation_name",
			"model_run_animation_name",
			"model_by_element",
		]:
			if latest.has(key):
				out[key] = latest[key]
	var variants_value = out.get("model_by_element", {})
	if typeof(variants_value) == TYPE_DICTIONARY:
		var variants: Dictionary = variants_value
		var element := str(out.get("element", ""))
		var variant_path := str(variants.get(element, ""))
		if variant_path.begins_with("res://"):
			out["model"] = variant_path
	return out

func _prep_race_unit_def_by_id(unit_id: String) -> Dictionary:
	var table: Dictionary = DataRegistry.get_table("race_units")
	var units: Array = table.get("units", [])
	for item in units:
		if typeof(item) == TYPE_DICTIONARY and str(item.get("id", "")) == unit_id:
			return item as Dictionary
	return {}

func _prep_model_path_available(model_path: String) -> bool:
	if model_path.is_empty():
		return false
	if ResourceLoader.exists(model_path):
		return true
	return FileAccess.file_exists(model_path)

func _center_prep_model(model: Node3D) -> void:
	var bounds := _prep_node3d_bounds(model)
	if bounds.size == Vector3.ZERO:
		return
	var center := bounds.get_center()
	model.position -= Vector3(center.x, bounds.position.y, center.z)

func _prep_node3d_bounds(root: Node3D) -> AABB:
	var bounds := AABB()
	var has_bounds := false
	var stack: Array[Dictionary] = [{"node": root, "transform": root.transform}]
	while not stack.is_empty():
		var item: Dictionary = stack.pop_back()
		var node: Node = item.get("node")
		var node_transform: Transform3D = item.get("transform", Transform3D.IDENTITY)
		if node is MeshInstance3D:
			var mesh_node := node as MeshInstance3D
			var mesh_bounds := _prep_transformed_aabb(mesh_node.get_aabb(), node_transform)
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

func _prep_transformed_aabb(box: AABB, transform: Transform3D) -> AABB:
	if box.size == Vector3.ZERO:
		return box
	var corners := [
		box.position,
		box.position + Vector3(box.size.x, 0.0, 0.0),
		box.position + Vector3(0.0, box.size.y, 0.0),
		box.position + Vector3(0.0, 0.0, box.size.z),
		box.position + Vector3(box.size.x, box.size.y, 0.0),
		box.position + Vector3(box.size.x, 0.0, box.size.z),
		box.position + Vector3(0.0, box.size.y, box.size.z),
		box.position + box.size,
	]
	var out := AABB(transform * corners[0], Vector3.ZERO)
	for index in range(1, corners.size()):
		out = out.expand(transform * corners[index])
	return out
