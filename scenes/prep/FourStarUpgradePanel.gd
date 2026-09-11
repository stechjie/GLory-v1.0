extends VBoxContainer

const Rules := preload("res://scripts/economy/CarrotEconomy.gd")
var piece_uid := ""
var submit: Callable
var confirming := false
var previewing := false
var inventory: Label
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

func _ready() -> void:
	add_theme_constant_override("separation", 6)
	add_child(HSeparator.new())
	preview = Button.new()
	preview.custom_minimum_size.y = 36
	preview.pressed.connect(func():
		previewing = not previewing
		preview_requested.emit(previewing, selected_cell())
		refresh())
	add_child(preview)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	stone_icon = TextureRect.new()
	stone_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stone_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	stone_icon.custom_minimum_size = Vector2(42, 42)
	row.add_child(stone_icon)
	inventory = Label.new()
	inventory.add_theme_font_size_override("font_size", 16)
	row.add_child(inventory)
	add_child(row)
	reason = Label.new()
	reason.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	reason.custom_minimum_size = Vector2(480, 20)
	reason.add_theme_font_size_override("font_size", 14)
	add_child(reason)
	var actions := HBoxContainer.new()
	cancel = Button.new()
	cancel.text = "返回 / Back"
	cancel.custom_minimum_size = Vector2(100, 48)
	cancel.pressed.connect(func(): confirming = false; refresh())
	actions.add_child(cancel)
	action = Button.new()
	action.custom_minimum_size.y = 48
	action.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action.pressed.connect(_pressed)
	ready_style = StyleBoxFlat.new()
	ready_style.bg_color = Color(0.20, 0.14, 0.055)
	ready_style.border_color = Color(1.0, 0.76, 0.30)
	ready_style.set_border_width_all(2)
	ready_style.set_corner_radius_all(7)
	ready_style.shadow_color = Color(1.0, 0.68, 0.18, 0.30)
	ready_style.shadow_size = 6
	action.add_theme_stylebox_override("normal", ready_style)
	action.add_theme_stylebox_override("hover", ready_style)
	actions.add_child(action)
	add_child(actions)
	refresh()

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
		action.self_modulate = Color(1.0, 0.84 + 0.12 * sin(elapsed * TAU / 2.5), 0.56)
		ready_style.shadow_color.a = 0.20 + 0.10 * (0.5 + 0.5 * sin(elapsed * TAU / 2.5))
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
	var cost := Rules.four_star_gold(int(d.get("tier", 0)))
	var signature := "%s/%s/%d/%d" % [piece_uid, element, cost, int(cell.get("star", 0))]
	if confirming and signature != confirm_signature:
		confirming = false
	var stone_name := str(({"sky": "Sky", "land": "Land", "ren": "Human"} if en \
		else {"sky": "天", "land": "地", "ren": "人"}).get(element, "?"))
	if element in Rules.STONE_TYPES:
		stone_icon.texture = load("res://assets/props/carrot_system/stones/stone_%s.png" % element)
	else:
		stone_icon.texture = null
	inventory.text = ("%s Stone × %d  ·  Team shared\nGold: %d / %d" if en \
		else "%s升级石 × %d  ·  队伍共享\n金币：%d / %d") % [stone_name, count, GameState.gold, maxi(0, cost)]
	var check := GameState.four_star_check(cell if not cell.is_empty() else null)
	var error := str(check.get("error", ""))
	if GameState.tutorial_mode:
		error = "tutorial"
	if not NetworkService.four_star_upgrade_available():
		error = "server_update"
	if not NetworkService.four_star_request_id.is_empty():
		error = "pending"
	action.disabled = not error.is_empty()
	if action.disabled:
		confirming = false
	var messages := {
		"tutorial": ["教学结束后开放四星升级", "Available after the tutorial"],
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
			Rules.four_star_gold(int(d.get("tier", 0))), int(cell.get("star", 0))]
		refresh()
	elif submit.is_valid():
		confirming = false
		submit.call(piece_uid)
		refresh()
