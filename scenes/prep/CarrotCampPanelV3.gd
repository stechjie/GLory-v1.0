extends PanelContainer

# 萝卜营地（11.11 羊皮纸风，照用户给的两张设计图重做）。
#
#   营地页：标题 + 萝卜钱包 + 关闭 → 「营地 / 升级石」页签 → 左「萝卜田」右「采集升级」两张内嵌卡
#           → 底部「下回合可收获 ｜ 持有金币」横条。
#   四星页（升级石页签进来）：左上「返回营地」、标题「四星升级」；左边抽石头一栏，右边两列棋子卡；
#           面板外左侧是「队伍共享」石头栏（attach_stone_rail，跟面板同一个中心）。
#
# 美术在 assets/ui/carrot_camp（这批图）+ assets/ui/unit_detail（星星、金币堆、升级按钮、手绘石头，
# 与棋子详情卡共用）。字体沿用详情卡的思源宋体 / 思源黑体（UnitDetailCard.font）。
# 玩法逻辑、回调、教学取值接口都没变；检查脚本读的 _tech_button / _tech_note / _draw_button /
# _carrot_balance / _stone_rail 名字保留。

const CarrotEconomy := preload("res://scripts/economy/CarrotEconomy.gd")
const Card := preload("res://ui/components/UnitDetailCard.gd")
const OrbitSparklesScript := preload("res://ui/components/OrbitSparkles.gd")
const NotifyBadgeScript := preload("res://ui/components/NotifyBadge.gd")
const PrepWidgets := preload("res://scenes/prep/PrepWidgets.gd")
const TEX_STONE_REVEAL: Texture2D = preload("res://assets/props/carrot_system/vfx/atlas_stone_reveal_4x4.png")
const ART := "res://assets/ui/carrot_camp/%s.png"
const UNIT_PORTRAIT_DIR := "res://assets/ui/unit_portraits"

const PANEL_SIZE := Vector2(940.0, 690.0)
# 颜色全部从设计图取样（11.11 用户：要很还原）
const INK := Color("3d1f0b")
const INK_SOFT := Color("7a4f2a")
const LINE := Color("cd9a57")
const PILL_FILL := Color("eecb96")      # 等级牌 / 提示牌 / 底部横条 / 钱包
const PILL_EDGE := Color("e3b97f")
const BOX_FILL := Color("f9dbad")       # 数值框（每回合产量那几行后面）
const BOX_EDGE := Color("e8c08c")
const ROW_LINE := Color("eecb9a")
# 内嵌卡底图偏白，设计图里是暖橙米色：整体乘一点暖色
const INSET_TINT := Color(1.0, 0.965, 0.9)
const WARN := Color("b5401f")

signal closed
# 切页签的事件。教学（9.25 萝卜 / 四星教学）靠它知道玩家现在在哪一页。
signal page_changed(index: int)

var _upgrade_callback: Callable
var _draw_callback: Callable
var _four_star_callback: Callable
var _camp_page: Control
var _stone_page: Control
var _tabs_row: Control
var _camp_tab: Button
var _stone_tab: Button
var _back_button: Button
var _title: Label
var _wallet: Control
var _carrot_balance: Label
var _farm_level: Label
var _farm_need: Label
var _farm_progress: Control
var _farm_next_capacity: Label
var _farm_next_production: Label
var _farm_next_income: Label
var _tech_level: Label
var _tech_current: Label
var _tech_next: Label
var _tech_note: Label
var _tech_button: Button
var _harvest_footer: Label
var _gold_footer: Label
var _draw_status: Label
var _draw_result: Label
var _draw_button: Button
var _stone_art: TextureRect
var _stone_reveal: TextureRect
var _stone_counts: Dictionary = {}
var _stone_icons: Dictionary = {}
# 「升级石」页签的两级提醒：有石头没能升的 —— 金点；有能升 4★ 的 —— 红底数字 + 金色光粒子。
var _stone_tab_orbit: Control
var _stone_tab_badge: Control
var _stone_rail: PanelContainer
var _four_star_list: GridContainer
var _last_stones := {"sky": 0, "land": 0, "ren": 0}
var _stones_initialized := false
var _reveal_serial := 0
var _action_locked := false
var _close_button: Button
var _current_page := 0
# 四星列表每张卡的「升级」按钮（每次 refresh 重建）。教学箭头要指着它。
var _four_star_buttons: Array[Button] = []


func setup(upgrade_callback: Callable, draw_callback: Callable,
		four_star_callback: Callable = Callable()) -> void:
	_upgrade_callback = upgrade_callback
	_draw_callback = draw_callback
	_four_star_callback = four_star_callback
	if not LocaleManager.locale_changed.is_connected(_on_locale_changed):
		LocaleManager.locale_changed.connect(_on_locale_changed)
	_build()


func _on_locale_changed(_locale: String) -> void:
	var selected_page := _current_page
	_reveal_serial += 1
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_camp_page = null
	_stone_page = null
	_stones_initialized = false
	_build()
	_show_page(selected_page)
	refresh()


# ============================================================ 搭建

func _build() -> void:
	if get_child_count() > 0:
		return
	custom_minimum_size = PANEL_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	var frame := Card.slice(ART % "panel_main", 0.7, Vector4(100, 100, 100, 100))
	# 设计图里面板底比这张图暖、亮一点
	frame.modulate_color = Color(1.04, 1.05, 1.05)
	frame.content_margin_left = 0
	frame.content_margin_right = 0
	frame.content_margin_top = 0
	frame.content_margin_bottom = 0
	add_theme_stylebox_override("panel", frame)
	# 关闭键要压在金框角上，不能放进容器里排版：外面套一层自由摆放的根节点
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 54)
	margin.add_theme_constant_override("margin_right", 54)
	margin.add_theme_constant_override("margin_top", 46)
	margin.add_theme_constant_override("margin_bottom", 58)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(margin)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	margin.add_child(body)
	_build_header(body)
	_build_tabs(body)
	var pages := Control.new()
	pages.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pages.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(pages)
	_camp_page = _build_camp_page()
	pages.add_child(_camp_page)
	_camp_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stone_page = _build_stone_page()
	pages.add_child(_stone_page)
	_stone_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 右上角圆形关闭键
	_close_button = _image_button("button_close", Vector2(58, 61))
	_close_button.tooltip_text = _t("关闭", "Close")
	_close_button.pressed.connect(_close)
	root.add_child(_close_button)
	_close_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_close_button.position = Vector2(PANEL_SIZE.x - 92, 30)
	_show_page(0)


# 队伍共享石头栏：面板的兄弟节点（PanelContainer 会把子节点撑满，栏得放在外面），
# 锚点跟面板同一个中心，摆在面板左边。只在四星页显示。
func attach_stone_rail(parent: Control) -> void:
	if _stone_rail != null and is_instance_valid(_stone_rail):
		return
	_stone_rail = PanelContainer.new()
	_stone_rail.name = "CarrotTeamStones"
	_stone_rail.anchor_left = 0.5
	_stone_rail.anchor_right = 0.5
	_stone_rail.anchor_top = 0.5
	_stone_rail.anchor_bottom = 0.5
	_stone_rail.offset_left = -PANEL_SIZE.x * 0.5 - 236
	_stone_rail.offset_right = -PANEL_SIZE.x * 0.5 - 6
	_stone_rail.offset_top = -250
	_stone_rail.offset_bottom = 250
	_stone_rail.z_index = 35
	_stone_rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rail_style := Card.slice(ART % "panel_inventory_rail", 0.72, Vector4(70, 70, 70, 70))
	rail_style.content_margin_left = 22
	rail_style.content_margin_right = 22
	rail_style.content_margin_top = 34
	rail_style.content_margin_bottom = 34
	_stone_rail.add_theme_stylebox_override("panel", rail_style)
	parent.add_child(_stone_rail)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 14)
	_stone_rail.add_child(column)
	column.add_child(_title_with_leaves(_t("队伍共享", "Team Stones"), 26))
	column.add_child(_diamond_rule())
	for stone_type in ["sky", "land", "ren"]:
		_add_stone_counter(column, stone_type)
	var rest := Control.new()
	rest.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rest.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(rest)
	visibility_changed.connect(_sync_stone_rail_visibility)
	_sync_stone_rail_visibility()
	refresh()


func _sync_stone_rail_visibility() -> void:
	if _stone_rail != null and is_instance_valid(_stone_rail):
		_stone_rail.visible = visible and _current_page == 1


func _build_header(parent: VBoxContainer) -> void:
	var header := Control.new()
	header.custom_minimum_size.y = 52
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(header)
	# 标题居中（两边各一枝叶子）
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(center)
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 14)
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(title_row)
	title_row.add_child(_leaf(36, true))
	_title = _text(_t("萝卜营地", "Carrot Camp"), 38, true, 900)
	title_row.add_child(_title)
	title_row.add_child(_leaf(36, false))
	# 左上：返回营地（只在四星页）
	_back_button = Button.new()
	_back_button.text = _t("返回营地", "Back to Camp")
	_back_button.custom_minimum_size = Vector2(176, 48)
	_texture_button(_back_button, "button_back", Vector4(140, 0, 60, 0), 48.0 / 125.0)
	_font(_back_button, true, 800, 20)
	(_back_button.get_theme_stylebox("normal") as StyleBoxTexture).content_margin_left = 40
	for state in ["hover", "pressed"]:
		(_back_button.get_theme_stylebox(state) as StyleBoxTexture).content_margin_left = 40
	_back_button.pressed.connect(_show_page.bind(0))
	header.add_child(_back_button)
	_back_button.position = Vector2(0, 2)
	# 右：萝卜钱包（给关闭键留出位置）
	# 钱包牌：照设计图取色 —— 暖褐底 #efc68a、金棕细边 #ce9c56、里面一道浅色细线
	_wallet = PanelContainer.new()
	var wallet_style := StyleBoxEmpty.new()
	wallet_style.content_margin_left = 16
	wallet_style.content_margin_right = 22
	_wallet.add_theme_stylebox_override("panel", wallet_style)
	_wallet.draw.connect(_draw_wallet_plate.bind(_wallet))
	_wallet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(_wallet)
	_wallet.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
	_wallet.offset_right = -60
	_wallet.offset_left = -270
	_wallet.offset_top = -16
	_wallet.offset_bottom = 28
	var wallet_row := HBoxContainer.new()
	wallet_row.alignment = BoxContainer.ALIGNMENT_CENTER
	wallet_row.add_theme_constant_override("separation", 10)
	wallet_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wallet.add_child(wallet_row)
	wallet_row.add_child(_icon(load(ART % "icon_carrot"), Vector2(32, 38)))
	_carrot_balance = _text(_t("萝卜：0 / 0", "Carrots: 0 / 0"), 20, false, 600)
	wallet_row.add_child(_carrot_balance)


# 两个页签（金色 = 当前页，米色 = 另一页），两边各拖一根金线
func _build_tabs(parent: VBoxContainer) -> void:
	var tabs := HBoxContainer.new()
	tabs.custom_minimum_size.y = 46
	tabs.alignment = BoxContainer.ALIGNMENT_CENTER
	tabs.add_theme_constant_override("separation", 10)
	parent.add_child(tabs)
	_tabs_row = tabs
	tabs.add_child(_gold_line(true))
	_camp_tab = Button.new()
	_camp_tab.text = _t("营地", "Camp")
	_camp_tab.custom_minimum_size = Vector2(230, 46)
	_camp_tab.pressed.connect(_show_page.bind(0))
	tabs.add_child(_camp_tab)
	_stone_tab = Button.new()
	_stone_tab.text = _t("升级石", "Upgrade Stones")
	_stone_tab.custom_minimum_size = Vector2(230, 46)
	_stone_tab.pressed.connect(_show_page.bind(1))
	tabs.add_child(_stone_tab)
	tabs.add_child(_gold_line(false))
	var orbit: Control = OrbitSparklesScript.new()
	orbit.name = "StoneTabOrbit"
	orbit.visible = false
	_stone_tab.add_child(orbit)
	_stone_tab_orbit = orbit
	var badge: Control = NotifyBadgeScript.new()
	badge.name = "StoneTabBadge"
	badge.visible = false
	_stone_tab.add_child(badge)
	_stone_tab_badge = badge


func _build_camp_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)
	page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cards := HBoxContainer.new()
	cards.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cards.add_theme_constant_override("separation", 16)
	page.add_child(cards)

	# ---- 左：萝卜田 ----
	var farm := _inset_column(cards)
	farm.add_child(_title_with_leaves(_t("萝卜田", "Carrot Field"), 26))
	farm.add_child(_icon(load(ART % "carrot_field"), Vector2(0, 112)))
	var level_row := HBoxContainer.new()
	level_row.add_theme_constant_override("separation", 10)
	farm.add_child(level_row)
	var level_pill := PanelContainer.new()
	level_pill.add_theme_stylebox_override("panel", _pill_style(16, 3))
	level_row.add_child(level_pill)
	_farm_level = _text(_t("营地等级：1", "Camp Lv. 1"), 19, true, 800)
	level_pill.add_child(_farm_level)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	level_row.add_child(gap)
	_farm_need = _text(_t("距离下一级：0", "To next: 0"), 18, true, 800)
	_farm_need.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	level_row.add_child(_farm_need)
	_farm_progress = CampProgress.new()
	_farm_progress.custom_minimum_size.y = 22
	farm.add_child(_farm_progress)
	var rows := _value_box(farm)
	_farm_next_capacity = _value_row(rows, load(ART % "harvest_basket"), _t("下级容量", "Next Capacity"), true)
	_farm_next_production = _value_row(rows, load(ART % "icon_carrot"), _t("每回合产量", "Yield / Round"), true)
	_farm_next_income = _value_row(rows, Card.art("icon_gold_stack"), _t("营地金币收益", "Camp Gold / Battle"), false)
	var hint := PanelContainer.new()
	hint.add_theme_stylebox_override("panel", _pill_style(16, 3))
	farm.add_child(hint)
	var hint_row := HBoxContainer.new()
	hint_row.alignment = BoxContainer.ALIGNMENT_CENTER
	hint_row.add_theme_constant_override("separation", 8)
	hint.add_child(hint_row)
	hint_row.add_child(_leaf(20, true))
	var hint_text := _text(_t("雇佣佣兵消耗萝卜可使营地成长。", "Spend carrots on mercenaries to grow the camp."), 17, true, 800)
	hint_row.add_child(hint_text)

	# ---- 右：采集升级 ----
	var tech := _inset_column(cards)
	tech.add_child(_title_with_leaves(_t("采集升级", "Harvest Upgrade"), 26))
	tech.add_child(_icon(load(ART % "harvest_basket"), Vector2(0, 118)))
	var tech_pill_row := CenterContainer.new()
	tech.add_child(tech_pill_row)
	var tech_pill := PanelContainer.new()
	tech_pill.add_theme_stylebox_override("panel", _pill_style(22, 3))
	tech_pill_row.add_child(tech_pill)
	_tech_level = _text(_t("采集等级：1", "Harvest Lv. 1"), 19, true, 800)
	tech_pill.add_child(_tech_level)
	var tech_rows := _value_box(tech)
	_tech_current = _value_row(tech_rows, load(ART % "icon_carrot"), _t("当前产量", "Current Yield"), true)
	_tech_next = _value_row(tech_rows, load(ART % "icon_harvest_upgrade"), _t("下一级产量", "Next Level Yield"), false)
	var tech_spacer := Control.new()
	tech_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tech.add_child(tech_spacer)
	_tech_button = _gold_button(_t("升级采集", "Upgrade Harvest"), Vector2(300, 62), 25)
	_tech_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_tech_button.pressed.connect(_on_upgrade)
	tech.add_child(_tech_button)
	_tech_note = _text(_t("升级后，下回合生效", "Takes effect next round"), 17, true, 700)
	_tech_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tech.add_child(_tech_note)

	# ---- 底部：下回合可收获 ｜ 持有金币 ----
	# 两端留出空，叶子别压到金框四角的装饰上
	var footer_margin := MarginContainer.new()
	footer_margin.add_theme_constant_override("margin_left", 22)
	footer_margin.add_theme_constant_override("margin_right", 22)
	page.add_child(footer_margin)
	var footer_line := HBoxContainer.new()
	footer_line.add_theme_constant_override("separation", 8)
	footer_margin.add_child(footer_line)
	footer_line.add_child(_leaf(30, true))
	var footer := PanelContainer.new()
	footer.add_theme_stylebox_override("panel", _pill_style(30, 3))
	footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer_line.add_child(footer)
	footer_line.add_child(_leaf(30, false))
	var footer_row := HBoxContainer.new()
	footer_row.alignment = BoxContainer.ALIGNMENT_CENTER
	footer_row.add_theme_constant_override("separation", 12)
	footer.add_child(footer_row)
	footer_row.add_child(_icon(load(ART % "icon_carrot"), Vector2(44, 46)))
	_harvest_footer = _text(_t("下回合可收获：0", "Next harvest: 0"), 21, true, 800)
	footer_row.add_child(_harvest_footer)
	var bar := ColorRect.new()
	bar.color = LINE
	bar.custom_minimum_size = Vector2(2, 30)
	footer_row.add_child(_spaced(bar, 30))
	footer_row.add_child(_icon(Card.art("icon_gold_stack"), Vector2(44, 44)))
	_gold_footer = _text(_t("持有金币：0", "Gold: 0"), 21, true, 800)
	footer_row.add_child(_gold_footer)
	return page


func _build_stone_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)
	page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cards := HBoxContainer.new()
	cards.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cards.add_theme_constant_override("separation", 14)
	page.add_child(cards)

	# ---- 左：抽升级石 ----
	var draw_card := PanelContainer.new()
	draw_card.add_theme_stylebox_override("panel", _inset_style())
	draw_card.custom_minimum_size.x = 200
	cards.add_child(draw_card)
	var draw := VBoxContainer.new()
	draw.alignment = BoxContainer.ALIGNMENT_CENTER
	draw.add_theme_constant_override("separation", 10)
	draw_card.add_child(draw)
	var art_stack := Control.new()
	art_stack.custom_minimum_size = Vector2(160, 170)
	draw.add_child(art_stack)
	var glow := StoneGlow.new()
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	art_stack.add_child(glow)
	_stone_art = _icon(Card.stone_texture(""), Vector2.ZERO)
	art_stack.add_child(_stone_art)
	_stone_art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stone_art.offset_left = 18
	_stone_art.offset_right = -18
	_stone_art.offset_top = 8
	_stone_art.offset_bottom = -8
	_stone_reveal = _icon(TEX_STONE_REVEAL, Vector2.ZERO)
	_stone_reveal.visible = false
	art_stack.add_child(_stone_reveal)
	_stone_reveal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var status_pill := PanelContainer.new()
	status_pill.add_theme_stylebox_override("panel", _pill_style(14, 3))
	status_pill.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	draw.add_child(status_pill)
	_draw_status = _text(_t("剩余次数：1", "Draws left: 1"), 18, true, 800)
	_draw_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_pill.add_child(_draw_status)
	_draw_result = _text("", 14, false, 500)
	_draw_result.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_draw_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_draw_result.custom_minimum_size = Vector2(170, 40)
	_draw_result.add_theme_color_override("font_color", INK_SOFT)
	draw.add_child(_draw_result)
	_draw_button = _gold_button(_t("抽取一次", "Draw Once"), Vector2(180, 54), 22)
	_draw_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_draw_button.pressed.connect(_on_draw)
	draw.add_child(_draw_button)
	draw.add_child(_diamond_rule())

	# ---- 右：可升四星的棋子（两列，可滚动） ----
	var list_card := PanelContainer.new()
	list_card.add_theme_stylebox_override("panel", _inset_style())
	list_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards.add_child(list_card)
	var scroll := preload("res://ui/components/TouchScrollContainer.gd").new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	# 手势区 = 整张列表卡：按在卡上任何地方上下滑都能滚，轻点照常落到子控件。
	scroll.set_drag_zone(func() -> Control: return list_card)
	list_card.add_child(scroll)
	_four_star_list = GridContainer.new()
	_four_star_list.columns = 2
	_four_star_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_four_star_list.add_theme_constant_override("h_separation", 10)
	_four_star_list.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_four_star_list)

	# ---- 底部说明 ----
	var foot := HBoxContainer.new()
	foot.alignment = BoxContainer.ALIGNMENT_CENTER
	foot.add_theme_constant_override("separation", 10)
	page.add_child(foot)
	foot.add_child(_gold_line(true))
	foot.add_child(_leaf(22, true))
	foot.add_child(_text(_t("升级需消耗对应升级石和金币。", "Upgrading costs the matching stone and gold."), 18, true, 800))
	foot.add_child(_leaf(22, false))
	foot.add_child(_gold_line(false))
	return page


func _show_page(index: int) -> void:
	if _camp_page == null:
		return
	_camp_page.visible = index == 0
	_stone_page.visible = index == 1
	_set_tab(_camp_tab, index == 0)
	_set_tab(_stone_tab, index == 1)
	# 四星页：没有页签，左上换成「返回营地」，标题换成「四星升级」，钱包收起
	_tabs_row.visible = index == 0
	_back_button.visible = index == 1
	_wallet.visible = index == 0
	_title.text = _t("四星升级", "4-Star Upgrade") if index == 1 else _t("萝卜营地", "Carrot Camp")
	_current_page = index
	_sync_stone_rail_visibility()
	page_changed.emit(index)


func current_page() -> int:
	return _current_page


# --- 教学取值（9.25）：只读暴露控件，给 PrepUI 的教学目标适配层用 -------------------

func tutorial_close_button() -> Control:
	return _close_button


# 四星页没有页签，回营地的入口是左上的「返回营地」
func tutorial_camp_tab() -> Control:
	return _back_button if _current_page == 1 else _camp_tab


func tutorial_stone_tab() -> Control:
	return _stone_tab


func tutorial_harvest_button() -> Control:
	return _tech_button


func tutorial_draw_button() -> Control:
	return _draw_button


# 第一枚可点的「升级」；一枚都不可点时退回第一枚，列表为空时退回列表容器。
func tutorial_four_star_target() -> Control:
	for button in _four_star_buttons:
		if is_instance_valid(button) and not button.disabled:
			return button
	for button in _four_star_buttons:
		if is_instance_valid(button):
			return button
	return _four_star_list


# 教学里某个萝卜操作此刻是否放行。非教学恒为 true。
func _tutorial_allows(action: String) -> bool:
	return not GameState.tutorial_mode or TutorialMode.allows_carrot_action(action)


# ============================================================ 刷新

func refresh() -> void:
	if _carrot_balance == null:
		return
	var capacity := GameState.carrot_capacity()
	var production := GameState.carrot_production()
	var preview := GameState.carrot_harvest_preview()
	var actual_gain := int(preview.get("gain", 0))
	var overflow := int(preview.get("overflow", 0))
	_carrot_balance.text = _t("萝卜：%d / %d", "Carrots: %d / %d") % [GameState.carrots, capacity]
	var level := GameState.carrot_farm_level()
	_farm_level.text = _t("营地等级：%d", "Camp Lv. %d") % (level + 1)
	var current_threshold := CarrotEconomy.farm_threshold_for_level(level)
	var next_level := level + 1
	var next_threshold := CarrotEconomy.farm_threshold_for_level(next_level)
	var spent_in_level := GameState.merc_carrots_spent_total - current_threshold
	var segment := maxi(1, next_threshold - current_threshold)
	_farm_progress.set("ratio", clampf(float(spent_in_level) / float(segment), 0.0, 1.0))
	_farm_need.text = _t("距离下一级：%d", "To next: %d") % maxi(0, next_threshold - GameState.merc_carrots_spent_total)
	_farm_need.tooltip_text = _t("再消耗 %d 萝卜雇佣佣兵，营地升到 %d 级", "Spend %d more carrots on mercenaries to reach Lv. %d") \
		% [maxi(0, next_threshold - GameState.merc_carrots_spent_total), next_level + 1]
	_farm_next_capacity.text = "%d → %d" % [capacity,
		CarrotEconomy.capacity_for_spent(next_threshold,
			PetService.carrot_bonus_rate(PlayerProfile.get_active()))]
	_farm_next_production.text = "%d → %d" % [production, CarrotEconomy.total_production(
		GameState.harvest_tech_level, next_threshold,
		PetService.carrot_bonus_rate(PlayerProfile.get_active()))]
	_farm_next_income.text = "%d → %d" % [GameState.carrot_camp_income(), CarrotEconomy.farm_income_for_level(next_level)]

	var tech_level := GameState.harvest_tech_level
	var price := CarrotEconomy.tech_price(tech_level)
	var tech_production := CarrotEconomy.production_for_tech(tech_level)
	var next_production := CarrotEconomy.production_for_tech(tech_level + 1)
	var farm_bonus := CarrotEconomy.farm_production_bonus(GameState.merc_carrots_spent_total)
	_tech_level.text = _t("采集等级：%d", "Harvest Lv. %d") % (tech_level + 1)
	_tech_current.text = str(tech_production)
	_tech_next.text = str(next_production)
	_tech_button.text = _t("升级采集 · %d金", "Upgrade · %d G") % price
	var online_blocked := NetworkService.team_active and not NetworkService.is_host and not NetworkService.carrot_economy_enabled()
	# 教学（9.25）：不受「第 2 回合才解锁」限制，但只在箭头指着它的那一步可点。
	var tech_round_locked := GameState.round_index < 2 and not GameState.tutorial_mode
	var tech_tutorial_locked := not _tutorial_allows("harvest_upgrade")
	_tech_button.disabled = tech_round_locked or tech_tutorial_locked or _action_locked or GameState.gold < price or online_blocked
	_tech_note.add_theme_color_override("font_color", INK)
	# 教学里采集科技有上限（TutorialMode.TUTORIAL_HARVEST_MAX），到顶后显示「已满」。
	var tutorial_maxed := GameState.tutorial_mode and TutorialMode.harvest_maxed()
	if tutorial_maxed:
		_tech_button.text = _t("已满", "Maxed")
		_tech_next.text = str(tech_production)
		_tech_note.text = _t("采集等级已满", "Harvest level maxed")
	elif tech_round_locked:
		_tech_note.text = _t("下一回合解锁升级", "Unlocks next round")
	elif GameState.gold < price:
		_tech_note.text = _t("金币不足 · 还差 %d", "Not enough gold · need %d") % (price - GameState.gold)
		_tech_note.add_theme_color_override("font_color", WARN)
	elif online_blocked:
		_tech_note.text = _t("等待房主开启联机萝卜系统", "Waiting for host to enable Carrot Camp")
	else:
		_tech_note.text = _t("农田额外 +%d · 升级下回合生效", "Field bonus +%d · next round") % farm_bonus if farm_bonus > 0 else _t("升级后，下回合生效", "Takes effect next round")
	_harvest_footer.text = _t("下回合可收获：%d%s", "Next harvest: %d%s") % [actual_gain, _t("（容量将满）", " (near capacity)") if overflow > 0 else ""]
	_harvest_footer.add_theme_color_override("font_color", WARN if overflow > 0 else INK)
	_gold_footer.text = _t("持有金币：%d", "Gold: %d") % GameState.gold
	_place_leaves(_tech_button)

	var draw_available := GameState.can_draw_upgrade_stone(GameState.round_index)
	var stone_cost := GameState.upgrade_stone_draw_cost()
	# 教学（9.25）：送的萝卜可以超过容量，抽石头不看容量门槛；但只在抽石头那一步可点。
	var unlocked := capacity >= stone_cost or (GameState.tutorial_mode and TutorialMode.scripted_stone_draw())
	var draw_tutorial_locked := not _tutorial_allows("draw_stone")
	_draw_status.text = _t("剩余次数：%d", "Draws left: %d") % (1 if draw_available else 0)
	_draw_button.text = (_t("免费抽取", "Free Draw") if stone_cost == 0 else _t("抽取 · %d萝卜", "Draw · %d") % stone_cost) if draw_available else _t("下回合恢复", "Next round")
	_draw_button.disabled = _action_locked or draw_tutorial_locked or not draw_available or not unlocked or GameState.carrots < stone_cost or online_blocked
	_place_leaves(_draw_button)
	if not unlocked:
		_draw_result.text = _t("容量不足 · 需要储存 %d 萝卜", "Capacity too low · store %d carrots") % stone_cost
	elif GameState.carrots < stone_cost and draw_available:
		_draw_result.text = _t("萝卜不足 · 还差 %d", "Not enough carrots · need %d") % (stone_cost - GameState.carrots)
	elif draw_available and _stone_art.texture == Card.stone_texture(""):
		_draw_result.text = _t("随机获得天、地、人石之一", "Get a random Sky, Land or Ren stone")
	elif not draw_available and _stone_art.texture == Card.stone_texture(""):
		_draw_result.text = _t("本回合已抽取", "Already drawn this round")
	var changed := ""
	for stone_type in CarrotEconomy.STONE_TYPES:
		var count := int(GameState.team_upgrade_stones.get(stone_type, 0))
		var count_label := _stone_counts.get(stone_type) as Label
		if count_label != null:
			count_label.text = _t("%s石 × %d", "%s × %d") % [_stone_display(stone_type), count]
		# 有存货的格子图标与数字正常色，没货的压暗
		var has_stock := count > 0
		var stone_icon := _stone_icons.get(stone_type) as TextureRect
		if stone_icon != null and is_instance_valid(stone_icon):
			stone_icon.modulate = Color.WHITE if has_stock else Color(0.72, 0.68, 0.62)
		if count_label != null:
			count_label.add_theme_color_override("font_color", INK if has_stock else INK_SOFT)
		if _stones_initialized and count > int(_last_stones.get(stone_type, 0)):
			changed = stone_type
		_last_stones[stone_type] = count
	if _stones_initialized and not changed.is_empty() and visible:
		_play_stone_reveal(changed)
	_stones_initialized = true
	_refresh_four_star_list()
	_refresh_stone_tab_hint()


# 页签上的两级提醒。数量取「现在真能升 4★ 的三星棋子有几枚」，判据走
# GameState.four_star_check —— 和棋盘上的「可升」光幕、营地入口角标同一口径。
func _refresh_stone_tab_hint() -> void:
	if _stone_tab == null or not is_instance_valid(_stone_tab):
		return
	var ready_count := 0
	for slots in [GameState.board_slots, GameState.bench_slots]:
		for cell in (slots as Array):
			if cell is Dictionary and bool(GameState.four_star_check(cell).get("ok", false)):
				ready_count += 1
	var stone_total := 0
	for value in GameState.team_upgrade_stones.values():
		stone_total += int(value)
	if _stone_tab_orbit != null and is_instance_valid(_stone_tab_orbit):
		_stone_tab_orbit.visible = ready_count > 0
	if _stone_tab_badge == null or not is_instance_valid(_stone_tab_badge):
		return
	if ready_count > 0:
		_stone_tab_badge.visible = true
		_stone_tab_badge.call("show_count", ready_count)
	elif stone_total > 0:
		_stone_tab_badge.visible = true
		_stone_tab_badge.call("show_dot")
	else:
		_stone_tab_badge.visible = false


func _refresh_four_star_list() -> void:
	if _four_star_list == null:
		return
	for child in _four_star_list.get_children():
		_four_star_list.remove_child(child)
		child.queue_free()
	_four_star_buttons.clear()
	var candidates: Array[Dictionary] = []
	for source in [["board", GameState.board_slots], ["bench", GameState.bench_slots]]:
		var where := str(source[0])
		var slots: Array = source[1]
		for index in slots.size():
			var cell: Variant = slots[index]
			if typeof(cell) != TYPE_DICTIONARY or int((cell as Dictionary).get("star", 1)) != GameState.MAX_MERGE_STAR:
				continue
			var check := GameState.four_star_check(cell)
			candidates.append({"where": where, "index": index, "cell": cell, "check": check,
				"ready": bool(check.get("ok", false)), "order": candidates.size()})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if bool(a.ready) != bool(b.ready):
			return bool(a.ready)
		return int(a.order) < int(b.order))
	_four_star_list.columns = 2 if not candidates.is_empty() else 1
	for candidate in candidates:
		_four_star_list.add_child(_four_star_card(candidate))
	if candidates.is_empty():
		var empty := VBoxContainer.new()
		empty.alignment = BoxContainer.ALIGNMENT_CENTER
		empty.custom_minimum_size = Vector2(0, 360)
		empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		empty.add_theme_constant_override("separation", 8)
		_four_star_list.add_child(empty)
		var title := _text(_t("暂无三星棋子", "No 3-Star Units"), 24, true, 900)
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_child(title)
		var hint := _text(_t("合成三星棋子后，可在这里使用对应升级石", "Merge a 3-star unit to use its matching stone here"), 17, false, 500)
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint.add_theme_color_override("font_color", INK_SOFT)
		empty.add_child(hint)


# 一张棋子卡：头像 | 名字、三星、需要的石头、金币、升级按钮（不能升时下面写原因）
func _four_star_card(candidate: Dictionary) -> Control:
	var cell: Dictionary = candidate.cell
	var check: Dictionary = candidate.check
	var unit_def: Dictionary = cell.get("def", {})
	var stone_type := str(check.get("stone", unit_def.get("element", "")))
	var ready := bool(candidate.ready)
	var card := PanelContainer.new()
	var style := _inset_style()
	style.content_margin_left = 10
	style.content_margin_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	card.add_theme_stylebox_override("panel", style)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	card.add_child(row)
	# 头像：深色圆角底 + 金边
	var frame := Panel.new()
	var frame_style := StyleBoxFlat.new()
	frame_style.bg_color = Color("1f2a3a")
	frame_style.border_color = Color("d4a24a")
	frame_style.set_border_width_all(3)
	frame_style.set_corner_radius_all(10)
	frame.add_theme_stylebox_override("panel", frame_style)
	frame.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	frame.custom_minimum_size = Vector2(118, 150)
	row.add_child(frame)
	var portrait := _icon(_unit_portrait(unit_def, stone_type), Vector2.ZERO)
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	frame.add_child(portrait)
	portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 3)
	row.add_child(info)
	# 棋子名走统一的本地化取法（英文界面下要显示 name_en）
	var unit_name := PrepWidgets.unit_name(unit_def) if not unit_def.is_empty() else _t("棋子", "Unit")
	var name_label := _text(unit_name, 22, true, 900)
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(name_label)
	var stars := HBoxContainer.new()
	stars.add_theme_constant_override("separation", 1)
	for i in 3:
		stars.add_child(_icon(Card.art("star_on"), Vector2(22, 22)))
	info.add_child(stars)
	var rule := ColorRect.new()
	rule.color = LINE
	rule.custom_minimum_size.y = 1
	info.add_child(rule)
	var stone_row := HBoxContainer.new()
	stone_row.add_theme_constant_override("separation", 6)
	stone_row.add_child(_icon(Card.stone_texture(stone_type), Vector2(34, 34)))
	var stone_text := _text(_t("%s石 × 1", "%s × 1") % _stone_display(stone_type), 18, true, 800)
	if not ready and str(check.get("error", "")) == "no_stone":
		stone_text.add_theme_color_override("font_color", WARN)
	stone_row.add_child(stone_text)
	info.add_child(stone_row)
	var gold_row := HBoxContainer.new()
	gold_row.add_theme_constant_override("separation", 6)
	gold_row.add_child(_icon(Card.art("icon_gold_stack"), Vector2(32, 30)))
	var gold_text := _text(_t("金币：%d", "Gold: %d") % CarrotEconomy.four_star_gold(int(unit_def.get("tier", 0))), 18, true, 800)
	if not ready and str(check.get("error", "")) == "not_enough_gold":
		gold_text.add_theme_color_override("font_color", WARN)
	gold_row.add_child(gold_text)
	info.add_child(gold_row)
	var action := _gold_button(_t("升级", "Upgrade"), Vector2(0, 40), 20)
	action.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action.disabled = _action_locked or not ready or not NetworkService.four_star_upgrade_available() \
		or not NetworkService.four_star_request_id.is_empty() or not _tutorial_allows("four_star")
	action.pressed.connect(_on_four_star.bind(str(candidate.where), int(candidate.index)))
	info.add_child(action)
	_four_star_buttons.append(action)
	if not ready:
		var reason := _text(_four_star_reason(str(check.get("error", "")), stone_type), 14, true, 700)
		reason.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		reason.add_theme_color_override("font_color", INK_SOFT)
		info.add_child(reason)
	else:
		action.tooltip_text = _four_star_gain_text(unit_def)
	return card


func _add_stone_counter(parent: VBoxContainer, stone_type: String) -> void:
	var box := PanelContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := _inset_style()
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	box.add_theme_stylebox_override("panel", style)
	parent.add_child(box)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(row)
	var stone_icon := _icon(Card.stone_texture(stone_type), Vector2(66, 70))
	row.add_child(stone_icon)
	_stone_icons[stone_type] = stone_icon
	var count := _text(_t("%s石 × 0", "%s × 0") % _stone_display(stone_type), 22, true, 900)
	count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(count)
	_stone_counts[stone_type] = count


func _play_stone_reveal(stone_type: String) -> void:
	_reveal_serial += 1
	var serial := _reveal_serial
	var frames := AtlasTexture.new()
	frames.atlas = TEX_STONE_REVEAL
	_stone_reveal.texture = frames
	_stone_reveal.visible = true
	_draw_result.text = _t("正在揭晓……", "Revealing...")
	for frame in range(16):
		if serial != _reveal_serial or not is_instance_valid(_stone_reveal):
			return
		frames.region = Rect2((frame % 4) * 256, (frame / 4) * 256, 256, 256)
		await get_tree().create_timer(0.055).timeout
	# 最后一次 await 期间切场景（备战被释放）就会在已销毁的节点上写属性，引擎报错会让检查变红
	if serial != _reveal_serial or not is_instance_valid(_stone_reveal) \
			or not is_instance_valid(_stone_art) or not is_instance_valid(_draw_result):
		return
	_stone_reveal.visible = false
	_stone_art.texture = Card.stone_texture(stone_type)
	_draw_result.text = _t("获得 %s石 ×1 · 已存入队伍库存", "Got %s Stone ×1 · added to team") % _stone_display(stone_type)


func _on_upgrade() -> void:
	if _action_locked or not _upgrade_callback.is_valid():
		return
	_action_locked = true
	_upgrade_callback.call()
	_action_locked = false
	refresh()


func _on_draw() -> void:
	if _action_locked or not _draw_callback.is_valid():
		return
	_action_locked = true
	_draw_callback.call()
	_action_locked = false
	refresh()


func _on_four_star(where: String, index: int) -> void:
	if _action_locked or not _four_star_callback.is_valid():
		return
	_action_locked = true
	_four_star_callback.call(where, index)
	_action_locked = false
	refresh()


func toggle() -> void:
	visible = not visible
	if visible:
		refresh()


func _close() -> void:
	visible = false
	closed.emit()


# ============================================================ 小部件

func _inset_style() -> StyleBoxTexture:
	var s := Card.slice(ART % "panel_inset", 0.4, Vector4(64, 64, 64, 64))
	s.modulate_color = INSET_TINT
	s.content_margin_left = 18
	s.content_margin_right = 18
	s.content_margin_top = 12
	s.content_margin_bottom = 14
	return s


func _inset_column(parent: Control) -> VBoxContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _inset_style())
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(card)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	card.add_child(column)
	return column


# 米色圆角小牌（等级、钱包、提示、底部横条）
func _pill_style(h_pad: float, v_pad: float) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = PILL_FILL
	s.border_color = PILL_EDGE
	s.set_border_width_all(2)
	s.set_corner_radius_all(20)
	s.content_margin_left = h_pad
	s.content_margin_right = h_pad
	s.content_margin_top = v_pad
	s.content_margin_bottom = v_pad
	return s


# 数值框：浅底圆角框，行与行之间一道细线
func _value_box(parent: VBoxContainer) -> VBoxContainer:
	var box := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = BOX_FILL
	s.border_color = BOX_EDGE
	s.set_border_width_all(2)
	s.set_corner_radius_all(12)
	s.content_margin_left = 14
	s.content_margin_right = 16
	s.content_margin_top = 4
	s.content_margin_bottom = 4
	box.add_theme_stylebox_override("panel", s)
	parent.add_child(box)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 0)
	box.add_child(rows)
	return rows


func _value_row(parent: VBoxContainer, icon: Texture2D, name: String, divider_after: bool) -> Label:
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = 35
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)
	row.add_child(_icon(icon, Vector2(40, 38)))
	var key := _text(name, 19, true, 800)
	key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	key.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(key)
	var value := _text("-", 19, true, 800)
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(value)
	if divider_after:
		var line := ColorRect.new()
		line.color = ROW_LINE
		line.custom_minimum_size.y = 1
		parent.add_child(line)
	return value


func _title_with_leaves(text: String, size: int) -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_leaf(size - 4, true))
	row.add_child(_text(text, size, true, 900))
	row.add_child(_leaf(size - 4, false))
	return row


# 叶子小枝（从详情卡的花边上截下来的那一枝）。左边那枝水平翻转，两边对称朝外
func _leaf(side: float, left: bool) -> TextureRect:
	var r := _icon(load(ART % "leaf"), Vector2(side, side))
	r.flip_h = left
	return r


# 页签 / 底部说明两边的金线：靠里那头粗，往外渐隐
func _gold_line(left: bool) -> Control:
	var line := GoldLine.new()
	line.fade_left = left
	line.custom_minimum_size = Vector2(60, 20)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return line


# 一道细线中间一颗小菱形
func _diamond_rule() -> Control:
	var rule := DiamondRule.new()
	rule.custom_minimum_size = Vector2(120, 14)
	return rule


func _spaced(node: Control, width: float) -> Control:
	var holder := CenterContainer.new()
	holder.custom_minimum_size.x = width
	holder.add_child(node)
	return holder


func _gold_button(text: String, min_size: Vector2, font_size: int) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	var k := min_size.y / 190.0
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for state in ["normal", "hover", "pressed", "disabled"]:
		var sb := Card.slice(Card.ART % ("upgrade_button_off" if state == "disabled" else "upgrade_button_on"),
			k, Vector4(115, 0, 115, 0))
		if state == "hover":
			sb.modulate_color = Color(1.06, 1.05, 1.0)
		elif state == "pressed":
			sb.modulate_color = Color(0.9, 0.87, 0.8)
		b.add_theme_stylebox_override(state, sb)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_font(b, true, 900, font_size)
	b.add_theme_color_override("font_color", Color("4a2608"))
	b.add_theme_color_override("font_hover_color", Color("4a2608"))
	b.add_theme_color_override("font_pressed_color", Color("4a2608"))
	b.add_theme_color_override("font_disabled_color", Color("5c4a3a"))
	return b


func _draw_wallet_plate(plate: Control) -> void:
	var r := Rect2(Vector2.ZERO, plate.size)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color("efc68a")
	fill.border_color = Color("ce9c56")
	fill.set_border_width_all(2)
	fill.set_corner_radius_all(int(r.size.y * 0.42))
	fill.anti_aliasing = true
	plate.draw_style_box(fill, r)
	var inner := StyleBoxFlat.new()
	inner.draw_center = false
	inner.border_color = Color(1.0, 0.88, 0.66, 0.85)
	inner.set_border_width_all(1)
	inner.set_corner_radius_all(int(r.size.y * 0.36))
	inner.anti_aliasing = true
	plate.draw_style_box(inner, r.grow(-4))


# 设计图里金色按钮 / 选中页签的字两边各有一枝深一点的叶子。按当前文字宽度摆，改字后要再调一次。
func _place_leaves(button: Button, show := true) -> void:
	if button == null:
		return
	var font := button.get_theme_font("font")
	var font_size := button.get_theme_font_size("font_size")
	var half := (font.get_string_size(button.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x if font != null else 60.0) * 0.5
	var leaf_size := font_size * 0.9
	for side in ["LeafL", "LeafR"]:
		var leaf := button.get_node_or_null(side) as TextureRect
		if leaf == null:
			leaf = _icon(load(ART % "leaf"), Vector2(leaf_size, leaf_size))
			leaf.name = side
			leaf.flip_h = side == "LeafL"
			leaf.modulate = Color(0.62, 0.42, 0.18)
			button.add_child(leaf)
			leaf.anchor_left = 0.5
			leaf.anchor_right = 0.5
			leaf.anchor_top = 0.5
			leaf.anchor_bottom = 0.5
		leaf.visible = show
		var x := -half - 10.0 - leaf_size if side == "LeafL" else half + 10.0
		leaf.offset_left = x
		leaf.offset_right = x + leaf_size
		leaf.offset_top = -leaf_size * 0.5
		leaf.offset_bottom = leaf_size * 0.5


func _image_button(piece: String, size: Vector2) -> Button:
	var b := Button.new()
	b.custom_minimum_size = size
	b.size = size
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for state in ["normal", "hover", "pressed"]:
		var sb := StyleBoxTexture.new()
		sb.texture = load(ART % piece)
		if state == "hover":
			sb.modulate_color = Color(1.07, 1.06, 1.0)
		elif state == "pressed":
			sb.modulate_color = Color(0.88, 0.85, 0.78)
		b.add_theme_stylebox_override(state, sb)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b


func _texture_button(b: Button, piece: String, margins: Vector4, k: float) -> void:
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for state in ["normal", "hover", "pressed", "disabled"]:
		var sb := Card.slice(ART % piece, k, margins)
		if state == "hover":
			sb.modulate_color = Color(1.06, 1.05, 1.0)
		elif state == "pressed":
			sb.modulate_color = Color(0.9, 0.87, 0.8)
		b.add_theme_stylebox_override(state, sb)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


# 页签：当前页金色底，另一页米色底；字都是深棕宋体
func _set_tab(button: Button, selected: bool) -> void:
	if button == null:
		return
	_texture_button(button, "tab_selected" if selected else "tab_unselected", Vector4(52, 0, 52, 0), 46.0 / 105.0)
	_font(button, true, 900, 24)
	button.add_theme_color_override("font_color", INK if selected else INK_SOFT)
	_place_leaves(button, selected)


func _font(c: Control, serif: bool, weight: int, size: int) -> void:
	c.add_theme_font_override("font", Card.font(false, weight))
	c.add_theme_font_size_override("font_size", size)
	c.add_theme_color_override("font_color", INK)
	c.add_theme_color_override("font_hover_color", INK)
	c.add_theme_color_override("font_pressed_color", INK)
	c.add_theme_color_override("font_disabled_color", INK_SOFT)
	c.add_theme_constant_override("outline_size", 0)


func _text(value: String, size: int, serif: bool, weight: int) -> Label:
	var l := Label.new()
	l.text = value
	_font(l, serif, weight, size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _t(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale().begins_with("en") else zh


func _icon(texture: Texture2D, minimum: Vector2) -> TextureRect:
	var result := TextureRect.new()
	result.texture = texture
	result.custom_minimum_size = minimum
	result.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	result.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	result.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	result.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return result


func _stone_display(stone_type: String) -> String:
	match stone_type:
		"sky": return _t("天", "Sky")
		"land": return _t("地", "Land")
		"ren": return _t("人", "Ren")
		_: return "?"


# 棋子头像；没有这张图就退回该属性的石头图标。
func _unit_portrait(unit_def: Dictionary, stone_type: String) -> Texture2D:
	var unit_id := str(unit_def.get("id", ""))
	if not unit_id.is_empty():
		var path := "%s/%s.png" % [UNIT_PORTRAIT_DIR, unit_id]
		if ResourceLoader.exists(path):
			var tex := load(path) as Texture2D
			if tex != null:
				return tex
	return Card.stone_texture(stone_type)


# 「攻击 80 → 104 · 生命 1200 → 1560」。系数走 GameState.star_stat_multiplier。
func _four_star_gain_text(unit_def: Dictionary) -> String:
	var atk := float(unit_def.get("atk", 0))
	var hp := float(unit_def.get("hp", 0))
	if atk <= 0.0 and hp <= 0.0:
		return ""
	var m3 := GameState.star_stat_multiplier(GameState.MAX_MERGE_STAR, unit_def)
	var m4 := GameState.star_stat_multiplier(GameState.MAX_UNIT_STAR, unit_def)
	var parts: PackedStringArray = []
	if atk > 0.0:
		parts.append(_t("攻击 %d → %d", "ATK %d → %d") % [int(round(atk * m3)), int(round(atk * m4))])
	if hp > 0.0:
		parts.append(_t("生命 %d → %d", "HP %d → %d") % [int(round(hp * m3)), int(round(hp * m4))])
	return "  ·  ".join(parts)


func _four_star_reason(error: String, stone_type: String) -> String:
	match error:
		"no_stone": return _t("升级石不足", "Need %s Stone" % _stone_display(stone_type))
		"not_enough_gold": return _t("金币不足", "Not enough gold")
		"bad_element": return _t("该棋子暂无对应升级石", "No matching stone for this unit")
		"already_max": return _t("已经达到四星", "Already 4 stars")
		_: return _t("暂时无法升级", "Upgrade unavailable")


# ============================================================ 代码画的小件

# 营地等级进度条：空槽 + 金色填充（两张图九宫格，填充缩在槽里面）
class CampProgress extends Control:
	var ratio := 0.0:
		set(v):
			ratio = clampf(v, 0.0, 1.0)
			queue_redraw()
	var _track: StyleBoxTexture
	var _fill: StyleBoxTexture

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		var detail_card := preload("res://ui/components/UnitDetailCard.gd")
		_track = detail_card.slice("res://assets/ui/carrot_camp/progress_track.png", 22.0 / 46.0, Vector4(23, 0, 23, 0))
		_fill = detail_card.slice("res://assets/ui/carrot_camp/progress_fill.png", 14.0 / 38.0, Vector4(19, 0, 19, 0))

	func _draw() -> void:
		draw_style_box(_track, Rect2(Vector2.ZERO, size))
		if ratio <= 0.0:
			return
		var inner := Rect2(Vector2(4, 4), size - Vector2(8, 8))
		var w := maxf(inner.size.y * 1.2, inner.size.x * ratio)
		draw_style_box(_fill, Rect2(inner.position, Vector2(w, inner.size.y)))


# 页签两边的金线
class GoldLine extends Control:
	var fade_left := true

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var y := size.y * 0.5
		var steps := 24
		for i in steps:
			var t0 := float(i) / steps
			var t1 := float(i + 1) / steps
			var a := t1 if fade_left else 1.0 - t0
			draw_line(Vector2(size.x * t0, y), Vector2(size.x * t1, y), Color(0.72, 0.52, 0.22, 0.9 * a), 2.0)


# 细线 + 中间一颗菱形
class DiamondRule extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var col := Color(0.72, 0.52, 0.22, 0.9)
		draw_line(Vector2(0, c.y), Vector2(c.x - 9, c.y), col, 1.5)
		draw_line(Vector2(c.x + 9, c.y), Vector2(size.x, c.y), col, 1.5)
		var d := PackedVector2Array([c + Vector2(0, -6), c + Vector2(6, 0), c + Vector2(0, 6), c + Vector2(-6, 0)])
		draw_colored_polygon(d, Color("e9c46a"))
		draw_polyline(d + PackedVector2Array([d[0]]), Color("8a5a1c"), 1.5)


# 抽石头那颗大石头后面的一圈暖光
class StoneGlow extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5
		for i in 14:
			var t := float(i) / 14.0
			draw_circle(c, r * (1.0 - t * 0.85), Color(1.0, 0.9, 0.55, 0.07 + t * 0.05))
		# 放射光线（设计图里是一圈很亮的金色光芒）
		for i in 20:
			var ang := TAU * float(i) / 20.0
			var dir := Vector2(cos(ang), sin(ang))
			draw_line(c + dir * r * 0.3, c + dir * r * 1.0, Color(1.0, 0.92, 0.6, 0.38), 5.0)
