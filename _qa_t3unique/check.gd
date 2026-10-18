extends Node
# ============================================================================
# T3 = 唯一棋子：契约门禁（10.15 bug 文档第 1 条）
#
# 【现场】
# 10.15 反馈原文：「增加设定：T3棋子=唯一棋子。目前发现穿云弩手为T3棋子但非唯一
# 棋子（没有唯一标识，上阵可以上两只）。现在进行设定，T3棋子均为唯一棋子，
# 名字增加相对应"（唯一）"标识，上阵最多只能一只。」
#
# 核查结论：**这不是「唯一机制没做」，而是逐枚手写的标记漏了一枚。**
# `data/units/race_units.json` 里 8 枚 tier==3 棋子，其中 7 枚早就带
# `unique_on_board`，只有 `skypierce`（穿云弩手）漏了。所以修复 = 补这一个字段，
# 其余全部由既有机制自动生效（见下）。
#
# 【既有机制，一处都不用新写】
#   * 数据真相：def 上的 `unique_on_board`（唯一的一条真相）
#   * 备战拦截：`PrepRules.has_unique_board_unit()` / `board_limit_for_def()`
#     —— 四个搬运 handler + 商店拖入 + 点击购买分流都过它
#   * 文案：`UnitDetailFormat.unique_suffix()` → 「名称 N星（唯一）」
#     详情卡（商店长按/格子长按）与图鉴详情共用这一份
#   * AI 与模拟器：`BotPlayer._roll_shop` / `BattleSimulator._is_unique_fighter`
#
# 【本门禁要钉住什么】
# 用户写的是等号 ——「T3棋子=唯一棋子」。当前表里 `tier==3` 与
# `unique_on_board==true` 恰好是同一个集合（互查为空），所以双向都断言：
# 以后再加一枚 T3 却忘了写字段、或者悄悄冒出一个非 T3 的唯一棋子，都会判红。
# 另加一条**变异对照**（擦掉字段后判据必须变假），防止有人把判据写成硬编码 true。
#
# 【运行】
#   Godot_v4.7.2-stable_win64_console.exe --headless --path <工程根> \
#        res://_qa_t3unique/check.tscn
# 退出码 0 = 全绿，非 0 = 有 FAIL。本目录只做门禁与留档，不进构建内容。
# ============================================================================

const PrepRules := preload("res://scenes/prep/PrepRules.gd")
const ShopRoll := preload("res://scripts/economy/ShopRoll.gd")
const UnitDetailFormat := preload("res://scripts/ui/UnitDetailFormat.gd")

const TAG := "[T3UNIQ]"
# 10.15 现场那一枚（穿云弩手）。单独点名断言，避免「整体统计碰巧通过」。
const REPORTED_UNIT := "skypierce"
# 用户口径里的标识。zh/en 各一份，与 UnitDetailFormat.unique_suffix() 同源。
const MARK_ZH := "（唯一）"
const MARK_EN := " (Unique)"
# 期望的 T3 数量（补上 skypierce 之后）。数量本身不是设计常量，
# 但它把「表被整体替换/截断」这类事故变成一条明确的红。
const EXPECTED_T3 := 8

var checks := 0
var failures := 0


func _check(ok: bool, description: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print(TAG, " ", "PASS " if ok else "FAIL ", description)


func _is_unique(d: Dictionary) -> bool:
	# 唯一真相的读法。全工程都长这样（PrepBoardController / PrepUI / BotPlayer /
	# BattleSimulator 都是 `bool(d.get("unique_on_board", false))`），
	# 门禁刻意用同一种写法，改语义时两边会一起动。
	return bool(d.get("unique_on_board", false))


func _ready() -> void:
	print(TAG, " ---- T3 = 唯一棋子 契约门禁 ----")
	var rows := _race_unit_rows()
	_check(rows.size() > 0, "race_units 表可读（%d 行）" % rows.size())

	var t3: Array = []
	var unique: Array = []
	for row in rows:
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = row
		if int(d.get("tier", 0)) == 3:
			t3.append(d)
		if _is_unique(d):
			unique.append(d)

	# --- A. 数据面：双向不变量 -------------------------------------------
	_check(t3.size() == EXPECTED_T3,
		"tier==3 的棋子应有 %d 枚，实际 %d 枚" % [EXPECTED_T3, t3.size()])

	var missing: Array = []
	for d in t3:
		if not _is_unique(d):
			missing.append("%s(%s)" % [str(d.get("name", "?")), str(d.get("id", "?"))])
	_check(missing.is_empty(),
		"每枚 tier==3 棋子都带 unique_on_board；缺写的：%s" % ("无" if missing.is_empty() else str(missing)))

	var not_t3: Array = []
	for d in unique:
		if int(d.get("tier", 0)) != 3:
			not_t3.append("%s(%s, tier=%d)" % [str(d.get("name", "?")), str(d.get("id", "?")), int(d.get("tier", 0))])
	_check(not_t3.is_empty(),
		"unique_on_board 的棋子都在 tier==3；越界的：%s" % ("无" if not_t3.is_empty() else str(not_t3)))

	# 现场那枚单独点名。
	var reported := _find_def(rows, REPORTED_UNIT)
	_check(not reported.is_empty(), "现场棋子 %s 存在于 race_units" % REPORTED_UNIT)
	_check(int(reported.get("tier", 0)) == 3 and _is_unique(reported),
		"现场棋子 %s（%s）是 tier==3 且带 unique_on_board" % [REPORTED_UNIT, str(reported.get("name", "?"))])

	# 变异对照：把字段擦掉，判据必须跟着变假。
	# 如果 _is_unique 被写成硬编码 true，这一条会红。
	var erased := reported.duplicate(true)
	erased.erase("unique_on_board")
	_check(_is_unique(reported) and not _is_unique(erased),
		"变异对照：擦掉 unique_on_board 后判定必须由真变假（证明判据真的读了字段）")

	# --- B. 文案面：「（唯一）」标识 --------------------------------------
	var original_locale := LocaleManager.get_locale()
	LocaleManager.set_locale("zh")
	var mark_zh := UnitDetailFormat.unique_suffix(reported)
	var detail_zh := UnitDetailFormat.format_unit_def(reported, 1)
	LocaleManager.set_locale("en")
	var mark_en := UnitDetailFormat.unique_suffix(reported)
	var detail_en := UnitDetailFormat.format_unit_def(reported, 1)
	LocaleManager.set_locale(original_locale)

	_check(mark_zh == MARK_ZH, "中文标识后缀 == \"%s\"，实际 \"%s\"" % [MARK_ZH, mark_zh])
	_check(mark_en == MARK_EN, "英文标识后缀 == \"%s\"，实际 \"%s\"" % [MARK_EN, mark_en])
	# 详情卡是玩家唯一看得到那一份（10.15 现场三张图全是详情卡的局部），
	# 所以判据落在**渲染结果**上，而不是只判字段。
	var want_zh := "%s 1星%s" % [str(reported.get("name", "?")), MARK_ZH]
	var want_en := "%s ★1%s" % [str(reported.get("name_en", "?")), MARK_EN]
	_check(detail_zh.contains(want_zh),
		"详情卡中文含 \"%s\"" % want_zh)
	_check(detail_en.contains(want_en),
		"详情卡英文含 \"%s\"" % want_en)

	# 反向控制：非唯一棋子不能被写上标识（防「一律返回（唯一）」的变异）。
	var plain := _first_row_with_tier(rows, 2)
	_check(not plain.is_empty(), "找到一枚 tier==2 的非唯一棋子做反向控制")
	_check(not _is_unique(plain) and UnitDetailFormat.unique_suffix(plain).is_empty(),
		"反向控制：非唯一棋子 %s 无标识且 unique_suffix 为空" % str(plain.get("id", "?")))

	# --- C. 拦截面：「上阵最多只能一只」 ---------------------------------
	_check(PrepRules.board_limit_for_def(reported) == 1,
		"%s 的上场上限 == 1（实际 %d）" % [REPORTED_UNIT, PrepRules.board_limit_for_def(reported)])

	var gate_ok := _board_gate_contract(reported)
	_check(gate_ok,
		"棋盘拦截（开关 ∧ 同名计数）：空场放行 / 已有 1 枚时第二枚被挡 / 同格移动放行（%s）" % REPORTED_UNIT)

	# 8 枚唯一棋子逐一过同一条契约 —— 保证规则对所有 T3 一致，不是只修了现场那枚。
	var gate_bad: Array = []
	for d in unique:
		if not _board_gate_contract(d):
			gate_bad.append(str(d.get("id", "?")))
	_check(gate_bad.is_empty(),
		"全部 %d 枚唯一棋子都满足同一条棋盘拦截契约（开关 ∧ 计数）；不满足的：%s" % [unique.size(), "无" if gate_bad.is_empty() else str(gate_bad)])

	# --- D. 商店/详情路径：标记能真的流到玩家眼前 -------------------------
	# 商店 offer 是**整行**复制（ShopRoll.pick_offer -> duplicate(true)），
	# 详情卡直接用 offer 渲染。这里走一遍真实摇店函数，证明字段没在中途被裁掉。
	# tier_roll=0.99 & round>=15 -> 三档；pick_roll=0.0 -> 池里第一枚。
	var offer: Dictionary = ShopRoll.pick_offer([reported], 20, 0.99, 0.0)
	_check(_is_unique(offer),
		"商店摇出的 offer 仍带 unique_on_board（详情卡才看得到标识）")
	_check(int(offer.get("tier", 0)) == 3 and int(offer.get("cost", 0)) == int(reported.get("cost", -1)),
		"该 offer 是整行（tier=%d, cost=%d），不是被裁过的副本" % [int(offer.get("tier", 0)), int(offer.get("cost", 0))])

	print(TAG, " ---- 合计 %d 项 / 失败 %d 项 ----" % [checks, failures])
	if failures == 0:
		print(TAG, " RESULT ALL PASS")
	else:
		print(TAG, " RESULT FAILED")
	get_tree().quit(1 if failures > 0 else 0)


func _race_unit_rows() -> Array:
	var table: Variant = DataRegistry.get_table("race_units")
	if typeof(table) != TYPE_DICTIONARY:
		return []
	var rows: Variant = (table as Dictionary).get("units", [])
	return rows as Array if typeof(rows) == TYPE_ARRAY else []


func _find_def(rows: Array, unit_id: String) -> Dictionary:
	for row in rows:
		if typeof(row) == TYPE_DICTIONARY and str((row as Dictionary).get("id", "")) == unit_id:
			return row as Dictionary
	return {}


func _first_row_with_tier(rows: Array, tier: int) -> Dictionary:
	for row in rows:
		if typeof(row) == TYPE_DICTIONARY \
				and int((row as Dictionary).get("tier", 0)) == tier \
				and not bool((row as Dictionary).get("unique_on_board", false)):
			return row as Dictionary
	return {}


# 「上阵最多只能一只」的判定，必须**逐字复刻真实调用点**：
#   PrepBoardController:497 / :641(_would_exceed_board_limit) / :740 / :764
#   PrepUI.gd:3799  全部长这样 ——
#       bool(def.get("unique_on_board", false)) and PrepRules.has_unique_board_unit(...)
# 两项相与，缺一不可：
#   * 少了开关那一半（只调 has_unique_board_unit）-> 单测「没写字段」的棋子照样拦得住，
#     于是本次这个 bug（字段漏写）**测不出来** —— 第一版就是踩了这个坑（变异态仍全绿）。
#   * 少了 has_unique_board_unit 那一半 -> 棋盘上有几枚都不拦。
# 三条契约：
#   1) 空场（棋盘上没有同名棋子）-> 不挡，可以上；
#   2) 棋盘第 0 格已经有 1 枚 -> 在别的格子再放一枚会被挡（这就是「只能一只」）；
#   3) 但把**那一枚自己**挪走/升星（ignore_index 指向它）不算超限，必须放行。
# 只判 2 会误伤「同一枚棋子换位置」，只判 3 就完全没拦住。
# board_slots 是 autoload 的活状态，这里改前备份、判完立刻还原。
func _board_gate_contract(d: Dictionary) -> bool:
	var unit_id := str(d.get("id", ""))
	if unit_id.is_empty():
		return false
	var flagged := bool(d.get("unique_on_board", false))
	var limit := PrepRules.board_limit_for_def(d)
	var saved: Array = GameState.board_slots.duplicate()
	if GameState.board_slots.size() < 2:
		GameState.board_slots.resize(2)
	GameState.board_slots.fill(null)
	var empty_ok := not (flagged and PrepRules.has_unique_board_unit(unit_id, limit))
	GameState.board_slots[0] = {"id": unit_id, "uid": "qa_t3uniq_0", "star": 1, "def": d}
	var second_blocked := flagged and PrepRules.has_unique_board_unit(unit_id, limit)
	var self_move_ok := not (flagged and PrepRules.has_unique_board_unit(unit_id, limit, 0))
	GameState.board_slots = saved
	return empty_ok and second_blocked and self_move_ok
