extends Node
# ============================================================================
# 2026-10-18「商店购买操作优化」验收门禁：备战商店支持**快速双击**购买棋子。
#
# 【需求原文（10.18 商店购买操作优化.docx，全文唯一一条）】
#   「对局里备战阶段商店购买棋子的操作需要优化，当前购买棋子有：拖动棋子到棋盘
#     或者选中棋子然后点击购买。优化为：额外增加支持快速双击购买棋子的功能。」
#
# 【追加口径（用户原话）】
#   「要求的是快速双击，超过一定时间的不连续双击可不行。」
#   => 窗口必须**真的有上限**。所以「慢双击不成交」和「快速双击成交」两条都是
#     硬判据，缺一条就可能把功能做成「任意两次点击都买」。
#
# 【要钉住什么】
#   1. 快速双击同一张卡 => 直接成交（金币按卡面价扣掉、shop_sold、待命区落子），
#      不再翻转选中态。
#   2. 慢双击（间隔明显超过 SHOP_DOUBLE_CLICK_WINDOW_MS）=> **不成交**，
#      退回「两次独立单击」（各自只翻转选中态）。单元段用合成时间戳卡端点，
#      集成段用真实等待再验一遍。
#   3. 窗口端点含等于：间隔 == 窗口算双击，窗口 + 1ms 不算。
#   4. 单击仍然只切换选中态 —— 旧行为没被顺手改掉。
#   5. 判定只认 `pressed`（松手才发、起过拖就不发）=>「按住划走再回来点一下」
#      不会被误判成双击。用真实输入验证：只按下不松手时，时间戳**不**记录。
#   6. 成交前校验与钱袋 A 共用（越界 / 空 offer / 已售 / 金币不足都不发
#      buy_requested，金币不足要弹 ui_not_enough_gold）—— 把校验拆成
#      _request_buy 不能把旧的那条路改坏。
#   7. 关店要清掉时间戳：否则「关店前一击 + 开店后一击」会被算成一次双击。
#
# 【跑法】
#   Godot_v4.7.2-stable_win64_console.exe --headless --path <工程根> \
#       _qa_1018/shop_double_click_buy_check.tscn
#   退出码 0 = PASS，1 = FAIL。
#
# 警告：集成段会**真的走一遍成交**（扣金币、写 user:// 存档）。
#   跑前先备份 %APPDATA%\Godot\app_userdata\测试服\glory_beta_004.save(.bak)，
#   跑完还原 —— 否则玩家的对局存档会被本门禁覆盖。
# 警告：必须带窗口尺寸跑：卡片几何依赖 viewport 宽度（基准 1600x720）。
#   本门禁自己把窗口设成 1600x720，不依赖命令行 --resolution。
#
# 【为什么不在编译期绑定新符号】
#   直接写 `probe._request_buy(...)` / `probe._card_press_ms` 这类 10.18 才有的
#   成员，未修复的构建上整个脚本解析失败 => 场景没有脚本 => 进程不退出（是挂住，
#   不是判红）。所以常量走 get_script_constant_map()、方法走 call()+has_method()、
#   私有变量走 get()。判据全部落在可观测行为上。
#
# 【为什么挂看门狗】
#   Godot 的运行期脚本错误只中止**当前函数**。某一段抛错时，若那段是协程，
#   `_ready` 会被一起中止 => 没有 finish() => 进程挂住（比判红更糟：看着像在跑）。
#   看门狗把这种情况转成一条 watchdog_timeout 失败。

const CheckHarness := preload("res://_qa_1016/CheckHarness.gd")
const EconomyLedger := preload("res://scripts/multiplayer/EconomyLedger.gd")
const ShopPanelScript := preload("res://scenes/prep/panels/ShopPanel.gd")

const CHECK_NAME := "shop_double_click_buy"
const VIEW := Vector2i(1600, 720)
const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"

# 卡 0 用的那枚棋子：定价表里 cost 正好等于它、且不带 shop_cost_multiplier。
# 写成字面量而不是拿 unit_cost() 反算 —— 后者等于「用被测函数验证被测函数」。
const EXPECTED_COST := 20

# 集成段：两次点击的间隔。一个稳稳在窗口内，一个稳稳在窗口外。
const FAST_GAP_SEC := 0.08
const SLOW_GAP_SEC := 0.55

# 看门狗：正常 30 秒内跑完，给到 120 秒。
const WATCHDOG_SEC := 120.0

var _h: CheckHarness
var _finished := false
var _prep: Node
var _shop: Variant

# 单元级探针：脱离 PrepScreen 的 ShopPanel。只验判定逻辑，宿主不在场 => 不真成交。
var _probe: Variant
var _probe_card: Button
var _buy_emits: Array = []
var _messages: Array = []
var _selected_emits: Array = []

# 4 个卡位的 offer（卡 0 是 EXPECTED_COST 那枚，其余用表里别的棋子）。
var _offers: Array = []


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_finished = false
	get_window().size = VIEW
	get_tree().create_timer(WATCHDOG_SEC).timeout.connect(_on_watchdog)
	await _settle(4)

	DataRegistry.ensure_loaded()
	_collect_offers()
	if _offers.size() < 4:
		_h.fail("offers_missing",
			"棋子表里凑不齐 4 枚可用的棋子（拿到 %d）—— 集成段无从摆商店" % _offers.size())
		_done()
		return

	# 第一节全程同步：判定逻辑只跟时间戳比大小，不依赖真实时钟。
	_run_section(_section_unit_logic, 32, "section_unit_incomplete")

	# 第二节要真实输入与真实等待，是协程；直接 await，跑完核对实跑条数。
	var before := _h.checked_count()
	await _section_integration()
	var done := _h.checked_count() - before
	if done < 20:
		_h.fail("section_integration_incomplete",
			"本节只跑了 %d 条断言（应 >= %d）—— 中途抛错或提前返回，不算跑过" % [done, 20])

	_done()


func _done() -> void:
	if _finished:
		return
	_finished = true
	_h.finish(get_tree())


func _on_watchdog() -> void:
	if _finished:
		return
	_h.fail("watchdog_timeout",
		"门禁 %.0f 秒还没跑完 —— 很可能是某一段抛错把 _ready 中止了。按失败计，不当成通过。"
			% WATCHDOG_SEC)
	_done()


# 跑一段断言，并核对它真的跑够了条数。
# Godot 的脚本运行期错误只中止**当前函数**，"某一段整体抛错"会表现成
# "这一段一条都没跑、别的段照跑、最后 PASS" —— 那就是假绿。
func _run_section(section: Callable, min_checks: int, code: String) -> void:
	var before := _h.checked_count()
	section.call()
	var done := _h.checked_count() - before
	if done < min_checks:
		_h.fail(code, "本节只跑了 %d 条断言（应 >= %d）—— 中途抛错或提前返回，不算跑过"
			% [done, min_checks])


# ---------------------------------------------------------------- 数据准备

# 卡 0：cost 恰为 EXPECTED_COST 且不带 shop_cost_multiplier 的第一枚。
# 卡 1..3：表里另外的棋子（cost 无所谓，集成段只关心「成交/不成交」与卡面价）。
func _collect_offers() -> void:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	var anchor: Dictionary = {}
	var others: Array = []
	var used_ids: Array = []
	for raw in units:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var def: Dictionary = raw
		var uid := str(def.get("id", ""))
		if uid.is_empty() or used_ids.has(uid):
			continue
		if anchor.is_empty() and int(def.get("cost", -1)) == EXPECTED_COST \
				and not def.has("shop_cost_multiplier"):
			anchor = def.duplicate(true)
			used_ids.append(uid)
			continue
		if others.size() < 3:
			others.append(def.duplicate(true))
			used_ids.append(uid)
		if not anchor.is_empty() and others.size() >= 3:
			break
	if anchor.is_empty():
		return
	_offers = [anchor, others[0], others[1], others[2]]


# 把 GameState 的商店摆成确定性状态：4 张卡有货、全未售、金币给够。
func _reset_shop_state(gold: int) -> void:
	GameState.reset_run()
	for i in GameState.SHOP_UNIT_SLOTS:
		GameState.shop_offers[i] = _offers[i].duplicate(true)
		GameState.shop_sold[i] = false
	GameState.gold = gold


func _card_price(index: int) -> int:
	var labels: Variant = _shop.get("price_labels")
	if typeof(labels) != TYPE_ARRAY or index >= (labels as Array).size():
		return -1
	var label := (labels as Array)[index] as Label
	if label == null:
		return -1
	return int(label.text)


# ---------------------------------------------------------------- 第一节
# 单元级判定逻辑：脱离宿主的 ShopPanel，只发信号不成交。全程同步，不依赖真实时钟。

func _section_unit_logic() -> void:
	_probe = ShopPanelScript.new()
	if not _h.expect(_probe != null and is_instance_valid(_probe), "probe_new_failed",
			"ShopPanel 实例化失败"):
		return
	_probe_card = Button.new()
	_probe_card.name = "ProbeCard"
	_probe.buy_requested.connect(_on_buy_requested)
	_probe.message_requested.connect(_on_message)
	_probe.card_selected.connect(_on_card_selected)

	_reset_shop_state(200)
	_probe.set("selected", -1)
	_clear_records()

	var constants: Dictionary = _probe.get_script().get_script_constant_map()
	var win_ms: int = int(constants.get("SHOP_DOUBLE_CLICK_WINDOW_MS", -1))
	var stamps: Variant = _probe.get("_card_press_ms")

	# 1.1 窗口常量：必须存在、必须是正数、且是 350（口径里的"一定时间"）。
	_h.expect(constants.has("SHOP_DOUBLE_CLICK_WINDOW_MS"), "window_constant_missing",
		"ShopPanel 上没有 SHOP_DOUBLE_CLICK_WINDOW_MS 常量 —— 双击窗口没有落成可读的常量")
	_h.expect(win_ms > 0, "window_constant_not_positive", "双击窗口常量是 %d，不是正数" % win_ms)
	_h.expect(win_ms == 350, "window_constant_value", "双击窗口常量是 %d，预期 350" % win_ms)

	# 1.2 每卡时间戳字典：存在、初始为空。
	_h.expect(stamps is Dictionary, "stamps_not_dictionary",
		"_card_press_ms 不是 Dictionary（拿到 %s）" % str(stamps))
	_h.expect(stamps is Dictionary and (stamps as Dictionary).is_empty(),
		"stamps_not_empty_at_start", "_card_press_ms 初始不为空：%s" % str(stamps))

	# 1.3 成交前校验必须是**共用**的那个函数（钱袋 A 与双击两条路走同一处）。
	_h.expect(bool(_probe.has_method("_request_buy")), "request_buy_missing",
		"ShopPanel 上没有 _request_buy —— 钱袋 A 与快速双击没有共用成交前校验")

	# 1.4 第一次点击：没有前一次 => 普通单击，只选中，不成交。
	_reset_probe()
	_probe.call("_on_card_pressed", _probe_card, 0)
	_h.expect(int(_probe.get("selected")) == 0, "single_click_select",
		"单击第 1 张卡后 selected=%d（应为 0）" % int(_probe.get("selected")))
	_h.expect(_selected_emits == [0], "single_click_signal",
		"单击第 1 张卡后 card_selected 序列是 %s（应为 [0]）" % str(_selected_emits))
	_h.expect(_buy_emits.is_empty(), "single_click_buys",
		"单击第 1 张卡竟然触发了成交（buy_requested=%s）—— 单击被做成了购买" % str(_buy_emits))

	# 1.5 间隔超过窗口的两次点击：各自翻转选中态，**不**成交。
	_reset_probe()
	_probe.call("_on_card_pressed", _probe_card, 0)      # 第 1 下：选中
	_age_stamp(0, win_ms + 1)                            # 上一次点击老化到窗口之外
	_probe.call("_on_card_pressed", _probe_card, 0)      # 第 2 下：翻回未选
	_h.expect(int(_probe.get("selected")) == -1, "slow_pair_toggles_off",
		"间隔超过窗口的两次点击后 selected=%d（应为 -1，即翻回未选）" % int(_probe.get("selected")))
	_h.expect(_selected_emits == [0, -1], "slow_pair_toggle_signal",
		"间隔超过窗口的两次点击，card_selected 序列是 %s（应为 [0, -1]）" % str(_selected_emits))
	_h.expect(_buy_emits.is_empty(), "slow_pair_no_buy",
		"间隔超过窗口的两次点击触发了成交（buy_requested=%s）—— 窗口没有上限，"
			% str(_buy_emits) + "「超过一定时间的不连续双击」会被算成双击")

	# 1.6 背靠背两次点击 => 成交，且不再翻转选中态。
	_reset_probe()
	_probe.call("_on_card_pressed", _probe_card, 0)
	_probe.call("_on_card_pressed", _probe_card, 0)
	_h.expect(_buy_emits == [0], "fast_double_click_buys",
		"背靠背两次点击第 1 张卡，buy_requested=%s（应为 [0]）—— 快速双击没有成交"
			% str(_buy_emits))
	_h.expect(int(_probe.get("selected")) == 0, "fast_double_click_keeps_selection",
		"快速双击成交后 selected=%d（应为 0，即没有把选中态翻掉）" % int(_probe.get("selected")))
	_h.expect((stamps as Dictionary).is_empty(), "fast_double_click_clears_stamp",
		"快速双击成交后 _card_press_ms 没有清空（%s）—— 第三次点击会被误判成双击"
			% str(stamps))

	# 1.7 / 1.8 窗口端点：== 窗口算双击，窗口 + 1ms 不算。
	_reset_probe()
	_age_stamp(0, win_ms)
	_probe.call("_on_card_pressed", _probe_card, 0)
	_h.expect(_buy_emits == [0], "window_boundary_inclusive",
		"间隔正好等于窗口（%dms）时没有成交（buy_requested=%s）—— 端点被做成了开区间"
			% [win_ms, str(_buy_emits)])

	_reset_probe()
	_age_stamp(0, win_ms + 1)
	_probe.call("_on_card_pressed", _probe_card, 0)
	_h.expect(_buy_emits.is_empty(), "window_boundary_exclusive",
		"间隔为窗口 +1ms 时竟然成交了（buy_requested=%s）—— 窗口没有上限" % str(_buy_emits))
	_h.expect(int(_probe.get("selected")) == 0, "window_boundary_exclusive_selects",
		"间隔为窗口 +1ms 时 selected=%d（应为 0，即退回普通单击）" % int(_probe.get("selected")))

	# 1.9 不同卡不配对：时间戳是**按卡位**记的。
	_reset_probe()
	_age_stamp(0, 0)
	_probe.call("_on_card_pressed", _probe_card, 1)
	_h.expect(_buy_emits.is_empty(), "other_card_not_paired",
		"在第 1 张卡留下时间戳后点第 2 张卡也成交了 —— 配对没有按卡位分开")
	_h.expect(int(_probe.get("selected")) == 1, "other_card_selects",
		"点第 2 张卡后 selected=%d（应为 1）" % int(_probe.get("selected")))

	# 1.10 / 1.11 / 1.12 / 1.13 成交前校验：越界、空 offer、已售、金币不足。
	_reset_probe()
	_probe.call("_request_buy", -1)
	_probe.call("_request_buy", GameState.SHOP_UNIT_SLOTS + 7)
	_h.expect(_buy_emits.is_empty(), "request_buy_out_of_range",
		"越界 index 也发出了 buy_requested（%s）—— 成交前校验没兜住" % str(_buy_emits))

	_reset_probe()
	GameState.shop_offers[2] = {}
	_probe.call("_request_buy", 2)
	_h.expect(_buy_emits.is_empty(), "request_buy_empty_offer",
		"空 offer 也发出了 buy_requested（%s）—— 成交前校验没兜住" % str(_buy_emits))
	GameState.shop_offers[2] = _offers[2].duplicate(true)

	_reset_probe()
	GameState.shop_sold[0] = true
	_probe.call("_request_buy", 0)
	_h.expect(_buy_emits.is_empty(), "request_buy_sold",
		"已售出的卡也发出了 buy_requested（%s）—— 成交前校验没兜住" % str(_buy_emits))
	GameState.shop_sold[0] = false

	_reset_probe()
	GameState.gold = 0
	_probe.call("_request_buy", 0)
	_h.expect(_buy_emits.is_empty(), "request_buy_no_gold",
		"金币不足也发出了 buy_requested（%s）—— 成交前校验没兜住" % str(_buy_emits))
	# tr() 出来的是译文（门禁进程当前语言下），所以跟 tr() 自己比，别跟键名比。
	_h.expect(_messages.size() >= 1 and str(_messages[0]) == tr("ui_not_enough_gold"),
		"request_buy_no_gold_message",
		"金币不足时没有弹 ui_not_enough_gold 的译文（message_requested=%s，期望 %s）—— "
			% [str(_messages), tr("ui_not_enough_gold")]
			+ "拆出 _request_buy 把原来的提示弄丢了")
	GameState.gold = 200

	# 1.14 钱袋 A 那条旧路仍然走到同一个校验。
	_reset_probe()
	_probe.set("selected", 0)
	_probe.call("buy_selected")
	_h.expect(_buy_emits == [0], "purse_path_still_works",
		"选中后调 buy_selected()，buy_requested=%s（应为 [0]）—— 钱袋 A 的旧路被改坏了"
			% str(_buy_emits))

	# 1.15 / 1.16 关店必须清掉时间戳。
	_reset_probe()
	_probe.call("_on_card_pressed", _probe_card, 0)
	_h.expect(not (stamps as Dictionary).is_empty(), "stamp_recorded_before_close",
		"单击之后 _card_press_ms 是空的 —— 这条判据的前提不成立")
	_probe.call("close_picker")
	_h.expect((stamps as Dictionary).is_empty(), "close_picker_clears_stamps",
		"close_picker() 之后 _card_press_ms 没有清空 —— 关店前一击 + 开店后一击会被算成双击")
	_probe.call("_on_card_pressed", _probe_card, 0)
	_h.expect(_buy_emits.is_empty(), "reopen_first_click_not_double",
		"关店再开店后的第一次点击竟然成交了 —— 关店没有把上一次点击的时间戳清掉")

	# 1.17 toggle_picker() 关店同样清。
	_reset_probe()
	_probe.call("toggle_picker")          # 打开（初始 picker_open=false）
	_probe.call("_on_card_pressed", _probe_card, 0)
	_probe.call("toggle_picker")          # 再调一次 = 关店
	_h.expect((stamps as Dictionary).is_empty(), "toggle_close_clears_stamps",
		"toggle_picker() 关店之后 _card_press_ms 没有清空")
	_h.expect(not bool(_probe.get("picker_open")), "toggle_closed_shop",
		"toggle_picker() 两次之后商店仍是开着的 —— 探针状态不对，上一条判据失去意义")


# 把某个卡位的时间戳改写成 ms_ago 毫秒之前，用来合成「间隔」。
func _age_stamp(index: int, ms_ago: int) -> void:
	if _probe == null or not is_instance_valid(_probe):
		return
	var stamps: Variant = _probe.get("_card_press_ms")
	if stamps is Dictionary:
		(stamps as Dictionary)[index] = Time.get_ticks_msec() - ms_ago


func _reset_probe() -> void:
	if _probe == null or not is_instance_valid(_probe):
		return
	_probe.set("selected", -1)
	var stamps: Variant = _probe.get("_card_press_ms")
	if stamps is Dictionary:
		(stamps as Dictionary).clear()
	_clear_records()


func _clear_records() -> void:
	_buy_emits.clear()
	_messages.clear()
	_selected_emits.clear()


func _on_buy_requested(index: int) -> void:
	_buy_emits.append(index)


func _on_message(text: String) -> void:
	_messages.append(text)


func _on_card_selected(index: int) -> void:
	_selected_emits.append(index)


# ---------------------------------------------------------------- 第二节
# 集成：PrepScreen + 真实输入事件，真的成交。

func _section_integration() -> void:
	var packed := load(PREP_SCENE) as PackedScene
	if not _h.expect(packed != null, "prep_scene_load_failed", "%s 加载不出来" % PREP_SCENE):
		return
	_prep = packed.instantiate()
	if not _h.expect(_prep != null, "prep_instantiate_failed", "PrepScreen 实例化失败"):
		return
	add_child(_prep)
	await _settle(12)

	_shop = _prep.get("_shop")
	if not _h.expect(_shop != null, "shop_missing",
			"PrepScreen 上取不到 _shop（面板被改名或没建起来）"):
		return

	_reset_shop_state(200)
	_shop.call("refresh")
	await _settle(6)
	await _open_shop()

	# 2.1 起点：商店开着、4 张卡都在、第 1 张可点。
	_h.expect(bool(_shop.get("picker_open")), "integration_shop_not_open",
		"前置不成立：toggle_picker() 之后商店没打开")
	var buttons: Variant = _shop.get("buttons")
	var button_count: int = (buttons as Array).size() if typeof(buttons) == TYPE_ARRAY else -1
	_h.expect(button_count >= 4, "integration_cards_missing",
		"商店卡片不足 4 张（拿到 %d）" % button_count)
	if button_count < 4:
		return
	var card0: Variant = (buttons as Array)[0]
	_h.expect(card0 != null and is_instance_valid(card0)
			and bool(card0.is_visible_in_tree()) and not bool(card0.get("disabled")),
		"integration_card0_not_tappable",
		"第 1 张商店卡不可点（visible=%s disabled=%s）"
			% [str(card0.is_visible_in_tree()) if card0 != null else "<null>",
				str(card0.get("disabled")) if card0 != null else "<null>"])

	var price0 := _card_price(0)
	_h.expect(price0 == EXPECTED_COST, "integration_price0_label",
		"第 1 张卡的卡面价是 %d，预期 %d" % [price0, EXPECTED_COST])

	# 2.2 只按下不松手 => 时间戳不记录（`pressed` 只在松手且未起拖时才发）。
	var stamps: Variant = _shop.get("_card_press_ms")
	_h.expect(stamps is Dictionary, "integration_stamps_not_dictionary",
		"商店面板上取不到 _card_press_ms 字典")
	var card0_point := _canvas_to_window((card0 as Control).get_global_rect().get_center())
	_push_mouse(card0_point, true)
	await _settle(2)
	_h.expect(stamps is Dictionary and (stamps as Dictionary).is_empty(),
		"press_only_records_stamp",
		"只按下不松手就记了时间戳（%s）—— 「按住划走再回来点一下」会被误判成双击"
			% str(stamps))
	_push_mouse(card0_point, false)     # 补一次松手，把按钮状态还回去
	await _settle(2)
	await _reopen_shop()                # 关店重开，把刚才那一下的时间戳清掉

	# 2.3 快速双击第 1 张卡 => 成交。
	var gold_before := GameState.gold
	var sold_before: Array = GameState.shop_sold.duplicate()
	_tap(card0_point)
	await get_tree().create_timer(FAST_GAP_SEC).timeout
	_tap(card0_point)
	await _settle(8)
	_h.expect(bool(GameState.shop_sold[0]), "fast_double_click_sold",
		"快速双击第 1 张卡没有成交（shop_sold[0]=%s）—— 双击购买没有生效"
			% str(GameState.shop_sold[0]))
	_h.expect(GameState.gold == gold_before - price0, "fast_double_click_gold",
		"快速双击成交后金币是 %d，预期 %d（成交前 %d、卡面价 %d）"
			% [GameState.gold, gold_before - price0, gold_before, price0])
	_h.expect(GameState.bench_slots[0] != null, "fast_double_click_bench",
		"快速双击成交后待命区第 1 格是空的 —— 钱扣了、棋子没落地")
	_h.expect(int(_shop.get("selected")) == -1, "fast_double_click_selection_cleared",
		"快速双击成交后 selected=%d（宿主成交后会清成 -1）" % int(_shop.get("selected")))
	_h.expect(bool(GameState.shop_sold[1]) == bool(sold_before[1])
			and bool(GameState.shop_sold[2]) == bool(sold_before[2])
			and bool(GameState.shop_sold[3]) == bool(sold_before[3]),
		"fast_double_click_only_one_card",
		"快速双击把别的卡也标成已售了：%s" % str(GameState.shop_sold))

	# 2.4 慢双击第 2 张卡 => 不成交，两次翻转回到未选。
	var card1: Variant = (buttons as Array)[1]
	var card1_point := _canvas_to_window((card1 as Control).get_global_rect().get_center())
	var gold_mid := GameState.gold
	_tap(card1_point)
	await _settle(4)
	_h.expect(int(_shop.get("selected")) == 1, "slow_double_click_first_tap_selects",
		"慢双击的第 1 下没有把第 2 张卡选中（selected=%d）" % int(_shop.get("selected")))
	await get_tree().create_timer(SLOW_GAP_SEC).timeout
	_tap(card1_point)
	await _settle(8)
	_h.expect(GameState.gold == gold_mid, "slow_double_click_gold_unchanged",
		"慢双击之后金币从 %d 变成了 %d —— 超过窗口的不连续双击也买了"
			% [gold_mid, GameState.gold])
	_h.expect(not bool(GameState.shop_sold[1]), "slow_double_click_not_sold",
		"慢双击之后第 2 张卡被标成已售 —— 超过窗口的不连续双击也买了")
	_h.expect(int(_shop.get("selected")) == -1, "slow_double_click_toggles_off",
		"慢双击之后 selected=%d（应为 -1，即两下各自翻转选中态）" % int(_shop.get("selected")))
	_h.expect(GameState.bench_slots[1] == null and GameState.bench_slots[0] != null,
		"slow_double_click_bench_untouched",
		"慢双击之后待命区多出了东西（slot0=%s slot1=%s）"
			% [str(GameState.bench_slots[0] != null), str(GameState.bench_slots[1] != null)])

	# 2.5 钱袋 A 的旧路（选中后点购买）仍然通。
	var card2: Variant = (buttons as Array)[2]
	_tap(_canvas_to_window((card2 as Control).get_global_rect().get_center()))
	await _settle(4)
	_h.expect(int(_shop.get("selected")) == 2, "purse_path_selects",
		"点第 3 张卡后 selected=%d（应为 2）" % int(_shop.get("selected")))
	var price2 := _card_price(2)
	var buy_button: Variant = _shop.get("buy_button")
	_h.expect(buy_button != null and is_instance_valid(buy_button)
			and bool(buy_button.is_visible_in_tree()), "purse_button_missing",
		"取不到可见的 buy_button（钱袋 A 的采购热区）")
	if buy_button != null and is_instance_valid(buy_button):
		var gold_pre := GameState.gold
		_tap(_canvas_to_window((buy_button as Control).get_global_rect().get_center()))
		await _settle(8)
		_h.expect(bool(GameState.shop_sold[2]), "purse_path_buys",
			"选中后点钱袋 A 没有成交（shop_sold[2]=%s）—— 拆出 _request_buy 把旧路改坏了"
				% str(GameState.shop_sold[2]))
		_h.expect(GameState.gold == gold_pre - price2, "purse_path_gold",
			"钱袋 A 成交后金币是 %d，预期 %d（成交前 %d、卡面价 %d）"
				% [GameState.gold, gold_pre - price2, gold_pre, price2])


# ---------------------------------------------------------------- 辅助

func _open_shop() -> void:
	if bool(_shop.get("picker_open")):
		_shop.call("close_picker")
		await _settle(3)
	_shop.call("toggle_picker")      # 走真实入口，不直接改 picker_open
	await _settle(5)


func _reopen_shop() -> void:
	await _open_shop()


func _canvas_to_window(pos: Vector2) -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return pos
	var canvas := vp.get_visible_rect().size
	var win := Vector2(vp.size)
	if canvas.x <= 0.0 or canvas.y <= 0.0:
		return pos
	return Vector2(pos.x * win.x / canvas.x, pos.y * win.y / canvas.y)


func _push_mouse(win_pos: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = win_pos
	e.global_position = win_pos
	get_viewport().push_input(e)


func _tap(win_pos: Vector2) -> void:
	_push_mouse(win_pos, true)
	_push_mouse(win_pos, false)


func _settle(frames: int = 2) -> void:
	for i in frames:
		await get_tree().process_frame
