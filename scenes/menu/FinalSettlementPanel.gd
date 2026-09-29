extends Control

signal return_room_requested
signal return_menu_requested

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Action := preload("res://ui/components/GloryActionButton.tscn")
const GOLD := Color("e8c46a")
const TEXT := Color("edeff4")
const MUTED := Color("b8becc")
const WIDTHS := [150.0, 340.0, 300.0, 240.0, 170.0, 170.0]
var data: Dictionary = {}
var _bubble: PanelContainer
var _bubble_label: Label
var _return_button: Button

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.color = Color("0d1219")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 28)
	scroll.add_child(margin)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 18)
	margin.add_child(content)
	var title := _label("最终战 · 结算", GOLD, 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(title)
	var outcome := int(data.get("outcome", 2))
	var winners := ["红队", "蓝队", "平局"]
	var winner := _label(("本场胜利：" + winners[clampi(outcome, 0, 2)] + ("（%s）" % str(data.get("allies", ["", ""])[outcome]) if outcome < 2 else "本场结果：平局")), Color("ff6b5a") if outcome == 0 else Color("4da3ff"), 18)
	winner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(winner)
	if data.get("seats", []).is_empty():
		content.add_child(_label("本局暂无完整结算详情，请返回主菜单。", MUTED))
	else:
		for side in 2:
			content.add_child(_team(side))
		content.add_child(_label("统计面板", TEXT, 20))
		content.add_child(_stats())
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 24)
	content.add_child(buttons)
	_return_button = _button("返回房间", buttons)
	_return_button.visible = bool(data.get("can_return_room", false))
	_return_button.pressed.connect(func():
		_return_button.disabled = true
		_return_button.text = "正在返回…"
		return_room_requested.emit())
	var menu := _button("返回主菜单", buttons)
	menu.add_theme_stylebox_override("normal", Tokens.panel_box(Color("e9aa43"), GOLD, 10))
	menu.add_theme_color_override("font_color", Color("231a0d"))
	menu.pressed.connect(func(): return_menu_requested.emit())
	var hint := _label("↓ 本结算面板超过一屏，可上下滚动查看全部内容", MUTED, 14)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(hint)
	_bubble = PanelContainer.new()
	_bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bubble.add_theme_stylebox_override("panel", Tokens.panel_box(Color(0.11, 0.13, 0.18, 0.88), Color(0.91, 0.77, 0.42, 0.75), 8))
	_bubble_label = _label("", GOLD, 13)
	_bubble.add_child(_bubble_label)
	add_child(_bubble)
	_bubble.hide()
	scroll.get_v_scroll_bar().value_changed.connect(func(_v): _bubble.hide())

func allow_return_retry() -> void:
	_return_button.disabled = false
	_return_button.text = "返回房间"

func _label(value: String, color: Color = TEXT, font_size: int = 16) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", font_size)
	return label

func _button(value: String, parent: Node) -> Button:
	var button: Button = Action.instantiate()
	button.text = value
	button.custom_minimum_size = Vector2(200, 44)
	button.add_theme_stylebox_override("normal", Tokens.panel_box(Color("252d40"), Color("586789"), 10))
	parent.add_child(button)
	return button

# Fixed ratios, independent of label/icon minimum widths: headers and data align.
class TableRow extends Container:
	var widths: Array = []
	func _get_minimum_size() -> Vector2:
		var height := 0.0
		for cell in get_children():
			height = maxf(height, cell.get_combined_minimum_size().y)
		return Vector2(0, height)
	func _notification(what: int) -> void:
		if what != NOTIFICATION_SORT_CHILDREN or widths.is_empty():
			return
		var total := 0.0
		for weight in widths:
			total += float(weight)
		var available := maxf(0, size.x - 12 * (widths.size() - 1))
		var x := 0.0
		for i in get_child_count():
			var width := available * float(widths[i]) / total
			fit_child_in_rect(get_child(i), Rect2(x, 0, width, size.y))
			x += width + 12

func _row(widths: Array) -> Container:
	var row := TableRow.new()
	row.widths = widths
	for width in widths:
		var cell := VBoxContainer.new()
		row.add_child(cell)
	return row

func _team(side: int) -> Control:
	var panel := PanelContainer.new()
	var color := Color("ff6b5a") if side == 0 else Color("4da3ff")
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(Color("121720"), color.darkened(0.4), 16))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	panel.add_child(column)
	var allies: Array = data.get("allies", ["", ""])
	column.add_child(_label(("红队" if side == 0 else "蓝队") + ("（%s）" % str(allies[side]) if not str(allies[side]).is_empty() else ""), color, 24))
	var headers := _row(WIDTHS)
	var labels := ["玩家", "上阵棋子", "召唤佣兵", "宝藏", "获取升级石", "获得总金币"]
	for i in labels.size():
		var label := _label(labels[i], MUTED, 14)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if i == 5 else HORIZONTAL_ALIGNMENT_LEFT
		label.set_meta("settlement_column", i)
		label.set_meta("settlement_team", side)
		label.set_meta("settlement_header", true)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		headers.get_child(i).add_child(label)
	column.add_child(_row_panel(headers, Color(0, 0, 0, 0)))
	for slot in range(side * 3, side * 3 + 3):
		var seats: Array = data.get("seats", [])
		if slot >= seats.size():
			continue
		var seat: Dictionary = seats[slot]
		var row := _row(WIDTHS)
		row.custom_minimum_size.y = 76
		column.add_child(_row_panel(row, Color("20212b"), color.darkened(0.7)))
		var name_label := _label(str(seat.get("name", "")), GameConstants.team_slot_color(slot), 15)
		name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.get_child(0).add_child(name_label)
		for group in 3:
			var flow := HFlowContainer.new()
			flow.add_theme_constant_override("h_separation", 6)
			row.get_child(group + 1).add_child(flow)
			if group < 2:
				for unit in seat.get("board" if group == 0 else "mercenaries", []):
					var id := str(unit.get("id", ""))
					var name_text := _unit_name(id, group == 1)
					var star := int(unit.get("star", 1)) if group == 0 else 0
					flow.add_child(_icon("res://assets/ui/%s/%s.png" % ["unit_portraits" if group == 0 else "mercenary_portraits", id], name_text + _stars_text(star) + _stacks_text(slot, id, int(unit.get("slot", -1))), star))
			else:
				for id in seat.get("treasures", []):
					var treasure := _treasure(str(id))
					flow.add_child(_icon(str(treasure.get("portrait", "")), str(treasure.get("name", id))))
		var stones := HFlowContainer.new()
		row.get_child(4).add_child(stones)
		for type in ["sky", "land", "ren"]:
			var count := int(seat.get("stones", {}).get(type, 0))
			if count > 0:
				var icon := _icon("res://assets/props/carrot_system/stones/stone_%s.png" % type, {"sky": "天", "land": "地", "ren": "人"}[type], 0, 44)
				var number := _label("×%d" % count, GOLD, 13)
				number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				icon.add_child(number)
				stones.add_child(icon)
		var gold := _label(str(seat.get("total_gold", 0)), Color("ffd24d"))
		gold.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		gold.set_meta("settlement_column", 5)
		gold.set_meta("settlement_team", side)
		row.get_child(5).add_child(gold)
	return panel

func _stats() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 0)
	var widths := [640.0, 340.0, 180.0, 180.0, 150.0]
	var header := _row(widths)
	for i in 5:
		var label := _label(["单位", "所属玩家", "造成伤害", "承受伤害", "治疗"][i], MUTED, 14)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if i >= 2 else HORIZONTAL_ALIGNMENT_LEFT
		label.set_meta("stats_column", i)
		label.set_meta("settlement_header", true)
		header.get_child(i).add_child(label)
	column.add_child(_row_panel(header, Color("293142")))
	var row_index := 0
	for entry in data.get("stats", []):
		var slot := int(entry.get("owner_slot", 0))
		var color := GameConstants.team_slot_color(slot)
		var row := _row(widths)
		row.custom_minimum_size.y = 44
		var star := 0 if bool(entry.get("is_mercenary", false)) else int(entry.get("star", 1))
		var stacks := int(entry.get("skill_stacks", 0))
		var values := [str(entry.get("name", "")) + _stars_text(star) + ("（%d层）" % stacks if stacks > 0 else ""), str(data.seats[slot].name), str(entry.get("damage_dealt", 0)), str(entry.get("damage_taken", 0)), str(entry.get("healing_done", 0))]
		for i in 5:
			var label := _label(values[i], color if i < 2 else (GOLD if i == 2 else (Color("62cfa2") if i == 4 else MUTED)), 15)
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if i >= 2 else HORIZONTAL_ALIGNMENT_LEFT
			label.set_meta("stats_column", i)
			label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			row.get_child(i).add_child(label)
		column.add_child(_row_panel(row, Color("19212e") if row_index % 2 == 0 else Color("141c27")))
		row_index += 1
	return column

func _icon(path: String, caption: String, stars: int = 0, pixels: int = 48) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	var art := TextureRect.new()
	art.custom_minimum_size = Vector2(pixels, pixels)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.mouse_filter = Control.MOUSE_FILTER_STOP
	var rounded := ShaderMaterial.new()
	rounded.shader = preload("res://ui/theme/SettlementIcon.gdshader")
	art.material = rounded
	if not path.is_empty() and ResourceLoader.exists(path):
		art.texture = load(path)
	box.add_child(art)
	art.gui_input.connect(func(event: InputEvent):
		if (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed) or (event is InputEventScreenTouch and event.pressed):
			_show_bubble(art, caption)
			art.accept_event())
	if stars > 0:
		var label := _label("★".repeat(stars), Color("ffd24d"), 9)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(label)
	return box

func _show_bubble(icon: Control, caption: String) -> void:
	_bubble_label.text = caption
	_bubble.reset_size()
	_bubble.show()
	var rect := icon.get_global_rect()
	_bubble.position = Vector2(clampf(rect.get_center().x - _bubble.size.x / 2, 4, size.x - _bubble.size.x - 4), maxf(4, rect.position.y - _bubble.size.y - 6))

func _stars_text(star: int) -> String:
	return ["", "一星", "二星", "三星", "四星"][clampi(star, 0, 4)]

func _stacks_text(slot: int, id: String, board_slot: int) -> String:
	for entry in data.get("stats", []):
		if int(entry.get("owner_slot", -1)) == slot and str(entry.get("id", "")) == id and int(entry.get("slot", -1)) == board_slot and int(entry.get("skill_stacks", 0)) > 0:
			return "（%d层）" % int(entry.skill_stacks)
	return ""

func _unit_name(id: String, merc: bool) -> String:
	if not merc:
		return str(DataRegistry.canonical_unit_def(id).get("name", id))
	for unit in DataRegistry.get_table("mercenaries").get("mercenaries", []):
		if str(unit.get("id", "")) == id:
			return str(unit.get("name", id))
	return id

func _treasure(id: String) -> Dictionary:
	var codex := preload("res://scripts/codex/CodexService.gd")
	for entry in codex._treasures() + codex._linkages() + codex._sets():
		if str(entry.id) == id:
			return entry
	return {}

func _row_panel(row: Control, background: Color, border: Color = Color(0, 0, 0, 0)) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := Tokens.panel_box(background, border, 12)
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	panel.add_child(row)
	return panel

func _input(event: InputEvent) -> void:
	if is_instance_valid(_bubble) and event is InputEventMouseButton and event.pressed:
		_bubble.hide()
