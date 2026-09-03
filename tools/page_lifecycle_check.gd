extends Node

# V3 P2-04 门禁：真实页面循环的生命周期泄漏。
#
# `modal_lifecycle` 已经覆盖「热身 + 20 轮」的漂移检测，但它驱动的是**独立实例化**
# 的 MainMenu / PrepScreen 各自开关一次 Dialog/Modal 再销毁 —— 不是真的经过
# `Main._show_menu()` → 信号 → `Main._show_xxx()` → `_on_back_requested()` 这条
# 玩家实际会走的页面切换路径。审计（`reports/v3_audit.json` P2-04）点名的缺口
# 正是这个：**真实页面循环（非仅 modal）**。这条门禁补的就是它。
#
# 走法只用 Main 自己的公开入口，不额外造测试专用接缝：
#   _show_menu() 建出的 MainMenu 会把 settings_requested / codex_requested /
#   prep_requested / team_offline_requested 接到 Main 对应的 _show_xxx()，
#   而每个子页面的 back_requested 已经接到 _page_back_route —— 于是调用
#   `main._on_back_requested()`（P0-09 那条返回键阶梯的真实入口）就等价于玩家
#   按了一次 Android Back / 桌面 Esc。全程不碰任何仅测试用的私有钩子。
#
# 覆盖菜单族四个不需要联机/对局状态的页面（设置、宠物、图鉴、组队大厅-离线）。
# PrepScreen/BattleScreen 需要真实对局状态，风险和铺垫都更大，留给
# tutorial_checkpoint / prep_battle_loading 这些已经在跑它们的门禁去覆盖。
#
# 复用与 modal_lifecycle 同一套「热身 N 轮取基线，再测 M 轮看漂移」的方法论 ——
# 单轮泄漏一个节点round-to-round 看不出来，20 轮之后才明显。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const MainScript := preload("res://scenes/main/Main.gd")

const CHECK_NAME := "page_lifecycle"
const WARMUP_CYCLES := 3
const MEASURED_CYCLES := 20

# 跟 modal_lifecycle 同一份判据字段，方便交叉对照。
const METRICS := ["canvas_layers", "stop_controls", "timers", "tweens",
	"signal_connections", "orphans", "nodes"]

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var main: MainScript = MainScript.new()
	add_child(main)
	await _settle(3)

	for i in WARMUP_CYCLES:
		await _run_one_cycle(main, i)
	await _settle(8)

	var baseline := _snapshot()
	_h.note("热身 %d 轮真实页面循环后的基线：%s" % [WARMUP_CYCLES, JSON.stringify(baseline)])

	var worst := {}
	for i in MEASURED_CYCLES:
		await _run_one_cycle(main, WARMUP_CYCLES + i)
		await _settle(4)
		var after := _snapshot()

		_h.expect(int(after["modal_depth"]) == 0, "cycle_left_modal_open",
			"第 %d 轮真实页面循环结束时模态栈还有 %d 层"
				% [i + 1, int(after["modal_depth"])])
		# 跟基线比增量，不比绝对零：每轮收尾停在「回到菜单」而不是「菜单已销毁」，
		# 而 MainMenu 稳定态本身就带两个默认隐藏的 STOP 控件（重连按钮、地址输入
		# 框——都是"仅在满足某条件时才显示"设计，不是缺陷）。真正的泄漏信号是
		# 这个数字比基线还往上涨，不是它非零。
		var stop_delta := int(after["invisible_stop"]) - int(baseline["invisible_stop"])
		_h.expect(stop_delta <= 0, "cycle_left_invisible_stop",
			"第 %d 轮结束时不可见 STOP 控件比基线多了 %d 个（基线 %d，现在 %d）"
				% [i + 1, stop_delta, int(baseline["invisible_stop"]), int(after["invisible_stop"])])
		# 每轮结束都必须真的回到了主菜单——否则后面的轮次是在一个已经错位的
		# 页面上继续点，测出来的漂移会文不对题。
		_h.expect(is_instance_valid(main._menu) and main._menu.is_inside_tree(),
			"cycle_did_not_return_to_menu",
			"第 %d 轮结束时没有回到主菜单，_menu 是 %s"
				% [i + 1, str(main._menu)])

		for key in METRICS:
			var delta := int(after.get(key, 0)) - int(baseline.get(key, 0))
			if delta > int(worst.get(key, 0)):
				worst[key] = delta

	var final := _snapshot()
	for key in METRICS:
		_h.item()
		var delta := int(final.get(key, 0)) - int(baseline.get(key, 0))
		_h.expect(delta <= 0, "cycle_metric_grew",
			("%d 轮「主菜单 ↔ 设置/宠物/图鉴/组队大厅」真实导航之后 %s 增长了 "
				+ "%+d（峰值 %+d）。每轮泄漏一个的话，这里就是 +%d。"
				+ "热身 %d 轮之后取的基线，所以一次性缓存已经排除。")
				% [MEASURED_CYCLES, key, delta, int(worst.get(key, 0)),
					MEASURED_CYCLES, WARMUP_CYCLES])

	main.queue_free()
	await _settle(4)
	_h.finish(get_tree())


# 一轮：菜单 -> 设置 -> 返回 -> 图鉴 -> 返回 -> 宠物 -> 返回 -> 组队大厅(离线) -> 返回。
# 每一步的「返回」都走 _on_back_requested()，不是直接调 _show_menu() ——
# 后者会绕过 P0-09 那条返回键阶梯，测不出阶梯本身的泄漏（比如某个页面的
# handle_back_request() 忘了清理自己的子面板）。
func _run_one_cycle(main: MainScript, index: int) -> void:
	main._show_menu()
	await _settle(2)
	if not is_instance_valid(main._menu):
		return

	# 房间面板是唯一一个从 MainMenu 直接推到 ModalStack 上的层（P0-07 迁移之后）。
	# 不经过它的话 cycle_left_modal_open 永远测不出「返回键没真的清栈」——
	# 本轮循环里没别的地方会往 ModalStack 推东西，那条断言就成了摆设。
	main._menu._show_room_overlay()
	await _settle(2)
	main._on_back_requested()
	await _settle(2)

	if not is_instance_valid(main._menu):
		return
	main._menu.settings_requested.emit()
	await _settle(2)
	main._on_back_requested()
	await _settle(2)

	if not is_instance_valid(main._menu):
		return
	main._menu.codex_requested.emit()
	await _settle(2)
	main._on_back_requested()
	await _settle(2)

	if not is_instance_valid(main._menu):
		return
	main._menu.prep_requested.emit()
	await _settle(2)
	main._on_back_requested()
	await _settle(2)

	if not is_instance_valid(main._menu):
		return
	main._menu.team_offline_requested.emit()
	await _settle(2)
	main._on_back_requested()
	await _settle(2)


func _settle(frames: int = 2) -> void:
	for i in frames:
		await get_tree().process_frame


# 与 modal_lifecycle_check._snapshot() 同一套字段，独立实现——这条门禁要能
# 单独回答「真实页面循环泄漏了什么」，不应该依赖另一个门禁脚本内部的私有函数。
func _snapshot() -> Dictionary:
	var counts := {"canvas_layers": 0, "stop_controls": 0, "timers": 0}
	_walk(get_tree().root, counts)
	return {
		"canvas_layers": int(counts["canvas_layers"]),
		"stop_controls": int(counts["stop_controls"]),
		"invisible_stop": ModalStack.find_invisible_stop_controls().size(),
		"modal_depth": ModalStack.depth(),
		"tweens": get_tree().get_processed_tweens().size(),
		"timers": int(counts["timers"]),
		"signal_connections": _service_connection_count(),
		"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
	}


func _walk(node: Node, counts: Dictionary) -> void:
	if node is CanvasLayer:
		counts["canvas_layers"] = int(counts["canvas_layers"]) + 1
	if node is Timer:
		counts["timers"] = int(counts["timers"]) + 1
	if node is Control and (node as Control).mouse_filter == Control.MOUSE_FILTER_STOP:
		counts["stop_controls"] = int(counts["stop_controls"]) + 1
	for child in node.get_children():
		_walk(child, counts)


func _service_connection_count() -> int:
	return (ModalStack.modal_opened.get_connections().size()
		+ ModalStack.modal_closed.get_connections().size()
		+ DialogService.dialog_resolved.get_connections().size()
		+ AsyncActionController.action_state_changed.get_connections().size()
		+ AsyncActionController.action_resolved.get_connections().size()
		+ NetworkService.session_changed.get_connections().size())
