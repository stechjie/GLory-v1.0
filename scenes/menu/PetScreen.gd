extends Control
# 备战界面（暂时只有宠物系统）。从主菜单「备战」按钮进入。
#   - 展示所有宠物（拥有的可「设为出战」，未拥有置灰）。
#   - 首次（needs_starter_pick）时为「三选一」：任选一只作为初始宠物（拥有 + 出战）。
#   - 右上角返回按钮回主菜单。
# 卡片统一规格：模型(占位) + 名字 + 效果。模型美术到位后替换 _build_model_placeholder。

const Theming := preload("res://ui/theme/GloryTheme.gd")
signal back_requested
signal starter_picked   # 首次三选一选定后发出（用于「进主菜单前的强制关卡」）

const CARD_SIZE := Vector2(210, 280)

var _cards_row: HBoxContainer
var _hint_label: Label
var _active_label: Label
var _back_btn: Button

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	if not PlayerProfile.pets_changed.is_connected(_refresh):
		PlayerProfile.pets_changed.connect(_refresh)
	_refresh()

func _exit_tree() -> void:
	if PlayerProfile.pets_changed.is_connected(_refresh):
		PlayerProfile.pets_changed.disconnect(_refresh)

func _build() -> void:
	# V3 P1-04 验收原文：「无业务按钮使用 Godot 默认主题」。
	# 这一页此前既没有 theme=，也没有任何 add_theme_stylebox_override，
	# 而 project.godot 也没有 gui/theme/custom —— 所以按钮走的是引擎
	# 默认灰色样式，和游戏其它地方长得完全不是一套。
	theme = Theming.get_theme()
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.08)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# 内容列：铺满屏，但设为 IGNORE，否则会盖住返回按钮把点击吃掉（卡片内按钮仍可点）。
	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 18)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)

	var title := Label.new()
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	title.text = tr("pet_title")
	col.add_child(title)

	_hint_label = Label.new()
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.add_theme_font_size_override("font_size", 18)
	_hint_label.add_theme_color_override("font_color", Color(0.75, 0.78, 0.85))
	col.add_child(_hint_label)

	_cards_row = HBoxContainer.new()
	_cards_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_cards_row.add_theme_constant_override("separation", 24)
	col.add_child(_cards_row)

	_active_label = Label.new()
	_active_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_active_label.add_theme_font_size_override("font_size", 20)
	_active_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.55))
	col.add_child(_active_label)

	# 返回按钮（右上角）。最后添加 = 输入拾取时在最上层，不会被内容列挡住。
	# 仅在非首次（已选过初始宠物）时显示；首次强制三选一时隐藏，逼玩家先选。
	_back_btn = Button.new()
	_back_btn.text = "← " + tr("pet_back")
	_back_btn.custom_minimum_size = Vector2(120, 46)
	_back_btn.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_back_btn.position = Vector2(_back_btn.position.x - 140, 20)
	_back_btn.pressed.connect(func(): back_requested.emit())
	add_child(_back_btn)

func _refresh() -> void:
	if _cards_row == null:
		return
	var starter_mode := PlayerProfile.needs_starter_pick
	_hint_label.text = tr("pet_starter_hint") if starter_mode else ""
	_hint_label.visible = starter_mode
	# 首次强制三选一时隐藏返回按钮，选完才放行。
	if _back_btn != null:
		_back_btn.visible = not starter_mode
	_active_label.text = tr("pet_active_label") % PetService.display_name(PlayerProfile.get_active())
	for c in _cards_row.get_children():
		c.queue_free()
	for p in PetService.all_pets():
		_cards_row.add_child(_build_card(str((p as Dictionary).get("id", "")), starter_mode))

func _build_card(pet_id: String, starter_mode: bool) -> Control:
	var owned := PlayerProfile.is_owned(pet_id)
	var is_active := PlayerProfile.get_active() == pet_id
	# 未拥有且非首次三选一时置灰。
	var greyed := not owned and not starter_mode

	var card := PanelContainer.new()
	card.custom_minimum_size = CARD_SIZE
	var m := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 12)
	card.add_child(m)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	m.add_child(content)

	content.add_child(_build_model_preview(pet_id, greyed))

	var name_lbl := Label.new()
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 24)
	name_lbl.text = PetService.display_name(pet_id)
	if is_active:
		name_lbl.text += "  ✓"
	if greyed:
		name_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	content.add_child(name_lbl)

	var effect_lbl := Label.new()
	effect_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	effect_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	effect_lbl.add_theme_font_size_override("font_size", 16)
	effect_lbl.text = PetService.effect_text(pet_id)
	effect_lbl.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45) if greyed else Color(0.55, 0.85, 0.55))
	content.add_child(effect_lbl)

	content.add_child(_build_card_button(pet_id, owned, is_active, starter_mode))
	return card

const PREVIEW_SIZE := Vector2(180, 130)
const PREVIEW_CAMERA_POS := Vector3(0.0, 1.05, 2.05)
const PREVIEW_CAMERA_TARGET := Vector3(0.0, 0.48, 0.0)
const PREVIEW_ORTHO_SIZE := 1.35
const PREVIEW_TARGET_HEIGHT := 0.95

# 卡片上的宠物模型预览：跟主菜单草地上用的是同一批 *_animated.tscn，
# 只是这里固定站着播 idle，不走动。没有模型（或未拥有时想留白）就回落到「?」占位框。
func _build_model_preview(pet_id: String, greyed: bool) -> Control:
	var path := PetService.model_path(pet_id)
	if path.is_empty():
		return _build_model_placeholder(greyed)
	var scene := ResourceLoader.load(path) as PackedScene
	if scene == null:
		return _build_model_placeholder(greyed)

	var frame := Panel.new()
	frame.custom_minimum_size = PREVIEW_SIZE
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
	camera.size = PREVIEW_ORTHO_SIZE
	camera.look_at_from_position(PREVIEW_CAMERA_POS, PREVIEW_CAMERA_TARGET, Vector3.UP)
	camera.current = true
	viewport.add_child(camera)

	var model := scene.instantiate() as Node3D
	if model == null:
		return _build_model_placeholder(greyed)
	viewport.add_child(model)
	_normalize_preview_model(model, pet_id)
	if greyed:
		# 未拥有：盖一层暗色，跟卡片其他元素的灰化保持一致。
		# 不能靠调灯光——toon shader 是 ambient_light_disabled，且暗部由 fragment 里的
		# EMISSION 兜底，调灯几乎不影响亮度。
		var dim := ColorRect.new()
		dim.color = Color(0.0, 0.0, 0.0, 0.55)
		dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		frame.add_child(dim)
	return frame

func _normalize_preview_model(model: Node3D, pet_id: String) -> void:
	var box := _preview_aabb(model)
	var height := maxf(0.0001, box.size.y)
	var factor := PREVIEW_TARGET_HEIGHT / height * PetService.model_scale(pet_id)
	model.scale = Vector3.ONE * factor
	model.position.y = -box.position.y * factor + PetService.model_y(pet_id)

func _preview_aabb(root: Node3D) -> AABB:
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

func _build_model_placeholder(greyed: bool) -> Control:
	# 没有模型时的兜底占位框。
	var frame := Panel.new()
	frame.custom_minimum_size = Vector2(180, 130)
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

func _build_card_button(pet_id: String, owned: bool, is_active: bool, starter_mode: bool) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(0, 44)
	if starter_mode:
		# 首次三选一：任选一只作为初始宠物，选定后发信号让上层放行进主菜单。
		btn.text = tr("pet_pick")
		btn.pressed.connect(func():
			if PlayerProfile.pick_starter(pet_id):
				starter_picked.emit())
	elif not owned:
		btn.text = tr("pet_locked")
		btn.disabled = true
	elif is_active:
		btn.text = tr("pet_active_tag")
		btn.disabled = true
	else:
		btn.text = tr("pet_set_active")
		btn.pressed.connect(func(): PlayerProfile.set_active(pet_id))
	return btn
