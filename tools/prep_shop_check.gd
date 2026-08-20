extends Node

# D2 的安全网之二：备战界面**商店 UI** 的行为用例。
#
# 为什么必须先有它，再动商店的拆分：
#   * `adversarial_client` 测的是服务端经济账本（`EconomyLedger.apply` 的 buy/refresh），
#     那是钱的权威裁决，**不是界面**
#   * `board_4x4_smoke` 里一个商店调用都没有
#   * `prep_tree_snapshot` 只能证明"构建出来的节点树一致"，证明不了"点击还能用"
# 也就是说，商店 UI 在这之前是**零覆盖**。把 19 个商店成员变量、644 行代码
# 抽成 ShopPanel，却只有构建快照兜底，那正是这套流程一直在反对的做法。
#
# 本检查驱动的是真实的私有方法（和 board_4x4_smoke 同一路数），
# 覆盖开关弹窗、选卡、售卖模式、刷新、购买理由判定这几条状态链。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/prep_shop_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")

const ShopPanelScript := preload("res://scenes/prep/panels/ShopPanel.gd")

const CHECK_NAME := "prep_shop"

var _h: CheckHarness
var _prep: Node


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "PrepScreen.tscn 无法加载"):
		_h.finish(get_tree())
		return
	_prep = packed.instantiate()
	add_child(_prep)
	await get_tree().process_frame
	await get_tree().process_frame

	_case_nodes_exist()
	_case_picker_toggle()
	_case_picker_close_idempotent()
	_case_sell_mode()
	_case_sell_drop_accepts_only_board_and_bench()
	_case_card_selection()
	_case_purchase_reason_bounds()
	_case_refresh_survives_empty_offers()

	_case_signals_wired()
	_case_card_selection_clears_board()

	_h.finish(get_tree())


# 取 PrepScreen 上的成员。不能叫 _get —— 与 Object._get(StringName) 撞名。
func _field(name: String) -> Variant:
	return _prep.get(name)


# 取商店簇的字段。D2 第三步后这 19 个成员搬进了 PrepShared.ShopPanel 内部类，
# 统一从 _prep._shop 上读。
func _shop_field(name: String) -> Variant:
	var shop: Variant = _prep.get("_shop")
	return null if shop == null else shop.get(name)


# 构建产物存在。这几个是后续拆分要搬走的核心节点，先钉住它们必须被建出来。
func _case_nodes_exist() -> void:
	for node_name in ["panel", "row", "open_button", "side_controls", "sell_overlay"]:
		_h.expect(_shop_field(node_name) != null, "shop_node_missing",
			"商店节点 _shop.%s 没有被构建出来" % node_name)
	var buttons: Variant = _shop_field("buttons")
	_h.expect(buttons is Array and (buttons as Array).size() == GameState.SHOP_UNIT_SLOTS,
		"shop_button_count",
		"商店卡位应有 %d 个，实际 %s" % [GameState.SHOP_UNIT_SLOTS, str(buttons)])


# 弹窗开关是纯状态翻转，且必须真的作用到 _shop_picker_open 上。
func _case_picker_toggle() -> void:
	_shop_panel().close_picker()
	_h.expect(not bool(_shop_field("picker_open")), "picker_not_closed", "初始应为关闭")
	_shop_panel().toggle_picker()
	_h.expect(bool(_shop_field("picker_open")), "toggle_open_failed", "toggle 后应打开")
	_shop_panel().toggle_picker()
	_h.expect(not bool(_shop_field("picker_open")), "toggle_close_failed", "再 toggle 应关闭")


# 关闭已关闭的弹窗必须是幂等的（实现里有提前 return）。
# 若哪天改成无条件执行，会重复触发 _refresh_shop_picker，
# 在弹窗动画/焦点上表现为闪一下，很难查。
func _case_picker_close_idempotent() -> void:
	_shop_panel().close_picker()
	var before := bool(_shop_field("picker_open"))
	_shop_panel().close_picker()
	_shop_panel().close_picker()
	_h.expect(bool(_shop_field("picker_open")) == before, "close_not_idempotent",
		"重复关闭改变了状态")


func _case_sell_mode() -> void:
	_prep.call("_set_shop_sell_mode", true)
	_h.expect(bool(_shop_field("drag_sell_mode")), "sell_mode_not_set", "售卖模式没有开启")
	var overlay: Variant = _shop_field("sell_overlay")
	if overlay != null:
		_h.expect(bool((overlay as CanvasItem).visible), "sell_overlay_hidden",
			"售卖模式开启时出售覆盖层应可见")
	_prep.call("_set_shop_sell_mode", false)
	_h.expect(not bool(_shop_field("drag_sell_mode")), "sell_mode_not_cleared", "售卖模式没有关闭")
	if overlay != null:
		_h.expect(not bool((overlay as CanvasItem).visible), "sell_overlay_visible",
			"售卖模式关闭时出售覆盖层应隐藏")


# 出售区只接受来自棋盘/待命区的拖拽。若放宽到商店卡，
# 会出现"把刚要买的卡拖进出售区"这种没有意义且可能扣钱的路径。
func _case_sell_drop_accepts_only_board_and_bench() -> void:
	_h.expect(bool(_prep.call("_can_drop_to_sell", {"kind": "board", "index": 0})),
		"sell_rejects_board", "出售区应接受棋盘单位")
	_h.expect(bool(_prep.call("_can_drop_to_sell", {"kind": "bench", "index": 0})),
		"sell_rejects_bench", "出售区应接受待命区单位")
	_h.expect(not bool(_prep.call("_can_drop_to_sell", {"kind": "shop", "index": 0})),
		"sell_accepts_shop", "出售区不该接受商店卡")
	_h.expect(not bool(_prep.call("_can_drop_to_sell", "not_a_dict")),
		"sell_accepts_garbage", "出售区不该接受非字典数据")


func _case_card_selection() -> void:
	_shop_panel()._on_card_selected(0)
	_h.expect(int(_shop_field("selected")) == 0, "select_failed",
		"点第 0 张卡后 _selected_shop 应为 0，实际 %d" % int(_shop_field("selected")))
	_shop_panel()._on_card_selected(1)
	_h.expect(int(_shop_field("selected")) == 1, "reselect_failed",
		"改点第 1 张卡后应为 1，实际 %d" % int(_shop_field("selected")))


# 越界索引必须给出"不能买"的理由而不是崩溃/空串。
func _case_purchase_reason_bounds() -> void:
	for bad in [-1, 999]:
		var reason: String = str(_shop_panel()._purchase_reason(bad))
		_h.expect(not reason.is_empty(), "reason_empty_on_bad_index",
			"索引 %d 应返回不可买的理由，实际空串" % bad)


# 商店位全空时刷新要正确清掉选中态（回合开始、卖光、教学模式都会出现空位）。
#
# 两处写法上的坑，记在这里免得下次再犯：
#  ① 空位必须填 `{}` 而不是留 `null`。GameState.reset_run() 是
#     `shop_offers.resize(N)` 之后逐个 `shop_offers[i] = {}`，
#     所以真实代码里永远不会出现 null。第一版用 resize() 造出 null，
#     结果 _refresh_shop 里 `.is_empty()` 打在 Nil 上报错 —— 那是**测试造了个
#     不可能的状态**，不是产品 bug。
#  ② 断言必须能失败。第一版写的是 `expect(true, ...)`，
#     于是脚本报了错、检查却显示 PASS —— 正是这套流程一直在消灭的假绿。
#     现在断言的是可观察的效果：选中态被清成 -1。
func _case_refresh_survives_empty_offers() -> void:
	var saved: Array = GameState.shop_offers.duplicate(true)
	var saved_sold: Array = GameState.shop_sold.duplicate(true)
	_shop_panel()._on_card_selected(0)          # 先选中一张，制造"选中态需要被清"的前提
	GameState.shop_offers.clear()
	GameState.shop_offers.resize(GameState.SHOP_UNIT_SLOTS)
	for i in GameState.SHOP_UNIT_SLOTS:
		GameState.shop_offers[i] = {}
	_shop_panel().refresh()
	_h.expect(int(_shop_field("selected")) == -1, "stale_selection_kept",
		"商店位全空后选中态应被清成 -1，实际 %d（会导致点购买时买到不存在的卡）"
			% int(_shop_field("selected")))
	GameState.shop_offers = saved
	GameState.shop_sold = saved_sold
	_shop_panel().refresh()


# 商店面板现在是独立节点。用 preload 常量做类型标注，让下面全是静态调用 ——
# 按名字调用会被 dynamic_call 的棘轮记账，而检查工具自己更不该制造那种调用。
func _shop_panel() -> ShopPanelScript:
	return _prep.get("_shop") as ShopPanelScript


# 商店面板通过**信号**与宿主通信（D2 步骤 3′b）。信号没接上的后果是静默的：
# 面板照常 emit，没人听，动作就是不发生 —— 不报错、不崩、界面看着正常。
#
# 这条用例是探针逼出来的：把 card_selected.connect(...) 那行注释掉，
# 这个检查原本 24 项照样全绿。只测「面板方法能调」证明不了「接线通了」。
func _case_signals_wired() -> void:
	var panel := _shop_panel()
	if not _h.expect(panel != null, "panel_missing", "取不到商店面板节点"):
		return
	for sig in ["card_selected", "buy_requested", "detail_requested",
			"picker_toggled", "refresh_requested", "message_requested", "state_changed"]:
		var conns: Array = panel.get_signal_connection_list(sig)
		_h.expect(conns.size() > 0, "signal_not_connected",
			"信号 %s 没有任何接收者 —— 面板会照常 emit，但动作不会发生，且不报错" % sig)


# 选中商店卡片必须让棋盘/待命的选中态归零。
# 这是 card_selected 信号的**实际效果**，不是「信号连上了」——
# 连上但处理函数写错，上一条用例照样绿。
func _case_card_selection_clears_board() -> void:
	var panel := _shop_panel()
	if panel == null:
		return
	_board_hud().set("_selected_board", 3)
	_board_hud().set("_selected_bench", 2)
	panel._on_card_selected(0)
	_h.expect(int(_board_hud().get("_selected_board")) == -1, "board_selection_not_cleared",
		"选中商店卡片后 _selected_board 仍是 %s —— 会出现「商店和棋盘同时高亮」" % str(_board_hud().get("_selected_board")))
	_h.expect(int(_board_hud().get("_selected_bench")) == -1, "bench_selection_not_cleared",
		"选中商店卡片后 _selected_bench 仍是 %s" % str(_board_hud().get("_selected_bench")))


# 棋盘选中态已随 D2 搬进 BoardHud 节点。
func _board_hud() -> Node:
	return _prep.get("_board_hud") as Node
