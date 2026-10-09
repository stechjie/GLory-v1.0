extends Control
# 对局历史面板。由 ProfileScreen 推进 ModalStack（入口是「战绩」块里那个按钮）。
#
# 数据来自 GET /v1/me/matches（backend/app/routes/battle_report.py），
# 而那张表的每一行都是**战斗服务器签过章**的战报，不是客户端自报的。
# 设计见 docs/排位系统设计.md 第七、八节。
#
# 三条在改这个文件之前必须知道的：
#
# 1. **只有「最近 N 场」，没有生涯统计。** 后端没有累计接口，这里只能算拉回来的
#    那 LIMIT 条。所以汇总文案一律写「最近 N 场」，**不许出现「胜率 58%」**
#    那种看起来像生涯数据的写法。要真的生涯胜率就得后端加一个聚合接口。
#
# 2. **金币那一列的可信度由 gold_authoritative 决定。** 影子期它是 false
#    （ServerFlags.economy_ledger_authoritative），数字实际来自客户端自报。
#    false 时界面上要标出来 —— 不标就是拿一个看起来权威的数字骗人。
#
# 3. **按钮不用 Button.new()**，一律实例化 ui/components/GloryActionButton.tscn。
#    tools/procedural_ui_ratchet_check 的单文件计数只许降不许升，新文件从 0 开始，
#    写一个 Button.new() 就是红的（同 scenes/menu/ChatScreen.gd 顶部那条）。
#
# 4. **「详细战况」就是打完那一刻的结算面板**（2026-09-29 用户定：「直接搬来」）。
#    不另画一份：点按钮弹出 scenes/menu/FinalSettlementPanel.gd 本身，数据由
#    settlement_view_data() 从历史接口的格式换成它认的格式。结算面板改了，这里跟着变。
#    023 之前打的局没有这份数据（settlement 为 null），按钮换成一句说明。
#    10.07 bug 文档第 8 条：结算面板对任何回合都出（含 PVE）⇒ 历史里也不再按战斗
#    种类挡 PVE，「有 settlement 就有详细战况」。
#
# 5. **名字是账号现在的名字**（2026-09-29 用户定）：后端按 player_id 现取，改过名显示新名字。
#    2026-10-04 bug 文档第 5 条（二次反馈）：这里**只显示昵称、隐藏 #好友码**
#    （seat_name 传 with_code=false）。本面板右列的座位行与「详细战况」弹的结算面板
#    共用同一个 seat_name，两处口径必须一致。

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const SfxService := preload("res://ui/services/SfxService.gd")
const SettlementPanel := preload("res://scenes/menu/FinalSettlementPanel.gd")
const FinalSettlementData := preload("res://scripts/multiplayer/FinalSettlementData.gd")
const PROFILE_BG_TEX := preload("res://assets/ui/profile/hall_of_glory.png")

# 「详细战况」叠在历史弹窗上面（ProfileScreen 推历史用的是 40）。
const DETAIL_MODAL_ID := "match_history_detail"
const DETAIL_PRIORITY := 50

signal dismissed()

# 一次拉多少局。后端 MAX_LIMIT 是 50；20 够翻一阵，而且六个座位的详情都在
# 同一份响应里，拉太多是白白占内存。
const FETCH_LIMIT := 20
const TouchScrollContainer := preload("res://ui/components/TouchScrollContainer.gd")

var _matches: Array = []
var _selected_match := -1
var _list_box: VBoxContainer
var _summary: Label
var _status: Label


func _ready() -> void:
	theme = Theming.get_theme()
	_build()
	_fetch()


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := TextureRect.new()
	background.texture = PROFILE_BG_TEX
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var veil := ColorRect.new()
	veil.color = Color(0.008, 0.016, 0.031, 0.43)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(veil)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + edge, 56)
	for edge in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 28)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	var title := Label.new()
	title.text = _text("对局历史", "Match History")
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close := ACTION_BUTTON.instantiate() as Button
	close.text = _text("返回", "Back")
	close.custom_minimum_size = Vector2(130, Tokens.TOUCH_MIN)
	close.pressed.connect(func() -> void:
		SfxService.play(SfxService.CUE_UI_CONFIRM)
		dismissed.emit())
	header.add_child(close)
	_summary = Label.new()
	_summary.add_theme_font_size_override("font_size", 18)
	_summary.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	column.add_child(_summary)
	var list_scroll := TouchScrollContainer.new()
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(list_scroll)
	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override("separation", 8)
	list_scroll.add_child(_list_box)
	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(0, 26)
	_status.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	column.add_child(_status)


# --- 取数 ---------------------------------------------------------------------

func _fetch() -> void:
	_set_status(_text("加载中…", "Loading…"))
	var result: Dictionary = await AccountManager.fetch_matches(FETCH_LIMIT)
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) != 200:
		# 失败时**不要清空已有列表**（这里本来就是空的，但以后加了刷新按钮就会咬人）。
		_set_status(_failure_text(result))
		return
	var body: Dictionary = result.get("body", {})
	var raw: Variant = body.get("matches", [])
	_matches = (raw as Array) if typeof(raw) == TYPE_ARRAY else []
	_set_status("")
	_refresh_summary()
	_refresh_list()
	if not _matches.is_empty():
		_select_match(0)


func _failure_text(result: Dictionary) -> String:
	var msg := str(result.get("error", ""))
	if msg.is_empty():
		msg = _text("拉不到对局历史", "Could not load match history")
	return msg


# --- 汇总：只说「最近 N 场」-----------------------------------------------------

func _refresh_summary() -> void:
	if _matches.is_empty():
		_summary.text = _text("还没有打完过一局", "No finished matches yet")
		return
	var wins := 0
	var losses := 0
	var draws := 0
	for item in _matches:
		match _my_result(item as Dictionary):
			"win": wins += 1
			"loss": losses += 1
			_: draws += 1
	# ⚠️ 文案必须带「最近 N 场」。见文件顶部第 1 条 —— 这是拉回来的窗口，
	# 不是生涯统计，写成百分比就成了假数据。
	var zh := "最近 %d 场 · %d 胜 %d 负" % [_matches.size(), wins, losses]
	var en := "Last %d · %dW %dL" % [_matches.size(), wins, losses]
	if draws > 0:
		zh += " %d 平" % draws
		en += " %dD" % draws
	_summary.text = _text(zh, en)


# 这一局对**我**来说是胜是负。outcome 是队伍级的，要按我的座位翻译过来。
#
# 🔴 跑路判负（2026-10-06，同 backend/app/ranked.py 的 _settle_ranked）：对局结束时我不在线，
# 队伍赢、输、平都算我输。判据同 _seat_state 的「掉线未归」—— 看 online_at_end，不看 was_ai。
func _my_result(item: Dictionary) -> String:
	var seats: Array = item.get("seats", []) if typeof(item.get("seats")) == TYPE_ARRAY else []
	for seat in seats:
		var mine := seat is Dictionary and int((seat as Dictionary).get("slot", -1)) == int(item.get("my_slot", -1))
		if mine and not bool((seat as Dictionary).get("online_at_end", true)):
			return "loss"
	var outcome := str(item.get("outcome", "draw"))
	if outcome == "draw":
		return "draw"
	var my_team := 0 if int(item.get("my_slot", 0)) < 3 else 1
	var winner := 0 if outcome == "team_a" else 1
	return "win" if my_team == winner else "loss"


# --- 左列：对局列表 -------------------------------------------------------------

func _refresh_list() -> void:
	for child in _list_box.get_children():
		_list_box.remove_child(child)
		child.queue_free()
	for index in _matches.size():
		_list_box.add_child(_list_row(index))


func _list_row(index: int) -> Control:
	var item: Dictionary = _matches[index]
	var outcome := _my_result(item)
	var available := has_settlement_details(item)
	var row := ACTION_BUTTON.instantiate() as Button
	row.text = ""
	row.custom_minimum_size = Vector2(0, 122)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_stylebox_override("normal", Tokens.flat_box(Color(0.015, 0.04, 0.08, 0.39), Color.TRANSPARENT, 0, 12))
	row.add_theme_stylebox_override("hover", Tokens.flat_box(Color(0.025, 0.075, 0.13, 0.67), Color.TRANSPARENT, 0, 12))
	row.add_theme_stylebox_override("pressed", Tokens.flat_box(Color(0.025, 0.075, 0.13, 0.8), Color.TRANSPARENT, 0, 12))
	row.pressed.connect(func() -> void:
		if available:
			SfxService.play(SfxService.CUE_UI_POPUP)
			_open_settlement(item))
	var inset := MarginContainer.new()
	inset.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	inset.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for edge in ["left", "right"]:
		inset.add_theme_constant_override("margin_" + edge, 18)
	for edge in ["top", "bottom"]:
		inset.add_theme_constant_override("margin_" + edge, 10)
	row.add_child(inset)
	var content := HBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_theme_constant_override("separation", 22)
	inset.add_child(content)
	var result_box := VBoxContainer.new()
	result_box.custom_minimum_size.x = 146
	result_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(result_box)
	result_box.add_child(_row_label(_outcome_word(outcome), _outcome_color(outcome), 26))
	result_box.add_child(_row_label("%s · %s %d" % [_mode_word(str(item.get("mode", ""))), _text("回合", "Round"), int(item.get("rounds", 0))], Tokens.TEXT_SECONDARY, 15))
	var seats: Array = item.get("seats", []) if typeof(item.get("seats")) == TYPE_ARRAY else []
	for team in 2:
		var team_box := VBoxContainer.new()
		team_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		team_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		team_box.add_theme_constant_override("separation", 1)
		content.add_child(team_box)
		team_box.add_child(_row_label(_text("红队", "Red Team") if team == 0 else _text("蓝队", "Blue Team"), Color("ff8b7f") if team == 0 else Color("82bdff"), 16))
		for seat in seats:
			if typeof(seat) != TYPE_DICTIONARY or int((seat as Dictionary).get("team", -1)) != team:
				continue
			var seat_data := seat as Dictionary
			var name := seat_name(seat_data, int(seat_data.get("slot", -1)) == int(item.get("my_slot", -1)))
			var state := _seat_state(seat_data)
			team_box.add_child(_row_label(name + state, Tokens.TEXT_PRIMARY if state.is_empty() else Tokens.TEXT_SECONDARY, 14))
	var action_box := VBoxContainer.new()
	action_box.custom_minimum_size.x = 190
	action_box.alignment = BoxContainer.ALIGNMENT_CENTER
	action_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(action_box)
	action_box.add_child(_row_label(_ago_text(int(item.get("age_sec", 0))), Tokens.TEXT_SECONDARY, 14))
	if not bool(item.get("gold_authoritative", false)):
		action_box.add_child(_row_label(_text("金币为客户端上报值", "Gold is client-reported"), Tokens.TEXT_SECONDARY, 12))
	if available:
		var detail := ACTION_BUTTON.instantiate() as Button
		detail.text = _text("详细战况", "Match details")
		detail.custom_minimum_size = Vector2(145, 38)
		detail.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		detail.pressed.connect(func() -> void:
			SfxService.play(SfxService.CUE_UI_POPUP)
			_open_settlement(item))
		action_box.add_child(detail)
	else:
		action_box.add_child(_row_label(_text("旧版本记录，没有详细战况", "Older record, no match details"), Tokens.TEXT_SECONDARY, 12))
	return row


func _row_label(value: String, color: Color, font_size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", font_size)
	label.clip_text = true
	return label


func _select_match(index: int) -> void:
	# Kept for the existing history fixture. Selection does not open a detail until tapped.
	if index >= 0 and index < _matches.size():
		_selected_match = index


# 谁坐在这个座位上：账号**现在**的名字（后端按 player_id 现取，见文件顶部第 5 条）。
# 注销了的账号，后端给的就是「已注销玩家」。
#
# ★ 2026-10-04 bug 文档第 5 条（二次反馈）——「结算面板隐藏 #ID 未实现」：
#   这个函数同时喂两处：本面板右列的座位行（_seat_row，:306）与「详细战况」弹出来的
#   **结算面板**（settlement_view_data → FinalSettlementPanel 的「玩家」列、以及统计表
#   的「所属玩家」列）。
#
#   结算面板有**两个入口**：打完那一刻走 FinalSettlementData.build（那边早就传了
#   false），历史对局走这里 —— **漏的就是这条路**，所以同一句结算里两个入口的名字
#   格式必须一致。`with_code` 在这里一次性传 false。
#
#   仍然带码的地方（刻意保留，见 AccountManager.display_name 顶上那段）：好友 / 聊天 /
#   世界频道 / 资料页（资料页是玩家看自己好友码的唯一入口，去了码等于删功能）。
static func seat_name(seat: Dictionary, mine: bool) -> String:
	var who: String
	if not _seat_pid(seat).is_empty():
		who = AccountManager.display_name(_json_str(seat.get("player_name")), _json_str(seat.get("friend_code")), false)
	elif bool(seat.get("was_ai", false)):
		who = "AI"
	else:
		# 没账号也不是 AI：有棋子 = 没带名片的真人（进程内门禁那条路），没棋子 = 空位。
		var board: Variant = seat.get("board", [])
		var has_units := typeof(board) == TYPE_ARRAY and not (board as Array).is_empty()
		who = _text("玩家", "Player") if has_units else _text("空位", "Empty")
	return who + (_text("（我）", " (me)") if mine else "")


# ⚠️ **JSON 的 null 在 GDScript 里是 null 变体，而 str(null) 得到字面量 "<null>"。**
#
# AI 座位的 player_id 就是 null（database/013 允许它为空）。直接写
# `str(seat.get("player_id", "")).is_empty()` 的话，"<null>" 不是空串 ——
# AI 座位会被当成真人，再因为它 online_at_end=false 被标成「掉线未归」。
# 2026-09-22 由 tools/match_history_ui_check 抓到。同 ProfileScreen._field()
# 顶上那条警告，是同一个坑。
static func _seat_pid(seat: Dictionary) -> String:
	return _json_str(seat.get("player_id", null))


static func _json_str(value: Variant) -> String:
	return "" if value == null else str(value)


# 🔴 「跑路」看的是 online_at_end，不是 was_ai。
#
# 座位断线 20 秒就转 AI（RESERVE_GRACE_SEC），但转了之后玩家还能回来
# （NetworkService._resume_seat）。把 was_ai 显示成「跑了」会冤枉一大片
# 只是切了后台、过了隧道的人。
func _seat_state(seat: Dictionary) -> String:
	if _seat_pid(seat).is_empty():
		return ""
	if not bool(seat.get("online_at_end", true)):
		return _text("（掉线未归）", "(left)")
	if int(seat.get("ai_rounds", 0)) > 0:
		return _text("（中途断线 %d 回合）" % int(seat.get("ai_rounds", 0)),
			"(AI %d rounds)" % int(seat.get("ai_rounds", 0)))
	return ""


# --- 详细战况 -------------------------------------------------------------------

func _open_settlement(item: Dictionary) -> void:
	if not has_settlement_details(item) or ModalStack.has(DETAIL_MODAL_ID):
		return
	var panel := SettlementPanel.new()
	panel.data = settlement_view_data(item)
	panel.close_text = _text("关闭", "Close")
	panel.return_menu_requested.connect(func() -> void: ModalStack.pop(DETAIL_MODAL_ID))
	ModalStack.push(panel, {
		"id": DETAIL_MODAL_ID,
		"owner": self,
		"priority": DETAIL_PRIORITY,
		"popup_sfx": false,
	})


# 历史接口的一局 → FinalSettlementPanel 认的 data（FinalSettlementData.build 的形状）。
#
# 棋子 / 佣兵 / 宝藏来自 match_seats（board 里 merc=true 的是佣兵），升级石 / 总金币 /
# 法阵守护 / 统计来自 settlement（database/023；统计是短键，见 BattleReport._clean_stats）。
# 没有 settlement（023 之前的局）返回空字典。
static func has_settlement_details(item: Dictionary) -> bool:
	if not item.get("settlement") is Dictionary:
		return false
	var kind := str(item.settlement.get("kind", ""))
	if not kind.is_empty():
		# 10.07 bug 文档第 8 条：任何回合结束都有结算面板（PVE 也要算我方上阵佣兵
		# 的数据），历史里也同步 ⇒ 有 settlement 就有详细战况，不再按战斗种类挡 PVE。
		# 以前这里是 `kind in ["pvp", "final"]`，PVE 记录一律显示「无结算详情」。
		return true
	# Old records have rounds but no battle-kind field. Read the schedule without
	# consulting GameState.final_round_played (which belongs to the current run).
	var round_index := int(item.get("rounds", 0))
	if round_index > 0:
		return round_index == GameState.FINAL_ROUND or RoundService.is_pvp_schedule_round(round_index)
	return true

static func settlement_view_data(item: Dictionary) -> Dictionary:
	var settle: Variant = item.get("settlement")
	if typeof(settle) != TYPE_DICTIONARY:
		return {}
	var extras: Array = (settle as Dictionary).get("seats", []) if typeof((settle as Dictionary).get("seats")) == TYPE_ARRAY else []
	var rows: Array = item.get("seats", []) if typeof(item.get("seats")) == TYPE_ARRAY else []
	var my_slot := int(item.get("my_slot", -1))
	var seats := []
	for slot in 6:
		var seat := {}
		for row in rows:
			if typeof(row) == TYPE_DICTIONARY and int((row as Dictionary).get("slot", -1)) == slot:
				seat = row
		var extra: Dictionary = extras[slot] if slot < extras.size() and typeof(extras[slot]) == TYPE_DICTIONARY else {}
		var board := []
		var mercs := []
		for cell in (seat.get("board", []) if typeof(seat.get("board")) == TYPE_ARRAY else []):
			if typeof(cell) != TYPE_DICTIONARY:
				continue
			var unit := {"id": str(cell.get("id", "")), "star": int(cell.get("star", 1)), "slot": int(cell.get("slot", -1))}
			if bool(cell.get("merc", false)):
				mercs.append(unit)
			else:
				board.append(unit)
		var owned: Array = seat.get("treasures", []) if typeof(seat.get("treasures")) == TYPE_ARRAY else []
		seats.append({
			"slot": slot,
			# 10.10 bug 第 8 条：自身标记改由结算面板统一加（FinalSettlementPanel.
			# _seat_display_name 读 is_local）—— 这里只把「我」是哪个座位告诉面板。
			# 若在这里也拼上「（我）」，面板会叠成「明（我）（我）」。
			"name": seat_name(seat, false),
			"is_local": slot == my_slot,
			"board": board,
			"mercenaries": mercs,
			"treasures": FinalSettlementData.display_treasures(owned),
			"stones": extra.get("stones", {}) if typeof(extra.get("stones")) == TYPE_DICTIONARY else {},
			"total_gold": int(extra.get("total_gold", 0)),
		})
	var stats := []
	for entry in ((settle as Dictionary).get("stats", []) if typeof((settle as Dictionary).get("stats")) == TYPE_ARRAY else []):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = entry
		stats.append({
			"owner_slot": clampi(int(e.get("own", 0)), 0, 5),
			"slot": int(e.get("slot", -1)),
			"id": str(e.get("id", "")),
			"name": str(e.get("name", "")),
			# 10.08c 第 1 条：把战报里新带的英文名 / 人王持久层数接回来（短键见
			# BattleReport._clean_stats）。旧记录没有这两项 —— 名字由结算面板按 id
			# 回数据表兜底（FinalSettlementPanel._stat_unit_name），层数就真的没有了。
			"name_en": str(e.get("n_en", "")),
			"star": int(e.get("star", 1)),
			"is_mercenary": bool(e.get("merc", false)),
			"skill_stacks": int(e.get("stack", 0)),
			"king_growth_stacks": clampi(int(e.get("kst", 0)), 0, 99),
			"damage_dealt": int(e.get("dmg", 0)),
			"damage_taken": int(e.get("taken", 0)),
			"healing_done": int(e.get("heal", 0)),
		})
	var allies: Array = ((settle as Dictionary).get("allies") as Array).duplicate() if typeof((settle as Dictionary).get("allies")) == TYPE_ARRAY else ["", ""]
	while allies.size() < 2:
		allies.append("")
	return {
		"outcome": {"team_a": 0, "team_b": 1}.get(str(item.get("outcome", "draw")), 2),
		"local_team": GameConstants.team_of_slot(my_slot),
		"allies": allies,
		"seats": seats,
		"stats": stats,
		"gold_authoritative": bool(item.get("gold_authoritative", false)),
		# 历史里没有「返回房间」：那个房间早就不在了。
		"can_return_room": false,
	}


# --- 文案 ---------------------------------------------------------------------

func _outcome_word(outcome: String) -> String:
	match outcome:
		"win": return _text("胜", "Win")
		"loss": return _text("负", "Loss")
		_: return _text("平", "Draw")


func _outcome_color(outcome: String) -> Color:
	match outcome:
		"win": return Color("67dca2")
		"loss": return Color("ff796f")
		_: return Tokens.TEXT_SECONDARY


func _mode_word(mode: String) -> String:
	match mode:
		"ranked": return _text("排位", "Ranked")
		"casual": return _text("休闲", "Casual")
		_: return _text("自定义", "Custom")


# 只发相对值。同邮件那条：手机的钟可能是错的，拿绝对时间在手机上算「几天前」会算歪。
# 后端回的就是 age_sec，这里只负责换个说法。
func _ago_text(age_sec: int) -> String:
	if age_sec < 3600:
		return _text("%d 分钟前" % maxi(1, age_sec / 60), "%dm ago" % maxi(1, age_sec / 60))
	if age_sec < 86400:
		return _text("%d 小时前" % (age_sec / 3600), "%dh ago" % (age_sec / 3600))
	return _text("%d 天前" % (age_sec / 86400), "%dd ago" % (age_sec / 86400))


func _set_status(text: String) -> void:
	if _status != null and is_instance_valid(_status):
		_status.text = text


static func _is_en() -> bool:
	return LocaleManager.get_locale().begins_with("en")


static func _text(zh: String, en: String) -> String:
	return en if _is_en() else zh
