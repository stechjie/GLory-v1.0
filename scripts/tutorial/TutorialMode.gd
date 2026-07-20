extends Node

signal completed
signal skip_requested

const GOLD_TEXT := "∞"
const TUTORIAL_GOLD := 9999
const TUTORIAL_HP := 10

enum Step {
	BUY_3,
	PLACE_3,
	START_PVE_1,
	UPGRADE_2,
	START_PVE_2,
	TAKE_TREASURE_1,
	UPGRADE_3,
	UPGRADE_OTHERS,
	BOND_HINT,
	VIEW_TREASURE,
	START_BOSS,
	TAKE_TREASURE_2,
	HIRE_MERC,
	FILL_7,
	FORMATION_HP,
	START_PVP,
	DONE,
}

# 放大2倍后的向下箭头（字号84）比原来高，往上多抬一些，箭尖仍指向目标顶部。
const ARROW_DOWN_Y_OFFSET := -100.0

var active := false
var step: int = Step.BUY_3
var bought_units := 0
# 教学 PVP 步的伪造对手棋盘（原先借用 NetworkService.opponent_board_snapshot，
# 1v1 联机删除后由教学模式自持，BattleSimulator 的教学 PVP 路径从这里读）。
var opponent_snapshot: Dictionary = {}
var _prep: Control
var _overlay: Control
var _arrow: Label
var _bubble: PanelContainer
var _text: Label
var _continue_btn: Button
var _hotspot: Button
var _skip_btn: Button
var _skip_confirm: ColorRect

const START_SHOP := ["human_militia", "human_archer", "human_merchant", "human_swordsman"]
const FILL_SHOP := ["human_swordsman", "human_mage", "human_cleric", "human_death_servant"]
# 升星步：商店铺满玩家要凑的同名棋子，让玩家自己买 + 刷新
const UPGRADE_2_SHOP := ["human_militia", "human_militia", "human_militia", "human_militia"]
const UPGRADE_OTHERS_SHOP := ["human_archer", "human_archer", "human_merchant", "human_merchant"]
const PVP_OPPONENT := ["human_militia", "human_archer", "human_merchant", "human_swordsman", "human_mage"]
const TREASURE_1 := ["def_iron_wall", "atk_blood_pact", "ctrl_shockwave"]
const TREASURE_2 := ["atk_fury_roster", "def_formation_heal", "money_discount"]

func start() -> void:
	active = true
	step = Step.BUY_3
	bought_units = 0
	GameState.reset_run()
	GameState.tutorial_mode = true
	GameState.player_formation_hp = TUTORIAL_HP
	GameState.enemy_formation_hp = TUTORIAL_HP
	GameState.gold = TUTORIAL_GOLD
	_apply_shop(START_SHOP)

func finish() -> void:
	active = false
	GameState.tutorial_mode = false
	opponent_snapshot = {}
	_detach()
	completed.emit()

func attach(prep: Control) -> void:
	if not active:
		return
	_prep = prep
	_ensure_overlay()
	sync()
	update_overlay()

func sync() -> void:
	if not active:
		return
	GameState.gold = TUTORIAL_GOLD
	if step == Step.BUY_3 and bought_units >= 3:
		step = Step.PLACE_3
	if step == Step.PLACE_3 and GameState.normal_unit_count() >= 3:
		step = Step.START_PVE_1
	if step == Step.UPGRADE_2 and _unit_star("human_militia") >= 2:
		step = Step.START_PVE_2
	if step == Step.TAKE_TREASURE_1 and GameState.owned_treasures.size() >= 1:
		_grant_units("human_militia", 2, 2)
		step = Step.UPGRADE_3
		_refresh_prep()
	if step == Step.UPGRADE_3 and _unit_star("human_militia") >= 3:
		# 弓手/商人升 2 星也让玩家自己在商店买，不再直接发材料。
		_apply_shop(UPGRADE_OTHERS_SHOP)
		step = Step.UPGRADE_OTHERS
		_refresh_prep()
	if step == Step.UPGRADE_OTHERS and _unit_star("human_archer") >= 2 and _unit_star("human_merchant") >= 2:
		step = Step.BOND_HINT
	if step == Step.TAKE_TREASURE_2 and GameState.owned_treasures.size() >= 2:
		step = Step.HIRE_MERC
	if step == Step.HIRE_MERC and _mercenary_count() >= 2:
		if _prep != null and _prep.has_method("_close_merc_picker"):
			_prep.call("_close_merc_picker")
		_apply_shop(FILL_SHOP)
		step = Step.FILL_7
	if step == Step.FILL_7 and GameState.normal_unit_count() >= 7:
		step = Step.FORMATION_HP
	update_overlay()

func can_start_battle() -> bool:
	return step in [Step.START_PVE_1, Step.START_PVE_2, Step.START_BOSS, Step.START_PVP]

func follow_arrow_hint() -> String:
	return _t("先完成箭头指示的操作。", "Follow the arrow first.")

func begin_battle() -> bool:
	if not can_start_battle():
		if _prep != null and _prep.has_method("show_message"):
			_prep.show_message(follow_arrow_hint())
		return false
	if step == Step.START_PVP:
		opponent_snapshot = _tutorial_opponent_snapshot()
	_detach()
	return true

func battle_kind() -> String:
	match step:
		Step.START_BOSS:
			return "boss"
		Step.START_PVP:
			return "pvp"
		_:
			return "pve"

func pve_enemy_count() -> int:
	return 4 if step == Step.START_PVE_2 else 3

func after_battle(result: Dictionary) -> void:
	match step:
		Step.START_PVE_1:
			# 升 2 星的民兵材料让玩家自己在商店买，不再直接发。
			_apply_shop(UPGRADE_2_SHOP)
			step = Step.UPGRADE_2
		Step.START_PVE_2:
			_start_treasure(TREASURE_1)
			step = Step.TAKE_TREASURE_1
		Step.START_BOSS:
			_start_treasure(TREASURE_2)
			step = Step.TAKE_TREASURE_2
		Step.START_PVP:
			result["kind"] = "pvp"
			result["player_wins"] = true
			result["enemy_alive"] = 0
			result["enemy_hp_current"] = 0
			GameState.enemy_formation_hp = 0
			step = Step.DONE
	GameState.gold = TUTORIAL_GOLD

func current_text() -> String:
	match step:
		Step.BUY_3:
			return _t("点击下方「商店」按钮打开商店，点击商店棋子，再点击采购按钮。买到的棋子会先进入待命区。已采购：%d/3" % mini(bought_units, 3), "Tap the Shop button at the bottom to open the shop, tap a unit, then tap Buy. Bought units go to standby first. Bought: %d/3" % mini(bought_units, 3))
		Step.PLACE_3:
			return _t("从待命区把 3 个棋子拖到棋盘。棋盘上的棋子才会参战。", "Drag 3 units from standby onto the board. Only board units fight.")
		Step.START_PVE_1:
			return _t("已经上阵 3 个棋子，点击开始战斗，打 3 个小怪。", "You placed 3 units. Start battle to fight 3 monsters.")
		Step.UPGRADE_2:
			return _t("在商店买 1 个「民兵」（不够就点刷新），拖到场上的民兵身上，升到 2 星。", "Buy 1 Militia from the shop (refresh if needed), then drag it onto your board Militia to reach 2-star.")
		Step.START_PVE_2:
			return _t("主力已经 2 星了。再开始战斗，这次打 4 个小怪。", "Your main unit is 2-star. Start battle again against 4 monsters.")
		Step.TAKE_TREASURE_1:
			return _t("选择一个宝藏。拿到的宝藏会显示在左下角。", "Choose a treasure. Owned treasures appear at the bottom-left.")
		Step.UPGRADE_3:
			return _t("现在给你 2 个 2 星材料。拖 1 个材料到主力身上，升到 3 星。", "You now have two 2-star copies. Drag one copy onto your main unit to make it 3-star.")
		Step.UPGRADE_OTHERS:
			return _t("在商店买弓手和商人各 1 个（不够就刷新），分别拖到场上的同名棋子上，升到 2 星。", "Buy 1 Archer and 1 Merchant from the shop (refresh if needed), then drag each onto its matching board unit to reach 2-star.")
		Step.BOND_HINT:
			return _t("同族数量够了会激活羁绊。看看左侧的羁绊效果，点一下继续。", "Matching races activate bonds. Check the bond effects on the left, then tap to continue.")
		Step.VIEW_TREASURE:
			return _t("点击左下角的宝藏图标，看看已获得宝藏的效果。", "Tap the treasure icon at the bottom-left to see your treasure's effect.")
		Step.START_BOSS:
			return _t("阵容变强了，点击开始战斗挑战 Boss。", "Your team is stronger. Start battle to challenge the Boss.")
		Step.TAKE_TREASURE_2:
			return _t("Boss 打完后，再选择一个宝藏强化阵容。", "After the Boss, choose another treasure to strengthen your team.")
		Step.HIRE_MERC:
			return _t("打开佣兵面板，召唤 2 个佣兵。佣兵是额外战力，但不算羁绊。", "Open the mercenary panel and hire 2 mercenaries. They are extra power but do not count for bonds.")
		Step.FILL_7:
			return _t("PVP 前把普通棋子放满 7 个。", "Before PVP, fill the board with 7 normal units.")
		Step.FORMATION_HP:
			return _t("看上方血条——教学局法阵 HP 是 10，把敌方法阵打到归零就胜利。点一下继续。", "See the HP bar above — tutorial formation HP is 10. Bring the enemy's to 0 to win. Tap to continue.")
		Step.START_PVP:
			return _t("点击开始战斗进入 PVP，赢下最后一战。", "Start battle for PVP and win the final fight.")
		_:
			return _t("教学胜利。", "Tutorial victory.")

func update_overlay() -> void:
	if not active or _prep == null or _overlay == null:
		return
	var target := _target_control()
	var rect := Rect2(Vector2(540, 290), Vector2(200, 80))
	if target is Control and target.is_inside_tree():
		rect = (target as Control).get_global_rect()
	_apply_arrow(rect)
	_bubble.position = _bubble_position(rect)
	_text.text = current_text()
	_continue_btn.visible = false
	_bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_position_hotspot(rect)

func _apply_arrow(rect: Rect2) -> void:
	# BOND_HINT：箭头 ◀ 放在羁绊面板右侧、指向左边的面板；其余步用向下 ▼。
	if step == Step.BOND_HINT:
		_arrow.text = "◀"
		_arrow.position = Vector2(rect.position.x + rect.size.x + 8.0, rect.position.y + rect.size.y * 0.5 - 48.0)
	else:
		_arrow.text = "▼"
		_arrow.position = rect.position + Vector2(rect.size.x * 0.5 - 36.0, ARROW_DOWN_Y_OFFSET)

func _position_hotspot(rect: Rect2) -> void:
	# 点击推进的步用透明热区拦截点击（不再依赖会被子节点吞掉的 gui_input）。
	if _hotspot == null:
		return
	match step:
		Step.BOND_HINT, Step.VIEW_TREASURE:
			_hotspot.visible = true
			var pad := 10.0
			_hotspot.position = rect.position - Vector2(pad, pad)
			_hotspot.size = rect.size + Vector2(pad, pad) * 2.0
		Step.FORMATION_HP:
			# 讲解 HP 后，点屏幕任意处一次即可继续。
			_hotspot.visible = true
			_hotspot.position = Vector2.ZERO
			_hotspot.size = _overlay.size
		_:
			_hotspot.visible = false

func _on_skip_pressed() -> void:
	if not active:
		return
	_show_skip_confirm()

func _show_skip_confirm() -> void:
	if _overlay == null or not is_instance_valid(_overlay):
		return
	if _skip_confirm != null and is_instance_valid(_skip_confirm):
		return
	# 半透明遮罩 + 居中确认框（防手滑）。
	_skip_confirm = ColorRect.new()
	_skip_confirm.name = "TutorialSkipConfirm"
	_skip_confirm.color = Color(0.0, 0.0, 0.0, 0.6)
	_skip_confirm.mouse_filter = Control.MOUSE_FILTER_STOP
	_skip_confirm.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(_skip_confirm)

	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.custom_minimum_size = Vector2(420, 0)
	panel.offset_left = -210
	panel.offset_top = -90
	panel.offset_right = 210
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.05, 0.06, 0.08, 0.96)
	panel_style.border_color = Color(1.0, 0.86, 0.28, 0.95)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(10)
	panel_style.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", panel_style)
	_skip_confirm.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)
	var msg := Label.new()
	msg.text = _t("确定跳过整段新手教学吗？将直接回到主菜单。", "Skip the whole tutorial and return to the main menu?")
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.add_theme_font_size_override("font_size", 18)
	msg.add_theme_color_override("font_color", Color(0.98, 0.96, 0.86))
	box.add_child(msg)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 20)
	box.add_child(row)
	var cancel_btn := Button.new()
	cancel_btn.text = _t("取消", "Cancel")
	cancel_btn.focus_mode = Control.FOCUS_NONE
	cancel_btn.custom_minimum_size = Vector2(140, 40)
	cancel_btn.pressed.connect(_close_skip_confirm)
	row.add_child(cancel_btn)
	var confirm_btn := Button.new()
	confirm_btn.text = _t("跳过", "Skip")
	confirm_btn.focus_mode = Control.FOCUS_NONE
	confirm_btn.custom_minimum_size = Vector2(140, 40)
	confirm_btn.pressed.connect(_on_skip_confirmed)
	row.add_child(confirm_btn)

func _close_skip_confirm() -> void:
	if _skip_confirm != null and is_instance_valid(_skip_confirm):
		_skip_confirm.queue_free()
	_skip_confirm = null

func _on_skip_confirmed() -> void:
	_close_skip_confirm()
	if not active:
		return
	skip_requested.emit()

func _on_hotspot_pressed() -> void:
	match step:
		Step.BOND_HINT:
			step = Step.VIEW_TREASURE
		Step.VIEW_TREASURE:
			step = Step.FORMATION_HP
		Step.FORMATION_HP:
			step = Step.START_PVP if GameState.normal_unit_count() >= 7 and _mercenary_count() >= 2 else Step.START_BOSS
		_:
			return
	update_overlay()

func record_shop_purchase() -> void:
	if active and step == Step.BUY_3:
		bought_units += 1
		sync()

func _bubble_position(target_rect: Rect2) -> Vector2:
	var margin := 18.0
	var bubble_size := Vector2(420.0, 126.0)
	var max_x := maxf(margin, _overlay.size.x - bubble_size.x - margin)
	var max_y := maxf(margin, _overlay.size.y - bubble_size.y - margin)
	if step == Step.BOND_HINT:
		# 箭头 ◀ 指向左侧面板，解释文字放在箭头右侧。
		var bx := target_rect.position.x + target_rect.size.x + 46.0
		var by := target_rect.position.y + target_rect.size.y * 0.5 - bubble_size.y * 0.5
		return Vector2(clampf(bx, margin, max_x), clampf(by, margin, max_y))
	# 向下箭头的步：气泡放在箭头「上方」，整体不压住箭头和目标（修复升星箭头被黑字挡）。
	var x := clampf(target_rect.position.x + target_rect.size.x * 0.5 - bubble_size.x * 0.5, margin, max_x)
	var arrow_top := target_rect.position.y + ARROW_DOWN_Y_OFFSET - 8.0
	var y := arrow_top - bubble_size.y
	if y < margin:
		# 上方放不下就落到目标下方，仍然不与箭头重叠。
		y = target_rect.position.y + target_rect.size.y + 18.0
	return Vector2(x, clampf(y, margin, max_y))

func _target_control() -> Control:
	if _prep == null:
		return null
	match step:
		Step.BUY_3:
			var selected := int(_prep.get("_selected_shop"))
			if _shop_index_available(selected):
				return _prep.get("_buy_shop_button") as Control
			return _first_available_shop_control()
		Step.PLACE_3:
			return _first_empty_board_control_middle() if _placing_from_bench() else _first_occupied_bench_control()
		Step.UPGRADE_2, Step.UPGRADE_3, Step.UPGRADE_OTHERS:
			# UPGRADE_3 用自动发的 2 星材料（一进来场上1+待命2=3个），直接教拖拽。
			if step == Step.UPGRADE_3:
				return _upgrade_target_control() if _holding_upgrade_piece() else _upgrade_material_control()
			# 2-star steps (player buys from shop): only point at the standby area to
			# teach dragging once enough copies are gathered (board + standby); until
			# then keep pointing at the shop to buy the next copy.
			if _upgrade_total_copies() >= GameState.copies_to_upgrade(_upgrade_star()):
				return _upgrade_target_control() if _holding_upgrade_piece() else _upgrade_material_control()
			return _upgrade_shop_control()
		Step.START_PVE_1, Step.START_PVE_2, Step.START_BOSS, Step.START_PVP:
			return _prep.get("_start_battle_button") as Control
		Step.FORMATION_HP:
			return _prep.get("_enemy_formation_bar") as Control
		Step.TAKE_TREASURE_1, Step.TAKE_TREASURE_2:
			var row := _prep.get("_treasure_choice_row") as Control
			return row.get_child(0) as Control if row != null and row.get_child_count() > 0 else row
		Step.HIRE_MERC:
			if not bool(_prep.get("_merc_picker_open")):
				return _prep.get("_merc_button") as Control
			var grid := _prep.get("_merc_overlay_grid") as Control
			if grid != null and grid.get_child_count() > 0:
				return grid.get_child(0) as Control
			return _prep.get("_merc_button") as Control
		Step.FILL_7:
			if _owned_normal_count() > GameState.normal_unit_count():
				return _first_empty_board_control() if _placing_from_bench() else _first_occupied_bench_control()
			var selected := int(_prep.get("_selected_shop"))
			if _shop_index_available(selected):
				return _prep.get("_buy_shop_button") as Control
			return _first_available_shop_control()
		Step.BOND_HINT:
			return _prep.get("_left_panel") as Control
		Step.VIEW_TREASURE:
			return _treasure_logo_control()
	return null

func _treasure_logo_control() -> Control:
	var box := _prep.get("_owned_treasure_box") as Control
	if box != null and box.get_child_count() > 0 and box.get_child(0) is Control:
		return box.get_child(0) as Control
	return box

func _upgrade_shop_control() -> Control:
	var selected := int(_prep.get("_selected_shop"))
	if _shop_index_available(selected):
		return _prep.get("_buy_shop_button") as Control
	return _first_available_shop_control()

# Total copies of the target unit at the target star across board + standby.
# Compared against GameState.copies_to_upgrade() to decide whether the upgrade
# arrow keeps pointing at the shop (not enough) or moves to standby (enough).
func _upgrade_total_copies() -> int:
	var id := _upgrade_id()
	var star := _upgrade_star()
	var count := 0
	for cell in GameState.board_slots + GameState.bench_slots:
		if _cell_matches_upgrade(cell, id, star):
			count += 1
	return count

func _first_empty_board_control_middle() -> Control:
	# 引导摆放到中间排：优先第 2 排（中间偏前），再第 1 排，最后任意空位。
	var buttons := _prep.get("_board_buttons") as Array
	for pref_row in [2, 1]:
		for col in GameConstants.BOARD_COLUMNS:
			var i: int = int(pref_row) * GameConstants.BOARD_COLUMNS + col
			if i >= 0 and i < GameState.board_slots.size() and GameState.board_slots[i] == null:
				var item = buttons[i]
				if item is Control and (item as Control).visible:
					return item as Control
	return _first_empty_board_control()

func _ensure_overlay() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		return
	_overlay = Control.new()
	_overlay.name = "TutorialOverlay"
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.z_index = 500
	_prep.add_child(_overlay)

	_arrow = Label.new()
	_arrow.text = "▼"
	_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arrow.add_theme_font_size_override("font_size", 84)
	_arrow.add_theme_color_override("font_color", Color(0.95, 0.13, 0.10))
	_arrow.add_theme_color_override("font_outline_color", Color(0.12, 0.0, 0.0))
	_arrow.add_theme_constant_override("outline_size", 8)
	_overlay.add_child(_arrow)

	_bubble = PanelContainer.new()
	_bubble.mouse_filter = Control.MOUSE_FILTER_STOP
	_bubble.custom_minimum_size = Vector2(400, 96)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.06, 0.88)
	style.border_color = Color(1.0, 0.86, 0.28, 0.95)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	_bubble.add_theme_stylebox_override("panel", style)
	_overlay.add_child(_bubble)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 10)
	_bubble.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)
	_text = Label.new()
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.add_theme_font_size_override("font_size", 18)
	_text.add_theme_color_override("font_color", Color(0.98, 0.96, 0.86))
	box.add_child(_text)
	_continue_btn = Button.new()
	_continue_btn.text = _t("继续", "Continue")
	_continue_btn.custom_minimum_size = Vector2(120, 34)
	_continue_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_continue_btn.visible = false
	_continue_btn.pressed.connect(_on_continue_pressed)
	box.add_child(_continue_btn)

	# 透明点击热区：覆盖在目标上，点一下推进（BOND_HINT / VIEW_TREASURE / FORMATION_HP）。
	_hotspot = Button.new()
	_hotspot.name = "TutorialHotspot"
	_hotspot.flat = true
	_hotspot.focus_mode = Control.FOCUS_NONE
	_hotspot.mouse_filter = Control.MOUSE_FILTER_STOP
	_hotspot.modulate = Color(1, 1, 1, 0)   # 不可见但可点击
	_hotspot.visible = false
	_hotspot.pressed.connect(_on_hotspot_pressed)
	_overlay.add_child(_hotspot)

	# 「跳过教学」按钮：固定在左上角，任何步都能一键跳过整段教学。
	_skip_btn = Button.new()
	_skip_btn.name = "TutorialSkipButton"
	_skip_btn.text = _t("跳过教学", "Skip Tutorial")
	_skip_btn.focus_mode = Control.FOCUS_NONE
	_skip_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	_skip_btn.anchor_left = 0.0
	_skip_btn.anchor_top = 0.0
	_skip_btn.anchor_right = 0.0
	_skip_btn.anchor_bottom = 0.0
	_skip_btn.position = Vector2(16, 44)
	_skip_btn.custom_minimum_size = Vector2(112, 34)
	_skip_btn.add_theme_font_size_override("font_size", 15)
	_skip_btn.add_theme_color_override("font_color", Color(0.98, 0.96, 0.86))
	var skip_style := StyleBoxFlat.new()
	skip_style.bg_color = Color(0.04, 0.05, 0.06, 0.88)
	skip_style.border_color = Color(1.0, 0.86, 0.28, 0.95)
	skip_style.set_border_width_all(2)
	skip_style.set_corner_radius_all(8)
	skip_style.set_content_margin_all(6)
	_skip_btn.add_theme_stylebox_override("normal", skip_style)
	_skip_btn.add_theme_stylebox_override("hover", skip_style)
	_skip_btn.add_theme_stylebox_override("pressed", skip_style)
	_skip_btn.add_theme_stylebox_override("focus", skip_style)
	_skip_btn.pressed.connect(_on_skip_pressed)
	_overlay.add_child(_skip_btn)

	var tween := _arrow.create_tween()
	tween.set_loops()
	tween.tween_property(_arrow, "modulate:a", 0.35, 0.45)
	tween.tween_property(_arrow, "modulate:a", 1.0, 0.45)

func _detach() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()
	_overlay = null
	_prep = null

func tutorial_shop_ids() -> Array:
	# 刷新商店时按当前步铺货：升星步铺满要凑的同名棋子。
	match step:
		Step.UPGRADE_2, Step.UPGRADE_3:
			return UPGRADE_2_SHOP
		Step.UPGRADE_OTHERS:
			return UPGRADE_OTHERS_SHOP
		_:
			return FILL_SHOP if step >= Step.HIRE_MERC else START_SHOP

func _apply_shop(ids: Array) -> void:
	var offers: Array = []
	for id in ids:
		var def := _unit_def(str(id))
		if not def.is_empty():
			offers.append(def)
	GameState.shop_offers.resize(GameState.SHOP_UNIT_SLOTS)
	GameState.shop_sold.resize(GameState.SHOP_UNIT_SLOTS)
	for i in GameState.SHOP_UNIT_SLOTS:
		GameState.shop_offers[i] = offers[i % offers.size()].duplicate(true) if not offers.is_empty() else {}
		GameState.shop_sold[i] = false

func _grant_units(id: String, count: int, star: int = 1) -> void:
	var def := _unit_def(id)
	if def.is_empty():
		return
	for n in count:
		var index := GameState.bench_slots.find(null)
		if index < 0:
			return
		GameState.bench_slots[index] = {"id": id, "star": star, "def": def.duplicate(true)}

func _on_continue_pressed() -> void:
	if step == Step.BOND_HINT:
		step = Step.START_BOSS
	elif step == Step.FORMATION_HP:
		step = Step.START_PVP
	update_overlay()

func _refresh_prep() -> void:
	if _prep != null and _prep.has_method("_refresh_all"):
		_prep.call_deferred("_refresh_all")

func _start_treasure(ids: Array) -> void:
	GameState.pending_treasure = {"active": true, "round": GameState.round_index, "candidates": ids.duplicate(), "refresh_index": 0}

func _tutorial_opponent_snapshot() -> Dictionary:
	var board := []
	board.resize(GameConstants.CELL_COUNT)
	board.fill(null)
	var slots := [1, 2, 5, 6, 9]
	for i in mini(PVP_OPPONENT.size(), slots.size()):
		var id := str(PVP_OPPONENT[i])
		var def := _unit_def(id)
		if not def.is_empty():
			board[int(slots[i])] = {"id": id, "star": 1, "def": def}
	return {
		"version": NetProtocol.SNAPSHOT_VERSION,
		"round": GameState.round_index,
		"board": NetProtocol.sanitize_board(board),
		"mercenaries": [],
		"treasures": [],
		"syn": {},
	}

func _unit_def(id: String) -> Dictionary:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	for unit in units:
		if str((unit as Dictionary).get("id", "")) == id:
			return (unit as Dictionary).duplicate(true)
	return {}

func _owned_normal_count() -> int:
	var count := 0
	for cell in GameState.board_slots + GameState.bench_slots:
		if typeof(cell) == TYPE_DICTIONARY:
			count += 1
	return count

func _unit_star(id: String) -> int:
	var best := 0
	for cell in GameState.board_slots + GameState.bench_slots:
		if typeof(cell) == TYPE_DICTIONARY and str((cell as Dictionary).get("id", "")) == id:
			best = maxi(best, int((cell as Dictionary).get("star", 1)))
	return best

func _mercenary_count() -> int:
	var count := 0
	for cell in GameState.mercenary_slots:
		if cell != null:
			count += 1
	return count

func _first_live_control(items: Array) -> Control:
	for item in items:
		if item is Control and (item as Control).visible:
			return item as Control
	return null

func _first_occupied_bench_control() -> Control:
	var buttons := _prep.get("_bench_buttons") as Array
	for i in buttons.size():
		if i < GameState.bench_slots.size() and GameState.bench_slots[i] != null:
			var item = buttons[i]
			if item is Control and (item as Control).visible:
				return item as Control
	return null

func _first_empty_board_control() -> Control:
	var buttons := _prep.get("_board_buttons") as Array
	for i in buttons.size():
		if i < GameState.board_slots.size() and GameState.board_slots[i] == null:
			var item = buttons[i]
			if item is Control and (item as Control).visible:
				return item as Control
	return null

func _placing_from_bench() -> bool:
	if _prep == null:
		return false
	if int(_prep.get("_selected_bench")) >= 0:
		return true
	var payload = _prep.get("_active_drag_payload")
	return typeof(payload) == TYPE_DICTIONARY and str((payload as Dictionary).get("kind", "")) == "bench"

func _upgrade_material_control() -> Control:
	var id := _upgrade_id()
	var star := _upgrade_star()
	var buttons := _prep.get("_bench_buttons") as Array
	for i in buttons.size():
		if i < GameState.bench_slots.size() and _cell_matches_upgrade(GameState.bench_slots[i], id, star):
			var item = buttons[i]
			if item is Control and (item as Control).visible:
				return item as Control
	return _first_occupied_bench_control()

func _upgrade_target_control() -> Control:
	var id := _upgrade_id()
	var star := _upgrade_star()
	var material_index := _held_upgrade_bench_index()
	var board_buttons := _prep.get("_board_buttons") as Array
	for i in board_buttons.size():
		if i < GameState.board_slots.size() and _cell_matches_upgrade(GameState.board_slots[i], id, star):
			var item = board_buttons[i]
			if item is Control and (item as Control).visible:
				return item as Control
	var bench_buttons := _prep.get("_bench_buttons") as Array
	for i in bench_buttons.size():
		if i == material_index:
			continue
		if i < GameState.bench_slots.size() and _cell_matches_upgrade(GameState.bench_slots[i], id, star):
			var item = bench_buttons[i]
			if item is Control and (item as Control).visible:
				return item as Control
	return _upgrade_material_control()

func _holding_upgrade_piece() -> bool:
	return _held_upgrade_bench_index() >= 0

func _held_upgrade_bench_index() -> int:
	var id := _upgrade_id()
	var star := _upgrade_star()
	var selected := int(_prep.get("_selected_bench"))
	if selected >= 0 and selected < GameState.bench_slots.size() and _cell_matches_upgrade(GameState.bench_slots[selected], id, star):
		return selected
	var payload = _prep.get("_active_drag_payload")
	if typeof(payload) == TYPE_DICTIONARY and str((payload as Dictionary).get("kind", "")) == "bench":
		var index := int((payload as Dictionary).get("index", -1))
		if index >= 0 and index < GameState.bench_slots.size() and _cell_matches_upgrade(GameState.bench_slots[index], id, star):
			return index
	return -1

func _upgrade_id() -> String:
	if step == Step.UPGRADE_OTHERS:
		return "human_archer" if _unit_star("human_archer") < 2 else "human_merchant"
	return "human_militia"

func _upgrade_star() -> int:
	return 2 if step == Step.UPGRADE_3 else 1

func _cell_matches_upgrade(cell: Variant, id: String, star: int) -> bool:
	return typeof(cell) == TYPE_DICTIONARY and str((cell as Dictionary).get("id", "")) == id and int((cell as Dictionary).get("star", 1)) == star

func _first_available_shop_control() -> Control:
	var buttons := _prep.get("_shop_buttons") as Array
	if buttons == null:
		return null
	for i in buttons.size():
		if _shop_index_available(i):
			var item = buttons[i]
			if item is Control and (item as Control).visible:
				return item as Control
	return null

func _shop_index_available(index: int) -> bool:
	if index < 0 or index >= GameState.shop_offers.size() or index >= GameState.shop_sold.size():
		return false
	if bool(GameState.shop_sold[index]):
		return false
	var offer = GameState.shop_offers[index]
	return typeof(offer) == TYPE_DICTIONARY and not (offer as Dictionary).is_empty()

func _t(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale() == "en" else zh
