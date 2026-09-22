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

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const SfxService := preload("res://ui/services/SfxService.gd")

signal dismissed()

# 一次拉多少局。后端 MAX_LIMIT 是 50；20 够翻一阵，而且六个座位的详情都在
# 同一份响应里，拉太多是白白占内存。
const FETCH_LIMIT := 20

const PANEL_SIZE := Vector2(1100, 620)
const LIST_WIDTH := 320.0
const PORTRAIT := 56.0

# 棋子头像。与 scripts/codex/CodexService.gd 的三个目录常量同源 ——
# 那边是图鉴用的，这边是历史用的，路径规则一样（<目录>/<id>.png）。
const UNIT_PORTRAIT_DIR := "res://assets/ui/unit_portraits/"
const MERC_PORTRAIT_DIR := "res://assets/ui/mercenary_portraits/"

var _matches: Array = []
var _selected_match := -1
var _selected_slot := -1
var _list_box: VBoxContainer
var _detail_box: VBoxContainer
var _summary: Label
var _status: Label


func _ready() -> void:
	theme = Theming.get_theme()
	_build()
	_fetch()


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box())
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = PANEL_SIZE
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Tokens.GAP_M)
	panel.add_child(column)

	var title := Label.new()
	title.text = _text("对局历史", "Match History")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	column.add_child(title)

	_summary = Label.new()
	_summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_summary.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	column.add_child(_summary)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", Tokens.GAP_M)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(body)

	var list_scroll := ScrollContainer.new()
	list_scroll.custom_minimum_size = Vector2(LIST_WIDTH, 0)
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(list_scroll)
	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override("separation", Tokens.GAP_S)
	list_scroll.add_child(_list_box)

	var detail_scroll := ScrollContainer.new()
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(detail_scroll)
	_detail_box = VBoxContainer.new()
	_detail_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_box.add_theme_constant_override("separation", Tokens.GAP_S)
	detail_scroll.add_child(_detail_box)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(0, 26)
	_status.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	column.add_child(_status)

	var close := ACTION_BUTTON.instantiate() as Button
	close.text = _text("关闭", "Close")
	close.pressed.connect(func() -> void:
		SfxService.play(SfxService.CUE_UI_CONFIRM)
		dismissed.emit())
	column.add_child(close)


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
func _my_result(item: Dictionary) -> String:
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
	var row := ACTION_BUTTON.instantiate() as Button
	row.custom_minimum_size = Vector2(LIST_WIDTH - Tokens.GAP_M, Tokens.TOUCH_MIN)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.text = "%s  %s  %s" % [
		_outcome_word(outcome),
		_mode_word(str(item.get("mode", ""))),
		_ago_text(int(item.get("age_sec", 0))),
	]
	row.add_theme_color_override("font_color", _outcome_color(outcome))
	if index == _selected_match:
		row.add_theme_color_override("font_color", Tokens.GOLD_EDGE)
	row.pressed.connect(func() -> void:
		SfxService.play(SfxService.CUE_UI_POPUP)
		_select_match(index))
	return row


func _select_match(index: int) -> void:
	if index < 0 or index >= _matches.size():
		return
	_selected_match = index
	# 默认摊开**我自己**那个座位。别人一进来最想看的是自己那局摆了什么。
	_selected_slot = int((_matches[index] as Dictionary).get("my_slot", 0))
	_refresh_list()
	_refresh_detail()


# --- 右列：这一局的详情 ---------------------------------------------------------

func _refresh_detail() -> void:
	for child in _detail_box.get_children():
		_detail_box.remove_child(child)
		child.queue_free()
	if _selected_match < 0 or _selected_match >= _matches.size():
		return
	var item: Dictionary = _matches[_selected_match]

	var head := Label.new()
	head.text = "%s · %s · %s %d · %s" % [
		_outcome_word(_my_result(item)),
		_mode_word(str(item.get("mode", ""))),
		_text("回合", "Round"), int(item.get("rounds", 0)),
		_ago_text(int(item.get("age_sec", 0))),
	]
	head.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	head.add_theme_color_override("font_color", _outcome_color(_my_result(item)))
	_detail_box.add_child(head)

	var hp := Label.new()
	hp.text = "%s  A %d : %d B" % [
		_text("法阵 HP", "Formation HP"),
		int(item.get("team_a_hp", 0)), int(item.get("team_b_hp", 0))]
	hp.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	_detail_box.add_child(hp)

	# 🔴 金币不是权威的时候要说出来。见文件顶部第 2 条。
	if not bool(item.get("gold_authoritative", false)):
		var note := Label.new()
		note.text = _text("金币为客户端上报值", "Gold is client-reported")
		note.add_theme_color_override("font_color", Tokens.TEXT_DISABLED)
		_detail_box.add_child(note)

	var seats: Array = (item.get("seats", []) as Array)
	for team in 2:
		var team_title := Label.new()
		team_title.text = _text("A 队", "Team A") if team == 0 else _text("B 队", "Team B")
		team_title.add_theme_color_override("font_color", Tokens.GOLD_EDGE)
		_detail_box.add_child(team_title)
		for seat in seats:
			if typeof(seat) != TYPE_DICTIONARY or int((seat as Dictionary).get("team", 0)) != team:
				continue
			_detail_box.add_child(_seat_row(seat as Dictionary, int(item.get("my_slot", -1))))

	_detail_box.add_child(_board_block(seats))


func _seat_row(seat: Dictionary, my_slot: int) -> Control:
	var slot := int(seat.get("slot", 0))
	var row := ACTION_BUTTON.instantiate() as Button
	row.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.text = "%s %s · %s %d · %s %d/%d" % [
		_seat_who(seat, my_slot),
		_seat_state(seat),
		_text("金币", "Gold"), int(seat.get("gold", 0)),
		_text("萝卜 剩/用", "Carrots left/used"),
		int(seat.get("carrots", 0)), int(seat.get("carrots_spent", 0)),
	]
	row.add_theme_color_override("font_color",
		Tokens.GOLD_EDGE if slot == _selected_slot else Tokens.TEXT_SECONDARY)
	row.pressed.connect(func() -> void:
		SfxService.play(SfxService.CUE_UI_POPUP)
		_selected_slot = slot
		_refresh_detail())
	return row


# 谁坐在这个座位上。
#
# **不显示别人的昵称** —— 历史接口只回 player_id，而昵称要另外一趟公开资料请求。
# 一局六个人 × 二十局 = 一百二十次请求，不值得。座位号足够定位，
# 「我」那一格标出来就够了。以后真要显示名字，是后端在 /v1/me/matches 里
# 顺带回昵称，而不是客户端一个个去问。
func _seat_who(seat: Dictionary, my_slot: int) -> String:
	var slot := int(seat.get("slot", 0))
	if slot == my_slot:
		return _text("我", "Me")
	if _seat_pid(seat).is_empty():
		return _text("AI", "AI")
	return "%s %d" % [_text("座位", "Seat"), slot + 1]


# ⚠️ **JSON 的 null 在 GDScript 里是 null 变体，而 str(null) 得到字面量 "<null>"。**
#
# AI 座位的 player_id 就是 null（database/013 允许它为空）。直接写
# `str(seat.get("player_id", "")).is_empty()` 的话，"<null>" 不是空串 ——
# AI 座位会被当成真人，再因为它 online_at_end=false 被标成「掉线未归」。
# 2026-09-22 由 tools/match_history_ui_check 抓到。同 ProfileScreen._field()
# 顶上那条警告，是同一个坑。
func _seat_pid(seat: Dictionary) -> String:
	var value: Variant = seat.get("player_id", null)
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


func _board_block(seats: Array) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE_RAISED, Tokens.GOLD_EDGE, Tokens.GAP_S))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(column)

	var title := Label.new()
	title.text = "%s %d %s" % [_text("座位", "Seat"), _selected_slot + 1, _text("的最终棋盘", "final board")]
	title.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	column.add_child(title)

	var seat := _seat_by_slot(seats, _selected_slot)
	var board: Array = (seat.get("board", []) as Array) if typeof(seat.get("board", [])) == TYPE_ARRAY else []
	if board.is_empty():
		var empty := Label.new()
		empty.text = _text("这一局没有记录到棋子", "No pieces recorded")
		empty.add_theme_color_override("font_color", Tokens.TEXT_DISABLED)
		column.add_child(empty)
	else:
		var grid := GridContainer.new()
		grid.columns = 8
		grid.add_theme_constant_override("h_separation", Tokens.GAP_S)
		grid.add_theme_constant_override("v_separation", Tokens.GAP_S)
		column.add_child(grid)
		for cell in board:
			if typeof(cell) == TYPE_DICTIONARY:
				grid.add_child(_piece(cell as Dictionary))

	var treasures: Array = (seat.get("treasures", []) as Array) if typeof(seat.get("treasures", [])) == TYPE_ARRAY else []
	if not treasures.is_empty():
		var line := Label.new()
		line.text = "%s %d" % [_text("宝藏", "Treasures"), treasures.size()]
		line.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
		column.add_child(line)
	return panel


func _seat_by_slot(seats: Array, slot: int) -> Dictionary:
	for seat in seats:
		if typeof(seat) == TYPE_DICTIONARY and int((seat as Dictionary).get("slot", -1)) == slot:
			return seat as Dictionary
	return {}


# 一个棋子：头像 + 名字 + 星级。
#
# 名字走 DataRegistry.unit_display_name()，**不是**战报里存的字符串 ——
# 战报里只有 id，而这正是当初把 uid / race_relations 排除在外的理由：
# 改过名的单位在历史里也要显示新名字（同 canonical_unit_def 那段注释）。
func _piece(cell: Dictionary) -> Control:
	var unit_id := str(cell.get("id", ""))
	var is_merc := bool(cell.get("merc", false))
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(PORTRAIT + 8, 0)
	box.add_theme_constant_override("separation", 2)

	var art := TextureRect.new()
	art.custom_minimum_size = Vector2(PORTRAIT, PORTRAIT)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var path := (MERC_PORTRAIT_DIR if is_merc else UNIT_PORTRAIT_DIR) + unit_id + ".png"
	# 缺图不是错误：历史里可能有已经下线的单位。留空格比留一个红叉好。
	if ResourceLoader.exists(path):
		art.texture = load(path)
	box.add_child(art)

	var name_label := Label.new()
	name_label.text = "%s ★%d" % [
		DataRegistry.unit_display_name({"id": unit_id}, _is_en()),
		clampi(int(cell.get("star", 1)), 1, 9),
	]
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	name_label.add_theme_color_override("font_color",
		Tokens.GOLD_EDGE if is_merc else Tokens.TEXT_SECONDARY)
	box.add_child(name_label)
	return box


# --- 文案 ---------------------------------------------------------------------

func _outcome_word(outcome: String) -> String:
	match outcome:
		"win": return _text("胜", "Win")
		"loss": return _text("负", "Loss")
		_: return _text("平", "Draw")


func _outcome_color(outcome: String) -> Color:
	match outcome:
		"win": return Tokens.TEXT_PRIMARY
		"loss": return Tokens.TEXT_DISABLED
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


func _is_en() -> bool:
	return LocaleManager.get_locale().begins_with("en")


func _text(zh: String, en: String) -> String:
	return en if _is_en() else zh
