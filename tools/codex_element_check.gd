extends Node

# 图鉴「元素」（天 / 地 / 人）门禁。
#
# 历史：10.01 第 11 条在「状态」后面加了一个「元素」分类页。
# ★ 11.18 用户要求：删掉那一页，改成查看棋子 / 怪物 / Boss 时，点「元素」或「系」
#   徽章弹出克制说明（和种族徽章弹羁绊说明一样）；同时修「说明要按两次才关掉」。
#
# 五节：
#   A 分类页确实删了：CATEGORIES 里没有 element，entries_for("element") 为空
#   B 本地化键还在（弹窗要用）：元素名 + 克制描述，中英各扫一遍
#   C 真实现：元素 / 系 / 种族徽章都装了手势；真点一下弹出的是该元素的克制说明；
#     「触摸 + 模拟鼠标」双路投递只弹**一个**框（11.18「要按两次」的根因）
#   D 回归：状态分类没被动
#   E 判别力：文案↔实现（从 BattleSimShared._element_multiplier 反推"谁克谁"，
#     再断言中文 desc 里点名的就是那个元素）、三族文本互不相同
#
# CodexScreen 不 add_child —— 它的 _ready() 会调 CodexService.sync_owned_pets()
# 写用户档案，门禁不该碰玩家数据。徽章行单独挂到本节点下（计时器要在树上才能 start）。

const H := preload("res://tools/CheckHarness.gd")
const ScreenScript := preload("res://scenes/menu/CodexScreen.gd")
# 用 preload 而不是全局类名：--headless 冷跑时全局类缓存不一定就绪。
const SimShared := preload("res://scripts/battle/BattleSimShared.gd")

const ELEM_IDS := ["sky", "land", "ren"]
const ELEM_CN := {"sky": "天", "land": "地", "ren": "人"}
const ELEM_EN := {"sky": "Sky", "land": "Land", "ren": "Human"}

# 状态分类的规模，用来证明它没被动。
const STATUS_COUNT := 14

var h


func _ready() -> void:
	h = H.new("codex_element")
	var saved: String = LocaleManager.get_locale()

	_section_category()
	_section_locale("zh")

	var screen: Control = ScreenScript.new()
	await _section_wiring(screen)
	_section_regression(screen)

	LocaleManager.set_locale("en")
	_section_locale("en")
	LocaleManager.set_locale(saved)

	_section_discrimination()
	screen.free()

	h.finish(get_tree())


# ── A. 分类页确实删了 ───────────────────────────────────────────────────────

func _section_category() -> void:
	var keys: Array[String] = []
	for c in CodexService.CATEGORIES:
		keys.append(str(c.get("key", "")))
	h.expect(not keys.has("element"), "cat_no_element_tab",
		"「元素」分类页 11.18 已删除，CATEGORIES 里不该再有 element")
	h.expect(keys.has("status"), "cat_keeps_status", "「状态」分类还在")
	h.expect(CodexService.entries_for("element").is_empty(), "cat_element_entries_empty",
		"entries_for(\"element\") 必须为空（不再有元素条目）")
	var ids_ok: bool = CodexService.ELEMENTS.size() == ELEM_IDS.size()
	for id in ELEM_IDS:
		ids_ok = ids_ok and CodexService.ELEMENTS.has(id)
	h.expect(ids_ok, "cat_element_ids",
		"元素 id 列表仍是 sky / land / ren（徽章弹窗靠它判断）")


# ── B. 本地化键还在（弹窗要用） ─────────────────────────────────────────────

func _section_locale(locale: String) -> void:
	LocaleManager.set_locale(locale)
	for id in ELEM_IDS:
		var want: String = ELEM_CN[id] if locale == "zh" else ELEM_EN[id]
		h.expect(tr("codex_elem_%s" % id) == want, "loc_%s_name_%s" % [locale, id],
			"「%s」的名称必须是 %s，实际 %s" % [id, want, tr("codex_elem_%s" % id)])
	# 漏配时 tr() 原样返回键名 —— 这才是真在查键。
	var keys := ["codex_element_suffix", "codex_series_suffix", "codex_bond_gotit"]
	for id in ELEM_IDS:
		keys.append("codex_element_%s_desc" % id)
	for key in keys:
		var got := tr(key)
		h.expect(not got.is_empty() and got != key, "loc_%s_%s" % [locale, key],
			"翻译键漏配或为空：%s" % key)


# ── C. 真实现 ───────────────────────────────────────────────────────────────

func _section_wiring(screen: Control) -> void:
	# 1) 棋子：种族徽章 + 元素徽章，两个都要能点。
	var unit_row: Control = screen._build_badges({"race": "god", "element": "sky", "tier": 1}, true)
	add_child(unit_row)
	var unit_arts := _clickable_arts(unit_row)
	h.expect(unit_arts.size() == 2, "wire_unit_two_clickable",
		"棋子详情里种族 + 元素两个徽章都要能点，实际 %d 个" % unit_arts.size())

	# 2) 怪物：「系」徽章也能点（11.18 用户确认要）。
	var mon_row: Control = screen._build_badges({"series": "land"}, true)
	add_child(mon_row)
	h.expect(_clickable_arts(mon_row).size() == 1, "wire_series_clickable",
		"怪物的「系」徽章要能点")

	# 3) 判别力：未知元素不装手势（不能见到徽章就装）。
	var bad_row: Control = screen._build_badges({"element": "water"}, true)
	add_child(bad_row)
	h.expect(_clickable_arts(bad_row).is_empty(), "wire_unknown_element_inert",
		"非 sky / land / ren 的元素徽章不该能点")

	# 4) 真点元素徽章：只弹一个框，内容是天元素的克制说明。
	#    事件顺序模拟手机：触摸按下 → 模拟鼠标按下 → 触摸抬起 → 模拟鼠标抬起。
	if unit_arts.size() == 2:
		var sky_art: Control = unit_arts[1]
		ModalStack.close_all()
		var before := DialogService.open_count()
		_tap_dual(sky_art)
		await _settle()
		h.expect(DialogService.open_count() == before + 1, "wire_dual_tap_one_dialog",
			"触摸 + 模拟鼠标双路投递只该弹 1 个框（「要按两次才关」的根因），实际弹了 %d 个"
				% (DialogService.open_count() - before))
		var body := _dialog_body_text()
		h.expect(body == tr("codex_element_sky_desc"), "wire_dialog_is_sky_desc",
			"弹出来的是天元素的克制说明，实际正文前 40 字：%s" % body.substr(0, 40))
		h.expect(body.contains("×1.25") and body.contains("×0.85"), "wire_dialog_has_numbers",
			"弹窗里给出克制倍率 ×1.25 / ×0.85")

		# 已开着时再点一次：不能叠第二个框。
		_tap_mouse(sky_art)
		await _settle()
		h.expect(DialogService.open_count() == before + 1, "wire_reopen_no_stack",
			"同一份说明开着时再点，不能叠出第二个框")
		ModalStack.close_all()
		await _settle()
		h.expect(DialogService.open_count() == before, "wire_dialog_closes",
			"关一次就全关掉")

		# 种族徽章同样只弹一个（同一条修复）。
		var race_art: Control = unit_arts[0]
		_tap_dual(race_art)
		await _settle()
		h.expect(DialogService.open_count() == before + 1, "wire_race_dual_tap_one_dialog",
			"种族徽章双路投递也只弹 1 个框，实际 %d 个" % (DialogService.open_count() - before))
		ModalStack.close_all()
		await _settle()

	for row in [unit_row, mon_row, bad_row]:
		row.queue_free()
	await get_tree().process_frame


# ── D. 回归：状态分类没被动 ─────────────────────────────────────────────────

func _section_regression(screen: Control) -> void:
	var st: Array[Dictionary] = CodexService.entries_for("status")
	h.expect(st.size() == STATUS_COUNT, "reg_status_count",
		"状态仍是 %d 条，实际 %d" % [STATUS_COUNT, st.size()])
	h.expect(CodexService.progress_for("status") == Vector2i(STATUS_COUNT, STATUS_COUNT),
		"reg_status_progress", "状态仍然全部可读")
	var st_badges := _label_texts(screen._build_badges(st[0], true))
	h.expect(st_badges.has(tr("codex_buff")) or st_badges.has(tr("codex_debuff")), "reg_status_badge_buff",
		"状态角标仍然是「增益 / 异常」，实际 %s" % str(st_badges))
	screen._category = "status"
	h.expect(screen._is_reference_category(), "reg_status_reference", "状态仍然是参考物料")
	h.expect((screen._build_state_line(st[0], true) as Label).text == tr("codex_status_reference"),
		"reg_status_state_copy", "状态脚注原样")
	screen._category = "god"
	h.expect(not screen._is_reference_category(), "reg_god_not_reference",
		"棋子分类不能算参考物料（判别力：这个断言必须有可能为假）")


# ── E. 判别力：文案 ↔ 实现 ─────────────────────────────────────────────────

func _section_discrimination() -> void:
	LocaleManager.set_locale("zh")
	# 谁克谁不是照抄注释，而是现算一遍倍率再回来点名。
	for a in ELEM_IDS:
		var beaten := _pick(a, true)
		var nemesis := _pick(a, false)
		var weak_to := _pick(a, true, true)
		var strong_def := _pick(a, false, true)
		h.expect(not beaten.is_empty(), "disc_%s_has_target" % a,
			"%s 应当恰好克制一个元素" % a)
		h.expect(not nemesis.is_empty(), "disc_%s_has_nemesis" % a,
			"%s 应当恰好被一个元素克制" % a)
		var desc := tr("codex_element_%s_desc" % a)
		if beaten.is_empty() or nemesis.is_empty() or weak_to.is_empty() or strong_def.is_empty():
			continue
		h.expect(desc.contains("克制「%s」" % ELEM_CN[beaten]), "disc_%s_names_target" % a,
			"desc 必须点名它克制的是「%s」" % ELEM_CN[beaten])
		h.expect(desc.contains("被「%s」克制" % ELEM_CN[nemesis]), "disc_%s_names_nemesis" % a,
			"desc 必须点名克制它的是「%s」" % ELEM_CN[nemesis])
		h.expect(desc.contains("攻击「%s」伤害 ×0.85" % ELEM_CN[weak_to]), "disc_%s_names_weak" % a,
			"desc 必须给出攻击「%s」只有 ×0.85" % ELEM_CN[weak_to])
		h.expect(desc.contains("受到「%s」攻击伤害 ×0.85" % ELEM_CN[strong_def]),
			"disc_%s_names_strong_def" % a,
			"desc 必须交代受到「%s」攻击只有 ×0.85" % ELEM_CN[strong_def])
		h.expect(desc.contains("×1.00"), "disc_%s_same_element" % a,
			"desc 必须交代同元素 ×1.00")

	# 三族文本互不相同（否则就是把同一段抄了三遍）。
	var uniq := {}
	for id in ELEM_IDS:
		uniq[tr("codex_element_%s_desc" % id)] = true
	h.expect(uniq.size() == ELEM_IDS.size(), "disc_texts_differ",
		"天 / 地 / 人 的克制数值描述必须两两不同，实际 %d 种" % uniq.size())


# attacker=true: 找 a 攻击谁倍率最高；attacker=false: 找谁攻击 a 倍率最高。
# weak=true 时反过来找倍率最低的那一个。
func _pick(a: String, attacker: bool, weak: bool = false) -> String:
	var best := ""
	var best_v := 1.0
	for b in ELEM_IDS:
		if b == a:
			continue
		var v: float = (SimShared._element_multiplier(a, b) if attacker
			else SimShared._element_multiplier(b, a))
		if weak:
			if v < best_v:
				best_v = v
				best = b
		elif v > best_v:
			best_v = v
			best = b
	return best


# ── 辅助 ────────────────────────────────────────────────────────────────────

# 装了手势的徽章图：mouse_filter = STOP 的 TextureRect（没装手势的保持 IGNORE）。
func _clickable_arts(root: Node) -> Array:
	var out: Array = []
	_collect_arts(root, out)
	return out


func _collect_arts(node: Node, out: Array) -> void:
	if node is TextureRect and (node as Control).mouse_filter == Control.MOUSE_FILTER_STOP:
		out.append(node)
	for child in node.get_children():
		_collect_arts(child, out)


# 手机上的一次轻点：触摸一路 + emulate_mouse_from_touch 模拟出来的鼠标一路。
func _tap_dual(art: Control) -> void:
	var tp := InputEventScreenTouch.new()
	tp.pressed = true
	art.gui_input.emit(tp)
	var mp := InputEventMouseButton.new()
	mp.button_index = MOUSE_BUTTON_LEFT
	mp.pressed = true
	art.gui_input.emit(mp)
	var tr_ev := InputEventScreenTouch.new()
	tr_ev.pressed = false
	art.gui_input.emit(tr_ev)
	var mr := InputEventMouseButton.new()
	mr.button_index = MOUSE_BUTTON_LEFT
	mr.pressed = false
	art.gui_input.emit(mr)


func _tap_mouse(art: Control) -> void:
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		art.gui_input.emit(ev)


func _settle() -> void:
	for _i in 3:
		await get_tree().process_frame


func _dialog_body_text() -> String:
	var label := get_tree().root.find_child("DialogBody", true, false) as Label
	return "" if label == null else label.text


# 递归收集一棵子树里所有 Label / Button 的文字。
func _label_texts(root: Node) -> Array:
	var out: Array = []
	if root == null:
		return out
	_collect(root, out)
	return out


func _collect(node: Node, out: Array) -> void:
	if node is Label:
		out.append((node as Label).text)
	elif node is Button:
		out.append((node as Button).text)
	for child in node.get_children():
		_collect(child, out)
