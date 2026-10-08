extends Control

signal return_room_requested
signal return_menu_requested

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Action := preload("res://ui/components/GloryActionButton.tscn")
const Growth := preload("res://scripts/units/UnitGrowth.gd")
const PROFILE_BG_TEX := preload("res://assets/ui/profile/hall_of_glory.png")
const GOLD := Color("e8c46a")
const TEXT := Color("edeff4")
const MUTED := Color("b8becc")
const WIDTHS := [150.0, 310.0, 270.0, 210.0, 150.0, 170.0, 150.0]
var data: Dictionary = {}
# 对局历史里复用这个面板时（MatchHistoryPanel「详细战况」），「返回主菜单」换成这里的字，
# 按下去照样发 return_menu_requested，由历史那边关掉弹窗。
var close_text := ""
var _bubble: PanelContainer
var _bubble_label: Label
# 10.06 反馈第 5 条：面板上、下各有一排同样的按钮，两排都要能被 allow_return_retry 重新启用，
# 所以用数组收集（原来是单个 _return_button）。
var _return_buttons: Array = []

func _ready() -> void:
	# Both live settlement and history render these same rows. Derive the total
	# here as well so old history records need no backfill or extra stored field.
	preload("res://scripts/multiplayer/FinalSettlementData.gd").update_round_damage(data.get("seats", []), data.get("stats", []))
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := TextureRect.new()
	background.texture = PROFILE_BG_TEX
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var veil := ColorRect.new()
	veil.color = Color(0.008, 0.016, 0.031, 0.52)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(veil)
	var scroll := preload("res://ui/components/TouchScrollContainer.gd").new()
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
	var title := _label(tr("settle_title"), GOLD, 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(title)
	var outcome := int(data.get("outcome", 2))
	var winner := _label(tr("settle_win_line") % _team_title(outcome) if outcome in [0, 1] else tr("settle_draw_line"), Color("ff6b5a") if outcome == 0 else Color("4da3ff"), 18)
	winner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(winner)
	# 10.06 反馈第 5 条：面板一屏塞不下时，底部那排按钮要滚到底才够得着 —— 在上部再放一排
	# 同样的按钮（返回房间 / 返回主菜单·关闭），玩家一打开面板就能操作。两排是同一份构造。
	content.add_child(_button_row())
	if data.get("seats", []).is_empty():
		content.add_child(_label(tr("settle_no_details"), MUTED))
	else:
		var own_side := clampi(int(data.get("local_team", GameConstants.team_of_slot(NetworkService.team_local_slot))), 0, 1)
		for side in [own_side, 1 - own_side]:
			content.add_child(_team(side))
		content.add_child(_label(tr("settle_stats_title"), TEXT, 20))
		content.add_child(_stats())
	content.add_child(_button_row())
	_bubble = PanelContainer.new()
	_bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bubble.add_theme_stylebox_override("panel", Tokens.panel_box(Color(0.04, 0.08, 0.14, 0.9), Color.TRANSPARENT, 8))
	_bubble_label = _label("", GOLD, 13)
	_bubble.add_child(_bubble_label)
	add_child(_bubble)
	_bubble.hide()
	scroll.get_v_scroll_bar().value_changed.connect(func(_v): _bubble.hide())

func allow_return_retry() -> void:
	for button in _return_buttons:
		if is_instance_valid(button):
			button.disabled = false
			button.text = tr("settle_back_room")


# 一排操作按钮（返回房间 + 返回主菜单 / 关闭）。上、下两处共用这一份构造，
# 保证两排的文案、配色、回调完全一致（10.06 反馈第 5 条）。
# 只在整局结束时出这张面板（2026-10-07 用户定），所以没有「继续下一回合」。
func _button_row() -> HBoxContainer:
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 24)
	var return_button := _button(tr("settle_back_room"), buttons)
	return_button.visible = bool(data.get("can_return_room", false))
	return_button.pressed.connect(func():
		for other in _return_buttons:
			if is_instance_valid(other):
				other.disabled = true
				other.text = tr("settle_returning")
		return_room_requested.emit())
	_return_buttons.append(return_button)
	var menu := _button(close_text if not close_text.is_empty() else tr("settle_back_menu"), buttons)
	menu.add_theme_stylebox_override("normal", Tokens.panel_box(Color("e9aa43"), GOLD, 10))
	menu.add_theme_color_override("font_color", Color("231a0d"))
	menu.pressed.connect(func(): return_menu_requested.emit())
	return buttons

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

func _team_title(side: int) -> String:
	var allies: Array = data.get("allies", [])
	var guardian := str(allies[side]).strip_edges() if side >= 0 and side < allies.size() else ""
	var base := tr("settle_team_red") if side == 0 else tr("settle_team_blue")
	return base if guardian.is_empty() else tr("settle_team_ally") % [base, guardian]

func _team(side: int) -> Control:
	var panel := PanelContainer.new()
	var color := Color("ff6b5a") if side == 0 else Color("4da3ff")
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(Color(0.02, 0.045, 0.08, 0.2), Color.TRANSPARENT, 16))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	panel.add_child(column)
	column.add_child(_label(_team_title(side), color, 24))
	var headers := _row(WIDTHS)
	var labels := ["settle_col_player", "settle_col_board", "settle_col_merc", "settle_col_treasure", "settle_col_stones", "settle_col_damage", "settle_col_gold"]
	for i in labels.size():
		var label := _label(tr(labels[i]), MUTED, 14)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if i >= 5 else HORIZONTAL_ALIGNMENT_LEFT
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
		column.add_child(_row_panel(row, Color(0.025, 0.055, 0.1, 0.46)))
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
					flow.add_child(_icon(str(treasure.get("portrait", "")), _codex_name(treasure, id)))
		var stones := HFlowContainer.new()
		row.get_child(4).add_child(stones)
		for type in ["sky", "land", "ren"]:
			var count := int(seat.get("stones", {}).get(type, 0))
			if count > 0:
				var icon := _icon("res://assets/props/carrot_system/stones/stone_%s.png" % type, tr("settle_stone_%s" % type), 0, 44)
				var number := _label("×%d" % count, GOLD, 13)
				number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				icon.add_child(number)
				stones.add_child(icon)
		var gold := _label(str(seat.total_gold) if seat.get("total_gold") != null else "—", Color("ffd24d"))
		gold.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		gold.set_meta("settlement_column", 6)
		gold.set_meta("settlement_team", side)
		row.get_child(6).add_child(gold)
		var damage := _label(str(seat.get("round_damage", 0)), TEXT)
		damage.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		damage.set_meta("settlement_column", 5)
		damage.set_meta("settlement_team", side)
		row.get_child(5).add_child(damage)
	return panel

func _stats() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 0)
	var widths := [640.0, 340.0, 180.0, 180.0, 150.0]
	var header := _row(widths)
	var stat_labels := ["settle_stat_unit", "settle_stat_owner", "settle_stat_dealt", "settle_stat_taken", "settle_stat_heal"]
	for i in 5:
		var label := _label(tr(stat_labels[i]), MUTED, 14)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if i >= 2 else HORIZONTAL_ALIGNMENT_LEFT
		label.set_meta("stats_column", i)
		label.set_meta("settlement_header", true)
		header.get_child(i).add_child(label)
	column.add_child(_row_panel(header, Color(0.025, 0.055, 0.1, 0.42)))
	var row_index := 0
	for entry in data.get("stats", []):
		var slot := int(entry.get("owner_slot", 0))
		var color := GameConstants.team_slot_color(slot)
		var row := _row(widths)
		row.custom_minimum_size.y = 44
		var star := 0 if bool(entry.get("is_mercenary", false)) else int(entry.get("star", 1))
		var stacks := _king_stacks(entry)
		var values := [_stat_unit_name(entry) + _stars_text(star) + (tr("settle_stacks") % stacks if stacks > 0 else ""), str(data.seats[slot].name), str(entry.get("damage_dealt", 0)), str(entry.get("damage_taken", 0)), str(entry.get("healing_done", 0))]
		for i in 5:
			var label := _label(values[i], color if i < 2 else (GOLD if i == 2 else (Color("62cfa2") if i == 4 else MUTED)), 15)
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if i >= 2 else HORIZONTAL_ALIGNMENT_LEFT
			label.set_meta("stats_column", i)
			label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			row.get_child(i).add_child(label)
		column.add_child(_row_panel(row, Color(0.025, 0.055, 0.1, 0.42) if row_index % 2 == 0 else Color(0.025, 0.055, 0.1, 0.24)))
		row_index += 1
	return column

func _icon(path: String, caption: String, stars: int = 0, pixels: int = 48) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	var art := TextureRect.new()
	art.custom_minimum_size = Vector2(pixels, pixels)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.mouse_filter = Control.MOUSE_FILTER_PASS
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
	var key := "settle_star_%d" % clampi(star, 0, 4)
	return "" if star <= 0 else tr(key)

# 「（N层）」**只有人王**才有 —— 那是人王专属技能 unique_king_growth 的叠加层数
# （见 UnitGrowth.king_stacks / KING_STACKS = "king_growth_stacks"）。别的棋子即便
# 战斗里 skill_stacks > 0（赤舞者叠 buff、破甲者叠破防…），也不该在这里显示「N层」，
# 否则玩家会把它读成「这棋子也是满层的人王」。
# 判据与源数据一致：拿 unit id 回数据表取 def，交给 UnitGrowth.is_king 判 skill_id。
func _is_king_unit(id: String) -> bool:
	if id.is_empty():
		return false
	var def := DataRegistry.canonical_unit_def(id)
	return not def.is_empty() and Growth.is_king({"def": def})

# 取**人王的持久层数**：只认 UnitGrowth.KING_STACKS（格子 → fighter → unit_stats
# 三级接力带上来的那份）。
#
# ★ 不要用 skill_stacks 顶替：那是战斗内的技能计数，赤舞者 / 破甲者 / 好几件宝物
#   都会把它抬起来，于是「（N层）」会错贴到非人王身上 —— 正是 10.08 反馈第 1 条里
#   「痛苦女王二星（4层）」的来历；而真正的人王因为持久层数在格子上、fighter 里没有，
#   反倒一个数都显示不出来。
func _king_stacks(entry: Dictionary) -> int:
	if not _is_king_unit(str(entry.get("id", ""))):
		return 0
	return maxi(0, int(entry.get(Growth.KING_STACKS, 0)))


func _stacks_text(slot: int, id: String, board_slot: int) -> String:
	if not _is_king_unit(id):
		return ""
	for entry in data.get("stats", []):
		if int(entry.get("owner_slot", -1)) == slot and str(entry.get("id", "")) == id and int(entry.get("slot", -1)) == board_slot:
			var stacks := _king_stacks(entry)
			if stacks > 0:
				return tr("settle_stacks") % stacks
	return ""

# 语言判定与全项目同口径（ShopPanel / BattleRenderer / PrepWidgets 都这么写）。
func _english() -> bool:
	return LocaleManager.get_locale() == "en"


# 上阵棋子 / 佣兵的显示名：走 DataRegistry 的 name_en 双字段。
# 以前直接读数据表的 `name`（中文字段）⇒ 语言切英文后整块面板仍是中文。
# merc 这个参数由调用方表达语义（区分羁绊来源），取不到 canonical 时保留 id 兜底。
func _unit_name(id: String, _merc: bool) -> String:
	return DataRegistry.unit_display_name({"id": id}, _english())


# 统计行的棋子名。
#
# ① 先按 id 回数据表取 canonical 名：**对局历史**里的旧记录是在「对局那一刻」写死的，
#    里面只有中文名（name_en 是 10.08c 才开始随战报存），按 id 查才能跟着
#    「打开历史那一刻」的语言走 —— 这正是真机截图里「英文语言下整列中文」的根因。
# ② 数据表里没有的（PvE 怪 / Boss，canonical 索引只收 race_units + mercenaries）
#    退回记录里存的 name_en → name。
func _stat_unit_name(entry: Dictionary) -> String:
	var english := _english()
	var id := str(entry.get("id", ""))
	if not id.is_empty() and not DataRegistry.canonical_unit_def(id).is_empty():
		return DataRegistry.unit_display_name({"id": id}, english)
	if english:
		var name_en := str(entry.get("name_en", ""))
		if not name_en.is_empty():
			return name_en
	return str(entry.get("name", ""))


# 宝物 / 羁绊 / 套装名：treasure_text.json 里也有 *_en 字段，同理。
func _codex_name(entry: Dictionary, fallback: String) -> String:
	if _english():
		var name_en := str(entry.get("name_en", ""))
		if not name_en.is_empty():
			return name_en
	var name := str(entry.get("name", ""))
	return name if not name.is_empty() else fallback

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
