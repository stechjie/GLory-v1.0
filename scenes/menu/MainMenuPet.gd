extends Control
# 主菜单中心草地上的宠物。玩家拥有的宠物每只出一个（上限 MAX_PETS 只），各走各的：
# 在「停顿 / 移动 / 做动作」三个状态之间随机切换。
#
# 3D 跑在自己的 SubViewport 里，并且 own_world_3d = true —— 里面是一个独立的 3D 世界，
# 只有宠物、灯光和相机。调这里的相机只影响宠物怎么被画出来，碰不到背景图。
#
# 手机端的开销控制：30Hz 出图而不是 60Hz；看不见（弹窗遮住、切走）时完全停画。

const REF_SIZE := Vector2(1672.0, 941.0)   # 与 MainMenu 同一套参考画布

# ── 活动区域（参考坐标）──────────────────────────────────────────
# 上边避开个人信息按钮（y 12~190），下边避开令牌行/底部按钮（y 585 起），
# 左右避开朋友/聊天与商店/公告两根侧栏。开 F3 能看到这块的黑框。
const AREA_POS := Vector2(250.0, 205.0)
const AREA_SIZE := Vector2(1080.0, 360.0)
# 视口初始尺寸。注意：SubViewportContainer.stretch = true 之后，视口分辨率会跟着
# 容器的屏幕尺寸走，这个值只是个初值。要真正封顶渲染分辨率就调容器的 stretch_shrink。
# 目前没封：三只宠物加起来才 ~9000 面，实测开销可以忽略。
const VIEWPORT_SIZE := Vector2i(1080, 360)
const RENDER_HZ := 30.0

const MAX_PETS := 5

# ── 3D 舞台（正交相机，好算也好调）────────────────────────────────
# 地面在 y=0 平面，宠物在 X(左右) / Z(远近) 上走动。
const GROUND_HALF_X := 4.8
const GROUND_HALF_Z := 1.5
const CAMERA_POS := Vector3(0.0, 2.6, 4.2)
const CAMERA_TARGET := Vector3(0.0, 0.5, 0.0)
const CAMERA_ORTHO_SIZE := 3.6

# ── 宠物 ────────────────────────────────────────────────────────
const PET_TARGET_HEIGHT := 0.95   # 统一归一化到这个世界高度，再乘 pets.json 的 model_scale
const MOVE_SPEED := 1.15          # 单位/秒。调这个跟 run 的步频对齐，避免脚底打滑
const TURN_SPEED := 7.0
const MIN_SEPARATION := 1.35      # 两只靠得比这近就互相推开，避免叠在一起
const SEPARATION_PUSH := 1.1
const ARRIVE_DIST := 0.12

const IDLE_TIME := Vector2(1.5, 4.0)
const ACTION_TIME := Vector2(0.9, 1.5)
const WALK_TIMEOUT := 8.0
# 停顿结束后各状态的权重
const WEIGHT_WALK := 62
const WEIGHT_ACTION := 24
const WEIGHT_IDLE := 14

var _viewport: SubViewport
var _container: SubViewportContainer
# 出图之前不显示容器，见 _build_stage 里那段说明。
var _revealing := false
var _stage: Node3D
var _camera: Camera3D
var _pets: Array[Dictionary] = []
var _shadow_texture: GradientTexture2D
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE   # 绝对不能吃掉点击
	set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_rng.randomize()
	_build_stage()
	_rebuild_pets()
	if not PlayerProfile.pets_changed.is_connected(_rebuild_pets):
		PlayerProfile.pets_changed.connect(_rebuild_pets)
	get_viewport().size_changed.connect(_layout_area)
	_layout_area()
	# 不等第一个 30Hz tick（33ms）。立刻请求一次出图，
	# 显示时机交给 _tick_render 里那段等 frame_post_draw 的逻辑。
	_tick_render()

func _build_stage() -> void:
	var container := SubViewportContainer.new()
	container.name = "PetStage"
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# ⚠️ **出过第一帧之前不显示。**
	#
	# SubViewportContainer 直接把视口的渲染目标画出来，而一个**从未渲染过**的
	# 渲染目标里是未定义内容 —— 在 D3D12 / GL 兼容模式下表现为**不透明黑**。
	# 视口建出来时是 UPDATE_DISABLED（省电），第一次出图要等 30Hz 定时器，
	# 而真正画完还要等材质首次编译，实测能到 0.4 秒以上。
	#
	# 那段时间玩家看到的就是主菜单正中央一块黑格，大小正好是
	# AREA_SIZE(1080x360) 按参考画布缩放后的尺寸。每次进主菜单都会出现，
	# 从别的界面返回主菜单（菜单是重建的）也会。
	#
	# 藏起来的代价是最初一两帧那块地方是空草地 —— 本来就该是草地。
	container.visible = false
	_container = container
	add_child(container)

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.size = VIEWPORT_SIZE
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	container.add_child(_viewport)

	# 灯光/环境沿用备战佣兵展示台那一套，模型观感跟棋子一致
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.0, 0.0, 0.0, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.58, 0.68, 0.61)
	env.ambient_light_energy = 0.40
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env_node.environment = env
	_viewport.add_child(env_node)

	var key_light := DirectionalLight3D.new()
	key_light.light_color = Color(1.0, 0.92, 0.76)
	key_light.light_energy = 0.64
	key_light.rotation_degrees = Vector3(-52.0, -28.0, 0.0)
	key_light.shadow_enabled = false
	_viewport.add_child(key_light)

	var fill_light := DirectionalLight3D.new()
	fill_light.light_color = Color(0.48, 0.68, 0.82)
	fill_light.light_energy = 0.18
	fill_light.rotation_degrees = Vector3(-38.0, 142.0, 0.0)
	fill_light.shadow_enabled = false
	_viewport.add_child(fill_light)

	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = CAMERA_ORTHO_SIZE
	_camera.look_at_from_position(CAMERA_POS, CAMERA_TARGET, Vector3.UP)
	_camera.current = true
	_viewport.add_child(_camera)

	_stage = Node3D.new()
	_stage.name = "PetStageRoot"
	_viewport.add_child(_stage)

	_shadow_texture = _make_shadow_texture()

	# 30Hz 出图：动画推进不受影响，省掉一半的绘制
	var timer := Timer.new()
	timer.wait_time = 1.0 / RENDER_HZ
	timer.autostart = true
	timer.timeout.connect(_tick_render)
	add_child(timer)

func _tick_render() -> void:
	if _viewport == null:
		return
	# 看不见就别画（弹窗挡住、切到别的界面），没有宠物也没什么可画
	var want := is_visible_in_tree() and not _pets.is_empty()
	if not want:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		# 没有宠物时把容器收起来：留着只会显示上一次的残影，
		# 或者（首次进入时）那块从没画过的黑。
		if _container != null and is_instance_valid(_container):
			_container.visible = false
		return

	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	if _container == null or not is_instance_valid(_container):
		return
	if _container.visible or _revealing:
		return

	# 等这一帧**真的画完**再显示。
	# 必须是 frame_post_draw 而不是 process_frame —— 后者在绘制之前就返回，
	# 容器会抢在渲染目标被写入之前先画一次，黑格照旧。
	_revealing = true
	await RenderingServer.frame_post_draw
	# await 期间主菜单可能已经被换掉（进备战、进战斗、开资料页都会重建菜单）。
	# 不加这道判断就会在已经离树的节点上继续跑。
	if not is_inside_tree():
		return
	_revealing = false
	if is_instance_valid(_container):
		_container.visible = true

# 脚下的软阴影：径向渐变，比开真阴影便宜得多，也好调
func _make_shadow_texture() -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.06, 0.05, 0.03, 0.42))
	gradient.set_color(1, Color(0.06, 0.05, 0.03, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 64
	tex.height = 64
	return tex

# ── 宠物生成 ────────────────────────────────────────────────────
func _rebuild_pets() -> void:
	for item in _pets:
		var node := item.node as Node3D
		if is_instance_valid(node):
			node.queue_free()
	_pets.clear()
	if _stage == null:
		return
	var ids: Array = PlayerProfile.owned_pets.duplicate()
	for i in range(min(ids.size(), MAX_PETS)):
		_spawn_pet(str(ids[i]), i, min(ids.size(), MAX_PETS))

func _spawn_pet(pet_id: String, index: int, total: int) -> void:
	var path := PetService.model_path(pet_id)
	if path.is_empty():
		return
	var scene := ResourceLoader.load(path) as PackedScene
	if scene == null:
		push_warning("宠物模型加载失败：%s" % path)
		return
	var node := scene.instantiate() as Node3D
	if node == null:
		return
	_stage.add_child(node)   # add_child 之后子模型已经加载完，可以量 AABB 了
	_normalize_model(node, pet_id)

	var shadow := _make_shadow_node()
	node.add_child(shadow)

	# 初始位置沿 X 均分铺开，免得开局全挤在中间
	var t := (float(index) + 0.5) / float(max(1, total))
	var start := Vector3(lerpf(-GROUND_HALF_X * 0.7, GROUND_HALF_X * 0.7, t),
		0.0, _rng.randf_range(-GROUND_HALF_Z, GROUND_HALF_Z))
	node.position = Vector3(start.x, node.position.y, start.z)

	var entry := {
		"id": pet_id,
		"node": node,
		"shadow": shadow,
		"state": "idle",
		"timer": _rng.randf_range(IDLE_TIME.x, IDLE_TIME.y),
		"target": start,
		"facing": _rng.randf_range(-PI, PI),
		"base_y": node.position.y,
	}
	_pets.append(entry)
	_play(node, "idle")

# Meshy 出的模型尺度是随的，按包围盒归一化到统一高度，并把脚底对齐到 y=0
func _normalize_model(node: Node3D, pet_id: String) -> void:
	var box := _model_aabb(node)
	var height := maxf(0.0001, box.size.y)
	var factor := PET_TARGET_HEIGHT / height * PetService.model_scale(pet_id)
	node.scale = Vector3.ONE * factor
	node.position.y = -box.position.y * factor + PetService.model_y(pet_id)

func _model_aabb(root: Node3D) -> AABB:
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
	return out if found else AABB(Vector3.ZERO, Vector3.ONE)

func _make_shadow_node() -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(1.15, 1.15)
	var material := StandardMaterial3D.new()
	material.albedo_texture = _shadow_texture
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = false
	var node := MeshInstance3D.new()
	node.name = "Shadow"
	node.mesh = quad
	node.material_override = material
	node.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	node.position = Vector3(0.0, 0.01, 0.0)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

# ── 行为状态机 ──────────────────────────────────────────────────
func _process(delta: float) -> void:
	if _pets.is_empty() or not is_visible_in_tree():
		return
	for entry in _pets:
		_step_pet(entry, delta)
	_separate_pets(delta)

func _step_pet(entry: Dictionary, delta: float) -> void:
	var node := entry.node as Node3D
	if not is_instance_valid(node):
		return
	entry.timer = float(entry.timer) - delta
	match str(entry.state):
		"idle":
			if float(entry.timer) <= 0.0:
				_pick_next_state(entry)
		"action":
			if float(entry.timer) <= 0.0:
				_enter_idle(entry)
		"walk":
			var target := entry.target as Vector3
			var flat := Vector3(node.position.x, 0.0, node.position.z)
			var to_target := Vector3(target.x - flat.x, 0.0, target.z - flat.z)
			if to_target.length() <= ARRIVE_DIST or float(entry.timer) <= 0.0:
				_enter_idle(entry)
				return
			var dir := to_target.normalized()
			node.position += dir * MOVE_SPEED * delta
			_clamp_to_ground(node)
			entry.facing = atan2(dir.x, dir.z)
	_apply_facing(entry, delta)

func _pick_next_state(entry: Dictionary) -> void:
	var roll := _rng.randi_range(0, WEIGHT_WALK + WEIGHT_ACTION + WEIGHT_IDLE - 1)
	if roll < WEIGHT_WALK:
		_enter_walk(entry)
	elif roll < WEIGHT_WALK + WEIGHT_ACTION:
		_enter_action(entry)
	else:
		_enter_idle(entry)

func _enter_idle(entry: Dictionary) -> void:
	entry.state = "idle"
	entry.timer = _rng.randf_range(IDLE_TIME.x, IDLE_TIME.y)
	_play(entry.node as Node3D, "idle")

func _enter_walk(entry: Dictionary) -> void:
	entry.state = "walk"
	entry.timer = WALK_TIMEOUT
	entry.target = Vector3(_rng.randf_range(-GROUND_HALF_X, GROUND_HALF_X), 0.0,
		_rng.randf_range(-GROUND_HALF_Z, GROUND_HALF_Z))
	_play(entry.node as Node3D, "run")

func _enter_action(entry: Dictionary) -> void:
	entry.state = "action"
	entry.timer = _rng.randf_range(ACTION_TIME.x, ACTION_TIME.y)
	_play(entry.node as Node3D, "attack")

func _apply_facing(entry: Dictionary, delta: float) -> void:
	var node := entry.node as Node3D
	var current := node.rotation.y
	var wanted := float(entry.facing)
	node.rotation.y = current + wrapf(wanted - current, -PI, PI) * minf(1.0, TURN_SPEED * delta)

func _clamp_to_ground(node: Node3D) -> void:
	node.position.x = clampf(node.position.x, -GROUND_HALF_X, GROUND_HALF_X)
	node.position.z = clampf(node.position.z, -GROUND_HALF_Z, GROUND_HALF_Z)

# 靠太近就互相推开，避免两只叠在一起
func _separate_pets(delta: float) -> void:
	if _pets.size() < 2:
		return
	for i in range(_pets.size()):
		for j in range(i + 1, _pets.size()):
			var a := _pets[i].node as Node3D
			var b := _pets[j].node as Node3D
			if not is_instance_valid(a) or not is_instance_valid(b):
				continue
			var offset := Vector3(b.position.x - a.position.x, 0.0, b.position.z - a.position.z)
			var distance := offset.length()
			if distance >= MIN_SEPARATION:
				continue
			var push := (offset / maxf(distance, 0.001)) if distance > 0.001 else Vector3(1.0, 0.0, 0.0)
			var amount := (MIN_SEPARATION - distance) * 0.5 * SEPARATION_PUSH * delta
			a.position -= push * amount
			b.position += push * amount
			_clamp_to_ground(a)
			_clamp_to_ground(b)

func _play(node: Node3D, action: String) -> void:
	if not is_instance_valid(node):
		return
	match action:
		"run":
			if node.has_method("play_run"):
				node.call("play_run")
		"attack":
			if node.has_method("play_attack"):
				node.call("play_attack")
		_:
			if node.has_method("play_idle"):
				node.call("play_idle")

# ── 布局：跟 MainMenu 用同一套参考画布，居中缩放 ──────────────────
func _layout_area() -> void:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var scale := minf(viewport_size.x / REF_SIZE.x, viewport_size.y / REF_SIZE.y)
	var origin := (viewport_size - REF_SIZE * scale) * 0.5
	position = origin + AREA_POS * scale
	size = AREA_SIZE * scale
