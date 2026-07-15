extends "res://scenes/battle/BattleScreen.gd"

# ============================================================================
# 离线自测 · 单位测试模式(officetest 专用)。
# 继承 BattleScreen:3D 战场渲染 / 回放播放 / 跳过 全部复用父类,不改原文件。
# 两种状态:
#   编辑态(_edit_mode=true):战场静止,96 个格点(6 槽 x 16 格)可点,
#     摆放任意 棋子/佣兵/怪兽/Boss/法阵Boss,按颜色槽走敌我;宝藏按槽勾选。
#   演示态:按"开始测试"后用 OfficeTestSim 算完整回放,走父类回放播放;
#     播完弹测试结算,回编辑态时摆放原样保留。全程不动 GameState 经济/存档。
# ============================================================================

signal back_requested

const SLOT_NAMES_CN := ["红 A", "蓝 B", "绿 C", "黄 1", "紫 2", "橙 3"]
const SLOT_NAMES_EN := ["Red A", "Blue B", "Green C", "Yellow 1", "Purple 2", "Orange 3"]
const KIND_TABS := ["piece", "merc", "monster", "boss", "formation"]
const KIND_NAMES_CN := {"piece": "棋子", "merc": "佣兵", "monster": "怪兽", "boss": "Boss", "formation": "法阵Boss"}
const KIND_NAMES_EN := {"piece": "Pieces", "merc": "Mercs", "monster": "Monsters", "boss": "Bosses", "formation": "Formation"}
const GRID_BTN_SIZE := Vector2(30.0, 30.0)

var _config := {"placements": [], "slot_treasures": {}}
var _edit_mode := true
var _demo_running := false
var _last_test_result: Dictionary = {}

var _edit_root: Control
var _grid_layer: Control
var _grid_buttons: Dictionary = {}
var _top_bar: Control
var _status_hint: Label
var _last_result_lbl: Label
var _back_btn: Button
var _start_test_btn: Button

var _picker_panel: PanelContainer
var _picker_title: Label
var _picker_list: VBoxContainer
var _picker_star_row: HBoxContainer
var _picker_tab_btns: Dictionary = {}
var _picker_star_btns: Array = []
var _picker_remove_btn: Button
var _picker_slot := -1
var _picker_cell := -1
var _picker_kind := "piece"
var _picker_star := 1

var _treasure_panel: PanelContainer
var _treasure_title: Label
var _treasure_list_box: VBoxContainer
var _treasure_slot := 0
var _treasure_chip_btns: Array = []

var _summary_panel: PanelContainer
var _summary_text: RichTextLabel


func _tt(cn: String, en: String) -> String:
	return en if LocaleManager.get_locale() == "en" else cn


func _slot_display_name(slot: int) -> String:
	return _tt(SLOT_NAMES_CN[slot], SLOT_NAMES_EN[slot])


func _kind_display_name(kind: String) -> String:
	return _tt(str(KIND_NAMES_CN.get(kind, kind)), str(KIND_NAMES_EN.get(kind, kind)))


func _ready() -> void:
	_kind = "pvp"
	_state = OfficeTestSim.build_test_state(_config, true)
	await get_tree().process_frame
	if not is_inside_tree():
		return
	_build()
	await get_tree().process_frame
	if not is_inside_tree():
		return
	_build_edit_ui()
	_refresh_visuals()
	_battle_setup_ready = true


func _process(delta: float) -> void:
	if _edit_mode:
		if _battle_setup_ready:
			_refresh_visuals()
			_update_grid_layout()
		return
	super._process(delta)


# 编辑态下父类跳过按钮不应触发模拟。
func _skip_animation() -> void:
	if _edit_mode:
		return
	super._skip_animation()


# ---------------------------------------------------------------------------
# 编辑 UI 搭建
# ---------------------------------------------------------------------------

func _build_edit_ui() -> void:
	_edit_root = Control.new()
	_edit_root.name = "OfficeTestEditUI"
	_edit_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_edit_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_edit_root.z_index = 150
	add_child(_edit_root)

	_grid_layer = Control.new()
	_grid_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_grid_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_edit_root.add_child(_grid_layer)
	for slot in 6:
		for cell in GameConstants.CELL_COUNT:
			var btn := Button.new()
			btn.focus_mode = Control.FOCUS_NONE
			btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			btn.custom_minimum_size = GRID_BTN_SIZE
			btn.size = GRID_BTN_SIZE
			btn.add_theme_font_size_override("font_size", 11)
			btn.pressed.connect(_on_grid_pressed.bind(slot, cell))
			_grid_layer.add_child(btn)
			_grid_buttons["%d_%d" % [slot, cell]] = btn
	_update_grid_buttons_state()

	_build_top_bar()
	_build_picker_panel()
	_build_treasure_panel()
	_build_summary_panel()

	# 返回按钮独立于编辑 UI,演示中也可退回自测房间。
	_back_btn = _make_text_button(_tt("返回房间", "Back"), 18)
	_back_btn.position = Vector2(12, 12)
	_back_btn.custom_minimum_size = Vector2(110, 40)
	_back_btn.z_index = 190
	_back_btn.pressed.connect(func(): back_requested.emit())
	add_child(_back_btn)


func _build_top_bar() -> void:
	_top_bar = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.08, 0.06, 0.72)
	sb.set_corner_radius_all(12)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	_top_bar.add_theme_stylebox_override("panel", sb)
	_top_bar.anchor_left = 0.5
	_top_bar.anchor_right = 0.5
	_top_bar.offset_left = -430
	_top_bar.offset_right = 430
	_top_bar.offset_top = 8
	_top_bar.offset_bottom = 92
	_edit_root.add_child(_top_bar)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	_top_bar.add_child(col)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	col.add_child(row)

	_start_test_btn = _make_text_button(_tt("开始测试", "Start Test"), 20)
	_start_test_btn.custom_minimum_size = Vector2(130, 40)
	_start_test_btn.pressed.connect(_start_test_demo)
	row.add_child(_start_test_btn)

	var treasure_lbl := Label.new()
	treasure_lbl.text = _tt("宝藏:", "Treasures:")
	treasure_lbl.add_theme_font_size_override("font_size", 16)
	treasure_lbl.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
	row.add_child(treasure_lbl)

	_treasure_chip_btns.clear()
	for slot in 6:
		var chip := _make_text_button("", 14)
		chip.custom_minimum_size = Vector2(86, 36)
		var chip_sb := StyleBoxFlat.new()
		var c := GameConstants.team_slot_color(slot)
		chip_sb.bg_color = Color(c.r, c.g, c.b, 0.55)
		chip_sb.border_color = c
		chip_sb.set_border_width_all(2)
		chip_sb.set_corner_radius_all(10)
		for s in ["normal", "hover", "pressed", "focus", "disabled"]:
			chip.add_theme_stylebox_override(s, chip_sb)
		chip.pressed.connect(_open_treasure_panel.bind(slot))
		row.add_child(chip)
		_treasure_chip_btns.append(chip)
	_update_treasure_chips()

	var info_row := HBoxContainer.new()
	info_row.add_theme_constant_override("separation", 16)
	col.add_child(info_row)

	_status_hint = Label.new()
	_status_hint.text = _tt("点击战场上的格点摆放单位。", "Click a grid point to place a unit.")
	_status_hint.add_theme_font_size_override("font_size", 14)
	_status_hint.add_theme_color_override("font_color", Color(1.0, 0.94, 0.70))
	info_row.add_child(_status_hint)

	_last_result_lbl = Label.new()
	_last_result_lbl.add_theme_font_size_override("font_size", 14)
	_last_result_lbl.add_theme_color_override("font_color", Color(0.72, 0.92, 1.0))
	info_row.add_child(_last_result_lbl)
	_update_last_result_label()


func _make_text_button(text: String, font_size: int) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.add_theme_font_size_override("font_size", font_size)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1.0, 0.93, 0.80, 0.88)
	sb.border_color = Color(0.57, 0.38, 0.13)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	for s in ["normal", "hover", "pressed", "focus"]:
		btn.add_theme_stylebox_override(s, sb)
	btn.add_theme_color_override("font_color", Color(0.42, 0.25, 0.07))
	btn.add_theme_color_override("font_hover_color", Color(0.25, 0.14, 0.03))
	btn.add_theme_color_override("font_pressed_color", Color(0.25, 0.14, 0.03))
	return btn


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.09, 0.08, 0.94)
	sb.border_color = Color(0.72, 0.86, 0.70)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 12.0
	return sb


func _panel_label(text: String, font_size: int, color := Color(0.95, 0.97, 0.92)) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	return lbl


# ---------------------------------------------------------------------------
# 格点
# ---------------------------------------------------------------------------

func _update_grid_layout() -> void:
	if _battle_3d_camera == null or _arena == null:
		return
	for key in _grid_buttons.keys():
		var parts: PackedStringArray = str(key).split("_")
		var slot := int(parts[0])
		var cell := int(parts[1])
		var sim_pos := OfficeTestSim.grid_sim_pos(slot, cell)
		var screen_pos := _world_to_arena(_sim_to_world_pos(sim_pos))
		var btn := _grid_buttons[key] as Button
		btn.position = screen_pos - btn.size * 0.5


func _update_grid_buttons_state() -> void:
	for key in _grid_buttons.keys():
		var parts: PackedStringArray = str(key).split("_")
		var slot := int(parts[0])
		var cell := int(parts[1])
		var btn := _grid_buttons[key] as Button
		var p := OfficeTestSim.placement_at(_config, slot, cell)
		var c := GameConstants.team_slot_color(slot)
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(15)
		if p.is_empty():
			btn.text = "+"
			sb.bg_color = Color(c.r, c.g, c.b, 0.20)
			sb.border_color = Color(c.r, c.g, c.b, 0.55)
			sb.set_border_width_all(1)
			btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
			btn.tooltip_text = "%s · %d" % [_slot_display_name(slot), cell]
		else:
			var kind := str(p.get("kind", ""))
			btn.text = "★%d" % int(p.get("star", 1)) if kind == "piece" else "●"
			sb.bg_color = Color(c.r, c.g, c.b, 0.62)
			sb.border_color = Color(1, 1, 1, 0.85)
			sb.set_border_width_all(2)
			btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
			var def := OfficeTestSim.find_def(kind, str(p.get("unit_id", "")))
			btn.tooltip_text = "%s · %s(%s)" % [_slot_display_name(slot), str(def.get("name", p.get("unit_id", ""))), _kind_display_name(kind)]
		for s in ["normal", "hover", "pressed", "focus"]:
			btn.add_theme_stylebox_override(s, sb)


func _on_grid_pressed(slot: int, cell: int) -> void:
	_treasure_panel.visible = false
	_summary_panel.visible = false
	_picker_slot = slot
	_picker_cell = cell
	var existing := OfficeTestSim.placement_at(_config, slot, cell)
	if not existing.is_empty():
		_picker_kind = str(existing.get("kind", "piece"))
		_picker_star = int(existing.get("star", 1))
	_picker_remove_btn.visible = not existing.is_empty()
	_picker_title.text = "%s · %s %d" % [_slot_display_name(slot), _tt("格", "Cell"), cell]
	_picker_panel.visible = true
	_refresh_picker()


# ---------------------------------------------------------------------------
# 单位选择面板
# ---------------------------------------------------------------------------

func _build_picker_panel() -> void:
	_picker_panel = PanelContainer.new()
	_picker_panel.add_theme_stylebox_override("panel", _panel_style())
	_picker_panel.anchor_left = 1.0
	_picker_panel.anchor_right = 1.0
	_picker_panel.anchor_top = 0.5
	_picker_panel.anchor_bottom = 0.5
	_picker_panel.offset_left = -348
	_picker_panel.offset_right = -10
	_picker_panel.offset_top = -300
	_picker_panel.offset_bottom = 320
	_picker_panel.visible = false
	_edit_root.add_child(_picker_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	_picker_panel.add_child(col)

	_picker_title = _panel_label("", 20, Color(1.0, 0.95, 0.72))
	col.add_child(_picker_title)

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 4)
	col.add_child(tabs)
	for kind in KIND_TABS:
		var tab := _make_text_button(_kind_display_name(kind), 13)
		tab.custom_minimum_size = Vector2(60, 32)
		tab.toggle_mode = false
		tab.pressed.connect(_on_picker_tab.bind(kind))
		tabs.add_child(tab)
		_picker_tab_btns[kind] = tab

	_picker_star_row = HBoxContainer.new()
	_picker_star_row.add_theme_constant_override("separation", 6)
	col.add_child(_picker_star_row)
	_picker_star_row.add_child(_panel_label(_tt("星级:", "Star:"), 15))
	_picker_star_btns.clear()
	for star in range(1, GameConstants.MAX_STAR + 1):
		var sb_btn := _make_text_button("%d★" % star, 14)
		sb_btn.custom_minimum_size = Vector2(48, 30)
		sb_btn.pressed.connect(_on_picker_star.bind(star))
		_picker_star_row.add_child(sb_btn)
		_picker_star_btns.append(sb_btn)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(310, 330)
	col.add_child(scroll)
	_picker_list = VBoxContainer.new()
	_picker_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_picker_list)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 8)
	col.add_child(bottom)
	_picker_remove_btn = _make_text_button(_tt("移除该单位", "Remove"), 15)
	_picker_remove_btn.pressed.connect(_on_picker_remove)
	bottom.add_child(_picker_remove_btn)
	var close_btn := _make_text_button(_tt("关闭", "Close"), 15)
	close_btn.pressed.connect(func(): _picker_panel.visible = false)
	bottom.add_child(close_btn)


func _on_picker_tab(kind: String) -> void:
	_picker_kind = kind
	_refresh_picker()


func _on_picker_star(star: int) -> void:
	_picker_star = star
	# 已放置的棋子直接原位改星,不必重选单位。
	var existing := OfficeTestSim.placement_at(_config, _picker_slot, _picker_cell)
	if not existing.is_empty() and str(existing.get("kind", "")) == "piece":
		OfficeTestSim.set_placement(_config, _picker_slot, _picker_cell, "piece", str(existing.get("unit_id", "")), star)
		_rebuild_edit_preview()
	_refresh_picker()


func _refresh_picker() -> void:
	for kind in _picker_tab_btns.keys():
		var tab := _picker_tab_btns[kind] as Button
		tab.modulate = Color(1, 1, 1, 1.0) if str(kind) == _picker_kind else Color(1, 1, 1, 0.55)
	_picker_star_row.visible = _picker_kind == "piece"
	for i in _picker_star_btns.size():
		(_picker_star_btns[i] as Button).modulate = Color(1, 1, 1, 1.0) if i + 1 == _picker_star else Color(1, 1, 1, 0.55)
	for child in _picker_list.get_children():
		child.queue_free()
	var en := LocaleManager.get_locale() == "en"
	for d in OfficeTestSim.unit_list(_picker_kind):
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var def: Dictionary = d
		var display := str(def.get("name_en", def.get("name", def.get("id", "?")))) if en else str(def.get("name", def.get("id", "?")))
		if _picker_kind == "piece":
			display = "T%d %s" % [int(def.get("tier", 1)), display]
		var item := _make_text_button(display, 14)
		item.alignment = HORIZONTAL_ALIGNMENT_LEFT
		item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item.pressed.connect(_on_picker_unit.bind(str(def.get("id", ""))))
		_picker_list.add_child(item)


func _on_picker_unit(unit_id: String) -> void:
	if _picker_slot < 0 or _picker_cell < 0 or unit_id.is_empty():
		return
	OfficeTestSim.set_placement(_config, _picker_slot, _picker_cell, _picker_kind, unit_id, _picker_star)
	_picker_panel.visible = false
	_rebuild_edit_preview()


func _on_picker_remove() -> void:
	if _picker_slot < 0 or _picker_cell < 0:
		return
	OfficeTestSim.remove_placement(_config, _picker_slot, _picker_cell)
	_picker_panel.visible = false
	_rebuild_edit_preview()


func _rebuild_edit_preview() -> void:
	_state = OfficeTestSim.build_test_state(_config, true)
	_update_grid_buttons_state()
	if _battle_setup_ready:
		_refresh_visuals()


# ---------------------------------------------------------------------------
# 宝藏面板(按颜色槽)
# ---------------------------------------------------------------------------

func _build_treasure_panel() -> void:
	_treasure_panel = PanelContainer.new()
	_treasure_panel.add_theme_stylebox_override("panel", _panel_style())
	_treasure_panel.anchor_left = 0.0
	_treasure_panel.anchor_top = 0.5
	_treasure_panel.anchor_bottom = 0.5
	_treasure_panel.offset_left = 10
	_treasure_panel.offset_right = 340
	_treasure_panel.offset_top = -300
	_treasure_panel.offset_bottom = 320
	_treasure_panel.visible = false
	_edit_root.add_child(_treasure_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	_treasure_panel.add_child(col)

	_treasure_title = _panel_label("", 20, Color(1.0, 0.95, 0.72))
	col.add_child(_treasure_title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(300, 420)
	col.add_child(scroll)
	_treasure_list_box = VBoxContainer.new()
	_treasure_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_treasure_list_box.add_theme_constant_override("separation", 2)
	scroll.add_child(_treasure_list_box)

	var close_btn := _make_text_button(_tt("关闭", "Close"), 15)
	close_btn.pressed.connect(func(): _treasure_panel.visible = false)
	col.add_child(close_btn)


func _open_treasure_panel(slot: int) -> void:
	_picker_panel.visible = false
	_summary_panel.visible = false
	_treasure_slot = slot
	_treasure_title.text = "%s · %s" % [_slot_display_name(slot), _tt("宝藏", "Treasures")]
	for child in _treasure_list_box.get_children():
		child.queue_free()
	var owned := OfficeTestSim.slot_treasures(_config, slot)
	var en := LocaleManager.get_locale() == "en"
	for d in OfficeTestSim.treasure_list():
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var def: Dictionary = d
		var tid := str(def.get("id", ""))
		var check := CheckBox.new()
		check.text = str(def.get("name_en", def.get("name", tid))) if en else str(def.get("name", tid))
		check.add_theme_font_size_override("font_size", 14)
		check.add_theme_color_override("font_color", Color(0.94, 0.96, 0.90))
		check.button_pressed = tid in owned
		check.toggled.connect(_on_treasure_toggled.bind(tid))
		_treasure_list_box.add_child(check)
	_treasure_panel.visible = true


func _on_treasure_toggled(pressed: bool, tid: String) -> void:
	var by_slot: Dictionary = _config.get("slot_treasures", {})
	var list = by_slot.get(_treasure_slot, [])
	var owned: Array = list if list is Array else []
	if pressed and not (tid in owned):
		owned.append(tid)
	elif not pressed:
		owned.erase(tid)
	by_slot[_treasure_slot] = owned
	_config["slot_treasures"] = by_slot
	_update_treasure_chips()
	_rebuild_edit_preview()


func _update_treasure_chips() -> void:
	for slot in _treasure_chip_btns.size():
		var chip := _treasure_chip_btns[slot] as Button
		chip.text = "%s(%d)" % [_slot_display_name(slot).left(1) if LocaleManager.get_locale() != "en" else _slot_display_name(slot).left(3), OfficeTestSim.slot_treasures(_config, slot).size()]
		chip.tooltip_text = "%s · %s" % [_slot_display_name(slot), _tt("宝藏", "Treasures")]


# ---------------------------------------------------------------------------
# 演示
# ---------------------------------------------------------------------------

func _start_test_demo() -> void:
	if _demo_running:
		return
	if OfficeTestSim.side_unit_count(_config, true) <= 0 or OfficeTestSim.side_unit_count(_config, false) <= 0:
		_status_hint.text = _tt("我方(红蓝绿)和敌方(黄紫橙)都至少要有 1 个单位才能开始测试。", "Both sides (ABC vs 123) need at least 1 unit.")
		return
	_demo_running = true
	_edit_mode = false
	_battle_setup_ready = false
	_set_edit_ui_visible(false)
	_show_team_waiting()
	var replay: Dictionary = await OfficeTestSim.compute_test_replay_async(_config)
	if not is_inside_tree():
		return
	if (replay.get("frames", []) as Array).is_empty():
		# 理论上到不了(两边都有单位),兜底直接回编辑态。
		_return_to_edit()
		return
	_start_replay(replay)
	if _battle_music_player != null:
		_battle_music_player.play()


func _set_edit_ui_visible(visible_now: bool) -> void:
	if _edit_root != null:
		_edit_root.visible = visible_now
	if not visible_now:
		if _picker_panel != null:
			_picker_panel.visible = false
		if _treasure_panel != null:
			_treasure_panel.visible = false


# 演示播完:不走父类的 battle_finished 导航,弹测试结算,可回编辑态。
func _finish_replay() -> void:
	if _return_emitted:
		return
	_finished = true
	_return_emitted = true
	_result = _replay.get("result", {})
	_stop_battle_music()
	_last_test_result = _build_summary_data()
	_show_test_summary()


func _return_to_edit() -> void:
	_summary_panel.visible = false
	if _result_overlay_lbl != null:
		_result_overlay_lbl.visible = false
	_stop_battle_music()
	_replay_mode = false
	_replay = {}
	_replay_by_uid = {}
	_replay_frame = 0
	_finished = false
	_return_emitted = false
	_sim_accumulator = 0.0
	_result = {}
	_demo_running = false
	_state = OfficeTestSim.build_test_state(_config, true)
	_edit_mode = true
	_battle_setup_ready = true
	_set_edit_ui_visible(true)
	_update_grid_buttons_state()
	_update_last_result_label()
	_refresh_visuals()


# ---------------------------------------------------------------------------
# 测试结算
# ---------------------------------------------------------------------------

func _build_summary_panel() -> void:
	_summary_panel = PanelContainer.new()
	_summary_panel.add_theme_stylebox_override("panel", _panel_style())
	_summary_panel.anchor_left = 0.5
	_summary_panel.anchor_right = 0.5
	_summary_panel.anchor_top = 0.5
	_summary_panel.anchor_bottom = 0.5
	_summary_panel.offset_left = -280
	_summary_panel.offset_right = 280
	_summary_panel.offset_top = -260
	_summary_panel.offset_bottom = 260
	_summary_panel.visible = false
	_summary_panel.z_index = 210
	add_child(_summary_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	_summary_panel.add_child(col)

	_summary_text = RichTextLabel.new()
	_summary_text.bbcode_enabled = true
	_summary_text.fit_content = false
	_summary_text.scroll_active = true
	_summary_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_summary_text.add_theme_font_size_override("normal_font_size", 16)
	_summary_text.add_theme_font_size_override("bold_font_size", 22)
	_summary_text.add_theme_color_override("default_color", Color(0.95, 0.97, 0.92))
	col.add_child(_summary_text)

	var back_to_edit := _make_text_button(_tt("回到摆放", "Back to Editing"), 18)
	back_to_edit.custom_minimum_size = Vector2(160, 44)
	back_to_edit.pressed.connect(_return_to_edit)
	col.add_child(back_to_edit)


func _build_summary_data() -> Dictionary:
	var result := _result
	var roster: Dictionary = _replay.get("roster", {})
	var frames: Array = _replay.get("frames", [])
	var damage_rows: Array = []
	if not frames.is_empty() and typeof(frames[frames.size() - 1]) == TYPE_ARRAY:
		for entry in frames[frames.size() - 1]:
			if typeof(entry) != TYPE_ARRAY or (entry as Array).size() < 11:
				continue
			var uid := str(entry[0])
			var info: Dictionary = roster.get(uid, {})
			var en := LocaleManager.get_locale() == "en"
			var display := str(info.get("name_en", info.get("name", uid))) if en else str(info.get("name", uid))
			damage_rows.append({
				"name": display,
				"owner_slot": int(info.get("owner_slot", -1)),
				"damage": int(entry[10]),
				"alive": bool(entry[4]),
			})
	damage_rows.sort_custom(func(a, b): return int(a.damage) > int(b.damage))
	return {
		"player_wins": bool(result.get("player_wins", false)),
		"elapsed": float(result.get("elapsed", 0.0)),
		"player_alive": int(result.get("player_alive", 0)),
		"enemy_alive": int(result.get("enemy_alive", 0)),
		"damage_rows": damage_rows,
	}


func _show_test_summary() -> void:
	var data := _last_test_result
	var win := bool(data.get("player_wins", false))
	var winner := _tt("红蓝绿(下方)获胜", "ABC (bottom) wins") if win else _tt("黄紫橙(上方)获胜", "123 (top) wins")
	var lines: Array[String] = []
	lines.append("[b]%s[/b]" % _tt("测试结算", "Test Result"))
	lines.append(winner)
	lines.append(_tt("用时 %.1fs · 存活 红蓝绿 %d / 黄紫橙 %d", "Time %.1fs · Alive ABC %d / 123 %d") % [float(data.get("elapsed", 0.0)), int(data.get("player_alive", 0)), int(data.get("enemy_alive", 0))])
	lines.append("")
	lines.append("[b]%s[/b]" % _tt("伤害榜", "Damage Ranking"))
	var rows: Array = data.get("damage_rows", [])
	var shown := mini(10, rows.size())
	for i in shown:
		var row: Dictionary = rows[i]
		var c := GameConstants.team_slot_color(int(row.get("owner_slot", -1)))
		var dead_mark := "" if bool(row.get("alive", false)) else _tt("(阵亡)", "(dead)")
		lines.append("%d. [color=#%s]%s[/color]%s  %d" % [i + 1, c.to_html(false), str(row.get("name", "?")), dead_mark, int(row.get("damage", 0))])
	_summary_text.text = "\n".join(lines)
	_summary_panel.visible = true


func _update_last_result_label() -> void:
	if _last_result_lbl == null:
		return
	if _last_test_result.is_empty():
		_last_result_lbl.text = _tt("上局:无", "Last run: none")
		return
	var win := bool(_last_test_result.get("player_wins", false))
	_last_result_lbl.text = _tt("上局:%s · %.1fs · 存活 %d/%d", "Last: %s · %.1fs · alive %d/%d") % [
		_tt("红蓝绿胜", "ABC won") if win else _tt("黄紫橙胜", "123 won"),
		float(_last_test_result.get("elapsed", 0.0)),
		int(_last_test_result.get("player_alive", 0)),
		int(_last_test_result.get("enemy_alive", 0)),
	]
