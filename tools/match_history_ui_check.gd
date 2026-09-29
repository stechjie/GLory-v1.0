extends Node

# 门禁：对局历史界面（scenes/menu/MatchHistoryPanel.gd + 资料页里的入口）。
#
# 设计见 docs/排位系统设计.md 第八节。数据链路那一半的门禁在
# tools/battle_report_check.tscn 与 backend/tests/test_battle_report.py。
#
# ## 这条门禁验什么
#
# 五件**会静默出错**的事：
#
#   1. 汇总写成了「胜率 58%」。后端没有累计接口，这里只有拉回来的 20 条 ——
#      百分比看起来像生涯数据，是拿一个假数字骗人。文案必须带「最近 N 场」。
#   2. 胜负按队伍判错。outcome 是队伍级的（team_a / team_b），要按 my_slot
#      翻译成「我」的胜负。judge 反了的话，B 队的人看到的每一局胜负都是反的，
#      而且**看起来完全正常**。
#   3. 金币不权威时没标出来。影子期那个数其实来自客户端自报
#      （见 database/013_match_history.sql），不标就是拿它当权威数字用。
#   4. 「掉线未归」按 was_ai 判。座位断线 20 秒就转 AI，但转了之后玩家还能回来
#      —— 拿 was_ai 当跑路会冤枉一大片只是切了后台的人。判据必须是 online_at_end。
#   5. 资料页那个入口没了 / 战绩块退回全占位。那样这一整块功能玩家根本点不到。
#   6. （2026-09-29）名字：按账号现在的名字显示，「我」标出来；AI / 空位分清。
#   7. （2026-09-29）「详细战况」：点开就是打完那一刻的结算面板（FinalSettlementPanel 本身），
#      数据从历史接口的格式换过去不能丢东西、不能串座位；旧局没有详细战况时要说清楚。
#
# ## 为什么直接戳私有成员
#
# 面板在 _ready() 里就发网络请求，headless 下必然失败。这里**不打桩网络**，
# 而是等它失败完，再把假数据塞进 _matches 重新渲染 —— 验的是渲染逻辑，
# 不是 HTTP。同 tools/ 下其它探针直接读写 NetworkService._rooms 的做法。
#
# 跑：
#   godot --headless --path <项目> tools/match_history_ui_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const PanelScript := preload("res://scenes/menu/MatchHistoryPanel.gd")
const ProfileScreenScript := preload("res://scenes/menu/ProfileScreen.gd")

const CHECK_NAME := "match_history_ui"
const PANEL_PATH := "res://scenes/menu/MatchHistoryPanel.gd"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	await _case_summary_never_says_percentage()
	await _case_outcome_is_per_seat()
	await _case_teams_named_red_blue()
	await _case_gold_caveat_shown()
	await _case_offline_uses_online_at_end()
	await _case_names_are_current()
	_case_settlement_view_data()
	await _case_detail_opens_settlement_panel()
	_case_profile_entry_exists()
	_case_profile_shows_real_rank()
	_case_no_hand_rolled_buttons()
	_h.finish(get_tree())


# --- 夹具 ---------------------------------------------------------------------

# 一局。my_slot 决定「我」在哪一队，outcome 是队伍级结果。
func _match(my_slot: int, outcome: String, gold_auth: bool = true, seats_over: Dictionary = {}, settlement: Variant = null) -> Dictionary:
	var seats := []
	for slot in 6:
		var seat := {
			"slot": slot, "team": 0 if slot < 3 else 1,
			"player_id": null if slot == 5 else "1111111%d-1111-1111-1111-111111111111" % slot,
			"player_name": null if slot == 5 else "玩家%d号" % slot,
			"friend_code": null if slot == 5 else "CODE000%d" % slot,
			"was_ai": slot == 5, "online_at_end": slot != 5, "ai_rounds": 0,
			"gold": 137, "carrots": 12, "carrots_spent": 40,
			"board": [{"slot": 0, "id": "dark_dragon", "star": 3, "merc": false}],
			"treasures": [],
		}
		if seats_over.has(slot):
			seat.merge(seats_over[slot], true)
		seats.append(seat)
	return {
		"match_uid": "a".repeat(32), "mode": "custom", "rounds": 21, "outcome": outcome,
		"team_a_hp": 17, "team_b_hp": 0, "age_sec": 7200, "my_slot": my_slot,
		"gold_authoritative": gold_auth, "carrot_authoritative": true, "seats": seats,
		"settlement": settlement,
	}


# 023 的详细战况（后端原样返回的那种：统计是短键）。
func _settlement() -> Dictionary:
	var extras := []
	for slot in 6:
		extras.append({"stones": {"sky": slot}, "total_gold": 1000 + slot})
	return {
		"allies": ["圣骑守护", "暗影守护"],
		"seats": extras,
		"stats": [
			{"own": 3, "slot": 0, "id": "dark_dragon", "name": "暗黑巨龙", "star": 3, "merc": false,
			 "stack": 2, "dmg": 9000, "taken": 800, "heal": 5},
			{"own": 1, "slot": 1, "id": "merc_x", "name": "佣兵甲", "star": 0, "merc": true,
			 "stack": 0, "dmg": 100, "taken": 50, "heal": 0},
		],
	}


# 建面板、等它把那趟必然失败的网络请求走完，再塞假数据重新渲染。
func _panel_with(matches: Array) -> Control:
	var panel := PanelScript.new() as Control
	add_child(panel)
	await get_tree().process_frame
	await get_tree().process_frame
	panel.set("_matches", matches)
	panel.call("_refresh_summary")
	panel.call("_refresh_list")
	if not matches.is_empty():
		panel.call("_select_match", 0)
	await get_tree().process_frame
	return panel


# --- 1. 汇总不许出现百分比 -------------------------------------------------------

func _case_summary_never_says_percentage() -> void:
	var panel := await _panel_with([
		_match(0, "team_a"), _match(0, "team_b"), _match(0, "team_a"), _match(0, "draw"),
	])
	var summary := str(panel.get("_summary").text)
	_h.expect(summary.contains("最近"), "summary_missing_window",
		"汇总没写「最近 N 场」：%s —— 这是拉回来的窗口，不是生涯统计" % summary)
	_h.expect(not summary.contains("%"), "summary_says_percentage",
		"汇总里出现了百分比：%s —— 后端没有累计接口，百分比是假数据" % summary)
	_h.expect(summary.contains("4"), "summary_wrong_count",
		"汇总里的场次不是 4：%s" % summary)
	# 源码层面再钉一道：以后有人加「胜率」时这一条会先红。
	# **只看代码行** —— 注释里正是在解释「不许这么写」，扫进去会自己红自己。
	_h.expect(not _code(PANEL_PATH).contains("胜率"), "source_mentions_winrate",
		"MatchHistoryPanel.gd 的代码里出现了「胜率」—— 只有窗口数据时不许这么写")
	panel.queue_free()


# --- 2. 胜负按我的座位翻译 --------------------------------------------------------

func _case_outcome_is_per_seat() -> void:
	var panel := await _panel_with([])
	# slot 0~2 是 A 队，slot 3~5 是 B 队（GameConstants.team_of_slot）。
	# 同一个 outcome，两队看到的结果必须相反。
	for expected in [[0, "team_a", "win"], [4, "team_a", "loss"],
			[4, "team_b", "win"], [1, "team_b", "loss"], [2, "draw", "draw"]]:
		var got := str(panel.call("_my_result", _match(int(expected[0]), str(expected[1]))))
		_h.expect(got == str(expected[2]), "outcome_per_seat_wrong",
			"座位 %d 遇上 %s 应该是 %s，实际 %s" % [
				int(expected[0]), str(expected[1]), str(expected[2]), got])
	panel.queue_free()


# --- 3. 队伍名是「红队 / 蓝队」，不是「A 队 / B 队」 --------------------------------

# 9.29 bug 文档第 2 条：战斗画面顶部是「左红水晶 / 右蓝水晶」，3v3 大厅也是「上方红队 /
# 下方蓝队」，对局历史里却写 A 队 / B 队 —— 玩家对不上号。改名后口径统一。
#
# 两条断言缺一不可：
#   · 行为：渲染出来的文本里**必须出现**「红队」「蓝队」，且**不许再出现**「A 队」「B 队」。
#   · 结构：源码里不许再有 A 队/B 队的字面量 —— 否则只要有一处漏改，某条渲染路径就退回旧词。
# 映射方向也钉死：team 0 = 红队、team 1 = 蓝队（GameConstants.TEAM_RED=0 / TEAM_BLUE=1）。
func _case_teams_named_red_blue() -> void:
	var panel := await _panel_with([_match(0, "team_a")])
	var texts := _texts(panel)
	_h.expect(texts.any(func(t): return t.contains("红队")), "team_red_missing",
		"对局历史里没有「红队」—— 队伍名没改过来")
	_h.expect(texts.any(func(t): return t.contains("蓝队")), "team_blue_missing",
		"对局历史里没有「蓝队」—— 队伍名没改过来")
	_h.expect(not texts.any(func(t): return t.contains("A 队") or t.contains("B 队")),
		"old_team_label_present",
		"对局历史里还残留「A 队 / B 队」—— 玩家对不上战斗里的红蓝水晶")
	panel.queue_free()

	# 结构断言：源码（去注释后）不许再有 A 队/B 队的字面量。
	var code := _code(PANEL_PATH)
	for bad in ["\"A 队\"", "\"B 队\"", "\"Team A\"", "\"Team B\""]:
		_h.expect(not code.contains(bad), "old_team_label_in_source",
			"MatchHistoryPanel.gd 的代码里还有 %s 字面量" % bad)
	# 结构断言：红队/蓝队必须与 team 索引绑定（team 0 -> 红、team 1 -> 蓝）。
	_h.expect(code.contains("\"红队\""), "red_team_literal_missing",
		"源码里没有「红队」字面量")
	_h.expect(code.contains("\"蓝队\""), "blue_team_literal_missing",
		"源码里没有「蓝队」字面量")


# --- 4. 金币不权威时要标出来 -----------------------------------------------------

func _case_gold_caveat_shown() -> void:
	var shadow := await _panel_with([_match(0, "team_a", false)])
	_h.expect(_texts(shadow).any(func(t): return t.contains("客户端上报")),
		"gold_caveat_missing",
		"gold_authoritative=false 时没标明金币来自客户端上报 —— 那就是拿它当权威数字")
	shadow.queue_free()

	var authoritative := await _panel_with([_match(0, "team_a", true)])
	_h.expect(not _texts(authoritative).any(func(t): return t.contains("客户端上报")),
		"gold_caveat_always_on",
		"gold_authoritative=true 时还在标「客户端上报」—— 那条提示会变成噪音")
	authoritative.queue_free()


# --- 4. 「掉线未归」判的是 online_at_end，不是 was_ai --------------------------------

func _case_offline_uses_online_at_end() -> void:
	# 中途转过 AI、但结束时人回来了：**不算跑路**。
	# 座位断线 20 秒就转 AI（RESERVE_GRACE_SEC），而 _resume_seat 让他还能回来。
	var came_back := await _panel_with([_match(0, "team_a", true, {
		1: {"was_ai": true, "online_at_end": true, "ai_rounds": 4},
	})])
	var texts := _texts(came_back)
	_h.expect(not texts.any(func(t): return t.contains("掉线未归")),
		"ai_misread_as_leaver",
		"was_ai=true 但结束时在线的座位被标成了「掉线未归」—— 切个后台就被冤枉")
	_h.expect(texts.any(func(t): return t.contains("中途断线")),
		"ai_rounds_not_shown", "AI 代打过的回合数没显示出来")
	came_back.queue_free()

	# 结束时确实没回来：要标出来。
	var left := await _panel_with([_match(0, "team_a", true, {
		1: {"was_ai": true, "online_at_end": false, "ai_rounds": 9},
	})])
	_h.expect(_texts(left).any(func(t): return t.contains("掉线未归")),
		"leaver_not_shown", "结束时不在线的座位没被标出来")
	left.queue_free()


# --- 6. 名字：账号现在的名字 ------------------------------------------------------

func _case_names_are_current() -> void:
	var panel := await _panel_with([_match(3, "team_b", true, {
		4: {"player_id": null, "player_name": null, "friend_code": null, "was_ai": false, "board": []},
	})])
	var texts := _texts(panel)
	_h.expect(texts.any(func(t): return t.contains("玩家3号 #CODE0003（我）")), "my_name_missing",
		"我那一行应该是「名字 #好友码（我）」")
	_h.expect(texts.any(func(t): return t.contains("玩家0号 #CODE0000")), "other_name_missing",
		"别人的座位应该显示账号的名字，不是「座位 N」")
	_h.expect(texts.any(func(t): return t.begins_with("AI")), "ai_seat_missing", "AI 座位要写 AI")
	_h.expect(texts.any(func(t): return t.begins_with("空位")), "empty_seat_missing",
		"没账号、不是 AI、也没棋子的座位是空位")
	_h.expect(not texts.any(func(t): return t.contains("座位 ")), "seat_number_left",
		"还在用「座位 N」—— 现在有名字了")
	panel.queue_free()


# --- 7. 详细战况 ------------------------------------------------------------------

func _case_settlement_view_data() -> void:
	var item := _match(3, "team_b", false, {
		3: {"board": [
			{"slot": 7, "id": "dark_dragon", "star": 3, "merc": false},
			{"slot": 0, "id": "merc_x", "star": 1, "merc": true},
		], "treasures": ["treasure_blood_pact"]},
	}, _settlement())
	var data: Dictionary = PanelScript.settlement_view_data(item)
	_eq(int(data.get("outcome", -1)), 1, "view_outcome", "team_b 应该换成 1（蓝队）")
	_eq(bool(data.get("can_return_room", true)), false, "view_can_return", "历史里不能有「返回房间」")
	_eq(data.get("allies", []), ["圣骑守护", "暗影守护"], "view_allies", "法阵守护照抄")
	var seats: Array = data.get("seats", [])
	_eq(seats.size(), 6, "view_seat_count", "永远六个座位")
	var mine: Dictionary = seats[3]
	_eq(str(mine.get("name", "")), "玩家3号 #CODE0003（我）", "view_my_name", "我那个座位的名字")
	_eq(mine.get("board", []), [{"id": "dark_dragon", "star": 3, "slot": 7}], "view_board",
		"棋盘只放 merc=false 的，带位置")
	_eq(mine.get("mercenaries", []), [{"id": "merc_x", "star": 1, "slot": 0}], "view_mercs",
		"merc=true 的进佣兵列")
	_h.expect((mine.get("treasures", []) as Array).has("treasure_blood_pact"), "view_treasures",
		"宝藏照抄（再按结算面板的规则补上联动 / 套装）")
	_eq(mine.get("stones", {}), {"sky": 3}, "view_stones", "升级石取 settlement.seats[3]，不能串座位")
	_eq(int(mine.get("total_gold", 0)), 1003, "view_total_gold", "总金币取 settlement.seats[3]")
	_eq(str((seats[5] as Dictionary).get("name", "")), "AI", "view_ai_name", "AI 座位叫 AI")
	var stat: Dictionary = (data.get("stats", []) as Array)[0]
	for key in ["owner_slot", "slot", "id", "name", "star", "is_mercenary", "skill_stacks",
			"damage_dealt", "damage_taken", "healing_done"]:
		_h.expect(stat.has(key), "view_stat_key", "统计要换回结算面板认的键：缺 %s" % key)
	_eq([int(stat.owner_slot), int(stat.damage_dealt), int(stat.skill_stacks)], [3, 9000, 2],
		"view_stat_values", "统计的值照抄")
	_eq(PanelScript.settlement_view_data(_match(0, "team_a")), {}, "view_no_settlement",
		"023 之前的局（settlement 为 null）返回空字典")


func _case_detail_opens_settlement_panel() -> void:
	# 旧局：不给按钮，给一句说明。
	var old := await _panel_with([_match(0, "team_a")])
	var old_texts := _texts(old)
	_h.expect(not old_texts.has("详细战况"), "old_match_has_button", "没有详细战况的旧局不该有按钮")
	_h.expect(old_texts.any(func(t): return t.contains("没有详细战况")), "old_match_silent",
		"旧局要说明为什么看不了")
	old.queue_free()

	var panel := await _panel_with([_match(3, "team_b", true, {}, _settlement())])
	var button := _button_with_text(panel, "详细战况")
	if not _h.expect(button != null, "detail_button_missing", "有详细战况的局没有「详细战况」按钮"):
		panel.queue_free()
		return
	button.pressed.emit()
	await get_tree().process_frame
	_h.expect(ModalStack.has(PanelScript.DETAIL_MODAL_ID), "detail_not_opened", "点了「详细战况」没弹出来")
	var top: Dictionary = ModalStack.top()
	var content: Variant = top.get("content")
	_h.expect(content != null and (content as Object).get_script() == PanelScript.SettlementPanel,
		"detail_not_settlement_panel", "弹出来的不是结算面板本身（要直接搬，不是另画一份）")
	if content != null:
		var texts := _texts(content as Node)
		_h.expect(texts.has("关闭") and not texts.has("返回主菜单"), "detail_close_text",
			"历史里那颗按钮应该叫「关闭」，不是「返回主菜单」")
		_h.expect(texts.any(func(t): return t.contains("暗黑巨龙")), "detail_stats_missing",
			"统计面板里没有最后一战的棋子")
		var close := _button_with_text(content as Node, "关闭")
		if close != null:
			close.pressed.emit()
			await get_tree().process_frame
		_h.expect(not ModalStack.has(PanelScript.DETAIL_MODAL_ID), "detail_not_closed", "点「关闭」没关掉")
	ModalStack.pop(PanelScript.DETAIL_MODAL_ID)
	panel.queue_free()


func _button_with_text(root: Node, text: String) -> Button:
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is Button and (node as Button).text == text:
			return node as Button
		for child in node.get_children():
			stack.append(child)
	return null


# --- 5. 资料页的入口 -------------------------------------------------------------

func _case_profile_entry_exists() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/menu/ProfileScreen.gd")
	_h.expect(src.contains("_record_block"), "profile_block_missing",
		"资料页没有 _record_block —— 战绩块退回全占位了")
	_h.expect(src.contains("HISTORY_MODAL_ID"), "profile_modal_id_missing",
		"资料页没有历史面板的 modal id")
	# 🔴 页面关掉时必须把浮层一起收走，否则它留在 ModalStack 上盖住主菜单
	# （头像选择器当初就是为这条加的 _exit_tree）。
	var exit_body := src.split("func _exit_tree()")[1].split("func ")[0] if src.contains("func _exit_tree()") else ""
	_h.expect(exit_body.contains("HISTORY_MODAL_ID"), "profile_modal_leak",
		"_exit_tree 没有 pop 历史面板 —— 关掉资料页后它会盖住主菜单")
	# 占位版那三行里的「场次 / 胜率」不该再出现：它现在是真入口。
	_h.expect(not src.contains("场次 / 胜率"), "profile_stale_placeholder",
		"资料页还留着「场次 / 胜率」占位行")


# --- 5b. 战绩块显示真段位（第 5c 步）---------------------------------------------

func _case_profile_shows_real_rank() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/menu/ProfileScreen.gd")
	var code := _code("res://scenes/menu/ProfileScreen.gd")
	_eq(src.contains("_load_ranked"), true, "profile_loads_ranked",
		"资料页没拉 /v1/me/ranked —— 战绩块退回占位了")
	_eq(src.contains("TIER_NAMES_ZH"), true, "tier_names_exist", "缺段位名表")

	# 八个段位名，和后端的 TIER_COUNT 对齐。少一个的话最高段会显示成越界或空。
	var zh := src.split("const TIER_NAMES_ZH := [")[1].split("]")[0]
	_eq(zh.split(",").size(), 8, "tier_names_count", "段位名不是 8 个")
	var py := FileAccess.get_file_as_string("res://backend/app/ranked.py")
	_eq(py.contains("TIER_COUNT = 8"), true, "tier_count_matches", "后端的段位数不是 8")

	# 🔴 **客户端不许自己算段位。** 服务器发的是 tier / tier_progress
	# （backend/app/ranked.py 的 tier_of 是唯一口径）。客户端再除一遍就是第二个真相，
	# 改段位宽窄时两边会分叉，而且**不报错** —— 只是有人的段位显示得不对。
	#
	# 判据是「用了服务器那两个字段」+「没有拿 score 去除」。
	# ⚠️ 第一版写成扫 `100)` 与 `/ 100`，结果撞上了 `body.get("credit", 100)` 这个
	# **默认值**和显示用的 `"%d/100"` —— 断言太宽会把对的代码报成错的。
	_eq(code.contains("body.get(\"tier\""), true, "uses_server_tier",
		"资料页没用服务器发的 tier")
	_eq(code.contains("body.get(\"tier_progress\""), true, "uses_server_progress",
		"资料页没用服务器发的 tier_progress")
	for bad in ["score / ", "score/", "/ TIER_SIZE", "score %"]:
		_eq(code.contains(bad), false, "client_computes_tier",
			"资料页里出现了 `%s` —— 段位换算的口径只在服务器" % bad)

	# 信誉分只给自己看（第四节）。PUBLIC 模式连这个块都不渲染。
	_eq(src.split("if _mode == Mode.SELF:")[1].split("else:")[0].contains("_record_block"),
		true, "record_block_is_self_only", "战绩块跑到 PUBLIC 模式去了")

	# 不放假数据：拉不到时留「—」，不显示 0。0 分是一个看起来正常的错值。
	_eq(code.contains("\"—\""), true, "placeholder_is_dash",
		"战绩块的初值不是「—」—— 显示 0 会让玩家以为自己掉段了")


# --- 6. 不许自绘按钮 -------------------------------------------------------------

func _case_no_hand_rolled_buttons() -> void:
	# procedural_ui_ratchet 的单文件计数只许降。新文件基线是 0，写一个就红 ——
	# 这里先红一次，报的话比那边的差异列表好读。
	_h.expect(not _code(PANEL_PATH).contains("Button.new()"), "hand_rolled_button",
		"MatchHistoryPanel.gd 的代码里有 Button.new() —— 一律实例化 GloryActionButton.tscn")
	_h.expect(FileAccess.get_file_as_string(PANEL_PATH).contains("GloryActionButton.tscn"),
		"action_button_missing", "MatchHistoryPanel.gd 没用 GloryActionButton.tscn")


# --- 小工具 ---------------------------------------------------------------------

# 去掉整行注释之后的源码。扫「代码里有没有写 X」的断言必须走这个 ——
# 直接扫全文会把「注释里解释为什么不许写 X」也算成违规。
func _code(path: String) -> String:
	var kept: Array[String] = []
	for line in FileAccess.get_file_as_string(path).split("
"):
		if not str(line).strip_edges().begins_with("#"):
			kept.append(str(line))
	return "
".join(kept)


func _texts(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is Label:
			out.append(str((node as Label).text))
		elif node is Button:
			out.append(str((node as Button).text))
		for child in node.get_children():
			stack.append(child)
	return out


# CheckHarness.expect 是 (条件, code, 文案) 三参数。这里的断言多是「相等」，
# 每处手写 `a == b` 会让失败信息丢掉实际值 —— 包一层，把两边都打出来。
# 同 tools/matchmaking_check.gd 里的那一个。
func _eq(got, want, code: String, message: String) -> void:
	_h.expect(got == want, code, "%s（实际 %s，期望 %s）" % [message, str(got), str(want)])
