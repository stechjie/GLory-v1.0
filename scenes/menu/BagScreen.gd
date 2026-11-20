extends Control

# 背包界面。入口：主菜单右上角「背包」。
#
# 2026-11-20 改版（用户定）：
#   · 去掉头像和宠物 —— 换宠物在备战页（PetScreen），换头像在资料页（ProfileScreen），
#     这里不再各做一份（两处要同步的逻辑迟早不一致）。
#   · 分页：全部 / 道具 / 体验卡 / 礼物 / 活动。现在只有体验卡；道具、礼物、活动暂时没有东西，显示空页。
#
# 体验卡（规则在 backend/app/trial.py）：
#   · 来源：宠物祈愿、樱花祈愿没抽中时附带；商城「棋子」页用游戏币买种族卡。
#   · 卡放在背包里不计时，点「使用」才开始；同一目标再用一张，时间往后叠。
#   · 已经永久拥有的目标，卡不能用，只能卖；任何卡都能卖（1/3/7 天 = 100/200/300 游戏币）。
#   · 背包里的卡永不过期。
#   · 正在体验的东西不在背包里列，剩余时间显示在用到它的地方（备战页的种族 / 皮肤 / 宠物卡上）。
#     这里只在选中一张卡时顺带说一句「这个目标正在体验中，剩 X」。
#
# ## 🔴 选中不重建格子
#
# 同旧版背包（10.08 反馈第 6 条）：选中只改卡框颜色、重画右侧详情。重建网格会把正在处理这次点击的
# 格子 remove + queue_free，安卓的模拟鼠标事件随后命中一批还没布局的新格子，表现是「点第一个跳到最后一个」。
# 只有数据变了（拉到新背包、用了 / 卖了一张）才走 _render()。

signal back_requested

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const Kit := preload("res://ui/theme/ParchmentKit.gd")
const UiJuice := preload("res://ui/theme/UiJuice.gd")
const Card := preload("res://ui/components/TrialCardKit.gd")
const SellDialog := preload("res://ui/components/TrialSellDialog.gd")
const Currency := preload("res://scripts/account/Currency.gd")
const TouchScrollContainer := preload("res://ui/components/TouchScrollContainer.gd")

const SECTION_COLOR := Color("8a4b12")
const PICK_TINT := Color(1.0, 0.86, 0.56)
const TILE := Vector2(126, 126)
const DETAIL_WIDTH := 360.0
const DETAIL_TILE := Vector2(150, 150)
# 一行放几张按左边面板的宽度现算（矮 / 窄屏少放几张，不把整页撑出屏幕）。
const MIN_COLUMNS := 2

const TAB_ALL := "all"
const TAB_ITEMS := "items"
const TAB_TRIALS := "trials"
const TAB_GIFTS := "gifts"
const TAB_EVENTS := "events"
const TABS := [
	{"id": TAB_ALL, "zh": "全部", "en": "All"},
	{"id": TAB_ITEMS, "zh": "道具", "en": "Items"},
	{"id": TAB_TRIALS, "zh": "体验卡", "en": "Trials"},
	{"id": TAB_GIFTS, "zh": "礼物", "en": "Gifts"},
	{"id": TAB_EVENTS, "zh": "活动", "en": "Events"},
]
# 体验卡排在「全部」里的顺序：种族、宠物、棋盘皮肤。
const KIND_ORDER := ["race", "pet", "prep_skin"]

var _loading := true
var _load_failed := false
var _busy := false
var _cards: Array = []          # 背包接口的 cards，排好序
var _trials: Dictionary = {}    # 正在体验：target -> expires_at
var _clock_offset := 0.0
var _active_tab := TAB_ALL
var _selected := ""             # "target|days"
var _pending_use: Dictionary = {}   # "target|days" -> 操作号（断网重试同一笔）

var _tab_buttons: Dictionary = {}
var _grid: GridContainer
var _grid_scroll: ScrollContainer
var _empty_label: Label
var _detail: VBoxContainer
# 「出售」「使用」钉在详情面板底部、滚动区外面：矮屏上文案一长，按钮也不会被滚到看不见的地方。
var _actions: HBoxContainer
var _tiles: Dictionary = {}     # key -> PanelContainer


func _ready() -> void:
	theme = Kit.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	# 开发截图 / 布局门禁在进树前灌一份固定背包（背包接口的 body 形状），不发网络请求。
	if has_meta("ui_capture_fixture"):
		_adopt(get_meta("ui_capture_fixture") as Dictionary)
		return
	_render()
	_reload()


# --- 骨架 ---------------------------------------------------------------------

func _build() -> void:
	Kit.backdrop(self, "inventory_storage")
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, Tokens.PAD)
	add_child(margin)
	# 灵动岛 / 圆角那几条让出来；背景照样铺满（ui/services/SafeArea.gd）。
	SafeArea.track(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", Tokens.GAP_M)
	margin.add_child(root)
	var header := Kit.header(_t("背包", "Bag"), func() -> void: back_requested.emit())
	root.add_child(header)
	var tabs := _tab_bar()
	root.add_child(tabs)

	var page := HBoxContainer.new()
	page.name = "BagPage"
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_theme_constant_override("separation", Tokens.GAP_M)
	root.add_child(page)
	page.add_child(_collection_panel())
	page.add_child(_detail_panel())
	UiJuice.pop_in([header, tabs, page], 0.0, 0.06, 0.93)


func _tab_bar() -> Control:
	var row := HBoxContainer.new()
	row.name = "BagTabs"
	row.add_theme_constant_override("separation", Tokens.GAP_M)
	for entry in TABS:
		var tab_id := str(entry.id)
		var button: Button = ACTION_BUTTON.instantiate()
		button.name = "Tab_%s" % tab_id
		button.text = _t(str(entry.zh), str(entry.en))
		Kit.style_tab(button, 50.0, 20)
		button.pressed.connect(func() -> void: _select_tab(tab_id))
		row.add_child(button)
		_tab_buttons[tab_id] = button
	return row


func _collection_panel() -> Control:
	var panel := PanelContainer.new()
	panel.name = "BagCollection"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", Kit.box("panel", Vector4(34, 40, 34, 20)))
	var scroll := TouchScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	_grid_scroll = scroll
	scroll.resized.connect(_fit_columns)
	var holder := VBoxContainer.new()
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.add_theme_constant_override("separation", Tokens.GAP_S)
	scroll.add_child(holder)
	_empty_label = Label.new()
	_empty_label.name = "BagEmpty"
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_label.custom_minimum_size.y = 120
	_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_label.add_theme_color_override("font_color", Kit.INK_SOFT)
	holder.add_child(_empty_label)
	_grid = GridContainer.new()
	_grid.name = "BagGrid"
	_grid.columns = MIN_COLUMNS
	_grid.add_theme_constant_override("h_separation", Tokens.GAP_S)
	_grid.add_theme_constant_override("v_separation", Tokens.GAP_S)
	holder.add_child(_grid)
	return panel


func _detail_panel() -> Control:
	var panel := PanelContainer.new()
	panel.name = "BagDetailPanel"
	panel.custom_minimum_size = Vector2(DETAIL_WIDTH, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", Kit.box("panel", Vector4(56, 46, 56, 30)))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(column)
	var scroll := TouchScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)
	_actions = HBoxContainer.new()
	_actions.name = "BagActions"
	_actions.alignment = BoxContainer.ALIGNMENT_CENTER
	_actions.add_theme_constant_override("separation", Tokens.GAP_M)
	column.add_child(_actions)
	_detail = VBoxContainer.new()
	_detail.name = "BagDetail"
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.add_theme_constant_override("separation", Tokens.GAP_S)
	scroll.add_child(_detail)
	return panel


func _fit_columns() -> void:
	if _grid == null or _grid_scroll == null:
		return
	var gap := float(Tokens.GAP_S)
	# 竖向滚动条出现时会占掉一条宽度，先让出来，免得列数在有无滚动条之间来回跳。
	var width := _grid_scroll.size.x - 14.0
	var columns := maxi(MIN_COLUMNS, int(floor((width + gap) / (TILE.x + gap))))
	if columns != _grid.columns:
		_grid.columns = columns


# --- 数据 ---------------------------------------------------------------------

func _reload() -> void:
	_loading = true
	_render()
	var result: Dictionary = await AccountManager.fetch_bag()
	if not is_inside_tree():
		return
	_loading = false
	if int(result.get("code", 0)) / 100 != 2:
		_load_failed = true
		_render()
		return
	_load_failed = false
	_adopt(result.get("body", {}))


func _adopt(body: Dictionary) -> void:
	_loading = false
	_clock_offset = Card.clock_offset(str(body.get("server_now", "")))
	_trials = Card.trial_map(body.get("trials", []))
	_cards.clear()
	for raw in body.get("cards", []):
		if raw is Dictionary and int(raw.get("count", 0)) > 0:
			_cards.append(raw)
	_cards.sort_custom(_card_before)
	_render()


static func _card_before(a: Dictionary, b: Dictionary) -> bool:
	var ka := KIND_ORDER.find(str(a.get("kind", "")))
	var kb := KIND_ORDER.find(str(b.get("kind", "")))
	if ka != kb:
		return ka < kb
	if str(a.get("target", "")) != str(b.get("target", "")):
		return str(a.get("target", "")) < str(b.get("target", ""))
	return int(a.get("days", 0)) < int(b.get("days", 0))


static func _key(card: Dictionary) -> String:
	return "%s|%d" % [str(card.get("target", "")), int(card.get("days", 0))]


func _visible_cards() -> Array:
	# 现在只有体验卡：「全部」「体验卡」两页显示它们，其余三页是空的。
	if _active_tab == TAB_ALL or _active_tab == TAB_TRIALS:
		return _cards
	return []


func _card_by_key(key: String) -> Dictionary:
	for card in _cards:
		if _key(card) == key:
			return card
	return {}


# --- 渲染 ---------------------------------------------------------------------

func _render() -> void:
	if _grid == null:
		return
	for tab_id in _tab_buttons:
		(_tab_buttons[tab_id] as Button).set_pressed_no_signal(str(tab_id) == _active_tab)
	_clear_children(_grid)
	_tiles.clear()
	if _loading:
		_show_empty(_t("正在整理背包…", "Organizing your bag…"))
		_render_detail_hint(_t("正在读取你的物品", "Loading your items"))
		return
	if _load_failed:
		_show_empty(_t("背包没拉到，稍后再试", "Could not load your bag — try again later"))
		_render_detail_retry()
		return
	var cards := _visible_cards()
	if cards.is_empty():
		_show_empty(_empty_text())
		_render_detail_hint(_t("选中一件物品查看详情", "Select an item to see details"))
		return
	_empty_label.visible = false
	if _card_by_key(_selected).is_empty():
		_selected = _key(cards[0])
	for card in cards:
		var key := _key(card)
		var tile := Card.tile(card, TILE)
		tile.name = "Card_%s_%d" % [str(card.get("target", "")), int(card.get("days", 0))]
		tile.mouse_filter = Control.MOUSE_FILTER_STOP
		tile.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		tile.gui_input.connect(_on_tile_input.bind(key))
		_tiles[key] = tile
		_grid.add_child(tile)
	_refresh_selection()


func _show_empty(text: String) -> void:
	_empty_label.text = text
	_empty_label.visible = true


func _empty_text() -> String:
	match _active_tab:
		TAB_TRIALS:
			return _t("还没有体验卡。宠物祈愿、樱花祈愿有机会获得，也可以在商城「棋子」页用游戏币购买种族体验卡。",
				"No trial cards yet. Pet and Sakura draws can drop them, and race trials can be bought with coins on the Shop's Units page.")
		TAB_ALL:
			return _t("背包是空的", "Your bag is empty")
	return _t("暂无物品", "Nothing here yet")


func _on_tile_input(event: InputEvent, key: String) -> void:
	var pressed := (event is InputEventMouseButton and event.pressed
		and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT) \
		or (event is InputEventScreenTouch and event.pressed)
	if pressed and key != _selected:
		_selected = key
		_refresh_selection()


# 只重新上色 + 重画详情，不重建格子（见文件头）。
func _refresh_selection() -> void:
	for key in _tiles:
		var tile = _tiles[key]
		if tile is PanelContainer and is_instance_valid(tile):
			var card := _card_by_key(str(key))
			var tint: Color = Card.DAY_TINT.get(int(card.get("days", 1)), Color.WHITE)
			(tile as PanelContainer).add_theme_stylebox_override("panel", Kit.box("slot",
				Vector4(10, 10, 10, 10), tint * PICK_TINT if key == _selected else tint))
	_render_detail(_card_by_key(_selected))


func _render_detail_hint(text: String) -> void:
	_clear_children(_detail)
	_clear_children(_actions)
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.y = 200
	label.add_theme_color_override("font_color", Kit.INK_SOFT)
	_detail.add_child(label)


func _render_detail_retry() -> void:
	_render_detail_hint(_t("网络不太好", "Connection problem"))
	_actions.add_child(_action(_t("重试", "Retry"), true, _reload))


func _render_detail(card: Dictionary) -> void:
	if card.is_empty():
		_render_detail_hint(_t("选中一件物品查看详情", "Select an item to see details"))
		return
	_clear_children(_detail)
	_clear_children(_actions)
	var kind := str(card.get("kind", ""))
	var target := str(card.get("target", ""))
	var days := int(card.get("days", 1))
	var count := int(card.get("count", 1))
	var owned := bool(card.get("owned", false))

	_detail.add_child(_text(_t("体验卡 · %s", "TRIAL CARD · %s") % Card.kind_name(kind),
		Tokens.FONT_CAPTION, SECTION_COLOR))
	var tile_holder := CenterContainer.new()
	var big := Card.tile(card, DETAIL_TILE)
	big.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile_holder.add_child(big)
	_detail.add_child(tile_holder)
	var title := _text(Card.card_title(kind, target, days), Tokens.FONT_BUTTON, Kit.INK)
	title.name = "BagDetailTitle"
	_detail.add_child(title)
	_detail.add_child(_text(_t("拥有 %d 张", "You have %d") % count, Tokens.FONT_CAPTION, Kit.INK_SOFT))
	_detail.add_child(HSeparator.new())
	_detail.add_child(_text(_effect_text(kind, days), Tokens.FONT_BODY, Kit.INK))
	if owned:
		_detail.add_child(_text(_t("你已经永久拥有它了，这张卡不能使用，可以出售。",
			"You already own this permanently. This card can't be used, but you can sell it."),
			Tokens.FONT_CAPTION, Color("a3271a")))
	elif _trials.has(target):
		_detail.add_child(_text(_t("正在体验中 · %s。再用一张会往后叠加。", "Trial active · %s. Using another extends it.")
			% Card.time_left(str(_trials[target]), _clock_offset), Tokens.FONT_CAPTION, SECTION_COLOR))
	_detail.add_child(_text(_t("出售价格：%s 游戏币 / 张", "Sells for %s coins each")
		% Currency.comma(int(card.get("sell_price", Card.PRICE.get(days, 0)))), Tokens.FONT_CAPTION, Kit.INK_SOFT))

	var sell := _action(_t("出售", "Sell"), false, _open_sell.bind(card))
	sell.name = "BagSell"
	_actions.add_child(sell)
	var use := _action(_t("已拥有", "Owned") if owned else _t("使用", "Use"), true, _use.bind(card))
	use.name = "BagUse"
	use.disabled = owned or _busy
	_actions.add_child(use)


func _effect_text(kind: String, days: int) -> String:
	match kind:
		"race":
			return _t("使用后 %d 天内可以带这一族出战（出战种族不满 4 个时自动带上，满了请到备战页更换）。",
				"For %d days you can take this race into battle (added automatically if you have fewer than 4; otherwise swap it in Prep).") % days
		"pet":
			return _t("使用后 %d 天内可以把这只宠物设为出战（在备战页更换）。",
				"For %d days you can set this pet as your active companion (in Prep).") % days
		"prep_skin":
			return _t("使用后 %d 天内可以使用这张棋盘皮肤（在备战页「棋盘皮肤」更换）。",
				"For %d days you can use this board skin (change it in Prep → Board skins).") % days
	return ""


func _text(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _action(text: String, primary: bool, cb: Callable) -> Button:
	var b: Button = ACTION_BUTTON.instantiate()
	b.text = text
	b.custom_minimum_size = Vector2(130, Tokens.BUTTON_HEIGHT)
	b.theme_type_variation = Theming.VARIATION_PRIMARY if primary else Theming.VARIATION_GHOST
	b.pressed.connect(cb)
	return b


func _select_tab(tab_id: String) -> void:
	if _active_tab == tab_id:
		return
	_active_tab = tab_id
	_render()


# --- 使用 / 出售 --------------------------------------------------------------

func _use(card: Dictionary) -> void:
	if _busy or bool(card.get("owned", false)):
		return
	var key := _key(card)
	var target := str(card.get("target", ""))
	var kind := str(card.get("kind", ""))
	var days := int(card.get("days", 1))
	_busy = true
	_render_detail(card)
	if not _pending_use.has(key):
		_pending_use[key] = AccountManager.new_client_order_id()
	var result: Dictionary = await AccountManager.use_trial_card(str(_pending_use[key]), target, days)
	if not is_inside_tree():
		return
	_busy = false
	var code := int(result.get("code", 0))
	if code / 100 != 2:
		# 断网 / 5xx：留着操作号，再点是重试同一笔（服务器只用一张卡）。
		if code != 0 and code < 500:
			_pending_use.erase(key)
		GloryToast.show_text(str(result.get("error", _t("使用失败", "Could not use it"))))
		_render_detail(card)
		return
	_pending_use.erase(key)
	var expires := str((result.get("body", {}) as Dictionary).get("expires_at", ""))
	GloryToast.show_text(_t("%s体验已生效，%s", "%s trial is active — %s") % [
		Card.target_name(kind, target), Card.time_left(expires, _clock_offset)])
	# 各自的缓存主人拉一次，备战页 / 摆放界面马上认得这次体验。
	if kind == "race":
		PlayerProfile.refresh_races()
	elif kind == "pet":
		PlayerProfile.refresh_pets()
	_reload()


func _open_sell(card: Dictionary) -> void:
	if _busy:
		return
	var dialog := SellDialog.new()
	dialog.configure(card)
	dialog.sold.connect(func(_body: Dictionary) -> void:
		if is_inside_tree():
			_reload())
	ModalStack.push(dialog, {"id": SellDialog.MODAL_ID, "owner": self, "dismiss_on_backdrop": true})


# --- 小工具 -------------------------------------------------------------------

func _clear_children(parent: Node) -> void:
	if parent == null:
		return
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()


func _t(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale().begins_with("en") else zh
