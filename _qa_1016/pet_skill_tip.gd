extends Node
# ============================================================================
# 2026-10-15 第 3 点门禁：备战-宠物页「点宠物模型显示技能框」。
#
# 【反馈原文】
#   「备战-宠物界面，增加一个功能：点击宠物的模型可以显示出对应的宠物技能文本框，
#     点击除宠物模型外的地方文本框消失，文本内容可以参考背包-宠物档案里的文本说明。」
#
# 【要钉住什么】
#   1. 浮框建起来了，且**初始不可见**。
#   2. 每只宠物的立绘都可点（mouse_filter=STOP）—— 否则 pet_id 传不进来。
#   3. 点立绘 → 浮框出现，且钉的是**这一只**：名字 / 摘要与 PetService 一致。
#   4. 「详情与摘要重复就不重复写」（与 BagScreen 伙伴档案同一条规则）。
#   5. 浮框整棵子树都是 MOUSE_FILTER_IGNORE —— 它只是提示，不得吃掉底下的点击。
#      行为锚点：把浮框挪到右上角「返回」上面，光标拾取仍必须是返回按钮。
#   6. 点别处 → 浮框消失。
#   7. 点另一只的立绘 → 换成那一只，而不是叠两个 / 关掉。
#   8. 切页签、卡片整批重建 → 浮框消失（它钉着的立绘已经不在树里了）。
#   9. 浮框高度按文案量出来：内容装得下（不裁字），长文案的框比短文案高。
#  10. 三种画布宽度下都贴得住屏内、可点可收。
#
# 【跑法】
#   Godot_v4.7.2-stable_win64_console.exe --headless --path <工程根> \
#       _qa_1016/pet_skill_tip.tscn
#   退出码 0 = PASS，1 = FAIL。
#
# ⚠ 门禁里的 620 / 16 / 420 是**自己写死的设计值**，刻意不去读 PetScreen 的常量 ——
#   读实现常量会让「实现改错了」和「门禁跟着改」互相抵消（同义反复）。

const CheckHarness := preload("res://_qa_1016/CheckHarness.gd")
const CHECK_NAME := "pet_skill_tip"

const VIEW := Vector2i(1600, 720)
const PET_SCENE := "res://scenes/menu/PetScreen.tscn"
const TIP_WIDTH := 620.0     # 设计值，与 PetScreen.PET_TIP_WIDTH 同义
const TIP_PAD := 16.0        # 设计值，与 PetScreen.PET_TIP_PAD 同义
const TIP_MAX_HEIGHT := 420.0

var _h: CheckHarness
var _page: Control


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	get_window().size = VIEW
	await _settle(4)

	var packed := load(PET_SCENE) as PackedScene
	if not _h.expect(packed != null, "pet_scene_load_failed", "%s 加载不出来" % PET_SCENE):
		_h.finish(get_tree())
		return
	_page = packed.instantiate() as Control
	if not _h.expect(_page != null, "pet_instantiate_failed", "PetScreen 实例化失败"):
		_h.finish(get_tree())
		return
	add_child(_page)
	await _settle(8)

	_case_built()
	await _case_tap_art_shows()
	await _case_tap_outside_hides()
	await _case_switch_art()
	await _case_tip_does_not_eat_clicks()
	await _case_tab_and_rebuild_hide()
	await _case_height_measures_text()
	await _case_all_resolutions()

	_h.finish(get_tree())


# ── ① 建起来了、初始不可见、立绘可点、浮框不吃输入 ─────────────────────────────

func _case_built() -> void:
	var tip := _tip()
	if not _h.expect(tip != null, "tip_missing",
			"PetScreen 上没有 _pet_tip —— 技能浮框根本没建起来"):
		return
	_h.expect(not tip.visible, "tip_visible_on_start",
		"刚进备战页浮框就是显示的（应该等玩家点模型）")
	_h.expect(absf(tip.size.x - TIP_WIDTH) < 0.5, "tip_width_wrong",
		"浮框宽度 %.0f，设计宽度 %.0f" % [tip.size.x, TIP_WIDTH])

	var col := _tip_rows()
	if not _h.expect(col.size() >= 4, "tip_rows_missing",
			"浮框只建出 %d 行（至少要有 4：眉标 / 名字 / 分隔线 / 摘要）" % col.size()):
		return
	# 每一行都要真的排在浮框**里面**（浮框自己算高度、自己摆位置，没有容器兜底）。
	_h.expect(_rows_inside(tip).is_empty(), "tip_rows_outside_panel",
		"这些行排到了浮框外面（会被裁掉）：%s" % str(_rows_inside(tip)))

	# ★ 整棵子树不得吃输入。Container / PanelContainer 的 mouse_filter 默认是 STOP，
	#   而且 mouse_filter 不继承 —— 漏一个后代就多一块「看不见的挡板」。
	var eating := _not_ignoring(tip)
	_h.expect(eating.is_empty(), "tip_eats_input",
		"浮框子树里有 %d 个控件不是 MOUSE_FILTER_IGNORE：%s" % [eating.size(), str(eating)])

	var cards := _cards()
	if not _h.expect(cards.size() > 0, "no_pet_cards",
			"宠物页一张卡都没建出来（pets 表没读到？）"):
		return
	var ids := _expected_ids()
	_h.expect(ids.size() >= cards.size(), "cards_more_than_pets",
		"建出 %d 张卡，但数据表只有 %d 只宠物" % [cards.size(), ids.size()])
	for i in cards.size():
		var art := _art_of(cards[i])
		if not _h.expect(art != null, "art_missing", "第 %d 张卡上取不到立绘" % (i + 1)):
			continue
		_h.expect(art.mouse_filter == Control.MOUSE_FILTER_STOP, "art_not_clickable",
			"第 %d 张卡的立绘 mouse_filter=%d，不是 STOP —— 点它收不到 gui_input，"
				% [i + 1, art.mouse_filter]
			+ "「点模型显示技能框」这条就永远触发不了")


# ── ② 点立绘 → 浮框出现，且钉的是这一只 ────────────────────────────────────────

func _case_tap_art_shows() -> void:
	var cards := _cards()
	if cards.is_empty():
		_h.fail("show_case_no_cards", "没有卡片，无法验证「点模型显示技能框」")
		return
	var ids := _expected_ids()
	var art := _art_of(cards[0])
	if not _h.expect(art != null and ids.size() > 0, "show_case_no_art",
			"第 1 张卡取不到立绘，或宠物表为空"):
		return

	await _tap_control(art)
	var tip := _tip()
	_h.expect(tip.visible, "tip_not_shown_on_art_tap",
		"点了第 1 只宠物（%s）的立绘 %s，浮框没出现" % [str(ids[0]), str(art.get_global_rect())])

	var pinned := str(_page.get("_pet_tip_pet"))
	_h.expect(pinned == str(ids[0]), "tip_pet_wrong",
		"点第 1 只（%s）的立绘，浮框钉的却是「%s」" % [str(ids[0]), pinned])

	var name_lbl := _page.get("_pet_tip_name") as Label
	var effect_lbl := _page.get("_pet_tip_effect") as Label
	var detail_lbl := _page.get("_pet_tip_detail") as Label
	if not _h.expect(name_lbl != null and effect_lbl != null and detail_lbl != null,
			"tip_labels_missing", "浮框里的名字 / 摘要 / 详情标签取不到"):
		return

	var want_name := PetService.display_name(str(ids[0]))
	var want_effect := PetService.effect_text(str(ids[0]))
	var want_detail := PetService.skill_detail_text(str(ids[0]))
	_h.expect(name_lbl.text == want_name, "tip_name_wrong",
		"浮框里的名字「%s」与 PetService.display_name 的「%s」不一致" % [name_lbl.text, want_name])
	_h.expect(effect_lbl.text == want_effect, "tip_effect_wrong",
		"浮框里的摘要「%s」与 PetService.effect_text 的「%s」不一致" % [effect_lbl.text, want_effect])
	# 和 BagScreen 的「伙伴档案」同规则：详情为空、或与摘要重复，就不重复写一遍。
	var want_detail_visible := not want_detail.is_empty() and want_detail != want_effect
	_h.expect(detail_lbl.visible == want_detail_visible, "tip_detail_visibility_wrong",
		"「详情与摘要重复就不重复写」没对上：详情非空=%s 详情==摘要=%s 而 visible=%s"
			% [str(not want_detail.is_empty()), str(want_detail == want_effect),
				str(detail_lbl.visible)])
	if want_detail_visible:
		_h.expect(detail_lbl.text == want_detail, "tip_detail_text_wrong",
			"浮框里的详情「%s」与 PetService.skill_detail_text 的「%s」不一致"
				% [detail_lbl.text, want_detail])
	# 文案与背包的「伙伴档案」同源：这里把它记进日志，人工核对时一眼能比。
	_h.note("第 1 只 %s：名字「%s」/ 摘要「%s」/ 详情「%s」"
		% [str(ids[0]), want_name, want_effect, want_detail])

	# ★ 第一次弹出最容易出事的一处（10.15 实测 814px 高的大黑框）：宽度必须还是设计
	#   宽度 —— 浮框曾是「量高度时标签还没排版」的受害者，量出的天文高度会被引擎的
	#   「尺寸不得小于最小尺寸」写进 size，把框撑成一整屏。
	_dump_tip("first_show")
	_h.expect(absf(tip.size.x - TIP_WIDTH) < 0.5, "shown_width_drifted",
		"第一次弹出后浮框宽 %.0f（设计 %.0f）—— 高度/宽度量串了" % [tip.size.x, TIP_WIDTH])
	_h.expect(tip.size.y <= TIP_MAX_HEIGHT + 1.0, "shown_height_blown_up",
		"第一次弹出时浮框高 %.0f，超过上限 %.0f —— 量高度时标签还没被排到固定宽度，"
			% [tip.size.y, TIP_MAX_HEIGHT]
		+ "量出来的是「每行一个字」的天文数字")

	_on_screen("shown")


# ── ③ 点别处 → 消失 ────────────────────────────────────────────────────────────

func _case_tap_outside_hides() -> void:
	await _ensure_shown()
	var tip := _tip()
	var point := _outside_point()
	if point == Vector2.INF:
		_h.fail("outside_point_missing", "找不到一个既不在浮框上、也不在任何立绘上的空点")
		return
	_h.expect(not tip.get_global_rect().has_point(point), "outside_point_inside_tip",
		"选出来的空点 %s 居然落在浮框 %s 里" % [str(point), str(tip.get_global_rect())])
	_tap(_canvas_to_window(point))
	await _settle(4)
	_h.expect(not tip.visible, "tip_not_hidden_on_outside_tap",
		"点了别处 %s（不在任何立绘上），浮框没消失" % str(point))


# ── ④ 点另一只的立绘 → 换成那只 ────────────────────────────────────────────────

func _case_switch_art() -> void:
	await _ensure_shown()
	var cards := _cards()
	if not _h.expect(cards.size() >= 2, "switch_case_too_few_cards",
			"只建出 %d 张卡，无法验证「换一只」" % cards.size()):
		return
	var ids := _expected_ids()
	var tip := _tip()
	var tip_rect := tip.get_global_rect()
	# 优先挑一只**被浮框盖住**的立绘：那样这一条同时也在验「浮框不吃点击」。
	var target := 1
	var covered := false
	for j in range(1, cards.size()):
		var a := _art_of(cards[j])
		if a != null and tip_rect.has_point(a.get_global_rect().get_center()):
			target = j
			covered = true
			break
	if not covered:
		_h.note("这一页没有别的立绘落在浮框 %s 里，本轮验的是「点没被盖住的立绘」"
			% str(tip_rect))
	var art := _art_of(cards[target])
	if not _h.expect(art != null, "switch_case_no_art", "第 %d 张卡取不到立绘" % (target + 1)):
		return
	await _tap_control(art)
	_h.expect(tip.visible, "tip_closed_on_second_art",
		"点了另一只的立绘之后浮框反而关了")
	_h.expect(str(_page.get("_pet_tip_pet")) == str(ids[target]), "tip_not_switched",
		"点第 %d 只（%s）的立绘，浮框钉的还是「%s」"
			% [target + 1, str(ids[target]), str(_page.get("_pet_tip_pet"))])


# ── ⑤ 反面：浮框不得吃掉底下的点击 ─────────────────────────────────────────────

func _case_tip_does_not_eat_clicks() -> void:
	await _ensure_shown()
	var tip := _tip()
	var back := _page.get("_back_btn") as Control
	if not _h.expect(back != null and back.is_visible_in_tree(), "back_button_missing",
			"取不到右上角「返回」按钮，做不了「浮框盖住了也不吃点击」的反面用例"):
		return
	# 真实点击时 _place_pet_tip 会自己躲开返回按钮，这里**刻意**把浮框摆到它头上，
	# 才能测到「盖住了也不吃」。拾取这一下没有键盘/按下事件，走的是纯 GUI 命中测试，
	# 所以它才是 mouse_filter 的真正判据。
	var canvas := get_viewport().get_visible_rect().size
	var back_rect := back.get_global_rect()
	tip.global_position = Vector2(
		clampf(back_rect.get_center().x - tip.size.x * 0.5, 12.0,
			maxf(12.0, canvas.x - tip.size.x - 12.0)),
		clampf(back_rect.get_center().y - tip.size.y * 0.5, 12.0,
			maxf(12.0, canvas.y - tip.size.y - 12.0)))
	await _settle(2)
	_h.expect(tip.get_global_rect().has_point(back_rect.get_center()), "back_not_covered",
		"造重叠失败：返回按钮中心 %s 不在浮框 %s 里"
			% [str(back_rect.get_center()), str(tip.get_global_rect())])

	_move(_canvas_to_window(back_rect.get_center()))
	await _settle(3)
	var hovered := get_viewport().gui_get_hovered_control()
	_h.expect(hovered == back or (hovered != null and back.is_ancestor_of(hovered)),
		"tip_steals_hover",
		"光标停在返回按钮上（浮框正盖着它），GUI 拾取到的却是 %s —— "
			% str(hovered)
		+ "浮框抢走了本属于返回按钮的命中")

	# 再真点一下：返回必须照样发出去。
	var fired := [false]
	_page.connect("back_requested", func() -> void: fired[0] = true)
	_tap(_canvas_to_window(back_rect.get_center()))
	await _settle(4)
	_h.expect(bool(fired[0]), "covered_back_click_swallowed",
		"点在浮框盖住的返回按钮上，back_requested 没有发出 —— 浮框吃掉了这次点击")


# ── ⑥ 切页签 / 卡片整批重建 → 收起 ─────────────────────────────────────────────

func _case_tab_and_rebuild_hide() -> void:
	await _ensure_shown()
	_page.call("_switch_tab", 1)   # Tab.RACES
	await _settle(3)
	_h.expect(not _tip().visible, "tip_survives_tab_switch",
		"切到「种族」页签之后浮框还开着")
	_page.call("_switch_tab", 0)   # 回到 Tab.PETS
	await _settle(3)

	await _ensure_shown()
	_page.call("_refresh_pets")
	await _settle(3)
	_h.expect(not _tip().visible, "tip_survives_card_rebuild",
		"卡片整批重建（_refresh_pets）之后浮框还开着 —— 它钉着的那个立绘已经不在树里了，"
		+ "框会悬在原地指向一只看不见的宠物")


# ── ⑦ 高度跟着文案量 ──────────────────────────────────────────────────────────

func _case_height_measures_text() -> void:
	var ids := _expected_ids()
	var cards := _cards()
	if not _h.expect(not ids.is_empty() and not cards.is_empty(), "fit_case_no_pets",
			"宠物表/卡片为空，无法验证浮框高度"):
		return
	var long_id := ""
	var short_id := ""
	var long_len := -1
	var short_len := 1 << 30
	for i in cards.size():
		if i >= ids.size():
			break
		var text: String = PetService.effect_text(str(ids[i])) + PetService.skill_detail_text(str(ids[i]))
		if text.length() > long_len:
			long_len = text.length()
			long_id = str(ids[i])
		if text.length() < short_len:
			short_len = text.length()
			short_id = str(ids[i])
	if not _h.expect(long_id != "" and short_id != "" and long_id != short_id,
			"fit_case_same_pet", "这一页上找不出文案长度不同的两只宠物"):
		return

	var h_long := await _show_and_measure(cards[ids.find(long_id)])
	var h_short := await _show_and_measure(cards[ids.find(short_id)])
	_h.note("浮框高度：最长(%s %d 字)=%.0f  最短(%s %d 字)=%.0f"
		% [long_id, long_len, h_long, short_id, short_len, h_short])
	_h.expect(h_long > h_short, "tip_height_not_tracking_text",
		"长文案（%s）的浮框高 %.0f 没有超过短文案（%s）的 %.0f —— 高度没跟着文案量"
			% [long_id, h_long, short_id, h_short])

	# 内容必须装得下：每一行的下沿都要落在浮框（去掉下内边距）以内。
	await _settle(3)
	var tip := _tip()
	_dump_tip("fit")
	var outside := _rows_inside(tip)
	_h.expect(outside.is_empty(), "tip_clips_content",
		"浮框高 %.0f，这些行的下沿却越过去了（文字会被裁）：%s" % [tip.size.y, str(outside)])
	_h.expect(tip.size.y <= TIP_MAX_HEIGHT + 1.0, "tip_too_tall",
		"浮框高 %.0f，超过上限 %.0f —— 长文案把框撑成半屏了" % [tip.size.y, TIP_MAX_HEIGHT])


# 返回「下沿超出浮框内框」的行，供断言用。
func _rows_inside(tip: Control) -> Array:
	var out: Array = []
	if tip == null:
		return out
	var limit := tip.size.y - TIP_PAD + 0.5
	for row in _tip_rows():
		if not (row is Control):
			continue
		var c := row as Control
		if not c.visible:
			continue
		if c.position.x < -0.5 or c.position.y < -0.5:
			out.append("%s@%s" % [c.name, str(c.position)])
			continue
		if c.position.x + c.size.x > tip.size.x + 0.5 or c.position.y + c.size.y > limit:
			out.append("%s bottom=%.1f > %.1f" % [c.name, c.position.y + c.size.y, limit])
	return out


# ── ⑧ 三种画布宽度都验一遍（stretch=canvas_items + expand） ────────────────────

func _case_all_resolutions() -> void:
	var restore := get_window().size
	for size in [Vector2i(1280, 720), Vector2i(1440, 720), Vector2i(1600, 720)]:
		get_window().size = size as Vector2i
		await _settle(6)
		await _ensure_shown()
		var canvas := get_viewport().get_visible_rect().size
		var tag := "%dx%d（画布 %.0fx%.0f）" % [size.x, size.y, canvas.x, canvas.y]
		var tip := _tip()
		var key := "%d_%d" % [size.x, size.y]
		_h.expect(tip.visible, "res_tip_not_shown_" + key, "%s：点了立绘浮框没出现" % tag)
		_on_screen("res_" + key)
		var point := _outside_point()
		if point == Vector2.INF:
			_h.fail("res_outside_point_" + key, "%s：找不到既不在浮框也不在立绘上的空点" % tag)
			continue
		_tap(_canvas_to_window(point))
		await _settle(4)
		_h.expect(not tip.visible, "res_tip_not_hidden_" + key,
			"%s：点了别处 %s，浮框没消失" % [tag, str(point)])
	get_window().size = restore
	await _settle(4)


# ── 辅助 ───────────────────────────────────────────────────────────────────────

func _tip() -> Control:
	return _page.get("_pet_tip") as Control


func _tip_rows() -> Array:
	var rows: Variant = _page.get("_pet_tip_rows")
	if rows is Array:
		return rows
	return []


# 只进日志：把浮框每一行摊开（当前尺寸 / 自己算出来的最小高度）。
# 第一次弹出被撑成 814px 时，一眼就能看出是哪一行还没排到固定宽度。
func _dump_tip(tag: String) -> void:
	var tip := _tip()
	if tip == null:
		return
	_h.note("%s: tip size=%s min=%s rows=%d" % [tag, str(tip.size),
		str(tip.get_combined_minimum_size()), _tip_rows().size()])
	for row in _tip_rows():
		if row is Control:
			var c := row as Control
			_h.note("%s:   %s visible=%s pos=%s size=%s min=%s" % [tag, c.name,
				str(c.visible), str(c.position), str(c.size), str(c.get_minimum_size())])


# 一张卡 = PanelContainer，内容是它唯一的子节点 VBox：
#   [0] 操作按钮  [1] 立绘  [2] 名字  [3] 效果
func _cards() -> Array:
	var out: Array = []
	var row := _page.get("_cards_row") as Node
	if row == null:
		return out
	for r in row.get_children():
		for card in (r as Node).get_children():
			out.append(card)
	return out


func _art_of(card: Node) -> Control:
	if card == null or card.get_child_count() == 0:
		return null
	var content := card.get_child(0)
	if content.get_child_count() < 2:
		return null
	return content.get_child(1) as Control


# 与 PetScreen._refresh_pets 同一份「这一页显示谁、按什么顺序」的定义。
# 刻意照抄规则而不是去读 _cards_row 的孩子来反推 —— 反推等于拿实现当标准答案。
func _expected_ids() -> Array:
	var ids: Array = []
	if PlayerProfile.needs_starter_pick:
		for id in PetService.starter_ids():
			ids.append(str(id))
	else:
		for p in PetService.all_pets():
			ids.append(str((p as Dictionary).get("id", "")))
	return ids


func _not_ignoring(root: Node) -> Array:
	var out: Array = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		for c in cur.get_children():
			stack.append(c)
		if cur is Control and (cur as Control).mouse_filter != Control.MOUSE_FILTER_IGNORE:
			out.append("%s(filter=%d)" % [cur.name, (cur as Control).mouse_filter])
	return out


func _on_screen(tag: String) -> void:
	var rect := _tip().get_global_rect()
	var canvas := get_viewport().get_visible_rect().size
	_h.expect(rect.position.x >= -0.5 and rect.position.y >= -0.5
			and rect.end.x <= canvas.x + 0.5 and rect.end.y <= canvas.y + 0.5,
		"tip_off_screen_" + tag,
		"%s：浮框 %s 越出画布 %.0fx%.0f" % [tag, str(rect), canvas.x, canvas.y])


# 一个既不在浮框上、也不在任何立绘上的画布坐标点。
# 顺序是「先点模型、后点别处」这条规则的唯一判据来源：只有立在立绘上才会重新打开浮框，
# 所以探针点必须避开所有立绘矩形。
func _outside_point() -> Vector2:
	var canvas := get_viewport().get_visible_rect().size
	var arts: Array[Rect2] = []
	for card in _cards():
		var art := _art_of(card)
		if art != null:
			arts.append(art.get_global_rect())
	var tip_rect := _tip().get_global_rect()
	for gy in range(1, 11):
		for gx in range(1, 17):
			var p := Vector2(canvas.x * float(gx) / 17.0, canvas.y * float(gy) / 11.0)
			if tip_rect.has_point(p):
				continue
			var taken := false
			for r in arts:
				if r.has_point(p):
					taken = true
					break
			if taken:
				continue
			return p
	return Vector2.INF


func _ensure_shown() -> void:
	var cards := _cards()
	if cards.is_empty():
		return
	var art := _art_of(cards[0])
	if art == null:
		return
	await _tap_control(art)


func _show_and_measure(card: Node) -> float:
	if card == null:
		return -1.0
	var art := _art_of(card)
	if art == null:
		return -1.0
	await _tap_control(art)
	await _settle(2)
	return _tip().size.y


func _tap_control(c: Control) -> void:
	_tap(_canvas_to_window(c.get_global_rect().get_center()))
	await _settle(4)


func _canvas_to_window(pos: Vector2) -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return pos
	var canvas := vp.get_visible_rect().size
	var win := Vector2(vp.size)
	if canvas.x <= 0.0 or canvas.y <= 0.0:
		return pos
	return Vector2(pos.x * win.x / canvas.x, pos.y * win.y / canvas.y)


func _move(win_pos: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = win_pos
	m.global_position = win_pos
	get_viewport().push_input(m)


func _tap(win_pos: Vector2) -> void:
	var d := InputEventMouseButton.new()
	d.button_index = MOUSE_BUTTON_LEFT
	d.pressed = true
	d.position = win_pos
	d.global_position = win_pos
	get_viewport().push_input(d)
	var u := InputEventMouseButton.new()
	u.button_index = MOUSE_BUTTON_LEFT
	u.pressed = false
	u.position = win_pos
	u.global_position = win_pos
	get_viewport().push_input(u)


func _settle(frames: int = 2) -> void:
	for i in frames:
		await get_tree().process_frame
