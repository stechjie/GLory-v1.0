extends RefCounted

# 宠物的 3D 小预览（一个 SubViewport + 正交相机 + 一盏主光）。
#
# 从 scenes/menu/PetScreen.gd 抽出来的 —— 商城和背包也要显示宠物，
# 而 data/pets/pets.json 的 icon 字段是空的：**宠物没有 2D 图，只有模型**。
# 不抽的话这七十行会被抄三遍，以后调一次相机角度要改三处。
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


# 没有模型 / 模型加载失败时都回占位框，**不返回 null** ——
# 调用方直接 add_child，多一个空判就多一处会忘的地方。
static func build(pet_id: String, size: Vector2 = CARD_SIZE, greyed: bool = false) -> Control:
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
	camera.size = ORTHO_SIZE
	camera.look_at_from_position(CAMERA_POS, CAMERA_TARGET, Vector3.UP)
	camera.current = true
	viewport.add_child(camera)

	viewport.add_child(model)
	normalize(model, pet_id)

	if greyed:
		var dim := ColorRect.new()
		dim.color = Color(0.0, 0.0, 0.0, 0.55)
		dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		frame.add_child(dim)
	return frame


# 把模型缩放到统一高度并把脚底对齐到框底。各宠物的模型尺寸差很多，
# 不做这一步的话兔子会比蘑菇大一圈。
static func normalize(model: Node3D, pet_id: String) -> void:
	var box := aabb_of(model)
	var height := maxf(0.0001, box.size.y)
	var factor := TARGET_HEIGHT / height * PetService.model_scale(pet_id)
	model.scale = Vector3.ONE * factor
	model.position.y = -box.position.y * factor + PetService.model_y(pet_id)


# 模型自己的包围盒。用遍历而不是 model.get_aabb()：Node3D 没有那个方法，
# 而且模型是一整棵树，只有 MeshInstance3D 上才有网格。
static func aabb_of(root: Node3D) -> AABB:
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
