extends PanelContainer

const CarrotEconomy := preload("res://scripts/economy/CarrotEconomy.gd")
const TEX_PANEL: Texture2D = preload("res://assets/props/carrot_system/ui/panel_carrot_camp.png")
const TEX_HEADER: Texture2D = preload("res://assets/props/carrot_system/ui/plaque_resource_header.png")
const TEX_TAB_SELECTED: Texture2D = preload("res://assets/props/carrot_system/ui/frame_tab_selected.png")
const TEX_CARROT: Texture2D = preload("res://assets/props/carrot_system/ui/icon_carrot_currency.png")
const TEX_FARM: Texture2D = preload("res://assets/props/carrot_system/ui/icon_carrot_farm_level.png")
const TEX_TECH: Texture2D = preload("res://assets/props/carrot_system/ui/icon_harvest_tech.png")
const TEX_PROGRESS_TRACK: Texture2D = preload("res://assets/props/carrot_system/ui/progress_track.png")
const TEX_PROGRESS_FILL: Texture2D = preload("res://assets/props/carrot_system/ui/progress_fill.png")
const TEX_STONE_UNKNOWN: Texture2D = preload("res://assets/props/carrot_system/stones/stone_unknown.png")
const TEX_STONE_SKY: Texture2D = preload("res://assets/props/carrot_system/stones/stone_sky.png")
const TEX_STONE_LAND: Texture2D = preload("res://assets/props/carrot_system/stones/stone_land.png")
const TEX_STONE_REN: Texture2D = preload("res://assets/props/carrot_system/stones/stone_ren.png")
const TEX_STONE_REVEAL: Texture2D = preload("res://assets/props/carrot_system/vfx/atlas_stone_reveal_4x4.png")

signal closed

var _upgrade_callback: Callable
var _draw_callback: Callable
var _hire_callback: Callable
var _open_merc_callback: Callable
var _warehouse_callback: Callable
var _four_star_callback: Callable
var _camp_page: VBoxContainer
var _stone_page: VBoxContainer
var _camp_tab: Button
var _stone_tab: Button
var _carrot_value: Label
var _gain_value: Label
var _income_value: Label
var _farm_title: Label
var _farm_progress_fill: TextureRect
var _farm_progress_value: Label
var _farm_benefit: Label
var _tech_title: Label
var _tech_gain: Label
var _tech_button: Button
var _draw_button: Button
var _draw_status: Label
var _draw_hint: Label
var _stone_art: TextureRect
var _stone_reveal: TextureRect
var _stone_counts: Dictionary = {}
var _four_star_list: VBoxContainer
var _last_stone_values := {"sky": 0, "land": 0, "ren": 0}
var _stone_values_initialized := false
var _reveal_serial := 0

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
	if get_child_count() > 0:
		return
	custom_minimum_size = Vector2(448.0, 560.0)
	add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var background := NinePatchRect.new()
	background.texture = TEX_PANEL
	background.set_patch_margin(SIDE_LEFT, 72)
	background.set_patch_margin(SIDE_TOP, 82)
	background.set_patch_margin(SIDE_RIGHT, 72)
	background.set_patch_margin(SIDE_BOTTOM, 82)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	var margin := MarginContainer.new()
	# The generated frame has transparent breathing room at its top and bottom.
	# These margins place every interactive control inside the visible wood frame.
	margin.add_theme_constant_override("margin_left", 42)
	margin.add_theme_constant_override("margin_top", 90)
	margin.add_theme_constant_override("margin_right", 42)
	margin.add_theme_constant_override("margin_bottom", 46)
	add_child(margin)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 7)
	margin.add_child(body)

	var title_row := HBoxContainer.new()
	title_row.custom_minimum_size.y = 34
	body.add_child(title_row)
	var title := _make_label("萝卜营地", 22, Color(1.0, 0.91, 0.57))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_row.add_child(title)
	var close_button := Button.new()
	close_button.text = "×"
	close_button.tooltip_text = "关闭"
	close_button.custom_minimum_size = Vector2(34, 30)
	close_button.add_theme_font_size_override("font_size", 20)
	close_button.add_theme_color_override("font_color", Color(1.0, 0.92, 0.68))
	close_button.add_theme_color_override("font_hover_color", Color.WHITE)
	var close_style := _flat_style(Color(0.18, 0.09, 0.035, 0.92), 14)
	close_style.border_color = Color(0.93, 0.65, 0.23, 0.95)
	close_style.set_border_width_all(1)
	close_button.add_theme_stylebox_override("normal", close_style)
	close_button.add_theme_stylebox_override("hover", _flat_style(Color(0.32, 0.18, 0.08, 0.8), 8))
	close_button.pressed.connect(_close)
	title_row.add_child(close_button)

	var resource_plate := NinePatchRect.new()
	resource_plate.texture = _region_texture(TEX_HEADER, Rect2(245, 41, 533, 168))
	resource_plate.set_patch_margin(SIDE_LEFT, 54)
	resource_plate.set_patch_margin(SIDE_RIGHT, 54)
	resource_plate.set_patch_margin(SIDE_TOP, 18)
	resource_plate.set_patch_margin(SIDE_BOTTOM, 18)
	resource_plate.custom_minimum_size.y = 58
	body.add_child(resource_plate)
	var resource_margin := MarginContainer.new()
	resource_margin.add_theme_constant_override("margin_left", 18)
	resource_margin.add_theme_constant_override("margin_right", 18)
	resource_margin.add_theme_constant_override("margin_top", 9)
	resource_margin.add_theme_constant_override("margin_bottom", 9)
	resource_plate.add_child(resource_margin)
	resource_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var metrics := HBoxContainer.new()
	metrics.alignment = BoxContainer.ALIGNMENT_CENTER
	metrics.add_theme_constant_override("separation", 14)
	resource_margin.add_child(metrics)
	var carrot_metric := _make_metric(TEX_CARROT, "0/0", "萝卜 / 容量")
	_carrot_value = carrot_metric.get("label") as Label
	metrics.add_child(carrot_metric.get("root") as Control)
	var gain_metric := _make_metric(TEX_TECH, "+0", "下回合")
	_gain_value = gain_metric.get("label") as Label
	metrics.add_child(gain_metric.get("root") as Control)
	var income_metric := _make_metric(TEX_FARM, "+0G", "营地收入")
	_income_value = income_metric.get("label") as Label
	metrics.add_child(income_metric.get("root") as Control)

	var tab_row := HBoxContainer.new()
	tab_row.alignment = BoxContainer.ALIGNMENT_CENTER
	tab_row.add_theme_constant_override("separation", 8)
	body.add_child(tab_row)
	_camp_tab = _make_tab_button("营地", TEX_FARM, "萝卜田与采集科技")
	_camp_tab.pressed.connect(_show_page.bind(0))
	tab_row.add_child(_camp_tab)
	_stone_tab = _make_tab_button("升级石", TEX_STONE_UNKNOWN, "抽取与队伍库存")
	_stone_tab.pressed.connect(_show_page.bind(1))
	tab_row.add_child(_stone_tab)

	_camp_page = VBoxContainer.new()
	_camp_page.add_theme_constant_override("separation", 9)
	_camp_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_camp_page)
	_build_camp_page()
	_stone_page = VBoxContainer.new()
	_stone_page.add_theme_constant_override("separation", 7)
	_stone_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_stone_page)
	_build_stone_page()
	_show_page(0)

func _build_camp_page() -> void:
	var farm_row := HBoxContainer.new()
	farm_row.add_theme_constant_override("separation", 10)
	_camp_page.add_child(farm_row)
	farm_row.add_child(_make_icon(TEX_FARM, Vector2(74, 74)))
	var farm_info := VBoxContainer.new()
	farm_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	farm_info.add_theme_constant_override("separation", 2)
	farm_row.add_child(farm_info)
	_farm_title = _make_label("萝卜田 Lv.1", 18, Color(1.0, 0.88, 0.48))
	farm_info.add_child(_farm_title)
	var progress_stack := Control.new()
	progress_stack.custom_minimum_size.y = 24
	progress_stack.clip_contents = true
	farm_info.add_child(progress_stack)
	var progress_track := _make_icon(
		_region_texture(TEX_PROGRESS_TRACK, Rect2(313, 3, 392, 115)), Vector2.ZERO)
	progress_track.stretch_mode = TextureRect.STRETCH_SCALE
	progress_stack.add_child(progress_track)
	progress_track.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	progress_track.offset_top = 3
	progress_track.offset_bottom = -3
	_farm_progress_fill = _make_icon(
		_region_texture(TEX_PROGRESS_FILL, Rect2(313, 3, 392, 115)), Vector2.ZERO)
	_farm_progress_fill.stretch_mode = TextureRect.STRETCH_SCALE
	progress_stack.add_child(_farm_progress_fill)
	_farm_progress_fill.anchor_left = 0.0
	_farm_progress_fill.anchor_top = 0.0
	_farm_progress_fill.anchor_right = 0.0
	_farm_progress_fill.anchor_bottom = 1.0
	_farm_progress_fill.offset_top = 3
	_farm_progress_fill.offset_bottom = -3
	_farm_progress_value = _make_label("0/9", 12, Color.WHITE)
	_farm_progress_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_farm_progress_value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_farm_progress_value.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_farm_progress_value.add_theme_constant_override("outline_size", 3)
	progress_stack.add_child(_farm_progress_value)
	_farm_progress_value.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_farm_benefit = _make_label("容量 12   +0G/场", 14, Color(0.88, 0.94, 0.82))
	farm_info.add_child(_farm_benefit)
	var divider := HSeparator.new()
	divider.modulate = Color(0.74, 0.48, 0.18, 0.65)
	_camp_page.add_child(divider)
	var tech_row := HBoxContainer.new()
	tech_row.add_theme_constant_override("separation", 10)
	_camp_page.add_child(tech_row)
	tech_row.add_child(_make_icon(TEX_TECH, Vector2(68, 68)))
	var tech_info := VBoxContainer.new()
	tech_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tech_row.add_child(tech_info)
	_tech_title = _make_label("采集 Lv.0", 18, Color(1.0, 0.88, 0.48))
	tech_info.add_child(_tech_title)
	_tech_gain = _make_label("+3 / 回合", 14, Color(0.78, 1.0, 0.72))
	tech_info.add_child(_tech_gain)
	_tech_button = Button.new()
	_tech_button.custom_minimum_size = Vector2(86, 50)
	_tech_button.add_theme_font_size_override("font_size", 16)
	_tech_button.add_theme_stylebox_override("normal", _action_style(Color(0.38, 0.20, 0.07, 0.96)))
	_tech_button.add_theme_stylebox_override("hover", _action_style(Color(0.52, 0.29, 0.09, 1.0)))
	_tech_button.pressed.connect(_on_upgrade)
	tech_row.add_child(_tech_button)

func _build_stone_page() -> void:
	var draw_row := HBoxContainer.new()
	draw_row.alignment = BoxContainer.ALIGNMENT_CENTER
	draw_row.add_theme_constant_override("separation", 14)
	_stone_page.add_child(draw_row)
	var art_stack := Control.new()
	art_stack.custom_minimum_size = Vector2(92, 92)
	draw_row.add_child(art_stack)
	_stone_art = _make_icon(TEX_STONE_UNKNOWN, Vector2(92, 92))
	art_stack.add_child(_stone_art)
	_stone_art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stone_reveal = _make_icon(TEX_STONE_REVEAL, Vector2(92, 92))
	_stone_reveal.visible = false
	art_stack.add_child(_stone_reveal)
	_stone_reveal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var draw_info := VBoxContainer.new()
	draw_info.custom_minimum_size.x = 150
	draw_info.add_theme_constant_override("separation", 4)
	draw_row.add_child(draw_info)
	_draw_status = _make_label("本回合 1/1", 16, Color(1.0, 0.88, 0.48))
	draw_info.add_child(_draw_status)
	_draw_button = Button.new()
	_draw_button.text = "50"
	_draw_button.icon = TEX_CARROT
	_draw_button.expand_icon = true
	_draw_button.add_theme_constant_override("icon_max_width", 30)
	_draw_button.custom_minimum_size = Vector2(142, 48)
	_draw_button.add_theme_font_size_override("font_size", 18)
	_draw_button.add_theme_stylebox_override("normal", _action_style(Color(0.38, 0.20, 0.07, 0.96)))
	_draw_button.add_theme_stylebox_override("hover", _action_style(Color(0.52, 0.29, 0.09, 1.0)))
	_draw_button.pressed.connect(_on_draw)
	draw_info.add_child(_draw_button)
	_draw_hint = _make_label("天 · 地 · 人", 13, Color(0.82, 0.89, 0.92))
	_draw_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	draw_info.add_child(_draw_hint)
	var divider := HSeparator.new()
	divider.modulate = Color(0.74, 0.48, 0.18, 0.65)
	_stone_page.add_child(divider)
	var inventory := GridContainer.new()
	inventory.columns = 3
	inventory.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inventory.add_theme_constant_override("h_separation", 8)
	_stone_page.add_child(inventory)
	_add_stone_counter(inventory, "sky", TEX_STONE_SKY, "天")
	_add_stone_counter(inventory, "land", TEX_STONE_LAND, "地")
	_add_stone_counter(inventory, "ren", TEX_STONE_REN, "人")
	var upgrade_scroll := ScrollContainer.new()
	upgrade_scroll.custom_minimum_size.y = 54
	upgrade_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	upgrade_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_stone_page.add_child(upgrade_scroll)
	_four_star_list = VBoxContainer.new()
	_four_star_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	upgrade_scroll.add_child(_four_star_list)

func _make_metric(texture: Texture2D, initial_text: String, tooltip: String) -> Dictionary:
	var root := HBoxContainer.new()
	root.tooltip_text = tooltip
	root.add_theme_constant_override("separation", 3)
	root.add_child(_make_icon(texture, Vector2(30, 30)))
	var label := _make_label(initial_text, 14, Color(1.0, 0.92, 0.70))
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	root.add_child(label)
	return {"root": root, "label": label}

func _make_tab_button(text: String, texture: Texture2D, tooltip: String) -> Button:
	var button := Button.new()
	button.text = text
	button.icon = texture
	button.expand_icon = true
	button.add_theme_constant_override("icon_max_width", 30)
	button.tooltip_text = tooltip
	button.custom_minimum_size = Vector2(140, 44)
	button.add_theme_font_size_override("font_size", 15)
	return button

func _make_icon(texture: Texture2D, minimum: Vector2) -> TextureRect:
	var icon := TextureRect.new()
	icon.texture = texture
	icon.custom_minimum_size = minimum
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return icon

func _region_texture(texture: Texture2D, region: Rect2) -> AtlasTexture:
	var atlas := AtlasTexture.new()
	atlas.atlas = texture
	atlas.region = region
	return atlas

func _make_label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label

func _flat_style(color: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	return style

func _action_style(color: Color) -> StyleBoxFlat:
	var style := _flat_style(color, 8)
	style.border_color = Color(0.93, 0.65, 0.23, 0.95)
	style.set_border_width_all(2)
	style.content_margin_left = 10
	style.content_margin_right = 10
	return style

func _selected_tab_style() -> StyleBoxTexture:
	var style := StyleBoxTexture.new()
	style.texture = TEX_TAB_SELECTED
	style.set_texture_margin(SIDE_LEFT, 44)
	style.set_texture_margin(SIDE_RIGHT, 44)
	style.set_texture_margin(SIDE_TOP, 24)
	style.set_texture_margin(SIDE_BOTTOM, 24)
	return style

func _set_tab_selected(button: Button, selected: bool) -> void:
	var normal: StyleBox = _selected_tab_style() if selected else _flat_style(Color(0.12, 0.07, 0.035, 0.82), 8)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", normal)
	button.add_theme_stylebox_override("pressed", normal)
	button.modulate = Color.WHITE if selected else Color(0.70, 0.70, 0.70, 1.0)

func _show_page(index: int) -> void:
	if _camp_page == null or _stone_page == null:
		return
	_camp_page.visible = index == 0
	_stone_page.visible = index == 1
	_set_tab_selected(_camp_tab, index == 0)
	_set_tab_selected(_stone_tab, index == 1)

func _add_stone_counter(parent: GridContainer, stone_type: String,
		texture: Texture2D, display_name: String) -> void:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.tooltip_text = "%s石：队伍共享" % display_name
	box.add_child(_make_icon(texture, Vector2(58, 54)))
	var count := _make_label("%s ×0" % display_name, 14, Color(1.0, 0.90, 0.68))
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(count)
	_stone_counts[stone_type] = count
	parent.add_child(box)

func _close() -> void:
	visible = false
	closed.emit()

func toggle() -> void:
	visible = not visible
	if visible:
		refresh()

func refresh() -> void:
	if _carrot_value == null:
		return
	var preview := CarrotEconomy.harvest(
		GameState.carrots, GameState.merc_carrots_spent_total, GameState.harvest_tech_level)
	var actual_gain := int(preview.get("gain", 0))
	var overflow := int(preview.get("overflow", 0))
	var capacity := GameState.carrot_capacity()
	_carrot_value.text = ("满 %d/%d" if actual_gain <= 0 and overflow > 0 else "%d/%d") % [GameState.carrots, capacity]
	_gain_value.text = "+%d" % actual_gain
	_gain_value.modulate = Color(1.0, 0.58, 0.38) if overflow > 0 else Color.WHITE
	_income_value.text = "+%dG" % GameState.carrot_camp_income()
	var farm_level := GameState.carrot_farm_level()
	var next_threshold := GameState.carrot_next_threshold()
	var current_threshold := int(CarrotEconomy.FARM_THRESHOLDS[farm_level])
	_farm_title.text = "萝卜田 Lv.%d" % (farm_level + 1)
	_farm_benefit.text = "容量 %d   +%dG/场" % [capacity, GameState.carrot_camp_income()]
	if next_threshold < 0:
		_farm_progress_fill.anchor_right = 1.0
		_farm_progress_value.text = "MAX"
	else:
		var segment_size := maxi(1, next_threshold - current_threshold)
		_farm_progress_fill.anchor_right = clampf(
			float(GameState.merc_carrots_spent_total - current_threshold) / float(segment_size), 0.0, 1.0)
		_farm_progress_value.text = "%d/%d" % [GameState.merc_carrots_spent_total, next_threshold]
	_farm_progress_fill.tooltip_text = "雇佣兵消耗萝卜会自动提升萝卜田"
	var tech_price := CarrotEconomy.tech_price(GameState.harvest_tech_level)
	_tech_title.text = "采集 Lv.%d" % GameState.harvest_tech_level
	_tech_gain.text = "+%d / 回合" % GameState.carrot_production()
	_tech_button.text = "满级" if tech_price < 0 else "%d G" % tech_price
	var online_blocked := NetworkService.team_active and not NetworkService.is_host and not NetworkService.carrot_economy_enabled()
	_tech_button.disabled = tech_price < 0 or GameState.gold < tech_price or online_blocked
	_tech_button.tooltip_text = "下回合起提高萝卜产量"
	var draw_available := GameState.can_draw_upgrade_stone(GameState.round_index)
	var draw_ready := GameState.carrots >= CarrotEconomy.STONE_COST and capacity >= CarrotEconomy.STONE_COST and draw_available
	_draw_status.text = "本回合 1/1" if draw_available else "本回合 0/1"
	_draw_button.text = "50" if draw_available else "已抽取"
	_draw_button.disabled = not draw_ready or online_blocked
	if capacity < CarrotEconomy.STONE_COST:
		_draw_hint.text = "萝卜田 Lv.4 开启"
	elif GameState.carrots < CarrotEconomy.STONE_COST:
		_draw_hint.text = "还差 %d" % (CarrotEconomy.STONE_COST - GameState.carrots)
	else:
		_draw_hint.text = "天 · 地 · 人"
	_draw_button.tooltip_text = "消耗50萝卜，随机获得一颗队伍升级石"
	var changed_stone := ""
	for stone_type in CarrotEconomy.STONE_TYPES:
		var count := int(GameState.team_upgrade_stones.get(stone_type, 0))
		var count_label := _stone_counts.get(stone_type) as Label
		if count_label != null:
			count_label.text = "%s ×%d" % [{"sky": "天", "land": "地", "ren": "人"}.get(stone_type, stone_type), count]
		if _stone_values_initialized and count > int(_last_stone_values.get(stone_type, 0)):
			changed_stone = stone_type
		_last_stone_values[stone_type] = count
	if _stone_values_initialized and not changed_stone.is_empty() and visible:
		_play_stone_reveal(changed_stone)
	_stone_values_initialized = true
	_refresh_four_star_list()

func _refresh_four_star_list() -> void:
	if _four_star_list == null:
		return
	for child in _four_star_list.get_children():
		child.queue_free()
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
			var stone_type := str(check.get("stone", ""))
			var button := Button.new()
			button.text = "%s  ★★★ → ★★★★" % str(unit_def.get("name", unit_def.get("id", "棋子")))
			button.icon = _stone_texture(stone_type)
			button.expand_icon = true
			button.add_theme_constant_override("icon_max_width", 28)
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			button.disabled = not bool(check.get("ok", false))
			button.tooltip_text = "消耗1颗对应升级石"
			button.pressed.connect(_on_four_star.bind(where, index))
			_four_star_list.add_child(button)
	if rows == 0:
		var empty := _make_label("暂无三星棋子", 13, Color(0.70, 0.72, 0.72))
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_four_star_list.add_child(empty)

func _stone_texture(stone_type: String) -> Texture2D:
	match stone_type:
		"sky": return TEX_STONE_SKY
		"land": return TEX_STONE_LAND
		"ren": return TEX_STONE_REN
		_: return TEX_STONE_UNKNOWN

func _play_stone_reveal(stone_type: String) -> void:
	_reveal_serial += 1
	var serial := _reveal_serial
	_stone_art.texture = TEX_STONE_UNKNOWN
	var frame_texture := AtlasTexture.new()
	frame_texture.atlas = TEX_STONE_REVEAL
	_stone_reveal.texture = frame_texture
	_stone_reveal.visible = true
	for frame in range(16):
		if serial != _reveal_serial or not is_instance_valid(_stone_reveal):
			return
		frame_texture.region = Rect2((frame % 4) * 256, (frame / 4) * 256, 256, 256)
		await get_tree().create_timer(0.055).timeout
	_stone_reveal.visible = false
	_stone_art.texture = _stone_texture(stone_type)
	await get_tree().create_timer(0.85).timeout
	if serial == _reveal_serial and is_instance_valid(_stone_art):
		_stone_art.texture = TEX_STONE_UNKNOWN

func _on_upgrade() -> void:
	if _upgrade_callback.is_valid():
		_upgrade_callback.call()
		refresh()

func _on_draw() -> void:
	if _draw_callback.is_valid():
		_draw_callback.call()
		refresh()

func _on_four_star(where: String, index: int) -> void:
	if _four_star_callback.is_valid():
		_four_star_callback.call(where, index)
		refresh()
