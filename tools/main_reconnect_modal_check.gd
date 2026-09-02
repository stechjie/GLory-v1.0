extends Node

# C-11 / B1 生产门禁：`Main.gd` 的断线重连提示层迁移到 ModalStack。
#
# 跑的是真实 `Main.gd`，只用一处 debug-only seam 替换「取消后的导航」——
# 不需要 socket、不需要专用服务器、不发任何真实 RPC：
# `NetworkService.state` 是可写属性，置成 RECONNECTING 再 emit `session_changed`
# 走的就是生产里 `_on_global_session_changed()` 的同一条路。
#
# 这一层最要命的性质：**关层 ≠ 取消**。
# `cancel_reconnect()` 会删掉重连凭证并 reset 整个会话。若 Back / `close_all` /
# owner 释放误触发那条链，玩家的对局凭证就被无声销毁了 —— 下面 §外部关闭 那组
# 断言守的就是这件事。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const MainScript := preload("res://scenes/main/Main.gd")

const CHECK_NAME := "main_reconnect_modal"

# 与 Main.gd 的合同保持一致；改那边这里要同步。
const RECONNECT_ID := "reconnect_status"
const RECONNECT_PRIORITY := 90
const RECONNECT_BACKDROP := Color(0.0, 0.0, 0.0, 0.72)

const CYCLES := 20
const RAPID_TAPS := 20

# 一律用假值，且从不打印 —— 门禁不碰也不泄漏玩家真实凭证。
const DUMMY_TOKEN := "gate_dummy_token"
const DUMMY_ADDRESS := "127.0.0.1"

# `cancel_reconnect()` → `SaveManager.clear_reconnect()` 会连 .bak/.tmp 一起删，
# 所以三个变体都要逐字快照并还原。
const USER_FILES: PackedStringArray = [
	"user://glory_reconnect.json",
	"user://glory_reconnect.json.bak",
	"user://glory_reconnect.json.tmp",
]

const METRICS: PackedStringArray = [
	"root_children", "canvas_layers", "stop_controls", "invisible_stop",
	"modal_depth", "timers", "signal_connections", "orphans", "nodes",
]


# 只数导航发生了几次。取消链是线性的，所以「导航一次」等价于「整条取消链落地一次」。
class NavProbe:
	extends RefCounted

	var count := 0

	func invoke() -> void:
		count += 1


var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)

	var files_before := _snapshot_files()
	var reports_before := _issue_report_files()
	var net_before := _save_network_state()
	var team_mode_before: bool = GameState.team_mode
	var locale_before := LocaleManager.get_locale()

	ModalStack.close_all()
	await _settle(4)

	# Main._ready() 在 OFFLINE 时会起 VFX 预热；置 READY 让它早退，
	# 与既有的 main_team_*_action 门禁做法一致。
	NetworkService.state = NetworkService.SessionState.READY
	NetworkService.team_active = true
	NetworkService.session_token = DUMMY_TOKEN
	NetworkService.reconnect_address = DUMMY_ADDRESS

	var main: MainScript = MainScript.new()
	add_child(main)
	await _settle(3)

	var nav := NavProbe.new()
	_h.expect(main.set_reconnect_cancel_navigation_check_hook(nav.invoke),
		"debug_nav_seam_rejected", "debug 构建拒绝安装取消导航探针")

	var baseline := _snapshot()
	var base_depth := int(baseline["modal_depth"])

	await _check_open_and_contract(main, baseline, base_depth)
	await _check_backdrop_and_locale(main, nav)
	await _check_external_close_never_cancels(main, nav, base_depth)
	await _check_leaving_reconnecting_pops(main)
	await _check_cancel_lands_once(main, nav)
	await _check_cycles_leave_nothing(main, base_depth)
	await _check_owner_freed(main, base_depth)
	_check_source_contract()

	# --- 还原 -----------------------------------------------------------------
	_leave_reconnecting(NetworkService.SessionState.OFFLINE)
	ModalStack.close_all()
	await _settle(4)
	LocaleManager.set_locale(locale_before)
	GameState.team_mode = team_mode_before
	_restore_network_state(net_before)
	_restore_files(files_before)

	var drift := _file_drift(files_before)
	_h.expect(drift.is_empty(), "user_files_not_restored",
		"测试结束后用户文件没有逐字还原：%s" % ", ".join(drift))
	# IssueReport.capture() 每调一次都会落一份 user://issue_report_*.json ——
	# _emit() 在 summary 的 "file" 键里内联调了 _write_report()。§6.12 要求验证
	# 模态在报告里看得见，所以门禁必然会写一份；写完自己收干净，
	# 不给开发者的 user:// 留垃圾。断言留在清理**之后**，清理失败就变红。
	for path in _issue_report_files():
		if not reports_before.has(path):
			DirAccess.remove_absolute(str(path))
	var leaked: Array = []
	for path in _issue_report_files():
		if not reports_before.has(path):
			leaked.append(str(path))
	_h.expect(leaked.is_empty(), "gate_left_issue_report",
		"门禁留下了 %d 个 issue_report 文件没清掉：%s" % [leaked.size(), ", ".join(leaked)])
	_h.expect(ModalStack.depth() == 0, "residual_modal_depth",
		"跑完之后模态栈还有 %d 层" % ModalStack.depth())

	_h.finish(get_tree())


# --- 1 / 2 / 3 / 12：打开、去重、视觉合同、可被 IssueReport 看见 ----------------

func _check_open_and_contract(main: MainScript, baseline: Dictionary, base_depth: int) -> void:
	_h.expect(_entries() == 0, "open_while_not_reconnecting",
		"还没进入 RECONNECTING，栈里却已经有 %s" % RECONNECT_ID)

	_enter_reconnecting()
	await _settle(3)
	if not _h.expect(_entries() == 1, "not_opened_once",
			"进入 RECONNECTING 后栈里有 %d 条 %s，应为 1" % [_entries(), RECONNECT_ID]):
		return

	var row := _row()
	_h.expect(ModalStack.depth() == base_depth + 1, "depth_not_plus_one",
		"打开后 depth=%d，相对基线 %d 应只 +1" % [ModalStack.depth(), base_depth])
	_h.expect(int(row.get("priority", -1)) == RECONNECT_PRIORITY, "priority_wrong",
		"priority=%s，应为 %d（高于战斗加载 80、低于确认框 100）"
			% [str(row.get("priority", "?")), RECONNECT_PRIORITY])
	_h.expect(bool(row.get("in_tree", false)), "not_in_tree",
		"记在栈上却不在树里 —— 界面其实没显示出来")
	_h.expect(bool(row.get("owner_valid", false)), "owner_invalid",
		"owner 无效 —— owner 兜底会失效")

	# --- 2 重复 show / session_changed 各 20 次不叠层 --------------------------
	for i in CYCLES:
		main._show_reconnect_overlay()
		NetworkService.session_changed.emit()
	await _settle(3)
	_h.expect(_entries() == 1, "repeat_show_stacked",
		"重复 show / session_changed 各 %d 次后栈里有 %d 条，应仍为 1" % [CYCLES, _entries()])
	_h.expect(ModalStack.depth() == base_depth + 1, "repeat_show_grew_depth",
		"重复 show 之后 depth=%d，应仍是 %d" % [ModalStack.depth(), base_depth + 1])

	# --- 3 backdrop 0.72 且是栈顶 STOP；content 内没有第二块全屏 STOP ----------
	var backdrop := _backdrop()
	_h.expect(backdrop != null and backdrop.color.is_equal_approx(RECONNECT_BACKDROP),
		"backdrop_color_changed",
		"backdrop 颜色是 %s，应为迁移前那块浮层的 Color(0,0,0,0.72)"
			% ("(无)" if backdrop == null else str(backdrop.color)))
	_h.expect(str(row.get("backdrop_filter", "")) == "STOP", "backdrop_not_stop",
		"栈顶 backdrop 不是 STOP，点击会漏到下面的界面")
	var content := _content()
	if _h.expect(content != null, "content_missing",
			"栈里有条目但找不到 ReconnectStatusOverlay content"):
		var vp := get_viewport().get_visible_rect().size
		var extra := _fullscreen_stops(content, vp)
		_h.expect(extra == 0, "content_has_fullscreen_stop",
			"content 子树里还有 %d 个全屏 STOP —— 全屏拦截只能由 backdrop 一处负责" % extra)
	_h.expect(int(_snapshot()["invisible_stop"]) <= int(baseline["invisible_stop"]),
		"invisible_stop_grew", "打开重连层之后多出了不可见 STOP 控件")

	# --- §5 最后一条：Main 切界面不得把 content 误删 ---------------------------
	# ModalStack 的宿主层挂在 root，而 _clear() 只删 Main 自己的子节点。
	main._clear()
	await _settle(3)
	_h.expect(_entries() == 1, "clear_removed_content",
		"Main._clear() 之后重连层没了 —— content 被当成 Main 的子节点删掉了")

	# --- 12 IssueReport / dump_modal_stack 看得见 ------------------------------
	var report: Dictionary = IssueReport.capture("main_reconnect_modal_check")
	var modal_section: Dictionary = report.get("modal_stack", {})
	var seen := false
	for entry in modal_section.get("entries", []):
		if typeof(entry) == TYPE_DICTIONARY and str((entry as Dictionary).get("id", "")) == RECONNECT_ID:
			seen = true
	_h.expect(seen, "issue_report_blind",
		"重连层正在显示，IssueReport 的 modal_stack 里却查不到 %s" % RECONNECT_ID)
	_h.expect(str(modal_section.get("top_id", "")) == RECONNECT_ID, "issue_report_top_wrong",
		"IssueReport 报告的栈顶不是 %s" % RECONNECT_ID)


# --- 4 / 5：双语文案与视觉尺寸；backdrop 既不关层也不取消 ----------------------

func _check_backdrop_and_locale(main: MainScript, nav: NavProbe) -> void:
	# --- 5 backdrop 实际事件 --------------------------------------------------
	# ⚠️ 只断言「层还在」是不可证伪的：这是强制层，就算 backdrop 真把它关掉，
	# 自愈也会在几帧内放回来。所以比对 content **实例本身**。
	var before_tap := _content()
	var nav_before := nav.count
	_tap_backdrop()
	await _settle(4)
	_h.expect(_entries() == 1, "backdrop_tap_closed_it",
		"点 backdrop 把重连层关掉了 —— 重连中唯一的出口应该只有取消按钮")
	_h.expect(before_tap != null and is_instance_valid(before_tap) and _content() == before_tap,
		"backdrop_tap_churned_content",
		("点 backdrop 之后 content 被销毁重建了 —— 说明 backdrop 其实关掉了这一层，"
			+ "只是自愈又把它放了回来"))
	_h.expect(nav.count == nav_before, "backdrop_tap_navigated",
		"点 backdrop 触发了取消导航")
	_h.expect(NetworkService.state == NetworkService.SessionState.RECONNECTING,
		"backdrop_tap_left_reconnecting", "点 backdrop 之后会话状态离开了 RECONNECTING")
	_h.expect(NetworkService.session_token == DUMMY_TOKEN, "backdrop_tap_cleared_token",
		"点 backdrop 把重连凭证清掉了")

	# --- 4 中英文文案与 260×48 -------------------------------------------------
	for locale in ["zh", "en"]:
		LocaleManager.set_locale(str(locale))
		# 关掉再开，让 content 用新语言重建（生产里换语言也走这条路）。
		_leave_reconnecting(NetworkService.SessionState.READY)
		await _settle(3)
		_enter_reconnecting()
		await _settle(3)
		var want_title := "Connection lost, reconnecting..." if str(locale) == "en" else "连接中断，正在重连…"
		var want_cancel := "Cancel and return to menu" if str(locale) == "en" else "取消并返回主菜单"
		var lbl: Label = main._reconnect_label
		var btn: Button = main._reconnect_cancel_button
		if not _h.expect(lbl != null and is_instance_valid(lbl)
				and btn != null and is_instance_valid(btn),
				"locale_widgets_missing", "%s 下拿不到标题或取消按钮" % str(locale)):
			continue
		_h.expect(lbl.text == want_title, "title_text_changed",
			"%s 标题是「%s」，应为「%s」" % [str(locale), lbl.text, want_title])
		_h.expect(btn.text == want_cancel, "cancel_text_changed",
			"%s 取消按钮是「%s」，应为「%s」" % [str(locale), btn.text, want_cancel])
		_h.expect(btn.custom_minimum_size == Vector2(260, 48), "cancel_size_changed",
			"取消按钮尺寸是 %s，应为 260×48" % str(btn.custom_minimum_size))
		_h.expect(lbl.get_theme_font_size("font_size") == 30, "title_font_changed",
			"标题字号是 %d，应为 30" % lbl.get_theme_font_size("font_size"))
	LocaleManager.set_locale("zh")


# --- 7：Back / close_all 不取消、不动凭证、不导航；仍重连中则 deferred 自愈 -----

func _check_external_close_never_cancels(main: MainScript, nav: NavProbe, base_depth: int) -> void:
	_leave_reconnecting(NetworkService.SessionState.READY)
	await _settle(3)
	NetworkService.session_token = DUMMY_TOKEN
	NetworkService.reconnect_address = DUMMY_ADDRESS
	GameState.team_mode = true
	_enter_reconnecting()
	await _settle(3)
	if not _h.expect(_entries() == 1, "external_close_setup_failed",
			"外部关闭用例前置：重连层没打开"):
		return

	for label in ["back", "close_all"]:
		var nav_before := nav.count
		if str(label) == "back":
			ModalStack.handle_back_request()
		else:
			ModalStack.close_all()
		await _settle(6)
		_h.expect(nav.count == nav_before, "external_close_navigated",
			"%s 关层触发了取消导航" % str(label))
		_h.expect(NetworkService.session_token == DUMMY_TOKEN, "external_close_cleared_token",
			"%s 关层把重连凭证清掉了 —— 玩家的对局就此丢失" % str(label))
		_h.expect(NetworkService.state == NetworkService.SessionState.RECONNECTING,
			"external_close_reset_session", "%s 关层把会话状态 reset 了" % str(label))
		_h.expect(GameState.team_mode, "external_close_cleared_team_mode",
			"%s 关层把 team_mode 改成了 false" % str(label))
		_h.expect(_entries() == 1, "external_close_did_not_restore",
			"%s 关层之后仍在重连，强制层却没有回来（栈里 %d 条）" % [str(label), _entries()])
		_h.expect(ModalStack.depth() == base_depth + 1, "restore_stacked",
			"%s 之后自愈成 %d 层，应仍只有一层" % [str(label), ModalStack.depth()])


# --- 6：state 离开 RECONNECTING 后 pop、引用置空、且不自愈 ---------------------

func _check_leaving_reconnecting_pops(main: MainScript) -> void:
	# READY 与 FAILED 分别是恢复成功 / 恢复失败之后的状态：
	# NetworkService 在 emit resume_completed / resume_failed 之前就已经改好 state，
	# 所以自愈读到的不是 RECONNECTING，面板不会在重连成功后又弹回来。
	for leaving in [NetworkService.SessionState.READY, NetworkService.SessionState.FAILED]:
		_enter_reconnecting()
		await _settle(3)
		if not _h.expect(_entries() == 1, "leave_setup_failed", "离开用例前置：层没打开"):
			continue
		_leave_reconnecting(leaving as NetworkService.SessionState)
		await _settle(4)
		_h.expect(_entries() == 0, "leave_did_not_pop",
			"state 离开 RECONNECTING（→ %d）之后层还在" % int(leaving))
		# ⚠️ Godot 4 里「已释放对象 == null」也是 true，只能用 typeof 区分：
		# 真 null 是 TYPE_NIL，悬空指针仍是 TYPE_OBJECT。
		_h.expect(typeof(main._reconnect_overlay) == TYPE_NIL, "overlay_ref_not_cleared",
			"关层后 _reconnect_overlay 仍指向已释放节点")
		_h.expect(typeof(main._reconnect_label) == TYPE_NIL, "label_ref_not_cleared",
			"关层后 _reconnect_label 仍指向已释放节点")
		_h.expect(typeof(main._reconnect_cancel_button) == TYPE_NIL, "button_ref_not_cleared",
			"关层后 _reconnect_cancel_button 仍指向已释放节点")
		await _settle(8)
		_h.expect(_entries() == 0, "reopened_after_leaving",
			"已经不在重连了，强制层却又自己回来了")

	# 直接调 hide（生产里 _on_resume_completed / _on_resume_failed 走的就是这一句）
	_enter_reconnecting()
	await _settle(3)
	_leave_reconnecting(NetworkService.SessionState.READY)
	await _settle(2)
	main._show_reconnect_overlay()
	await _settle(2)
	main._hide_reconnect_overlay()
	await _settle(6)
	_h.expect(_entries() == 0, "hide_did_not_pop", "_hide_reconnect_overlay() 之后层还在")


# --- 8：真实取消按钮连点 20 次，整条链只落地一次 -------------------------------

func _check_cancel_lands_once(main: MainScript, nav: NavProbe) -> void:
	NetworkService.session_token = DUMMY_TOKEN
	NetworkService.reconnect_address = DUMMY_ADDRESS
	NetworkService.team_active = true
	GameState.team_mode = true
	_enter_reconnecting()
	await _settle(3)
	if not _h.expect(_entries() == 1, "cancel_setup_failed", "取消用例前置：层没打开"):
		return

	var btn: Button = main._reconnect_cancel_button
	if not _h.expect(btn != null and is_instance_valid(btn), "cancel_button_missing",
			"取消用例拿不到按钮"):
		return
	var nav_before := nav.count
	for i in RAPID_TAPS:
		if is_instance_valid(btn):
			btn.pressed.emit()
	await _settle(4)

	_h.expect(nav.count == nav_before + 1, "cancel_navigated_more_than_once",
		"连点 %d 次触发了 %d 次返回主菜单，应恰好 1 次"
			% [RAPID_TAPS, nav.count - nav_before])
	_h.expect(_entries() == 0, "cancel_left_layer_open", "取消之后层没关")
	_h.expect(not GameState.team_mode, "cancel_left_team_mode",
		"取消之后 team_mode 仍是 true")
	_h.expect(NetworkService.session_token.is_empty(), "cancel_kept_token",
		"取消之后重连凭证没有被清掉 —— cancel_reconnect() 没有真的跑")
	_h.expect(NetworkService.state != NetworkService.SessionState.RECONNECTING,
		"cancel_left_reconnecting", "取消之后仍停在 RECONNECTING")
	await _settle(8)
	_h.expect(_entries() == 0, "reopened_after_cancel",
		"取消之后强制层又自己回来了 —— 玩家会被困在重连界面里")

	# 迟到的旧按钮实例：随 content 一起销毁，不得再取消或导航一次。
	var nav_after := nav.count
	if is_instance_valid(btn):
		btn.pressed.emit()
		await _settle(3)
	_h.expect(nav.count == nav_after, "late_button_navigated",
		"迟到的旧取消按钮又触发了一次导航")


# --- 10：热身后连续 20 次 show/hide 零增长 -------------------------------------

func _check_cycles_leave_nothing(main: MainScript, base_depth: int) -> void:
	# 先热身一轮吸收首次走这条路径的一次性懒初始化。
	_enter_reconnecting()
	await _settle(3)
	_leave_reconnecting(NetworkService.SessionState.READY)
	await _settle(4)

	var cycle_baseline := _snapshot()
	_h.note("热身后的基线：%s" % JSON.stringify(cycle_baseline))
	for i in CYCLES:
		_enter_reconnecting()
		await _settle(2)
		_leave_reconnecting(NetworkService.SessionState.READY)
		await _settle(2)
	await _settle(6)

	var after := _snapshot()
	_h.note("%d 轮后：%s" % [CYCLES, JSON.stringify(after)])
	_h.expect(int(after["modal_depth"]) == base_depth, "cycle_depth_drift",
		"%d 轮开关后 depth=%d，应回到 %d" % [CYCLES, int(after["modal_depth"]), base_depth])
	var grew := _growth(cycle_baseline, after)
	_h.expect(grew.is_empty(), "cycle_left_residue",
		"%d 轮开关之后相对热身基线仍有残留：%s" % [CYCLES, _describe(grew)])


# --- 9：owner 释放 --------------------------------------------------------------

func _check_owner_freed(main: MainScript, base_depth: int) -> void:
	NetworkService.session_token = DUMMY_TOKEN
	NetworkService.reconnect_address = DUMMY_ADDRESS
	_enter_reconnecting()
	await _settle(3)
	if not _h.expect(_entries() == 1, "owner_case_setup_failed",
			"owner 用例前置：层没打开"):
		main.queue_free()
		await _settle(6)
		return

	main.queue_free()
	await _settle(10)
	_h.expect(_entries() == 0, "survived_owner",
		"owner 已释放，栈里仍有 %s" % RECONNECT_ID)
	_h.expect(ModalStack.depth() == base_depth, "depth_after_owner_freed",
		"owner 释放后 depth=%d，应回到 %d" % [ModalStack.depth(), base_depth])
	var orphan := 0
	for child in get_tree().root.get_children():
		if str(child.name) == "Modal_%s" % RECONNECT_ID:
			orphan += 1
	_h.expect(orphan == 0, "orphan_host",
		"root 下还挂着 %d 个 Modal_%s CanvasLayer" % [orphan, RECONNECT_ID])
	_h.expect(ModalStack.find_invisible_stop_controls().is_empty(),
		"owner_left_invisible_stop", "owner 释放后残留了不可见 STOP 控件")
	# owner 没了就不该有孤儿层自己回来（凭证仍在、state 仍是 RECONNECTING）。
	await _settle(8)
	_h.expect(_entries() == 0, "restored_without_owner",
		"owner 已经释放，重连层却自己回来了 —— 那会是一个没人管的孤儿层")
	_h.expect(NetworkService.session_token == DUMMY_TOKEN, "owner_freed_cleared_token",
		"owner 释放把重连凭证清掉了 —— 下次进主菜单就再也接不回这一局")


# --- 11：源码合同 --------------------------------------------------------------

func _check_source_contract() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/main/Main.gd")
	if not _h.expect(not src.is_empty(), "source_unreadable", "读不到 Main.gd"):
		return
	_h.expect(not src.contains('_reconnect_overlay.name = "ReconnectOverlay"'),
		"raw_canvaslayer_returned",
		"源码里又自己建 ReconnectOverlay CanvasLayer 了 —— 层级应由 ModalStack 管")
	_h.expect(not src.contains("_reconnect_overlay.queue_free()"),
		"manual_free_returned",
		"源码里又用 _reconnect_overlay.queue_free() 管生命周期了 —— 所有权在 ModalStack")
	_h.expect(src.contains("_restore_reconnect_if_still_needed.call_deferred()"),
		"restore_not_deferred",
		("自愈没有走 call_deferred —— ModalStack.close_all() 是同步 while 循环，"
			+ "在 modal_closed 里直接 push 会让进程原地转死"))
	_h.expect(src.contains("OS.is_debug_build() and _reconnect_cancel_navigation_check_hook.is_valid()"),
		"seam_not_debug_guarded",
		"取消导航 seam 没有 OS.is_debug_build() 守卫，release 路径可达")


# --- 驱动与查询 ----------------------------------------------------------------

func _enter_reconnecting() -> void:
	NetworkService.state = NetworkService.SessionState.RECONNECTING
	NetworkService.session_changed.emit()


func _leave_reconnecting(to: NetworkService.SessionState) -> void:
	NetworkService.state = to
	NetworkService.session_changed.emit()


func _entries() -> int:
	var n := 0
	for row in ModalStack.dump_modal_stack():
		if str(row.get("id", "")) == RECONNECT_ID:
			n += 1
	return n


func _row() -> Dictionary:
	for row in ModalStack.dump_modal_stack():
		if str(row.get("id", "")) == RECONNECT_ID:
			return row
	return {}


func _host() -> Node:
	return get_tree().root.get_node_or_null(NodePath("Modal_%s" % RECONNECT_ID))


func _content() -> Control:
	var host := _host()
	if host == null:
		return null
	return host.get_node_or_null(NodePath("ModalRoot/ReconnectStatusOverlay")) as Control


func _backdrop() -> ColorRect:
	var host := _host()
	if host == null:
		return null
	return host.get_node_or_null(NodePath("ModalRoot/Backdrop")) as ColorRect


func _tap_backdrop() -> void:
	var backdrop := _backdrop()
	if backdrop == null:
		return
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	backdrop.gui_input.emit(press)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	backdrop.gui_input.emit(release)


# content 子树里**全屏**的 STOP 控件数。取消按钮当然要 STOP，
# 但绝不能再有第二块盖满视口的 STOP —— 那是 backdrop 一个人的职责。
func _fullscreen_stops(node: Node, vp: Vector2) -> int:
	var n := 0
	if node is Control:
		var c := node as Control
		if c.mouse_filter == Control.MOUSE_FILTER_STOP:
			var r := c.get_global_rect()
			if r.size.x >= vp.x - 1.0 and r.size.y >= vp.y - 1.0:
				n += 1
	for child in node.get_children():
		n += _fullscreen_stops(child, vp)
	return n


# --- 快照 ----------------------------------------------------------------------

func _snapshot() -> Dictionary:
	var counts := {"canvas_layers": 0, "stop_controls": 0, "timers": 0}
	_walk(get_tree().root, counts)
	return {
		"root_children": get_tree().root.get_child_count(),
		"canvas_layers": int(counts["canvas_layers"]),
		"stop_controls": int(counts["stop_controls"]),
		"invisible_stop": ModalStack.find_invisible_stop_controls().size(),
		"modal_depth": ModalStack.depth(),
		"timers": int(counts["timers"]),
		"signal_connections": NetworkService.session_changed.get_connections().size(),
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


# 只看正增长：残留是「多出来的」，少掉的不是泄漏。
func _growth(before: Dictionary, after: Dictionary) -> Dictionary:
	var out := {}
	for key in METRICS:
		var delta := int(after.get(key, 0)) - int(before.get(key, 0))
		if delta > 0:
			out[key] = delta
	return out


func _describe(d: Dictionary) -> String:
	var parts: Array[String] = []
	for key in d.keys():
		parts.append("%s %+d" % [str(key), int(d[key])])
	return ", ".join(parts)


func _settle(frames: int = 4) -> void:
	for i in frames:
		await get_tree().process_frame


# --- 用户文件与网络状态 ---------------------------------------------------------

func _snapshot_files() -> Dictionary:
	var out := {}
	for path in USER_FILES:
		out[path] = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else null
	return out


func _restore_files(snap: Dictionary) -> void:
	for path in snap.keys():
		var want = snap[path]
		if want == null:
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(path)
			continue
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_buffer(want)
			f = null


func _file_drift(snap: Dictionary) -> Array:
	var bad: Array = []
	for path in snap.keys():
		var want = snap[path]
		var exists := FileAccess.file_exists(path)
		if want == null:
			if exists:
				bad.append("%s 本来不存在，现在多出来了" % path)
			continue
		if not exists:
			bad.append("%s 不见了" % path)
			continue
		if FileAccess.get_file_as_bytes(path) != want:
			bad.append("%s 字节与开跑前不同" % path)
	return bad


func _issue_report_files() -> Array:
	var out: Array = []
	var dir := DirAccess.open("user://")
	if dir == null:
		return out
	for name in dir.get_files():
		if str(name).begins_with("issue_report_"):
			out.append("user://%s" % str(name))
	return out


func _save_network_state() -> Dictionary:
	return {
		"state": NetworkService.state,
		"team_active": NetworkService.team_active,
		"session_token": NetworkService.session_token,
		"reconnect_address": NetworkService.reconnect_address,
		"remote_port": NetworkService.remote_port,
		"team_local_slot": NetworkService.team_local_slot,
		"last_error": NetworkService.last_error,
	}


func _restore_network_state(saved: Dictionary) -> void:
	NetworkService.state = int(saved.get("state", NetworkService.SessionState.OFFLINE)) as NetworkService.SessionState
	NetworkService.team_active = bool(saved.get("team_active", false))
	NetworkService.session_token = str(saved.get("session_token", ""))
	NetworkService.reconnect_address = str(saved.get("reconnect_address", ""))
	NetworkService.remote_port = int(saved.get("remote_port", NetworkService.DEFAULT_PORT))
	NetworkService.team_local_slot = int(saved.get("team_local_slot", -1))
	NetworkService.last_error = str(saved.get("last_error", ""))
