extends Node
# ============================================================================
# 本地化「防复发」门禁（10.16 第 2 条之后的新基建）
#
# 【它要防的是什么】同一个坑已经复发三次：prep_1008 修过「统计行 / 上阵头像 /
#   宝物名」三处直读中文 `name`，10.16 又是七处。既有门禁
#   `tools/prep_1008_check.gd` 的 `bug1_no_bare_chinese_literals` 只管**中文字面量**，
#   管不到「直读数据表 name 字段」和「把贴图名当显示名」。所以这里换一条路：
#   **不检查代码怎么写，只检查最终画面上有没有汉字** —— 新增任何显示路径都逃不掉。
#
# 【四段】
#   ① CJK 检测器自测：认得汉字，不误伤全角标点 / 拉丁字母
#   ② 玩家文本豁免自测（★ 这一段的判据是核心）：
#        昵称、聊天正文、邮件理由…… 这些地方出现中文是**对的**。
#        判据分三道：控件类型（可编辑控件的 text 不扫）/ 节点路径关键词 /
#        把已知玩家文本从字符串里挖掉后再看剩下有没有汉字。
#        第 ③ 道最要紧：它让「英文行里嵌了玩家的中文昵称」不误报，
#        同时「同一行里另有漏掉的中文名」照样被抓。
#   ③ 数据双语断言：11 张表 237 条，`name` 与 `name_en` 必须双非空
#        （新增一条数据忘填 name_en ⇒ 红）
#   ④ 真界面巡检（中 / 英各一轮）：实例化萝卜营地面板、四星出售确认框、
#        联动详情浮层，然后扫整棵树的可见文本。
#        中文轮断言「确实扫到了汉字」（证明界面真的建出来了、不是空转），
#        英文轮断言「一个汉字都没有」。
#
# 【跑法】
#   Godot_v4.7.2-stable_win64_console.exe --headless --path <工程根> \
#       _qa_1016/locale_guard_check.tscn
#   退出码 0 = PASS，1 = FAIL。

const CheckHarness := preload("res://_qa_1016/CheckHarness.gd")
const LocaleTextAudit := preload("res://_qa_1016/LocaleTextAudit.gd")
const CarrotCampPanelV3 := preload("res://scenes/prep/CarrotCampPanelV3.gd")
const PrepBoardController := preload("res://scenes/prep/PrepBoardController.gd")
const PrepWidgets := preload("res://scenes/prep/PrepWidgets.gd")

const CHECK_NAME := "locale_guard"
const UNIT_ID := "god_priest"
const LINK_ID := "link_phoenix"

# 11 张「进 UI 显示」的数据表。新增表要登记在这里，否则新增的漏填盯不住。
const DATA_FILES := [
	"res://data/avatars.json",
	"res://data/boss/bosses.json",
	"res://data/codex/treasure_text.json",
	"res://data/formation/formation_allies.json",
	"res://data/mercenary/mercenaries.json",
	"res://data/pets/pets.json",
	"res://data/prep_skins.json",
	"res://data/pve/pve_monsters.json",
	"res://data/shop.json",
	"res://data/treasure/treasures.json",
	"res://data/units/race_units.json",
]

var _h: CheckHarness
var _def := {}
var _row_count := 0
var _missing_en: Array[String] = []


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()
	_def = _unit_by_id(UNIT_ID)
	_selftest_detector()
	_selftest_exemptions()
	_data_bilingual()
	await _surface_round("zh", false)
	await _surface_round("en", true)
	LocaleManager.set_locale("zh")
	GameState.reset_run()
	_h.expect(_h.checked_count() >= 20, "too_few_assertions",
		"整份门禁只量到 %d 条断言，等于没验" % _h.checked_count())
	_h.finish(get_tree())


# ---- ① 检测器自测 ------------------------------------------------------------

func _selftest_detector() -> void:
	_h.expect(LocaleTextAudit.has_cjk("凤凰涅槃"), "detector_miss_cjk", "没认出汉字「凤凰涅槃」")
	_h.expect(LocaleTextAudit.has_cjk("神侍"), "detector_miss_cjk2", "没认出汉字「神侍」")
	_h.expect(not LocaleTextAudit.has_cjk("Phoenix Rebirth"), "detector_false_positive_latin",
		"把纯拉丁文本误判成含汉字")
	# 全角标点属于 Fullwidth Forms，不是汉字 —— 英文界面的 `：` 不该被报。
	_h.expect(not LocaleTextAudit.has_cjk("Treasures: Wall Resonance + Soul Counter"),
		"detector_false_positive_punct", "把英文行误判成含汉字")
	_h.expect(not LocaleTextAudit.has_cjk("4 Defense · Shell Guard"),
		"detector_false_positive_interpunct", "把含间隔号的英文行误判成含汉字")


# ---- ② 玩家文本豁免自测（核心）-----------------------------------------------

func _selftest_exemptions() -> void:
	var host := Node.new()
	host.name = "ExemptSelftest"
	add_child(host)
	var nick := "老王"

	# (a) 昵称嵌在英文行里 ⇒ 挖掉后没有汉字 ⇒ 不该报
	var inline_name := Label.new()
	inline_name.name = "UnitRowName"
	inline_name.text = "Shell Guard · %s" % nick
	host.add_child(inline_name)
	var hits := LocaleTextAudit.audit(host, [nick])
	_h.expect(not _has_path(hits, "UnitRowName"), "exempt_inline_nickname_reported",
		"英文行里嵌了玩家昵称「%s」被误报：%s" % [nick, LocaleTextAudit.format_hits(hits)])

	# (b) ☆ 同一行里再嵌一个**真漏点** ⇒ 挖掉昵称后还剩汉字 ⇒ 必须报
	var mixed := Label.new()
	mixed.name = "UnitRowMixed"
	mixed.text = "Shell Guard · %s · 甲壳守卫" % nick
	host.add_child(mixed)
	hits = LocaleTextAudit.audit(host, [nick])
	_h.expect(_has_path(hits, "UnitRowMixed"), "exempt_residual_cjk_missed",
		"挖掉昵称后剩下的汉字（真漏点）没被抓出来：%s" % LocaleTextAudit.format_hits(hits))

	# (c) 路径命中玩家文本关键词 ⇒ 整条豁免（聊天正文里当然有中文）
	var chat := Label.new()
	chat.name = "ChatMessageBody"
	chat.text = "%s：今晚打不打" % nick
	host.add_child(chat)
	hits = LocaleTextAudit.audit(host, [])
	_h.expect(not _has_path(hits, "ChatMessageBody"), "exempt_chat_node_reported",
		"聊天正文节点被误报：%s" % LocaleTextAudit.format_hits(hits))

	# (d) 昵称节点整条豁免
	var nick_node := Label.new()
	nick_node.name = "PlayerNicknameLabel"
	nick_node.text = nick
	host.add_child(nick_node)
	hits = LocaleTextAudit.audit(host, [])
	_h.expect(not _has_path(hits, "PlayerNicknameLabel"), "exempt_nickname_node_reported",
		"昵称节点被误报：%s" % LocaleTextAudit.format_hits(hits))

	# (e) 可编辑控件的 text 是玩家输入 ⇒ 不扫；它自己的 placeholder 是开发文案 ⇒ 要扫
	var query := LineEdit.new()
	query.name = "QueryBox"
	query.text = "玩家手打的中文"
	query.placeholder_text = "输入名字"
	host.add_child(query)
	hits = LocaleTextAudit.audit(host, [])
	_h.expect(not _has_text(hits, "玩家手打的中文"), "exempt_editable_text_reported",
		"输入框里玩家手打的内容被误报：%s" % LocaleTextAudit.format_hits(hits))
	_h.expect(_has_text(hits, "输入名字"), "editable_placeholder_missed",
		"输入框的 placeholder（开发写的文案）漏检了：%s" % LocaleTextAudit.format_hits(hits))

	host.queue_free()


# ---- ③ 数据双语断言 ----------------------------------------------------------

func _data_bilingual() -> void:
	for path in DATA_FILES:
		if not FileAccess.file_exists(path):
			_h.fail("data_missing", "数据表不存在：%s —— 表被挪走/改名时这条门禁必须红" % path)
			continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed == null:
			_h.fail("data_unreadable", "数据表解析失败：%s" % path)
			continue
		_collect_rows(parsed, path)
	_h.expect(_row_count >= 200, "data_rows_too_few",
		"只扫到 %d 条带 name 的条目（应 >= 200）—— 多半是表结构变了，这条断言要重看" % _row_count)
	_h.expect(_missing_en.is_empty(), "data_name_en_missing",
		"%d/%d 条缺 name_en：%s" % [_missing_en.size(), _row_count, ", ".join(_missing_en.slice(0, 10))])


func _collect_rows(node: Variant, path: String) -> void:
	if node is Dictionary:
		var d := node as Dictionary
		if d.has("name"):
			_row_count += 1
			if str(d.get("name_en", "")).strip_edges().is_empty():
				_missing_en.append("%s:%s" % [path.get_file(), str(d.get("id", d.get("name", "?")))])
		for key in d:
			_collect_rows(d[key], path)
	elif node is Array:
		for item in (node as Array):
			_collect_rows(item, path)


# ---- ④ 真界面巡检（中 / 英各一轮）--------------------------------------------

func _surface_round(locale: String, expect_clean: bool) -> void:
	LocaleManager.set_locale(locale)
	if not _def.is_empty():
		GameState.reset_run()
		GameState.board_slots[0] = {"def": _def.duplicate(true), "star": 3, "uid": "guard_3"}
		GameState.board_slots[1] = {"def": _def.duplicate(true), "star": 4, "uid": "guard_4"}

	var host := Node.new()
	host.name = "AuditHost_" + locale
	add_child(host)

	# 1) 萝卜营地 · 升级石页 · 四星候选行
	var panel := CarrotCampPanelV3.new()
	host.add_child(panel)
	panel.setup(Callable(), Callable(), Callable())
	if panel.has_method("refresh"):
		panel.call("refresh")

	# 2) 卖掉四星的二次确认框（真对话框）
	var ctrl := PrepBoardController.new()
	host.add_child(ctrl)
	ctrl.call("_ask_four_star_sell", "board", 1, GameState.board_slots[1])
	await get_tree().process_frame
	await get_tree().process_frame

	# 3) 联动详情浮层（真跑 _show_linkage_detail）
	var pop := PopupPanel.new()
	host.add_child(pop)
	var detail := RichTextLabel.new()
	pop.add_child(detail)
	var overlay: Variant = ctrl.get("_overlay")
	if overlay != null:
		overlay.call("bind", pop, detail)
		ctrl.call("_show_linkage_detail", LINK_ID)
	await get_tree().process_frame

	# 扫整棵树：门禁自己 + autoload 都不含中文，命中即为被测界面。
	var hits := LocaleTextAudit.audit(get_tree().root, [])
	if expect_clean:
		_h.expect(hits.is_empty(), "en_surface_has_chinese",
			"英文界面下仍有 %d 处汉字：\n%s" % [hits.size(), LocaleTextAudit.format_hits(hits)])
	else:
		_h.expect(not hits.is_empty(), "zh_surface_no_chinese",
			"中文界面下一处汉字都没扫到 —— 说明界面根本没建出来，这一轮的英文断言等于空转")
		_h.item(hits.size())

	ModalStack.close_all()
	host.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


# ---- 小工具 ------------------------------------------------------------------

func _has_path(hits: Array, needle: String) -> bool:
	for h in hits:
		if str(h.get("path", "")).contains(needle):
			return true
	return false


func _has_text(hits: Array, needle: String) -> bool:
	for h in hits:
		if str(h.get("text", "")).contains(needle):
			return true
	return false


func _unit_by_id(id: String) -> Dictionary:
	for table_key in ["race_units", "mercenaries"]:
		var row_key := "units" if table_key == "race_units" else "mercenaries"
		for row in DataRegistry.get_table(table_key).get(row_key, []):
			if row is Dictionary and str((row as Dictionary).get("id", "")) == id:
				return (row as Dictionary).duplicate(true)
	return {}
