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

const PET_CARD := Vector2(200, 260)
const PET_PREVIEW := Vector2(170, 140)
const AVATAR_TILE := Vector2(110, 110)
const COLUMNS := 5

var _busy := false
var _loading := true
var _owned_pets: Array = []
var _active_pet := ""
var _paid_content: Dictionary = {}   # 内容 id -> true，玩家买到的付费内容
var _sold_content: Dictionary = {}   # 内容 id -> true，服务端目录里在卖的
var _notice := ""
var _notice_bad := false

var _body: VBoxContainer
var _notice_label: Label


func _ready() -> void:
	theme = Theming.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_render()
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

	var panel := PanelContainer.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override(
		"panel", Tokens.panel_box(Tokens.SURFACE, Tokens.BORDER, Tokens.GAP_M))
	root.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	_body = VBoxContainer.new()
	_body.name = "Sections"
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", Tokens.GAP_L)
	scroll.add_child(_body)


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
	title.text = _t("背包", "Bag")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	row.add_child(title)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(160, 0)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)
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
	if _body == null:
		return
	_notice_label.visible = not _notice.is_empty()
	_notice_label.text = _notice
	_notice_label.add_theme_color_override(
		"font_color", Tokens.DANGER if _notice_bad else Tokens.GOLD)

	for child in _body.get_children():
		child.queue_free()

	if _loading:
		_body.add_child(_hint(_t("正在载入…", "Loading…")))
		return

	_body.add_child(_section_title(_t("宠物", "Pets")))
	if _owned_pets.is_empty():
		_body.add_child(_hint(_t("还没有宠物。去商城看看？", "No pets yet. Try the shop?")))
	else:
		var pet_grid := _grid(4)
		for pet_id in _owned_pets:
			pet_grid.add_child(_pet_card(str(pet_id)))
		_body.add_child(pet_grid)

	_body.add_child(_section_title(_t("头像", "Avatars")))
	_body.add_child(_hint(_t("在资料页更换头像", "Change your avatar on the profile page")))
	var avatars := _usable_avatars()
	if avatars.is_empty():
		_body.add_child(_hint(_t("（没有可用的头像）", "(No avatars available)")))
	else:
		var avatar_grid := _grid(COLUMNS)
		for value in avatars:
			avatar_grid.add_child(_avatar_tile(str(value)))
		_body.add_child(avatar_grid)


func _section_title(text: String) -> Control:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	label.add_theme_color_override("font_color", Tokens.GOLD)
	return label


func _hint(text: String) -> Control:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	return label


func _grid(columns: int) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = columns
	grid.add_theme_constant_override("h_separation", Tokens.GAP_M)
	grid.add_theme_constant_override("v_separation", Tokens.GAP_M)
	return grid


func _pet_card(pet_id: String) -> Control:
	var active := pet_id == _active_pet
	var panel := PanelContainer.new()
	panel.custom_minimum_size = PET_CARD
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE_RAISED, Tokens.GOLD_EDGE if active else Tokens.BORDER, Tokens.GAP_S))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(box)
	box.add_child(PetPreview.build(pet_id, PET_PREVIEW, false))

	var name_label := Label.new()
	name_label.text = PetService.display_name(pet_id)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	name_label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	box.add_child(name_label)

	var effect := Label.new()
	effect.text = PetService.effect_text(pet_id)
	effect.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	effect.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	effect.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	effect.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	box.add_child(effect)

	var button: Button = ACTION_BUTTON.instantiate()
	button.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	if active:
		button.text = _t("出战中", "Active")
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
	panel.add_theme_stylebox_override(
		"panel", Tokens.panel_box(Tokens.SURFACE_RAISED, Tokens.BORDER, Tokens.GAP_S))
	var tex := AvatarCatalog.texture_for(value, true)
	if tex == null:
		panel.add_child(_hint("?"))
		return panel
	var rect := TextureRect.new()
	rect.texture = tex
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(rect)
	return panel


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
