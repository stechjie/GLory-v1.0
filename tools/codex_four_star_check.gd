extends Node

# 10.07 bug 文档第 2 条：图鉴补「四级升星后」的四星技能说明。
#
# 判据分两层（缺一不可）：
#   1. 结构：图鉴里 40 个族棋子中「带 star4 覆写」的那些，详情里必须多出
#      「四级升星后」标签 + 一段与一~三星正文**不同**的四星正文；没 star4 的不许多画。
#   2. 内容：神侍（god_priest）的四星正文必须与需求逐字一致：
#      「星辉祈愿（冷却4.0秒）：治疗生命比例最低的友军，回复其最大生命24%；有50%概率清除负面状态。」
#
# ★ 神侍那条走 **CodexScreen 真例化**（不是直接调 helper）：
#   直接调 _four_star_skill_text 只能证明函数写得对，证明不了它真被挂进详情面板。
#   本仓踩过「外层守卫先 return，内层删掉也全绿」的坑 —— 变异实测：把
#   `_build_skill_box` 里那段四星标签删掉（改成 `if false:`），只测 helper 的
#   旧版门禁**仍然全绿**。所以下面 §1 用 **真面板结构断言**兜底：
#   `_build_skill_box(entry, true)` 出来的节点树里必须真的有「四级升星后」这个
#   标签，且它后面紧跟一段不等于一~三星正文的文字。
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/codex_four_star_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const CodexScreenScript := preload("res://scenes/menu/CodexScreen.gd")

const CHECK_NAME := "codex_four_star"

const EXPECT_PRIEST := "星辉祈愿（冷却4.0秒）：治疗生命比例最低的友军，回复其最大生命24%；有50%概率清除负面状态。"
const LABEL_ZH := "四级升星后"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	add_child(CodexScreenScript.new())
	await get_tree().process_frame
	await get_tree().process_frame

	# ★ 每个 case 必须 await —— 里面有 `await get_tree().process_frame`，
	#   不 await 的话执行到第一处 await 就挂起，后面的断言与 _h.finish() 抢跑，
	#   门禁会「绿得莫名其妙」（本文件自己踩过一次：删掉面板那段仍全绿）。
	await _case_priest_text_exact()
	await _case_panel_renders_four_star_label()
	await _case_star4_units_all_have_copy()
	await _case_no_star4_units_skip()

	_h.finish(get_tree())


# 1) 神侍四星正文逐字一致（走生产 helper，raw 与图鉴同源）。
func _case_priest_text_exact() -> void:
	var raw := _raw_for("god_priest")
	_h.expect(not raw.is_empty(), "priest_raw_present",
		"族棋子表里应当有 god_priest 这条")
	if raw.is_empty():
		return
	var text := str(UnitDetailFormat.format_skill_detail(
		UnitFactory.apply_star_stats(raw, GameConstants.MAX_STAR)))
	_h.expect(text == EXPECT_PRIEST, "priest_four_star_text",
		"神侍四星正文与需求不一致：\n  期望 %s\n  实际 %s" % [EXPECT_PRIEST, text])


# 1b) ★ 结构断言：真面板里必须挂出「四级升星后」标签 + 一段不同的四星正文。
# 这条专门堵「helper 对、但面板没画」—— 上面 §1 只测 helper，删掉面板那段它照绿。
func _case_panel_renders_four_star_label() -> void:
	var screen: Node = _screen()
	var raw := _raw_for("god_priest")
	var entry := {"raw": raw, "skill_id": str(raw.get("skill_id", ""))}
	var panel: Control = screen._build_skill_box(entry, true)
	add_child(panel)
	await get_tree().process_frame
	var labels := _all_labels(panel)
	var texts: Array[String] = []
	for l in labels:
		texts.append(l.text)
	panel.queue_free()
	_h.expect(LABEL_ZH in texts, "panel_has_four_star_label",
		"详情面板里必须出现「%s」标签，实际文本：%s" % [LABEL_ZH, texts])
	var idx := texts.find(LABEL_ZH)
	if idx < 0:
		return
	_h.expect(idx + 1 < texts.size(), "panel_label_followed_by_body",
		"「%s」标签后面必须紧跟四星正文，实际它之后没有文本" % LABEL_ZH)
	if idx + 1 >= texts.size():
		return
	var body_after := texts[idx + 1]
	_h.expect(body_after == EXPECT_PRIEST, "panel_four_star_body_text",
		"「%s」后面的正文应为神侍四星文本：\n  期望 %s\n  实际 %s" % [LABEL_ZH, EXPECT_PRIEST, body_after])
	# 反向：这段必须与一~三星正文不同（否则等于没写四星）。
	var base := str(screen._skill_text(entry))
	_h.expect(body_after != base, "panel_four_star_differs_base",
		"四星正文不能和一~三星正文相同，两者都是：%s" % base)


# 2) 结构：所有带 star4 的族棋子，四星正文都不为空、且与一~三星正文不同。
func _case_star4_units_all_have_copy() -> void:
	var total := 0
	var with_star4 := 0
	var same_as_base := 0
	var missing_label := 0
	var screen: Node = _screen()
	for raw in DataRegistry.get_table("race_units").get("units", []):
		var d := raw as Dictionary
		if d == null:
			continue
		total += 1
		if typeof(d.get("star4", null)) != TYPE_DICTIONARY:
			continue
		with_star4 += 1
		var base_text := UnitDetailFormat.format_skill_detail(d)
		var four_text := UnitDetailFormat.format_skill_detail(
			UnitFactory.apply_star_stats(d, GameConstants.MAX_STAR))
		if four_text.is_empty() or four_text == base_text:
			same_as_base += 1
		# 真面板结构：带 star4 的必须都画出标签。
		var entry := {"raw": d, "skill_id": str(d.get("skill_id", ""))}
		var panel: Control = screen._build_skill_box(entry, true)
		add_child(panel)
		var texts: Array[String] = []
		for l in _all_labels(panel):
			texts.append(l.text)
		panel.queue_free()
		if not (LABEL_ZH in texts):
			missing_label += 1
	_h.expect(total == 40, "race_unit_total_40",
		"族棋子应当是 40 个，实际 %d" % total)
	_h.expect(with_star4 > 0, "has_star4_units",
		"应当有带 star4 覆写的族棋子，实际 %d" % with_star4)
	_h.expect(same_as_base == 0, "star4_copy_differs_from_base",
		"带 star4 的棋子四星正文必须与一~三星不同，实际有 %d 个相同/为空" % same_as_base)
	_h.expect(missing_label == 0, "all_star4_units_render_label",
		"带 star4 的棋子面板里都要有「%s」标签，实际漏了 %d 个" % [LABEL_ZH, missing_label])


# 3) 没有 star4 覆写的棋子：helper 返回空串（不许多画一段）。
func _case_no_star4_units_skip() -> void:
	var screen: Node = _screen()
	var checked := 0
	for raw in DataRegistry.get_table("race_units").get("units", []):
		var d := raw as Dictionary
		if d == null or typeof(d.get("star4", null)) == TYPE_DICTIONARY:
			continue
		checked += 1
		var entry := {"raw": d, "skill_id": str(d.get("skill_id", ""))}
		var text := str(screen._four_star_skill_text(entry))
		_h.expect(text.is_empty(), "no_star4_%s_skips" % str(d.get("id", "")),
			"没有 star4 的棋子不该有四星正文，实际得到 %s" % text)
		# 面板里也不许出现标签。
		var panel: Control = screen._build_skill_box(entry, true)
		add_child(panel)
		var texts: Array[String] = []
		for l in _all_labels(panel):
			texts.append(l.text)
		panel.queue_free()
		_h.expect(not (LABEL_ZH in texts), "no_star4_%s_no_label" % str(d.get("id", "")),
			"没有 star4 的棋子面板里不该有「%s」标签" % LABEL_ZH)
	_h.expect(checked >= 1, "has_units_without_star4",
		"应当存在没有 star4 覆写的棋子作为反向对照，实际 %d" % checked)


func _screen() -> Node:
	return get_child(0)


# ★ 必须按**树的前序**收集（父 -> 子、从左到右），不能用栈倒序。
#   `_build_skill_box` 里标签的添加顺序就是 [技能, 一~三星正文, 四级升星后, 四星正文]；
#   用 stack.pop_back() 会得到倒序，于是「四级升星后」的下一项变成它**上面**那条
#   （一~三星正文）—— 断言会以为四星正文等于基础正文，产生假红/假绿。
func _all_labels(node: Node) -> Array[Label]:
	var out: Array[Label] = []
	var queue: Array[Node] = [node]
	while not queue.is_empty():
		var cur: Node = queue.pop_front()
		if cur is Label:
			out.append(cur as Label)
		for c in cur.get_children():
			queue.append(c)
	return out


func _raw_for(unit_id: String) -> Dictionary:
	for raw in DataRegistry.get_table("race_units").get("units", []):
		var d := raw as Dictionary
		if d != null and str(d.get("id", "")) == unit_id:
			return d
	return {}
