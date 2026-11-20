extends Node

# 背包布局门禁。
#
# 2026-11-20 背包改版：去掉宠物 / 头像，分成 全部 / 道具 / 体验卡 / 礼物 / 活动（BagScreen 文件头）。
# 原来这里钉的是宠物页的三处老问题（立绘越界、宠物栏被顶出屏幕、重影），宠物页没了，
# 改成钉新背包的几何与交互（文件名 / 门禁 id 保留，免得跑门禁的脚本找不到它）：
#
#   A 页签、左侧格子面板、右侧详情面板都完整落在屏幕内
#   B 格子不横向溢出左侧面板（窄屏少放几列，不把整页撑宽）
#   C 「使用」「出售」两颗按钮在详情面板里、可见
#   D 点选格子**不重建**格子（10.08 反馈第 6 条：重建会让安卓的模拟鼠标点到最后一个）
#   E 目标已永久拥有的卡，「使用」按钮禁用
#   F 道具 / 礼物 / 活动三页是空页，显示空提示、没有格子
#
# 几何判据，与渲染无关（headless 即可）。尺寸三种：常见 16:9 / 1024×600 / 960×540。

const H := preload("res://tools/CheckHarness.gd")
const BAG := preload("res://scenes/menu/BagScreen.gd")

const SIZES := [Vector2i(1280, 720), Vector2i(1024, 600), Vector2i(960, 540)]
const EPS := 0.5
const FIXTURE := {
	"cards": [
		{"target": "dark", "kind": "race", "days": 1, "count": 1, "sell_price": 100, "owned": false},
		{"target": "dark", "kind": "race", "days": 3, "count": 2, "sell_price": 200, "owned": false},
		{"target": "god", "kind": "race", "days": 7, "count": 1, "sell_price": 300, "owned": false},
		{"target": "undead", "kind": "race", "days": 1, "count": 4, "sell_price": 100, "owned": false},
		{"target": "pet_tiger", "kind": "pet", "days": 3, "count": 1, "sell_price": 200, "owned": false},
		{"target": "pet_squirrel", "kind": "pet", "days": 7, "count": 1, "sell_price": 300, "owned": false},
		{"target": "prep_skin_sakura", "kind": "prep_skin", "days": 1, "count": 1, "sell_price": 100, "owned": true},
		{"target": "prep_skin_nightwisp", "kind": "prep_skin", "days": 7, "count": 3, "sell_price": 300, "owned": false},
		{"target": "crimson", "kind": "race", "days": 3, "count": 1, "sell_price": 200, "owned": false},
	],
	"trials": [{"target": "dark", "kind": "race", "expires_at": "2099-01-01T00:00:00Z"}],
	"server_now": "2026-11-20T10:00:00Z",
}

var h


func _ready() -> void:
	h = H.new("bag_pet_layout")
	var previous_locale := LocaleManager.get_locale()
	for locale in ["zh", "en"]:
		LocaleManager.set_locale(locale)
		for size in SIZES:
			await _check_size(size)
	LocaleManager.set_locale(previous_locale)
	h.finish(get_tree())


func _check_size(size: Vector2i) -> void:
	# 用固定尺寸的壳子把屏幕撑到目标大小：根视口在 headless 里不一定能被改尺寸。
	var shell := Control.new()
	shell.custom_minimum_size = Vector2(size)
	shell.size = Vector2(size)
	add_child(shell)
	var bag: Control = BAG.new()
	bag.set_meta("ui_capture_fixture", FIXTURE)
	bag.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shell.add_child(bag)
	await _settle()
	var label := "%s@%s" % [LocaleManager.get_locale(), str(size)]
	var screen := shell.get_global_rect()

	var tabs := bag.find_child("BagTabs", true, false) as Control
	var collection := bag.find_child("BagCollection", true, false) as Control
	var detail_panel := bag.find_child("BagDetailPanel", true, false) as Control
	var grid := bag.find_child("BagGrid", true, false) as GridContainer
	h.expect(tabs != null and collection != null and detail_panel != null and grid != null,
		"nodes_present", "%s 背包的关键节点应存在" % label)
	if tabs == null or collection == null or detail_panel == null or grid == null:
		shell.queue_free()
		return

	# A 三块都在屏幕里
	for pair in [["tabs", tabs], ["collection", collection], ["detail", detail_panel]]:
		var rect := (pair[1] as Control).get_global_rect()
		h.item()
		h.expect(rect.position.x >= screen.position.x - EPS and rect.end.x <= screen.end.x + EPS
				and rect.position.y >= screen.position.y - EPS and rect.end.y <= screen.end.y + EPS,
			"inside_screen", "%s %s 越出屏幕：%s screen=%s" % [label, pair[0], str(rect), str(screen)])
	h.item()
	h.expect(tabs.get_child_count() == 5, "five_tabs", "%s 应有 5 个页签，实际 %d" % [label, tabs.get_child_count()])

	# B 格子不横向溢出左侧面板
	h.item()
	h.expect(grid.get_child_count() == FIXTURE["cards"].size(), "all_cards_shown",
		"%s 「全部」应显示 %d 张卡，实际 %d" % [label, FIXTURE["cards"].size(), grid.get_child_count()])
	var panel_rect := collection.get_global_rect()
	for tile in grid.get_children():
		var tr := (tile as Control).get_global_rect()
		h.item()
		h.expect(tr.end.x <= panel_rect.end.x + EPS and tr.position.x >= panel_rect.position.x - EPS,
			"tile_inside_panel", "%s 格子越出左侧面板：tile=%s panel=%s" % [label, str(tr), str(panel_rect)])

	# C 使用 / 出售按钮在详情面板里
	_check_buttons(bag, detail_panel, label, false)

	# D 点选不重建格子；E 已拥有的卡「使用」禁用
	var before: Array[int] = []
	for tile in grid.get_children():
		before.append(tile.get_instance_id())
	var owned_index := -1
	for i in FIXTURE["cards"].size():
		if bool(FIXTURE["cards"][i]["owned"]):
			owned_index = i
	var cards: Array = bag.get("_cards")
	for i in cards.size():
		var card: Dictionary = cards[i]
		bag.call("_on_tile_input", _click(), "%s|%d" % [card["target"], int(card["days"])])
		await _settle()
		_check_buttons(bag, detail_panel, "%s/%s-%dd" % [label, card["target"], int(card["days"])],
			bool(card["owned"]))
	var after: Array[int] = []
	for tile in grid.get_children():
		after.append(tile.get_instance_id())
	h.item()
	h.expect(before == after, "select_does_not_rebuild",
		"%s 点选格子后格子被重建了（安卓会点错格子，见 BagScreen 文件头）" % label)
	h.item()
	h.expect(owned_index >= 0, "fixture_has_owned", "夹具里应有一张已拥有目标的卡")

	# F 空页
	for tab_id in ["items", "gifts", "events"]:
		bag.call("_select_tab", tab_id)
		await _settle()
		var empty := bag.find_child("BagEmpty", true, false) as Label
		h.item()
		h.expect(grid.get_child_count() == 0 and empty != null and empty.visible and not empty.text.is_empty(),
			"empty_tab", "%s 「%s」页应是空页并显示提示" % [label, tab_id])
	bag.call("_select_tab", "trials")
	await _settle()
	h.item()
	h.expect(grid.get_child_count() == FIXTURE["cards"].size(), "trial_tab_lists_cards",
		"%s 「体验卡」页应列出全部体验卡" % label)
	shell.queue_free()


func _check_buttons(bag: Control, panel: Control, label: String, owned: bool) -> void:
	var use := bag.find_child("BagUse", true, false) as Button
	var sell := bag.find_child("BagSell", true, false) as Button
	h.item()
	h.expect(use != null and sell != null and use.is_visible_in_tree() and sell.is_visible_in_tree(),
		"buttons_present", "%s 详情里应有「使用」「出售」" % label)
	if use == null or sell == null:
		return
	var pr := panel.get_global_rect()
	h.item()
	h.expect(pr.encloses(use.get_global_rect()) and pr.encloses(sell.get_global_rect()),
		"buttons_inside_panel", "%s 按钮越出详情面板：use=%s sell=%s panel=%s" % [
			label, str(use.get_global_rect()), str(sell.get_global_rect()), str(pr)])
	h.item()
	h.expect(use.disabled == owned and not sell.disabled, "use_disabled_when_owned",
		"%s 「使用」应%s" % [label, "禁用（目标已永久拥有）" if owned else "可点"])


func _click() -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	return event


# 容器布局要几帧才收敛（宠物立绘是 3D 预览回退时还要等 SubViewport 建好）。
func _settle() -> void:
	for _i in 6:
		await get_tree().process_frame
