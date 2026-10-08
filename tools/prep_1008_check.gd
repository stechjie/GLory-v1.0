extends Node

# 10.08 反馈（10.08bug提交及修复.docx，9 条）里**能用 headless 驱动的那几条**的行为/几何判据。
# 逐条对应：
#
#   第 1 条  结算/统计面板：英文下不再残留中文；「（N层）」只在人王身上出现
#   第 2 条  图鉴分类按钮宽高统一；种族图标有长按入口且能拿到羁绊文本
#   第 4 条  备战准备头像改「上下两行」（不再是一排）
#   第 6 条  背包头像「点第一个跳到最后一个」——真事件（触摸 / 鼠标 / Android 双路）
#             逐个瓦片断言「点谁选谁」，视口取基准 + 两个手机画布尺寸
#   第 9 条  出售区恢复原尺寸 ＋ 商店 UI / 金图标处能卖（视觉区与命中区解耦），
#             三个分辨率下都不许把红区撑大（撑大会吃掉刷新按钮和待命区）
#
# **没进这个门禁的条目**（各有出口）：
#   第 7 条  好友码键盘自动隐藏 — 纯逻辑可判（见 _case_structure_guards），但输入法行为
#             真机才能确认，这里只钉住「重建列表不得踩掉正在编辑的输入框」
#   第 8 条  房间 ghost 成员 — 后端 Python，`backend/tests/test_party_presence_stdlib.py`
#
# 跑法：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/prep_1008_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const CodexScreen := preload("res://scenes/menu/CodexScreen.tscn")
const SettlementPanel := preload("res://scenes/menu/FinalSettlementPanel.gd")
const SynergyPanel := preload("res://scenes/prep/panels/SynergyPanel.gd")
const BattleScript := preload("res://scenes/battle/BattleScreen.gd")

const CHECK_NAME := "prep_1008"
const VIEW := Vector2i(1600, 1600)
# 出售红区的原尺寸高度（PrepUI 里按 SHOP_POPUP_SIZE 定的几何）。
# ★ 不许靠「把红区改大」去覆盖商店 —— 命中范围走 _point_in_sell_coverage()。
const SELL_OVERLAY_HEIGHT := 150.0
# 第 9 条必须多分辨率都过：10.08b 的撑大事故只在手机画布上才暴露。
const SELL_VIEWPORTS := [Vector2i(1600, 720), Vector2i(1280, 720), Vector2i(2340, 1080)]

# 第 1 条对照用的 fixtures（全部取自真实数据表 / 真实译文，写死的正是数据里的值）。
# 人王是数据里**唯一** skill_id == unique_king_growth 的棋子；痛苦女王的
# same_target_damage_stack 会把 skill_stacks 叠起来 —— 正是它被错当成「层数」贴到别人身上。
const KING_UNIT_ID := "human_king"
const KING_ZH_NAME := "人王"
const KING_EN_NAME := "Human King"
const KING_SLOT := 0
const NON_KING_UNIT_ID := "dark_queen"
const QUEEN_ZH_NAME := "痛苦女王"
const QUEEN_EN_NAME := "Pain Queen"
const QUEEN_SLOT := 3
# 痛苦女王战斗里被同一目标叠加出来的技能层数：必须是它以前能被错当成人王层数的那个数。
const STACKS_FROM_SKILL := 4
const TREASURE_ID := "def_iron_wall"
const TREASURE_ZH_NAME := "铁壁之护"
const TREASURE_EN_NAME := "Iron Wall"
# 人王这次带了 5 层（1 层起，活过 4 场）。
const KING_STACKS_VALUE := 5

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	await _case_bug9_sell_zone_restored_and_store_sellable()
	await _case_bug4_ready_avatars_two_rows()
	_case_bug1_settlement_localized_and_king_stacks()
	await _case_bug1_history_path_localized()
	_case_bug2_codex_tabs_and_race_long_press()
	await _case_bug35_background_clock_and_frame_cap()
	await _case_bug6_bag_avatar_tap()
	_case_structure_guards()
	# 前提体检：各用例至少要贡献若干条 checked；总数对不上就是有用例没跑到。
	# 10.08c 补判据后实测 163 条；门槛跟着往上抬（低于 155 说明有用例整体没跑到）。
	_h.expect(_h.checked_count() >= 155, "cases_not_executed",
		"检查项只有 %d 条（应 ≥155）—— 有用例没跑到（多半是忘了 await），门禁在无声失效"
			% _h.checked_count())
	_h.finish(get_tree())


# ── 第 9 条：出售区「恢复原尺寸」+「商店 UI / 金图标也能卖」 ────────────────────
#
# ★ 10.08c 真机返工（必读，防止回退）：
#   10.08b 的修法是「把红区运行时按布局拉宽去盖住商店弹窗和钱袋」，结果在手机画布上
#   红区被撑成一个巨框 —— 压住商店刷新按钮（用户报「商店打开后没有刷新按钮」），
#   并且盖住待命区导致棋子拖不回去（用户报「售卖区被异常放大，棋子无法回到待命区」）。
#
#   ⇒ 现在的口径是**视觉区与命中区解耦**：
#       * 看得见的红区（sell_overlay）维持**原尺寸**（底部中央一条，高 150）；
#       * 看不见的命中范围由 PrepBoardController._point_in_sell_coverage() 单独放宽
#         （红区 ∪ 商店弹窗 ∪ 侧栏钱袋/金图标），在 _on_drag_ended 里抢先按出售处理。
#
#   ⇒ 所以判据分两半：**不许红区变大**（反向）＋**命中必须够宽**（正向），缺一半
#     就会被「把红区拉满屏」这类写法骗过去。
#   ⇒ 还必须多分辨率都跑：10.08b 那次就是只在基准 1600×720 下看着没问题。
func _case_bug9_sell_zone_restored_and_store_sellable() -> void:
	for size in SELL_VIEWPORTS:
		await _bug9_at(size)


func _bug9_at(viewport_size: Vector2i) -> void:
	var tag := str(viewport_size)
	NetworkService.team_active = true
	GameState.reset_run()
	GameState.tutorial_mode = false
	var prep := await _build_prep(viewport_size)
	if prep == null:
		_h.fail("prep_unavailable_bug9_" + tag, "PrepScreen 无法实例化，出售区判据无法执行")
		_restore_network()
		return
	var shop: Object = prep.get("_shop")
	if shop == null:
		_h.fail("shop_missing_bug9_" + tag, "PrepScreen 上没有 _shop")
		await _teardown_node(prep)
		_restore_network()
		return
	# 打开商店（走真实入口，side_controls 的显隐才会同步），再进拖拽态让红区显示。
	if not bool(shop.get("picker_open")):
		shop.toggle_picker()
	await get_tree().process_frame
	await get_tree().process_frame
	prep._on_drag_started({"kind": "board", "index": 0})
	await get_tree().process_frame
	await get_tree().process_frame

	var overlay: Control = shop.get("sell_overlay")
	if overlay == null or not is_instance_valid(overlay):
		_h.fail("sell_overlay_missing_bug9_" + tag, "红区 _shop.sell_overlay 不存在")
		await _teardown_node(prep)
		_restore_network()
		return

	_h.expect(overlay.visible, "bug9_overlay_visible_while_dragging_" + tag,
		"拖动棋盘棋子时出售红区应当显示，实际 visible=false")

	var zone := overlay.get_global_rect()
	# ① 反向：红区必须是**原尺寸**。撑大就是用户报的「售卖区被异常放大」。
	_h.expect(absf(zone.size.y - SELL_OVERLAY_HEIGHT) <= 2.0,
		"bug9_overlay_restored_size_" + tag,
		"出售红区高度应恢复为原尺寸 %.0f，实测 %.1f（%s）—— 撑大会挡住待命区与刷新按钮"
			% [SELL_OVERLAY_HEIGHT, zone.size.y, tag])

	# ② 反向：侧栏控件（钱袋 / 刷新）不得被红区压住。
	var side: Control = shop.get("side_controls")
	var gold_rect := Rect2()
	var covered: Array[String] = []
	if side != null and is_instance_valid(side):
		for child in side.get_children():
			if not (child is Control):
				continue
			var kid := child as Control
			if gold_rect.size.x <= 0.0 and kid.get_child_count() >= 5:
				gold_rect = kid.get_global_rect()
			if kid.visible and kid.get_global_rect().intersects(zone):
				covered.append(String(kid.name))
	_h.expect(covered.is_empty(), "bug9_overlay_not_covering_side_controls_" + tag,
		"红区不得压住侧挂控件（钱袋/刷新），%s 下压住 %d 个：%s"
			% [tag, covered.size(), str(covered.slice(0, 5))])

	# ③ 正向：商店刷新按钮必须看得见、也没被压住（10.08c 真机报「没有刷新按钮」）。
	var refresh: Control = shop.get("refresh_button")
	if refresh == null or not is_instance_valid(refresh):
		_h.fail("bug9_refresh_button_missing_" + tag, "商店上找不到 refresh_button")
	else:
		_h.expect(refresh.visible, "bug9_refresh_button_visible_" + tag,
			"商店打开后刷新按钮必须可见（%s 实测 visible=%s）" % [tag, str(refresh.visible)])
		_h.expect(not refresh.get_global_rect().intersects(zone),
			"bug9_refresh_button_not_covered_" + tag,
			"刷新按钮不得被红区压住：按钮=%s 红区=%s（%s）"
				% [str(refresh.get_global_rect()), str(zone), tag])

	# ④ 正向：命中判定要覆盖商店弹窗、商店**卡片**、钱袋 A（金图标）——
	#    这是「能在商店 UI / 金图标处卖掉」的唯一实现路径（不再靠把红区撑大）。
	#    ★ 必须专门取「卡片所在的位置」：面板几何中心恰好落在红区里，只测它会假绿
	#      —— narrow 变异（命中区退回「只有红区」）实测只有钱袋那半条变红。
	var card_pts: Array[Vector2] = []
	var cards: Array = shop.get("buttons")
	if cards != null:
		for b in cards:
			if b is Control and is_instance_valid(b) and (b as Control).visible:
				card_pts.append((b as Control).get_global_rect().get_center())
	_h.expect(not card_pts.is_empty(), "bug9_shop_cards_found_" + tag,
		"商店打开后拿不到任何可见卡片（%s）—— 「在商店 UI 处能卖」无处可测" % tag)
	var missing_cards: Array[String] = []
	for cp in card_pts:
		if not bool(prep._point_in_sell_coverage(cp)):
			missing_cards.append(str(cp.round()))
	_h.expect(missing_cards.is_empty(), "bug9_coverage_hits_shop_cards_" + tag,
		"商店卡片中心必须能卖（%s），实测命中=false 的卡片：%s"
			% [tag, str(missing_cards.slice(0, 5))])
	var panel: Control = shop.get("panel")
	if panel != null and is_instance_valid(panel) and panel.visible:
		var pc: Vector2 = panel.get_global_rect().get_center()
		_h.expect(bool(prep._point_in_sell_coverage(pc)), "bug9_coverage_hits_shop_panel_" + tag,
			"商店弹窗中心必须能卖（%s 实测命中=false @ %s）" % [tag, str(pc.round())])
	_h.expect(gold_rect.size.x > 0.0, "bug9_gold_area_found_" + tag,
		"没能定位钱袋 A（side_controls 里应有 child_count>=5 的 Control），"
		+ "第 9 条的「金图标处能卖」无处可测")
	if gold_rect.size.x > 0.0:
		var gc := gold_rect.get_center()
		_h.expect(bool(prep._point_in_sell_coverage(gc)), "bug9_coverage_hits_gold_area_" + tag,
			"钱袋 A（金图标）中心必须能卖（%s 实测命中=false @ %s）" % [tag, str(gc.round())])

	# ⑤ 反向对照：棋盘中心**不能**算可出售，否则正常拖动会被误卖。
	#    ★ 这一条兼作判别力：命中区一旦退化成「整屏都算」，它会立刻变红。
	var vrect := get_viewport().get_visible_rect()
	var board_pt := Vector2(vrect.size.x * 0.5, vrect.size.y * 0.36)
	_h.expect(not bool(prep._point_in_sell_coverage(board_pt)),
		"bug9_coverage_ignores_board_" + tag,
		"棋盘中心不得算可出售（%s 实测命中=true @ %s）—— 否则正常拖动会被误卖"
			% [tag, str(board_pt.round())])

	# ⑥ 反向对照：空闲态红区必须隐藏（否则商店整块变成隐性出售区）。
	prep._on_drag_ended()
	await get_tree().process_frame
	_h.expect(not overlay.visible, "bug9_overlay_hidden_when_idle_" + tag,
		"拖拽结束后出售红区应当隐藏（否则商店整块变成隐性出售区）")

	await _teardown_node(prep)
	_restore_network()


# ── 第 4 条：准备头像改上下两行 ────────────────────────────────────────────────
#
# 判据是**结构**：自己队与对面不再并排在同一行，而是各自成行。
# 直接量 6 个徽章的中心 y / x：一排时 y 全相同、x 递增；两行时 y 分成两档。
func _case_bug4_ready_avatars_two_rows() -> void:
	NetworkService.team_active = true
	GameState.reset_run()
	GameState.tutorial_mode = false
	var prep := await _build_prep()
	if prep == null:
		_h.fail("prep_unavailable_bug4", "PrepScreen 无法实例化，头像布局判据无法执行")
		_restore_network()
		return
	var dots: Array = prep.get("_ready_dots")
	_h.expect(dots != null and dots.size() == 6, "bug4_six_avatar_badges",
		"准备头像应有 6 个徽章，实际 %d" % (dots.size() if dots != null else -1))
	if dots == null or dots.size() != 6:
		await _teardown_node(prep)
		_restore_network()
		return
	# 徽章可能还没被布局（尺寸 0），先等两帧。
	await get_tree().process_frame
	await get_tree().process_frame

	var rows: Dictionary = {}
	for i in 6:
		var badge: Control = dots[i]
		if badge == null or not is_instance_valid(badge):
			continue
		var c := badge.get_global_rect().get_center()
		rows[roundi(c.y)] = int(rows.get(roundi(c.y), 0)) + 1
	_h.expect(rows.size() == 2, "bug4_two_rows",
		"准备头像应当排成上下两行，实测中心 y 有 %d 档：%s" % [rows.size(), str(rows.keys())])
	# 每行 3 个。
	var per_row_ok := true
	for y in rows.keys():
		if int(rows[y]) != 3:
			per_row_ok = false
	_h.expect(per_row_ok, "bug4_three_per_row",
		"上下两行应当各 3 个头像，实际分布 %s" % str(rows))

	await _teardown_node(prep)
	_restore_network()


# ── 第 1 条：结算面板英文化 + 「（N层）」仅人王 ────────────────────────────────
func _case_bug1_settlement_localized_and_king_stacks() -> void:
	var prev_locale := LocaleManager.get_locale()
	# 这一条全靠读源码字面量，不走实例化（面板依赖整局结算数据，headless 造不出来）。
	var src := FileAccess.get_file_as_string("res://scenes/menu/FinalSettlementPanel.gd")
	_h.expect(not src.is_empty(), "bug1_source_readable", "读不到 FinalSettlementPanel.gd，判据无法执行")
	if src.is_empty():
		return
	# 结构判据：文件里不许再有「裸中文字面量」——除了注释。
	# 做法：剥离注释行，再找双引号里的中文。
	var offenders: Array[String] = []
	var line_no := 0
	for raw in src.split("\n"):
		line_no += 1
		var line := String(raw)
		var hash_at := line.find("#")
		var code := line if hash_at < 0 else line.substr(0, hash_at)
		if _has_cn_in_strings(code):
			offenders.append("%d: %s" % [line_no, line.strip_edges()])
	_h.expect(offenders.is_empty(), "bug1_no_bare_chinese_literals",
		"结算面板里仍有未走 tr() 的中文字面量（英文语言下不会切换）：\n%s"
			% "\n".join(offenders.slice(0, 8)))
	# 「（N层）」必须带人王判定（读的是 UnitGrowth 那套 king 判据），不能无条件加。
	_h.expect(src.contains("is_king") or src.contains("KING") or src.contains("king_growth"),
		"bug1_stacks_guarded_by_king",
		"「（N层）」必须只在人王身上出现，源码里找不到任何 king 相关判定")
	# ── 10.08c 真机返工：第 1 条其实是两条独立要求，各配一套判据 ─────────────────
	#
	#   (a) **英文语言下棋子的中文必须跟着变**：会漏的有三处取名字的路径 ——
	#       统计行 `_stat_unit_name`、上阵/佣兵头像 `_unit_name`、宝物 `_codex_name`。
	#       以前它们一律无条件读中文字段 `name`，面板就整块停在中文上。
	#   (b) **「（N层）」只属于人王**：以前读的是 `skill_stacks`（战斗内的技能计数，
	#       痛苦女王的 same_target_damage_stack 就会把它叠到 4），于是层数错贴给别人；
	#       而人王的**持久层数**记在**摆放格子**上（UnitGrowth.KING_STACKS），
	#       fighter 里本来没有 ⇒ 真正的人王一个数都显示不出来。
	#
	#   (b) 的修法是**三级接力**，任一级被删都不会报错、只会静默回到「0 层」：
	#       格子 → fighter    BattleSimShared._fighter_from_cell()
	#       fighter → 统计表  BattleSimulator.result_from_state()
	#       统计表 → 面板     FinalSettlementPanel._king_stacks()
	#   ⇒ 三级各给一条**行为**判据（都是静态函数，真跑一遍），再加**结构**锚，
	#     哪一级被删都能当场定位 —— 「改动每一处都要有判据」。
	#
	# 判据一共四层，缺一不可：
	#   ① 行为：真跑三级接力；非人王即便格子上带层数也必须落成 0
	#   ② 行为：真实例化面板两次（zh / en），读**树上 Label 的实际文本**
	#   ③ 行为：面板自己的取值函数逐个验双语 + 只认人王
	#   ④ 结构：三个源文件的落点锚（含「_king_stacks 不许再用 skill_stacks」）
	var Growth := preload("res://scripts/units/UnitGrowth.gd")
	var SimShared := preload("res://scripts/battle/BattleSimShared.gd")
	var Sim := preload("res://scripts/battle/BattleSimulator.gd")
	var king_def: Dictionary = DataRegistry.canonical_unit_def(KING_UNIT_ID)
	var queen_def: Dictionary = DataRegistry.canonical_unit_def(NON_KING_UNIT_ID)
	_h.expect(not king_def.is_empty(), "bug1_king_def_found",
		"数据表里找不到人王（%s）—— 后面的接力判据会在没有输入的情况下变绿" % KING_UNIT_ID)
	_h.expect(not queen_def.is_empty(), "bug1_non_king_def_found",
		"数据表里找不到用来对照的非人王棋子（%s）—— 「层数不贴错人」判不了" % NON_KING_UNIT_ID)
	if king_def.is_empty() or queen_def.is_empty():
		LocaleManager.set_locale(prev_locale)
		return
	# ①-1 格子 → fighter
	var king_cell := {
		"def": king_def.duplicate(true), "uid": "chk_king", "star": 1, "slot": 3,
		Growth.KING_STACKS: KING_STACKS_VALUE,
	}
	var king_fighter: Dictionary = SimShared._fighter_from_cell(king_cell, 3, "player")
	_h.expect(int(king_fighter.get(Growth.KING_STACKS, -1)) == KING_STACKS_VALUE,
		"bug1_relay_cell_to_fighter",
		"格子→fighter 断了：人王的 %d 层没被带上战场（fighter[%s]=%s）"
			% [KING_STACKS_VALUE, Growth.KING_STACKS, str(king_fighter.get(Growth.KING_STACKS, "字段缺失"))])
	# 反向：**非人王**即便格子上带着层数也必须落成 0 —— 这正是「痛苦女王二星（4层）」的来历。
	var queen_cell := {
		"def": queen_def.duplicate(true), "uid": "chk_queen", "star": 2, "slot": 4,
		Growth.KING_STACKS: KING_STACKS_VALUE + 2,
	}
	var queen_fighter: Dictionary = SimShared._fighter_from_cell(queen_cell, 4, "player")
	_h.expect(int(queen_fighter.get(Growth.KING_STACKS, -1)) == 0,
		"bug1_relay_non_king_stays_zero",
		"非人王（%s）不该被人王层数穿透：fighter[%s]=%s"
			% [NON_KING_UNIT_ID, Growth.KING_STACKS, str(queen_fighter.get(Growth.KING_STACKS, "字段缺失"))])
	# ①-2 fighter → unit_stats（走 forced_result 这条早返回分支，不碰整局结果逻辑）
	var king_uid := str(king_fighter.get("uid", ""))
	var relay_state := {
		"player": [king_fighter], "enemy": [],
		"unit_stats": {king_uid: {"id": KING_UNIT_ID, "name": KING_ZH_NAME, "name_en": KING_EN_NAME}},
		"forced_result": {"player_wins": true},
	}
	var relay_result: Dictionary = Sim.result_from_state(relay_state)
	var relay_stats: Dictionary = relay_state.get("unit_stats", {})
	var relay_entry: Dictionary = relay_stats.get(king_uid, {})
	_h.expect(int(relay_entry.get(Growth.KING_STACKS, -1)) == KING_STACKS_VALUE,
		"bug1_relay_fighter_to_stats",
		"fighter→unit_stats 断了：结算面板拿不到人王层数（unit_stats[%s][%s]=%s）"
			% [king_uid, Growth.KING_STACKS, str(relay_entry.get(Growth.KING_STACKS, "字段缺失"))])
	var result_stats: Dictionary = relay_result.get("unit_stats", {})
	_h.expect(int(Dictionary(result_stats.get(king_uid, {})).get(Growth.KING_STACKS, -1)) == KING_STACKS_VALUE,
		"bug1_relay_stats_in_result",
		"result_from_state 的返回值里丢了人王层数（FinalSettlementData 抄的是这一份）")

	# ② 真实例化整块面板各一次（zh / en），读树上 Label 的实际文本
	var king_stat := {
		"owner_slot": KING_SLOT, "id": KING_UNIT_ID, "slot": 3, "star": 1,
		"name": KING_ZH_NAME, "name_en": KING_EN_NAME,
		Growth.KING_STACKS: KING_STACKS_VALUE,
		"damage_dealt": 1200, "damage_taken": 300, "healing_done": 0,
	}
	var queen_stat := {
		"owner_slot": QUEEN_SLOT, "id": NON_KING_UNIT_ID, "slot": 4, "star": 2,
		"name": QUEEN_ZH_NAME, "name_en": QUEEN_EN_NAME,
		"skill_stacks": STACKS_FROM_SKILL,
		"damage_dealt": 900, "damage_taken": 500, "healing_done": 0,
	}
	# `skill_stacks` **必须 > 0**：它正是以前被错当成人王层数、贴到痛苦女王身上的那个数。
	_h.expect(int(queen_stat.get("skill_stacks", 0)) > 0, "bug1_queen_fixture_has_skill_stacks",
		"对照用的非人王棋子必须自带 skill_stacks > 0，否则「层数不贴错人」这条失去判别力")
	var seats: Array = []
	for i in 6:
		seats.append({"name": "Slot %d" % i, "board": [], "mercenaries": [], "treasures": [], "stones": {}, "total_gold": 10, "round_damage": 0})
	seats[KING_SLOT]["board"] = [{"id": KING_UNIT_ID, "star": 1, "slot": 3}]
	seats[QUEEN_SLOT]["board"] = [{"id": NON_KING_UNIT_ID, "star": 2, "slot": 4}]
	seats[KING_SLOT]["treasures"] = [TREASURE_ID]
	var settlement_data := {
		"local_team": 0, "outcome": 0, "allies": ["", ""],
		"seats": seats, "stats": [king_stat, queen_stat],
	}
	LocaleManager.set_locale("zh")
	var zh_texts := _build_settlement(settlement_data)
	var zh_units := _build_settlement_stat_units(settlement_data)
	# 期望串必须**在各自的 locale 下**拼：tr() 取的是当前语言，
	# 切回 prev_locale 之后再拼就会拿中文译文去比英文行（自己造一条假红）。
	var want_zh_king := KING_ZH_NAME + tr("settle_star_1") + (tr("settle_stacks") % KING_STACKS_VALUE)
	var want_zh_queen := QUEEN_ZH_NAME + tr("settle_star_2")
	LocaleManager.set_locale("en")
	var en_texts := _build_settlement(settlement_data)
	var en_units := _build_settlement_stat_units(settlement_data)
	var want_en_king := KING_EN_NAME + tr("settle_star_1") + (tr("settle_stacks") % KING_STACKS_VALUE)
	var want_en_queen := QUEEN_EN_NAME + tr("settle_star_2")
	LocaleManager.set_locale(prev_locale)
	_h.expect(not zh_texts.is_empty(), "bug1_zh_build_not_empty",
		"中文场景下整块面板一个 Label 都没造出来 —— 造不出东西时下面的双语判据全是空的")
	_h.expect(not en_texts.is_empty(), "bug1_en_build_not_empty",
		"英文场景下整块面板一个 Label 都没造出来 —— 下面的双语判据会是假的绿")
	_h.expect(zh_units.size() == 2 and en_units.size() == 2, "bug1_stats_rows_built",
		"统计表应当有两行（人王 + 痛苦女王），实测 zh=%d en=%d" % [zh_units.size(), en_units.size()])
	# (a) 正面：英文场景下**整块面板**不许残留中文（座位名用的是英文假数据，命中就是真 bug）
	var en_cn_rows: Array[String] = []
	for entry in en_texts:
		if _text_has_cn(String(entry)):
			en_cn_rows.append(String(entry))
	_h.expect(en_cn_rows.is_empty(), "bug1_en_has_no_chinese",
		"英文语言下结算面板仍有中文行：\n%s" % "\n".join(en_cn_rows.slice(0, 8)))
	# 中文场景反过来必须有中文（否则说明 locale 没切过去，上面那条会跟着一起假绿）
	var zh_has_cn := false
	for entry in zh_texts:
		if _text_has_cn(String(entry)):
			zh_has_cn = true
			break
	_h.expect(zh_has_cn, "bug1_zh_has_chinese",
		"中文场景下整块面板一个中文字都没有 —— 说明 locale 没切到 zh，双语判据不可信")
	if zh_units.size() == 2 and en_units.size() == 2:
		# (a)+(b) 合起来就是用户要的那一行：中文「人王一星（5层）」/ 英文「Human King★1 (5 stacks)」
		# 非人王一行两种语言都**不许**带层数。
		_h.expect(String(zh_units[0]) == want_zh_king, "bug1_zh_king_row",
			"中文人王行应为「%s」，实测「%s」" % [want_zh_king, String(zh_units[0])])
		_h.expect(String(zh_units[1]) == want_zh_queen, "bug1_zh_queen_row",
			"中文痛苦女王行应为「%s」（不带层数），实测「%s」" % [want_zh_queen, String(zh_units[1])])
		_h.expect(String(en_units[0]) == want_en_king, "bug1_en_king_row",
			"英文人王行应为「%s」，实测「%s」" % [want_en_king, String(en_units[0])])
		_h.expect(String(en_units[1]) == want_en_queen, "bug1_en_queen_row",
			"英文痛苦女王行应为「%s」（不带层数），实测「%s」" % [want_en_queen, String(en_units[1])])
		# 反向再钉一次：非人王行不许出现任何「层 / stack」字样
		_h.expect(not _has_layer_mark(String(en_units[1])), "bug1_en_queen_has_no_layer_mark",
			"非人王（%s）行仍带着层数标记：%s" % [NON_KING_UNIT_ID, String(en_units[1])])

	# ③ 面板取值函数逐个验（头像那行说明文字只在点击气泡里出现、不上树，只能直调）
	var probe := SettlementPanel.new()
	probe.data = settlement_data.duplicate(true)
	var treasure_entry: Dictionary = probe._treasure(TREASURE_ID)
	_h.expect(not treasure_entry.is_empty(), "bug1_treasure_fixture_found",
		"找不到用于对照的宝物 %s，双语宝物名判不了" % TREASURE_ID)
	LocaleManager.set_locale("zh")
	_h.expect(int(probe._king_stacks(king_stat)) == KING_STACKS_VALUE, "bug1_king_stacks_value_zh",
		"_king_stacks(人王) 应返回 %d，实测 %d" % [KING_STACKS_VALUE, int(probe._king_stacks(king_stat))])
	_h.expect(int(probe._king_stacks(queen_stat)) == 0, "bug1_king_stacks_skips_non_king",
		"_king_stacks(非人王) 应返回 0（不能读 skill_stacks=%d），实测 %d"
			% [STACKS_FROM_SKILL, int(probe._king_stacks(queen_stat))])
	_h.expect(probe._stat_unit_name(king_stat) == KING_ZH_NAME, "bug1_stat_unit_name_zh",
		"中文下 _stat_unit_name 应返回「%s」，实测「%s」" % [KING_ZH_NAME, probe._stat_unit_name(king_stat)])
	_h.expect(probe._unit_name(KING_UNIT_ID, false) == KING_ZH_NAME, "bug1_unit_name_zh",
		"中文下 _unit_name 应返回「%s」，实测「%s」" % [KING_ZH_NAME, probe._unit_name(KING_UNIT_ID, false)])
	_h.expect(probe._codex_name(treasure_entry, TREASURE_ID) == TREASURE_ZH_NAME, "bug1_codex_name_zh",
		"中文下宝物名应返回「%s」，实测「%s」" % [TREASURE_ZH_NAME, probe._codex_name(treasure_entry, TREASURE_ID)])
	_h.expect(probe._stacks_text(KING_SLOT, KING_UNIT_ID, 3) == tr("settle_stacks") % KING_STACKS_VALUE,
		"bug1_stacks_text_king_zh",
		"人王头像说明应带层数，实测「%s」" % probe._stacks_text(KING_SLOT, KING_UNIT_ID, 3))
	_h.expect(probe._stacks_text(QUEEN_SLOT, NON_KING_UNIT_ID, 4) == "", "bug1_stacks_text_queen_empty_zh",
		"非人王头像说明不该带层数，实测「%s」" % probe._stacks_text(QUEEN_SLOT, NON_KING_UNIT_ID, 4))
	LocaleManager.set_locale("en")
	_h.expect(probe._stat_unit_name(king_stat) == KING_EN_NAME, "bug1_stat_unit_name_en",
		"英文下 _stat_unit_name 仍返回中文「%s」—— 统计面板整列不会切换" % probe._stat_unit_name(king_stat))
	_h.expect(probe._unit_name(KING_UNIT_ID, false) == KING_EN_NAME, "bug1_unit_name_en",
		"英文下 _unit_name 仍返回中文「%s」—— 上阵头像不会切换" % probe._unit_name(KING_UNIT_ID, false))
	_h.expect(probe._unit_name(NON_KING_UNIT_ID, false) == QUEEN_EN_NAME, "bug1_unit_name_non_king_en",
		"英文下非人王的 _unit_name 应返回「%s」，实测「%s」" % [QUEEN_EN_NAME, probe._unit_name(NON_KING_UNIT_ID, false)])
	_h.expect(probe._codex_name(treasure_entry, TREASURE_ID) == TREASURE_EN_NAME, "bug1_codex_name_en",
		"英文下宝物名应返回「%s」，实测「%s」" % [TREASURE_EN_NAME, probe._codex_name(treasure_entry, TREASURE_ID)])
	_h.expect(int(probe._king_stacks(king_stat)) == KING_STACKS_VALUE, "bug1_king_stacks_value_en",
		"英文下 _king_stacks(人王) 也应是 %d，实测 %d" % [KING_STACKS_VALUE, int(probe._king_stacks(king_stat))])
	probe.free()

	# ④ 结构锚：三级接力各一处 + 「不许再用 skill_stacks 顶替」
	var clean := _strip_comments(src)
	var ff_body := _strip_comments(_fn_body(
		_clean_source("res://scripts/battle/BattleSimShared.gd"), "static func _fighter_from_cell("))
	_h.expect(ff_body.contains("UnitGrowth.KING_STACKS"), "bug1_simshared_anchor",
		"BattleSimShared._fighter_from_cell() 里不再写 UnitGrowth.KING_STACKS —— 第一级接力断了")
	var rf_body := _strip_comments(_fn_body(
		_clean_source("res://scripts/battle/BattleSimulator.gd"), "static func result_from_state("))
	_h.expect(rf_body.contains("UnitGrowth.KING_STACKS") and rf_body.contains("unit_stats"),
		"bug1_simulator_anchor",
		"BattleSimulator.result_from_state() 里不再往 unit_stats 抄 UnitGrowth.KING_STACKS —— 第二级接力断了")
	var ks_body := _strip_comments(_fn_body(clean, "func _king_stacks("))
	_h.expect(not ks_body.is_empty(), "bug1_king_stacks_fn_found", "找不到 FinalSettlementPanel._king_stacks()")
	_h.expect(ks_body.contains("Growth.KING_STACKS"), "bug1_king_stacks_reads_growth_key",
		"_king_stacks() 不读 Growth.KING_STACKS —— 第三级接力断了，层数恒 0")
	_h.expect(not ks_body.contains("skill_stacks"), "bug1_king_stacks_not_skill_stacks",
		"_king_stacks() 又回去读 skill_stacks 了 —— 那就是「痛苦女王（4层）」的来历")
	var stats_body := _strip_comments(_fn_body(clean, "func _stats("))
	_h.expect(stats_body.contains("_stat_unit_name("), "bug1_stats_row_localized",
		"统计行不再走 _stat_unit_name()（无条件读 name）⇒ 英文下一整列还是中文")
	_h.expect(stats_body.contains("_king_stacks("), "bug1_stats_row_king_stacks",
		"统计行不再走 _king_stacks() ⇒ 人王的层数显示不出来")
	var team_body := _strip_comments(_fn_body(clean, "func _team("))
	_h.expect(team_body.contains("_unit_name("), "bug1_board_icons_localized",
		"上阵/佣兵头像不再走 _unit_name() ⇒ 英文下不会切换")
	_h.expect(team_body.contains("_codex_name("), "bug1_treasure_icons_localized",
		"宝物头像不再走 _codex_name() ⇒ 英文下不会切换")
	var un_body := _strip_comments(_fn_body(clean, "func _unit_name("))
	_h.expect(un_body.contains("DataRegistry.unit_display_name") and un_body.contains("_english()"),
		"bug1_unit_name_uses_registry",
		"_unit_name() 不走 DataRegistry.unit_display_name(..., _english()) —— 双语取名的唯一入口没了")
	LocaleManager.set_locale(prev_locale)


# 一行代码里是否出现「字符串字面量中的中文」。
func _has_cn_in_strings(code: String) -> bool:
	var in_str := false
	var i := 0
	while i < code.length():
		var ch := code[i]
		if ch == "\"":
			in_str = not in_str
		elif in_str and _is_cn(ch):
			return true
		i += 1
	return false


func _is_cn(ch: String) -> bool:
	var c := ch.unicode_at(0)
	return c >= 0x4E00 and c <= 0x9FFF


# ── 第 2 条：图鉴分类按钮统一 + 种族长按 ──────────────────────────────────────
func _case_bug2_codex_tabs_and_race_long_press() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/menu/CodexScreen.gd")
	_h.expect(not src.is_empty(), "bug2_source_readable", "读不到 CodexScreen.gd，判据无法执行")
	if src.is_empty():
		return
	# 分类按钮：必须有一个统一的最小尺寸常量被 _build_tabs 用上。
	# 只断言「存在 custom_minimum_size」会被别处的按钮蒙混，所以钉住常量名 + 落点。
	_h.expect(src.contains("TAB_BUTTON_SIZE"), "bug2_tab_size_constant",
		"分类按钮应当有一个统一的尺寸常量（TAB_BUTTON_SIZE），否则宽度会随文字走")
	var tab_fn := _fn_body(src, "func _build_tabs()")
	_h.expect(not tab_fn.is_empty(), "bug2_build_tabs_found", "找不到 _build_tabs() 函数体")
	_h.expect(tab_fn.contains("custom_minimum_size") and tab_fn.contains("TAB_BUTTON_SIZE"),
		"bug2_tabs_apply_size",
		"_build_tabs() 里没有把 TAB_BUTTON_SIZE 应用到按钮上，大小仍会不一")
	# 种族徽章：必须有长按入口，且长按回调要取到羁绊文本。
	var emblem_fn := _fn_body(src, "func _emblem_badge(")
	_h.expect(not emblem_fn.is_empty(), "bug2_emblem_badge_found", "找不到 _emblem_badge() 函数体")
	_h.expect(emblem_fn.contains("gui_input") or emblem_fn.contains("attach_long_press"),
		"bug2_race_icon_long_press",
		"种族图标没有长按入口（gui_input / attach_long_press 都没有）")
	_h.expect(emblem_fn.contains("synergy") or emblem_fn.contains("race_text")
			or emblem_fn.contains("bond") or emblem_fn.contains("LongPress"),
		"bug2_race_icon_uses_synergy_text",
		"种族图标的长按回调没有接羁绊文本（备战里那份）")
	# 羁绊文本源头仍然可用：SynergyPanel 的两张静态表都在（图鉴要用它，不在图鉴里另抄一份）。
	_h.expect(SynergyPanel.race_name("human") == ("Human" if _locale_en() else "人"),
		"bug2_synergy_race_name_value",
		"SynergyPanel.race_name('human') 返回异常：%s" % SynergyPanel.race_name("human"))
	_h.expect(not SynergyPanel._race_entries("human").is_empty(), "bug2_synergy_race_entries",
		"SynergyPanel._race_entries('human') 是空的，图鉴拿不到羁绊文本")


# 去掉整行注释与行尾注释。判据要落在**代码**上：本文件自己就会在注释里引用
# `_render()` 这类被禁用的调用，不剥掉注释就会把说明当成违规（假红）。
func _strip_comments(src: String) -> String:
	var out: Array[String] = []
	for raw in src.split("\n"):
		var line := String(raw)
		var hash_at := line.find("#")
		out.append(line if hash_at < 0 else line.substr(0, hash_at))
	return "\n".join(out)


# 取一个函数的函数体（从签名到下一个同缩进的 func / 文件尾）。
func _fn_body(src: String, signature: String) -> String:
	var start := src.find(signature)
	if start < 0:
		return ""
	var rest := src.substr(start + signature.length())
	var next := rest.find("\nfunc ")
	return rest if next < 0 else rest.substr(0, next)


# ── 第 3 / 5 条：切后台不丢回合战斗金 + 不卡屏 ────────────────────────────────
#
# 两条同一个根因：本场景的 deadline 全部走**墙钟**（Time.get_ticks_msec()）。手机上切
# 后台再回来，墙钟一次性跳掉几分钟 ⇒ 每个 deadline 瞬间过期 ⇒ 回放被判
# `battle_playback_timeout`（判负、回合战斗金不结算 = 第 3 条），且恢复帧的积压
# delta 会让回放在单帧里补几十帧、每帧还要起特效（= 第 5 条「卡屏」）。
#
# 判据分三层，缺一不可：
#   ① 单调表在「后台」期间一格不走（哪怕平台仍投帧）；
#   ② 恢复帧的积压 delta 被夹住，且那条 deadline 用单调表比对时没过期；
#   ③ 单帧补帧数 + 累加器都有上限（这是「卡屏」的直接原因）。
# 再加一层结构判据：所有 deadline 的写入/比对都不得残留墙钟。
func _case_bug35_background_clock_and_frame_cap() -> void:
	var bs = BattleScript.new()
	add_child(bs)
	await get_tree().process_frame

	bs._replay_mode = true
	bs._battle_setup_ready = false
	bs._playback_deadline_msec = 0

	# 走几帧把单调表推起来。
	for i in 5:
		bs._process(0.02)
	var mono_before: int = int(bs._mono_msec)
	_h.expect(mono_before > 0, "bug35_mono_clock_advances",
		"单调表必须随 _process 前进，实测 %d" % mono_before)

	# 造一条「同一时钟域里、120 秒之后」的 deadline，并证明若用墙钟比对必过期。
	# 这就是修复前的形状：deadline 在切后台前写死，回来时墙钟已远超它。
	var mono_now: int = int(bs._mono_msec)
	bs._playback_deadline_msec = mono_now + 120000
	var wall_at_set := Time.get_ticks_msec()
	_h.expect(wall_at_set > 0, "bug35_wall_clock_available", "墙钟可读（对照组基准）")
	var wall_after_bg := wall_at_set + 120000 + 1
	_h.expect(wall_after_bg >= bs._playback_deadline_msec
			and bs._playback_deadline_msec >= mono_now,
		"bug35_wall_clock_would_expire",
		"对照组：同一条 deadline 若用墙钟比对（%d <= %d）必过期；单调表口径下它还在未来"
			% [bs._playback_deadline_msec, wall_after_bg])

	# 切后台。真机上 APPLICATION_PAUSED 期间 Godot 不调 _process；这里**额外**手动
	# 狂推，是为了让判据强于真机：即便有平台在后台仍投帧，单调表也必须一格不走。
	bs._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	var mono_at_pause: int = int(bs._mono_msec)
	for i in 60:
		bs._process(0.5)
	var mono_at_resume: int = int(bs._mono_msec)
	_h.expect(mono_at_resume == mono_at_pause, "bug35_mono_clock_frozen_while_paused",
		"后台期间单调表必须不动（%d -> %d）" % [mono_at_pause, mono_at_resume])

	bs._notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	bs._process(30.0)
	var mono_after_resume: int = int(bs._mono_msec)
	_h.expect(mono_after_resume - mono_at_resume <= int(BattleScript.RESUME_DELTA_CLAMP_SEC * 1000.0) + 1,
		"bug35_resume_delta_clamped",
		"恢复帧的积压 delta 必须被夹到 %.2fs 以内，实测推进 %d ms"
			% [BattleScript.RESUME_DELTA_CLAMP_SEC, mono_after_resume - mono_at_resume])

	# 关键断言：那条 deadline 用单调表比对时**没过期**（修复前墙钟早已越过它）。
	_h.expect(bs._mono_msec < bs._playback_deadline_msec, "bug35_deadline_not_expired_on_mono",
		"单调表 %d 未越过 deadline %d ⇒ 不会 _fail_team_replay"
			% [bs._mono_msec, bs._playback_deadline_msec])
	_h.expect(not bs._return_emitted, "bug35_no_fail_during_background",
		"切后台回来此后不得发出失败结果（_return_emitted=%s）" % str(bs._return_emitted))

	# 第 5 条：单帧补帧必须封顶。把场景摆成**真的在播回放**，只给一帧巨大 delta。
	bs._battle_setup_ready = true
	bs._finished = false
	bs._final_round_intro_active = false
	bs._settlement_waiting = false
	bs._return_emitted = false
	bs._replay_mode = true
	var fake_frames: Array = []
	for i in 60:
		fake_frames.append({"tick": i})
	bs._replay = {"frames": fake_frames}
	bs._replay_own = {"frames": fake_frames}
	bs._watching_rival = false
	bs._replay_frame = 0
	bs._sim_accumulator = 0.0
	bs._mono_frozen = false
	bs._resume_frame_pending = false
	bs._process(30.0)
	var advanced: int = int(bs._replay_frame)
	var cap: int = int(BattleScript.MAX_REPLAY_FRAMES_PER_FRAME)
	_h.expect(advanced <= cap, "bug35_single_frame_replay_capped",
		"单帧推进的回放帧数必须有上限：本帧推了 %d 帧 > 上限 %d（这就是「卡屏」）"
			% [advanced, cap])
	# 累加器是被夹住的：它才是「一帧想补多少帧」的源头。
	var tick := 0.1   # == BattleUI.SIM_TICK_SEC（基类常量，避免跨脚本取常量）
	_h.expect(float(bs._sim_accumulator) < tick * float(cap + 1) + 0.001,
		"bug35_accumulator_bounded_after_big_delta",
		"巨量 delta 之后累加器必须被夹住，实测 %.3f 秒（上限 %.3f）"
			% [float(bs._sim_accumulator), tick * float(cap + 1)])

	if is_instance_valid(bs):
		bs.queue_free()
		await get_tree().process_frame


# ── 第 6 条：背包头像「点第一个跳到最后一个」 ─────────────────────────────────
#
# 根因：`_select_avatar` 走 `_render()` 整体重建网格 —— 把**正在处理这次点击**的
# 瓦片 remove_child + queue_free，再补一批新控件，而新控件这一帧还没布局，全部堆在
# 第一个格子上。Android 的 `emulate_mouse_from_touch` 会把同一次触摸**再投一路模拟
# 鼠标**事件，它命中的是这批未布局控件里最上层的那个（子节点逆序 ⇒ 最后一个）⇒
# 「点第一个，跳到最后一个」。
#
# 判据：真例化整页 + 真事件（触摸 / 鼠标 / Android 双路各一遍），逐个瓦片断言
# 「点谁选谁」；再加一条「右侧详情跟着选中走」。视口取基准 + 两个手机画布尺寸，
# 因为 `canvas_items`+`expand` 下手机的画布和桌面基准不是同一个尺寸。
const BagScene := preload("res://scenes/menu/BagScreen.tscn")
const BagAvatarCatalog := preload("res://scripts/account/AvatarCatalog.gd")
const BAG_VIEWPORTS := [Vector2i(1600, 720), Vector2i(2340, 1080), Vector2i(1280, 720)]


func _case_bug6_bag_avatar_tap() -> void:
	for size in BAG_VIEWPORTS:
		await _bug6_at(size)


func _bug6_at(viewport_size: Vector2i) -> void:
	get_viewport().size = viewport_size
	await get_tree().process_frame
	var tag := str(viewport_size)
	var bag: Control = BagScene.instantiate()
	# 固定收藏，避免真网络（与开发者截图场景同一入口）。
	bag.set_meta("ui_capture_fixture", true)
	bag.set("_loading", false)
	bag.set("_owned_pets", ["pet_mushroom", "pet_cat", "pet_rabbit"])
	bag.set("_active_pet", "pet_cat")
	bag.set("_paid_content", {})
	bag.set("_sold_content", {})
	add_child(bag)
	await get_tree().process_frame
	await get_tree().process_frame
	bag.set("_loading", false)
	bag.call("_render")
	bag.call("_select_tab", "avatars")
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	var grid: GridContainer = bag.get("_avatar_grid")
	_h.expect(grid != null and is_instance_valid(grid), "bug6_avatar_grid_" + tag,
		"背包头像分区找不到网格")
	if grid == null:
		_teardown_node_nowait(bag)
		return
	var avatars: Array = bag.call("_usable_avatars")
	var n: int = grid.get_child_count()
	_h.expect(n > 0 and n == avatars.size(), "bug6_tiles_match_catalog_" + tag,
		"头像瓦片数 %d 与可用头像数 %d 不一致" % [n, avatars.size()])
	if n == 0:
		_teardown_node_nowait(bag)
		return

	# 触摸路径：逐个瓦片「点谁选谁」。
	var bad_touch: Array[String] = []
	for i in n:
		bag.set("_selected_avatar", "")
		await get_tree().process_frame
		var live: Array = grid.get_children()
		if i >= live.size():
			break
		var tile = live[i]
		if not (tile is Control) or not is_instance_valid(tile):
			continue
		_tap_touch(_canvas_to_window((tile as Control).get_global_rect().get_center()))
		await get_tree().process_frame
		await get_tree().process_frame
		var got := str(bag.get("_selected_avatar"))
		if got != str(avatars[i]):
			bad_touch.append("#%d->%s(want %s)" % [i, got, str(avatars[i])])
	_h.expect(bad_touch.is_empty(), "bug6_touch_taps_correct_tile_" + tag,
		"触摸点每个头像瓦片都应选中它自己，%s 下有 %d 个不一致：%s"
			% [tag, bad_touch.size(), str(bad_touch.slice(0, 5))])

	# Android 双路（触摸 + 模拟鼠标）：这一路才是报告的现场，判据必须单独有。
	var bad_dual: Array[String] = []
	for i in n:
		bag.set("_selected_avatar", "")
		await get_tree().process_frame
		var live2: Array = grid.get_children()
		if i >= live2.size():
			break
		var tile2 = live2[i]
		if not (tile2 is Control) or not is_instance_valid(tile2):
			continue
		_tap_dual(_canvas_to_window((tile2 as Control).get_global_rect().get_center()))
		await get_tree().process_frame
		await get_tree().process_frame
		var got2 := str(bag.get("_selected_avatar"))
		if got2 != str(avatars[i]):
			bad_dual.append("#%d->%s(want %s)" % [i, got2, str(avatars[i])])
	_h.expect(bad_dual.is_empty(), "bug6_dual_delivery_taps_correct_tile_" + tag,
		"Android 双路投递下每个头像瓦片都应选中它自己（这就是「点第一个跳到最后一个」）——"
		+ "%s 下有 %d 个不一致：%s" % [tag, bad_dual.size(), str(bad_dual.slice(0, 5))])

	# 右侧详情必须跟着选中走。
	var probe_index := 3
	if n > probe_index:
		bag.set("_selected_avatar", "")
		await get_tree().process_frame
		var live3: Array = grid.get_children()
		if probe_index < live3.size():
			_tap_touch(_canvas_to_window((live3[probe_index] as Control).get_global_rect().get_center()))
			await get_tree().process_frame
			await get_tree().process_frame
			var want_name: String = BagAvatarCatalog.display_name(
				BagAvatarCatalog.id_from_value(str(avatars[probe_index])))
			var detail_text := _collect_text(bag.get("_avatar_detail"))
			_h.expect(detail_text.find(want_name) >= 0, "bug6_detail_follows_selection_" + tag,
				"选中 #%d（%s）后右侧详情应出现它的名字，实际=%s"
					% [probe_index, want_name, detail_text.substr(0, 80)])

	_teardown_node_nowait(bag)


# 画布坐标 -> 窗口坐标。push_input 收的是窗口坐标，而 stretch=canvas_items 会按
# 拉伸系数换算后再命中测试；不换算在高分屏尺寸下会整体偏移（实测点第一个中第九个）。
func _canvas_to_window(pos: Vector2) -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return pos
	var canvas := vp.get_visible_rect().size
	var win := Vector2(vp.size)
	if canvas.x <= 0.0 or canvas.y <= 0.0:
		return pos
	return Vector2(pos.x * win.x / canvas.x, pos.y * win.y / canvas.y)


func _tap_touch(win_pos: Vector2) -> void:
	var p := InputEventScreenTouch.new()
	p.index = 0
	p.pressed = true
	p.position = win_pos
	get_viewport().push_input(p)
	var r := InputEventScreenTouch.new()
	r.index = 0
	r.pressed = false
	r.position = win_pos
	get_viewport().push_input(r)


# Android `emulate_mouse_from_touch` 默认开着：同一次触摸会再来一路模拟鼠标。
func _tap_dual(win_pos: Vector2) -> void:
	var t := InputEventScreenTouch.new()
	t.index = 0
	t.pressed = true
	t.position = win_pos
	get_viewport().push_input(t)
	var m := InputEventMouseButton.new()
	m.button_index = MOUSE_BUTTON_LEFT
	m.pressed = true
	m.position = win_pos
	m.global_position = win_pos
	get_viewport().push_input(m)
	var tr := InputEventScreenTouch.new()
	tr.index = 0
	tr.pressed = false
	tr.position = win_pos
	get_viewport().push_input(tr)
	var mr := InputEventMouseButton.new()
	mr.button_index = MOUSE_BUTTON_LEFT
	mr.pressed = false
	mr.position = win_pos
	mr.global_position = win_pos
	get_viewport().push_input(mr)


func _collect_text(node: Variant) -> String:
	if node == null or not (node is Node):
		return ""
	var out := ""
	if node is Label:
		out += (node as Label).text + "\n"
	elif node is Button:
		out += (node as Button).text + "\n"
	for child in (node as Node).get_children():
		out += _collect_text(child)
	return out


func _teardown_node_nowait(node: Node) -> void:
	if node != null and is_instance_valid(node):
		remove_child(node)
		node.queue_free()


# ── 结构守卫（读源码确认关键接线没被摘掉）─────────────────────────────────────
func _case_structure_guards() -> void:
	# 第 3/5 条：deadline 口径不得残留墙钟。
	_case_bug35_no_wall_clock_deadline_left()
	# 第 6 条：选中不得走整体重建（否则会踩掉正在处理点击的控件）。
	# ★ 只在**代码行**上判 —— 注释里提到 `_render()` 是刻意的说明，不能当命中。
	var bag_src := FileAccess.get_file_as_string("res://scenes/menu/BagScreen.gd")
	var sel_fn := _fn_body(bag_src, "func _select_avatar(")
	_h.expect(not sel_fn.is_empty(), "bug6_select_avatar_found", "找不到 _select_avatar()")
	var sel_code := _strip_comments(sel_fn)
	_h.expect(sel_code.find("_render()") < 0, "bug6_select_avatar_does_not_rebuild",
		"_select_avatar() 里又出现 _render() —— 整体重建会把正在处理本次点击的瓦片"
		+ "queue_free 掉，Android 双路投递下会点中未布局的最后一个瓦片")
	_h.expect(sel_code.find("_refresh_avatar_selection()") >= 0, "bug6_select_avatar_uses_light_refresh",
		"_select_avatar() 必须走只重上色的 _refresh_avatar_selection()")
	# 第 9 条：出售区必须是「视觉区维持原尺寸 + 命中区解耦放宽」，
	# 而不是「把红区撑大去盖住商店」—— 后者就是 10.08c 真机事故的写法。
	var prepui := _strip_comments(
		FileAccess.get_file_as_string("res://scenes/prep/PrepUI.gd"))
	_h.expect(prepui.find("_sync_sell_zone_geometry") < 0, "bug9_sync_fn_removed",
		"PrepUI 里又出现了 _sync_sell_zone_geometry() —— 那个「显示时按布局重算红区左缘」"
		+ "的写法在手机画布上会把红区撑成巨框，压掉刷新按钮并挡住待命区")
	var ctrl := FileAccess.get_file_as_string("res://scenes/prep/PrepBoardController.gd")
	_h.expect(ctrl.contains("func _point_in_sell_coverage("), "bug9_coverage_fn_exists",
		"PrepBoardController 缺少 _point_in_sell_coverage() —— 商店 UI / 金图标处没有命中判定")
	var drag_body := _strip_comments(_fn_body(ctrl, "func _on_drag_ended()"))
	_h.expect(not drag_body.is_empty(), "bug9_drag_ended_found", "找不到 _on_drag_ended()")
	_h.expect(drag_body.find("_point_in_sell_coverage(") >= 0, "bug9_coverage_used_on_drop",
		"_on_drag_ended 没有先判 _point_in_sell_coverage()，松手在商店/金图标上会被"
		+ "吸附回待命区（表现＝卖不掉）")
	var sell_body := _strip_comments(_fn_body(ctrl, "func _set_shop_sell_mode("))
	_h.expect(not sell_body.is_empty(), "bug9_sell_mode_found", "找不到 _set_shop_sell_mode()")
	_h.expect(sell_body.find("_sync_sell_zone_geometry(") < 0, "bug9_sell_mode_keeps_geometry",
		"_set_shop_sell_mode 又在运行时改红区几何 —— 红区尺寸必须与布局解耦")
	# 第 8 条：后端两条接线缺一不可 —— ws 断连要记账，matchmaking.tick 要收尾。
	# ★ 只钉一半会出事：10.08b 收口时后端 A/B 脚本的还原漏了两份文件，
	# 因为当时只有 ws 这一条判据，matchmaking 那一半被静默换回仓旧版没人发现。
	var ws := FileAccess.get_file_as_string("res://backend/app/routes/ws.py")
	_h.expect(ws.contains("party.current()"), "bug8_ws_notifies_party",
		"ws.py 断连路径里没有 party 的处理，掉线玩家的房间成员项会永久残留")
	var mm := FileAccess.get_file_as_string("res://backend/app/matchmaking.py")
	_h.expect(mm.contains("_prune_party_ghosts"), "bug8_matchmaking_prunes_ghosts",
		"matchmaking.py 里没有 _prune_party_ghosts() —— 宽限到期没人收尾，"
		+ "掉线成员会一直挂在房间里（ws 只记账、不摘人）")
	_h.expect(mm.contains("from app import party"), "bug8_matchmaking_imports_party",
		"matchmaking.py 没有 import party，_prune_party_ghosts 会 NameError")
	# ★ 10.08c 回归守卫：对局中重启后必须还能走重连。
	#
	# 事故：本轮为「切后台丢回合战斗金」在 Main.gd 的 result.has("error") 分支里加了
	# 一层「服务器已权威结算就提前 return」的兜底，**直接跳过了
	# NetworkService.enter_recoverable_failure()** —— 那是触发重连的入口。结果对局中
	# 重启后不再进重连，建房被服务端以 ACTIVE_MATCH_HINT（「正在对局中，请进行游戏
	# 重连」）拒掉。那几层兜底已整体撤销，只保留 BattleScreen 的单调时钟修复。
	#
	# 判据：从 `if result.has("error"):` 到 `enter_recoverable_failure` 之间
	# **不得出现任何 return**（注释已剥离），保证错误分支一定能走到重连入口。
	var main_src := FileAccess.get_file_as_string("res://scenes/main/Main.gd")
	var fin := _strip_comments(_fn_body(main_src,
		"func _finish_server_authoritative_team_battle("))
	var at_err := fin.find("if result.has(\"error\"):")
	_h.expect(at_err >= 0, "reconnect_error_branch_found",
		"Main.gd 里找不到 _finish_server_authoritative_team_battle 的 error 分支")
	if at_err >= 0:
		var at_rec := fin.find("enter_recoverable_failure", at_err)
		_h.expect(at_rec > at_err, "reconnect_uses_recoverable_failure",
			"error 分支里不再调用 enter_recoverable_failure —— 重连没有入口了")
		if at_rec > at_err:
			var between := fin.substr(at_err, at_rec - at_err)
			_h.expect(between.find("return") < 0, "reconnect_branch_has_no_early_return",
				"error 分支在 enter_recoverable_failure 之前出现了 return —— "
				+ "某些技术失败会被判定为『已结算』而跳过重连，玩家建房时会被服务端以"
				+ "「正在对局中，请进行游戏重连」拒掉")
	# 第 7 条：好友页重建列表前必须避开「正在编辑的输入框」。
	var friends := FileAccess.get_file_as_string("res://scenes/menu/FriendsScreen.gd")
	_h.expect(friends.contains("has_focus"), "bug7_render_preserves_focus",
		"FriendsScreen._render 没有 has_focus 保护，5 秒轮询会把输入框连同键盘一起清掉")


# 第 3/5 条：所有 deadline 的写入/比对都改成了单调表，不得残留墙钟。
#   * 结构 1：写入点必须是 `_xxx_deadline_msec = _mono_msec + ...`
#   * 结构 2：比对点必须用 `_mono_msec`
#   * 结构 3：任何出现 deadline 变量的**代码行**都不许掺 `Time.get_ticks_msec()`
#            （注释行豁免 —— 说明文字里提墙钟是刻意的）。
func _case_bug35_no_wall_clock_deadline_left() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/battle/BattleScreen.gd")
	_h.expect(not src.is_empty(), "bug35_source_readable", "读不到 BattleScreen.gd")
	if src.is_empty():
		return
	_h.expect(src.find("_playback_deadline_msec = _mono_msec +") >= 0,
		"bug35_playback_deadline_uses_mono", "回放 deadline 必须写 _mono_msec")
	_h.expect(src.find("_battle_prepare_deadline_msec = _mono_msec +") >= 0,
		"bug35_prepare_deadline_uses_mono", "准备 deadline 必须写 _mono_msec")
	_h.expect(src.find("_battle_prepare_deadline_msec > 0 and _mono_msec >") >= 0,
		"bug35_prepare_deadline_compares_mono", "准备 deadline 必须用 _mono_msec 比对")
	_h.expect(src.find("NOTIFICATION_APPLICATION_PAUSED") >= 0
			and src.find("NOTIFICATION_APPLICATION_RESUMED") >= 0,
		"bug35_handles_app_lifecycle", "必须处理暂停/恢复通知")
	var leftover := 0
	for line in src.split("\n"):
		if line.begins_with("#") or line.strip_edges().begins_with("#"):
			continue
		if line.find("_playback_deadline_msec") >= 0 or line.find("_battle_prepare_deadline_msec") >= 0:
			if line.find("Time.get_ticks_msec()") >= 0:
				leftover += 1
		if line.find(">= deadline") >= 0 and line.find("Time.get_ticks_msec()") >= 0:
			leftover += 1
	_h.expect(leftover == 0, "bug35_no_wall_clock_deadline_left",
		"deadline 口径不得残留墙钟，实测残留 %d 行" % leftover)

	# ★ 10.08c 返工（第三个新 bug：进战场读条后整场战斗被跳过）:
	#   本场景的 deadline 全在前台单调表上，但 BattleRenderWarmup.prepare_replays()
	#   内部是拿**墙钟** `Time.get_ticks_msec()` 比对的。把单调值原样递过去 ⇒
	#   那个数远小于当前墙钟 ⇒ 一进门就 render_warmup_timeout ⇒ _fail_team_replay
	#   ⇒ 战斗被整体跳过（开局越晚越必现）。
	#   ⇒ 出界必须经 warmup_cutoff_msec() 换算：剩余预算按单调表算，再贴回墙钟。
	var model_fn := _strip_comments(_fn_body(src, "func _prepare_battle_models()"))
	_h.expect(not model_fn.is_empty(), "bug35_prepare_models_found", "找不到 _prepare_battle_models()")
	_h.expect(model_fn.find("prepare_replays(") >= 0, "bug35_warmup_called",
		"_prepare_battle_models 里应当调用 BattleRenderWarmup.prepare_replays()")
	_h.expect(model_fn.find("_battle_prepare_deadline_msec)") < 0, "bug35_warmup_cutoff_converted",
		"prepare_replays(...) 又把单调 deadline 原样递给了 BattleRenderWarmup —— "
		+ "它内部是按墙钟比对的，这样会一进门就判 render_warmup_timeout、整场战斗被跳过")
	_h.expect(model_fn.find("warmup_cutoff_msec(") >= 0, "bug35_warmup_uses_converter",
		"出界给 BattleRenderWarmup 的 cutoff 必须经 warmup_cutoff_msec() 换算（单调→墙钟）")
	_h.expect(BattleScript.warmup_cutoff_msec(5000, 60000) == 65000, "bug35_cutoff_adds_budget",
		"换算应当把剩余预算贴到当前墙钟上，实测 %d" % BattleScript.warmup_cutoff_msec(5000, 60000))
	_h.expect(BattleScript.warmup_cutoff_msec(0, 60000) == 60000, "bug35_cutoff_zero_budget",
		"零预算应当落在当前墙钟，实测 %d" % BattleScript.warmup_cutoff_msec(0, 60000))
	_h.expect(BattleScript.warmup_cutoff_msec(-3, 60000) == 60000, "bug35_cutoff_clamps_negative",
		"预算耗尽后不得倒推出一个过去的截止时间，实测 %d" % BattleScript.warmup_cutoff_msec(-3, 60000))


# ── helpers ──────────────────────────────────────────────────────────────────

func _build_prep(size: Vector2i = VIEW) -> Node:
	get_viewport().size = size
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if packed == null:
		return null
	var prep: Node = packed.instantiate()
	add_child(prep)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	return prep


func _teardown_node(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.queue_free()
		await get_tree().process_frame


func _restore_network() -> void:
	NetworkService.team_active = false
	NetworkService.team_slot_states = []
	NetworkService.team_ready = []


func _locale_en() -> bool:
	return TranslationServer.get_locale().begins_with("en")


# ── 第 1 条专用：把面板真建出来，读它**树上 Label 的实际文本** ──────────────────
#
# 为什么不让 Step 停在源码断言上：「Panel 里有没有中文」是**渲染结果**，源码断言只能证明
# 函数存在、证明不了它被用在渲染路径上。真建一次才能同时证伪
# 「英文下残留中文」和「人王行数不是 (N层)」。
func _clean_source(path: String) -> String:
	return FileAccess.get_file_as_string(path)


# 建一块结算面板（进树 ⇒ _ready 会真的把整棵树造出来），收集所有 Label 文本后销毁。
func _build_settlement(data: Dictionary) -> Array[String]:
	var panel := SettlementPanel.new()
	panel.data = data.duplicate(true)
	add_child(panel)
	var out: Array[String] = []
	_collect_label_texts(panel, out)
	panel.queue_free()
	return out


# 只要统计表的第一列（就是这个 dysplay 名：「人王一星（5层）」）。
func _build_settlement_stat_units(data: Dictionary) -> Array[String]:
	var panel := SettlementPanel.new()
	panel.data = data.duplicate(true)
	add_child(panel)
	var out: Array[String] = []
	_collect_stat_units(panel, out)
	panel.queue_free()
	return out


func _collect_label_texts(node: Node, sink: Array[String]) -> void:
	if node is Label:
		sink.append((node as Label).text)
	for child in node.get_children():
		_collect_label_texts(child, sink)


func _collect_stat_units(node: Node, sink: Array[String]) -> void:
	if node is Label and not node.has_meta("settlement_header") \
			and node.has_meta("stats_column") and int(node.get_meta("stats_column", -1)) == 0:
		sink.append((node as Label).text)
	for child in node.get_children():
		_collect_stat_units(child, sink)


func _text_has_cn(text: String) -> bool:
	for i in text.length():
		if _is_cn(text[i]):
			return true
	return false


# 「层数」标记：中文「（N层）」/ 英文 " (N stacks)"，两种写法都要认。
func _has_layer_mark(text: String) -> bool:
	return text.contains("层") or text.contains("stack")

# ── 第 1 条（对局历史支线）：历史统计表的语言 / 人王层数 ──────────────────────────
#
# 真机返工截图：语言选英文，从「对局历史 → 详细战况」打开的统计表里棋子名仍是中文、
# 人王只有「人王★1」没有层数。根因不在面板 —— 在**历史数据链**：
#
#   BattleReport._clean_stats（写报，短键）→ 后端 battle_report._settlement_stat（白名单校验）
#   → MatchHistoryPanel.settlement_view_data（读报适配）→ FinalSettlementPanel
#
# 这条链以前**只存中文名和战斗内技能计数**（stack）：英文名（n_en）与人王持久层数（kst）
# 压根不落盘 ⇒ 面板再对也读不到。修法＝四处一起动（写报 / 后端 / 读报 / 面板按 id 兜底）。
# 判据四层，缺一不可：
#   ① 行为：写报端 _clean_stats 直调 —— 全键进、短键出；
#   ② 行为：读报端 settlement_view_data 直调 —— 旧格式（无 n_en/kst）与新格式各跑一遍；
#   ③ 行为：旧格式喂给结算面板，英文下名字**仍要**翻出来（按 id 回数据表）——
#          这是「老对局」唯一能救的一侧；层数旧记录没存，**不许凭空编数**（行里不许出现层数）；
#   ④ 结构：三处落点锚 + 后端白名单锚（服务端把它裁掉就全白搭）。
func _case_bug1_history_path_localized() -> void:
	var History := preload("res://scenes/menu/MatchHistoryPanel.gd")
	var Report := preload("res://scripts/multiplayer/BattleReport.gd")
	var Growth := preload("res://scripts/units/UnitGrowth.gd")
	var prev_locale := LocaleManager.get_locale()
	# ① 写报端：结算统计的全键 → 战报短键
	var cleaned: Array = Report._clean_stats([{
		"owner_slot": KING_SLOT, "slot": 3, "id": KING_UNIT_ID,
		"name": KING_ZH_NAME, "name_en": KING_EN_NAME, "star": 1,
		"is_mercenary": false, "skill_stacks": 2,
		Growth.KING_STACKS: KING_STACKS_VALUE,
		"damage_dealt": 209, "damage_taken": 1079, "healing_done": 42,
	}])
	_h.expect(cleaned.size() == 1, "bug1h_writer_row_kept",
		"_clean_stats 把唯一的统计行弄丢了（%d 行）—— 历史链写端判据没有输入" % cleaned.size())
	if cleaned.size() == 1:
		var row: Dictionary = cleaned[0]
		_h.expect(str(row.get("n_en", "")) == KING_EN_NAME, "bug1h_writer_name_en",
			"战报没把英文名写进 n_en（实测 %s）—— 历史统计表英文翻不出来" % str(row.get("n_en", "缺")))
		_h.expect(int(row.get("kst", -1)) == KING_STACKS_VALUE, "bug1h_writer_king_stacks",
			"战报没把人王持久层数写进 kst（实测 %s）—— 历史里的人王显示不出层数"
				% str(row.get("kst", "缺")))
		_h.expect(int(row.get("stack", -1)) == 2, "bug1h_writer_skill_stacks_kept",
			"战斗内技能计数 stack 被写坏了（实测 %s）" % str(row.get("stack", "缺")))
	# ② 读报端：旧格式 / 新格式各一遍
	var old_stats := [
		{"own": 0, "slot": 3, "id": KING_UNIT_ID, "name": KING_ZH_NAME, "star": 1,
			"merc": false, "stack": 0, "dmg": 209, "taken": 1079, "heal": 42},
		{"own": 3, "slot": 4, "id": NON_KING_UNIT_ID, "name": QUEEN_ZH_NAME, "star": 2,
			"merc": false, "stack": STACKS_FROM_SKILL, "dmg": 900, "taken": 500, "heal": 0},
	]
	var old_data: Dictionary = History.settlement_view_data(_history_item(old_stats))
	var old_rows: Array = old_data.get("stats", [])
	_h.expect(old_rows.size() == 2, "bug1h_reader_rows",
		"settlement_view_data 应还原 2 行统计，实测 %d" % old_rows.size())
	if old_rows.size() == 2:
		var old_king: Dictionary = old_rows[0]
		# 旧记录本来就没有这两项 ⇒ 读出来就该是空 / 0（这正是老对局翻不出来的原因，
		# 判据钉住「读端没有偷偷拿别的键顶替」）。
		_h.expect(str(old_king.get("name_en", "x")) == "", "bug1h_reader_old_has_no_name_en",
			"旧格式记录不该凭空读出 name_en（实测 %s）" % str(old_king.get("name_en", "缺")))
		_h.expect(int(old_king.get(Growth.KING_STACKS, -1)) == 0, "bug1h_reader_old_has_no_king_stacks",
			"旧格式记录不该凭空读出人王层数（实测 %s）" % str(old_king.get(Growth.KING_STACKS, "缺")))
		var new_stats := [
			{"own": 0, "slot": 3, "id": KING_UNIT_ID, "name": KING_ZH_NAME,
				"n_en": KING_EN_NAME, "kst": KING_STACKS_VALUE, "star": 1,
				"merc": false, "stack": 0, "dmg": 209, "taken": 1079, "heal": 42},
		] + old_stats.slice(1, 2)
		var new_data: Dictionary = History.settlement_view_data(_history_item(new_stats))
		var new_rows: Array = new_data.get("stats", [])
		_h.expect(new_rows.size() == 2, "bug1h_reader_new_rows", "新格式应还原 2 行，实测 %d" % new_rows.size())
		if new_rows.size() == 2:
			_h.expect(str(new_rows[0].get("name_en", "")) == KING_EN_NAME, "bug1h_reader_new_name_en",
				"读端没把 n_en 接回 name_en（实测 %s）" % str(new_rows[0].get("name_en", "缺")))
			_h.expect(int(new_rows[0].get(Growth.KING_STACKS, -1)) == KING_STACKS_VALUE,
				"bug1h_reader_new_king_stacks",
				"读端没把 kst 接回 %s（实测 %s）" % [Growth.KING_STACKS, str(new_rows[0].get(Growth.KING_STACKS, "缺"))])
			# ③ 新格式喂给面板：这才是用户在历史里要看到的那一行
			LocaleManager.set_locale("en")
			var new_units := _build_settlement_stat_units(new_data)
			var want_en := KING_EN_NAME + tr("settle_star_1") + (tr("settle_stacks") % KING_STACKS_VALUE)
			_h.expect(new_units.size() == 2 and String(new_units[0]) == want_en, "bug1h_history_en_king_row",
				"历史（新格式）英文人王行应为「%s」，实测 %s" % [want_en, str(new_units)])
			_h.expect(new_units.size() == 2 and not _has_layer_mark(String(new_units[1])),
				"bug1h_history_en_queen_no_stacks",
				"历史里非人王行仍带层数标记：%s" % str(new_units))
			LocaleManager.set_locale("zh")
			var zh_units := _build_settlement_stat_units(new_data)
			var want_zh := KING_ZH_NAME + tr("settle_star_1") + (tr("settle_stacks") % KING_STACKS_VALUE)
			_h.expect(zh_units.size() == 2 and String(zh_units[0]) == want_zh, "bug1h_history_zh_king_row",
				"历史（新格式）中文人王行应为「%s」，实测 %s" % [want_zh, str(zh_units)])
	# ③' 旧格式喂给面板：名字必须仍能翻出来（按 id 回数据表），层数不许编
	LocaleManager.set_locale("en")
	var old_units := _build_settlement_stat_units(old_data)
	var want_old := KING_EN_NAME + tr("settle_star_1")
	_h.expect(old_units.size() == 2 and String(old_units[0]) == want_old, "bug1h_history_old_en_king_row",
		"历史（旧格式）英文人王行应为「%s」—— 旧记录没有 name_en，必须按 id 回数据表，实测 %s"
			% [want_old, str(old_units)])
	_h.expect(old_units.size() == 2 and not _has_layer_mark(String(old_units[1])),
		"bug1h_history_old_en_queen_no_stacks",
		"旧记录的非人王行仍带层数标记（skill_stacks=%d 不该被当层数显示）：%s"
			% [STACKS_FROM_SKILL, str(old_units)])
	LocaleManager.set_locale(prev_locale)
	# ④ 结构锚：写报 / 读报 / 后端白名单三处，缺一处这条链就断
	var w_body := _strip_comments(_fn_body(
		_clean_source("res://scripts/multiplayer/BattleReport.gd"), "static func _clean_stats("))
	_h.expect(w_body.contains("\"n_en\"") and w_body.contains("\"kst\""), "bug1h_writer_anchor",
		"BattleReport._clean_stats() 不再写 n_en / kst —— 历史链写端断了")
	var r_body := _strip_comments(_fn_body(
		_clean_source("res://scenes/menu/MatchHistoryPanel.gd"), "static func settlement_view_data("))
	_h.expect(r_body.contains("\"n_en\"") and r_body.contains("king_growth_stacks"), "bug1h_reader_anchor",
		"settlement_view_data() 不再把 n_en / kst 接回面板字段 —— 历史链读端断了")
	var b_body := _strip_comments(_fn_body(
		_clean_source("res://backend/app/battle_report.py"), "def _settlement_stat("))
	_h.expect(b_body.contains("\"n_en\"") and b_body.contains("\"kst\""), "bug1h_backend_anchor",
		"后端 _settlement_stat() 的白名单没有放行 n_en / kst —— 服务端会把它们裁掉，历史照样翻不出来")


# 历史接口的一条记录（settlement_view_data 吃的形状，只需要它用到的键）。
func _history_item(stats: Array) -> Dictionary:
	return {
		"outcome": "win", "my_slot": 0, "gold_authoritative": true,
		"seats": [],
		"settlement": {"kind": "pvp", "allies": ["", ""], "seats": [], "stats": stats},
	}
