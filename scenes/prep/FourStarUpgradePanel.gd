extends VBoxContainer

const Rules := preload("res://scripts/economy/CarrotEconomy.gd")
# 11.11 羊皮纸风：这块现在嵌在长按详情卡（ui/components/UnitDetailCard.gd）的「四星升级」框里，
# 部件全用 assets/ui/unit_detail 那批图；逻辑（确认两步、队伍共享石、等待回执）没动。
const Card := preload("res://ui/components/UnitDetailCard.gd")
const Kit := preload("res://ui/theme/ParchmentKit.gd")
var piece_uid := ""
var submit: Callable
var confirming := false
var previewing := false
var inventory: Label          # 金币需求那半行（检查脚本读它的 「 / 费用」结尾）
var stone_label: Label        # 升级石那半行
var reason: Label
var action: Button
var cancel: Button
var preview: Button
var stone_icon: TextureRect
var elapsed := 0.0
var poll := 0.0
var confirm_signature := ""
var ready_style: StyleBoxFlat
signal preview_requested(enabled: bool, cell: Dictionary)
signal shared_stone_unavailable
var had_matching_stone := false
var stone_notice_sent := false

func _ready() -> void:
	add_theme_constant_override("separation", 5)
	# 查看四星属性与技能：卷轴按钮，左边小卷轴图标
	preview = Button.new()
	preview.custom_minimum_size = Vector2(250, 34)
	preview.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	preview.icon = Card.art("icon_scroll")
	preview.expand_icon = false
	preview.add_theme_constant_override("icon_max_width", 22)
	_texture_button(preview, "scroll_button", Vector4(80, 0, 80, 0), 34.0 / 150.0, "scroll_button")
	_font(preview, false, 600, 16)
	preview.pressed.connect(func():
		previewing = not previewing
		preview_requested.emit(previewing, selected_cell())
		refresh())
	add_child(preview)
	# 升级石 ｜ 金币需求
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	stone_icon = TextureRect.new()
	stone_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stone_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	stone_icon.custom_minimum_size = Vector2(30, 30)
	row.add_child(stone_icon)
	stone_label = _plain_label(15)
	row.add_child(stone_label)
	var bar := _plain_label(15)
	bar.text = "|"
	bar.modulate.a = 0.45
	bar.custom_minimum_size.x = 20
	bar.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(bar)
	var gold_icon := TextureRect.new()
	gold_icon.texture = Card.art("icon_gold_stack")
	gold_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	gold_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	gold_icon.custom_minimum_size = Vector2(24, 24)
	row.add_child(gold_icon)
	inventory = _plain_label(15)
	row.add_child(inventory)
	add_child(row)
	# 返回（确认那一步才出现）＋ 升级大按钮：可升级金色底，不可升级灰色底（disabled 样式）
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 10)
	cancel = Button.new()
	cancel.text = "Back" if LocaleManager.get_locale() == "en" else "返回"
	cancel.custom_minimum_size = Vector2(96, 42)
	Kit.style_plate(cancel, false)
	_font(cancel, false, 600, 16)
	cancel.pressed.connect(func(): confirming = false; refresh())
	actions.add_child(cancel)
	action = Button.new()
	action.custom_minimum_size = Vector2(244, 42)
	action.pressed.connect(_pressed)
	_texture_button(action, "upgrade_button_on", Vector4(115, 0, 115, 0), 42.0 / 190.0, "upgrade_button_off")
	_font(action, true, 900, 19)
	action.add_theme_color_override("font_color", Color("4a2608"))
	action.add_theme_color_override("font_hover_color", Color("4a2608"))
	action.add_theme_color_override("font_pressed_color", Color("4a2608"))
	action.add_theme_color_override("font_disabled_color", Color("5c4a3a"))
	# 旧版的发光底框：现在只留着给 _process 的呼吸节奏用，不再当按钮底图
	ready_style = StyleBoxFlat.new()
	ready_style.shadow_color = Color(1.0, 0.68, 0.18, 0.30)
	actions.add_child(action)
	add_child(actions)
	# 提示（需要先合成三星 / 消耗多少）放在按钮下面
	reason = _plain_label(15)
	reason.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	reason.custom_minimum_size = Vector2(380, 20)
	add_child(reason)
	refresh()


func _plain_label(size: int) -> Label:
	var l := Label.new()
	_font(l, false, 500, size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _font(c: Control, serif: bool, weight: int, size: int) -> void:
	c.add_theme_font_override("font", Card.font(serif, weight))
	c.add_theme_font_size_override("font_size", size)
	c.add_theme_color_override("font_color", Card.INK)
	c.add_theme_color_override("font_hover_color", Card.INK)
	c.add_theme_color_override("font_pressed_color", Card.INK)
	c.add_theme_color_override("font_disabled_color", Card.INK_SOFT)
	c.add_theme_constant_override("outline_size", 0)


func _texture_button(b: Button, piece: String, margins: Vector4, k: float, disabled_piece: String) -> void:
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for state in ["normal", "hover", "pressed", "disabled"]:
		var sb := Card.slice(Card.ART % (disabled_piece if state == "disabled" else piece), k, margins)
		if state == "hover":
			sb.modulate_color = Color(1.06, 1.05, 1.0)
		elif state == "pressed":
			sb.modulate_color = Color(0.9, 0.87, 0.8)
		b.add_theme_stylebox_override(state, sb)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

func selected_cell() -> Dictionary:
	if piece_uid.is_empty():
		return {}
	for slots in [GameState.board_slots, GameState.bench_slots]:
		for c in slots:
			if c is Dictionary and str(c.get("uid", "")) == piece_uid:
				return c
	return {}

func open_for(cell: Dictionary, callback: Callable) -> void:
	piece_uid = str(cell.get("uid", ""))
	submit = callback
	confirming = false
	previewing = false
	had_matching_stone = int(GameState.team_upgrade_stones.get(str(cell.get("def", {}).get("element", "")), 0)) > 0
	stone_notice_sent = false
	show()
	refresh()

func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	elapsed += delta
	poll += delta
	if poll >= 0.15:
		poll = 0.0
		refresh()
	if not action.disabled:
		# 金色按钮轻轻呼吸（底图已经是金色，不再整体染黄）
		var pulse := 0.5 + 0.5 * sin(elapsed * TAU / 2.5)
		action.self_modulate = Color(1.0 + 0.06 * pulse, 1.0 + 0.05 * pulse, 1.0)
		ready_style.shadow_color.a = 0.20 + 0.10 * pulse
	else:
		action.self_modulate = Color.WHITE

func refresh() -> void:
	if action == null:
		return
	var en := LocaleManager.get_locale() == "en"
	var cell := selected_cell()
	var d: Dictionary = cell.get("def", {})
	var element := str(d.get("element", ""))
	var count := int(GameState.team_upgrade_stones.get(element, 0))
	# Keep the initial availability while a request is pending: a room snapshot
	# may arrive before our own successful receipt/grant is applied.
	if count > 0:
		had_matching_stone = true
	if had_matching_stone and count <= 0 and int(cell.get("star", 0)) == 3 \
			and NetworkService.team_active and NetworkService.four_star_request_id.is_empty() \
			and not stone_notice_sent:
		stone_notice_sent = true
		confirming = false
		action.disabled = true
		shared_stone_unavailable.emit()
		return
	if stone_notice_sent:
		action.disabled = true
		return
	var cost := GameState.four_star_cost(d)
	var signature := "%s/%s/%d/%d" % [piece_uid, element, cost, int(cell.get("star", 0))]
	if confirming and signature != confirm_signature:
		confirming = false
	var stone_name := str(({"sky": "Sky", "land": "Land", "ren": "Human"} if en \
		else {"sky": "天", "land": "地", "ren": "人"}).get(element, "?"))
	# 手绘升级石（没有元素时是问号那颗）
	stone_icon.texture = Card.stone_texture(element if element in Rules.STONE_TYPES else "")
	stone_label.text = ("Team %s stone × %d" if en else "队伍共享%s升级石 × %d") % [stone_name, count]
	inventory.text = ("Gold %d / %d" if en else "金币 %d / %d") % [GameState.gold, maxi(0, cost)]
	var check := GameState.four_star_check(cell if not cell.is_empty() else null)
	var error := str(check.get("error", ""))
	# 9.25：教学里四星在「升到四星」那一步开放（萝卜 / 四星教学），其余步骤仍然锁着。
	if GameState.tutorial_mode and not TutorialMode.allows_carrot_action("four_star"):
		error = "tutorial"
	if not NetworkService.four_star_upgrade_available():
		error = "server_update"
	if not NetworkService.four_star_request_id.is_empty():
		error = "pending"
	action.disabled = not error.is_empty()
	if action.disabled:
		confirming = false
	var messages := {
		"tutorial": ["教学到「升到四星」这一步再升级", "Available at the 4-Star tutorial step"],
		"empty_cell": ["棋子已移除", "Unit no longer available"],
		"need_three_star": ["需要先合成三星", "Requires a three-star unit"],
		"already_max": ["已达最高星级", "Maximum star level"],
		"mercenary": ["佣兵无法升四星", "Mercenaries cannot ascend"],
		"no_stone": ["对应升级石不足", "Matching upgrade stone required"],
		"not_enough_gold": ["金币不足", "Not enough gold"],
		"server_update": ["服务器尚未更新四星费用规则", "Server upgrade rules need updating"],
		"pending": ["升级中，请等待结果…", "Upgrading — waiting for result…"],
	}
	reason.text = str(messages.get(error, ["无法升级", "Upgrade unavailable"])[1 if en else 0]) \
		if not error.is_empty() else (("Consume 1 team stone + %d gold" if en else "消耗队伍升级石 ×1 ＋ %d 金币") % cost)
	# 教学（9.25）：详情弹窗是独立窗口，教学箭头画不到它上面（PrepScreen 会在弹窗
	# 打开期间把教学浮层隐藏）。所以这两下点击的指引直接写在弹窗里。
	if GameState.tutorial_mode and error.is_empty():
		reason.text += "\n" + (("Tutorial: tap Confirm upgrade to finish." if en else "教学：再点「确认升级」完成四星。") \
			if confirming else ("Tutorial: tap Upgrade to ★★★★ below." if en else "教学：点下方「升级至四星」。"))
	action.text = ("Confirm upgrade" if en else "确认升级") if confirming else ("Upgrade to ★★★★" if en else "升级至 ★★★★")
	if error == "already_max":
		action.text = "★★★★"
	cancel.visible = confirming
	cancel.text = "Back" if en else "返回"
	preview.text = ("Back to current stats" if en else "返回当前属性") if previewing \
		else ("View four-star stats & skill" if en else "查看四星属性与技能")
	preview.disabled = cell.is_empty()

func _pressed() -> void:
	refresh()
	if action.disabled:
		return
	if not confirming:
		confirming = true
		var cell := selected_cell()
		var d: Dictionary = cell.get("def", {})
		confirm_signature = "%s/%s/%d/%d" % [piece_uid, str(d.get("element", "")), \
			GameState.four_star_cost(d), int(cell.get("star", 0))]
		refresh()
	elif submit.is_valid():
		confirming = false
		submit.call(piece_uid)
		refresh()
