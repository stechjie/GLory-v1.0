extends PanelContainer

const CarrotEconomy := preload("res://scripts/economy/CarrotEconomy.gd")

signal closed

var _upgrade_callback: Callable
var _four_star_callback: Callable
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
var _four_star_list: VBoxContainer

func setup(upgrade_callback: Callable, draw_callback: Callable, hire_callback: Callable,
		open_merc_callback: Callable, warehouse_callback: Callable,
		four_star_callback: Callable = Callable()) -> void:
	_upgrade_callback = upgrade_callback
	_draw_callback = draw_callback
	_hire_callback = hire_callback
	_open_merc_callback = open_merc_callback
	_warehouse_callback = warehouse_callback
	_four_star_callback = four_star_callback
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
	var four_star_scroll := ScrollContainer.new()
	four_star_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	four_star_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	stone_page.add_child(four_star_scroll)
	_four_star_list = VBoxContainer.new()
	_four_star_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	four_star_scroll.add_child(_four_star_list)

# 列出棋盘和待命区里所有三星棋子，能升的给按钮、不能升的置灰并写明原因。
# 判定不在这里重写 —— 一律问 GameState.four_star_check()，与实际执行读同一份条件，
# 不会出现「按钮亮着但点了没反应」。
func _refresh_four_star_list() -> void:
	if _four_star_list == null:
		return
	for child in _four_star_list.get_children():
		child.queue_free()
	var stone_label := {"sky": "天", "land": "地", "ren": "人"}
	var rows := 0
	for source in [["board", GameState.board_slots], ["bench", GameState.bench_slots]]:
		var where := str(source[0])
		var slots: Array = source[1]
		for i in slots.size():
			var cell = slots[i]
			if typeof(cell) != TYPE_DICTIONARY:
				continue
			if int((cell as Dictionary).get("star", 1)) != GameState.MAX_MERGE_STAR:
				continue
			rows += 1
			var check := GameState.four_star_check(cell)
			var d: Dictionary = (cell as Dictionary).get("def", {})
			var name := str(d.get("name", d.get("id", "?")))
			var stone := str(check.get("stone", ""))
			var row := Button.new()
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			if bool(check.get("ok", false)):
				row.text = "%s（%s）%s → ★★★★  消耗 1 颗%s石" % [
					name, "场上" if where == "board" else "待命", "★★★",
					stone_label.get(stone, stone)]
				row.disabled = false
				row.pressed.connect(_on_four_star.bind(where, i))
			else:
				row.text = "%s（%s） %s" % [name, "场上" if where == "board" else "待命",
					_four_star_reason(str(check.get("error", "")), stone_label.get(stone, stone))]
				row.disabled = true
			_four_star_list.add_child(row)
	if rows == 0:
		var empty := Label.new()
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.text = "还没有三星棋子。四星只能由三星 + 同属性升级石获得，无法靠合成得到。"
		_four_star_list.add_child(empty)

func _four_star_reason(error: String, stone_name: String) -> String:
	match error:
		"no_stone":
			return "缺少%s石" % stone_name
		"already_max":
			return "已经是四星"
		"mercenary":
			return "佣兵不能升四星"
		"bad_element":
			return "属性数据缺失"
		_:
			return "暂不可升级"

func _on_four_star(where: String, index: int) -> void:
	if _four_star_callback.is_valid():
		_four_star_callback.call(where, index)

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
	# 「下回合 +N」必须显示**实际到账**，不是原始产量。采集是
	# `gained = min(产量, 上限 - 当前)`，满仓时到账 0、多出来的部分直接丢弃。
	# 此前这里显示的是 carrot_production()（原始产量），于是满仓玩家看到
	# 「12/12 下回合 +3」，然后下一回合数字一动不动 —— 看起来像采集坏了。
	#
	# 这里不重抄公式，而是拿 CarrotEconomy.harvest() 做一次**无副作用的预演**：
	# 它是纯静态函数，返回 gain/overflow。显示与实际发放读同一份规则，
	# 以后改产量表（比如给萝卜田等级加产量）这里会自动跟上，不会再分家。
	var preview := CarrotEconomy.harvest(
		GameState.carrots, GameState.merc_carrots_spent_total, GameState.harvest_tech_level)
	var actual_gain := int(preview.get("gain", 0))
	var wasted := int(preview.get("overflow", 0))
	# 「浪费」和「已满仓」是两种状态，不能混为一谈：产量高于剩余空间时会浪费一部分
	# （此时仓还没满），只有到账为 0 才是真的满仓。提示行只在真满仓时出现——
	# 那才是玩家会卡死的状态（萝卜不再增长），少量溢出靠数字本身表达就够，
	# 否则高采集科技下会常驻一行噪声。
	var gain_text := "下回合 +%d" % actual_gain
	var overflow_hint := ""
	if wasted > 0:
		var full_prefix := "已满仓，" if actual_gain <= 0 else ""
		gain_text = "下回合 +%d（%s浪费 %d）" % [actual_gain, full_prefix, wasted]
		if actual_gain <= 0:
			overflow_hint = "\n→ 雇佣兵消耗的萝卜会提升萝卜田等级与储存上限"
	_summary.text = "萝卜 %d/%d   %s\n萝卜田 Lv.%d   累计雇佣 %s\n营地收入 +%d 金/场%s" % [
		GameState.carrots, GameState.carrot_capacity(), gain_text,
		GameState.carrot_farm_level() + 1, threshold_text, GameState.carrot_camp_income(),
		overflow_hint]
	var tech_price := CarrotEconomy.tech_price(GameState.harvest_tech_level)
	_tech_button.text = "采集科技 Lv.%d → %s" % [GameState.harvest_tech_level,
		("满级" if tech_price < 0 else "%d 金" % tech_price)]
	var carrot_online_blocked := NetworkService.team_active and not NetworkService.is_host and not NetworkService.carrot_economy_enabled()
	_tech_button.disabled = tech_price < 0 or GameState.gold < tech_price or carrot_online_blocked
	var draw_available := GameState.can_draw_upgrade_stone(GameState.round_index)
	var draw_ready := GameState.carrots >= CarrotEconomy.STONE_COST and GameState.carrot_capacity() >= CarrotEconomy.STONE_COST and draw_available
	_draw_button.text = "本回合已抽取" if not draw_available else ("抽升级石（50萝卜）" if draw_ready else "抽石：4级田/50萝卜/每回合1次")
	_draw_button.disabled = not draw_ready or carrot_online_blocked
	_refresh_four_star_list()
	_stones.text = "队伍升级石：天 %d · 地 %d · 人 %d" % [
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
