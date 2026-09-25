extends PanelContainer

const CarrotEconomy := preload("res://scripts/economy/CarrotEconomy.gd")
const TEX_CARROT: Texture2D = preload("res://assets/props/carrot_system/ui/icon_carrot_currency.png")
const TEX_FARM: Texture2D = preload("res://assets/props/carrot_system/ui/icon_carrot_farm_level.png")
const TEX_TECH: Texture2D = preload("res://assets/props/carrot_system/ui/icon_harvest_tech.png")
const TEX_STONE_UNKNOWN: Texture2D = preload("res://assets/props/carrot_system/stones/stone_unknown.png")
const TEX_STONE_SKY: Texture2D = preload("res://assets/props/carrot_system/stones/stone_sky.png")
const TEX_STONE_LAND: Texture2D = preload("res://assets/props/carrot_system/stones/stone_land.png")
const TEX_STONE_REN: Texture2D = preload("res://assets/props/carrot_system/stones/stone_ren.png")
const TEX_STONE_REVEAL: Texture2D = preload("res://assets/props/carrot_system/vfx/atlas_stone_reveal_4x4.png")

const PANEL_SIZE := Vector2(760.0, 520.0)
const GOLD := Color(0.94, 0.72, 0.34)
const TEXT := Color(0.97, 0.92, 0.80)
const MUTED := Color(0.72, 0.72, 0.62)
const GREEN := Color(0.74, 0.90, 0.59)

signal closed
# 切页签的事件。教学（9.25 萝卜 / 四星教学）靠它知道玩家现在在哪一页。
signal page_changed(index: int)

var _upgrade_callback: Callable
var _draw_callback: Callable
var _four_star_callback: Callable
var _camp_page: Control
var _stone_page: Control
var _camp_tab: Button
var _stone_tab: Button
var _help_panel: Control
var _carrot_balance: Label
var _carrot_capacity: Label
var _farm_level: Label
var _farm_need: Label
var _farm_progress: ProgressBar
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
var _four_star_list: VBoxContainer
var _last_stones := {"sky": 0, "land": 0, "ren": 0}
var _stones_initialized := false
var _reveal_serial := 0
var _action_locked := false
var _close_button: Button
var _current_page := 0
# 四星列表每行的「升至四星」按钮（每次 refresh 重建）。教学箭头要指着它。
var _four_star_buttons: Array[Button] = []

# 只收面板真正会调用的三个回调。
#
# 以前还有 hire / open_merc / warehouse 三个参数，是 V1 那版「萝卜营地替换佣兵按钮」
# 设计的遗留：V1 里有第三个「佣兵」页签用 hire_callback，4fd1e48 改版时页签被拿掉，
# 另外两个从建出来就没接过按钮。参数留着不报错，只会让调用方以为面板能雇佣兵 ——
# 而实际入口在佣兵选择层（PrepUI._create_mercenary_purchase_card）。
func setup(upgrade_callback: Callable, draw_callback: Callable,
		four_star_callback: Callable = Callable()) -> void:
	_upgrade_callback = upgrade_callback
	_draw_callback = draw_callback
	_four_star_callback = four_star_callback
	if not LocaleManager.locale_changed.is_connected(_on_locale_changed):
		LocaleManager.locale_changed.connect(_on_locale_changed)
	_build()

func _on_locale_changed(_locale: String) -> void:
	var selected_page := 1 if _stone_page != null and _stone_page.visible else 0
	_reveal_serial += 1
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_camp_page = null
	_stone_page = null
	_help_panel = null
	_stone_counts.clear()
	_stones_initialized = false
	_build()
	_show_page(selected_page)
	refresh()

func _build() -> void:
	if get_child_count() > 0:
		return
	custom_minimum_size = PANEL_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", _panel_style())
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 26)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 26)
	margin.add_theme_constant_override("margin_bottom", 18)
	add_child(margin)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	margin.add_child(body)
	_build_header(body)
	_build_tabs(body)
	var pages := Control.new()
	pages.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(pages)
	_camp_page = _build_camp_page()
	pages.add_child(_camp_page)
	_camp_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stone_page = _build_stone_page()
	pages.add_child(_stone_page)
	_stone_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_help_panel()
	_show_page(0)

func _build_header(parent: VBoxContainer) -> void:
	var header := HBoxContainer.new()
	header.custom_minimum_size.y = 48
	header.add_theme_constant_override("separation", 10)
	parent.add_child(header)
	var title := _label(_t("萝卜营地", "Carrot Camp"), 26, TEXT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(title)
	var wallet := PanelContainer.new()
	wallet.custom_minimum_size = Vector2(230, 44)
	wallet.add_theme_stylebox_override("panel", _flat(Color(0.075,0.115,0.09,0.98),11,Color(0.28,0.34,0.25),1))
	header.add_child(wallet)
	var wallet_row := HBoxContainer.new()
	wallet_row.alignment = BoxContainer.ALIGNMENT_CENTER
	wallet_row.add_theme_constant_override("separation", 4)
	wallet.add_child(wallet_row)
	wallet_row.add_child(_label(_t("当前萝卜", "Carrots"), 14, MUTED))
	wallet_row.add_child(_icon(TEX_CARROT, Vector2(36,36)))
	_carrot_balance = _label("0", 23, TEXT)
	wallet_row.add_child(_carrot_balance)
	_carrot_capacity = _label("/ 0", 15, MUTED)
	wallet_row.add_child(_carrot_capacity)
	var help := _icon_button("?", _t("玩法说明", "How it works"))
	help.pressed.connect(_toggle_help)
	header.add_child(help)
	var close := _icon_button("×", _t("关闭", "Close"))
	close.add_theme_font_size_override("font_size", 22)
	close.pressed.connect(_close)
	header.add_child(close)
	_close_button = close

func _build_tabs(parent: VBoxContainer) -> void:
	var tabs := HBoxContainer.new()
	tabs.custom_minimum_size.y = 45
	tabs.add_theme_constant_override("separation", 8)
	parent.add_child(tabs)
	_camp_tab = _tab_button(_t("营地", "Camp"))
	_camp_tab.pressed.connect(_show_page.bind(0))
	tabs.add_child(_camp_tab)
	_stone_tab = _tab_button(_t("升级石", "Upgrade Stones"))
	_stone_tab.pressed.connect(_show_page.bind(1))
	tabs.add_child(_stone_tab)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.add_child(spacer)

func _build_camp_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 12)
	var cards := HBoxContainer.new()
	cards.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cards.add_theme_constant_override("separation", 14)
	page.add_child(cards)
	var farm_card := _card(false)
	farm_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards.add_child(farm_card)
	var farm := VBoxContainer.new()
	farm.add_theme_constant_override("separation", 7)
	farm_card.add_child(farm)
	var farm_heading := HBoxContainer.new()
	farm_heading.add_theme_constant_override("separation", 10)
	farm.add_child(farm_heading)
	farm_heading.add_child(_icon(TEX_FARM, Vector2(74,74)))
	var farm_titles := VBoxContainer.new()
	farm_titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	farm_heading.add_child(farm_titles)
	_farm_level = _label(_t("营地等级 · 1", "Camp Lv. 1"), 14, GOLD)
	farm_titles.add_child(_farm_level)
	farm_titles.add_child(_label(_t("萝卜田", "Carrot Field"), 22, TEXT))
	farm_titles.add_child(_label(_t("随雇佣自动成长", "Grows as you hire"), 13, GREEN))
	_farm_need = _label(_t("距离下一级", "To next level"), 15, TEXT)
	farm.add_child(_farm_need)
	_farm_progress = ProgressBar.new()
	_farm_progress.custom_minimum_size.y = 14
	_farm_progress.show_percentage = false
	_farm_progress.add_theme_stylebox_override("background", _flat(Color(0.07,0.12,0.09),7))
	_farm_progress.add_theme_stylebox_override("fill", _flat(Color(0.48,0.68,0.36),7))
	farm.add_child(_farm_progress)
	farm.add_child(_label(_t("雇佣佣兵消耗的萝卜计入成长", "Carrots spent hiring mercenaries count toward growth"), 13, MUTED))
	var next_box := VBoxContainer.new()
	next_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	next_box.add_theme_constant_override("separation", 5)
	farm.add_child(next_box)
	next_box.add_child(_divider())
	_farm_next_capacity = _value_row(next_box, _t("下级容量", "Next Capacity"))
	_farm_next_production = _value_row(next_box, _t("每回合产量", "Yield / Round"))
	_farm_next_income = _value_row(next_box, _t("营地金币收益", "Camp Gold / Battle"))
	var tech_card := _card(true)
	tech_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards.add_child(tech_card)
	var tech := VBoxContainer.new()
	tech.add_theme_constant_override("separation", 7)
	tech_card.add_child(tech)
	var tech_heading := HBoxContainer.new()
	tech_heading.add_theme_constant_override("separation", 10)
	tech.add_child(tech_heading)
	tech_heading.add_child(_icon(TEX_TECH, Vector2(74,74)))
	var tech_titles := VBoxContainer.new()
	tech_titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tech_heading.add_child(tech_titles)
	_tech_level = _label(_t("采集等级 · 0", "Harvest Lv. 0"), 14, GOLD)
	tech_titles.add_child(_tech_level)
	tech_titles.add_child(_label(_t("提升采集", "Harvest Upgrade"), 22, TEXT))
	tech_titles.add_child(_label(_t("采集基础产量", "Base Harvest Yield"), 13, MUTED))
	var yield_row := HBoxContainer.new()
	yield_row.alignment = BoxContainer.ALIGNMENT_CENTER
	yield_row.custom_minimum_size.y = 76
	yield_row.add_theme_constant_override("separation", 18)
	tech.add_child(yield_row)
	_tech_current = _label("3", 36, TEXT)
	yield_row.add_child(_tech_current)
	yield_row.add_child(_label("→", 25, MUTED))
	_tech_next = _label("6", 36, GREEN)
	yield_row.add_child(_tech_next)
	_tech_note = _label(_t("升级后，下回合生效", "Takes effect next round"), 14, MUTED)
	_tech_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tech.add_child(_tech_note)
	var tech_spacer := Control.new()
	tech_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tech.add_child(tech_spacer)
	_tech_button = _primary_button(_t("升级采集", "Upgrade Harvest"))
	_tech_button.pressed.connect(_on_upgrade)
	tech.add_child(_tech_button)
	var footer := HBoxContainer.new()
	footer.custom_minimum_size.y = 28
	page.add_child(footer)
	_harvest_footer = _label(_t("下回合可收获 0 萝卜", "Next harvest: 0"), 14, GREEN)
	_harvest_footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(_harvest_footer)
	_gold_footer = _label(_t("持有金币 0", "Gold: 0"), 14, TEXT)
	footer.add_child(_gold_footer)
	return page

func _build_stone_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)
	var cards := HBoxContainer.new()
	cards.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cards.add_theme_constant_override("separation", 14)
	page.add_child(cards)
	var draw_card := _card(true)
	draw_card.custom_minimum_size.x = 315
	cards.add_child(draw_card)
	var draw := VBoxContainer.new()
	draw.alignment = BoxContainer.ALIGNMENT_CENTER
	draw.add_theme_constant_override("separation", 5)
	draw_card.add_child(draw)
	var draw_title := _label(_t("抽取升级石", "Draw Upgrade Stone"), 22, TEXT)
	draw_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	draw.add_child(draw_title)
	_draw_status = _label(_t("本回合剩余 1 次", "1 draw remaining"), 14, MUTED)
	_draw_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	draw.add_child(_draw_status)
	var art_stack := Control.new()
	art_stack.custom_minimum_size = Vector2(130,130)
	draw.add_child(art_stack)
	_stone_art = _icon(TEX_STONE_UNKNOWN, Vector2.ZERO)
	art_stack.add_child(_stone_art)
	_stone_art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stone_reveal = _icon(TEX_STONE_REVEAL, Vector2.ZERO)
	_stone_reveal.visible = false
	art_stack.add_child(_stone_reveal)
	_stone_reveal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_draw_result = _label(_t("随机获得天、地、人石之一", "Get one random Sky, Land, or Ren Stone"), 14, MUTED)
	_draw_result.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_draw_result.custom_minimum_size.y = 26
	draw.add_child(_draw_result)
	_draw_button = _primary_button(_t("抽取一次", "Draw Once"))
	_draw_button.pressed.connect(_on_draw)
	draw.add_child(_draw_button)

	var inventory_card := _card(false)
	inventory_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards.add_child(inventory_card)
	var inventory := VBoxContainer.new()
	inventory.add_theme_constant_override("separation", 8)
	inventory_card.add_child(inventory)
	var inventory_header := HBoxContainer.new()
	inventory.add_child(inventory_header)
	var inventory_title := _label(_t("升级石库存", "Upgrade Stone Inventory"), 21, TEXT)
	inventory_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inventory_header.add_child(inventory_title)
	inventory_header.add_child(_label(_t("队伍共享", "Team Shared"), 13, GREEN))
	var stones := HBoxContainer.new()
	stones.add_theme_constant_override("separation", 7)
	inventory.add_child(stones)
	_add_stone_counter(stones, "sky", TEX_STONE_SKY, _stone_display("sky"))
	_add_stone_counter(stones, "land", TEX_STONE_LAND, _stone_display("land"))
	_add_stone_counter(stones, "ren", TEX_STONE_REN, _stone_display("ren"))
	inventory.add_child(_divider())
	inventory.add_child(_label(_t("四星升级", "4-Star Upgrade"), 16, TEXT))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inventory.add_child(scroll)
	_four_star_list = VBoxContainer.new()
	_four_star_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_four_star_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_four_star_list)
	var footer := _label(_t("对应升级石 ×1  →  三星棋子升至四星", "1 matching stone → upgrade a 3-star unit to 4 stars"), 14, GREEN)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	page.add_child(footer)
	return page

func _build_help_panel() -> void:
	_help_panel = PanelContainer.new()
	_help_panel.visible = false
	_help_panel.z_index = 20
	_help_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_help_panel.add_theme_stylebox_override("panel", _flat(Color(0.055,0.08,0.065,0.99),16,Color(0.65,0.52,0.30),2))
	add_child(_help_panel)
	_help_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_help_panel.offset_left = 110
	_help_panel.offset_right = -110
	_help_panel.offset_top = 75
	_help_panel.offset_bottom = -75
	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_%s" % side, 28)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 24)
	_help_panel.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	margin.add_child(content)
	var heading := HBoxContainer.new()
	content.add_child(heading)
	var title := _label(_t("萝卜营地怎么玩", "How Carrot Camp Works"), 23, TEXT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(title)
	var close := _icon_button("×", _t("关闭说明", "Close help"))
	close.pressed.connect(_toggle_help)
	heading.add_child(close)
	content.add_child(_label(_t("宠物每回合自动采集萝卜。", "Pets harvest carrots automatically every round."), 16, TEXT))
	content.add_child(_label(_t("用萝卜雇佣佣兵，萝卜田会自动成长。", "Spend carrots on mercenaries to grow the field."), 16, TEXT))
	content.add_child(_label(_t("用金币升级采集，提高之后每回合的产量。", "Spend gold to raise next round's harvest."), 16, TEXT))
	content.add_child(_label(_t("萝卜田达到 Lv.4 后，每回合可抽取一次升级石。", "At Field Lv. 4, draw one upgrade stone each round."), 16, TEXT))

func _show_page(index: int) -> void:
	if _camp_page == null:
		return
	_camp_page.visible = index == 0
	_stone_page.visible = index == 1
	_set_tab(_camp_tab, index == 0)
	_set_tab(_stone_tab, index == 1)
	_current_page = index
	page_changed.emit(index)


func current_page() -> int:
	return _current_page


# --- 教学取值（9.25）：只读暴露控件，给 PrepUI 的教学目标适配层用 -------------------

func tutorial_close_button() -> Control:
	return _close_button


func tutorial_camp_tab() -> Control:
	return _camp_tab


func tutorial_stone_tab() -> Control:
	return _stone_tab


func tutorial_harvest_button() -> Control:
	return _tech_button


func tutorial_draw_button() -> Control:
	return _draw_button


# 第一枚可点的「升至四星」；一枚都不可点时退回第一枚，列表为空时退回列表容器。
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

func refresh() -> void:
	if _carrot_balance == null:
		return
	var capacity := GameState.carrot_capacity()
	var production := GameState.carrot_production()
	var preview := CarrotEconomy.harvest(GameState.carrots, GameState.merc_carrots_spent_total, GameState.harvest_tech_level)
	var actual_gain := int(preview.get("gain", 0))
	var overflow := int(preview.get("overflow", 0))
	_carrot_balance.text = str(GameState.carrots)
	_carrot_capacity.text = "/ %d" % capacity
	var level := GameState.carrot_farm_level()
	_farm_level.text = _t("营地等级 · %d", "Camp Lv. %d") % (level + 1)
	var current_threshold := CarrotEconomy.farm_threshold_for_level(level)
	var next_level := level + 1
	var next_threshold := CarrotEconomy.farm_threshold_for_level(next_level)
	var spent_in_level := GameState.merc_carrots_spent_total - current_threshold
	var segment := maxi(1, next_threshold - current_threshold)
	_farm_progress.value = 100.0 * float(spent_in_level) / float(segment)
	_farm_need.text = _t("距离 Lv.%d · 还需消耗 %d 萝卜", "To Lv.%d · spend %d more carrots") % [next_level + 1, next_threshold - GameState.merc_carrots_spent_total]
	_farm_next_capacity.text = "%d → %d" % [capacity, CarrotEconomy.farm_capacity_for_level(next_level)]
	_farm_next_production.text = "%d → %d" % [production, CarrotEconomy.total_production(GameState.harvest_tech_level, next_threshold)]
	_farm_next_income.text = _t("%d → %d G / 场", "%d → %d G / battle") % [GameState.carrot_camp_income(), CarrotEconomy.farm_income_for_level(next_level)]

	var tech_level := GameState.harvest_tech_level
	var price := CarrotEconomy.tech_price(tech_level)
	var tech_production := CarrotEconomy.production_for_tech(tech_level)
	var next_production := CarrotEconomy.production_for_tech(tech_level + 1)
	var farm_bonus := CarrotEconomy.farm_production_bonus(GameState.merc_carrots_spent_total)
	_tech_level.text = _t("采集等级 · %d", "Harvest Lv. %d") % (tech_level + 1)
	_tech_current.text = str(tech_production)
	_tech_next.text = str(next_production)
	_tech_button.text = _t("升级采集\n%d 金币", "Upgrade Harvest\n%d Gold") % price
	var online_blocked := NetworkService.team_active and not NetworkService.is_host and not NetworkService.carrot_economy_enabled()
	# 教学（9.25）：不受「第 2 回合才解锁」限制，但只在箭头指着它的那一步可点。
	var tech_round_locked := GameState.round_index < 2 and not GameState.tutorial_mode
	var tech_tutorial_locked := not _tutorial_allows("harvest_upgrade")
	_tech_button.disabled = tech_round_locked or tech_tutorial_locked or _action_locked or GameState.gold < price or online_blocked
	if tech_round_locked:
		_tech_note.text = _t("下一回合解锁升级", "Unlocks next round")
	elif GameState.gold < price:
		_tech_note.text = _t("金币不足 · 还差 %d", "Not enough gold · need %d") % (price - GameState.gold)
	elif online_blocked:
		_tech_note.text = _t("等待房主开启联机萝卜系统", "Waiting for host to enable Carrot Camp")
	else:
		_tech_note.text = _t("农田额外 +%d · 升级下回合生效", "Field bonus +%d · next round") % farm_bonus if farm_bonus > 0 else _t("升级后，下回合生效", "Takes effect next round")
	_harvest_footer.text = _t("下回合可收获 %d 萝卜%s", "Next harvest: %d%s") % [actual_gain, _t(" · 容量将满", " · Near capacity") if overflow > 0 else ""]
	_harvest_footer.modulate = Color(1.0,0.66,0.42) if overflow > 0 else Color.WHITE
	_gold_footer.text = _t("持有金币 %d", "Gold: %d") % GameState.gold

	var draw_available := GameState.can_draw_upgrade_stone(GameState.round_index)
	var stone_cost := GameState.upgrade_stone_draw_cost()
	# 教学（9.25）：送的萝卜可以超过容量，抽石头不看容量门槛；但只在抽石头那一步可点。
	var unlocked := capacity >= stone_cost or GameState.tutorial_mode
	var draw_tutorial_locked := not _tutorial_allows("draw_stone")
	_draw_status.text = _t("本回合剩余 1 次", "1 draw remaining") if draw_available else _t("本回合已抽取 · 下回合恢复", "Draw used · resets next round")
	_draw_button.text = _t("抽取一次\n%d 萝卜", "Draw Once\n%d Carrots") % stone_cost if draw_available else _t("下回合恢复", "Resets next round")
	_draw_button.disabled = _action_locked or draw_tutorial_locked or not draw_available or not unlocked or GameState.carrots < stone_cost or online_blocked
	if not unlocked:
		_draw_result.text = _t("容量不足 · 需要储存 %d 萝卜", "Capacity too low · store %d carrots") % stone_cost
	elif GameState.carrots < stone_cost and draw_available:
		_draw_result.text = _t("萝卜不足 · 还差 %d", "Not enough carrots · need %d") % (stone_cost - GameState.carrots)
	elif draw_available and _stone_art.texture == TEX_STONE_UNKNOWN:
		_draw_result.text = _t("随机获得天、地、人石之一", "Get one random Sky, Land, or Ren Stone")
	var changed := ""
	for stone_type in CarrotEconomy.STONE_TYPES:
		var count := int(GameState.team_upgrade_stones.get(stone_type, 0))
		var count_label := _stone_counts.get(stone_type) as Label
		if count_label != null:
			count_label.text = "%s  %d" % [_stone_display(stone_type), count]
		if _stones_initialized and count > int(_last_stones.get(stone_type, 0)):
			changed = stone_type
		_last_stones[stone_type] = count
	if _stones_initialized and not changed.is_empty() and visible:
		_play_stone_reveal(changed)
	_stones_initialized = true
	_refresh_four_star_list()

func _refresh_four_star_list() -> void:
	if _four_star_list == null:
		return
	for child in _four_star_list.get_children():
		_four_star_list.remove_child(child)
		child.queue_free()
	_four_star_buttons.clear()
	var rows := 0
	for source in [["board", GameState.board_slots], ["bench", GameState.bench_slots]]:
		var where := str(source[0])
		var slots: Array = source[1]
		for index in slots.size():
			var cell: Variant = slots[index]
			if typeof(cell) != TYPE_DICTIONARY or int((cell as Dictionary).get("star", 1)) != GameState.MAX_MERGE_STAR:
				continue
			rows += 1
			var check := GameState.four_star_check(cell)
			var unit_def: Dictionary = (cell as Dictionary).get("def", {})
			var stone_type := str(check.get("stone", unit_def.get("element", "")))
			var row := PanelContainer.new()
			row.add_theme_stylebox_override("panel", _flat(Color(0.07,0.115,0.09,0.92),8))
			row.custom_minimum_size.y = 52
			_four_star_list.add_child(row)
			var row_content := HBoxContainer.new()
			row_content.add_theme_constant_override("separation", 6)
			row.add_child(row_content)
			row_content.add_child(_icon(_stone_texture(stone_type), Vector2(42,42)))
			var info := VBoxContainer.new()
			info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row_content.add_child(info)
			info.add_child(_label("%s  ★★★" % str(unit_def.get("name", unit_def.get("id", _t("棋子", "Unit")))), 14, TEXT))
			var reason := _t("1 颗%s石 ＋ %d 金", "1 %s Stone + %d Gold") % [_stone_display(stone_type), CarrotEconomy.four_star_gold(int(unit_def.get("tier", 0)))]
			if not bool(check.get("ok", false)):
				reason = _four_star_reason(str(check.get("error", "")), stone_type)
			info.add_child(_label(reason, 12, MUTED))
			var action := Button.new()
			action.text = _t("升至四星", "Upgrade to 4 Stars")
			action.custom_minimum_size = Vector2(90,44)
			action.add_theme_font_size_override("font_size", 14)
			action.add_theme_stylebox_override("normal", _secondary_button_style())
			action.disabled = _action_locked or not bool(check.get("ok", false)) or not NetworkService.four_star_upgrade_available() or not NetworkService.four_star_request_id.is_empty() \
				or not _tutorial_allows("four_star")
			action.pressed.connect(_on_four_star.bind(where, index))
			row_content.add_child(action)
			_four_star_buttons.append(action)
	if rows == 0:
		var empty := VBoxContainer.new()
		empty.alignment = BoxContainer.ALIGNMENT_CENTER
		empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_four_star_list.add_child(empty)
		var title := _label(_t("暂无三星棋子", "No 3-Star Units"), 16, TEXT)
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_child(title)
		var hint := _label(_t("合成三星棋子后，可在这里使用对应升级石", "Merge a 3-star unit to use its matching stone here"), 13, MUTED)
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_child(hint)

func _add_stone_counter(parent: HBoxContainer, stone_type: String, texture: Texture2D, display_name: String) -> void:
	var box := PanelContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_stylebox_override("panel", _flat(Color(0.055,0.10,0.075,0.95),9,Color(0.25,0.32,0.24),1))
	parent.add_child(box)
	var column := VBoxContainer.new()
	box.add_child(column)
	column.add_child(_icon(texture, Vector2(66,62)))
	var count := _label("%s  0" % display_name, 15, TEXT)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(count)
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
	# 循环里每帧都判了，循环**外**这三行以前没判 —— 最后一次 await 期间切场景
	# （备战被释放）就会在已销毁的节点上写属性。那会打一条引擎级错误，而
	# tools/run_check.ps1 把引擎错误行当硬失败，于是不相干的检查会莫名其妙变红。
	if serial != _reveal_serial or not is_instance_valid(_stone_reveal) 			or not is_instance_valid(_stone_art) or not is_instance_valid(_draw_result):
		return
	_stone_reveal.visible = false
	_stone_art.texture = _stone_texture(stone_type)
	_draw_result.text = _t("获得 %s石 ×1 · 已存入队伍库存", "Received %s Stone ×1 · added to team inventory") % _stone_display(stone_type)

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
	else:
		_help_panel.visible = false

func _close() -> void:
	visible = false
	_help_panel.visible = false
	closed.emit()

func _toggle_help() -> void:
	_help_panel.visible = not _help_panel.visible

func _card(gold_tint: bool) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := _flat(
		Color(0.24,0.22,0.14,0.96) if gold_tint else Color(0.12,0.17,0.13,0.96),
		13, Color(0.53,0.43,0.26) if gold_tint else Color(0.30,0.36,0.27), 1)
	style.content_margin_left = 18
	style.content_margin_top = 16
	style.content_margin_right = 18
	style.content_margin_bottom = 16
	panel.add_theme_stylebox_override("panel", style)
	return panel

func _value_row(parent: VBoxContainer, name: String) -> Label:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var key := _label(name, 14, MUTED)
	key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(key)
	var value := _label("-", 14, GREEN)
	row.add_child(value)
	return value

func _label(value: String, size: int, color: Color) -> Label:
	var result := Label.new()
	result.text = value
	result.add_theme_font_size_override("font_size", size)
	result.add_theme_color_override("font_color", color)
	return result

func _t(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale().begins_with("en") else zh

func _icon(texture: Texture2D, minimum: Vector2) -> TextureRect:
	var result := TextureRect.new()
	result.texture = texture
	result.custom_minimum_size = minimum
	result.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	result.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	result.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return result

func _divider() -> HSeparator:
	var result := HSeparator.new()
	result.modulate = Color(0.54,0.49,0.31,0.7)
	return result

func _icon_button(value: String, tooltip: String) -> Button:
	var result := Button.new()
	result.text = value
	result.tooltip_text = tooltip
	result.custom_minimum_size = Vector2(44,44)
	result.add_theme_font_size_override("font_size", 18)
	result.add_theme_color_override("font_color", TEXT)
	result.add_theme_stylebox_override("normal", _flat(Color(0.075,0.11,0.085),11,Color(0.38,0.35,0.24),1))
	result.add_theme_stylebox_override("hover", _flat(Color(0.16,0.20,0.13),11,GOLD,1))
	return result

func _tab_button(value: String) -> Button:
	var result := Button.new()
	result.text = value
	result.custom_minimum_size = Vector2(132,44)
	result.add_theme_font_size_override("font_size", 17)
	result.add_theme_color_override("font_color", MUTED)
	result.add_theme_color_override("font_hover_color", TEXT)
	return result

func _set_tab(button: Button, selected: bool) -> void:
	var style := _flat(Color(0.16,0.18,0.12,0.92) if selected else Color(0,0,0,0),8)
	if selected:
		style.border_color = GOLD
		style.set_border_width(SIDE_BOTTOM,3)
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_stylebox_override("hover", style)
	button.add_theme_stylebox_override("pressed", style)
	button.add_theme_color_override("font_color", TEXT if selected else MUTED)

func _primary_button(value: String) -> Button:
	var result := Button.new()
	result.text = value
	result.custom_minimum_size.y = 62
	result.add_theme_font_size_override("font_size", 17)
	result.add_theme_color_override("font_color", Color(0.20,0.14,0.06))
	result.add_theme_color_override("font_disabled_color", Color(0.53,0.49,0.39))
	result.add_theme_stylebox_override("normal", _primary_style(Color(0.91,0.66,0.28)))
	result.add_theme_stylebox_override("hover", _primary_style(Color(1.0,0.76,0.36)))
	result.add_theme_stylebox_override("pressed", _primary_style(Color(0.78,0.53,0.20)))
	result.add_theme_stylebox_override("disabled", _flat(Color(0.21,0.22,0.17),9,Color(0.34,0.34,0.27),1))
	return result

func _primary_style(color: Color) -> StyleBoxFlat:
	var result := _flat(color,9,Color(1.0,0.86,0.52),1)
	result.content_margin_top = 8
	result.content_margin_bottom = 8
	return result

func _secondary_button_style() -> StyleBoxFlat:
	return _flat(Color(0.27,0.23,0.13),8,Color(0.69,0.53,0.25),1)

func _panel_style() -> StyleBoxFlat:
	var result := _flat(Color(0.075,0.105,0.085,0.99),18,Color(0.63,0.48,0.25),2)
	result.shadow_color = Color(0,0,0,0.65)
	result.shadow_size = 18
	result.shadow_offset = Vector2(0,8)
	return result

func _flat(color: Color, radius: int, border: Color = Color.TRANSPARENT, width: int = 0) -> StyleBoxFlat:
	var result := StyleBoxFlat.new()
	result.bg_color = color
	result.set_corner_radius_all(radius)
	result.border_color = border
	result.set_border_width_all(width)
	return result

func _stone_texture(stone_type: String) -> Texture2D:
	match stone_type:
		"sky": return TEX_STONE_SKY
		"land": return TEX_STONE_LAND
		"ren": return TEX_STONE_REN
		_: return TEX_STONE_UNKNOWN

func _stone_display(stone_type: String) -> String:
	match stone_type:
		"sky": return _t("天", "Sky")
		"land": return _t("地", "Land")
		"ren": return _t("人", "Ren")
		_: return "?"

func _four_star_reason(error: String, stone_type: String) -> String:
	match error:
		"no_stone": return _t("缺少%s石", "Need %s Stone") % _stone_display(stone_type)
		"not_enough_gold": return _t("金币不足", "Not enough gold")
		"bad_element": return _t("该棋子暂无对应升级石", "No matching upgrade stone for this unit")
		"already_max": return _t("已经达到四星", "Already 4 stars")
		_: return _t("暂时无法升级", "Upgrade unavailable")
