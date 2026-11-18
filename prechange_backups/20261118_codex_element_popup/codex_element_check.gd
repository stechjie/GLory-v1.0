extends Node

# 第 11 点（10.01 反馈）：图鉴在「状态」后面新增「元素」分类（天 / 地 / 人）。
#
# 用户原文：「图鉴功能在状态后面增加一个类别：元素，分为"天""地""人"，图标选自游戏里。
# 图鉴内容写对应元素的具体克制属性数值。……参考状态分类里的"护盾"，图标改为天元素的
# 图标，然后名称"护盾"改为"天"，上面的"增益"改为"属性"，效果描述就改成天元素的克制
# 关系和数值。」
#
# 五节：
#   A 纯数据：元素分类的结构与位置（必须排在状态**之后**）
#   B 本地化键真的翻得出来（漏配时 tr() 原样返回键名，页面上就会冒出 codex_xxx），
#     中英各扫一遍
#   C 真实现：Script.new() 直调 CodexScreen 的 _is_reference_category / _build_badges
#     / _build_detail / _build_state_line。**不 add_child** —— CodexScreen._ready() 会
#     调 CodexService.sync_owned_pets() 写用户档案，门禁不该碰玩家数据
#   D 回归：状态分类没被顶掉，「增益 / 异常」角标和它的脚注原样
#   E 判别力：文案↔实现（从 BattleSimShared._element_multiplier 反推"谁克谁"，
#     再断言中文 desc 里点名的就是那个元素）、三族文本互不相同、未知名分类为空

const H := preload("res://tools/CheckHarness.gd")
const ScreenScript := preload("res://scenes/menu/CodexScreen.gd")
# 用 preload 而不是全局类名：--headless 冷跑时全局类缓存不一定就绪。
const SimShared := preload("res://scripts/battle/BattleSimShared.gd")

const ELEM_IDS := ["sky", "land", "ren"]
const ELEM_CN := {"sky": "天", "land": "地", "ren": "人"}
const ELEM_EN := {"sky": "Sky", "land": "Land", "ren": "Human"}

# 状态分类的规模，用来证明它没被新分类挤掉。
const STATUS_COUNT := 14

# 元素条目**不许**带这些字段：带上就会落到「增益 / 异常」的分支去。
const FORBIDDEN_FIELDS := ["buff"]

var h


func _ready() -> void:
	h = H.new("codex_element")
	var saved: String = LocaleManager.get_locale()

	var list: Array[Dictionary] = CodexService.entries_for("element")
	_section_category(list)
	_section_locale(list, "zh")

	var screen: Control = ScreenScript.new()
	_section_wiring(screen, list)
	_section_regression(screen)

	LocaleManager.set_locale("en")
	_section_locale(list, "en")
	LocaleManager.set_locale(saved)

	_section_discrimination(list)
	screen.free()

	h.finish(get_tree())


# ── A. 分类结构与位置 ───────────────────────────────────────────────────────

func _section_category(list: Array[Dictionary]) -> void:
	var keys: Array[String] = []
	for c in CodexService.CATEGORIES:
		keys.append(str(c.get("key", "")))

	h.expect(keys.has("element"), "cat_has_element",
		"CATEGORIES 里必须有 element 分类")
	h.expect(keys.find("element") == keys.find("status") + 1, "cat_element_right_after_status",
		"「元素」必须**紧跟**在「状态」之后（第 11 条：在状态后面增加）")
	h.expect(not keys.is_empty() and keys[keys.size() - 1] == "element", "cat_element_is_last",
		"「元素」是最后一个标签页")
	h.expect(keys.count("element") == 1, "cat_element_once",
		"element 分类不能重复登记")
	h.expect(str(CodexService._category("element").get("kind", "")) == "element", "cat_kind",
		"element 分类的 kind 必须是 element，entries_for 才路由得到")

	h.expect(list.size() == ELEM_IDS.size(), "cat_entry_count",
		"元素分类正好 %d 条（天 / 地 / 人），实际 %d" % [ELEM_IDS.size(), list.size()])

	for entry in list:
		var id := str(entry.get("id", ""))
		h.expect(ELEM_IDS.has(id), "item_%s_id" % id, "条目 id 必须是 sky / land / ren，实际 %s" % id)
		h.expect(str(entry.get("name_key", "")) == "codex_elem_%s" % id, "item_%s_name_key" % id,
			"名称走本地化键 codex_elem_%s（静态上下文里 tr() 不可调用）" % id)
		h.expect(str(entry.get("desc_key", "")) == "codex_element_%s_desc" % id, "item_%s_desc_key" % id,
			"描述走本地化键 codex_element_%s_desc" % id)
		var portrait := str(entry.get("portrait", ""))
		h.expect(portrait == "res://assets/ui/codex_portraits/elem_%s.png" % id, "item_%s_portrait_path" % id,
			"图标指向 elem_%s.png（第 11 条：图标选自游戏里）" % id)
		h.expect(ResourceLoader.exists(portrait), "item_%s_portrait_exists" % id,
			"图标文件必须真的存在：%s" % portrait)
		h.expect(bool(entry.get("icon_art", false)), "item_%s_icon_art" % id,
			"icon_art=true（整图不裁切，和状态图标同一种画法）")
		h.expect(bool(entry.get("attribute", false)), "item_%s_attribute" % id,
			"attribute=true —— 角标才写「属性」而不是「增益 / 异常」")
		h.expect(not bool(entry.get("collectible", true)), "item_%s_not_collectible" % id,
			"参考物料不算收集进度（计数栏写「N 种」）")
		h.expect(CodexService.is_unlocked(entry), "item_%s_unlocked" % id,
			"元素永远可读，不参与解锁")
		for f in FORBIDDEN_FIELDS:
			# 前提体检：带上 buff 的条目会走「增益 / 异常」分支，
			# 那下面「角标写属性」的断言就成了走不到的空话。
			h.expect(not entry.has(f), "item_%s_no_%s" % [id, f],
				"元素条目不许带 %s 字段，否则落到状态那条角标分支" % f)


# ── B. 本地化键真的配了 ─────────────────────────────────────────────────────

func _section_locale(list: Array[Dictionary], locale: String) -> void:
	LocaleManager.set_locale(locale)
	if locale == "zh":
		h.expect(tr("codex_tab_element") == "元素", "loc_zh_tab", "标签名是「元素」")
		h.expect(tr("codex_attr") == "属性", "loc_zh_attr", "角标是「属性」而不是「增益」")
		for id in ELEM_IDS:
			h.expect(tr("codex_elem_%s" % id) == ELEM_CN[id], "loc_zh_name_%s" % id,
				"「%s」的中文名必须是 %s" % [id, ELEM_CN[id]])
	else:
		h.expect(tr("codex_tab_element") == "Element", "loc_en_tab", "英文标签名是 Element")
		h.expect(tr("codex_attr") == "Attribute", "loc_en_attr", "英文角标是 Attribute")
		for id in ELEM_IDS:
			h.expect(tr("codex_elem_%s" % id) == ELEM_EN[id], "loc_en_name_%s" % id,
				"「%s」的英文名必须是 %s" % [id, ELEM_EN[id]])

	# 漏配时 tr() 原样返回键名 —— 这才是真在查键。
	for key in ["codex_tab_element", "codex_attr", "codex_element_reference"]:
		h.expect(tr(key) != key, "loc_%s_%s_missing" % [locale, key], "翻译键漏配：%s" % key)
	for entry in list:
		for key_field in ["name_key", "desc_key"]:
			var key := str(entry.get(key_field, ""))
			var got := tr(key)
			h.expect(not got.is_empty() and got != key, "loc_%s_%s_%s" % [locale, entry.get("id", ""), key_field],
				"翻译键漏配或为空：%s" % key)


# ── C. 真实现 ───────────────────────────────────────────────────────────────

func _section_wiring(screen: Control, list: Array[Dictionary]) -> void:
	# 参考档：计数栏写「N 种」而不是「已发现 N/M」。
	screen._category = "element"
	h.expect(screen._is_reference_category(), "wire_element_is_reference",
		"元素和状态一样是参考物料")
	screen._category = "god"
	h.expect(not screen._is_reference_category(), "wire_god_not_reference",
		"棋子分类不能算参考物料（判别力：这个断言必须有可能为假）")

	var sky: Dictionary = list[0]

	# 角标：「属性」。之前这里只有 buff / debuff 两支，元素会一个角标都没有。
	var badges: Control = screen._build_badges(sky, true)
	h.expect(badges != null, "wire_badges_not_null",
		"元素条目必须有角标（没有 attribute 分支时 _build_badges 会因为空行返回 null）")
	var badge_texts := _label_texts(badges)
	h.expect(badge_texts.has(tr("codex_attr")), "wire_badge_attribute",
		"角标文字是「属性」，实际 %s" % str(badge_texts))
	h.expect(not badge_texts.has(tr("codex_buff")) and not badge_texts.has(tr("codex_debuff")),
		"wire_badge_not_buff", "元素不能出现「增益 / 异常」角标")

	# 脚注：元素不能复用状态那句（那句讲的是战斗 HUD 的减益图标）。
	# 显式标注类型：screen 是 Control，走它的私有方法拿到的是 Variant，
	# `var line := ...` 推不出类型会直接 Parse Error（GDScript 静默不了的硬错）。
	var line: Control = screen._build_state_line(sky, true)
	h.expect(line is Label, "wire_state_is_label", "脚注是一个 Label")
	h.expect((line as Label).text == tr("codex_element_reference"), "wire_state_copy",
		"元素脚注走 codex_element_reference")
	h.expect((line as Label).text != tr("codex_status_reference"), "wire_state_not_status_copy",
		"元素不能套用状态那句「图标与战斗中显示的完全一致」")

	# 右页整页：名称「天」+ 角标「属性」+ 描述里的克制数值。
	screen._detail = VBoxContainer.new()
	screen._build_detail(sky)
	var page := _label_texts(screen._detail)
	var all := "\n".join(page)
	h.expect(page.has(ELEM_CN["sky"]), "wire_page_name",
		"右页名称是「天」，实际 %s" % str(page))
	h.expect(page.has(tr("codex_attr")), "wire_page_attribute", "右页有「属性」角标")
	h.expect(all.contains("×1.25"), "wire_page_has_125", "右页描述给出克制倍率 ×1.25")
	h.expect(all.contains("×0.85"), "wire_page_has_085", "右页描述给出被反制倍率 ×0.85")
	h.expect(not all.contains("已解锁") and not all.contains("未解锁") and not all.contains("还差"),
		"wire_page_no_battle_state", "元素描述里不许出现战场达成条件")
	h.expect(screen._detail.get_child_count() > 0, "wire_page_built",
		"右页真的建出了内容")


# ── D. 回归：状态分类没被动 ─────────────────────────────────────────────────

func _section_regression(screen: Control) -> void:
	var st: Array[Dictionary] = CodexService.entries_for("status")
	h.expect(st.size() == STATUS_COUNT, "reg_status_count",
		"状态仍是 %d 条，实际 %d" % [STATUS_COUNT, st.size()])
	var keeps_buff := true
	for s in st:
		if not s.has("buff"):
			keeps_buff = false
	h.expect(keeps_buff, "reg_status_keeps_buff", "状态条目仍然带 buff 字段")
	h.expect(CodexService.progress_for("status") == Vector2i(STATUS_COUNT, STATUS_COUNT),
		"reg_status_progress", "状态仍然全部可读")

	var st_badges := _label_texts(screen._build_badges(st[0], true))
	h.expect(st_badges.has(tr("codex_buff")) or st_badges.has(tr("codex_debuff")), "reg_status_badge_buff",
		"状态角标仍然是「增益 / 异常」，实际 %s" % str(st_badges))

	screen._category = "status"
	h.expect(screen._is_reference_category(), "reg_status_reference", "状态仍然是参考物料")
	h.expect((screen._build_state_line(st[0], true) as Label).text == tr("codex_status_reference"),
		"reg_status_state_copy", "状态脚注原样")
	screen._category = "element"


# ── E. 判别力 ───────────────────────────────────────────────────────────────

func _section_discrimination(list: Array[Dictionary]) -> void:
	h.expect(list.size() == ELEM_IDS.size(), "disc_list_size",
		"入口拿到的就是三条元素条目")

	# 文案 ↔ 实现：谁克谁不是照抄注释，而是现算一遍倍率再回来点名。
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
	var texts: Array[String] = []
	for id in ELEM_IDS:
		texts.append(tr("codex_element_%s_desc" % id))
	var uniq := {}
	for t in texts:
		uniq[t] = true
	h.expect(uniq.size() == ELEM_IDS.size(), "disc_texts_differ",
		"天 / 地 / 人 的克制数值描述必须两两不同，实际 %d 种" % uniq.size())

	# 判别力：未知名分类必须空，不能因为兜底返回全部而假绿。
	h.expect(CodexService.entries_for("no_such_category").is_empty(), "disc_unknown_empty",
		"未知分类必须返回空")
	h.expect(CodexService.entries_for("element").size() == ELEM_IDS.size(), "disc_element_only",
		"元素分类只出元素条目")


# attacker=true: 找 a 攻击谁倍率最高；attacker=false: 找谁攻击 a 倍率最高。
# weak=true 时反过来找 a 攻击谁倍率最低（被反制的那一个）。
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
