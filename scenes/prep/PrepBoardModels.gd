extends "res://scenes/prep/PrepShared.gd"

const PREP_RELATION_PARTICLES_SCRIPT := preload("res://scenes/prep/PrepRelationParticles3D.gd")

# 9.17 音效。**只在这一层声明一次**：整条继承链
# PrepBoardModels ← PrepUI ← PrepFlowController ← PrepBoardController ← PrepScreen
# 都从这里继承，子类再声明一次会撞「成员在父类里已存在」的解析错误。
# preload 而不是全局类名，理由见 Main.gd 顶上那条注释。
const SfxService := preload("res://ui/services/SfxService.gd")
# 棋盘底图、下河流、待命区、萝卜、商店按钮这几张图随皮肤换，路径一律问它。
const PrepSkin := preload("res://scenes/prep/PrepSkin.gd")
const PREP_RELATION_LINK_SCRIPT := preload("res://scenes/prep/PrepRelationLink3D.gd")
const UnitActor3DScript := preload("res://effects/runtime/presentation/UnitActor3D.gd")
const UnitVisualResolverScript := preload("res://effects/runtime/presentation/UnitVisualResolver.gd")
const UnitContactShadowScript := preload("res://effects/runtime/presentation/UnitContactShadow.gd")
const FOUR_STAR_READY_AURA := preload("res://effects/vfx3d/modules/FourStarAura3D.gd")
const FOUR_STAR_AURA := preload("res://effects/vfx3d/modules/FourStarAuraV3_3D.gd")
const CARROT_CURRENCY_ICON := preload("res://assets/props/carrot_system/ui/icon_carrot_currency.png")
# 棋盘正中的「上阵数 / 上限」图案本体（矢量自绘）。10.05 第 2 条返工把它从 2D 徽章
# 改成贴地的 3D 面片，所以 preload 从 PrepUI 挪到这一层 —— **基类不能引用子类的常量**，
# 而面片是在 PrepBoardModels 里建的。
const PrepDeployCounterScript := preload("res://scenes/prep/panels/PrepDeployCounter.gd")
var _four_star_visual_poll := 0.0

func refresh_four_star_visuals(delta: float) -> void:
	_four_star_visual_poll += delta
	if _four_star_visual_poll < 0.2:
		return
	_four_star_visual_poll = 0.0
	for source in [[GameState.board_slots, _prep_board_model_nodes], [GameState.bench_slots, _prep_standby_model_nodes]]:
		var slots: Array = source[0]
		var models: Dictionary = source[1]
		for index in models:
			var actor := models[index] as Node3D
			if is_instance_valid(actor) and int(index) < slots.size() and slots[index] is Dictionary:
				_sync_four_star_actor(actor, slots[index])

func _sync_four_star_actor(actor: Node3D, cell: Dictionary) -> void:
	var def: Dictionary = cell.get("def", {})
	var state := 0
	if not bool(cell.get("is_mercenary", false)):
		if int(cell.get("star", 1)) == GameState.MAX_UNIT_STAR:
			state = 2
		elif (not GameState.tutorial_mode or TutorialMode.allows_carrot_action("four_star")) and NetworkService.four_star_upgrade_available() and NetworkService.four_star_request_id.is_empty() and bool(GameState.four_star_check(cell).get("ok", false)):
			state = 1
	var affinity := str(def.get("element", ""))
	# Keep the established gold readiness hint for eligible three-star pieces.
	# The approved V2 envelope is reserved for completed four-star pieces.
	var ready_aura := FOUR_STAR_READY_AURA.sync(actor, state if state == 1 else 0, affinity, 1.0)
	if ready_aura != null and state == 1 and actor.is_inside_tree():
		if not actor.has_meta("four_star_aura_transform") and bool(actor.get_meta("prep_model_centered", false)):
			FOUR_STAR_READY_AURA.fit_to_skeleton(ready_aura, actor, 0.24)
			var attempts := int(actor.get_meta("four_star_fit_attempts", 0)) + 1
			actor.set_meta("four_star_fit_attempts", attempts)
			if bool(ready_aura.get_meta("skeleton_fitted", false)) or attempts >= 10:
				actor.set_meta("four_star_aura_transform", ready_aura.transform)
		if actor.has_meta("four_star_aura_transform"):
			ready_aura.transform = actor.get_meta("four_star_aura_transform")
			ready_aura.attach_rim(actor)
	var aura := FOUR_STAR_AURA.sync(actor, 2 if state == 2 else 0, affinity, 1.0)
	if aura != null and state == 2 and actor.is_inside_tree():
		if not actor.has_meta("four_star_aura_v2_transform") and bool(actor.get_meta("prep_model_centered", false)):
			# Prep units have no Foot/HeadAnchor; 0.32 matches the rendered prep model
			# height. 0.20 = world radius of the ring drawn in board_cell_mark.png, so the
			# four-star ring sits on the cell circle instead of spreading outward.
			FOUR_STAR_AURA.fit_to_actor(aura, actor, 0.32, 0.20)
			actor.set_meta("four_star_aura_v2_transform", aura.transform)
		if actor.has_meta("four_star_aura_v2_transform"):
			aura.transform = actor.get_meta("four_star_aura_v2_transform")
			aura.attach_rim(actor)

func play_four_star_upgrade(uid: String) -> void:
	for source in [[GameState.board_slots, _prep_board_model_nodes], [GameState.bench_slots, _prep_standby_model_nodes]]:
		var slots: Array = source[0]
		var models: Dictionary = source[1]
		for index in slots.size():
			if slots[index] is Dictionary and str(slots[index].get("uid", "")) == uid:
				var actor := models.get(index) as Node3D
				if is_instance_valid(actor):
					_sync_four_star_actor(actor, slots[index])
					var aura := actor.get_node_or_null("FourStarAuraV2")
					if aura != null:
						aura.play_upgrade()
				return
# 3D 河流场地（river_arena FBX + 其材质）已弃用，改为贴在平躺 quad 上的 2D 分层棋盘，
# 见下方 _add_prep_art_layers()。原来的两个路径常量与 _apply_prep_river_material()
# 指向的 assets/models/prep/river_arena/ 目录早已不存在，且全仓无调用点，
# 于 2026-08-18 随 A1 资产清单一并清理。
# 2.5D 分层棋盘背景图（贴在 3D 平躺地面 quad 上，和棋子一起呈现 TFT 倾斜纵深）随皮肤换，见 PrepSkin.SLOTS。
# 每个 4×4 格子上的站位图案（站位.png）——3D 地面 quad，模型在其上方不会被盖。
const PREP_CELL_MARK_PATH := "res://assets/board/prep_2_5d/board_cell_mark.png"
const PREP_CELL_MARK_SIZE := Vector2(0.6, 0.6)   # 每张站位图的世界尺寸（可调大小）
const PREP_CELL_MARK_Y_LIFT := 0.005             # 抬离地面高度（河流之上、模型之下）
# 「上阵数 / 上限」贴地图案（10.05 反馈第 2 条返工）。
#
# 为什么必须是 3D 面片而不是 2D 控件：2D 层（z_index≥0）整块压在 3D 视口
# （PrepRiverArenaLayer，z_index = -19）之上，任何 2D 图案都会**盖住棋子**；
# 而这块面片躺在棋盘地面上、和 16 张站位图同一套深度排序规则 —— 棋子是不透明
# 3D 物体、比它离相机更近，深度测试自然把它挡在身后，于是图案落在棋子**脚下**。
#
# 图案本体仍在 `PrepDeployCounter`（纯 `_draw()` 矢量），由 SubViewport 渲成贴图
# 再贴到面片上；这样既不新增图片素材，也不用把矢量画法搬进 3D。
const PREP_DEPLOY_COUNTER_VIEWPORT_SIZE := Vector2i(162, 88)   # = BADGE_SIZE + 2×发光边距
const PREP_DEPLOY_COUNTER_WORLD_WIDTH := 1.30                  # 面片世界宽度（含发光边距）
const PREP_DEPLOY_COUNTER_Y_LIFT := 0.0045                     # 河道波光(0.004) 与站位图(0.005) 之间
const PREP_DEPLOY_COUNTER_RENDER_PRIORITY := 5                 # 与站位图同层（两者互斥，不会同现）
# 兜底开关：若真机上视口贴图与普通贴图的 V 轴相反、图案上下颠倒，改 true 即翻正
# （结构门禁在 headless 下渲不出图，测不到朝向，所以留这一行显式开关）。
const PREP_DEPLOY_COUNTER_FLIP_V := false
const PREP_RIVER_TOP_PATH := "res://assets/board/prep_2_5d/prep20_river_top.png"        # 上河流（黑底，shader 键透明+流动）
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
const PREP_CARROT_DIG_PATH := "res://assets/props/carrot_system/vfx/atlas_digging_dust_4x4.png"
const PREP_CARROT_LEVELUP_PATH := "res://assets/props/carrot_system/vfx/atlas_farm_levelup_4x4.png"
const CARROT_PET_POSITIONS := [
	Vector3(-0.14, 0.0, -0.11), Vector3(0.0, 0.0, -0.18), Vector3(0.14, 0.0, -0.11),
	Vector3(-0.14, 0.0, 0.12), Vector3(0.0, 0.0, 0.15), Vector3(0.14, 0.0, 0.12),
]
# ══════ 只调「4×4 格子」（发光圈 + 落子网格）在地面上的铺排 ══════
# ⚠️ 只动格子，不动画死的石台图；挪多了格子会跑出石台、对不上。
# UV 是贴图 0~1 占比：范围拉大 = 格子铺更开；两端同时加/减 = 格子整排平移。
const BOARD_STONE_U := Vector2(0.3, 0.64)             # 4×4 格子横向范围/位置
const BOARD_STONE_V := Vector2(0.26, 0.78)             # 4×4 格子纵向范围/位置
const BOARD_CELL_RADIUS := 0.22                         # 每个格子圆的大小（世界半径；地面上真圆，投影成椭圆）
const BOARD_CELL_SEGMENTS := 20                          # 圆的多边形段数
const BOARD_MODEL_SPREAD_U := 0.95  # Compensate perspective at body height, after live foot anchoring.
const BOARD_MODEL_SPREAD_V := 1.0
# 待命区：横排 8 个，放在棋盘正下方（前景 v≈0.88，u 横跨 0.31~0.79）。
# 待命区 8 个格子的地面 UV 落点，参数化：改下面几个数就能整排调位置/间距/大小，
# 不用手编 8 个点。（格子和棋子模型都用这套值，改一处两个一起动。）
const STANDBY_SLOT_COUNT := 8
const STANDBY_ROW_V := 0.815        # 整排前后位置：0=远/靠上，1=近/靠下（越大越往屏幕下方）
const STANDBY_CENTER_U := 0.49     # 整排水平中心：0=左，1=右（整体左右移动改这个）
const STANDBY_STEP_U := 0.047      # 相邻两格的水平间距：越大越疏、越小越密
const STANDBY_SPOT_RADIUS := 0.16   # 每个格子圆的世界半径：越大格子越大
const STANDBY_MODEL_DX := 0.0   # 待命模型左右微调（不动圆圈）
const STANDBY_MODEL_DZ := 0.02  # Body center sits slightly above the platform center after foot anchoring.
const STANDBY_MODEL_SPREAD := 0.94  # Body height expands the apparent spacing toward the screen edges.
# 待命区背景平台：做成 3D 地面 quad（不是 2D 贴图），模型是地面上方的 3D 物体，自然盖在它上面。
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
var _carrot_gather_root: Node3D
var _carrot_pet_nodes: Array[Node3D] = []
var _carrot_pet_nodes_by_slot: Dictionary = {}
var _carrot_placeholder: Node3D
var _carrot_pet_signature := ""
var _carrot_last_farm_level := -1
var _carrot_vfx_serial := 0
var _prep_river_viewport: SubViewport
var _prep_river_stage_root: Node3D
var _prep_river_camera: Camera3D
var _prep_board_frame: Control
var _prep_board_glow: CPUParticles2D
var _prep_standby_model_nodes: Dictionary = {}
var _prep_standby_model_signatures: Dictionary = {}
var _prep_board_model_nodes: Dictionary = {}
var _prep_board_model_signatures: Dictionary = {}
var _prep_relation_link_nodes: Dictionary = {}
# 16 张站位图（`PrepCellMark%d`）与棋盘正中的计数面片。两者**互斥**：
# 平时藏圆圈、显计数图案；一拖棋子就反过来（落点引导接管棋盘）。
var _prep_cell_mark_nodes: Array[Node3D] = []
var _prep_cell_marks_visible := false
var _prep_deploy_counter_viewport: SubViewport
# 用 const-preload 当类型标注（同 PrepShared 的 `_shop: ShopPanelScript`）：
# 标成 Control 的话，`configure()` / `deploy_text()` 在静态检查期就不认了。
var _prep_deploy_counter_control: PrepDeployCounterScript
var _prep_deploy_counter_layer: MeshInstance3D
var _prep_deploy_counter_visible := true
# 模型/动画缓存已移到 BattleAssetService（备战棋盘与战斗共用一份，且跨场景存活）。
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
	_prep_river_viewport.own_world_3d = true
	_prep_river_viewport.size = PREP_RIVER_VIEWPORT_SIZE
	# Only the high preset adds coverage samples; keep the mobile budgets and
	# this viewport's 30 Hz refresh unchanged.
	_prep_river_viewport.msaa_3d = Viewport.MSAA_2X \
		if VFXManager.get_quality_tier() == VFXQualityBudget.Tier.HIGH else Viewport.MSAA_DISABLED
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
	_setup_carrot_gathering()

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


func _setup_carrot_gathering() -> void:
	_carrot_gather_root = Node3D.new()
	_carrot_gather_root.name = "CarrotGatheringRoot"
	# Keep the gathering group in the open ground between the board and the
	# right-side UI.  These are stage-local coordinates (the stage is scaled).
	_carrot_gather_root.position = Vector3(0.373, 0.02, 0.10)
	_prep_river_stage_root.add_child(_carrot_gather_root)
	_carrot_placeholder = Node3D.new()
	_carrot_placeholder.name = "CarrotVisual"
	_carrot_gather_root.add_child(_carrot_placeholder)
	var carrot_texture := ResourceLoader.load(PrepSkin.path("carrot")) as Texture2D
	if carrot_texture != null:
		var carrot_sprite := Sprite3D.new()
		carrot_sprite.name = "CarrotGeneratedSprite"
		carrot_sprite.texture = carrot_texture
		carrot_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		# Keep the generated prop close to one world unit after the
		# 3.5x preparation-stage scale.
		# Leave enough room for the faces of the three pets in the back row.
		carrot_sprite.pixel_size = 0.00022
		carrot_sprite.position = Vector3(0.0, 0.12, 0.0)
		carrot_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		carrot_sprite.transparent = true
		carrot_sprite.shaded = false
		carrot_sprite.no_depth_test = false
		_carrot_placeholder.add_child(carrot_sprite)
	else:
		# Keep a readable development fallback if the imported PNG is unavailable.
		_add_carrot_placeholder_fallback()
	_refresh_carrot_gathering()

# 萝卜田升级只放一次爆光和升级音。萝卜后面原来按等级摆的花坛 / 金桂冠（2026-09-26 他定）
# 所有皮肤都不要了 —— 冰萝卜后面露出泥土花坛很怪，草地也一起拿掉；等级在萝卜营地面板里看。
func _refresh_carrot_farm_visual() -> void:
	var farm_level := GameState.carrot_farm_level()
	if _carrot_last_farm_level >= 0 and farm_level > _carrot_last_farm_level:
		_play_carrot_world_flipbook(PREP_CARROT_LEVELUP_PATH, 0.23, 0.00058)
		# 9.17：萝卜田升级音。萝卜田是**自动**升级的（累计花萝卜到达门槛就升，
		# 面板上没有升级按钮），所以这一行的 `farm_level > _carrot_last_farm_level`
		# 就是全局唯一、且已经被缓存字段去重的跨门槛判据。
		#
		# 不能把音效放到 _refresh_carrot_farm_visual() 开头：它被
		# _refresh_carrot_gathering() 带着跑，而后者在**每次 room_state 广播**
		# （PrepFlowController）和每个萝卜动作之后都会执行 —— 放开头等于
		# 每帧网络同步响一声。
		SfxService.play(SfxService.CUE_CARROT_FARM_UPGRADE)
	_carrot_last_farm_level = farm_level

func _add_carrot_placeholder_fallback() -> void:
	var box := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(0.28, 0.20, 0.28)
	box.mesh = box_mesh
	var box_material := StandardMaterial3D.new()
	box_material.albedo_color = Color(0.94, 0.44, 0.08)
	box_material.roughness = 0.82
	box.material_override = box_material
	box.position.y = 0.11
	_carrot_placeholder.add_child(box)
	var leaf := MeshInstance3D.new()
	var leaf_mesh := BoxMesh.new()
	leaf_mesh.size = Vector3(0.08, 0.04, 0.18)
	leaf.mesh = leaf_mesh
	var leaf_material := StandardMaterial3D.new()
	leaf_material.albedo_color = Color(0.22, 0.68, 0.22)
	leaf_material.roughness = 0.9
	leaf.material_override = leaf_material
	leaf.position = Vector3(0.0, 0.24, -0.02)
	leaf.rotation_degrees = Vector3(0.0, 18.0, -18.0)
	_carrot_placeholder.add_child(leaf)

func refresh_carrot_gathering() -> void:
	_refresh_carrot_gathering()

func _refresh_carrot_gathering() -> void:
	# 离树守卫：Main._clear() 是 remove_child + queue_free，切界面后节点在本帧末
	# 销毁前仍然 is_instance_valid，但已经不在树上。而 NetworkService 是 autoload，
	# 这窗口里来一个 room_state 广播照样会打到这里（PrepFlowController._on_network_
	# session_changed），往离树的根上重建一批宠物。同帧 _refresh_carrot_farm_visual()
	# 还可能触发 _play_carrot_world_flipbook 的 `await get_tree()...`，离树时是空指针。
	if _carrot_gather_root == null or not is_instance_valid(_carrot_gather_root):
		return
	if not is_inside_tree():
		return
	_refresh_carrot_farm_visual()
	var entries := _carrot_pet_entries()
	var signature := JSON.stringify(entries)
	if signature == _carrot_pet_signature:
		return
	for pet in _carrot_pet_nodes:
		if is_instance_valid(pet):
			pet.queue_free()
	_carrot_pet_nodes.clear()
	_carrot_pet_nodes_by_slot.clear()
	_carrot_pet_signature = signature
	for entry_value in entries:
		var entry: Dictionary = entry_value
		var pet_id := str(entry.get("pet_id", ""))
		var model_path := PetService.model_path(pet_id)
		if model_path.is_empty():
			continue
		var scene := ResourceLoader.load(model_path) as PackedScene
		if scene == null:
			push_warning("萝卜采集宠物模型加载失败：%s" % model_path)
			continue
		var pet := scene.instantiate() as Node3D
		if pet == null:
			continue
		pet.name = "CarrotGatheringPet_%d" % int(entry.get("slot", 0))
		# The pet scenes create their action meshes from their own _ready().  Keep
		# the raw model hidden until its real bounds have been measured so a large
		# source FBX cannot flash on screen or remain at its import size.
		pet.visible = false
		var target: Vector3 = entry.get("position", Vector3.ZERO)
		pet.position = target
		_carrot_gather_root.add_child(pet)
		_carrot_pet_nodes.append(pet)
		_carrot_pet_nodes_by_slot[int(entry.get("slot", -1))] = pet
		# Pet scenes populate their FBX meshes in _ready(), so normalize after
		# the model tree exists.
		call_deferred("_normalize_carrot_pet", pet, pet_id, target,
			_carrot_facing_yaw(target), 6)

func _carrot_pet_entries() -> Array:
	var entries: Array = []
	if not NetworkService.team_active:
		# Single-player has one real owner. Do not fill the other five gathering
		# positions with starter pets.
		var offline_pet := PlayerProfile.get_active()
		if not PetService.model_path(offline_pet).is_empty():
			entries.append({"slot": 4, "pet_id": offline_pet, "position": CARROT_PET_POSITIONS[4]})
		return entries
	var states: Array = NetworkService.team_slot_states
	var local_slot := clampi(NetworkService.team_local_slot, 0, 5)
	for slot in 6:
		if slot >= states.size() or str(states[slot]) not in ["player", "dummy"]:
			continue
		var pet_id := str(NetworkService.team_seat_pets.get(slot,
			NetworkService.team_seat_pets.get(str(slot), "")))
		# The local player's currently equipped pet is a valid immediate source
		# while its first authoritative room-state update is in flight.
		if pet_id.is_empty() and slot == local_slot:
			pet_id = PlayerProfile.get_active()
		# Local-host debugging still broadcasts real submitted boards. This is a
		# factual fallback, unlike the removed starter-pet fallback.
		if pet_id.is_empty() and NetworkService.team_boards.has(slot):
			pet_id = str((NetworkService.team_boards[slot] as Dictionary).get("pet", ""))
		elif pet_id.is_empty() and NetworkService.team_boards.has(str(slot)):
			pet_id = str((NetworkService.team_boards[str(slot)] as Dictionary).get("pet", ""))
		if PetService.model_path(pet_id).is_empty():
			continue
		entries.append({
			"slot": slot,
			"pet_id": pet_id,
			"position": CARROT_PET_POSITIONS[slot],
		})
	return entries

func _carrot_facing_yaw(position: Vector3) -> float:
	var toward_carrot := Vector3(-position.x, 0.0, -position.z).normalized()
	return rad_to_deg(atan2(toward_carrot.x, toward_carrot.z))

func _normalize_carrot_pet(pet: Node3D, pet_id: String, target: Vector3, yaw: float,
		attempts_left: int = 0) -> void:
	if pet == null or not is_instance_valid(pet):
		return
	# 已离树就直接放弃，且**不重试**：离树的宠物不会再回来，重试只会烧掉 6 次
	# call_deferred，最后再报一句误导人的「模型未生成可测量网格」。
	if not pet.is_inside_tree():
		return
	# The preparation camera looks down at a steep angle.  Tilt only the visual
	# model away from the camera so the face and front of the body remain visible.
	# The rotated bounds below then keep the feet resting on the gathering ground.
	var visual_root := pet.get_node_or_null("ModelRoot") as Node3D
	if visual_root != null:
		visual_root.rotation_degrees.x = -18.0
	var pet_box := _carrot_pet_aabb(pet)
	if pet_box.size.y <= 0.0001:
		if attempts_left > 0:
			call_deferred("_normalize_carrot_pet", pet, pet_id, target, yaw,
				attempts_left - 1)
		else:
			push_warning("萝卜采集宠物模型未生成可测量网格：%s" % pet_id)
		return
	var pet_height := pet_box.size.y
	# The gathering pets are supporting actors around the carrot.  A 0.12-world
	# height projects to about 60-70 px at 1600 x 720, matching the reference.
	var pet_scale := 0.12 / pet_height * PetService.model_scale(pet_id)
	pet.scale = Vector3.ONE * pet_scale
	pet.position = Vector3(target.x,
		-pet_box.position.y * pet_scale + PetService.model_y(pet_id) / PREP_RIVER_STAGE_SCALE.y,
		target.z)
	pet.rotation_degrees.y = yaw
	pet.visible = true
	_play_carrot_pet_ambient(pet)

func _play_carrot_pet_ambient(pet: Node3D) -> void:
	if pet == null or not is_instance_valid(pet) or pet not in _carrot_pet_nodes:
		return
	# The current pet library has no authored idle clips; its idle is a frozen
	# attack frame.  Loop the original run clip in place so the gathering pets
	# remain alive without changing their assigned positions.
	if pet.has_method("play_run"):
		pet.call("play_run")
	elif pet.has_method("play_idle"):
		pet.call("play_idle")

func _resume_carrot_pet_ambient(pet: Node3D, harvest_serial: int) -> void:
	await get_tree().create_timer(1.15).timeout
	if pet == null or not is_instance_valid(pet):
		return
	if int(pet.get_meta("carrot_harvest_serial", -1)) != harvest_serial:
		return
	_play_carrot_pet_ambient(pet)

func play_carrot_harvest_feedback(gains_by_slot: Dictionary) -> void:
	# 这个函数是 PrepScreen._ready() 里 call_deferred 出去的，落地时界面可能已被
	# Main._clear() 摘树（见 _refresh_carrot_gathering 的说明）。离树时 create_tween()
	# 会直接报 "Can't create Tween when not inside scene tree"。
	if gains_by_slot.is_empty() or _carrot_gather_root == null or not is_instance_valid(_carrot_gather_root):
		return
	if not is_inside_tree():
		return
	var has_harvest := false
	for slot_value in _carrot_pet_nodes_by_slot.keys():
		var slot := int(slot_value)
		var pet := _carrot_pet_nodes_by_slot.get(slot) as Node3D
		if not is_instance_valid(pet):
			continue
		var gain := maxi(0, int(gains_by_slot.get(slot, gains_by_slot.get(str(slot), 0))))
		_show_carrot_pet_gain(pet, gain)
		if gain <= 0:
			continue
		has_harvest = true
		var harvest_serial := int(pet.get_meta("carrot_harvest_serial", 0)) + 1
		pet.set_meta("carrot_harvest_serial", harvest_serial)
		if pet.has_method("play_attack"):
			pet.call("play_attack")
		_resume_carrot_pet_ambient(pet, harvest_serial)
		var base_y := pet.position.y
		var tween := create_tween()
		tween.tween_property(pet, "position:y", base_y + 0.030, 0.18)
		tween.tween_property(pet, "position:y", base_y, 0.18)
		tween.tween_property(pet, "position:y", base_y + 0.022, 0.18)
		tween.tween_property(pet, "position:y", base_y, 0.18)
	if has_harvest:
		_play_carrot_world_flipbook(PREP_CARROT_DIG_PATH, 0.12, 0.00050)

func _show_carrot_pet_gain(pet: Node3D, gain: int) -> void:
	var head_world := pet.global_position + Vector3(0.0, 0.175, 0.0)
	var head_screen := _world_to_main_screen(head_world)
	var badge := Control.new()
	badge.name = "CarrotHarvestGain"
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.size = Vector2(82.0, 36.0)
	badge.clip_contents = true
	badge.position = head_screen - Vector2(badge.size.x * 0.5, badge.size.y)
	badge.pivot_offset = badge.size * 0.5
	badge.scale = Vector2.ONE * 0.70
	badge.z_index = 80
	add_child(badge)

	var plate := Panel.new()
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var plate_style := StyleBoxFlat.new()
	plate_style.bg_color = Color(0.075, 0.045, 0.018, 0.90)
	plate_style.border_color = Color(0.96, 0.63, 0.16, 0.92) if gain > 0 else Color(0.55, 0.55, 0.48, 0.82)
	plate_style.set_border_width_all(2)
	plate_style.set_corner_radius_all(12)
	plate.add_theme_stylebox_override("panel", plate_style)
	badge.add_child(plate)

	var icon := TextureRect.new()
	icon.name = "CarrotIcon"
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.texture = CARROT_CURRENCY_ICON
	icon.position = Vector2(8.0, 4.0)
	icon.size = Vector2(28.0, 28.0)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.modulate = Color(1.0, 1.0, 1.0, 1.0 if gain > 0 else 0.72)
	badge.add_child(icon)

	var gain_label := Label.new()
	gain_label.name = "GainText"
	gain_label.text = "+%d" % gain
	gain_label.position = Vector2(35.0, 0.0)
	gain_label.size = Vector2(43.0, 36.0)
	gain_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gain_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	gain_label.add_theme_font_size_override("font_size", 23)
	gain_label.add_theme_constant_override("outline_size", 5)
	gain_label.add_theme_color_override("font_outline_color", Color(0.08, 0.045, 0.015, 0.96))
	gain_label.modulate = Color(1.0, 0.88, 0.30, 1.0) if gain > 0 else Color(0.76, 0.76, 0.67, 0.92)
	gain_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_child(gain_label)

	var pop := create_tween()
	pop.tween_property(badge, "scale", Vector2.ONE * 1.10, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	pop.tween_property(badge, "scale", Vector2.ONE, 0.08).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	var rise := create_tween()
	rise.tween_property(badge, "position:y", badge.position.y - 24.0, 2.0).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	var fade := create_tween()
	fade.tween_interval(1.55)
	fade.tween_property(badge, "modulate:a", 0.0, 0.45)
	fade.chain().tween_callback(badge.queue_free)

func _play_carrot_world_flipbook(path: String, height: float, pixel_size: float) -> void:
	if _carrot_gather_root == null or not is_instance_valid(_carrot_gather_root):
		return
	var texture := ResourceLoader.load(path) as Texture2D
	if texture == null:
		return
	_carrot_vfx_serial += 1
	var serial := _carrot_vfx_serial
	var frame_texture := AtlasTexture.new()
	frame_texture.atlas = texture
	var sprite := Sprite3D.new()
	sprite.name = "CarrotGatheringFlipbook"
	sprite.texture = frame_texture
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.pixel_size = pixel_size
	sprite.position = Vector3(0.0, height, 0.035)
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	sprite.transparent = true
	sprite.shaded = false
	sprite.no_depth_test = true
	_carrot_gather_root.add_child(sprite)
	for frame in range(16):
		if serial != _carrot_vfx_serial or not is_instance_valid(sprite):
			if is_instance_valid(sprite):
				sprite.queue_free()
			return
		frame_texture.region = Rect2((frame % 4) * 256, (frame / 4) * 256, 256, 256)
		await get_tree().create_timer(0.055).timeout
	if is_instance_valid(sprite):
		sprite.queue_free()

func _carrot_pet_aabb(root: Node3D) -> AABB:
	# 下面按 global_transform 换算，离树时引擎只会报错并返回单位矩阵，算出来的包围盒
	# 是错的。兜底放在 helper 里，任何调用点都不会再踩。
	if root == null or not is_instance_valid(root) or not root.is_inside_tree():
		return AABB()
	var out := AABB()
	var found := false
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		for child in current.get_children():
			stack.append(child)
		if not (current is MeshInstance3D):
			continue
		var mesh_instance := current as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var local := root.global_transform.affine_inverse() * mesh_instance.global_transform
		var box := local * mesh_instance.get_aabb()
		if found:
			out = out.merge(box)
		else:
			out = box
			found = true
	return out if found else AABB()

func _add_prep_art_layers(world: Node3D) -> void:
	# v4 横向竞技场，一层一层贴在平躺 3D 平面上（保留 2.5D 倾斜）
	_add_prep_texture_plane(world, "PrepBaseLayer", PrepSkin.path("board"), 0.000, 0)
	# 下河流：黑底贴图，flow shader 键透明 + 横向滚动流动
	_add_prep_texture_plane(world, "PrepRiverBottomLayer", PrepSkin.path("river"), 0.002, 2)
	# 流动波光是照草地河道画的，皮肤可以关掉它（data/prep_skins.json 的 river_glow）。
	if PrepSkin.river_glow():
		_add_prep_river_flow(world)
	# 主战场 4×4：每格一张站位图（3D 地面 quad）。发光环仍由代码画在上层。
	_add_prep_cell_marks(world)
	# 棋盘正中「上阵数 / 上限」贴地图案（10.05 第 2 条返工）。放在站位图**之后**建，
	# 位置与它们同一层地面 —— 与站位图互斥显隐，见 set_prep_cell_marks_visible()。
	_add_prep_deploy_counter_layer(world)
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
	_prep_cell_mark_nodes.clear()
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
		# 初始显隐：平时藏起来（棋盘正中交给计数图案），拖棋子上阵时才出现。
		layer.visible = _prep_cell_marks_visible
		world.add_child(layer)
		_prep_cell_mark_nodes.append(layer)

# 棋盘正中的「上阵数 / 上限」贴地图案（10.05 反馈第 2 条返工）。
#
# 做法：`PrepDeployCounter`（纯 `_draw()` 矢量）塞进一个 SubViewport 渲成贴图，
# 再把贴图贴到一块**躺在棋盘地面上的 PlaneMesh** 上。这样：
#   * 它与棋子同处 3D 场景 —— 棋子不透明、离相机更近，深度测试自然把它盖住，
#     于是图案在棋子脚下（旧版是 2D 控件，整块压在 3D 视口之上，反而遮棋子）；
#   * 与 16 张站位图同一个 y 层与 render_priority，谁显谁隐由状态决定；
#   * 不新增图片素材，矢量画法一行不用改。
func _add_prep_deploy_counter_layer(world: Node3D) -> void:
	var counter: PrepDeployCounterScript = PrepDeployCounterScript.new()
	counter.name = PrepDeployCounterScript.NODE_NAME
	_prep_deploy_counter_control = counter

	var vp := SubViewport.new()
	vp.name = "PrepDeployCounterViewport"
	vp.transparent_bg = true    # 底板以外要透出草地，否则面片是一块深色矩形
	vp.disable_3d = true        # 只画 2D 图案，不必为它建一套 3D 世界与相机
	vp.size = PREP_DEPLOY_COUNTER_VIEWPORT_SIZE
	# 图案是静态的，只在数值变化时重渲一帧（手机上别常开一块视口全速重画）。
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.add_child(counter)
	add_child(vp)
	_prep_deploy_counter_viewport = vp

	var layer := MeshInstance3D.new()
	layer.name = "PrepDeployCounterLayer"
	var plane := PlaneMesh.new()
	plane.size = Vector2(PREP_DEPLOY_COUNTER_WORLD_WIDTH,
		PREP_DEPLOY_COUNTER_WORLD_WIDTH * float(PREP_DEPLOY_COUNTER_VIEWPORT_SIZE.y)
			/ float(PREP_DEPLOY_COUNTER_VIEWPORT_SIZE.x))
	layer.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = vp.get_texture()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mat.render_priority = PREP_DEPLOY_COUNTER_RENDER_PRIORITY
	if PREP_DEPLOY_COUNTER_FLIP_V:
		# 兜底开关：视口贴图与普通贴图的 V 轴在真机上若相反，图案会上下颠倒。
		# 结构门禁测不到这一点（headless 下渲不出图），所以留一行开关，改 true 即翻正。
		mat.uv1_scale = Vector3(1.0, -1.0, 1.0)
	layer.material_override = mat
	# 摆在 16 格的**正中心**：同样走棋盘 UV → 世界坐标的换算，不另起一套。
	var center := _board_plane_world_pos(
		(BOARD_STONE_U.x + BOARD_STONE_U.y) * 0.5,
		(BOARD_STONE_V.x + BOARD_STONE_V.y) * 0.5)
	center.y = PREP_BOARD_GROUND_CENTER.y + PREP_DEPLOY_COUNTER_Y_LIFT
	layer.position = center
	layer.visible = _prep_deploy_counter_visible
	world.add_child(layer)
	_prep_deploy_counter_layer = layer
	set_prep_deploy_counter_values(GameState.normal_unit_count(), GameState.normal_unit_cap())
	# 首帧那次渲染有可能落在控件还没画完的时候，补一次延迟重渲（一帧、162×88，成本可忽略）。
	# 另外每次棋盘刷新都会经 set_prep_deploy_counter_values 再补一次，漏不掉。
	_refresh_prep_deploy_counter_texture.call_deferred()

# 16 张站位图的显隐（平时藏起来，拖棋子上阵时才出现当落点引导）。
func set_prep_cell_marks_visible(visible_now: bool) -> void:
	_prep_cell_marks_visible = visible_now
	for node in _prep_cell_mark_nodes:
		if is_instance_valid(node):
			node.visible = visible_now

# 计数图案的显隐（与站位图互斥）。
func set_prep_deploy_counter_visible(visible_now: bool) -> void:
	_prep_deploy_counter_visible = visible_now
	if _prep_deploy_counter_layer != null and is_instance_valid(_prep_deploy_counter_layer):
		_prep_deploy_counter_layer.visible = visible_now
	if visible_now:
		# 藏起来的这段时间上阵数可能变过，重新出现时保证贴图是新的。
		_refresh_prep_deploy_counter_texture()

# 计数图案的数值。改完立刻重渲一帧 SubViewport，否则贴图还是旧的。
func set_prep_deploy_counter_values(count: int, cap: int) -> void:
	if _prep_deploy_counter_control == null or not is_instance_valid(_prep_deploy_counter_control):
		return
	_prep_deploy_counter_control.configure(count, cap, _prep_deploy_counter_color())
	_refresh_prep_deploy_counter_texture()

func _prep_deploy_counter_color() -> Color:
	# 与棋盘格子共用同一份玩家色（3v3 是座位色，单机是棋盘默认青色）。
	if _board_hud == null or not is_instance_valid(_board_hud):
		return Color(0.48, 1.0, 0.92, 0.55)
	return _board_hud.player_color()

func _refresh_prep_deploy_counter_texture() -> void:
	if _prep_deploy_counter_viewport == null or not is_instance_valid(_prep_deploy_counter_viewport):
		return
	_prep_deploy_counter_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

# 契约快照 —— 门禁读它，不直接伸手摸 3D 节点。
# 「贴地 + 在棋子脚下」拆成四条**可判定的量**：
#   * `counter_is_3d`            它是 MeshInstance3D（不是 2D 控件）；
#   * `counter_in_board_world`   它与棋子渲染在**同一个 3D 视口**里 —— 这一条才是
#                                「不会被 2D 层压住」的实质：2D 层和 3D 视口根本
#                                不在一个渲染空间，同空间才谈得上深度排序；
#   * `counter_y_lift`           离地高度，必须不高于棋子站立的地面层；
#   * `counter_render_priority`  与站位图同层（5），低于待命区平台（7）。
func prep_deploy_counter_snapshot() -> Dictionary:
	var layer_valid := _prep_deploy_counter_layer != null and is_instance_valid(_prep_deploy_counter_layer)
	var counter_valid := _prep_deploy_counter_control != null \
		and is_instance_valid(_prep_deploy_counter_control)
	var priority := -1
	var in_board_world := false
	if layer_valid:
		var mat := _prep_deploy_counter_layer.material_override as BaseMaterial3D
		if mat != null:
			priority = mat.render_priority
		in_board_world = _prep_deploy_counter_layer.is_inside_tree() \
			and _prep_river_viewport != null \
			and _prep_deploy_counter_layer.get_viewport() == _prep_river_viewport
	var text := ""
	if counter_valid:
		text = _prep_deploy_counter_control.deploy_text()
	return {
		"cell_mark_count": _prep_cell_mark_nodes.size(),
		"cell_marks_visible": _prep_cell_marks_visible,
		"cell_mark_visible_count": _count_visible_cell_marks(),
		"counter_is_3d": layer_valid and _prep_deploy_counter_layer is MeshInstance3D,
		"counter_in_board_world": in_board_world,
		"counter_visible": _prep_deploy_counter_visible,
		"counter_visible_on_layer": layer_valid and _prep_deploy_counter_layer.visible,
		"counter_text": text,
		"counter_render_priority": priority,
		"counter_y_lift": (_prep_deploy_counter_layer.position.y - PREP_BOARD_GROUND_CENTER.y)
			if layer_valid else -1.0,
		"cell_mark_y_lift": PREP_CELL_MARK_Y_LIFT,
	}

func _count_visible_cell_marks() -> int:
	var count := 0
	for node in _prep_cell_mark_nodes:
		if is_instance_valid(node) and node.visible:
			count += 1
	return count

func _add_prep_standby_bg_plane(world: Node3D) -> void:
	# 待命区背景做成 3D 地面 quad：躺在待命格子位置，被模型自然遮挡（模型在地面上方，深度更近）。
	var bench_path := PrepSkin.path("bench")
	var tex := ResourceLoader.load(bench_path) as Texture2D
	if tex == null:
		push_warning("待命区背景加载失败：%s" % bench_path)
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
	# 全场萤火虫缓慢飘浮（颜色随皮肤，默认金色；冰雪是白色雪点）+ 下河面青色星光闪烁
	var dot := _make_soft_dot_texture()
	var ground := PREP_BOARD_GROUND_CENTER
	world.add_child(_make_prep_drift_particles(
		"PrepFireflies", dot,
		ground + Vector3(0.0, 0.30, 0.0), Vector3(3.4, 0.26, 1.9),
		34, 7.0, PrepSkin.firefly_color(), 0.5, 1.1, 0.05
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

func _setup_prep_board_model_view(board_frame: Control) -> void:
	# Board models now share the river arena viewport, camera, lights and depth.
	_prep_board_frame = board_frame
	# 用 item_rect_changed 而不是 resized：左侧羁绊面板在 body 这个 HBox 里和棋盘共享水平空间，
	# 加按钮（如慷慨命运赌博）会把 board_frame 整体右挤——这是**平移**不是 resize，
	# 纯平移不触发 resized，于是 _realign_prep_board_cells 不重跑，棋盘圆圈就停留在旧坐标、
	# 相对于固定位置的 3D 石台向右偏移。item_rect_changed 在 rect（位置+尺寸）变化时都会发。
	if not board_frame.item_rect_changed.is_connected(_queue_prep_model_layout_refresh):
		board_frame.item_rect_changed.connect(_queue_prep_model_layout_refresh)
	if _board_hud.standby_frame != null and not _board_hud.standby_frame.item_rect_changed.is_connected(_queue_prep_model_layout_refresh):
		_board_hud.standby_frame.item_rect_changed.connect(_queue_prep_model_layout_refresh)
	if not resized.is_connected(_queue_prep_model_layout_refresh):
		resized.connect(_queue_prep_model_layout_refresh)
	_queue_prep_model_layout_refresh()
	_connect_prep_layout_guard()


# ── 上阵光圈「持续守卫」 ─────────────────────────────────────────────────────
#
# 为什么需要（9.30 门禁实测定位，不是推理）：
#   `board_frame.item_rect_changed` 只能捕获「board_frame 在**自己的父容器里**被
#   重新排布」—— 那是它的**局部** rect 变了。但「拿到宝物后左面板多一个按钮」
#   走的是另一条路：左侧羁绊面板变尺寸 ⇒ body/center 重新排布 ⇒ board_frame 被
#   **祖先带着整体平移**，它自己的局部 position 没变 ⇒ **信号根本不发**。
#
#   实测（tools/prep_ring_layout_check 用例 A，走生产收尾 _finish_treasure_change）：
#     grid 整体右移 78px，而 `_prep_model_root` 一次都没被隐藏过（说明
#     `_apply_prep_model_layout_after_frames` 从没跑过），
#     同一时刻 `frame.item_rect_changed.is_connected(...)` 仍然是 true。
#   结果就是上阵光圈停在旧坐标、相对固定不动的 3D 石台偏 78px，一直到玩家做
#   别的操作（比如点赌博，那条路径显式调了重排）才回正 —— 与用户实测一致。
#
# 所以再加一道与「谁引起的、什么时候引起」全都无关的防线：每帧比一次 grid 的
# 全局位置，和上次对齐时用的值不同就原地补一次对齐。常态成本只是一次 Vector2
# 比较，只有真的挪了才重算。
#
# 边界（都用实测定的，别顺手扩）：
#   * 只补 2D 那一层，**不碰** `_reposition_existing_prep_models()`：3D 棋子是
#     固定投影到石台上的，被祖先带着平移的是 2D 层，把棋子也拽走只会错得更远。
#     实测偏移的也只有 2D 光圈。
#   * **不走** `_queue_prep_model_layout_refresh()`：那条路会先把 3D 模型藏两帧
#     再放出来（防闪烁设计），每帧这么做会闪成一片。
#   * 锚点由 `_realign_prep_board_cells()` 自己在末尾写入，谁调的都算对过账。
var _prep_aligned_grid_pos := Vector2.INF


func _connect_prep_layout_guard() -> void:
	var tree := get_tree()
	if tree == null:
		return
	if not tree.process_frame.is_connected(_tick_prep_board_layout_guard):
		tree.process_frame.connect(_tick_prep_board_layout_guard)


func _tick_prep_board_layout_guard() -> void:
	if _board_hud == null or _board_hud.grid == null:
		return
	if _prep_river_camera == null or _prep_river_viewport == null:
		return
	if not _board_hud.grid.is_inside_tree():
		return
	var now := _board_hud.grid.global_position
	if _prep_aligned_grid_pos.is_finite() and now.is_equal_approx(_prep_aligned_grid_pos):
		return
	_realign_prep_board_cells()
	_realign_prep_standby_cells()
	_update_prep_board_glow()

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
	# 轮询到棋盘 global_position 真正稳定再对齐：选中/赌博宝物会改变左侧羁绊面板与
	# 商店内容，进而使棋盘整体平移（多为竖直方向）。这个平移可能在接下来若干帧内才
	# 落定；若用过渡中的旧 global_position 去投影，圆圈就会整体错开石台——
	# 这正是 tester 看到的「绿/红圈向右/向左偏移」且进下一轮对战后回正的根因。
	# 这里等到 global_position 连续两帧不变（或版本被新请求覆盖）再算，杜绝陈旧坐标。
	var stable := 0
	var last_pos := _board_hud.grid.global_position
	var guard := 0
	while stable < 2 and is_inside_tree() and guard < 16:
		await get_tree().process_frame
		guard += 1
		if version != _prep_layout_refresh_version:
			return
		if _board_hud.grid.global_position.is_equal_approx(last_pos):
			stable += 1
		else:
			stable = 0
			last_pos = _board_hud.grid.global_position
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
	# Animated wrappers instantiate their rigs in _ready. Measure once after the
	# first idle pose has reached Skeleton3D, including when the stage is hidden.
	if attempt == 0 and is_instance_valid(model_node) and not bool(model_node.get_meta("prep_model_centered", false)):
		await get_tree().process_frame
		await get_tree().process_frame
	if not is_instance_valid(model_node):
		return
	if str(model_node.get_meta("visual_kind", "")) == "portrait_fallback":
		_configure_prep_contact_shadow(model_node)
		model_node.set_meta("prep_anchor_update_pending", false)
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
			await get_tree().process_frame
			_update_prep_model_anchors.call_deferred(model_node, attempt + 1)
		else:
			model_node.set_meta("prep_anchor_update_pending", false)
		return
	_configure_prep_contact_shadow(model_node)
	model_node.set_meta("relation_waist_height", bounds.size.y * 0.52)
	model_node.set_meta("four_star_height", bounds.size.y)
	model_node.set_meta("prep_anchor_update_pending", false)

func _make_prep_board_model(cell: Dictionary, unit_def: Dictionary) -> Node3D:
	var model_path := str(unit_def.get("model", ""))
	var actor = UnitActor3DScript.new()
	actor.name = "PrepActor_%s" % str(cell.get("id", "unit"))
	actor.configure_contract(0.98)
	actor.set_meta("unit_id", str(cell.get("id", unit_def.get("id", ""))))
	actor.set_meta("resolved_visual", unit_def)
	var scene := _prep_model_scene_for_path(model_path) if _prep_model_path_available(model_path) else null
	var instance = scene.instantiate() if scene != null else null
	if instance is Node3D:
		var model := instance as Node3D
		# 摆放界面永远只播 idle：*Animated 场景看到这个标记后跳过 attack/run 两份 FBX。
		model.set_meta("load_idle_only", true)
		var visual_scale := float(unit_def.get("model_visual_scale", 1.0))
		model.scale = Vector3.ONE * visual_scale
		model.rotation_degrees = Vector3.ZERO
		actor.attach_model(model)
		actor.set_meta("prep_visual_root", actor.get_path_to(model))
		_play_prep_model_idle(model, unit_def)
	else:
		if instance is Node:
			(instance as Node).queue_free()
		var reason := "model scene unavailable" if scene == null else "model root is not Node3D"
		UnitVisualResolverScript.report_failure(str(unit_def.get("id", cell.get("id", ""))), model_path, "prep", reason)
		var portrait_ok: bool = actor.attach_portrait_fallback(
			str(unit_def.get("portrait", "")),
			str(unit_def.get("fallback_frame", "")),
			Color(0.25, 0.85, 1.0, 0.58),
			0.98
		)
		if not portrait_ok:
			UnitVisualResolverScript.report_failure(str(unit_def.get("id", cell.get("id", ""))), str(unit_def.get("portrait", "")), "prep", "portrait unavailable")
	var prep_scale_factor := 1.4 if int(unit_def.get("tier", 1)) >= 3 else 1.2
	actor.scale = Vector3.ONE * PREP_MODEL_BASE_SCALE * prep_scale_factor
	actor.set_meta("relation_waist_height", _prep_board_model_target_size() * 0.52)
	# Prep models are enlarged 20%; epic (tier 3) units 40%.
	_add_prep_contact_shadow(actor)
	_sync_four_star_actor(actor, cell)
	# 名字/星级改为 2D 格子下方标签（见 _make_cell_caption），不再用 3D Label3D 浮标+锚点。
	return actor

func _add_prep_contact_shadow(pivot: Node3D) -> void:
	var shadow := UnitContactShadowScript.create("ContactShadow3D", Vector2(1.2, 0.9))
	# Transparent cell marks (5) and the bench platform (7) draw after priority
	# zero. Draw the contact shade last while keeping depth testing against feet.
	shadow.get_active_material(0).render_priority = 8
	pivot.add_child(shadow)

func _configure_prep_contact_shadow(model_node: Node3D) -> void:
	var shadow := model_node.get_node_or_null("ContactShadow3D") as MeshInstance3D
	if shadow == null:
		return
	var shadow_mesh := shadow.mesh as PlaneMesh
	if shadow_mesh == null:
		return
	shadow_mesh.size = Vector2(1.2, 0.9)
	shadow.position = Vector3(0.0, 0.012, 0.0)

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
	# Set the minimum first: Control.size is clamped to the previous minimum.
	# Doing this in reverse kept the initial oversized hit rectangle after the
	# visible ring had been projected, shifting tutorial pointers off its center.
	child.custom_minimum_size = bounds.size
	child.size = bounds.size
	var local := PackedVector2Array()
	for p in pts:
		local.append(p - bounds.position)
	child.configure_polygon(local)
	# caption 若标了「跟圆圈」：摆到椭圆【质心】(≈真正圆心) 而不是包围盒中心——补透视斜椭圆偏移，越靠边越准。
	var cap := (child as Node).get_node_or_null("CellCaption") as Control
	if cap != null and bool(cap.get_meta("caption_centroid", false)):
		var ctr := Vector2.ZERO
		for p in local:
			ctr += p
		ctr /= float(maxi(1, local.size()))
		var cw: float = cap.get_meta("caption_w", 156.0)
		var ch: float = cap.get_meta("caption_h", 37.0)
		var cdx: float = cap.get_meta("caption_dx", 0.0)
		var cdrop: float = cap.get_meta("caption_drop", 0.0)
		cap.anchor_left = 0.0
		cap.anchor_top = 0.0
		cap.anchor_right = 0.0
		cap.anchor_bottom = 0.0
		cap.offset_left = ctr.x - cw * 0.5 + cdx
		cap.offset_right = ctr.x + cw * 0.5 + cdx
		var cy := ctr.y + bounds.size.y * cdrop
		cap.offset_top = cy - ch * 0.5
		cap.offset_bottom = cy + ch * 0.5

# 把 16 个主战格子用 3D 投影对齐到石台上，画成跟着斜面的椭圆圆圈
func _realign_prep_board_cells() -> void:
	if _board_hud.grid == null or _prep_river_camera == null or _prep_river_viewport == null:
		return
	if not _board_hud.grid.is_inside_tree():
		return
	var grid_origin := _board_hud.grid.global_position
	var cols := GameConstants.BOARD_COLUMNS
	var rows := GameConstants.BOARD_ROWS
	for child in _board_hud.grid.get_children():
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
	# 记下这次对齐用的原点，「持续守卫」靠它判断棋盘有没有被挪走（见
	# `_tick_prep_board_layout_guard` 的注释）。
	_prep_aligned_grid_pos = _board_hud.grid.global_position
	_sync_prep_board_readability_geometry()
	_sync_prep_board_readability_state()

# 把 8 个待命卡片用 3D 投影散落到左草地，画成跟着斜面的椭圆圆圈
func _realign_prep_standby_cells() -> void:
	if _board_hud.standby_frame == null or _prep_river_camera == null or _prep_river_viewport == null:
		return
	if not _board_hud.standby_frame.is_inside_tree():
		return
	var origin := _board_hud.standby_frame.global_position
	for child in _board_hud.standby_frame.get_children():
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
	var v := lerpf(BOARD_STONE_V.x, BOARD_STONE_V.y, (float(row) + 0.60) / float(GameConstants.BOARD_ROWS))
	# 模型"离棋盘中心的横/纵距离"按 SPREAD 缩放（圆圈不受影响）：治"中间对齐、越往边越偏"。
	var center_u := (BOARD_STONE_U.x + BOARD_STONE_U.y) * 0.5
	var center_v := (BOARD_STONE_V.x + BOARD_STONE_V.y) * 0.5
	u = center_u + (u - center_u) * BOARD_MODEL_SPREAD_U
	v = center_v + (v - center_v) * BOARD_MODEL_SPREAD_V
	var world_pos := _board_plane_world_pos(u, v)
	world_pos.y += PREP_CELL_MARK_Y_LIFT
	if _prep_model_root != null and _prep_model_root.is_inside_tree():
		model_node.position = _prep_model_root.to_local(world_pos)
		# The stage and board root are translated/scaled. Replacing the converted
		# local Y with zero lifts every piece 0.212 world units above its cell.
		model_node.position.y += unit_y_offset
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
	var plane_local := _prep_model_root.to_local(PREP_BOARD_GROUND_CENTER + Vector3(0.0, PREP_CELL_MARK_Y_LIFT, 0.0))
	plane_local.y += unit_y_offset
	var plane_origin := _prep_model_root.to_global(plane_local)
	var plane_normal := _prep_model_root.global_transform.basis.y.normalized()
	var ground_plane := Plane(plane_normal, plane_origin)
	var hit = ground_plane.intersects_ray(ray_origin, ray_direction)
	if hit == null:
		return null
	var local_hit := _prep_model_root.to_local(hit)
	local_hit.y = plane_local.y
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
		world_pos.y += PREP_STANDBY_BG_Y_LIFT
		# 模型"离整排中心的横向距离"按 SPREAD 缩放（圆圈不受影响）：治"中间对齐、越往两边越偏"。
		var center_wx := _board_plane_world_pos(STANDBY_CENTER_U, spot.y).x
		world_pos.x = center_wx + (world_pos.x - center_wx) * STANDBY_MODEL_SPREAD
		world_pos.x += STANDBY_MODEL_DX   # 微调左右：正=右移
		world_pos.z += STANDBY_MODEL_DZ   # 微调前后：正=近/下移，负=远/上移
		model_node.position = _prep_standby_model_root.to_local(world_pos)
		model_node.position.y += standby_unit_y_offset
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

# 备战棋盘和战斗共用 BattleAssetService 的缓存。
#
# 以前这里有自己的 _prep_model_scene_cache，和 BattleUI._model_scene_cache 互不知情，
# 同一个模型要加载两遍；而且它是实例变量，每回合随备战场景销毁。
# 实测放下第一个棋子冻结 3.3 秒（tex +11.1 MB），就是在这里现加载。
func _prep_model_scene_for_path(model_path: String) -> PackedScene:
	return BattleAssetService.get_scene(model_path)

func _prep_animation_scene_for_path(scene_path: String) -> PackedScene:
	if not _prep_model_path_available(scene_path):
		return null
	return BattleAssetService.get_scene(scene_path)

func _prep_display_unit_def(cell: Dictionary) -> Dictionary:
	return UnitVisualResolverScript.resolve_for_cell(cell)

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
	# A skinned mesh AABB describes its bind pose, not its idle stance. Several
	# human rigs retained a full model unit of forward offset after AABB fitting,
	# which pushed their bodies against the platform captions. Anchor only X/Z
	# to the live feet; keep the established vertical clearance unchanged.
	var foot_center: Variant = _prep_model_foot_center(model)
	if foot_center is Vector3:
		model.position -= Vector3(foot_center.x, 0.0, foot_center.z)

func _prep_model_foot_center(model: Node3D) -> Variant:
	var parent := model.get_parent() as Node3D
	if parent == null or not model.is_inside_tree():
		return null
	var total := Vector3.ZERO
	var count := 0
	for node in model.find_children("*", "Skeleton3D", true, false):
		var skeleton := node as Skeleton3D
		# The whole prep stage can still be hidden during its first-frame reveal;
		# exclude hidden action branches, not a hidden ancestor outside this model.
		var branch: Node = skeleton
		var active := true
		while branch != model and branch != null:
			if branch is Node3D and not (branch as Node3D).visible:
				active = false
				break
			branch = branch.get_parent()
		if not active:
			continue
		for bone_index in skeleton.get_bone_count():
			if not skeleton.get_bone_name(bone_index).to_lower().ends_with("foot"):
				continue
			total += parent.to_local(skeleton.to_global(skeleton.get_bone_global_pose(bone_index).origin))
			count += 1
	return total / float(count) if count > 0 else null

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
