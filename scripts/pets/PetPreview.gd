extends RefCounted

# 宠物的 3D 小预览（一个 SubViewport + 正交相机 + 一盏主光）。
#
# 从 scenes/menu/PetScreen.gd 抽出来的共用预览。商店与备战卡片优先展示
# pets.json 的手绘插画；背包也展示手绘插画，主菜单与缺图回退仍使用 3D 模型。
#
# 用法：
#     content.add_child(PetPreview.build(pet_id, PetPreview.CARD_SIZE, not owned))
#
# 参数里的 greyed 是「未拥有」的表现。**不能靠调灯光实现** —— toon shader 是
# ambient_light_disabled，暗部由 fragment 里的 EMISSION 兜底，调灯几乎不影响亮度。
# 所以盖一层暗色 ColorRect。

const PetService := preload("res://scripts/pets/PetService.gd")

const CARD_SIZE := Vector2(180, 130)
const CAMERA_POS := Vector3(0.0, 1.05, 2.05)
const CAMERA_TARGET := Vector3(0.0, 0.48, 0.0)
const ORTHO_SIZE := 1.35
const TARGET_HEIGHT := 0.95

# 读条进度条上「跟着进度跑」的宠物（10.05 反馈第 5 条）。
const RUNNER_SIZE := Vector2(64, 64)
# 侧前方视角：跑动/前进走动这类动作从侧面最好认（正面看就是原地踏步）。
const RUNNER_CAMERA_POS := Vector3(-1.35, 0.78, 1.15)
const RUNNER_CAMERA_TARGET := Vector3(0.0, 0.46, 0.0)
# 1.16 → 1.40（10.05 第 5 条返工）：不再靠「单帧量一次」拍板，而是按帧采样整个 run 周期
# 取最坏一帧（work/_qa_1005d/probe_petanim_1005d）。跑步时身体前后摆，单帧余量会被吃掉：
#   1.16 → 猫 1px / 蘑菇 5px / 兔 6px（宠物会擦边甚至被裁）
#   1.40 → 猫 15px / 蘑菇 18px / 兔 19px（160px 框上约 9% 留白）
#   1.50 → 19px 起（再放大宠物就明显变小了，不值）
const RUNNER_ORTHO_SIZE := 1.40


# 商店和备战卡片展示数据表中的手绘图；未配置或缺失时回退到现有模型预览。
# 主菜单和战场继续调用 build()，不改变它们的 3D 展示。
static func build_illustration(pet_id: String, size: Vector2 = CARD_SIZE,
	greyed: bool = false) -> Control:
	var icon_path := str(PetService.pet_by_id(pet_id).get("icon", ""))
	if icon_path.is_empty() or not ResourceLoader.exists(icon_path):
		return build(pet_id, size, greyed)
	var texture := load(icon_path) as Texture2D
	if texture == null:
		return build(pet_id, size, greyed)
	var frame := Control.new()
	frame.custom_minimum_size = size
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var art := TextureRect.new()
	art.texture = texture
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if greyed:
		art.modulate = Color(0.45, 0.45, 0.45)
	frame.add_child(art)
	return frame


# 没有模型 / 模型加载失败时都回占位框，**不返回 null** ——
# 调用方直接 add_child，多一个空判就多一处会忘的地方。
static func build(pet_id: String, size: Vector2 = CARD_SIZE, greyed: bool = false,
	camera_size: float = ORTHO_SIZE, camera_y_offset: float = 0.0) -> Control:
	var path := PetService.model_path(pet_id)
	if path.is_empty():
		return placeholder(size, greyed)
	var scene := ResourceLoader.load(path) as PackedScene
	if scene == null:
		return placeholder(size, greyed)
	var model := scene.instantiate() as Node3D
	if model == null:
		return placeholder(size, greyed)

	var frame := Panel.new()
	frame.custom_minimum_size = size

	var container := SubViewportContainer.new()
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.add_child(container)

	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(viewport)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.0, 0.0, 0.0, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.58, 0.68, 0.61)
	env.ambient_light_energy = 0.40
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env_node.environment = env
	viewport.add_child(env_node)

	var key_light := DirectionalLight3D.new()
	key_light.light_color = Color(1.0, 0.92, 0.76)
	key_light.light_energy = 0.64
	key_light.rotation_degrees = Vector3(-52.0, -28.0, 0.0)
	key_light.shadow_enabled = false
	viewport.add_child(key_light)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = camera_size
	var camera_offset := Vector3(0.0, camera_y_offset, 0.0)
	camera.look_at_from_position(CAMERA_POS + camera_offset,
		CAMERA_TARGET + camera_offset, Vector3.UP)
	camera.current = true
	viewport.add_child(camera)

	viewport.add_child(model)
	fit_when_ready(model, pet_id)

	if greyed:
		var dim := ColorRect.new()
		dim.color = Color(0.0, 0.0, 0.0, 0.55)
		dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		frame.add_child(dim)
	return frame


# 把模型缩放到统一高度并把脚底对齐到框底。各宠物的模型尺寸差很多，
# 不做这一步的话兔子会比蘑菇大一圈。**调用时机见 `fit_when_ready()`：直接在模型
# 还没进树时调它，量到的是空包围盒，等于没归一化。**
static func normalize(model: Node3D, pet_id: String) -> void:
	var box := aabb_of(model)
	var height := maxf(0.0001, box.size.y)
	var factor := TARGET_HEIGHT / height * PetService.model_scale(pet_id)
	model.scale = Vector3.ONE * factor
	# ★ 脚底基准**不能**用 `box.position.y`（10.05 第 5 条返工的根因）。
	#
	# 宠物 FBX 导入后是 `ModelRoot/Armature(scale=100)/Skeleton3D/Mesh1_0`，
	# `MeshInstance3D.get_aabb()` 给的是**以网格节点原点为中心**的盒子 —— 实测三只
	# 宠物的盒子都关于 0 对称（猫 [-0.794, +0.790]、蘑菇 [-0.747, +0.749]、
	# 兔 [-0.949, +0.948]）：**高度是对的，基准错了半身**。
	# 而真正被动画驱动、真正被渲染出来的几何（骨骼当前姿势）是 [0.000, +1.178]
	# —— 脚底恰好落在 local y = 0（见 work/_qa_1005d/probe_petbones_1005d）。
	# 拿盒底当脚底 ⇒ 宠物被整体抬高半身 ⇒ 头顶出画，读条上那只猫只剩斗篷
	#（用户 10.05 截图 feedback 第 5 条）。
	# 高度继续用 AABB（实测与骨骼+网格一致），只把基准换成骨骼下沿。
	var anchor := skeleton_bottom(model, box)
	model.position.y = -anchor * factor + PetService.model_y(pet_id)


# 模型**当前姿势**的脚底高度（模型 local 空间）。骨骼才是动画真正驱动的东西，
# `MeshInstance3D.get_aabb()` 不是（详见 `normalize()` 的说明）。
# 找不到骨骼时退回包围盒底 —— 与改之前同口径，至少不会更差。
static func skeleton_bottom(root: Node3D, box: AABB) -> float:
	var found := false
	var bottom := 0.0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		for child in current.get_children():
			stack.append(child)
		if not (current is Skeleton3D):
			continue
		var skeleton := current as Skeleton3D
		if skeleton.get_bone_count() == 0 or not shown_under(root, skeleton):
			continue
		var local := root.global_transform.affine_inverse() * skeleton.global_transform
		for i in skeleton.get_bone_count():
			var y := (local * skeleton.get_bone_global_pose(i).origin).y
			if found:
				bottom = minf(bottom, y)
			else:
				bottom = y
				found = true
	return bottom if found else box.position.y


# 读条进度条上跟着进度前进的宠物（10.05 反馈第 5 条）。
#
# 与 build() 的三点差别：
#   1. 相机从**侧前方**看 —— 跑动/前进走动从侧面最好认；
#   2. 模型按 `play_run()` 播跑动片段（宠物库没有 idle 片段，`play_idle` 是一帧静止，
#      见 PrepBoardModels._play_carrot_pet_ambient 的注释）；
#   3. 尺寸先自己设好再交给调用方 —— 调用方是把它挂在 ProgressBar 底下的，
#      而 ProgressBar 不是容器，不会替子节点套用 custom_minimum_size。
#
# 没有宠物 / 模型缺失时返回 **null**（不是占位框）：读条上不该出现一个「?」，
# 玩家会以为加载出错了。调用方看到 null 就只留进度条。
#
# `camera_size` / `camera_y_offset` 与 `build()` 同名同义，默认取上面的常量。
# 加这两个参数是为了能用同一份生产代码做**取景标定**（work/_qa_1005d 的扫描探针），
# 而不是在探针里照抄一遍相机参数。
static func build_runner(pet_id: String, size: Vector2 = RUNNER_SIZE,
	camera_size: float = RUNNER_ORTHO_SIZE, camera_y_offset: float = 0.0) -> Control:
	if pet_id.is_empty():
		return null
	var path := PetService.model_path(pet_id)
	if path.is_empty():
		return null
	var scene := ResourceLoader.load(path) as PackedScene
	if scene == null:
		return null
	var model := scene.instantiate() as Node3D
	if model == null:
		return null

	var frame := Panel.new()
	frame.custom_minimum_size = size
	frame.size = size
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_theme_stylebox_override("panel", StyleBoxEmpty.new())

	var container := SubViewportContainer.new()
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.add_child(container)

	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.disable_3d = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(viewport)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.0, 0.0, 0.0, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.72, 0.66)
	env.ambient_light_energy = 0.45
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env_node.environment = env
	viewport.add_child(env_node)

	var key_light := DirectionalLight3D.new()
	key_light.light_color = Color(1.0, 0.94, 0.80)
	key_light.light_energy = 0.70
	key_light.rotation_degrees = Vector3(-46.0, 18.0, 0.0)
	key_light.shadow_enabled = false
	viewport.add_child(key_light)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = camera_size
	var runner_offset := Vector3(0.0, camera_y_offset, 0.0)
	camera.look_at_from_position(RUNNER_CAMERA_POS + runner_offset,
		RUNNER_CAMERA_TARGET + runner_offset, Vector3.UP)
	camera.current = true
	viewport.add_child(camera)

	viewport.add_child(model)
	# ★ 先切动作、再量包围盒：两个都挂在模型的 `ready` 上，按连接顺序回调（先 run 后 fit）。
	# 量尺寸只看显示着的子模型（shown_under），这样量到的就是读条上真正在跑的那个（10-07 起；
	# 之前是先量后切，量的是待机模型）。
	play_run(model)
	fit_when_ready(model, pet_id)
	return frame


# 「等模型真的进树、`_ready()` 跑完再量包围盒」的时机处理（10.05 第 5 条返工）。
#
# 根因：宠物模型的三个动作子模型是 `_load_action_models()` 在**模型的 `_ready()` 里**
# 建的（见 assets/models/pets/pet_cat/PetCatAnimated.gd），而 `build()` / `build_runner()`
# 返回的 frame 还没被调用方 `add_child` —— 此刻模型不在树里，`_ready()` 没跑，
# ModelRoot 下**一个 MeshInstance3D 都没有**。`aabb_of()` 于是找不到网格，落到兜底的
# `AABB(Vector3.ZERO, Vector3.ONE)`（size.y = 1.0），`normalize()` 按「模型高 1.0」算出
# 缩放系数恒为 0.95 —— 而真实模型高约 1.5~1.9 ⇒ 宠物被画面裁掉，
# 就是用户反馈的「宠物的模型不全」（读条上那只猫只看得见头和斗篷）。
#
# 实测（work/_qa_1005d/probe_petfit，改前）：三只宠物 × 两条入口（build/build_runner）
# × 两种姿势，渲染出来的**不透明像素全部贴住画面四边**（即全部被裁），
# 且 `model.scale` 恒为 0.950、`model.position.y` 恒为 0.000。
static func fit_when_ready(model: Node3D, pet_id: String) -> void:
	if model == null or not is_instance_valid(model):
		return
	if model.is_node_ready():
		normalize(model, pet_id)
	else:
		model.ready.connect(func() -> void: normalize(model, pet_id), CONNECT_ONE_SHOT)


# 把模型切到跑动片段。宠物模型不一定都有这个动作 —— **没有 `play_run()` 方法的
# 模型保持默认姿态，不报错**（所以下面用 `has_method` 兜底）。
# 调用时机见函数体内的说明：不能在模型还没进树时直接调。
static func play_run(model: Node3D) -> void:
	if model == null or not is_instance_valid(model):
		return
	if not model.has_method("play_run"):
		return
	# ★ 不能在「模型还没进树」时直接调。宠物脚本里写的是
	#   `@onready var animation_player: AnimationPlayer = $AnimationPlayer`，
	#   而 @onready 只在 `_ready()` 那一刻赋值；build_runner 返回的 frame 还没被
	#   调用方 add_child，模型此时不在树里 ⇒ `animation_player` 仍是 null，
	#   直接调会让它在模型内部炸出
	#   `Cannot call method 'play' on a null value`（10.05 实测，被读条门禁日志抓到）。
	#   而且模型的 `_ready()` 结尾自己会 `play_idle()` —— 抢在它前面调，
	#   就算不炸也会被那一句覆盖回静止帧。
	#   所以：已经 ready 就直接切；没 ready 就挂一次性 `ready` 信号（该信号在
	#   `_ready()` 之后才发），等它自己初始化完再切到跑动。
	if model.is_node_ready():
		model.call("play_run")
	else:
		model.ready.connect(func() -> void: model.call("play_run"), CONNECT_ONE_SHOT)


# 模型自己的包围盒。用遍历而不是 model.get_aabb()：Node3D 没有那个方法，
# 而且模型是一整棵树，只有 MeshInstance3D 上才有网格。
# 只算**现在画得出来**的那个动作模型（见 shown_under）；一个都看不到时才退回全部网格。
static func aabb_of(root: Node3D) -> AABB:
	var box := _mesh_box(root, true)
	if box.size == Vector3.ZERO:
		box = _mesh_box(root, false)
	return box if box.size != Vector3.ZERO else AABB(Vector3.ZERO, Vector3.ONE)


static func _mesh_box(root: Node3D, shown_only: bool) -> AABB:
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
		if mesh_instance.mesh == null or (shown_only and not shown_under(root, mesh_instance)):
			continue
		var box := mesh_box_in(root, mesh_instance)
		if found:
			out = out.merge(box)
		else:
			out = box
			found = true
	return out


# node 在 root 以下这几层里是不是都显示着。宠物的待机 / 跑 / 攻击各是一个子模型，
# 同一时间只显示一个；藏着的那几个不该参与量尺寸、对脚底（10-07）：老虎的跑步模型
# 原文件小约 488 倍、靠 ImportedPetAnimated.run_model_scale 放大，它的骨架算进来
# 会把包围盒和脚底拉偏。只看到 root 为止 —— 整只宠物先藏着再归一化
# （萝卜营地的宠物 visible=false 时量）不受影响。
static func shown_under(root: Node, node: Node) -> bool:
	var current := node
	while current != null and current != root:
		if current is Node3D and not (current as Node3D).visible:
			return false
		current = current.get_parent()
	return true


# 一个网格在 root 空间里**实际画出来**的包围盒。主界面走动的宠物（MainMenuPet）、
# 萝卜营地的宠物（PrepBoardModels）也用这一个，别再各写一份。
#
# 蒙皮网格画在哪由骨架决定：骨架 × 骨头 × 绑定逆矩阵 × 顶点，网格节点自己的变换不参与。
# 只拿 网格节点变换 × get_aabb() 去量，在骨架和网格单位不一致的模型上会差很多（10-07）：
#   · 松鼠（CC 骨架、厘米、Armature 缩 0.01）量成 0.019、实际 1.89 → 归一化放大五十倍，主界面整个框被它占满
#   · 老虎量成 1.95、实际 1.59 → 比别的宠物小两成
# 猫 / 兔 / 蘑菇的绑定是单位矩阵，两种量法结果一样（逐顶点蒙皮核对过）。
# 用静止姿势（rest）算，不随当前动作帧变。
static func mesh_box_in(root: Node3D, mesh_instance: MeshInstance3D) -> AABB:
	var to_root := root.global_transform.affine_inverse()
	var skeleton := mesh_instance.get_node_or_null(mesh_instance.skeleton) as Skeleton3D
	var skin := mesh_instance.skin
	if skeleton != null and skin != null and skin.get_bind_count() > 0:
		var bone := skin.get_bind_bone(0)
		if bone < 0:
			bone = skeleton.find_bone(skin.get_bind_name(0))
		if bone >= 0:
			var bind := skeleton.get_bone_global_rest(bone) * skin.get_bind_pose(0)
			return (to_root * skeleton.global_transform * bind) * mesh_instance.get_aabb()
	return (to_root * mesh_instance.global_transform) * mesh_instance.get_aabb()


static func placeholder(size: Vector2 = CARD_SIZE, greyed: bool = false) -> Control:
	var frame := Panel.new()
	frame.custom_minimum_size = size
	var q := Label.new()
	q.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	q.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	q.add_theme_font_size_override("font_size", 44)
	q.text = "?"
	q.add_theme_color_override("font_color", Color(0.4, 0.4, 0.45) if greyed else Color(0.7, 0.7, 0.75))
	q.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(q)
	return frame
