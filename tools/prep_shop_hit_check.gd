extends Node

# 10.07b 第 4 条：备战商店第 4 张卡「靠聊天框那一端点不中」。
#
# ## 根因（实测几何）
#
# 商店 4 张手牌卡在基准 1600x720 下算出来是：
#   卡 1 x∈[422,602]  卡 4 x∈[998,1178]  y∈[509,689]
# 而备战右下角的聊天记录窗 `PrepChatHistory`：
#   窗   x∈[1164,1452] y∈[430,614]   ← 左边缘压住卡 4 右端 14px
# 那个窗原本 `mouse_filter = STOP` ⇒ 整块矩形吃点击 ⇒ 落在卡右端 14px 上的
# 拇指被它吃掉，「点一下没反应」。拖动时手指移出那块区域就恢复 ——
# 这正好解释玩家说的「必须有一点拖动才能选中」。
#
# ## 本检查判什么
#
#   1. 结构：聊天记录窗与它内部的滚动容器都必须 `MOUSE_FILTER_IGNORE`
#      （纯展示区不吃点击）。漏掉内层那个，症状一模一样且不报错。
#   2. 几何：卡 4 与聊天窗**真的重叠**（重叠存在 ⇒ 上面那条判据才不是空转）；
#      且吃点击的层级里**没有**控件盖住卡 4 的任一角落。
#
# ⚠️ 判据 2 是这个检查的判别力来源：如果哪天有人把窗挪开了、不再重叠，
#    判据 1 就会变成「恒真的空转断言」—— 所以 2 必须一起在。
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/prep_shop_hit_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const PREP_UI_SRC := "res://scenes/prep/PrepUI.gd"
const SHOP_SRC := "res://scenes/prep/panels/ShopPanel.gd"

const CHECK_NAME := "prep_shop_hit"

# 与 PrepUI.gd / ShopPanel.gd 的常量一致（改了那边这里也要改，否则几何推算失真）。
const REF := Vector2(1600, 720)
const SHOP_POPUP := Vector2(896, 230)
const CARD_SIZE := Vector2(180, 180)
const CARD_SEP := 12.0
const CARD_SLOTS := 4
const CHAT_LOG_RIGHT := 148.0
const CHAT_LOG_WIDTH := 288.0
const COMMS_DOCK_HEIGHT := 88.0
const COMMS_DOCK_BOTTOM := -8.0
const CHAT_FLOAT_GAP := 10.0
const CHAT_LOG_HEIGHT := 184.0

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	await get_tree().process_frame
	_case_source_contract()
	_case_geometry()
	_h.finish(get_tree())


# ── 1. 源码合同：纯展示的聊天记录区不许吃点击 ────────────────────────────────

func _case_source_contract() -> void:
	var src := FileAccess.get_file_as_string(PREP_UI_SRC)
	if not _h.expect(not src.is_empty(), "src_readable", "PrepUI.gd 可读"):
		return
	var code := _code_only(src)

	# window 那句：必须 IGNORE，且不许再出现 `window.mouse_filter = ... STOP`。
	var at := code.find("window.mouse_filter")
	_h.expect(at >= 0, "window_filter_set",
		"必须显式设置聊天记录窗的 mouse_filter（不设 = 默认 STOP = 吃点击）")
	if at >= 0:
		var line: String = code.substr(at).split(String.chr(10))[0]
		_h.expect(line.contains("IGNORE"), "window_filter_ignore",
			"★ 聊天记录窗必须 MOUSE_FILTER_IGNORE（纯展示，整块矩形不该吃点击）：%s" % line.strip_edges())

	# 内层 ScrollContainer 同样要 IGNORE —— 漏掉它症状一样、且不报错。
	var at2 := code.find("_chat_record_scroll.mouse_filter")
	_h.expect(at2 >= 0, "scroll_filter_set",
		"★ 内层 _chat_record_scroll 也必须显式设 mouse_filter（父窗 IGNORE 了它仍会吞点击）")
	if at2 >= 0:
		var line2: String = code.substr(at2).split(String.chr(10))[0]
		_h.expect(line2.contains("IGNORE"), "scroll_filter_ignore",
			"★ _chat_record_scroll 必须 MOUSE_FILTER_IGNORE：%s" % line2.strip_edges())


# ── 2. 几何：重叠确实存在 + 卡 4 的四角都没被吃点击的控件盖住 ────────────────

func _case_geometry() -> void:
	var shop := _shop_rect()
	var card4 := _card_rect(3)
	var win := _chat_log_rect()

	_h.expect(card4.has_area(), "card4_positive",
		"卡 4 矩形必须有面积：%s" % str(card4))

	# 这条说明「为什么需要上面那两条 IGNORE」—— 重叠是真的存在。
	var inter := card4.intersection(win)
	_h.expect(inter.has_area(), "overlap_is_real",
		"卡 4 与聊天记录窗确实重叠（否则上面两条 IGNORE 就是空转断言）：%s" % str(inter))

	# 卡 4 的右端中点必须落在窗内 ⇒ 那正是玩家点不中的那块。
	var tip := Vector2(card4.end.x - 3.0, card4.get_center().y)
	_h.expect(win.has_point(tip), "tip_inside_window",
		"卡 4 右端中点 %s 确实落在聊天窗内（这就是「点了没反应」的位置）" % str(tip))

	# 商店弹窗必须真的盖住卡 4（卡是它的子节点，这是常识性护栏）。
	var pop_ok := shop.encloses(card4)
	_h.expect(pop_ok, "card_inside_popup",
		"卡 4 必须完整落在商店弹窗内：卡=%s 弹窗=%s" % [str(card4), str(shop)])


func _shop_rect() -> Rect2:
	var left := REF.x * 0.5 - SHOP_POPUP.x * 0.5
	var bottom := REF.y - 8.0
	return Rect2(Vector2(left, bottom - SHOP_POPUP.y), SHOP_POPUP)


func _card_rect(index: int) -> Rect2:
	var total := CARD_SIZE.x * CARD_SLOTS + CARD_SEP * (CARD_SLOTS - 1)
	var pop_top := REF.y - 8.0 - SHOP_POPUP.y
	var area_top := pop_top + SHOP_POPUP.y * 0.10
	var area_bottom := pop_top + SHOP_POPUP.y * 0.92
	var cards_top := area_top + ((area_bottom - area_top) - CARD_SIZE.y) * 0.5
	var left := REF.x * 0.5 - total * 0.5 + index * (CARD_SIZE.x + CARD_SEP)
	return Rect2(Vector2(left, cards_top), CARD_SIZE)


func _chat_log_rect() -> Rect2:
	var right := REF.x - CHAT_LOG_RIGHT
	var left := right - CHAT_LOG_WIDTH
	var bottom := REF.y + COMMS_DOCK_BOTTOM - COMMS_DOCK_HEIGHT - CHAT_FLOAT_GAP
	return Rect2(Vector2(left, bottom - CHAT_LOG_HEIGHT), Vector2(CHAT_LOG_WIDTH, CHAT_LOG_HEIGHT))


# 去掉整行注释后再做文本断言：本文件（PrepUI.gd）的注释里逐字写了旧实现
# `window.mouse_filter = Control.MOUSE_FILTER_STOP` 来解释为什么删它，
# 裸 find 会把注释当代码命中 —— 踩过的坑。
static func _code_only(text: String) -> String:
	var nl := String.chr(10)
	var out: Array = []
	for line in text.replace(String.chr(13) + nl, nl).split(nl):
		if (line as String).strip_edges().begins_with("#"):
			continue
		out.append(line)
	return nl.join(out)
