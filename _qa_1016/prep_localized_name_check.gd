extends Node
# ============================================================================
# 2026-10-16 第 2 条门禁：英文界面下的**显示名**必须走本地化取法。
#
# 【反馈原文】（桌面《10.16bug提交及修复.docx》第 2 点）
#   「英文语音模式下，萝卜营地里三星升级四星功能棋子的名字未转成英文版格式。
#     之前遇到太多相关的情况，也修复了几处类似的地方。请你仔细检查，如果还有
#     类似的地方请调整过来。」
#
# 【根因】显示名直读数据表的 `name`。DataRegistry.canonicalize_unit_display_names()
#   只把 name / name_en 覆写成正式表的值（防服务器 payload 与旧存档的历史名），
#   **不按 locale 选语言**；按 locale 取 name_en 的只有 unit_display_name()，
#   包装层是 PrepWidgets.unit_name() / PrepWidgets.localized_name()。
#   ⇒ 任何 `def.get("name")` 在英文界面下**永远**是中文。
#
# 【这个门禁钉什么】（七处站点 + 一条"图标不许消失"的回归钉）
#   site1 萝卜营地 · 升级石页 · 四星候选行标题
#   site2 卖掉四星棋子 · 二次确认框正文
#   site3 佣兵购买卡 · 拖拽预览（源码断言：UI 组装函数要整棵 PrepUI 才跑得起来）
#   site4/5/6 已拥有宝物 / 联动 / 套装 logo 的 tooltip（源码断言，同上）
#   site7 联动详情浮层的**标题**（真跑 _show_linkage_detail）
#   site8 「图标消失」回归钉：_add_owned_treasure_logo() 的第二个参数是**贴图名**
#         （treasure_logos/ 下就是中文文件名），同时兼任"缺图时的文字兜底"。
#         把显示名喂进去 ⇒ 英文下路径成了 "Phoenix Rebirth.png" ⇒ 找不到
#         ⇒ 只剩兜底文字（玩家截图：「宝藏图标消失了」）。所以本门禁两头钉：
#           · 行为侧：三张贴图名表的每个值在 treasure_logos/ 里都有对应文件
#           · 源码侧：调用点的第二参必须是贴图名表达式，显示名只能喂 tooltip
#
# 【★ 为什么必须有源码那一侧】行为侧只证明"表 ↔ 目录一致"，证明不了
#   "调用点用的是表"。而"图标会不会消失"完全取决于调用点怎么写 ——
#   只钉数据就会在把显示名塞进第二参时**照样绿**，正是这次返工的教训。
#
# 【跑法】
#   Godot_v4.7.2-stable_win64_console.exe --headless --path <工程根> \
#       _qa_1016/prep_localized_name_check.tscn
#   退出码 0 = PASS，1 = FAIL。
#
# 【写法铁律】本轮新增的 `_localized_row_name` 一律走 has_method + Callable，
#   **不编译期绑定** —— 否则未修复构建整个脚本解析失败、场景无脚本、进程不退出
#   （假挂而不是判红）。Callable 取法失效时必须 fail() 显式记账，不能直接 call()。

const CheckHarness := preload("res://_qa_1016/CheckHarness.gd")
const CarrotCampPanelV3 := preload("res://scenes/prep/CarrotCampPanelV3.gd")
const PrepBoardController := preload("res://scenes/prep/PrepBoardController.gd")
const PrepUI := preload("res://scenes/prep/PrepUI.gd")
const PrepWidgets := preload("res://scenes/prep/PrepWidgets.gd")

const CHECK_NAME := "prep_localized_name"
const PREP_UI_SRC := "res://scenes/prep/PrepUI.gd"
const PREP_CTRL_SRC := "res://scenes/prep/PrepBoardController.gd"
const CARROT_SRC := "res://scenes/prep/CarrotCampPanelV3.gd"
const LOGO_DIR := "res://assets/ui/treasure_logos"

const UNIT_ID := "god_priest"        # 神侍 / Godhand
const MERC_ID := "merc_cancer_shell" # 甲壳守卫 / Shell Guard
const TREASURE_ID := "def_iron_wall" # 铁壁之护 / Iron Wall
const LINK_ID := "link_phoenix"      # 凤凰涅槃 / Phoenix Rebirth
const SET_CAT := "defense"           # 4防卫 / 4 Defense

var _h: CheckHarness
var _def := {}
var _merc := {}
var _treasure := {}
var _link := {}
var _set := {}


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()
	_def = _unit_by_id(UNIT_ID)
	_merc = _unit_by_id(MERC_ID)
	_treasure = TreasureService.treasure_by_id(TREASURE_ID)
	_link = CodexService.link_text(LINK_ID)
	_set = CodexService.set_text(SET_CAT)
	await _run()
	# 收尾：locale 还回中文，免得同进程里后续检查被污染。
	LocaleManager.set_locale("zh")
	GameState.reset_run()
	_h.expect(_h.checked_count() >= 55, "too_few_assertions",
		"整个门禁只量到 %d 条断言，等于没验" % _h.checked_count())
	_h.finish(get_tree())


func _run() -> void:
	_root_cause()
	await _site1_carrot_row()
	await _site2_sell_dialog()
	await _site7_link_title()
	_helper_behaviour()
	_logo_art_tables()
	_source_assertions()


# ---- 根因：canonicalize 不改语言，只有 unit_display_name 按 locale 取 ----------

func _root_cause() -> void:
	_h.expect(not _def.is_empty() and not _merc.is_empty()
		and not _treasure.is_empty() and not _link.is_empty() and not _set.is_empty(),
		"probe_data_missing",
		"五份被测数据没取全（unit=%d merc=%d treasure=%d link=%d set=%d）—— 后面全是空转"
		% [_def.size(), _merc.size(), _treasure.size(), _link.size(), _set.size()])
	var zh_name := str(_def.get("name", ""))
	var en_name := str(_def.get("name_en", ""))
	_h.expect(zh_name == "神侍" and en_name == "Godhand", "probe_unit_names_changed",
		"神侍/Godhand 的名字变了（name=%s name_en=%s）—— 换一枚棋子再跑" % [zh_name, en_name])

	_h.expect(DataRegistry.unit_display_name(_def, false) == zh_name,
		"unit_display_name_zh", "中文档取到的不是 name")
	_h.expect(DataRegistry.unit_display_name(_def, true) == en_name,
		"unit_display_name_en",
		"英文档取到的不是 name_en（得到 %s）—— 本地化取法本身坏了"
		% str(DataRegistry.unit_display_name(_def, true)))

	# canonicalize 只同步「改名」，不做本地化：调用之后 name 仍是中文。
	var canon := _def.duplicate(true)
	DataRegistry.canonicalize_unit_display_names(canon)
	_h.expect(str(canon.get("name", "")) == zh_name, "canonicalize_changed_locale",
		"canonicalize 之后 name 不再是中文（%s）—— 「直读 name 在英文下必中文」这条根因表述要重读"
		% str(canon.get("name", "")))

	LocaleManager.set_locale("en")
	_h.expect(PrepWidgets.is_en(), "widgets_is_en_not_following_locale",
		"set_locale(\"en\") 之后 PrepWidgets.is_en() 仍为假 —— 后面所有英文断言都会假绿")
	_h.expect(PrepWidgets.unit_name(_def) == en_name, "widgets_unit_name_en",
		"PrepWidgets.unit_name 在英文档下返回 %s（应为 %s）"
		% [PrepWidgets.unit_name(_def), en_name])
	LocaleManager.set_locale("zh")


# ---- site1 萝卜营地四星候选行标题（真面板，中英各刷一次）---------------------

func _site1_carrot_row() -> void:
	var panel := CarrotCampPanelV3.new()
	add_child(panel)
	panel.setup(Callable(), Callable(), Callable())
	GameState.board_slots[0] = {"def": _def.duplicate(true), "star": 3, "uid": "gate_1"}
	LocaleManager.set_locale("zh")
	var zh := _find_label_containing(panel, "★★★")
	LocaleManager.set_locale("en")
	var en := _find_label_containing(panel, "★★★")
	panel.queue_free()

	if zh.is_empty() or en.is_empty():
		_h.fail("site1_row_missing",
			"萝卜营地没有生成 ★★★ 候选行（zh=\"%s\" en=\"%s\"）—— 面板本身没建出行，这条量不到" % [zh, en])
		return
	_site_pair("site1", zh, en, str(_def.get("name", "")), str(_def.get("name_en", "")))


# ---- site2 卖掉四星棋子 · 二次确认框正文（真对话框）--------------------------

func _site2_sell_dialog() -> void:
	GameState.reset_run()
	GameState.board_slots[0] = {"def": _def.duplicate(true), "star": 4, "uid": "gate_2"}
	var ctrl := PrepBoardController.new()
	add_child(ctrl)
	# ModalStack._attach 在 root 未 ready 时是 call_deferred 挂载 ⇒ 必须等两帧。
	LocaleManager.set_locale("zh")
	ctrl.call("_ask_four_star_sell", "board", 0, GameState.board_slots[0])
	await get_tree().process_frame
	await get_tree().process_frame
	var zh := _find_label_named(get_tree().root, "DialogBody")
	ModalStack.close_all()
	LocaleManager.set_locale("en")
	ctrl.call("_ask_four_star_sell", "board", 0, GameState.board_slots[0])
	await get_tree().process_frame
	await get_tree().process_frame
	var en := _find_label_named(get_tree().root, "DialogBody")
	ModalStack.close_all()
	ctrl.queue_free()

	if zh.is_empty() or en.is_empty():
		_h.fail("site2_dialog_missing",
			"没读到二次确认框的 DialogBody（zh=\"%s\" en=\"%s\"）" % [zh, en])
		return
	_site_pair("site2", zh, en, str(_def.get("name", "")), str(_def.get("name_en", "")))


# ---- site7 联动详情浮层的标题（真跑 _show_linkage_detail）--------------------

func _site7_link_title() -> void:
	var ctrl := PrepBoardController.new()
	add_child(ctrl)
	var pop := PopupPanel.new()
	add_child(pop)
	var lbl := RichTextLabel.new()
	pop.add_child(lbl)
	var ov: Variant = ctrl.get("_overlay")
	if ov == null:
		_h.fail("site7_overlay_missing", "PrepBoardController 上没有 _overlay，标题量不到")
		ctrl.queue_free()
		return
	ov.call("bind", pop, lbl)

	LocaleManager.set_locale("zh")
	ctrl.call("_show_linkage_detail", LINK_ID)
	var zh := lbl.text
	LocaleManager.set_locale("en")
	ctrl.call("_show_linkage_detail", LINK_ID)
	var en := lbl.text
	ctrl.queue_free()
	pop.queue_free()

	var zh_name := str(_link.get("name", ""))
	var en_name := str(_link.get("name_en", ""))
	# 标题是第一行；正文（Treasures: … / 宝藏：…）本来就已经本地化了。
	var zh_title := zh.split("\n")[0] if not zh.is_empty() else ""
	var en_title := en.split("\n")[0] if not en.is_empty() else ""
	if zh_title.is_empty() or en_title.is_empty():
		_h.fail("site7_title_missing",
			"联动详情浮层没拿到文本（zh=\"%s\" en=\"%s\"）" % [zh, en])
		return
	_site_pair("site7", zh_title, en_title, zh_name, en_name)
	# 贴图名（恒为中文）绝不能当标题：这条与上一条互为证据。
	_h.expect(en_title != str(PrepUI.TREASURE_LINKAGE_LOGOS.get(LINK_ID, "")),
		"site7_en_art_name_as_title",
		"英文档下联动标题仍是贴图名「%s」—— 显示名又直读了 TREASURE_LINKAGE_LOGOS"
		% str(PrepUI.TREASURE_LINKAGE_LOGOS.get(LINK_ID, "")))


# ---- helper 行为（走 has_method + Callable，取法失效必须显式记账）-------------

func _helper_behaviour() -> void:
	var ui: Node = PrepUI.new()
	var probe: Variant = ui
	if not ui.has_method("_localized_row_name"):
		_h.fail("helper_unavailable",
			"PrepUI._localized_row_name 不存在（未修复构建？）—— 宝物/联动/套装的 tooltip 取法量不到了")
		ui.free()
		return
	var fn: Callable = Callable(probe, "_localized_row_name")
	if not fn.is_valid():
		_h.fail("helper_unavailable",
			"Callable(PrepUI, \"_localized_row_name\") 无效 —— 取法失效，不能直接 call()")
		ui.free()
		return

	var row := {"id": TREASURE_ID, "name": "铁壁之护", "name_en": "Iron Wall"}
	LocaleManager.set_locale("en")
	var en: String = fn.call(row, "fallback")
	LocaleManager.set_locale("zh")
	var zh: String = fn.call(row, "fallback")
	_h.expect(en == "Iron Wall", "helper_en_not_localized",
		"_localized_row_name 在英文档下返回 %s（应为 Iron Wall）" % en)
	_h.expect(zh == "铁壁之护", "helper_zh_broken",
		"_localized_row_name 在中文档下返回 %s（应为 铁壁之护）" % zh)
	LocaleManager.set_locale("en")
	_h.expect(fn.call({}, "fb") == "fb", "helper_empty_row_fallback",
		"空行没有回落 fallback（得到 %s）" % str(fn.call({}, "fb")))
	_h.expect(fn.call({"name_en": "?", "name": "?"}, "fb") == "fb", "helper_question_mark_fallback",
		"取不到名（\"?\"）时没有回落 fallback（得到 %s）" % str(fn.call({"name_en": "?", "name": "?"}, "fb")))
	LocaleManager.set_locale("zh")
	ui.free()


# ---- site8 图标回归钉：三张贴图名表 ↔ treasure_logos/ ------------------------

func _logo_art_tables() -> void:
	var missing: Array[String] = []
	var count := 0
	for key in PrepUI.TREASURE_LINKAGE_LOGOS:
		var art := str(PrepUI.TREASURE_LINKAGE_LOGOS[key])
		count += 1
		_h.item(1)
		if not ResourceLoader.exists("%s/%s.png" % [LOGO_DIR, art]):
			missing.append("linkage:%s→%s" % [str(key), art])
	for key in CodexService.SET_ART_NAME:
		var art := str(CodexService.SET_ART_NAME[key])
		count += 1
		_h.item(1)
		if not ResourceLoader.exists("%s/%s.png" % [LOGO_DIR, art]):
			missing.append("set:%s→%s" % [str(key), art])
	for row in DataRegistry.get_table("treasures").get("treasures", []):
		var art := str((row as Dictionary).get("name", ""))
		count += 1
		_h.item(1)
		if not ResourceLoader.exists("%s/%s.png" % [LOGO_DIR, art]):
			missing.append("treasure:%s→%s" % [str((row as Dictionary).get("id", "")), art])
	_h.expect(missing.is_empty(), "logo_art_file_missing",
		"%d/%d 个贴图名在 %s/ 里没有对应文件：%s —— 传进 _add_owned_treasure_logo 第二参"
		% [missing.size(), count, LOGO_DIR, ", ".join(missing)])


# ---- 源码断言（贴图名当第二参、显示名只喂 tooltip）----------------------------

func _source_assertions() -> void:
	var prep_ui := _read(PREP_UI_SRC)
	var ctrl := _read(PREP_CTRL_SRC)
	var carrot := _read(CARROT_SRC)

	# 宝物 logo：第二参 = t.name（贴图名），显示名进第四参
	_h.expect(prep_ui.contains('_add_owned_treasure_logo(tid_str, str(t.get("name", tid_str)),'),
		"src_treasure_logo_art",
		"宝物 logo 的第二参不再是贴图名（t.name）—— 英文档下贴图路径会跑飞、图标消失")
	_h.expect(prep_ui.contains('_treasure.show_detail.bind(tid_str), _localized_row_name(t, tid_str))'),
		"src_treasure_logo_tip",
		"宝物 logo 的 tooltip 没有走 _localized_row_name —— 英文档下悬停还是中文")
	# 联动 logo：同上
	_h.expect(prep_ui.contains('_add_owned_treasure_logo(lid, str(TREASURE_LINKAGE_LOGOS[lid]),'),
		"src_linkage_logo_art",
		"联动 logo 的第二参不再是贴图名（TREASURE_LINKAGE_LOGOS[lid]）—— 图标会消失")
	_h.expect(prep_ui.contains('_localized_row_name(CodexService.link_text(lid), str(TREASURE_LINKAGE_LOGOS[lid])))'),
		"src_linkage_logo_tip",
		"联动 logo 的 tooltip 没有走 _localized_row_name")
	# 套装 logo：第二参 = art（贴图名），显示名进第四参
	_h.expect(prep_ui.contains('_add_owned_treasure_logo(TreasureService.set_id(category), art,'),
		"src_set_logo_art",
		"套装 logo 的第二参不再是贴图名（art）—— 图标会消失")
	_h.expect(prep_ui.contains('_show_set_detail.bind(category), _localized_row_name(CodexService.set_text(category), art))'),
		"src_set_logo_tip",
		"套装 logo 的 tooltip 没有走 _localized_row_name")
	# site3 佣兵拖拽预览
	_h.expect(prep_ui.contains('card.set_meta("drag_preview_text", "%s\\n%s" % [PrepWidgets.unit_name(mercenary), price_text])'),
		"src_merc_drag_preview",
		"佣兵拖拽预览不再是 PrepWidgets.unit_name(mercenary) —— 英文档下飘出来的还是中文")
	# site7 联动详情标题
	_h.expect(ctrl.contains('var title := str(entry.get("name_en", "")) if PrepWidgets.is_en() else str(entry.get("name", ""))'),
		"src_link_detail_title",
		"联动详情标题没有按 locale 取 name_en/name")
	_h.expect(not ctrl.contains('var title := str(TREASURE_LINKAGE_LOGOS.get(link_id, link_id))'),
		"src_link_detail_art_as_title",
		"联动详情标题又变回贴图名（TREASURE_LINKAGE_LOGOS）—— 英文档下标题冒中文")
	# site1 萝卜营地行标题
	_h.expect(carrot.contains('PrepWidgets.unit_name(unit_def) if not unit_def.is_empty()'),
		"src_carrot_row_name",
		"萝卜营地四星候选行标题不再是 PrepWidgets.unit_name(unit_def)")


# ---- 小工具 ------------------------------------------------------------------

# 同一份数据在中文档要中文、英文档要英文，且英文档里**不能混着中文名**。
func _site_pair(prefix: String, zh: String, en: String, zh_want: String, en_want: String) -> void:
	_h.expect(zh.contains(zh_want), prefix + "_zh_not_chinese",
		"%s：中文档下没有出现「%s」（实际 \"%s\"）" % [prefix, zh_want, zh])
	_h.expect(en.contains(en_want), prefix + "_en_not_english",
		"%s：英文档下没有出现「%s」（实际 \"%s\"）—— 显示名直读了 name" % [prefix, en_want, en])
	_h.expect(not en.contains(zh_want), prefix + "_en_still_chinese",
		"%s：英文档下仍然是中文「%s」（实际 \"%s\"）" % [prefix, zh_want, en])


func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		_h.fail("src_missing", "读不到源文件 %s —— 源码断言全部落空" % path)
		return ""
	return FileAccess.get_file_as_string(path)


func _unit_by_id(id: String) -> Dictionary:
	for table_key in ["race_units", "mercenaries"]:
		var row_key := "units" if table_key == "race_units" else "mercenaries"
		for row in DataRegistry.get_table(table_key).get(row_key, []):
			if row is Dictionary and str((row as Dictionary).get("id", "")) == id:
				return (row as Dictionary).duplicate(true)
	return {}


func _find_label_containing(root: Node, needle: String) -> String:
	if root == null:
		return ""
	if root is Label and str((root as Label).text).contains(needle):
		return str((root as Label).text)
	for c in root.get_children():
		var hit := _find_label_containing(c, needle)
		if not hit.is_empty():
			return hit
	return ""


func _find_label_named(root: Node, want: String) -> String:
	if root == null:
		return ""
	if root is Label and str(root.name) == want:
		return str((root as Label).text)
	for c in root.get_children():
		var hit := _find_label_named(c, want)
		if not hit.is_empty():
			return hit
	return ""
