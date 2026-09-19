extends Control

# 背包界面（docs/商城系统设计.md）。入口：主菜单右上角「背包」。
#
# 三个分区：宠物 / 头像 / 头像框。显示玩家能用的东西，宠物可以直接「设为出战」。
#
# ## 🔴 「拥有」不等于「归属表里有」
#
# `GET /v1/me/entitlements` 只回**卖过的**内容。现有那 20 张头像和默认头像框
# 不在服务端目录里，所以一条归属记录都没有 —— 但它们人人可用（免费）。
#
# 所以这一页的头像分区是「目录里所有的免费头像 + 买过的付费头像」，
# 不是「归属表里的那些」。照后者写会让每个玩家打开背包发现自己什么都没有。
# 判定的唯一真相在服务端 shop.requires_entitlement()，客户端这边靠
# 「目录里有没有」来推：付费内容一定在 /v1/shop 里，免费的一定不在。
#
# ## 换装为什么只做宠物
#
# 头像与头像框的选择器已经在资料页（ProfileScreen + AvatarPickerPanel），
# 那里还带改名、签名、可见性一整套。在这里再做一份就是两处要同步的逻辑，
# 而且玩家换头像的习惯入口本来就是资料页。这里只展示，点了跳过去。

signal back_requested
signal profile_requested   # 头像那块点一下 -> 资料页（换装在那边）

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const MENU_BG_TEX := preload("res://assets/ui/main_menu_live/background.png")
const PetPreview := preload("res://scripts/pets/PetPreview.gd")
const AvatarCatalog := preload("res://scripts/account/AvatarCatalog.gd")
const PetService := preload("res://scripts/pets/PetService.gd")

const PET_CARD := Vector2(214, 244)
const PET_PREVIEW := Vector2(176, 126)
const PET_DETAIL_PREVIEW := Vector2(292, 226)
const AVATAR_TILE := Vector2(126, 126)
const DETAIL_WIDTH := 344.0
const PET_COLUMNS := 3
const AVATAR_COLUMNS := 8

const TAB_PETS := "pets"
const TAB_AVATARS := "avatars"

var _busy := false
var _loading := true
var _owned_pets: Array = []
var _active_pet := ""
var _paid_content: Dictionary = {}   # 内容 id -> true，玩家买到的付费内容
var _sold_content: Dictionary = {}   # 内容 id -> true，服务端目录里在卖的
var _notice := ""
var _notice_bad := false
var _active_tab := TAB_PETS
var _selected_pet := ""
var _selected_avatar := ""

var _grid: GridContainer
var _detail: VBoxContainer
var _empty_label: Label
var _notice_label: Label
var _pet_count_label: Label
var _avatar_count_label: Label
var _tab_buttons: Dictionary = {}


func _ready() -> void:
	theme = Theming.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_render()
	# 开发截图场景会在进树前灌固定收藏；不发网络请求，保证视觉回归图稳定。
	if has_meta("ui_capture_fixture"):
		return
	_reload()


# --- 骨架 ---------------------------------------------------------------------

func _build() -> void:
	var bg := TextureRect.new()
	bg.texture = MENU_BG_TEX
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var dim := ColorRect.new()
	dim.color = Tokens.BACKDROP
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, Tokens.PAD)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", Tokens.GAP_M)
	margin.add_child(root)
	root.add_child(_header())

	_notice_label = Label.new()
	_notice_label.name = "Notice"
	_notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	_notice_label.visible = false
	root.add_child(_notice_label)

	root.add_child(_tab_bar())

	var shell := PanelContainer.new()
	shell.size_flags_vertical = Control.SIZE_EXPAND_FILL
	shell.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.INK_PANEL, Tokens.INK_EDGE, Tokens.GAP_S))
	root.add_child(shell)

	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", Tokens.GAP_S)
	shell.add_child(split)
	split.add_child(_collection_panel())

	var divider := ColorRect.new()
	divider.custom_minimum_size = Vector2(1, 0)
	divider.color = Tokens.INK_EDGE.darkened(0.42)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	split.add_child(divider)
	split.add_child(_detail_panel())


func _tab_bar() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE, Tokens.BORDER.darkened(0.35), Tokens.GAP_S))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(row)
	for entry in [
		{"id": TAB_PETS, "zh": "宠物", "en": "Pets"},
		{"id": TAB_AVATARS, "zh": "头像", "en": "Avatars"},
	]:
		var tab_id := str(entry.id)
		var button: Button = ACTION_BUTTON.instantiate()
		button.text = _t(str(entry.zh), str(entry.en))
		button.custom_minimum_size = Vector2(220, Tokens.TOUCH_MIN)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(func() -> void: _select_tab(tab_id))
		row.add_child(button)
		_tab_buttons[tab_id] = button
	return panel


func _collection_panel() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE, Tokens.BORDER.darkened(0.42), Tokens.GAP_S))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(col)

	var head := HBoxContainer.new()
	head.custom_minimum_size.y = 34
	col.add_child(head)
	var title := Label.new()
	title.text = _t("我的收藏", "My Collection")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", Tokens.FONT_BUTTON)
	title.add_theme_color_override("font_color", Tokens.GOLD)
	head.add_child(title)
	_pet_count_label = _count_label()
	head.add_child(_pet_count_label)
	_avatar_count_label = _count_label()
	head.add_child(_avatar_count_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	var holder := VBoxContainer.new()
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.add_theme_constant_override("separation", Tokens.GAP_S)
	scroll.add_child(holder)
	_empty_label = Label.new()
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	holder.add_child(_empty_label)
	_grid = GridContainer.new()
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", Tokens.GAP_S)
	_grid.add_theme_constant_override("v_separation", Tokens.GAP_S)
	holder.add_child(_grid)
	return panel


func _detail_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(DETAIL_WIDTH, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE, Tokens.GOLD_PRESSED.darkened(0.18), Tokens.GAP_M))
	_detail = VBoxContainer.new()
	_detail.name = "CollectionDetail"
	_detail.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(_detail)
	return panel


func _count_label() -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	return label


func _header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_M)

	var back: Button = ACTION_BUTTON.instantiate()
	back.name = "Back"
	back.text = _t("← 返回", "← Back")
	back.custom_minimum_size = Vector2(160, Tokens.TOUCH_MIN)
	back.pressed.connect(func() -> void: back_requested.emit())
	row.add_child(back)

	var title := Label.new()
	title.text = _t("收藏背包", "Collection Bag")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	row.add_child(title)

	var profile: Button = ACTION_BUTTON.instantiate()
	profile.text = _t("个人资料 →", "Profile →")
	profile.theme_type_variation = Theming.VARIATION_GHOST
	profile.custom_minimum_size = Vector2(160, Tokens.TOUCH_MIN)
	profile.pressed.connect(func() -> void: profile_requested.emit())
	row.add_child(profile)
	return row


# --- 拉数据 -------------------------------------------------------------------

func _reload() -> void:
	_loading = true
	_render()
	# 宠物走 PlayerProfile —— 它是归属缓存的唯一主人。直连 AccountManager 的话，
	# 这里换了出战宠物、备战页还显示旧的（两处各自维护一份缓存）。
	var pets_ok := await PlayerProfile.refresh_pets()
	var owned: Dictionary = await AccountManager.fetch_entitlements()
	# 目录只用来回答「这个内容是不是付费的」，见文件头那段。
	var catalog: Dictionary = await AccountManager.fetch_shop()
	if not is_inside_tree():
		return
	_loading = false

	# 拉失败也照样读缓存：PlayerProfile 失败时不动旧值，显示上次那份比显示空好。
	_owned_pets = PlayerProfile.owned_pets.duplicate()
	_active_pet = PlayerProfile.get_active()
	if not pets_ok and not PlayerProfile.pets_loaded:
		_set_notice(_t("宠物列表没拉到，稍后再试", "Could not load your pets — try again later"), true)

	_paid_content.clear()
	if int(owned.get("code", 0)) / 100 == 2:
		for id in ((owned.get("body", {}) as Dictionary).get("items", []) as Array):
			_paid_content[str(id)] = true

	_sold_content.clear()
	if int(catalog.get("code", 0)) / 100 == 2:
		for raw in ((catalog.get("body", {}) as Dictionary).get("items", []) as Array):
			_sold_content[str((raw as Dictionary).get("grants", ""))] = true
	_render()


# --- 渲染 ---------------------------------------------------------------------

func _render() -> void:
	if _grid == null:
		return
	_notice_label.visible = not _notice.is_empty()
	_notice_label.text = _notice
	_notice_label.add_theme_color_override(
		"font_color", Tokens.DANGER if _notice_bad else Tokens.GOLD)

	for tab_id in _tab_buttons:
		var tab_button := _tab_buttons[tab_id] as Button
		tab_button.theme_type_variation = (Theming.VARIATION_PRIMARY
			if str(tab_id) == _active_tab else Theming.VARIATION_GHOST)

	_clear_children(_grid)
	_clear_children(_detail)
	var avatars := _usable_avatars() if not _loading else []
	_pet_count_label.text = _t("宠物 %d", "Pets %d") % _owned_pets.size()
	_avatar_count_label.text = _t("  ·  头像 %d", "  ·  Avatars %d") % avatars.size()

	if _loading:
		_empty_label.text = _t("正在整理收藏…", "Organizing your collection…")
		_empty_label.visible = true
		_detail.add_child(_detail_hint(_t("正在读取你的物品", "Loading your items")))
		return

	if _active_tab == TAB_PETS:
		_grid.columns = PET_COLUMNS
		if _owned_pets.is_empty():
			_empty_label.text = _t("还没有宠物。去商店看看吧。", "No pets yet. Visit the Shop to find one.")
			_empty_label.visible = true
			_detail.add_child(_detail_hint(_t("获得宠物后，可以在这里设为出战", "Equip a pet here after you unlock one")))
			return
		_empty_label.visible = false
		if _selected_pet.is_empty() or not _owned_pets.has(_selected_pet):
			_selected_pet = _active_pet if _owned_pets.has(_active_pet) else str(_owned_pets[0])
		for pet_id in _owned_pets:
			_grid.add_child(_pet_card(str(pet_id)))
		_render_pet_detail(_selected_pet)
		return

	_grid.columns = AVATAR_COLUMNS
	if avatars.is_empty():
		_empty_label.text = _t("没有可用的头像", "No avatars available")
		_empty_label.visible = true
		_detail.add_child(_detail_hint(_t("头像会显示在这里", "Your avatars will appear here")))
		return
	_empty_label.visible = false
	if _selected_avatar.is_empty() or not avatars.has(_selected_avatar):
		_selected_avatar = str(avatars[0])
	for value in avatars:
		_grid.add_child(_avatar_tile(str(value)))
	_render_avatar_detail(_selected_avatar)


func _pet_card(pet_id: String) -> Control:
	var active := pet_id == _active_pet
	var selected := pet_id == _selected_pet
	var panel := PanelContainer.new()
	panel.custom_minimum_size = PET_CARD
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE_RAISED,
		Tokens.GOLD_EDGE if active else (Tokens.CYAN if selected else Tokens.BORDER),
		Tokens.GAP_S))
	panel.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_select_pet(pet_id)
		elif event is InputEventScreenTouch and event.pressed:
			_select_pet(pet_id))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(box)
	box.add_child(_pet_preview_stage(pet_id, PET_PREVIEW, active))

	var name_label := Label.new()
	name_label.text = PetService.display_name(pet_id)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.clip_text = true
	name_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	name_label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(name_label)

	var effect := Label.new()
	effect.text = PetService.effect_text(pet_id)
	effect.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	effect.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	effect.max_lines_visible = 2
	effect.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	effect.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	effect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(effect)

	var button: Button = ACTION_BUTTON.instantiate()
	button.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	if active:
		button.text = _t("出战中 ✓", "Equipped ✓")
		button.disabled = true
	else:
		button.text = _t("设为出战", "Set active")
		button.pressed.connect(func() -> void: _set_active(pet_id))
	box.add_child(button)
	return panel


# 玩家能用的头像：目录里没卖的（免费）+ 买到的付费的。见文件头那段。
func _usable_avatars() -> Array:
	var out: Array = []
	for entry in AvatarCatalog.avatars():
		var value := "preset:%s" % str((entry as Dictionary).get("id", ""))
		if not _sold_content.get(value, false) or _paid_content.get(value, false):
			out.append(value)
	return out


func _avatar_tile(value: String) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = AVATAR_TILE
	panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	panel.add_theme_stylebox_override(
		"panel", Tokens.panel_box(Tokens.SURFACE_RAISED,
			Tokens.GOLD_EDGE if value == _selected_avatar else Tokens.BORDER, Tokens.GAP_S))
	panel.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_select_avatar(value)
		elif event is InputEventScreenTouch and event.pressed:
			_select_avatar(value))
	var tex := AvatarCatalog.texture_for(value, true)
	if tex == null:
		panel.add_child(_detail_hint("?"))
		return panel
	var rect := TextureRect.new()
	rect.texture = tex
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(rect)
	return panel


func _pet_preview_stage(pet_id: String, preview_size: Vector2, active: bool) -> Control:
	var stage := Control.new()
	stage.custom_minimum_size = Vector2(preview_size.x, preview_size.y + 8.0)
	stage.mouse_filter = Control.MOUSE_FILTER_PASS
	var well := PanelContainer.new()
	well.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	well.mouse_filter = Control.MOUSE_FILTER_IGNORE
	well.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.BG_DEEP, Tokens.BORDER.darkened(0.45), Tokens.GAP_S))
	stage.add_child(well)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	well.add_child(center)
	var preview := PetPreview.build(pet_id, preview_size, false)
	_ignore_mouse_tree(preview)
	center.add_child(preview)
	if active:
		var badge := Label.new()
		badge.text = _t("  出战中  ", "  EQUIPPED  ")
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		badge.position = Vector2(-98, 8)
		badge.size = Vector2(90, 26)
		badge.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
		badge.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
		badge.add_theme_stylebox_override("normal", Tokens.panel_box(
			Tokens.INK_PANEL, Tokens.GOLD_PRESSED, 2))
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stage.add_child(badge)
	return stage


func _render_pet_detail(pet_id: String) -> void:
	var active := pet_id == _active_pet
	var eyebrow := Label.new()
	eyebrow.text = _t("宠物详情", "PET DETAILS")
	eyebrow.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	eyebrow.add_theme_color_override("font_color", Tokens.GOLD)
	_detail.add_child(eyebrow)
	_detail.add_child(_pet_preview_stage(pet_id, PET_DETAIL_PREVIEW, active))
	var name_label := Label.new()
	name_label.text = PetService.display_name(pet_id)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	_detail.add_child(name_label)
	var effect := Label.new()
	effect.text = PetService.effect_text(pet_id)
	effect.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	effect.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	effect.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	effect.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	_detail.add_child(effect)
	_detail.add_child(_flex_spacer())
	var status := Label.new()
	status.text = _t("✓ 当前出战宠物", "✓ Currently equipped") if active else _t("可设为出战", "Ready to equip")
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.add_theme_color_override("font_color", Tokens.GOLD_HOVER if active else Tokens.TEXT_SECONDARY)
	_detail.add_child(status)
	var action: Button = ACTION_BUTTON.instantiate()
	action.custom_minimum_size = Vector2(0, Tokens.BUTTON_HEIGHT)
	if active:
		action.text = _t("出战中 ✓", "Equipped ✓")
		action.disabled = true
	else:
		action.text = _t("设为出战", "Set Active")
		action.theme_type_variation = Theming.VARIATION_PRIMARY
		action.pressed.connect(func() -> void: _set_active(pet_id))
	_detail.add_child(action)


func _render_avatar_detail(value: String) -> void:
	var eyebrow := Label.new()
	eyebrow.text = _t("头像预览", "AVATAR PREVIEW")
	eyebrow.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	eyebrow.add_theme_color_override("font_color", Tokens.GOLD)
	_detail.add_child(eyebrow)
	var well := PanelContainer.new()
	well.custom_minimum_size = Vector2(292, 292)
	well.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.BG_DEEP, Tokens.BORDER.darkened(0.45), Tokens.GAP_M))
	_detail.add_child(well)
	var tex := AvatarCatalog.texture_for(value)
	if tex != null:
		var rect := TextureRect.new()
		rect.texture = tex
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		well.add_child(rect)
	var name_label := Label.new()
	name_label.text = AvatarCatalog.display_name(AvatarCatalog.id_from_value(value))
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	_detail.add_child(name_label)
	var hint := Label.new()
	hint.text = _t("头像的装备与个人资料保持同步", "Avatar selection is managed on your profile")
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	hint.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	_detail.add_child(hint)
	_detail.add_child(_flex_spacer())
	var action: Button = ACTION_BUTTON.instantiate()
	action.text = _t("前往个人资料更换", "Change in Profile")
	action.theme_type_variation = Theming.VARIATION_PRIMARY
	action.custom_minimum_size = Vector2(0, Tokens.BUTTON_HEIGHT)
	action.pressed.connect(func() -> void: profile_requested.emit())
	_detail.add_child(action)


func _select_tab(tab_id: String) -> void:
	if _active_tab == tab_id:
		return
	_active_tab = tab_id
	_render()


func _select_pet(pet_id: String) -> void:
	if _selected_pet == pet_id:
		return
	_selected_pet = pet_id
	_render()


func _select_avatar(value: String) -> void:
	if _selected_avatar == value:
		return
	_selected_avatar = value
	_render()


func _detail_hint(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	return label


func _flex_spacer() -> Control:
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return spacer


func _clear_children(parent: Node) -> void:
	if parent == null:
		return
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()


func _ignore_mouse_tree(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore_mouse_tree(child)


# --- 换出战宠物 ---------------------------------------------------------------

func _set_active(pet_id: String) -> void:
	if _busy:
		return
	_busy = true
	var ok := await PlayerProfile.set_active(pet_id)
	_busy = false
	if not is_inside_tree():
		return
	_owned_pets = PlayerProfile.owned_pets.duplicate()
	_active_pet = PlayerProfile.get_active()
	if ok:
		_set_notice(_t("已换出战宠物", "Active pet changed"), false)
	else:
		_set_notice(_t("换不了，稍后再试", "Could not change pet — try again later"), true)
	_render()


# --- 小工具 -------------------------------------------------------------------

func _set_notice(text: String, bad: bool) -> void:
	_notice = text
	_notice_bad = bad


func _english() -> bool:
	return LocaleManager.get_locale().begins_with("en")


func _t(zh: String, en: String) -> String:
	return en if _english() else zh
