extends Control

# 商城界面（docs/商城系统设计.md）。入口：主菜单右侧「商店」。
#
# 网格铺商品卡片，卡片上是模型预览 + 名字 + 价格。已拥有的置灰、写「已拥有」、点不动。
# 点可买的 -> 确认框 -> POST /v1/shop/orders -> 回执刷新余额与拥有列表。
#
# ## 三条纪律
#
# 1. **客户端只发意图。** 请求体里只有 client_order_id 和 item_id，没有价格、
#    没有「我有多少钱」。卡片上那个价格只是显示用的，服务端另算一遍
#    （docs/P1经济账本RFC.md 第六节）。
#
# 2. **client_order_id 生成一次，整笔重试期间复用。** 换一个新的就是新订单，
#    会再扣一次钱。所以它存在 _pending_order_id 里，成功或明确失败之后才清。
#
# 3. **「不在目录里 = 免费」。** 拥有列表里没有某个内容**不代表**玩家没有它 ——
#    现有 20 张头像都不在归属表里却人人可用。这一页只显示服务端目录里的东西，
#    所以这里不会踩到；但别把这页的判断逻辑抄去做「有没有资格用」。

signal back_requested
signal diamond_store_requested
signal pet_draw_requested

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
# 9.17 音效。preload 而不是全局类名，理由见 Main.gd 顶上那条注释。
const SfxService := preload("res://ui/services/SfxService.gd")
# 9.17 第二批：商城有**自己的独立 BGM**（反馈第 2 条括号里那句
# 「商城功能自身有独立的 bgm」）。进商城切到这一首，返回主菜单时
# MainMenu._start_menu_music() 会把 menu_music 切回来 —— 各页各播各的，
# 播放器是同一个（MusicService），所以不会叠。
const MusicService := preload("res://ui/services/MusicService.gd")
const SHOP_MUSIC_PATH := "res://assets/audio/bgm/shop_music.mp3"
const ConfirmDialog := preload("res://ui/components/GloryConfirmDialog.gd")
# 新按钮一律实例化组件，不写 Button.new()：procedural_ui_ratchet 按文件只许降。
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const MENU_BG_TEX := preload("res://assets/ui/main_menu_live/background.png")
const SHOP_HERO_TEX := preload("res://assets/ui/shop/shop_hero_bg.png")
const ICE_FRAME_TEX := preload("res://assets/ui/shop/frame_7day_ice.png")
const ICE_BOARD_TEX := preload("res://assets/skins/prep/prep_skin_ice/board.png")
const ICE_REVEAL_SHADER := preload("res://assets/ui/shop/ice_reveal.gdshader")
# 货币图标（从整条货币条里裁出来的）与千分位，主菜单 / 商城 / 邮件共用这一份。
const Currency := preload("res://scripts/account/Currency.gd")
const PetPreview := preload("res://scripts/pets/PetPreview.gd")
const AvatarCatalog := preload("res://scripts/account/AvatarCatalog.gd")
const PrepSkin := preload("res://scenes/prep/PrepSkin.gd")

const CARD_SIZE := Vector2(230, 430)
const PREVIEW_SIZE := Vector2(255, 230)
const DETAIL_PREVIEW_SIZE := Vector2(280, 130)
const DETAIL_WIDTH := 316.0
const COLUMNS := 3

const CATEGORY_ALL := "all"
const CATEGORY_PETS := "pet"
const CATEGORY_AVATARS := "avatar"
const CATEGORY_FRAMES := "frame"
const CATEGORY_SKINS := "prep_skin"
const CATEGORY_DIAMONDS := "diamonds"
const CATEGORY_EVENT := "seven_day"

var _busy := false
var _loading := true
var _items: Array = []
var _owned: Dictionary = {}     # 内容 id -> true
var _diamond := 0
var _coin := 0
var _notice := ""
var _notice_bad := false
var _active_category := CATEGORY_PETS
var _selected_item_id := ""
var _active_pet := ""
var _login_state: Dictionary = {}
var _diamond_products: Array = []

# 正在进行的那笔购买的幂等键。**重试必须复用它**，见文件头第 2 条。
var _pending_order_id := ""
var _pending_item_id := ""

var _grid: GridContainer
var _detail: VBoxContainer
var _notice_label: Label
var _diamond_label: Label
var _coin_label: Label
var _empty_label: Label
var _catalog_count_label: Label
var _catalog_title_label: Label
var _category_buttons: Dictionary = {}
var _catalog_shell: PanelContainer
var _summon_panel_control: Control
var _detail_panel_control: Control
var _special_panel: PanelContainer
var _special_content: VBoxContainer
var _hero_panel: Control
var _event_dot: Label


func _ready() -> void:
	theme = Theming.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var products_data: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/diamond_products.json"))
	if products_data is Dictionary:
		_diamond_products = (products_data as Dictionary).get("products", [])
	_build()
	_render()
	# 开发截图场景会在进树前灌固定目录与余额；不发网络请求，保证视觉回归图稳定。
	if has_meta("ui_capture_fixture"):
		return
	_reload()
	# 9.17 第二批：商城独立 BGM。放在 _reload() 之后 —— 它只是一条 play()，
	# 但排在网络请求后面能保证「进页面先看到东西、再听音乐」，不会反过来。
	# 返回主菜单时由 MainMenu 负责切回 menu_music，这里不需要收尾。
	MusicService.play(SHOP_MUSIC_PATH)


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
	_hero_panel = _hero()

	_notice_label = Label.new()
	_notice_label.name = "Notice"
	_notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	_notice_label.visible = false
	root.add_child(_notice_label)

	root.add_child(_category_bar())

	# 商店是「浏览 + 决策」页面：左边快速扫货，右边保留稳定的大预览和唯一的
	# 购买决策区。卡片仍可直接购买，兼顾熟练玩家；点卡片其余区域则只切详情。
	_catalog_shell = PanelContainer.new()
	_catalog_shell.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_catalog_shell.add_theme_stylebox_override(
		"panel", Tokens.panel_box(Tokens.INK_PANEL, Tokens.INK_EDGE, Tokens.GAP_S))
	root.add_child(_catalog_shell)

	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", Tokens.GAP_S)
	_catalog_shell.add_child(split)
	split.add_child(_catalog_panel())

	var divider := ColorRect.new()
	divider.custom_minimum_size = Vector2(1, 0)
	divider.color = Tokens.INK_EDGE.darkened(0.42)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	split.add_child(divider)
	_summon_panel_control = _summon_panel()
	split.add_child(_summon_panel_control)
	_detail_panel_control = _detail_panel()
	split.add_child(_detail_panel_control)

	_special_panel = PanelContainer.new()
	_special_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_special_panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.INK_PANEL, Tokens.GOLD_PRESSED.darkened(0.4), Tokens.GAP_M))
	root.add_child(_special_panel)
	_special_content = VBoxContainer.new()
	_special_content.add_theme_constant_override("separation", Tokens.GAP_M)
	_special_panel.add_child(_special_content)
	_special_panel.hide()


func _hero() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 170
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.BG_DEEP, Tokens.GOLD_EDGE, 2))
	var canvas := Control.new()
	canvas.clip_contents = true
	panel.add_child(canvas)
	var art := TextureRect.new()
	art.texture = SHOP_HERO_TEX
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(art)
	var shade := ColorRect.new()
	shade.color = Color(0.025, 0.065, 0.065, 0.82)
	shade.anchor_right = 0.56
	shade.anchor_bottom = 1.0
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(shade)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	canvas.add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	margin.add_child(col)
	var eyebrow := Label.new()
	eyebrow.text = _t("GLORY · 珍藏", "GLORY · COLLECTION")
	eyebrow.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	eyebrow.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	col.add_child(eyebrow)
	var title := Label.new()
	title.text = _t("每一份冒险，都值得珍藏", "Treasures for every adventure")
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Color.WHITE)
	col.add_child(title)
	var sub := Label.new()
	sub.text = _t("收集伙伴 · 点亮冰雪之境", "Collect companions · reveal the frost realm")
	sub.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	sub.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	col.add_child(sub)
	var action: Button = ACTION_BUTTON.instantiate()
	action.text = _t("查看七日冰雪活动  →", "Explore the seven-day event  →")
	action.custom_minimum_size = Vector2(230, 36)
	action.theme_type_variation = Theming.VARIATION_PRIMARY
	action.pressed.connect(func() -> void: _select_category(CATEGORY_EVENT))
	col.add_child(action)
	return panel


func _category_bar() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE, Tokens.BORDER.darkened(0.35), Tokens.GAP_S))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(row)
	for entry in [
		{"id": CATEGORY_PETS, "zh": "宠物", "en": "Pets"},
		{"id": CATEGORY_FRAMES, "zh": "头像框", "en": "Avatar Frames"},
		{"id": CATEGORY_SKINS, "zh": "外观", "en": "Appearance"},
		{"id": CATEGORY_EVENT, "zh": "七日登录 · 冰雪", "en": "Seven days · Frost"},
	]:
		var category := str(entry.id)
		var button: Button = ACTION_BUTTON.instantiate()
		button.text = _t(str(entry.zh), str(entry.en))
		button.custom_minimum_size = Vector2(150 if category != CATEGORY_EVENT else 190, Tokens.TOUCH_MIN)
		button.pressed.connect(func() -> void: _select_category(category))
		row.add_child(button)
		_category_buttons[category] = button
		if category == CATEGORY_EVENT:
			_event_dot = Label.new()
			_event_dot.text = "●"
			_event_dot.add_theme_color_override("font_color", Tokens.UNREAD_DOT)
			_event_dot.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
			_event_dot.set_anchors_preset(Control.PRESET_TOP_RIGHT)
			_event_dot.position = Vector2(-25, 5)
			_event_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
			button.add_child(_event_dot)
	return panel


func _catalog_panel() -> Control:
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
	_catalog_title_label = Label.new()
	_catalog_title_label.text = _t("金币宠物", "Coin companions")
	_catalog_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_catalog_title_label.add_theme_font_size_override("font_size", Tokens.FONT_BUTTON)
	_catalog_title_label.add_theme_color_override("font_color", Tokens.GOLD)
	head.add_child(_catalog_title_label)
	_catalog_count_label = Label.new()
	_catalog_count_label.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	_catalog_count_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	head.add_child(_catalog_count_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	var holder := VBoxContainer.new()
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.add_theme_constant_override("separation", Tokens.GAP_M)
	scroll.add_child(holder)

	_empty_label = Label.new()
	_empty_label.name = "Empty"
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	_empty_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	holder.add_child(_empty_label)

	_grid = GridContainer.new()
	_grid.name = "Grid"
	_grid.columns = COLUMNS
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
	_detail.name = "ItemDetail"
	_detail.add_theme_constant_override("separation", 4)
	panel.add_child(_detail)
	return panel


func _summon_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 344
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE, Tokens.GOLD_PRESSED, Tokens.GAP_M))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(col)
	var eyebrow := Label.new()
	eyebrow.text = _t("钻石召唤 · 预告", "DIAMOND SUMMON · PREVIEW")
	eyebrow.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	eyebrow.add_theme_color_override("font_color", Tokens.GOLD)
	col.add_child(eyebrow)
	var title := Label.new()
	title.text = _t("邂逅稀有伙伴", "Meet rare companions")
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	col.add_child(title)
	var art := TextureRect.new()
	art.texture = SHOP_HERO_TEX
	art.custom_minimum_size.y = 176
	art.size_flags_vertical = Control.SIZE_EXPAND_FILL
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	col.add_child(art)
	var price := Label.new()
	price.text = _t("75 钻石 / 次", "75 gems / draw")
	price.add_theme_font_size_override("font_size", Tokens.FONT_BUTTON)
	price.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	col.add_child(price)
	var pity := Label.new()
	pity.text = _t("10 抽内必得新宠物  ·  当前剩余 — 抽", "New pet within 10 draws  ·  Remaining —")
	pity.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	pity.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	col.add_child(pity)
	var note := Label.new()
	note.text = _t("未获得新宠物时，返还 100 游戏币。", "No new pet? Receive 100 coins.")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	note.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	col.add_child(note)
	var action: Button = ACTION_BUTTON.instantiate()
	action.text = _t("查看召唤奖池  →", "View summon pool  →")
	action.custom_minimum_size.y = Tokens.TOUCH_MIN
	action.theme_type_variation = Theming.VARIATION_PRIMARY
	action.pressed.connect(func() -> void: pet_draw_requested.emit())
	col.add_child(action)
	return panel


func _header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_M)

	var back: Button = ACTION_BUTTON.instantiate()
	back.name = "Back"
	back.text = _t("← 返回", "← Back")
	back.custom_minimum_size = Vector2(160, Tokens.TOUCH_MIN)
	back.pressed.connect(func() -> void: back_requested.emit())
	var left_side := HBoxContainer.new()
	left_side.custom_minimum_size = Vector2(360, Tokens.TOUCH_MIN)
	left_side.add_child(back)
	row.add_child(left_side)

	var title := Label.new()
	title.text = _t("荣耀商店", "Glory Shop")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	row.add_child(title)

	# 余额。与主菜单右上角是同一组图标（同一条 gold.png / diamond.png，这里只裁出图标那一段）——
	# 两处显示同一个数，图不一样会让人以为是两种钱。
	var purse := HBoxContainer.new()
	purse.add_theme_constant_override("separation", Tokens.GAP_S)
	purse.custom_minimum_size = Vector2(360, Tokens.TOUCH_MIN)
	purse.alignment = BoxContainer.ALIGNMENT_END
	_coin_label = _purse_entry(purse, Currency.icon("coin"), _t("金币", "Coins"))
	_diamond_label = _purse_entry(purse, Currency.icon("diamond"), _t("钻石", "Gems"))
	var plus: Button = ACTION_BUTTON.instantiate()
	plus.text = "+"
	plus.custom_minimum_size = Vector2(Tokens.TOUCH_MIN, Tokens.TOUCH_MIN)
	plus.pressed.connect(func() -> void: diamond_store_requested.emit())
	purse.add_child(plus)
	row.add_child(purse)
	return row


func _purse_entry(parent: HBoxContainer, tex: Texture2D, label_text: String) -> Label:
	var chip := PanelContainer.new()
	chip.custom_minimum_size = Vector2(172, Tokens.TOUCH_MIN)
	chip.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.INK_PANEL, Tokens.INK_EDGE, Tokens.GAP_S))
	parent.add_child(chip)
	if label_text == _t("钻石", "Gems"):
		chip.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		chip.gui_input.connect(func(event: InputEvent) -> void:
			if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
				diamond_store_requested.emit()
			elif event is InputEventScreenTouch and event.pressed:
				diamond_store_requested.emit())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_S)
	chip.add_child(row)

	var icon := TextureRect.new()
	icon.texture = tex
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(32, 32)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)

	var caption := Label.new()
	caption.text = label_text
	caption.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	caption.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	row.add_child(caption)

	var label := Label.new()
	label.text = "—"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	label.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(label)
	return label


# --- 拉数据 -------------------------------------------------------------------

# 目录、余额、拥有列表一起拉。**三个都到齐才重画** ——
# 先画目录再补拥有状态的话，已买的商品会先亮一下「可购买」，玩家会去点。
func _reload() -> void:
	_loading = true
	_render()
	var catalog: Dictionary = await AccountManager.fetch_shop()
	var wallet: Dictionary = await AccountManager.fetch_wallet()
	var owned: Dictionary = await AccountManager.fetch_entitlements()
	var pets: Dictionary = await AccountManager.fetch_pets()
	var login: Dictionary = await AccountManager.fetch_seven_day_login()
	if not is_inside_tree():
		return
	_loading = false

	if int(catalog.get("code", 0)) / 100 != 2:
		_set_notice(str(catalog.get("error", _t("商城打不开", "The shop failed to load"))), true)
		_render()
		return
	# 这个包里没有图的棋盘皮肤不上架：买了也显示不出来（新皮肤要等玩家换新包）。
	_items = ((catalog.get("body", {}) as Dictionary).get("items", []) as Array).filter(
		func(item: Variant) -> bool:
			var d := item as Dictionary
			return str(d.get("kind", "")) != CATEGORY_SKINS or PrepSkin.has_skin(str(d.get("grants", ""))))

	# 余额和拥有列表失败不算致命：目录还能看，只是买不了。
	# 直接整页报错的话，一次网络抖动就把整个商城变成错误页。
	if int(wallet.get("code", 0)) / 100 == 2:
		var w: Dictionary = wallet.get("body", {})
		# 9.17：进商城时 **不**播代币音。这是拉一次余额，不是一笔收支 ——
		# 和读档、重开一局同一种性质（那两处也不响）。
		_diamond = int(w.get("diamond", 0))
		_coin = int(w.get("coin", 0))
	if int(owned.get("code", 0)) / 100 == 2:
		_owned.clear()
		for id in ((owned.get("body", {}) as Dictionary).get("items", []) as Array):
			_owned[str(id)] = true
	if int(pets.get("code", 0)) / 100 == 2:
		_active_pet = str((pets.get("body", {}) as Dictionary).get("active", ""))
	if int(login.get("code", 0)) / 100 == 2:
		_login_state = login.get("body", {}) as Dictionary
	_render()


# --- 渲染 ---------------------------------------------------------------------

func _render() -> void:
	if _grid == null:
		return
	_diamond_label.text = "—" if _loading else Currency.comma(_diamond)
	_coin_label.text = "—" if _loading else Currency.comma(_coin)

	_notice_label.visible = not _notice.is_empty()
	_notice_label.text = _notice
	_notice_label.add_theme_color_override(
		"font_color", Tokens.DANGER if _notice_bad else Tokens.GOLD)

	for category in _category_buttons:
		var category_button := _category_buttons[category] as Button
		category_button.visible = (_loading or str(category) == CATEGORY_PETS
			or _category_has_items(str(category)))
		category_button.theme_type_variation = (Theming.VARIATION_PRIMARY
			if str(category) == _active_category else Theming.VARIATION_GHOST)
	_event_dot.visible = bool(_login_state.get("claimable_today", false))
	var special := _active_category in [CATEGORY_SKINS, CATEGORY_EVENT]
	_catalog_shell.visible = not special
	_special_panel.visible = special
	if special:
		_clear_children(_special_content)
		if _active_category == CATEGORY_EVENT:
			_render_event()
		else:
			_render_appearance()
		return
	_catalog_title_label.text = (_t("珍藏头像框", "Collector frames")
		if _active_category == CATEGORY_FRAMES else _t("金币宠物", "Coin companions"))
	_summon_panel_control.visible = _active_category == CATEGORY_PETS
	_detail_panel_control.visible = _active_category == CATEGORY_FRAMES

	_clear_children(_grid)
	_clear_children(_detail)

	if _loading:
		_empty_label.text = _t("正在载入…", "Loading…")
		_empty_label.visible = true
		_catalog_count_label.text = ""
		return
	var visible_items := _visible_items()
	_catalog_count_label.text = (_t("%d 件商品", "%d items") % visible_items.size())
	if visible_items.is_empty():
		_empty_label.text = _t("这个分类暂时没有商品", "No items in this category yet")
		_empty_label.visible = true
		_selected_item_id = ""
		return

	_empty_label.visible = false
	if _selected_item(visible_items).is_empty():
		_selected_item_id = _item_id(visible_items[0] as Dictionary)
	for raw in visible_items:
		_grid.add_child(_card(raw as Dictionary))
	if _active_category == CATEGORY_FRAMES:
		_render_detail(_selected_item(visible_items))


func _section_title(title_text: String, subtitle: String) -> void:
	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	_special_content.add_child(title)
	var sub := Label.new()
	sub.text = subtitle
	sub.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	sub.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	_special_content.add_child(sub)


func _render_diamonds() -> void:
	_section_title(_t("钻石宝库", "Diamond vault"), _t(
		"钻石将通过应用商店安全购买；当地价格与付款功能接入平台后显示。",
		"Diamonds will be sold through the platform store. Local prices appear when billing is connected."))
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", Tokens.GAP_S)
	_special_content.add_child(row)
	for raw in _diamond_products:
		var product := raw as Dictionary
		var card := PanelContainer.new()
		card.custom_minimum_size = Vector2(185, 220)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.add_theme_stylebox_override("panel", Tokens.panel_box(
			Tokens.SURFACE_RAISED, Tokens.GOLD_PRESSED, Tokens.GAP_S))
		row.add_child(card)
		var col := VBoxContainer.new()
		col.alignment = BoxContainer.ALIGNMENT_CENTER
		col.add_theme_constant_override("separation", Tokens.GAP_S)
		card.add_child(col)
		var icon := TextureRect.new()
		icon.texture = Currency.icon("diamond")
		icon.custom_minimum_size = Vector2(64, 64)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		col.add_child(icon)
		var amount := Label.new()
		amount.text = Currency.comma(int(product.get("diamond", 0)))
		amount.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		amount.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
		amount.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
		col.add_child(amount)
		var caption := Label.new()
		caption.text = _t("钻石", "Diamonds")
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caption.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
		col.add_child(caption)
		var button: Button = ACTION_BUTTON.instantiate()
		button.text = _t("即将开放", "Coming soon")
		button.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
		button.disabled = true
		col.add_child(button)
	var foot := Label.new()
	foot.text = _t("充值成功后由服务器发放钻石；当前页面不收取费用。",
		"Diamonds are credited by the server after a verified purchase. No payment is taken here yet.")
	foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	foot.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	_special_content.add_child(foot)


func _render_appearance() -> void:
	_section_title(_t("冰雪之境", "Frost realm"), _t(
		"七日登录，逐步点亮冰雪棋盘。第七天领取后永久拥有。",
		"Reveal the frost board over seven login days. Claim day seven to own it forever."))
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", Tokens.GAP_L)
	_special_content.add_child(row)
	var art := TextureRect.new()
	art.texture = ICE_BOARD_TEX
	art.custom_minimum_size = Vector2(620, 270)
	art.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	row.add_child(art)
	var side := VBoxContainer.new()
	side.custom_minimum_size.x = 335
	side.add_theme_constant_override("separation", Tokens.GAP_M)
	row.add_child(side)
	var status := Label.new()
	status.text = _t("已永久拥有", "Permanently owned") if _owned.has("prep_skin_ice") else _t(
		"七日活动限定", "Seven-day event exclusive")
	status.add_theme_font_size_override("font_size", Tokens.FONT_BUTTON)
	status.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	side.add_child(status)
	var desc := Label.new()
	desc.text = _t("让备战棋盘化为冰封战场，河流与待命区也换上冰雪主题。",
		"Transform your preparation board, river and bench into a frozen realm.")
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	side.add_child(desc)
	var action: Button = ACTION_BUTTON.instantiate()
	action.text = _t("立即使用", "Equip now") if _owned.has("prep_skin_ice") else _t(
		"查看七日登录", "View seven-day rewards")
	action.theme_type_variation = Theming.VARIATION_PRIMARY
	action.pressed.connect(func() -> void:
		if _owned.has("prep_skin_ice"):
			_equip_ice_skin()
		else:
			_select_category(CATEGORY_EVENT))
	side.add_child(action)


func _render_event() -> void:
	_section_title(_t("七日登录 · 冰雪觉醒", "Seven days · Frost awakening"), _t(
		"每天主动领取一次，点亮一片冰雪。累计七天即可永久解锁。",
		"Claim once per game day. Every claim reveals part of the frost board; day seven unlocks it."))
	var progress := int(_login_state.get("ice_skin_progress", 0))
	var top := HBoxContainer.new()
	top.custom_minimum_size.y = 220
	top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	top.add_theme_constant_override("separation", Tokens.GAP_M)
	_special_content.add_child(top)
	var stage := Control.new()
	stage.custom_minimum_size = Vector2(690, 215)
	stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stage.clip_contents = true
	top.add_child(stage)
	var image := TextureRect.new()
	image.texture = ICE_BOARD_TEX
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var reveal := ShaderMaterial.new()
	reveal.shader = ICE_REVEAL_SHADER
	reveal.set_shader_parameter("progress", float(progress))
	image.material = reveal
	stage.add_child(image)
	var badge := Label.new()
	badge.text = _t("冰雪点亮  %d / 7" % progress, "FROST REVEALED  %d / 7" % progress)
	badge.position = Vector2(16, 12)
	badge.add_theme_font_size_override("font_size", Tokens.FONT_BUTTON)
	badge.add_theme_color_override("font_color", Color.WHITE)
	badge.add_theme_stylebox_override("normal", Tokens.panel_box(
		Color(0.02, 0.09, 0.15, 0.86), Tokens.GOLD_EDGE, 6))
	stage.add_child(badge)
	var side := VBoxContainer.new()
	side.custom_minimum_size.x = 325
	side.add_theme_constant_override("separation", Tokens.GAP_M)
	top.add_child(side)
	var frame := TextureRect.new()
	frame.texture = ICE_FRAME_TEX
	frame.custom_minimum_size = Vector2(120, 120)
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	side.add_child(frame)
	var current := Label.new()
	current.text = _t("活动状态暂时无法加载", "Event status unavailable") if _login_state.is_empty() else (
		_t("全部奖励已领取", "All rewards claimed") if bool(_login_state.get("completed", false)) else (
		_t("今日可领取", "Ready to claim") if bool(_login_state.get("claimable_today", false)) else _t(
			"明日继续点亮", "Return next game day")))
	current.add_theme_font_size_override("font_size", Tokens.FONT_BUTTON)
	current.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	side.add_child(current)
	var note := Label.new()
	note.text = _t("第 6 天获得限定头像框；第 7 天自动解锁冰雪皮肤。",
		"Day six grants the exclusive frame. Day seven unlocks the frost skin.")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	side.add_child(note)
	if _owned.has("prep_skin_ice"):
		var equip: Button = ACTION_BUTTON.instantiate()
		equip.text = _t("立即使用冰雪皮肤", "Equip frost skin")
		equip.theme_type_variation = Theming.VARIATION_PRIMARY
		equip.pressed.connect(_equip_ice_skin)
		side.add_child(equip)
	var rewards: Array = _login_state.get("rewards", [])
	if rewards.is_empty():
		var fallback: Variant = JSON.parse_string(FileAccess.get_file_as_string(
			"res://data/seven_day_login.json"))
		if fallback is Dictionary:
			rewards = (fallback as Dictionary).get("rewards", [])
	var strip := HBoxContainer.new()
	strip.add_theme_constant_override("separation", Tokens.GAP_S)
	strip.custom_minimum_size.y = 150
	_special_content.add_child(strip)
	for raw in rewards:
		strip.add_child(_reward_card(raw as Dictionary))


func _reward_card(reward: Dictionary) -> Control:
	var day := int(reward.get("day", 0))
	var claimed: Array = _login_state.get("claimed_days", [])
	var done := day in claimed
	var ready := day == int(_login_state.get("current_day", 0)) and bool(
		_login_state.get("claimable_today", false))
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(137, 150)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE_RAISED, Tokens.GOLD_EDGE if ready else Tokens.BORDER, Tokens.GAP_S))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	card.add_child(col)
	var title := Label.new()
	title.text = "DAY %d" % day
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	title.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	col.add_child(title)
	var icon := TextureRect.new()
	icon.texture = ICE_FRAME_TEX if day == 6 else Currency.icon(
		"coin" if str(reward.get("reward_type", "")) == "coin" else "diamond")
	icon.custom_minimum_size = Vector2(48, 48)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	col.add_child(icon)
	var caption := Label.new()
	caption.text = (_t("限定头像框", "Exclusive frame") if day == 6 else
		_t("100 钻石 + 皮肤", "100 gems + skin") if day == 7 else
		"%d %s" % [int(reward.get("amount", 0)), _t("金币", "coins") if
		str(reward.get("reward_type", "")) == "coin" else _t("钻石", "diamonds")])
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	caption.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	col.add_child(caption)
	var button: Button = ACTION_BUTTON.instantiate()
	button.custom_minimum_size = Vector2(0, 34)
	button.text = _t("已领取 ✓", "Claimed ✓") if done else (
		_t("领取", "Claim") if ready else _t("未解锁", "Locked"))
	button.disabled = not ready
	if ready:
		button.theme_type_variation = Theming.VARIATION_PRIMARY
		button.pressed.connect(_claim_seven_day)
	col.add_child(button)
	return card


func _claim_seven_day() -> void:
	if _busy:
		return
	_busy = true
	var previous_progress := int(_login_state.get("ice_skin_progress", 0))
	var result: Dictionary = await AccountManager.claim_seven_day_login()
	_busy = false
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) / 100 != 2:
		# A lost response may follow a successful commit. Read server state before
		# showing failure so the card and balances cannot invite another claim.
		var refreshed: Dictionary = await AccountManager.fetch_seven_day_login()
		if int(refreshed.get("code", 0)) / 100 == 2:
			_login_state = refreshed.get("body", {}) as Dictionary
		var wallet_result: Dictionary = await AccountManager.fetch_wallet()
		if int(wallet_result.get("code", 0)) / 100 == 2:
			var wallet_body: Dictionary = wallet_result.get("body", {})
			_coin = int(wallet_body.get("coin", _coin))
			_diamond = int(wallet_body.get("diamond", _diamond))
		if int(_login_state.get("ice_skin_progress", 0)) > previous_progress:
			_set_notice(_t("今天的奖励已到账", "Today's reward is in your account"), false)
		else:
			_set_notice(str(result.get("error", _t("领取失败", "Claim failed"))), true)
		_render()
		return
	var body: Dictionary = result.get("body", {})
	var old_coin := _coin
	var old_diamond := _diamond
	_coin = int(body.get("coin", _coin))
	_diamond = int(body.get("diamond", _diamond))
	if _coin > old_coin or _diamond > old_diamond:
		SfxService.play(SfxService.CUE_UI_CURRENCY_GAIN)
	var reward: Dictionary = body.get("reward", {})
	if str(reward.get("reward_type", "")) == "avatar_frame":
		_owned[str(reward.get("item_id", ""))] = true
	if bool(body.get("skin_unlocked", false)):
		_owned["prep_skin_ice"] = true
	var fresh: Dictionary = await AccountManager.fetch_seven_day_login()
	if int(fresh.get("code", 0)) / 100 == 2:
		_login_state = fresh.get("body", {}) as Dictionary
	_render()
	if bool(body.get("skin_unlocked", false)):
		DialogService.confirm({"owner": self, "title": _t("冰雪之境已解锁！", "Frost realm unlocked!"),
			"body": _t("七日点亮完成。冰雪皮肤已永久进入你的账号。", "The frost skin is now permanently yours."),
			"confirm_text": _t("立即使用", "Equip now"), "cancel_text": _t("稍后", "Later"),
			"on_result": func(answer: String, _id: String) -> void:
				if answer == ConfirmDialog.RESULT_CONFIRMED:
					_equip_ice_skin()})
	else:
		DialogService.info({"owner": self, "title": _t("奖励已领取", "Reward claimed"),
			"body": _t("冰雪之境已点亮第 %d 片。" % int(body.get("day", 0)),
				"Frost reveal: %d of 7." % int(body.get("day", 0)))})


func _equip_ice_skin() -> void:
	var result: Dictionary = await AccountManager.save_prep_skin("prep_skin_ice")
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) / 100 == 2:
		PrepSkin.active_id = "prep_skin_ice"
		_set_notice(_t("冰雪皮肤已使用", "Frost skin equipped"), false)
	else:
		_set_notice(str(result.get("error", _t("使用失败", "Could not equip"))), true)
	_render()


func _card(item: Dictionary) -> Control:
	var grants := str(item.get("grants", ""))
	var owned := bool(_owned.get(grants, false))
	var price := int(item.get("price", 0))
	var currency := str(item.get("currency", "diamond"))
	var catalog_pending := bool(item.get("_catalog_pending", false))
	var affordable := _balance_of(currency) >= price
	var selected := _item_id(item) == _selected_item_id

	var panel := PanelContainer.new()
	panel.custom_minimum_size = CARD_SIZE
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	panel.add_theme_stylebox_override(
		"panel", Tokens.panel_box(
			Tokens.SURFACE_RAISED,
			Tokens.GOLD_EDGE if selected else (Tokens.GOLD_PRESSED if owned else Tokens.BORDER),
			Tokens.GAP_S))
	panel.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_select_item(item)
		elif event is InputEventScreenTouch and event.pressed:
			_select_item(item))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(box)
	box.add_child(_preview_stage(item, owned, PREVIEW_SIZE))

	var name_label := Label.new()
	name_label.text = _item_name(item)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.clip_text = true
	name_label.tooltip_text = _item_name(item)
	name_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	name_label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(name_label)
	if str(item.get("kind", "")) == "pet":
		var effect := Label.new()
		match grants:
			"pet_mushroom":
				effect.text = _t("自身生命 +1%", "Self HP +1%")
			"pet_cat":
				effect.text = _t("金币利息 +1%", "Coin interest +1%")
			"pet_rabbit":
				effect.text = _t("自身攻击 +1%", "Self attack +1%")
			_:
				effect.text = _t("伙伴效果", "Companion effect")
		effect.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		effect.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
		effect.add_theme_color_override("font_color", Tokens.CYAN)
		effect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(effect)

	var price_row := HBoxContainer.new()
	price_row.custom_minimum_size.y = 28
	price_row.alignment = BoxContainer.ALIGNMENT_CENTER
	price_row.add_theme_constant_override("separation", Tokens.GAP_S)
	price_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(price_row)
	if owned:
		var owned_text := Label.new()
		owned_text.text = _t("收藏中", "In collection")
		owned_text.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
		owned_text.add_theme_color_override("font_color", Tokens.GOLD)
		owned_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
		price_row.add_child(owned_text)
	else:
		var icon := TextureRect.new()
		icon.texture = Currency.icon(currency)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(28, 28)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		price_row.add_child(icon)
		var price_label := Label.new()
		price_label.text = Currency.comma(price)
		price_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
		# 买不起就把价格标红。按钮上只写「余额不足」不够 —— 玩家要看到差多少。
		price_label.add_theme_color_override(
			"font_color", Tokens.TEXT_PRIMARY if affordable or catalog_pending else Tokens.DANGER)
		price_row.add_child(price_label)

	var button: Button = ACTION_BUTTON.instantiate()
	button.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	if owned:
		if str(item.get("kind", "")) == "pet":
			var active := grants == _active_pet
			button.text = _t("使用中", "Equipped") if active else _t("使用", "Equip")
			button.disabled = active
			if not active:
				button.pressed.connect(func() -> void: _equip_pet(grants))
		else:
			button.text = _t("已拥有 ✓", "Owned ✓")
			button.disabled = true
	elif catalog_pending:
		button.text = _t("价格待同步", "Awaiting sync")
		button.disabled = true
	elif not affordable:
		button.text = _t("余额不足", "Not enough")
		button.disabled = true
	else:
		button.text = _t("购买", "Buy")
		button.pressed.connect(func() -> void: _confirm_buy(item))
	box.add_child(button)
	return panel


func _preview_stage(item: Dictionary, owned: bool, preview_size: Vector2) -> Control:
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
	var preview := _preview(item, false, preview_size)
	preview.custom_minimum_size = preview_size
	_ignore_mouse_tree(preview)
	center.add_child(preview)

	if owned:
		var badge := Label.new()
		badge.text = _t("  已拥有  ", "  OWNED  ")
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		badge.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		badge.position = Vector2(-90, 8)
		badge.size = Vector2(82, 26)
		badge.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
		badge.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
		badge.add_theme_stylebox_override("normal", Tokens.panel_box(
			Tokens.INK_PANEL, Tokens.GOLD_PRESSED, 2))
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stage.add_child(badge)
	return stage


# 卡片上的图。宠物优先使用手绘插画，缺图时回退 3D 模型；头像 / 头像框是 2D 图，
# 棋盘皮肤是实机画面截的预览图（铺满卡片，裁掉多出来的边）。
func _preview(item: Dictionary, owned: bool, preview_size: Vector2 = PREVIEW_SIZE) -> Control:
	var kind := str(item.get("kind", ""))
	var grants := str(item.get("grants", ""))
	if kind == "pet":
		return PetPreview.build_illustration(grants, preview_size, owned)
	if kind == "avatar_frame":
		return _frame_preview(grants, preview_size, owned)
	var tex: Texture2D = null
	if kind == CATEGORY_SKINS:
		var skin_preview := PrepSkin.preview_path(grants)
		if ResourceLoader.exists(skin_preview):
			tex = load(skin_preview) as Texture2D
	else:
		tex = AvatarCatalog.texture_for(grants)
	if tex == null:
		return PetPreview.placeholder(preview_size, owned)
	var rect := TextureRect.new()
	rect.texture = tex
	rect.custom_minimum_size = preview_size
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = (TextureRect.STRETCH_KEEP_ASPECT_COVERED if kind == CATEGORY_SKINS
		else TextureRect.STRETCH_KEEP_ASPECT_CENTERED)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if owned:
		rect.modulate = Color(0.45, 0.45, 0.45)
	return rect


func _frame_preview(grants: String, preview_size: Vector2, owned: bool) -> Control:
	var stage := Control.new()
	stage.custom_minimum_size = preview_size
	stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var frame := TextureRect.new()
	frame.texture = AvatarCatalog.frame_texture_for(grants)
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.add_child(frame)
	if owned:
		stage.modulate = Color(0.70, 0.70, 0.70)
	return stage


func _render_detail(item: Dictionary) -> void:
	if item.is_empty():
		_detail.add_child(_detail_hint(_t("选择一个商品查看详情", "Select an item to see details")))
		return
	var grants := str(item.get("grants", ""))
	var owned := bool(_owned.get(grants, false))
	var price := int(item.get("price", 0))
	var currency := str(item.get("currency", "diamond"))
	var affordable := _balance_of(currency) >= price
	var catalog_pending := bool(item.get("_catalog_pending", false))

	var eyebrow := Label.new()
	eyebrow.text = _t("当前选择", "SELECTED ITEM")
	eyebrow.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	eyebrow.add_theme_color_override("font_color", Tokens.GOLD)
	_detail.add_child(eyebrow)
	_detail.add_child(_preview_stage(item, owned,
		Vector2(280, 218) if _item_category(item) == CATEGORY_FRAMES else DETAIL_PREVIEW_SIZE))

	var name_label := Label.new()
	name_label.text = _item_name(item)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	name_label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	_detail.add_child(name_label)

	var kind_label := Label.new()
	kind_label.text = _kind_label(item)
	kind_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kind_label.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	kind_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	_detail.add_child(kind_label)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail.add_child(spacer)

	var status := Label.new()
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	if owned:
		status.text = _t("✓ 已加入你的收藏", "✓ Already in your collection")
		status.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	else:
		status.text = (_t("价格：%s", "Price: %s") % Currency.comma(price))
		status.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY if affordable else Tokens.DANGER)
	_detail.add_child(status)

	var buy: Button = ACTION_BUTTON.instantiate()
	buy.custom_minimum_size = Vector2(0, Tokens.BUTTON_HEIGHT)
	if owned:
		if str(item.get("kind", "")) == "pet":
			var active := grants == _active_pet
			buy.text = _t("使用中", "Equipped") if active else _t("使用", "Equip")
			buy.disabled = active
			if not active:
				buy.theme_type_variation = Theming.VARIATION_PRIMARY
				buy.pressed.connect(func() -> void: _equip_pet(grants))
		else:
			buy.text = _t("已拥有 ✓", "Owned ✓")
			buy.disabled = true
	elif catalog_pending:
		buy.text = _t("价格待同步", "Awaiting sync")
		buy.disabled = true
	elif not affordable:
		buy.text = _t("余额不足", "Not enough balance")
		buy.disabled = true
	else:
		buy.text = _t("购买", "Buy")
		buy.theme_type_variation = Theming.VARIATION_PRIMARY
		buy.pressed.connect(func() -> void: _confirm_buy(item))
	_detail.add_child(buy)

	if not owned:
		var balance_hint := Label.new()
		balance_hint.text = (_t("当前余额：%s", "Balance: %s")
			% Currency.comma(_balance_of(currency)))
		balance_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		balance_hint.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
		balance_hint.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
		_detail.add_child(balance_hint)


func _detail_hint(text: String) -> Control:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	return label


func _select_category(category: String) -> void:
	if _active_category == category:
		return
	_active_category = category
	_selected_item_id = ""
	_render()


func _equip_pet(pet_id: String) -> void:
	if _busy:
		return
	_busy = true
	var result: Dictionary = await AccountManager.set_active_pet(pet_id)
	_busy = false
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) / 100 == 2:
		_active_pet = pet_id
		await PlayerProfile.refresh_pets()
		_set_notice(_t("宠物已设为出战", "Pet equipped"), false)
	else:
		_set_notice(str(result.get("error", _t("使用失败", "Could not equip"))), true)
	_render()


func _select_item(item: Dictionary) -> void:
	var item_id := _item_id(item)
	if item_id == _selected_item_id:
		return
	_selected_item_id = item_id
	_render()


func _visible_items() -> Array:
	if _active_category in [CATEGORY_PETS, CATEGORY_ALL]:
		var local: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/shop.json"))
		var coin_pets: Array = []
		if local is Dictionary:
			for raw in (local as Dictionary).get("items", []):
				var configured := raw as Dictionary
				if str(configured.get("kind", "")) != "pet" or str(configured.get("currency", "")) != "coin":
					continue
				if not bool(configured.get("enabled", true)):
					continue
				var matching: Dictionary = {}
				for server_raw in _items:
					var server_item := server_raw as Dictionary
					if str(server_item.get("id", "")) == str(configured.get("id", "")):
						matching = server_item
						break
				if str(matching.get("currency", "")) == "coin" and int(matching.get("price", -1)) == int(configured.get("price", 0)):
					coin_pets.append(matching)
				else:
					var preview := configured.duplicate()
					preview["_catalog_pending"] = true
					coin_pets.append(preview)
		return coin_pets
	if _active_category == CATEGORY_FRAMES:
		var local_frames: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/shop.json"))
		var frames: Array = []
		if local_frames is Dictionary:
			for raw in (local_frames as Dictionary).get("items", []):
				var configured := raw as Dictionary
				if str(configured.get("kind", "")) != "avatar_frame" or not bool(configured.get("enabled", true)):
					continue
				var matching: Dictionary = {}
				for server_raw in _items:
					var server_item := server_raw as Dictionary
					if str(server_item.get("id", "")) == str(configured.get("id", "")):
						matching = server_item
						break
				if str(matching.get("grants", "")) == str(configured.get("grants", "")) \
					and str(matching.get("currency", "")) == "coin" \
					and int(matching.get("price", -1)) == int(configured.get("price", 0)):
					frames.append(matching)
				else:
					var preview := configured.duplicate()
					preview["_catalog_pending"] = true
					frames.append(preview)
		return frames
	var out: Array = []
	for raw in _items:
		var item := raw as Dictionary
		if _item_category(item) == _active_category and (
			_active_category != CATEGORY_PETS or str(item.get("currency", "")) == "coin"):
			out.append(item)
	return out


func _category_has_items(category: String) -> bool:
	if category in [CATEGORY_DIAMONDS, CATEGORY_FRAMES, CATEGORY_SKINS, CATEGORY_EVENT]:
		return true
	for raw in _items:
		if _item_category(raw as Dictionary) == category:
			return true
	return false


func _selected_item(items: Array) -> Dictionary:
	for raw in items:
		var item := raw as Dictionary
		if _item_id(item) == _selected_item_id:
			return item
	return {}


func _item_id(item: Dictionary) -> String:
	return str(item.get("id", item.get("grants", "")))


func _item_category(item: Dictionary) -> String:
	var kind := str(item.get("kind", "")).to_lower()
	if kind == CATEGORY_SKINS:
		return CATEGORY_SKINS
	if kind.contains("pet"):
		return CATEGORY_PETS
	if kind.contains("frame"):
		return CATEGORY_FRAMES
	return CATEGORY_AVATARS


func _kind_label(item: Dictionary) -> String:
	match _item_category(item):
		CATEGORY_PETS:
			return _t("宠物 · 可在背包设为出战", "PET · Equip it from your Bag")
		CATEGORY_FRAMES:
			return _t("头像框 · 购买后在资料页佩戴", "AVATAR FRAME · Equip from Profile")
		CATEGORY_SKINS:
			return _t("棋盘皮肤 · 在「备战」里更换", "BOARD SKIN · Switch it in Prep")
		_:
			return _t("头像 · 个人资料装饰", "AVATAR · Profile cosmetic")


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


# --- 购买 ---------------------------------------------------------------------

func _confirm_buy(item: Dictionary) -> void:
	if _busy:
		return
	var price := int(item.get("price", 0))
	var currency_name := _t("钻石", "diamonds") if str(item.get("currency", "")) == "diamond" \
		else _t("金币", "coins")
	DialogService.confirm({
		"title": _t("确认购买", "Confirm purchase"),
		# 中英语序不同，各自格式化 —— 硬凑成一个模板会让参数顺序随语言变，
		# 那是「改文案顺手改错参数」的经典入口。
		"body": ("Buy \"%s\" for %d %s?" % [_item_name(item), price, currency_name]
			if _english()
			else "花 %d %s 购买「%s」？" % [price, currency_name, _item_name(item)]),
		"confirm_text": _t("购买", "Buy"),
		"owner": self,
		"on_result": func(result: String, _request_id: String) -> void:
			if result == ConfirmDialog.RESULT_CONFIRMED:
				await _buy(item),
	})


func _buy(item: Dictionary) -> void:
	if _busy:
		return
	_busy = true
	var item_id := str(item.get("id", ""))
	# 🔴 同一件商品重试时复用上一次的幂等键。换新的等于开一张新订单 ——
	# 上一笔如果其实成功了（只是回执丢在路上），玩家就被扣了两次钱。
	if _pending_order_id.is_empty() or _pending_item_id != item_id:
		_pending_order_id = AccountManager.new_client_order_id()
		_pending_item_id = item_id
	var result: Dictionary = await AccountManager.place_shop_order(_pending_order_id, item_id)
	_busy = false
	if not is_inside_tree():
		return

	var code := int(result.get("code", 0))
	if code / 100 == 2:
		_pending_order_id = ""
		_pending_item_id = ""
		var receipt: Dictionary = (result.get("body", {}) as Dictionary).get("receipt", {})
		var diamond_after := int(receipt.get("diamond", _diamond))
		var coin_after := int(receipt.get("coin", _coin))
		# 9.17 钻石/金币收支音。SfxService 的代币监视器只盯 GameState.gold（局内金币），
		# 盯不到这里的钱包 —— 钻石是服务端钱包（AccountManager.fetch_wallet），
		# 各页面自己 fetch 自己存，没有中心状态。
		#
		# 按**余额变化方向**播，而不是按「购买 = 扣钱」写死：商品里既有花钻石买的
		# 东西，也有充值钻石的档位，后者是入账。
		#
		# 重放的旧回执（replayed）不改余额，所以那段天然不会响。
		if diamond_after != _diamond:
			SfxService.play(SfxService.CUE_UI_CURRENCY_GAIN if diamond_after > _diamond else SfxService.CUE_UI_CURRENCY_SPEND)
		elif coin_after != _coin:
			SfxService.play(SfxService.CUE_UI_CURRENCY_GAIN if coin_after > _coin else SfxService.CUE_UI_CURRENCY_SPEND)
		_diamond = diamond_after
		_coin = coin_after
		_owned[str(receipt.get("granted", ""))] = true
		# replayed = 服务端重放了一张旧回执（上一次其实成功了）。不另说一句的话，
		# 玩家会以为这次又扣了一笔。
		# 买的是宠物就把归属缓存刷一遍 —— 备战页与出战宠物都读 PlayerProfile，
		# 不刷的话玩家买完回去发现新宠物不在那儿。
		if str(item.get("kind", "")) == "pet":
			await PlayerProfile.refresh_pets()
		if bool(receipt.get("replayed", false)):
			_set_notice(_t("这件你刚才已经买到了，没有重复扣费",
				"You already bought this a moment ago — you were not charged twice"), false)
		else:
			_set_notice(_t("购买成功", "Purchased"), false)
		_render()
		return

	# 409 / 402 这些是「明确的失败」，服务端一定没扣钱，可以把幂等键丢掉。
	# 但 0（根本没发出去 / 没收到响应）和 5xx **必须留着** —— 那笔可能已经成交了，
	# 换个新 id 重试就会变成第二笔订单。
	if code != 0 and code < 500:
		_pending_order_id = ""
		_pending_item_id = ""
	var message := str(result.get("error", _t("购买失败", "Purchase failed")))
	if code == 402:
		message = _t("余额不足", "Not enough balance")
	elif code == 0 or code >= 500:
		message = "%s（%s）" % [message,
			_t("再点一次「购买」会接着这一笔，不会重复扣费",
				"Tapping Buy again resumes this order — you will not be charged twice")]
	_set_notice(message, true)
	# 余额和拥有状态可能已经变了（比如在另一台设备上买过），重新拉一次。
	await _reload()


# --- 小工具 -------------------------------------------------------------------

func _balance_of(currency: String) -> int:
	return _diamond if currency == "diamond" else _coin


func _item_name(item: Dictionary) -> String:
	var key := "name_en" if _english() else "name"
	return str(item.get(key, item.get("name", item.get("id", ""))))


func _set_notice(text: String, bad: bool) -> void:
	_notice = text
	_notice_bad = bad


func _english() -> bool:
	return LocaleManager.get_locale().begins_with("en")


func _t(zh: String, en: String) -> String:
	return en if _english() else zh
