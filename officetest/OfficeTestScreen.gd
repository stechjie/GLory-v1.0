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
# 统计表单元格内边距(左,上,右,下):不加的话 7 列会挤成一团。
const CELL_PAD := "padding=6,2,14,2"

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
# 9.19：编辑态对一个「已摆放的棋子」点开选择器时，额外给「升星」按钮（直接升到 4 星，
# 方便离线验证四星合成音）。该标志在 _on_grid_pressed 里按是否已有同格棋子置位。
var _editing_existing_piece := false
var _upgrade_row: HBoxContainer
var _upgrade_btn: Button
var _to4_btn: Button

var _treasure_panel: PanelContainer
var _treasure_title: Label
var _treasure_list_box: VBoxContainer
var _treasure_slot := 0
var _treasure_chip_btns: Array = []

var _summary_panel: PanelContainer
var _summary_text: RichTextLabel

var _detail_panel: PanelContainer
var _detail_text: RichTextLabel

# 9.14 反馈：演示态（战斗开始后）鼠标停在棋子上要弹「实时数值面板」。
var _stat_panel: PanelContainer
var _stat_text: RichTextLabel
var _hover_unit_id := ""


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
	# 9.19：确保音效播放器池已挂到 root，离线自测里「升星」按钮才播得出四星合成音。
	# install() 幂等（已挂则跳过），与 Main._ready 调的那次不冲突。
	SfxService.install()
	_battle_setup_ready = true


func _process(delta: float) -> void:
	if _edit_mode:
		if _battle_setup_ready:
			_refresh_visuals()
			_update_grid_layout()
		return
	super._process(delta)
	# 演示态：悬停面板跟着当前帧刷新 —— 生命/护盾/状态剩余时间/层数每帧都在变。
	if not _hover_unit_id.is_empty():
		_refresh_stat_panel()


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
			# 长按看详细数值(只在编辑态生效,见 _show_unit_detail)。
			_attach_long_press(btn, _show_unit_detail.bind(slot, cell))
			_grid_layer.add_child(btn)
			_grid_buttons["%d_%d" % [slot, cell]] = btn
	_update_grid_buttons_state()

	_build_top_bar()
	_build_picker_panel()
	_build_treasure_panel()
	_build_summary_panel()
	_build_detail_panel()
	_build_stat_panel()

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
			btn.tooltip_text = UnitDetailFormat.format_unit_def(def, int(p.get("star", 1))).replace("[b]", "").replace("[/b]", "")
		for s in ["normal", "hover", "pressed", "focus"]:
			btn.add_theme_stylebox_override(s, sb)


func _on_grid_pressed(slot: int, cell: int) -> void:
	# 长按刚弹过详情:吞掉这次短按,别顺手把选择器也开了。
	var btn := _grid_buttons.get("%d_%d" % [slot, cell]) as Button
	if btn != null and bool(btn.get_meta("long_press_triggered", false)):
		return
	_treasure_panel.visible = false
	_summary_panel.visible = false
	_detail_panel.visible = false
	_picker_slot = slot
	_picker_cell = cell
	var existing := OfficeTestSim.placement_at(_config, slot, cell)
	if not existing.is_empty():
		_picker_kind = str(existing.get("kind", "piece"))
		_picker_star = int(existing.get("star", 1))
	_editing_existing_piece = not existing.is_empty() and str(existing.get("kind", "")) == "piece"
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

	# 9.19：升星按钮（仅编辑「已摆放棋子」时出现）。无条件 +1★，封顶 MAX_STAR；
	# 另给「直接到 4★」一步到位，方便离线验证四星合成音。升到 4 星时播合成音。
	_upgrade_row = HBoxContainer.new()
	_upgrade_row.add_theme_constant_override("separation", 8)
	col.add_child(_upgrade_row)
	_upgrade_row.add_child(_panel_label(_tt("升星:", "Upgrade:"), 15))
	_upgrade_btn = _make_text_button(_tt("升星 +1★", "Upgrade +1★"), 15)
	_upgrade_btn.pressed.connect(_on_upgrade_star.bind(1))
	_upgrade_row.add_child(_upgrade_btn)
	_to4_btn = _make_text_button(_tt("直接到 4★", "To 4★"), 15)
	_to4_btn.pressed.connect(_on_upgrade_star.bind(99))
	_upgrade_row.add_child(_to4_btn)

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
		# 9.19：直接选到 4★ 时也播合成音，方便离线验证。
		if star >= GameConstants.MAX_STAR:
			SfxService.play(SfxService.star4_cue_for(str(existing.get("unit_id", ""))))
		_rebuild_edit_preview()
	_refresh_picker()


func _refresh_picker() -> void:
	for kind in _picker_tab_btns.keys():
		var tab := _picker_tab_btns[kind] as Button
		tab.modulate = Color(1, 1, 1, 1.0) if str(kind) == _picker_kind else Color(1, 1, 1, 0.55)
	_picker_star_row.visible = _picker_kind == "piece"
	# 升星按钮只在「编辑一个已摆放的棋子」时出现；摆新单位或选佣兵/怪兽/Boss/法阵时隐藏。
	if _upgrade_row != null:
		_upgrade_row.visible = _editing_existing_piece
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
		item.tooltip_text = UnitDetailFormat.format_unit_def(def, _picker_star).replace("[b]", "").replace("[/b]", "")
		item.alignment = HORIZONTAL_ALIGNMENT_LEFT
		item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item.pressed.connect(_on_picker_unit.bind(str(def.get("id", ""))))
		_picker_list.add_child(item)


func _on_picker_unit(unit_id: String) -> void:
	if _picker_slot < 0 or _picker_cell < 0 or unit_id.is_empty():
		return
	OfficeTestSim.set_placement(_config, _picker_slot, _picker_cell, _picker_kind, unit_id, _picker_star)
	# 9.19：摆 unit 时若直接选了 4★，也播合成音，方便离线验证。
	if _picker_kind == "piece" and _picker_star >= GameConstants.MAX_STAR:
		SfxService.play(SfxService.star4_cue_for(unit_id))
	_picker_panel.visible = false
	_rebuild_edit_preview()


func _on_picker_remove() -> void:
	if _picker_slot < 0 or _picker_cell < 0:
		return
	OfficeTestSim.remove_placement(_config, _picker_slot, _picker_cell)
	_picker_panel.visible = false
	_rebuild_edit_preview()


# 9.19：编辑态对一个已摆放的棋子「无条件升星」。delta=1 时每次 +1★（可连点直到 4★），
# delta>=MAX_STAR 时一步到位到 4★。升到 4★ 的瞬间播四星合成音，方便离线验证 9.19
# 修复后的合成音（不再误用战斗技能素材）。
func _on_upgrade_star(delta: int) -> void:
	var existing := OfficeTestSim.placement_at(_config, _picker_slot, _picker_cell)
	if existing.is_empty() or str(existing.get("kind", "")) != "piece":
		return
	var cur := int(existing.get("star", 1))
	var target := clampi(cur + delta, 1, GameConstants.MAX_STAR) if delta < GameConstants.MAX_STAR else GameConstants.MAX_STAR
	if target <= cur:
		return
	OfficeTestSim.set_placement(_config, _picker_slot, _picker_cell, "piece", str(existing.get("unit_id", "")), target)
	_picker_star = target
	if target >= GameConstants.MAX_STAR:
		SfxService.play(SfxService.star4_cue_for(str(existing.get("unit_id", ""))))
	_rebuild_edit_preview()
	_refresh_picker()


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
		var formatter := preload("res://scenes/prep/panels/TreasureChoicePanel.gd").new()
		check.tooltip_text = formatter.effect_text(tid)
		formatter.free()
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
	# 9.19：这里原本是 `_battle_music_player.play()`，而那个 AudioStreamPlayer
	# 在 9.17「BGM 统一走 MusicService、五处页面自带播放器全删」时已被移除 ——
	# 留下的是一个**已不存在的成员**，导致本脚本整个编译不过、离线自测打不开。
	# 改调父类的 `_start_battle_music()`（内部走 MusicService.play + 正确的
	# 战斗 BGM 路径），与正式对战起 BGM 的口径一致。
	_start_battle_music()


func _set_edit_ui_visible(visible_now: bool) -> void:
	if _edit_root != null:
		_edit_root.visible = visible_now
	if not visible_now:
		if _picker_panel != null:
			_picker_panel.visible = false
		if _treasure_panel != null:
			_treasure_panel.visible = false
		if _detail_panel != null:
			_detail_panel.visible = false


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
	# 悬停面板属于演示态，回编辑态必须收掉，否则会盖在格点上。
	_hover_unit_id = ""
	if _stat_panel != null:
		_stat_panel.visible = false
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
	# 放得下 7 列统计表。
	_summary_panel.offset_left = -470
	_summary_panel.offset_right = 470
	_summary_panel.offset_top = -280
	_summary_panel.offset_bottom = 280
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


# ---------------------------------------------------------------------------
# 长按看详细数值(编辑态)
# ---------------------------------------------------------------------------

# 战斗链没有备战链那套长按助手,这里放一份精简版:长按 0.7s 触发,拖动 >8px 取消。
func _attach_long_press(btn: BaseButton, cb: Callable) -> void:
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = 0.7
	btn.add_child(timer)
	btn.set_meta("long_press_timer", timer)
	timer.timeout.connect(func():
		if not bool(btn.get_meta("long_press_cancelled", false)):
			btn.set_meta("long_press_triggered", true)
			cb.call()
	)
	btn.button_down.connect(func():
		btn.set_meta("long_press_start", btn.get_local_mouse_position())
		btn.set_meta("long_press_cancelled", false)
		btn.set_meta("long_press_triggered", false)
		timer.start()
	)
	btn.button_up.connect(func():
		timer.stop()
	)
	btn.gui_input.connect(func(event: InputEvent):
		if not timer.time_left > 0.0:
			return
		if event is InputEventMouseMotion or event is InputEventScreenDrag:
			var start: Vector2 = btn.get_meta("long_press_start", btn.get_local_mouse_position())
			if btn.get_local_mouse_position().distance_to(start) > 8.0:
				btn.set_meta("long_press_cancelled", true)
				timer.stop()
	)


func _build_detail_panel() -> void:
	_detail_panel = PanelContainer.new()
	_detail_panel.add_theme_stylebox_override("panel", _panel_style())
	_detail_panel.anchor_left = 0.5
	_detail_panel.anchor_right = 0.5
	_detail_panel.anchor_top = 0.5
	_detail_panel.anchor_bottom = 0.5
	_detail_panel.offset_left = -250
	_detail_panel.offset_right = 250
	_detail_panel.offset_top = -240
	_detail_panel.offset_bottom = 240
	_detail_panel.visible = false
	_detail_panel.z_index = 220
	add_child(_detail_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	_detail_panel.add_child(col)

	_detail_text = RichTextLabel.new()
	_detail_text.bbcode_enabled = true
	_detail_text.scroll_active = true
	_detail_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail_text.add_theme_font_size_override("normal_font_size", 15)
	_detail_text.add_theme_font_size_override("bold_font_size", 18)
	_detail_text.add_theme_color_override("default_color", Color(0.95, 0.97, 0.92))
	col.add_child(_detail_text)

	var close_btn := _make_text_button(_tt("关闭", "Close"), 16)
	close_btn.custom_minimum_size = Vector2(120, 38)
	close_btn.pressed.connect(func(): _detail_panel.visible = false)
	col.add_child(close_btn)


# ---------------------------------------------------------------------------
# 实时数值面板（演示态，鼠标悬停在棋子上）
# ---------------------------------------------------------------------------

# 9.14 反馈：离线自测要一个「实时数值展示」—— 战斗开始后，鼠标放到棋子上，就显示这枚棋子
# **当前这一帧**的数值面板；移开即收起。
#
# 面板内容全部读父类的 _frame_fighter_by_id：它是 _refresh_visuals() 每帧重建的「本帧存活
# 单位」快照，hp / shield / statuses / skill_stacks / attack_count / damage_dealt 都是从
# 回放帧直接灌进来的真值（见 BattleSimulator 的帧结构）。
#
# ⚠️ 攻击/攻速/暴击/射程 取的是**星级缩放后的 def 基准值**，不是被增益后的实时值：回放帧
# 只记录 uid/pos/hp/alive/… 十几个字段，攻击力与攻速都不在其中（模拟器内部才有一份被
# buff 改过的 fighter.atk）。所以这三行是「面板口径说明」的基准，别当成实时战报。
func _build_stat_panel() -> void:
	_stat_panel = PanelContainer.new()
	_stat_panel.add_theme_stylebox_override("panel", _panel_style())
	_stat_panel.anchor_left = 0.0
	_stat_panel.anchor_right = 0.0
	_stat_panel.anchor_top = 0.5
	_stat_panel.anchor_bottom = 0.5
	_stat_panel.offset_left = 12
	_stat_panel.offset_right = 272
	_stat_panel.offset_top = -170
	_stat_panel.offset_bottom = 170
	# 面板不挡鼠标：鼠标划过它时仍算在棋子上，面板不会因为自己把鼠标“吃掉”而闪没。
	_stat_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stat_panel.visible = false
	_stat_panel.z_index = 205
	add_child(_stat_panel)

	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 6)
	_stat_panel.add_child(col)

	_stat_text = RichTextLabel.new()
	_stat_text.bbcode_enabled = true
	_stat_text.scroll_active = true
	_stat_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stat_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stat_text.add_theme_font_size_override("normal_font_size", 15)
	_stat_text.add_theme_font_size_override("bold_font_size", 18)
	_stat_text.add_theme_color_override("default_color", Color(0.95, 0.97, 0.92))
	col.add_child(_stat_text)


# 覆写父类的悬停回调（BattleRenderer._make_unit_node 给每个单位挂了 mouse_entered /
# mouse_exited）。只在演示态生效；编辑态仍然走「长按格点看详情」那条老路。
func _on_battle_unit_hover(unit_id: String, entered: bool) -> void:
	if _edit_mode or _stat_panel == null:
		return
	if entered:
		_hover_unit_id = unit_id
		_refresh_stat_panel()
		return
	if _hover_unit_id == unit_id:
		_hover_unit_id = ""
		if _hover_unit_id.is_empty():
			_stat_panel.visible = false


# 9.19：离线自测固定「红 A（slot 0）为自身」，让四星技能音等 self-only 音效
# 按正式对战口径只响红方，方便逐一验证每个四星单位的技能音。
# 不依赖 NetworkService.team_local_slot（从组队大厅进来自测时它可能是蓝方槽），
# 也不改 BattleVfx 的线上逻辑——只在本自测场景覆写。布局上「下面三方(红队)=我方、
# 上面三方(蓝队)=敌方」由 build_test_state / grid_sim_pos 保证，这里只定「自身」归属。
func _is_local_owned_unit(sim_uid: String) -> bool:
	var unit: Dictionary = _cue_unit_snapshot(sim_uid)
	for side in ["player", "enemy"]:
		for raw in _state.get(side, []):
			if raw is Dictionary and str(raw.get("uid", "")) == sim_uid:
				unit = raw
	if unit.is_empty():
		return false
	var owner := int(unit.get("owner_slot", -1))
	return owner == 0


func _refresh_stat_panel() -> void:
	if _stat_panel == null or _hover_unit_id.is_empty():
		return
	var value = _frame_fighter_by_id.get(_hover_unit_id)
	if typeof(value) != TYPE_DICTIONARY:
		# 这枚棋子本帧已经阵亡/离场：不要把上一帧的旧数字留在屏幕上。
		_stat_panel.visible = false
		return
	var f: Dictionary = value
	var def_value = f.get("def", {})
	var def: Dictionary = def_value if typeof(def_value) == TYPE_DICTIONARY else {}
	var color := _fighter_display_color(f)
	var lines: Array[String] = []
	lines.append("[color=#%s][b]%s[/b][/color] ★%d" % [
		color.to_html(false), _fighter_display_name(f), int(f.get("star", def.get("star", 1)))])
	lines.append("%s  %d / %d" % [_tt("生命", "HP"), int(f.get("hp", 0)), int(f.get("max_hp", 1))])
	if int(f.get("shield", 0)) > 0:
		lines.append("%s  %d" % [_tt("护盾", "Shield"), int(f.get("shield", 0))])
	lines.append("%s  %d   %s  %.2f" % [
		_tt("攻击", "ATK"), _fighter_atk(f), _tt("攻速", "AS"), float(def.get("attack_speed", 1.0))])
	lines.append("%s  %d   %s  %.0f%%" % [
		_tt("防御", "DEF"), int(def.get("def", 0)), _tt("暴击", "Crit"), float(def.get("crit", 0.0)) * 100.0])
	lines.append("%s  %s   %s  %d" % [
		_tt("射程", "Range"), str(def.get("range", 1)), _tt("技能层数", "Stacks"), int(f.get("skill_stacks", 0))])
	lines.append("%s  %d   %s  %d" % [
		_tt("攻击次数", "Hits"), int(f.get("attack_count", 0)), _tt("已造成伤害", "Damage"), _fighter_damage_dealt(f)])
	# 技能冷却：skill_ready 是「模拟时钟」上的绝对时刻。回放播放时 _state.elapsed 恒为 0
	# （只有本地模拟才推进它），所以这里用帧号自己换算当前模拟时刻，否则算出来永远是整段 CD。
	var sim_time := float(_replay_frame) * SIM_TICK_SEC
	if float(f.get("skill_ready", 0.0)) > sim_time:
		lines.append("%s  %.1fs" % [_tt("技能冷却", "Skill CD"), float(f.get("skill_ready", 0.0)) - sim_time])
	var statuses_value = f.get("statuses", {})
	var statuses: Dictionary = statuses_value if typeof(statuses_value) == TYPE_DICTIONARY else {}
	if statuses.is_empty():
		lines.append(_tt("状态：无", "Statuses: none"))
	else:
		lines.append("[b]%s[/b]" % _tt("状态", "Statuses"))
		var keys := statuses.keys()
		keys.sort()
		for key in keys:
			var status_entry = statuses[key]
			var remaining := 0.0
			if typeof(status_entry) == TYPE_DICTIONARY:
				remaining = float((status_entry as Dictionary).get("remaining", 0.0))
			elif typeof(status_entry) == TYPE_FLOAT or typeof(status_entry) == TYPE_INT:
				remaining = float(status_entry)
			if remaining <= 0.0:
				continue
			lines.append("  · %s  %s%s" % [
				BattleStatsFormat.status_display_name(str(key)),
				BattleStatsFormat.format_seconds(remaining),
				"s" if UnitDetailFormat.is_en() else "秒"])
	_stat_text.text = "\n".join(lines)
	_stat_panel.visible = true


# 长按格点:弹出该棋子的详细数值。数值口径与模拟器一致(走 OfficeTestSim 同一套 def/星级)。
func _show_unit_detail(slot: int, cell: int) -> void:
	if not _edit_mode:
		return
	var p := OfficeTestSim.placement_at(_config, slot, cell)
	if p.is_empty():
		return
	var def := OfficeTestSim.def_for_placement(p)
	if def.is_empty():
		return
	var kind := str(p.get("kind", "piece"))
	var star := OfficeTestSim.star_for_placement(p)
	var c := GameConstants.team_slot_color(slot)
	var head := "[color=#%s][b]%s[/b][/color] · %s" % [c.to_html(false), _slot_display_name(slot), _kind_display_name(kind)]
	_picker_panel.visible = false
	_treasure_panel.visible = false
	_summary_panel.visible = false
	_detail_text.text = "%s\n\n%s" % [head, UnitDetailFormat.format_unit_def(def, star)]
	_detail_panel.visible = true


func _build_summary_data() -> Dictionary:
	var result := _result
	# 统计口径与主游戏「上局统计」一致:直接用模拟器产出的 unit_stats。
	# 存活状态取自回放最后一帧(unit_stats 本身不记录生死)。
	var alive_by_uid: Dictionary = {}
	var frames: Array = _replay.get("frames", [])
	if not frames.is_empty() and typeof(frames[frames.size() - 1]) == TYPE_ARRAY:
		for entry in frames[frames.size() - 1]:
			if typeof(entry) == TYPE_ARRAY and (entry as Array).size() >= 5:
				alive_by_uid[str(entry[0])] = bool(entry[4])
	var stats_value = result.get("unit_stats", {})
	var rows: Array = []
	if typeof(stats_value) == TYPE_DICTIONARY:
		for uid in (stats_value as Dictionary).keys():
			var entry_value = (stats_value as Dictionary)[uid]
			if typeof(entry_value) != TYPE_DICTIONARY:
				continue
			var row: Dictionary = (entry_value as Dictionary).duplicate(true)
			row["alive"] = bool(alive_by_uid.get(str(uid), false))
			rows.append(row)
	# 造成伤害降序;并列时按槽位、名字稳定排序。
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var da := int(a.get("damage_dealt", 0))
		var db := int(b.get("damage_dealt", 0))
		if da != db:
			return da > db
		var sa := int(a.get("owner_slot", -1))
		var sb := int(b.get("owner_slot", -1))
		if sa != sb:
			return sa < sb
		return str(a.get("name", "")) < str(b.get("name", ""))
	)
	return {
		"player_wins": bool(result.get("player_wins", false)),
		"elapsed": float(result.get("elapsed", 0.0)),
		"player_alive": int(result.get("player_alive", 0)),
		"enemy_alive": int(result.get("enemy_alive", 0)),
		"rows": rows,
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
	# 与主游戏「上局统计」同款 7 列表格,一张总表按槽位颜色区分六方。
	var rows: Array = data.get("rows", [])
	lines.append("[b]%s[/b]" % _tt("单位统计（按造成伤害排序）", "Unit Stats (by damage dealt)"))
	lines.append("")
	lines.append("[table=7]")
	for header in [
		_tt("单位", "Unit"), _tt("位置", "Pos"), _tt("造成伤害", "Dmg Dealt"),
		_tt("承受伤害", "Dmg Taken"), _tt("治疗", "Healing"),
		_tt("负面效果", "Debuffs"), _tt("正面效果", "Buffs"),
	]:
		lines.append("[cell %s][b]%s[/b][/cell]" % [CELL_PAD, header])
	if rows.is_empty():
		for value in [_tt("无", "None"), "-", "0", "0", "0", _tt("无", "None"), _tt("无", "None")]:
			lines.append("[cell %s]%s[/cell]" % [CELL_PAD, value])
	else:
		for row in rows:
			var dict: Dictionary = row
			var dead_mark := "" if bool(dict.get("alive", false)) else _tt("(阵亡)", "(dead)")
			for value in [
				BattleStatsFormat.stats_display_name(dict) + dead_mark,
				BattleStatsFormat.stats_display_position(dict),
				int(dict.get("damage_dealt", 0)),
				int(dict.get("damage_taken", 0)),
				int(dict.get("healing_done", 0)),
				BattleStatsFormat.sanitize_stats_cell(BattleStatsFormat.format_status_bucket(dict.get("debuffs", {}))),
				BattleStatsFormat.sanitize_stats_cell(BattleStatsFormat.format_status_bucket(dict.get("buffs", {}))),
			]:
				lines.append("[cell %s]%s[/cell]" % [CELL_PAD, BattleStatsFormat.stats_color_cell(dict, str(value))])
	lines.append("[/table]")
	_summary_text.text = "\n".join(lines)
	if _detail_panel != null:
		_detail_panel.visible = false
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
