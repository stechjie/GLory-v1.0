extends Node

# 守 README D2 的验收条：「商店、拖拽、宝物、详情、战力推荐都可独立场景加载」。
#
# 这条检查**不实例化 PrepScreen**。它逐个 load 五个面板场景、单独放进树、
# 断言它们自己能立起来。这正是「自治组合节点」与「继承链上的一层」的分界：
# 继承链上的一层没法单独加载 —— 你得把整个 6853 行的类拉起来才能碰到商店。
#
# 它能抓到什么：
#   * 面板脚本在 _ready/_enter_tree 里偷偷依赖宿主（单独加载会崩或报错）
#   * 场景文件与脚本脱钩（.tscn 忘了挂脚本、路径写错）
#   * 对外信号被改名或删掉（宿主那边是 connect 字符串，编译期不报）
#   * 面板之间意外产生依赖（load A 却把 B 也拉起来并崩掉）
#
# 面板允许「没有 setup 就什么都不做」，但**不允许崩**。
# 依赖注入的东西（host / overlay / hover_handler）在这里一律不给 ——
# 面板必须能在裸状态下安全存在。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/panel_scene_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "panel_scene"

# 面板路径 -> 它必须对外暴露的信号。
# 信号名写死在这里是刻意的：宿主是用 `panel.xxx.connect(...)` 连的，
# 改名后编译期确实会报，但**删掉一条信号**并顺手删掉宿主那行不会报 ——
# 那正是「动作静默不发生」的来源（见 prep_shop_check 的 signal_not_connected）。
const PANELS := {
	"res://scenes/prep/panels/ShopPanel.tscn": [
		"card_selected", "buy_requested", "detail_requested",
		"picker_toggled", "refresh_requested", "message_requested", "state_changed",
	],
	"res://scenes/prep/panels/SynergyPanel.tscn": [
		"altar_requested", "gamble_requested", "treasure_detail_requested",
	],
	"res://scenes/prep/panels/TreasureChoicePanel.tscn": [
		"pick_requested", "claim_requested", "net_signals_needed", "state_changed",
	],
	"res://scenes/prep/panels/BoardHud.tscn": [
		"visuals_dirty", "state_changed",
	],
	# 战力统计面板是纯显示，一条信号都不该有 —— 空列表是断言，不是省略。
	"res://scenes/prep/panels/BattleStatsPanel.tscn": [],
}

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()

	for path in PANELS.keys():
		await _check_panel(str(path), PANELS[path])

	_h.expect(PANELS.size() == 5, "panel_count_changed",
		"这条检查应覆盖 5 个面板，实际 %d 个 —— 新增面板要一并登记" % PANELS.size())
	_h.finish(get_tree())


func _check_panel(path: String, want_signals: Array) -> void:
	var packed := load(path) as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "%s 加载不出来" % path):
		return

	var node := packed.instantiate()
	if not _h.expect(node != null, "instantiate_failed", "%s 实例化失败" % path):
		return
	_h.expect(node is Control, "root_not_control",
		"%s 的根节点不是 Control（面板要能直接进 UI 树）" % path)
	_h.expect(node.get_script() != null, "script_missing",
		"%s 的根节点没有挂脚本 —— 场景与脚本脱钩了" % path)

	# 裸状态进树：没有 setup、没有宿主。面板不该因此崩。
	add_child(node)
	await get_tree().process_frame
	_h.expect(node.is_inside_tree(), "not_in_tree", "%s 加入场景树后不在树里" % path)

	var have := {}
	for sig in node.get_signal_list():
		have[str(sig.get("name", ""))] = true
	for sig_name in want_signals:
		_h.expect(have.has(str(sig_name)), "signal_missing",
			"%s 少了对外信号 %s —— 宿主那边的 connect 会连不上，动作静默不发生" % [path, str(sig_name)])

	# 纯显示面板不该有自定义信号。
	#
	# 判定方式：读**脚本源码里的 signal 声明**，而不是从 get_signal_list 里
	# 减去一份「引擎自带信号名单」—— 第一版就是那么写的，名单漏了一个
	# （Control 的某个信号）就误报了 BattleStatsPanel。
	# 维护一份引擎信号白名单注定会漏，读源码是确定的。
	if want_signals.is_empty():
		var declared := _declared_signals(str(node.get_script().resource_path))
		_h.expect(declared.is_empty(), "unexpected_signal",
			"%s 声称是纯显示面板，却声明了信号：%s" % [path, ", ".join(declared)])
	node.queue_free()
	await get_tree().process_frame


func _declared_signals(script_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var f := FileAccess.open(script_path, FileAccess.READ)
	if f == null:
		return out
	for raw in f.get_as_text().split("
"):
		var line := str(raw)
		if not line.begins_with("signal "):
			continue
		var after := line.substr(7).strip_edges()
		var cut := after.find("(")
		if cut < 0:
			cut = after.find(" ")
		out.append(after if cut < 0 else after.substr(0, cut))
	f.close()
	return out
