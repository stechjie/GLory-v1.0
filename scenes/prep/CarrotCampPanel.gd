extends PanelContainer

const CarrotEconomy := preload("res://scripts/economy/CarrotEconomy.gd")

signal closed

var _upgrade_callback: Callable
var _draw_callback: Callable
var _hire_callback: Callable
var _open_merc_callback: Callable
var _warehouse_callback: Callable
var _body: VBoxContainer
var _merc_list: VBoxContainer
var _summary: Label
var _tech_button: Button
var _draw_button: Button
var _stones: Label

func setup(upgrade_callback: Callable, draw_callback: Callable, hire_callback: Callable,
		open_merc_callback: Callable, warehouse_callback: Callable) -> void:
	_upgrade_callback = upgrade_callback
	_draw_callback = draw_callback
	_hire_callback = hire_callback
	_open_merc_callback = open_merc_callback
	_warehouse_callback = warehouse_callback
	_build()

func _build() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.10, 0.15, 0.97)
	style.border_color = Color(0.88, 0.62, 0.24, 0.95)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	add_theme_stylebox_override("panel", style)
	custom_minimum_size = Vector2(360, 470)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 6)
	margin.add_child(_body)
	var header := HBoxContainer.new()
	_body.add_child(header)
	var title := Label.new()
	title.text = "萝卜营地"
	title.add_theme_font_size_override("font_size", 21)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close := Button.new()
	close.text = "×"
	close.custom_minimum_size = Vector2(34, 30)
	close.pressed.connect(_close)
	header.add_child(close)
	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.add_theme_color_override("font_color", Color(1.0, 0.88, 0.58))
	_body.add_child(_summary)
	var tabs := TabContainer.new()
	tabs.name = "CarrotCampTabs"
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(tabs)
	var gather_page := VBoxContainer.new()
	gather_page.name = "采集"
	gather_page.add_theme_constant_override("separation", 10)
	tabs.add_child(gather_page)
	var gather_hint := Label.new()
	gather_hint.text = "金币提升采集科技；新产量从下一回合生效。"
	gather_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	gather_page.add_child(gather_hint)
	_tech_button = Button.new()
	_tech_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tech_button.pressed.connect(_on_upgrade)
	gather_page.add_child(_tech_button)
	var merc_page := VBoxContainer.new()
	merc_page.name = "佣兵"
	merc_page.add_theme_constant_override("separation", 6)
	tabs.add_child(merc_page)
	var merc_title := Label.new()
	merc_title.text = "本回合佣兵（点击直接雇佣）"
	merc_title.add_theme_color_override("font_color", Color(0.78, 0.88, 1.0))
	merc_page.add_child(merc_title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	merc_page.add_child(scroll)
	_merc_list = VBoxContainer.new()
	_merc_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_merc_list)
	var stone_page := VBoxContainer.new()
	stone_page.name = "升级石"
	stone_page.add_theme_constant_override("separation", 10)
	tabs.add_child(stone_page)
	var stone_hint := Label.new()
	stone_hint.text = "每回合最多抽取一次；天、地、人石等概率进入队伍仓库。"
	stone_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stone_page.add_child(stone_hint)
	_draw_button = Button.new()
	_draw_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_draw_button.pressed.connect(_on_draw)
	stone_page.add_child(_draw_button)
	_stones = Label.new()
	_stones.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stone_page.add_child(_stones)

func _close() -> void:
	visible = false
	closed.emit()

func toggle() -> void:
	visible = not visible
	if visible:
		refresh()

func refresh() -> void:
	if _summary == null:
		return
	var next_threshold := GameState.carrot_next_threshold()
	var threshold_text := "已满级" if next_threshold < 0 else "%d / 下一级 %d" % [GameState.merc_carrots_spent_total, next_threshold]
	_summary.text = "萝卜 %d/%d   下回合 +%d\n萝卜田 Lv.%d   累计雇佣 %s\n营地收入 +%d 金/场" % [
		GameState.carrots, GameState.carrot_capacity(), GameState.carrot_production(),
		GameState.carrot_farm_level() + 1, threshold_text, GameState.carrot_camp_income()]
	var tech_price := CarrotEconomy.tech_price(GameState.harvest_tech_level)
	_tech_button.text = "采集科技 Lv.%d → %s" % [GameState.harvest_tech_level,
		("满级" if tech_price < 0 else "%d 金" % tech_price)]
	var carrot_online_blocked := NetworkService.team_active and not NetworkService.is_host and not NetworkService.carrot_economy_enabled()
	_tech_button.disabled = tech_price < 0 or GameState.gold < tech_price or carrot_online_blocked
	var draw_available := GameState.can_draw_upgrade_stone(GameState.round_index)
	var draw_ready := GameState.carrots >= CarrotEconomy.STONE_COST and GameState.carrot_capacity() >= CarrotEconomy.STONE_COST and draw_available
	_draw_button.text = "本回合已抽取" if not draw_available else ("抽升级石（50萝卜）" if draw_ready else "抽石：4级田/50萝卜/每回合1次")
	_draw_button.disabled = not draw_ready or carrot_online_blocked
	_stones.text = "队伍升级石：天 %d · 地 %d · 人 %d（四星升级待开放）" % [
		int(GameState.team_upgrade_stones.get("sky", 0)),
		int(GameState.team_upgrade_stones.get("land", 0)),
		int(GameState.team_upgrade_stones.get("ren", 0))]
	for child in _merc_list.get_children():
		child.queue_free()
	var mercs: Array = DataRegistry.get_table("mercenaries").get("mercenaries", [])
	for index in mercs.size():
		var merc: Dictionary = mercs[index]
		var button := Button.new()
		button.text = "%s   %d 萝卜" % [str(merc.get("name", merc.get("id", ""))), int(merc.get("carrot_cost", -1))]
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.disabled = GameState.tutorial_mode or carrot_online_blocked or GameState.mercenary_slots.find(null) < 0 or GameState.carrots < int(merc.get("carrot_cost", -1))
		button.pressed.connect(_hire_callback.bind(str(merc.get("id", ""))))
		_merc_list.add_child(button)

func _on_upgrade() -> void:
	if _upgrade_callback.is_valid():
		_upgrade_callback.call()
		refresh()

func _on_draw() -> void:
	if _draw_callback.is_valid():
		_draw_callback.call()
		refresh()

func _open_existing_picker() -> void:
	if _open_merc_callback.is_valid():
		_close()
		_open_merc_callback.call()

func _open_warehouse() -> void:
	if _warehouse_callback.is_valid():
		_close()
		_warehouse_callback.call()
