extends Node

# V3 P2-04 scene / modal lifecycle leak gate.
#
# What it is actually looking for: the runtime residue a page leaves behind after
# the player has navigated away from it. The visible symptom is always the same
# and always blamed on something else — "the game got slow", "the button stopped
# working" — because an invisible MOUSE_FILTER_STOP sheet or a never-freed
# CanvasLayer does not announce itself.
#
# Real screens, real autoload services. A synthetic stand-in would prove that my
# stand-in does not leak, which is not the question. MainMenu and PrepScreen are
# instantiated the same way prep_detail_overlay_check does it, and dialogs go
# through the real DialogService -> ModalStack path.
#
# Measurement shape, and why it is not a widened allowlist: the first couple of
# cycles legitimately grow the process — resource caches fill, lazily-built
# singletons appear, theme resources land. That is one-time initialisation, not a
# per-cycle leak. So we burn WARMUP_CYCLES, snapshot, then require the next
# MEASURED_CYCLES to add exactly nothing. A leak of one node per cycle shows up
# as +20; a one-time cache does not show up at all. No metric is exempted, and
# no failure is suppressed — the baseline is taken later, not made looser.
#
# The lower-level owner-freed backstop is covered once in input_stress_check;
# this gate exercises the real DialogService -> ModalStack path and page cycles,
# so the two checks stay complementary rather than counting one contract twice.

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "modal_lifecycle"

const MENU_SCENE := "res://scenes/menu/MainMenu.tscn"
const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"
# 用 preload 常量做类型标注，下面对 PrepScreen 的调用才是**静态**调用。
# 按方法名派发会给 dynamic_call 的棘轮（191，只降不升）添丁 —— 检查工具本身
# 不该是让项目未受编译器检查的调用变多的那个。
const PrepScript := preload("res://scenes/prep/PrepScreen.gd")

# PvP 警告层的时间常量，与 PrepUI 里的保持一致；改那边这里要同步。
const PVP_WARNING_ID := "pvp_warning"
const TEAM_MERCS_ID := "team_mercs_review"
const MERC_PICKER_ID := "mercenary_picker"
const TREASURE_ID := "treasure_choice"
const TREASURE_PRIORITY := 70
# 与 TreasureChoicePanel.TREASURE_BACKDROP_COLOR 保持一致；改那边这里要同步。
const TREASURE_BACKDROP := Color(0.0, 0.0, 0.0, 0.66)
const PVP_WARNING_DWELL_SEC := 2.0
const PVP_WARNING_FADE_SEC := 0.18

# Cycles whose growth is treated as one-time initialisation.
const WARMUP_CYCLES := 2
# Cycles that must add nothing at all. The brief asks for at least 20.
const MEASURED_CYCLES := 20

# Every metric the V3 P2-04 brief lists, plus the two that make a leak legible
# (orphans, total nodes).
const METRICS: PackedStringArray = [
	"root_children", "canvas_layers", "stop_controls", "invisible_stop",
	"modal_depth", "dialog_open", "tweens", "timers", "signal_connections",
	"async_active", "orphans", "nodes",
]

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()
	await get_tree().process_frame

	await _check_detector_actually_detects()
	await _check_repeat_modal_is_one_modal()
	await _check_dialog_dismissed_outside_can_reopen()
	await _check_stale_request_cannot_clobber_new_one()
	await _check_pvp_warning_modal()
	await _check_team_mercs_modal()
	await _check_merc_picker_modal()
	await _check_treasure_choice_modal()
	_check_room_panel_is_modal()
	await _check_page_cycles_leave_nothing()
	await _check_final_state_is_clean()

	_h.finish(get_tree())


# --- snapshot ------------------------------------------------------------------

func _snapshot() -> Dictionary:
	var counts := {"canvas_layers": 0, "stop_controls": 0, "timers": 0}
	_walk(get_tree().root, counts)
	return {
		"root_children": get_tree().root.get_child_count(),
		"canvas_layers": int(counts["canvas_layers"]),
		"stop_controls": int(counts["stop_controls"]),
		"invisible_stop": ModalStack.find_invisible_stop_controls().size(),
		"modal_depth": ModalStack.depth(),
		"dialog_open": DialogService.open_count(),
		"tweens": get_tree().get_processed_tweens().size(),
		"timers": int(counts["timers"]),
		"signal_connections": _service_connection_count(),
		"async_active": int(AsyncActionController.dump_action_state().get("active_count", 0)),
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


# A page that forgets to disconnect keeps the shared autoload holding a reference
# to a dead object; the count is the cheapest way to see it.
func _service_connection_count() -> int:
	return (ModalStack.modal_opened.get_connections().size()
		+ ModalStack.modal_closed.get_connections().size()
		+ DialogService.dialog_resolved.get_connections().size()
		+ AsyncActionController.action_state_changed.get_connections().size()
		+ AsyncActionController.action_resolved.get_connections().size())


func _diff(before: Dictionary, after: Dictionary) -> Dictionary:
	var out := {}
	for key in METRICS:
		var delta := int(after.get(key, 0)) - int(before.get(key, 0))
		if delta != 0:
			out[key] = delta
	return out


# Residue means things that were ADDED and never cleaned up. A metric going down
# (a cache released, a node collected) is not a leak, and failing on it would
# make the gate red for good news.
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
		parts.append("%s%+d" % [key, int(d[key])])
	parts.sort()
	return ", ".join(parts)


func _settle(frames: int = 4) -> void:
	for _i in frames:
		await get_tree().process_frame


# --- 1. prove the detector can see a leak --------------------------------------

func _check_detector_actually_detects() -> void:
	# If find_invisible_stop_controls() silently returned [] the whole gate would
	# be decorative, so plant one and require it to be found.
	var trap := Control.new()
	trap.name = "InvisibleStopTrap"
	trap.mouse_filter = Control.MOUSE_FILTER_STOP
	trap.visible = false
	add_child(trap)
	await get_tree().process_frame

	var found: Array = ModalStack.find_invisible_stop_controls()
	var hit := false
	for path in found:
		if str(path).ends_with("InvisibleStopTrap"):
			hit = true
	_h.expect(hit, "stop_detector_blind",
		("种了一个不可见 STOP 控件，find_invisible_stop_controls() 没报出来（返回 %d 条）。"
		+ "探测器瞎了的话，下面所有泄漏断言都是装饰品。") % found.size())

	trap.queue_free()
	await _settle()
	_h.expect(not _paths_contain(ModalStack.find_invisible_stop_controls(),
			"InvisibleStopTrap"),
		"stop_detector_sticky", "陷阱控件已释放，探测器仍报着它")

	# Same for tweens: a tween the page forgot to kill must be visible to us.
	var host := Node.new()
	add_child(host)
	var tween := host.create_tween()
	tween.tween_interval(600.0)
	await get_tree().process_frame
	_h.expect(get_tree().get_processed_tweens().size() > 0, "tween_detector_blind",
		"起了一条长 tween，get_processed_tweens() 仍为空，tween 泄漏测不出来")
	tween.kill()
	host.queue_free()
	await _settle()


func _paths_contain(paths: Array, needle: String) -> bool:
	for p in paths:
		if str(p).contains(needle):
			return true
	return false


# --- 2. a repeated modal is one modal ------------------------------------------

func _check_repeat_modal_is_one_modal() -> void:
	var owner_node := Node.new()
	owner_node.name = "RepeatOwner"
	add_child(owner_node)

	var before := _snapshot()
	var ids: Array[String] = []
	for i in 10:
		ids.append(DialogService.confirm({
			"title": "t", "body": "b", "owner": owner_node,
			"request_id": "same_request",
		}))
	await _settle()

	for i in ids.size():
		_h.item()
		_h.expect(ids[i] == ids[0], "repeat_dialog_new_request",
			"第 %d 次重复请求拿到了不同 request_id" % (i + 1))
	_h.expect(DialogService.open_count() == 1, "repeat_dialog_stacked",
		"同一个 request_id 连点 10 次开出了 %d 个框" % DialogService.open_count())
	_h.expect(ModalStack.depth() == 1, "repeat_dialog_stacked_modals",
		"同一个 request_id 连点 10 次让模态栈到了 %d 层" % ModalStack.depth())

	DialogService.close(ids[0])
	owner_node.queue_free()
	await _settle(6)

	var leaked := _growth(before, _snapshot())
	_h.expect(leaked.is_empty(), "repeat_dialog_left_residue",
		"10 次重复弹窗请求关闭后残留：%s" % _describe(leaked))


# --- 2b. a dialog dismissed by tapping outside must be re-openable -------------

func _check_dialog_dismissed_outside_can_reopen() -> void:
	# Both production callers use a FIXED request_id on purpose, so that repeat
	# taps merge into one box:
	#   TutorialMode.SKIP_DIALOG_REQUEST = "tutorial_skip"
	#   MainMenu._show_coming_soon()     = "main_menu_coming_soon"   (8 hot zones; the chat one left for ChatScreen on 2026-09-11)
	# DialogService.info() also sets dismiss_on_backdrop=true for INFO intent.
	# So the dismiss-by-tapping-outside path is reachable in shipped builds today,
	# with no Back-key routing required (V3 P0-09 is still 未开始).
	var owner_node := Node.new()
	owner_node.name = "ReopenOwner"
	add_child(owner_node)

	const RID := "reopen_probe"
	var dismissals: Array[Dictionary] = []
	var on_result := func(result: String, request_id: String) -> void:
		dismissals.append({"result": result, "request_id": request_id})
	DialogService.confirm({
		"title": "t", "body": "b", "owner": owner_node,
		"request_id": RID, "intent": 2, "on_result": on_result,
	})
	await _settle(2)
	_h.expect(DialogService.is_open(RID), "reopen_setup_failed",
		"用例前置：第一次打开就失败了")

	# Dismiss it the way the modal layer does — straight through ModalStack, the
	# same call backdrop dismissal, the Back key and owner teardown all end in.
	ModalStack.close_top(ModalStack.REASON_BACKDROP)
	await _settle(3)

	_h.expect(ModalStack.depth() == 0, "reopen_modal_not_popped",
		"用例前置：模态没有被弹出")
	_h.expect(not DialogService.is_open(RID), "dialog_pending_survived_modal_close",
		("对话框已经被 ModalStack 关掉，DialogService._pending 里却还留着 %s。"
		+ "DialogService 必须同步 modal_closed；点框外、返回键、owner 释放和 close_all "
		+ "都必须清掉 pending，并且只结算一次 dismissed。") % RID)
	_h.expect(dismissals.size() == 1, "external_close_callback_count_wrong",
		"外部关窗后 on_result 调用了 %d 次，应为 1" % dismissals.size())
	if dismissals.size() == 1:
		_h.expect(str(dismissals[0].get("result", "")) == "dismissed",
			"external_close_result_wrong", "外部关窗应返回 dismissed，实际 %s"
				% str(dismissals[0].get("result", "")))
		_h.expect(str(dismissals[0].get("request_id", "")) == RID,
			"external_close_request_id_lost", "外部关窗回调丢失 request_id")

	# The consequence that a player actually feels.
	DialogService.confirm({
		"title": "t", "body": "b", "owner": owner_node,
		"request_id": RID, "intent": 2, "on_result": on_result,
	})
	await _settle(2)
	_h.expect(ModalStack.depth() == 1, "dialog_never_reopens_after_outside_tap",
		("点框外关掉之后，同一个 request_id 再也打不开对话框（depth=%d）。"
		+ "confirm() 在 `if _pending.has(request_id): return request_id` 处提前返回。"
		+ "玩家侧后果：主菜单「敬请期待」被点框外关掉一次后，那 9 个热区整局都不再出框；"
		+ "「跳过新手教学」同理。") % ModalStack.depth())

	# Leave nothing behind regardless of which way the assertions went.
	DialogService.close(RID)
	ModalStack.close_all()
	owner_node.queue_free()
	await _settle(4)


# --- 3. a stale request must not clobber the live one --------------------------

func _check_stale_request_cannot_clobber_new_one() -> void:
	var stale: String = AsyncActionController.begin("lifecycle_probe",
		{"owner": self, "cancellable": true, "timeout_msec": 30000})
	AsyncActionController.mark_pending(stale)
	AsyncActionController.cancel(stale, "user_left_page")

	var fresh: String = AsyncActionController.begin("lifecycle_probe",
		{"owner": self, "cancellable": true, "timeout_msec": 30000})
	_h.expect(fresh != stale, "new_request_reused_stale_id",
		"取消后新开的动作复用了旧 request_id")
	AsyncActionController.mark_pending(fresh)

	# The old page's网络回调 finally lands. It must not resolve the new request.
	_h.expect(not AsyncActionController.succeed(stale),
		"stale_request_resolved_after_cancel",
		"上一页遗留的成功回调被接受了")
	var snap: Dictionary = AsyncActionController.snapshot_for("lifecycle_probe")
	_h.expect(str(snap.get("request_id", "")) == fresh, "stale_request_replaced_current",
		"旧 request 的回调把当前 request 换掉了，现在是 %s" % str(snap.get("request_id", "")))
	_h.expect(str(snap.get("state", "")) == AsyncActionController.STATE_PENDING,
		"stale_request_changed_state",
		"旧 request 的回调改了新 request 的状态，现在是 %s" % str(snap.get("state", "")))

	AsyncActionController.cancel(fresh, "cleanup", true)
	AsyncActionController.reset("lifecycle_probe")
	await _settle()


# --- 3b. PvP 开战警告层（C-11 的 C5，V3 P0-07 / P1-03）--------------------------
#
# 迁移前这一层自己铺全屏 MOUSE_FILTER_STOP、自己 queue_free，带两个真实缺陷：
# 没有防叠守卫（2 秒内二次触发叠两层），以及 await 恢复后可能在已释放节点上动手。
# 下面三组就是钉住这两条，外加一条「模态期间必须能被 IssueReport 看见」。

func _new_prep() -> PrepScript:
	var packed := load(PREP_SCENE) as PackedScene
	if not _h.expect(packed != null, "pvp_prep_scene_load_failed",
			"%s 加载不出来" % PREP_SCENE):
		return null
	var prep: PrepScript = packed.instantiate() as PrepScript
	if not _h.expect(prep != null, "pvp_prep_wrong_type",
			"PrepScreen.tscn 实例化出来的不是 PrepScreen 脚本类型"):
		return null
	add_child(prep)
	return prep


func _pvp_entries() -> int:
	var n := 0
	for row in ModalStack.dump_modal_stack():
		if str(row.get("id", "")) == PVP_WARNING_ID:
			n += 1
	return n


# content 子树里不该再有任何 STOP：那是 ModalStack backdrop 的职责。
func _pvp_content_stop_count() -> int:
	var host := get_tree().root.get_node_or_null(NodePath("Modal_%s" % PVP_WARNING_ID))
	if host == null:
		return 0
	var content := host.get_node_or_null(NodePath("ModalRoot/PvPWarningOverlay"))
	if content == null:
		return 0
	var counts := {"canvas_layers": 0, "stop_controls": 0, "timers": 0}
	_walk(content, counts)
	return int(counts["stop_controls"])


func _wait_sec(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _check_pvp_warning_modal() -> void:
	ModalStack.close_all()
	await _settle(4)
	var baseline := _snapshot()
	var base_depth := int(baseline["modal_depth"])

	# --- A. 2 秒内重复触发，栈里只能有一个 -----------------------------------
	var prep_a := _new_prep()
	if prep_a == null:
		return
	await _settle(2)
	# 基准必须在 PrepScreen 建好**之后**取。备战页自带约 20 个隐藏的 STOP 面板
	# （_merc_overlay / _team_mercs_overlay / 宝藏层，正是 C-11 清点里的 C3/C4），
	# 拿建页之前的基准比，会把它们全算成本次警告的残留。
	var page_baseline := _snapshot()

	prep_a._show_pvp_warning_overlay()
	prep_a._show_pvp_warning_overlay()
	await _settle(3)

	# 前置：警告必须真的弹出来了。缺贴图时函数会静默 return，
	# 那样下面每条断言都会空过 —— 空过比红更危险。
	if not _h.expect(_pvp_entries() == 1, "pvp_warning_not_shown_once",
			"两次触发后栈里有 %d 个 %s，应为 1（0 = 根本没弹出来，2 = 去重失效）"
				% [_pvp_entries(), PVP_WARNING_ID]):
		prep_a.queue_free()
		await _settle(4)
		return

	_h.expect(ModalStack.depth() == base_depth + 1, "pvp_warning_stacked_twice",
		"2 秒内触发两次后 depth=%d，相对基线 %d 应只 +1 —— 同 id 去重失效"
			% [ModalStack.depth(), base_depth])

	# --- C（前半）. 模态期间必须可被 IssueReport / dump_modal_stack 看见 ------
	var seen_in_dump := false
	var in_tree := false
	for row in ModalStack.dump_modal_stack():
		if str(row.get("id", "")) == PVP_WARNING_ID:
			seen_in_dump = true
			in_tree = bool(row.get("in_tree", false))
	_h.expect(seen_in_dump, "pvp_warning_invisible_to_dump",
		"警告正在显示，dump_modal_stack() 里却查不到 %s —— IssueReport 会看不见它"
			% PVP_WARNING_ID)
	_h.expect(in_tree, "pvp_warning_not_in_tree",
		"%s 记在栈上却不在树里，玩家看不到它" % PVP_WARNING_ID)

	# 迁移的核心收益：全屏 STOP 只剩 ModalStack 那一块，content 自己不再拦。
	var content_stops := _pvp_content_stop_count()
	_h.expect(content_stops == 0, "pvp_warning_content_still_stops",
		("警告 content 子树里还有 %d 个 MOUSE_FILTER_STOP 控件 —— "
		+ "输入拦截应当只由 ModalStack 的 backdrop 负责") % content_stops)

	# 等完整生命周期（停留 + 淡出）自然结束。
	await _wait_sec(PVP_WARNING_DWELL_SEC + PVP_WARNING_FADE_SEC + 0.6)

	_h.expect(_pvp_entries() == 0, "pvp_warning_not_popped",
		"停留与淡出都结束了，栈里还有 %d 个 %s" % [_pvp_entries(), PVP_WARNING_ID])
	_h.expect(ModalStack.depth() == base_depth, "pvp_warning_depth_not_restored",
		"关闭后 depth=%d，未回到基线 %d" % [ModalStack.depth(), base_depth])

	# queue_free 在帧末回收，等几帧再快照，否则量到的是「还没收干净」而不是泄漏。
	await _settle(6)
	var after_warmup := _snapshot()

	# 不可见 STOP 是可以绝对判定的：警告这一轮不该新增一个。
	_h.expect(int(after_warmup["invisible_stop"]) <= int(page_baseline["invisible_stop"]),
		"pvp_warning_stop_residue",
		"警告关闭后，不可见 STOP 控件相对建页基准增加了：%d -> %d"
			% [int(page_baseline["invisible_stop"]), int(after_warmup["invisible_stop"])])

	# 节点总数要按「第二轮」量，不是第一轮。实测第一轮 +1、第二轮 +0 ——
	# 那 1 个是首次走这条路径的一次性懒初始化，不是每次触发都漏。
	# 这和本文件对页面循环用的是同一套方法论：先热身吸收一次性开销，
	# 再要求随后的一轮一点都不涨。基准取得更晚，不是判得更松。
	prep_a._show_pvp_warning_overlay()
	await _settle(3)
	_h.expect(_pvp_entries() == 1, "pvp_warning_second_cycle_not_shown",
		"第二轮触发没有弹出警告，增量测量会空过")
	await _wait_sec(PVP_WARNING_DWELL_SEC + PVP_WARNING_FADE_SEC + 0.6)
	await _settle(6)
	var after_a := _snapshot()

	var grew := _growth(after_warmup, after_a)
	_h.expect(grew.is_empty(), "pvp_warning_left_residue",
		"热身一轮之后再走一整轮，相对上一轮仍有残留：%s" % _describe(grew))

	prep_a.queue_free()
	await _settle(6)

	# --- B. owner 在停留期间被释放 -------------------------------------------
	ModalStack.close_all()
	await _settle(4)
	var b_base := int(_snapshot()["modal_depth"])

	var prep_b := _new_prep()
	if prep_b == null:
		return
	await _settle(2)
	prep_b._show_pvp_warning_overlay()
	await _settle(3)
	if not _h.expect(_pvp_entries() == 1, "pvp_warning_setup_b_failed",
			"用例 B 前置：警告没有弹出来"):
		prep_b.queue_free()
		await _settle(4)
		return

	# 停留 2 秒还没到就把宿主释放掉。
	await _wait_sec(0.4)
	prep_b.queue_free()
	await _settle(6)

	_h.expect(_pvp_entries() == 0, "pvp_warning_survived_owner",
		"owner 已释放，栈里仍有 %d 个 %s —— ModalStack 的 owner 兜底没生效"
			% [_pvp_entries(), PVP_WARNING_ID])
	_h.expect(ModalStack.depth() == b_base, "pvp_warning_depth_after_owner_freed",
		"owner 释放后 depth=%d，应回到 %d" % [ModalStack.depth(), b_base])

	# 关键的一步：**继续等到超过原协程的 2.0 + 0.18 秒**。
	# 如果迟到的协程在已释放节点上建 tween 或 queue_free，引擎错误会在这段时间里打出来，
	# 由 run_check.ps1 的 EngineErrorPatterns 判红（本门禁自己看不到引擎日志）。
	await _wait_sec(PVP_WARNING_DWELL_SEC + PVP_WARNING_FADE_SEC + 0.4)

	var after_b := _snapshot()
	_h.expect(_pvp_entries() == 0, "pvp_warning_late_resurrect",
		"迟到协程恢复后又往栈里放回了 %s" % PVP_WARNING_ID)
	_h.expect(ModalStack.depth() == b_base, "pvp_warning_late_depth_drift",
		"迟到协程跑完后 depth=%d，应仍为 %d" % [ModalStack.depth(), b_base])
	_h.expect(int(after_b["invisible_stop"]) <= int(baseline["invisible_stop"]),
		"pvp_warning_late_stop_residue",
		"owner 释放路径留下了不可见 STOP 控件：%d" % int(after_b["invisible_stop"]))
	var orphan_hosts := 0
	for child in get_tree().root.get_children():
		if str(child.name) == "Modal_%s" % PVP_WARNING_ID:
			orphan_hosts += 1
	_h.expect(orphan_hosts == 0, "pvp_warning_orphan_host",
		"root 下还挂着 %d 个 Modal_%s CanvasLayer" % [orphan_hosts, PVP_WARNING_ID])


# --- 3c. 组队佣兵检阅层（C-11 的 C4，V3 P0-07 / P1-03）--------------------------
#
# 这一层迁移前只盖 center_host，三条关闭路径（侧栏按钮、普通佣兵按钮、商店按钮）
# 全在它外面。迁进全屏 backdrop 的 ModalStack 之后那三条都会被挡住，所以关闭语义
# 改由 dismiss_on_backdrop 承担 —— 下面第 3 组就是钉住「玩家真的出得来」。

func _tm_entries() -> int:
	var n := 0
	for row in ModalStack.dump_modal_stack():
		if str(row.get("id", "")) == TEAM_MERCS_ID:
			n += 1
	return n


func _tm_row() -> Dictionary:
	for row in ModalStack.dump_modal_stack():
		if str(row.get("id", "")) == TEAM_MERCS_ID:
			return row
	return {}


func _tm_host() -> Node:
	return get_tree().root.get_node_or_null(NodePath("Modal_%s" % TEAM_MERCS_ID))


# content 子树里的 STOP 数。输入拦截应当只由 ModalStack 的 backdrop 负责。
func _tm_content_stop_count() -> int:
	var host := _tm_host()
	if host == null:
		return 0
	var content := host.get_node_or_null(NodePath("ModalRoot/TeamMercsReviewOverlay"))
	if content == null:
		return 0
	var counts := {"canvas_layers": 0, "stop_controls": 0, "timers": 0}
	_walk(content, counts)
	return int(counts["stop_controls"])


# 舞台内的 SubViewport / 3D 模型数，用来证明关闭后资源真的没了。
func _tm_stage_counts() -> Dictionary:
	var out := {"subviewports": 0, "node3d": 0, "anim_players": 0}
	var host := _tm_host()
	if host == null:
		return out
	_tm_walk3d(host, out)
	return out


func _tm_walk3d(node: Node, out: Dictionary) -> void:
	if node is SubViewport:
		out["subviewports"] = int(out["subviewports"]) + 1
	elif node is Node3D:
		out["node3d"] = int(out["node3d"]) + 1
	elif node is AnimationPlayer:
		out["anim_players"] = int(out["anim_players"]) + 1
	for child in node.get_children():
		_tm_walk3d(child, out)


# 模拟玩家「点内容矩形之外」：直接把主键释放事件送进栈顶 backdrop 的 gui_input，
# 走的是 ModalStack._on_backdrop_input 的真实路径，不是伪造状态。
func _tm_tap_backdrop() -> void:
	var host := _tm_host()
	if host == null:
		return
	var backdrop := host.get_node_or_null(NodePath("ModalRoot/Backdrop")) as Control
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


func _check_team_mercs_modal() -> void:
	ModalStack.close_all()
	await _settle(4)

	var prep := _new_prep()
	if prep == null:
		return
	await _settle(3)
	var page_baseline := _snapshot()
	var base_depth := int(page_baseline["modal_depth"])

	# --- 1. 打开：栈里恰好一条，owner 有效且 in-tree ---------------------------
	prep._toggle_team_mercs_picker()
	await _settle(3)

	if not _h.expect(_tm_entries() == 1, "tm_not_opened_once",
			"打开后栈里有 %d 条 %s，应为 1" % [_tm_entries(), TEAM_MERCS_ID]):
		prep.queue_free()
		await _settle(4)
		return

	var row := _tm_row()
	_h.expect(bool(row.get("in_tree", false)), "tm_not_in_tree",
		"%s 记在栈上却不在树里" % TEAM_MERCS_ID)
	_h.expect(bool(row.get("owner_valid", false)), "tm_owner_invalid",
		"%s 的 owner 无效 —— owner 兜底会失效" % TEAM_MERCS_ID)
	_h.expect(prep._team_mercs_open, "tm_business_state_desync_open",
		"模态开着但 _team_mercs_open 是 false")

	# --- 2. backdrop 是唯一的全屏 STOP，content 子树 STOP 数为 0 ---------------
	_h.expect(str(row.get("backdrop_filter", "")) == "STOP", "tm_backdrop_not_stop",
		"栈顶 backdrop 不是 STOP，点击会漏到下面的备战页")
	var content_stops := _tm_content_stop_count()
	_h.expect(content_stops == 0, "tm_content_still_stops",
		"content 子树里还有 %d 个 STOP 控件 —— 拦截应当只由 backdrop 负责" % content_stops)
	_h.expect(int(_snapshot()["invisible_stop"]) <= int(page_baseline["invisible_stop"]),
		"tm_invisible_stop_grew",
		"打开检阅台之后多出了不可见 STOP 控件")

	# 舞台资源确实建起来了，否则下面「关闭后归零」是空过。
	var open_counts := _tm_stage_counts()
	_h.expect(int(open_counts["subviewports"]) == 1, "tm_subviewport_missing",
		"打开后 content 里有 %d 个 SubViewport，应为 1" % int(open_counts["subviewports"]))

	# --- 3. 玩家的关闭路径：点内容矩形之外 -------------------------------------
	_tm_tap_backdrop()
	await _settle(4)
	_h.expect(_tm_entries() == 0, "tm_backdrop_tap_did_not_close",
		"点 backdrop 之后模态还在 —— 玩家被困在这一层里出不来")
	_h.expect(not prep._team_mercs_open, "tm_business_state_desync_close",
		"模态已关但 _team_mercs_open 仍是 true")
	_h.expect(int(_tm_stage_counts()["subviewports"]) == 0, "tm_subviewport_survived",
		"关闭后 SubViewport 仍在")
	_h.expect(prep._team_mercs_render_timer != null
			and prep._team_mercs_render_timer.is_stopped(),
		"tm_timer_still_running", "关闭后 30Hz 渲染计时器仍在跑")

	# --- 4. 外部 close_all 也要同步业务状态 ------------------------------------
	prep._toggle_team_mercs_picker()
	await _settle(3)
	_h.expect(_tm_entries() == 1, "tm_reopen_failed", "关闭后重新打开失败")
	ModalStack.close_all()
	await _settle(4)
	_h.expect(_tm_entries() == 0, "tm_close_all_left_entry", "close_all 之后栈里还有它")
	_h.expect(not prep._team_mercs_open, "tm_close_all_state_desync",
		"close_all 关掉了模态，_team_mercs_open 却还是 true")
	_h.expect(prep._team_mercs_render_timer != null
			and prep._team_mercs_render_timer.is_stopped(),
		"tm_close_all_timer_running", "close_all 之后计时器仍在跑")

	# --- 6. 网络刷新：开着时照常刷新，关着时不得复活模态或重启计时器 -----------
	prep._on_team_prep_mercs_changed()
	await _settle(3)
	_h.expect(_tm_entries() == 0, "tm_network_refresh_resurrected",
		"关闭状态下收到网络刷新，模态被重新拉起来了")
	_h.expect(prep._team_mercs_render_timer.is_stopped(),
		"tm_network_refresh_restarted_timer",
		"关闭状态下收到网络刷新，计时器被重新启动")

	prep._toggle_team_mercs_picker()
	await _settle(3)
	prep._on_team_prep_mercs_changed()
	await _settle(3)
	_h.expect(_tm_entries() == 1, "tm_network_refresh_closed_modal",
		"打开状态下收到网络刷新，模态反而没了")
	_h.expect(not prep._team_mercs_render_timer.is_stopped(),
		"tm_network_refresh_stopped_timer",
		"打开状态下收到网络刷新，计时器被停掉了")

	# --- 8. 与 pvp_warning 的优先级顺序 ----------------------------------------
	prep._show_pvp_warning_overlay()
	await _settle(3)
	if _pvp_entries() == 1:
		_h.expect(ModalStack.top_id() == PVP_WARNING_ID, "tm_priority_order_wrong",
			("检阅台(40) 与 pvp_warning(60) 同时在栈上时，栈顶是 %s，"
			+ "应为 %s —— 优先级阶梯反了") % [ModalStack.top_id(), PVP_WARNING_ID])
		ModalStack.pop(PVP_WARNING_ID, ModalStack.REASON_PROGRAMMATIC)
		await _settle(3)
		_h.expect(_tm_entries() == 1, "tm_broken_by_sibling_pop",
			"关掉 pvp_warning 把检阅台也带走了")
		_h.expect(prep._team_mercs_open, "tm_state_broken_by_sibling_pop",
			"关掉 pvp_warning 之后检阅台的业务状态被改坏了")
	else:
		_h.note("pvp_warning 未能弹出（多半缺贴图），优先级顺序这一组跳过")

	prep._close_team_mercs_picker()
	await _settle(4)

	# --- 7. 连续 20 次开关，零增长 --------------------------------------------
	# 先热身一轮吸收首次走这条路径的一次性懒初始化，与本文件既有方法论一致。
	prep._toggle_team_mercs_picker()
	await _settle(3)
	prep._close_team_mercs_picker()
	await _settle(4)
	var cycle_baseline := _snapshot()

	for i in 20:
		prep._toggle_team_mercs_picker()
		await _settle(2)
		prep._close_team_mercs_picker()
		await _settle(2)
		if i == 0 or i == 19:
			_h.expect(_tm_entries() == 0, "tm_cycle_left_modal",
				"第 %d 轮关闭后栈里还有 %s" % [i + 1, TEAM_MERCS_ID])
	await _settle(6)

	var after_cycles := _snapshot()
	_h.expect(int(after_cycles["modal_depth"]) == base_depth, "tm_cycle_depth_drift",
		"20 轮开关后 depth=%d，应回到 %d" % [int(after_cycles["modal_depth"]), base_depth])
	var grew := _growth(cycle_baseline, after_cycles)
	_h.expect(grew.is_empty(), "tm_cycle_left_residue",
		"20 轮开关之后相对热身基线仍有残留：%s" % _describe(grew))
	_h.expect(int(_tm_stage_counts()["subviewports"]) == 0, "tm_cycle_subviewport_leak",
		"20 轮之后仍有 SubViewport 残留")

	# --- 5. owner 在打开期间被释放 --------------------------------------------
	prep._toggle_team_mercs_picker()
	await _settle(3)
	if not _h.expect(_tm_entries() == 1, "tm_owner_case_setup_failed",
			"owner 用例前置：检阅台没打开"):
		prep.queue_free()
		await _settle(4)
		return
	prep.queue_free()
	await _settle(8)

	_h.expect(_tm_entries() == 0, "tm_survived_owner",
		"owner 已释放，栈里仍有 %s" % TEAM_MERCS_ID)
	_h.expect(ModalStack.depth() == base_depth, "tm_depth_after_owner_freed",
		"owner 释放后 depth=%d，应回到 %d" % [ModalStack.depth(), base_depth])
	var orphan := 0
	for child in get_tree().root.get_children():
		if str(child.name) == "Modal_%s" % TEAM_MERCS_ID:
			orphan += 1
	_h.expect(orphan == 0, "tm_orphan_host",
		"root 下还挂着 %d 个 Modal_%s CanvasLayer" % [orphan, TEAM_MERCS_ID])
	_h.expect(int(_snapshot()["invisible_stop"]) <= int(page_baseline["invisible_stop"]),
		"tm_owner_freed_stop_residue",
		"owner 释放路径留下了不可见 STOP 控件")


# --- 4. the cycle ---------------------------------------------------------------

# --- 普通佣兵选择层（C-11 的 C3，V3 P0-07 / P1-03）------------------------------
#
# 与 C4 检阅台的关键差别：这一层 content 里有 12 张**可点击**的佣兵卡。
# 所以 content 根保留 STOP（它只占 center_host 矩形、不是全屏），卡片正常收输入；
# 全屏 STOP 仍然只有 ModalStack 的 backdrop 那一块。

func _mp_entries() -> int:
	var n := 0
	for row in ModalStack.dump_modal_stack():
		if str(row.get("id", "")) == MERC_PICKER_ID:
			n += 1
	return n


func _mp_host() -> Node:
	return get_tree().root.get_node_or_null(NodePath("Modal_%s" % MERC_PICKER_ID))


func _mp_content() -> Control:
	var host := _mp_host()
	if host == null:
		return null
	return host.get_node_or_null(NodePath("ModalRoot/MercPickerOverlay")) as Control


func _mp_grid() -> GridContainer:
	var content := _mp_content()
	if content == null:
		return null
	var found: Array[GridContainer] = []
	_mp_find_grid(content, found)
	return null if found.is_empty() else found[0]


func _mp_find_grid(node: Node, out: Array[GridContainer]) -> void:
	if node is GridContainer:
		out.append(node as GridContainer)
		return
	for child in node.get_children():
		_mp_find_grid(child, out)


func _mp_filled_slots() -> int:
	var n := 0
	for cell in GameState.mercenary_slots:
		if cell != null:
			n += 1
	return n


# 送一次主键按下+释放到栈顶 backdrop，走 ModalStack._on_backdrop_input 的真实路径。
func _mp_tap_backdrop() -> void:
	var host := _mp_host()
	if host == null:
		return
	var backdrop := host.get_node_or_null(NodePath("ModalRoot/Backdrop")) as Control
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


# 雇佣兵这一下该扣的那种货币的余额（规则见第 7 组的注释：教学局金币、正式局萝卜）。
func _mp_currency() -> int:
	return GameState.gold if GameState.tutorial_mode else GameState.carrots


func _mp_currency_name() -> String:
	return "金币" if GameState.tutorial_mode else "萝卜"


func _check_merc_picker_modal() -> void:
	ModalStack.close_all()
	await _settle(4)

	# 购买用例会改 GameState，先整份快照，用例结束逐字还原。
	var gold_before := GameState.gold
	var slots_before: Array = GameState.mercenary_slots.duplicate(true)

	var prep := _new_prep()
	if prep == null:
		return
	await _settle(3)
	var page_baseline := _snapshot()
	var base_depth := int(page_baseline["modal_depth"])

	# --- 4（关闭态）教程目标应是入口按钮 --------------------------------
	var closed_target := prep._tutorial_target_hire_mercenary()
	_h.expect(closed_target != null and is_instance_valid(closed_target),
		"mp_tutorial_target_closed_invalid", "关闭状态下教程目标无效")

	# --- 1 打开：稳定 id 存在，depth 只 +1 -------------------------------
	prep._toggle_merc_picker()
	await _settle(3)
	if not _h.expect(_mp_entries() == 1, "mp_not_opened_once",
			"打开后栈里有 %d 条 %s，应为 1" % [_mp_entries(), MERC_PICKER_ID]):
		prep.queue_free()
		await _settle(4)
		GameState.gold = gold_before
		return
	_h.expect(ModalStack.depth() == base_depth + 1, "mp_depth_not_plus_one",
		"打开后 depth=%d，相对基线 %d 应只 +1" % [ModalStack.depth(), base_depth])
	_h.expect(prep._merc_picker_open, "mp_state_desync_open",
		"模态开着但 _merc_picker_open 是 false")

	# --- 2 连点 10 次仍只有一层 -----------------------------------------------
	for i in 10:
		prep._refresh_mercenary_overlay()
	await _settle(3)
	_h.expect(_mp_entries() == 1, "mp_repeat_open_stacked",
		"重复调用 10 次后栈里有 %d 条，应仍为 1" % _mp_entries())
	_h.expect(ModalStack.depth() == base_depth + 1, "mp_repeat_open_grew_depth",
		"重复调用 10 次后 depth=%d，应仍是 %d" % [ModalStack.depth(), base_depth + 1])

	# --- 3 content 在正确矩形，样式与 4 列网格都在 -----------------------------
	var content := _mp_content()
	if not _h.expect(content != null, "mp_content_missing",
			"栈里有条目但找不到 MercPickerOverlay content"):
		prep.queue_free()
		await _settle(4)
		GameState.gold = gold_before
		return
	var vp := get_viewport().get_visible_rect().size
	var rect := content.get_global_rect()
	_h.expect(rect.size.x > 0.0 and rect.size.y > 0.0, "mp_content_rect_empty",
		"content 矩形是空的：%s" % str(rect))
	_h.expect(rect.size.x < vp.x, "mp_content_went_fullscreen",
		("content 宽度 %.0f 已铺满视口 %.0f —— 迁移前它只占 center_host 那一列"
			% [rect.size.x, vp.x]))
	var grid := _mp_grid()
	_h.expect(grid != null, "mp_grid_missing", "content 里找不到 GridContainer")
	if grid != null:
		_h.expect(grid.columns == 4, "mp_grid_columns_changed",
			"佣兵网格是 %d 列，应为 4 列" % grid.columns)
		_h.expect(grid.get_child_count() > 0, "mp_grid_empty",
			"网格里一张卡都没有，下面的教程目标与购买断言会空过")
	_h.expect(content.mouse_filter == Control.MOUSE_FILTER_STOP,
		"mp_content_root_not_stop",
		("content 根不是 STOP —— 卡片之间的间隙会穿透到 backdrop，"
			+ "玩家挑佣兵时误触就会把面板关掉"))
	_h.expect(content.has_theme_stylebox_override("panel"), "mp_style_lost",
		"content 的 StyleBoxFlat 边框样式丢了")
	var row := {}
	for r in ModalStack.dump_modal_stack():
		if str(r.get("id", "")) == MERC_PICKER_ID:
			row = r
	_h.expect(str(row.get("backdrop_filter", "")) == "STOP", "mp_backdrop_not_stop",
		"栈顶 backdrop 不是 STOP，点击会漏到下面的备战页")
	_h.expect(bool(row.get("owner_valid", false)), "mp_owner_invalid",
		"%s 的 owner 无效 —— owner 兜底会失效" % MERC_PICKER_ID)

	# --- 4（打开态）教程目标必须是当前 content 里有效的第一张卡 ----------------
	var open_target := prep._tutorial_target_hire_mercenary()
	_h.expect(open_target != null and is_instance_valid(open_target),
		"mp_tutorial_target_open_invalid",
		"打开状态下教程目标无效 —— 极可能返回了已释放的实例")
	if grid != null and grid.get_child_count() > 0:
		_h.expect(open_target == grid.get_child(0), "mp_tutorial_target_not_first_card",
			"打开状态下教程目标不是当前 content 的第一张佣兵卡")
	_h.expect(open_target != closed_target, "mp_tutorial_target_did_not_change",
		"开合两态返回了同一个目标")

	# --- 7 购买一次，只发生一次扣费/槽位变化 -----------------------------
	# 雇佣兵花哪种货币由规则决定（PrepBoardController._hire_mercenary_to_slot）：
	# 教学局扣金币，正式局扣萝卜 —— docs/萝卜采集与升级石系统设计实施方案.md：
	# 「所有购买按钮和服务端交易改读 carrot_cost」。所以这里只验「恰好扣了一次」，
	# 不把货币写死。上一版写死了金币，萝卜经济上线后这一条红了一周（2026-09-11 改）。
	# 萝卜与累计消费在这一组结束时逐字还原；金币由用例末尾那次整体还原负责。
	var carrots_before := GameState.carrots
	var carrots_spent_before := GameState.merc_carrots_spent_total
	GameState.gold = 9999
	GameState.carrots = 9999
	prep._refresh_mercenary_overlay()
	await _settle(3)
	grid = _mp_grid()
	var buyable: BaseButton = null
	if grid != null:
		for child in grid.get_children():
			if child is BaseButton and bool((child as BaseButton).get_meta("can_purchase", false)):
				buyable = child as BaseButton
				break
	if buyable != null:
		var paid_pre := _mp_currency()
		var filled_pre := _mp_filled_slots()
		buyable.pressed.emit()
		await _settle(3)
		var filled_post := _mp_filled_slots()
		_h.expect(filled_post == filled_pre + 1, "mp_purchase_slot_delta_wrong",
			"一次点击后佣兵槽由 %d 变成 %d，应恰好 +1" % [filled_pre, filled_post])
		_h.expect(_mp_currency() < paid_pre, "mp_purchase_not_charged",
			"一次购买后%s没有扣除：%d -> %d" % [_mp_currency_name(), paid_pre, _mp_currency()])
		# 买完面板必须还开着：backdrop 迁移后最容易出的倒退就是「买一个就被关掉」。
		_h.expect(_mp_entries() == 1, "mp_closed_by_purchase",
			"买一名佣兵之后面板被关掉了 —— 玩家连买两个要重开两次")
		_h.expect(prep._merc_picker_open, "mp_state_desync_after_purchase",
			"购买后 _merc_picker_open 与栈不一致")
		# 刷新是幂等的：重复刷不会再扣一次钱、也不会再占一个槽。
		var paid_settled := _mp_currency()
		for i in 5:
			prep._refresh_mercenary_overlay()
		await _settle(3)
		_h.expect(_mp_currency() == paid_settled, "mp_refresh_charged_again",
			"重复刷新面板又扣了一次%s：%d -> %d" % [_mp_currency_name(), paid_settled, _mp_currency()])
		_h.expect(_mp_filled_slots() == filled_post, "mp_refresh_hired_again",
			"重复刷新面板又雇了一个人")
	else:
		_h.note("没有可购买的佣兵卡（多半是槽位已满或数据表为空），购买这一组跳过")
	GameState.carrots = carrots_before
	GameState.merc_carrots_spent_total = carrots_spent_before

	# --- 6 与组队佣兵层双向互斥 -----------------------------------------------
	prep._toggle_team_mercs_picker()
	await _settle(3)
	_h.expect(_mp_entries() == 0, "mp_not_closed_by_team_mercs",
		"打开组队佣兵层之后，普通佣兵层还在栈上")
	_h.expect(not prep._merc_picker_open, "mp_state_desync_after_team_open",
		"组队佣兵层已接管，_merc_picker_open 仍是 true")
	prep._toggle_merc_picker()
	await _settle(3)
	_h.expect(_tm_entries() == 0, "mp_team_mercs_not_closed",
		"打开普通佣兵层之后，组队佣兵检阅台还在栈上")
	_h.expect(_mp_entries() == 1, "mp_reopen_failed", "互斥切换后普通佣兵层没打开")

	# --- 5 三条关闭路径都同步业务状态并清引用 ---------------------------
	_mp_tap_backdrop()
	await _settle(4)
	_h.expect(_mp_entries() == 0, "mp_backdrop_tap_did_not_close",
		"点 backdrop 之后面板还在 —— 玩家的关闭路径断了")
	_h.expect(not prep._merc_picker_open, "mp_state_desync_backdrop",
		"backdrop 关闭后 _merc_picker_open 仍是 true")
	# Godot 4 里 `已释放对象 == null` 也是 true，所以这里必须用 typeof 才可证伪：
	# 真的置空是 TYPE_NIL，悬空指针仍是 TYPE_OBJECT。
	_h.expect(typeof(prep._merc_overlay) == TYPE_NIL, "mp_ref_not_cleared_backdrop",
		"backdrop 关闭后 _merc_overlay 仍指向已释放节点（未置空）")
	_h.expect(typeof(prep._merc_count_label) == TYPE_NIL, "mp_count_label_not_cleared",
		"backdrop 关闭后 _merc_count_label 仍指向已释放节点（未置空）")

	prep._toggle_merc_picker()
	await _settle(3)
	prep._close_merc_picker()
	await _settle(4)
	_h.expect(_mp_entries() == 0 and not prep._merc_picker_open,
		"mp_programmatic_close_failed", "程序化关闭没有生效")

	prep._toggle_merc_picker()
	await _settle(3)
	ModalStack.close_all()
	await _settle(4)
	_h.expect(_mp_entries() == 0, "mp_close_all_left_entry", "close_all 之后栈里还有它")
	_h.expect(not prep._merc_picker_open, "mp_state_desync_close_all",
		"close_all 关掉了模态，_merc_picker_open 却还是 true")
	_h.expect(typeof(prep._merc_overlay_grid) == TYPE_NIL, "mp_grid_ref_not_cleared",
		"close_all 之后 _merc_overlay_grid 仍指向已释放节点（未置空）")

	# --- 8 连续 20 次开关零增长 -----------------------------------------------
	# 先热身一轮吸收首次走这条路径的一次性懒初始化，与本文件既有方法论一致。
	prep._toggle_merc_picker()
	await _settle(3)
	prep._close_merc_picker()
	await _settle(4)
	var cycle_baseline := _snapshot()
	for i in MEASURED_CYCLES:
		prep._toggle_merc_picker()
		await _settle(2)
		prep._close_merc_picker()
		await _settle(2)
	await _settle(6)
	var after_cycles := _snapshot()
	_h.expect(int(after_cycles["modal_depth"]) == base_depth, "mp_cycle_depth_drift",
		"%d 轮开关后 depth=%d，应回到 %d"
			% [MEASURED_CYCLES, int(after_cycles["modal_depth"]), base_depth])
	var grew := _growth(cycle_baseline, after_cycles)
	_h.expect(grew.is_empty(), "mp_cycle_left_residue",
		"%d 轮开关之后相对热身基线仍有残留：%s" % [MEASURED_CYCLES, _describe(grew)])

	# --- 9 owner 在面板打开时释放 ---------------------------------------------
	prep._toggle_merc_picker()
	await _settle(3)
	if _h.expect(_mp_entries() == 1, "mp_owner_case_setup_failed",
			"owner 用例前置：面板没打开"):
		prep.queue_free()
		await _settle(8)
		_h.expect(_mp_entries() == 0, "mp_survived_owner",
			"owner 已释放，栈里仍有 %s" % MERC_PICKER_ID)
		_h.expect(ModalStack.depth() == base_depth, "mp_depth_after_owner_freed",
			"owner 释放后 depth=%d，应回到 %d" % [ModalStack.depth(), base_depth])
		var orphan := 0
		for child in get_tree().root.get_children():
			if str(child.name) == "Modal_%s" % MERC_PICKER_ID:
				orphan += 1
		_h.expect(orphan == 0, "mp_orphan_host",
			"root 下还挂着 %d 个 Modal_%s CanvasLayer" % [orphan, MERC_PICKER_ID])
	else:
		prep.queue_free()
		await _settle(6)

	# --- 10 生产源码不再用 visible 当生命周期 ---------------------------------
	var ui_src := FileAccess.get_file_as_string("res://scenes/prep/PrepUI.gd")
	_h.expect(not ui_src.is_empty(), "mp_source_unreadable", "读不到 PrepUI.gd")
	_h.expect(not ui_src.contains("_merc_overlay.visible = _merc_picker_open"),
		"mp_visible_lifecycle_returned",
		"源码里又出现了 `_merc_overlay.visible = _merc_picker_open` —— 生命周期回到了 visible 开关")

	# --- 还原 GameState -------------------------------------------------------
	GameState.gold = gold_before
	for i in mini(slots_before.size(), GameState.mercenary_slots.size()):
		GameState.mercenary_slots[i] = slots_before[i]
	var filled_orig := 0
	for cell in slots_before:
		if cell != null:
			filled_orig += 1
	_h.expect(GameState.gold == gold_before, "mp_gold_not_restored",
		"测试结束后金币未还原：%d != %d" % [GameState.gold, gold_before])
	_h.expect(_mp_filled_slots() == filled_orig, "mp_slots_not_restored",
		"测试结束后佣兵槽未还原：%d != %d" % [_mp_filled_slots(), filled_orig])


# --- 宝藏三选一层（C-11 的 C2，V3 P0-07 / P1-03）--------------------------------
#
# 这一层与前三层的根本差别：它是**强制选择层**。
# GameState.pending_treasure.active 是玩法状态，不是 UI 状态 ——
# 外部关掉这一层不等于玩家做出了选择，所以关层不得清 pending、不得 claim、
# 不得白送宝物；而且只要 pending 仍 active、owner 仍有效，层就必须自己回来。

# 单机真实选宝会落盘两处：SaveManager 的存档（含 .bak 轮转）和 PlayerProfile
# 的图鉴档案（add_owned -> mark_seen -> save_profile）。两处都要逐字还原，
# 否则跑一次门禁就在开发者的真实档案里永久多解锁一条图鉴。
const TC_USER_FILES: PackedStringArray = [
	"user://glory_beta_004.save",
	"user://glory_beta_004.save.bak",
	"user://profile.json",
]


func _tc_snapshot_files() -> Dictionary:
	var out := {}
	for path in TC_USER_FILES:
		out[path] = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else null
	return out


func _tc_restore_files(snap: Dictionary) -> void:
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
	# 原子写的中间文件：正常路径下已被 rename 掉，异常中断时可能残留。
	for path in TC_USER_FILES:
		if FileAccess.file_exists(path + ".tmp"):
			DirAccess.remove_absolute(path + ".tmp")


# 返回与快照不一致的文件描述；空数组表示逐字还原成功。
func _tc_file_drift(snap: Dictionary) -> Array:
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


func _tc_entries() -> int:
	var n := 0
	for row in ModalStack.dump_modal_stack():
		if str(row.get("id", "")) == TREASURE_ID:
			n += 1
	return n


func _tc_row() -> Dictionary:
	for row in ModalStack.dump_modal_stack():
		if str(row.get("id", "")) == TREASURE_ID:
			return row
	return {}


func _tc_host() -> Node:
	return get_tree().root.get_node_or_null(NodePath("Modal_%s" % TREASURE_ID))


func _tc_content() -> Control:
	var host := _tc_host()
	if host == null:
		return null
	return host.get_node_or_null(NodePath("ModalRoot/TreasureChoiceOverlay")) as Control


func _tc_backdrop() -> ColorRect:
	var host := _tc_host()
	if host == null:
		return null
	return host.get_node_or_null(NodePath("ModalRoot/Backdrop")) as ColorRect


# content 子树里**全屏**的 STOP 控件数。卡片和刷新按钮当然要 STOP，
# 但绝不能再有第二块盖满视口的 STOP —— 那是 backdrop 一个人的职责。
func _tc_fullscreen_stops(node: Node, vp: Vector2) -> int:
	var n := 0
	if node is Control:
		var c := node as Control
		if c.mouse_filter == Control.MOUSE_FILTER_STOP:
			var r := c.get_global_rect()
			if r.size.x >= vp.x - 1.0 and r.size.y >= vp.y - 1.0:
				n += 1
	for child in node.get_children():
		n += _tc_fullscreen_stops(child, vp)
	return n


func _tc_cards(prep: PrepScript) -> Array:
	var row: Control = prep._treasure._treasure_choice_row
	if row == null or not is_instance_valid(row):
		return []
	return row.get_children()


func _tc_tap_backdrop() -> void:
	var backdrop := _tc_backdrop()
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


func _tc_money_ids(count: int) -> Array:
	var out: Array = []
	for raw in DataRegistry.get_table("treasures").get("treasures", []):
		var t: Dictionary = raw
		if str(t.get("category", "")) == "money":
			out.append(str(t.get("id", "")))
		if out.size() >= count:
			break
	return out


# 把 pending 摆成「这一轮有三个候选待选」。round 取 2：非 0 才会被 claim 记账。
#
# 先按生产路径把上一层关干净再开新的一层：直接换 pending 而不关层的话，
# 待定锁会留在上一轮的状态里（生产里那是由 offer_changed / grant / deny 结算的），
# 下一组用例点卡片就会静默无效。
func _tc_arm_pending(prep: PrepScript) -> void:
	GameState.pending_treasure.active = false
	prep._treasure.refresh()
	GameState.pending_treasure = {
		"active": true,
		"round": 2,
		"candidates": TreasureService.roll_candidates(3),
		"refresh_index": 0,
	}
	prep._treasure.refresh()


func _check_treasure_choice_modal() -> void:
	ModalStack.close_all()
	await _settle(4)

	# --- 全量快照：三个用户文件 + 所有会被本用例改到的运行时状态 ---------------
	var files_before := _tc_snapshot_files()
	var gold_before := GameState.gold
	var owned_before: Array = GameState.owned_treasures.duplicate()
	var claimed_before: Array = GameState.claimed_treasure_rounds.duplicate()
	var pending_before: Dictionary = GameState.pending_treasure.duplicate(true)
	var team_before: bool = NetworkService.team_active

	GameState.pending_treasure = {"active": false, "round": 0, "candidates": [], "refresh_index": 0}
	GameState.owned_treasures.clear()
	GameState.claimed_treasure_rounds.clear()
	GameState.gold = 1000
	NetworkService.team_active = false

	var prep := _new_prep()
	if prep == null:
		_tc_restore_files(files_before)
		return
	await _settle(3)
	var page_baseline := _snapshot()
	var base_depth := int(page_baseline["modal_depth"])
	var vp := get_viewport().get_visible_rect().size

	# --- 1 pending 未激活时不该有这一层 ---------------------------------------
	_h.expect(_tc_entries() == 0, "tc_open_while_inactive",
		"pending 是 inactive，栈里却已经有 %s" % TREASURE_ID)

	# --- 1 激活：恰好一层，owner 有效、在树上、priority=70 ---------------------
	_tc_arm_pending(prep)
	await _settle(3)
	if not _h.expect(_tc_entries() == 1, "tc_not_opened_once",
			"pending 激活后栈里有 %d 条 %s，应为 1" % [_tc_entries(), TREASURE_ID]):
		prep.queue_free()
		await _settle(4)
		GameState.pending_treasure = pending_before.duplicate(true)
		_tc_restore_files(files_before)
		return
	var row := _tc_row()
	_h.expect(ModalStack.depth() == base_depth + 1, "tc_depth_not_plus_one",
		"打开后 depth=%d，相对基线 %d 应只 +1" % [ModalStack.depth(), base_depth])
	_h.expect(int(row.get("priority", -1)) == TREASURE_PRIORITY, "tc_priority_wrong",
		"priority=%s，应为 %d（高于 pvp_warning=60、低于战斗加载 80）"
			% [str(row.get("priority", "?")), TREASURE_PRIORITY])
	_h.expect(bool(row.get("in_tree", false)), "tc_not_in_tree",
		"记在栈上却不在树里 —— 界面其实没显示出来")
	_h.expect(bool(row.get("owner_valid", false)), "tc_owner_invalid",
		"owner 无效 —— owner 兜底会失效")

	# --- 2 连续刷新 10 次仍只有一层 -------------------------------------------
	for i in 5:
		prep._treasure.refresh()
		prep._refresh_all()
	await _settle(3)
	_h.expect(_tc_entries() == 1, "tc_repeat_refresh_stacked",
		"_treasure.refresh()/_refresh_all() 各 5 次后栈里有 %d 条，应仍为 1" % _tc_entries())
	_h.expect(ModalStack.depth() == base_depth + 1, "tc_repeat_refresh_grew_depth",
		"重复刷新后 depth=%d，应仍是 %d" % [ModalStack.depth(), base_depth + 1])

	# --- 3 三张卡、原尺寸、标题、刷新按钮、backdrop 颜色、只有 backdrop 全屏 STOP
	var content := _tc_content()
	if not _h.expect(content != null, "tc_content_missing",
			"栈里有条目但找不到 TreasureChoiceOverlay content"):
		prep.queue_free()
		await _settle(4)
		GameState.pending_treasure = pending_before.duplicate(true)
		_tc_restore_files(files_before)
		return
	var cards := _tc_cards(prep)
	_h.expect(cards.size() == 3, "tc_card_count_changed",
		"候选卡有 %d 张，应为 3 张" % cards.size())
	for card in cards:
		if card is Control:
			_h.expect((card as Control).custom_minimum_size == Vector2(437, 582),
				"tc_card_size_changed",
				"卡片尺寸变成 %s，应为 437×582" % str((card as Control).custom_minimum_size))
	_h.expect(prep._treasure._treasure_timer_lbl != null
			and prep._treasure._treasure_timer_lbl.text == tr("ui_treasure_pick"),
		"tc_title_lost", "标题文案不是 ui_treasure_pick")
	_h.expect(prep._treasure._treasure_refresh_btn != null
			and prep._treasure._treasure_refresh_btn.custom_minimum_size == Vector2(220, 46),
		"tc_refresh_button_changed", "刷新按钮不见了或尺寸变了（应 220×46）")
	var backdrop := _tc_backdrop()
	_h.expect(backdrop != null and backdrop.color.is_equal_approx(TREASURE_BACKDROP),
		"tc_backdrop_color_changed",
		"backdrop 颜色是 %s，应为迁移前那块浮层的 Color(0,0,0,0.66)"
			% ("(无)" if backdrop == null else str(backdrop.color)))
	_h.expect(str(row.get("backdrop_filter", "")) == "STOP", "tc_backdrop_not_stop",
		"栈顶 backdrop 不是 STOP，卡片缝隙的点击会漏到下面的备战页")
	var extra_stops := _tc_fullscreen_stops(content, vp)
	_h.expect(extra_stops == 0, "tc_content_has_fullscreen_stop",
		"content 子树里还有 %d 个全屏 STOP —— 全屏拦截只能由 backdrop 一处负责" % extra_stops)
	_h.expect(int(_snapshot()["invisible_stop"]) <= int(page_baseline["invisible_stop"]),
		"tc_invisible_stop_grew", "打开三选一之后多出了不可见 STOP 控件")

	# --- 11 长按详情的挂接仍在（见交接：show_detail 目前是空实现）--------------
	var with_long_press := 0
	for card in cards:
		if card is BaseButton:
			var timer = (card as BaseButton).get_meta("long_press_timer", null)
			if timer != null and is_instance_valid(timer) and timer is Timer:
				with_long_press += 1
	_h.expect(with_long_press == cards.size(), "tc_long_press_lost",
		"%d/%d 张卡还挂着长按计时器 —— 迁移不能把长按详情的接线弄丢"
			% [with_long_press, cards.size()])

	# --- 10 教程目标就是当前 content 里的第一张卡 -----------------------------
	var target_a := prep._tutorial_target_treasure_choice()
	_h.expect(target_a != null and is_instance_valid(target_a), "tc_tutorial_target_invalid",
		"打开状态下教程取宝目标无效")
	if not cards.is_empty():
		_h.expect(target_a == cards[0], "tc_tutorial_target_not_first_card",
			"教程取宝目标不是当前 content 的第一张卡")
	# 重建一次：旧卡必须失效，新目标必须有效 —— 这正是迁移最容易漏的死引用来源。
	prep._treasure.refresh()
	await _settle(3)
	var target_b := prep._tutorial_target_treasure_choice()
	_h.expect(not is_instance_valid(target_a), "tc_old_card_survived_rebuild",
		"重建之后旧卡仍然有效 —— 说明旧 content 没被销毁")
	_h.expect(target_b != null and is_instance_valid(target_b), "tc_tutorial_target_stale",
		"重建之后教程目标失效 —— 教程会拿到已释放的实例")

	# --- 4 backdrop 点击不得关闭，pending 不变 --------------------------------
	# ⚠️ 只断言「层还在」是不可证伪的 —— 就算 backdrop 真把它关掉了，
	# 强制层的自愈也会在几帧内把它放回来。所以这里比对 content **实例本身**：
	# 没被关过，实例就必须是同一个。
	var content_before_tap := _tc_content()
	_tc_tap_backdrop()
	await _settle(4)
	_h.expect(_tc_entries() == 1, "tc_backdrop_tap_closed_it",
		"点 backdrop 把强制选择层关掉了 —— 玩家可以不选宝物就跳过这一轮")
	_h.expect(content_before_tap != null and is_instance_valid(content_before_tap)
			and _tc_content() == content_before_tap,
		"tc_backdrop_tap_churned_content",
		("点 backdrop 之后 content 被销毁重建了 —— 说明 backdrop 其实关掉了这一层，"
			+ "只是自愈又把它放了回来。玩家会看到面板闪一下，强制选择也被绕过了一瞬。"))
	_h.expect(bool(GameState.pending_treasure.get("active", false)), "tc_backdrop_tap_cleared_pending",
		"点 backdrop 之后 pending_treasure.active 变成了 false")

	# --- 5 Back / close_all 都不能跳过选择，且 settle 后自愈 -------------------
	ModalStack.handle_back_request()
	await _settle(6)
	_h.expect(bool(GameState.pending_treasure.get("active", false)), "tc_back_cleared_pending",
		"Back 关层之后 pending 被清了 —— 这一轮宝物白送掉了")
	_h.expect(_tc_entries() == 1, "tc_back_did_not_restore",
		"Back 关层后强制选择层没有回来（栈里 %d 条）" % _tc_entries())
	var owned_after_back := GameState.owned_treasures.size()
	_h.expect(owned_after_back == 0, "tc_back_granted_treasure",
		"Back 关层竟然让玩家白拿了 %d 件宝物" % owned_after_back)
	_h.expect(GameState.claimed_treasure_rounds.is_empty(), "tc_back_claimed_round",
		"Back 关层就把这一轮 claim 掉了 —— 玩家再也抽不到这一轮的宝物")

	ModalStack.close_all()
	await _settle(6)
	_h.expect(bool(GameState.pending_treasure.get("active", false)), "tc_close_all_cleared_pending",
		"close_all 之后 pending 被清了")
	_h.expect(_tc_entries() == 1, "tc_close_all_did_not_restore",
		"close_all 之后强制选择层没有回来（栈里 %d 条）" % _tc_entries())
	_h.expect(ModalStack.depth() == base_depth + 1, "tc_restore_stacked",
		"自愈之后 depth=%d，应仍只有一层（%d）" % [ModalStack.depth(), base_depth + 1])

	# --- 9 刷新：普通费用精确扣一次 -------------------------------------------
	GameState.gold = 1000
	prep._treasure.refresh()
	await _settle(2)
	var cost := TreasureService.refresh_cost(
		int(GameState.pending_treasure.get("refresh_index", 0)), TreasureService.has_set("money"))
	var cands_before: Array = (GameState.pending_treasure.get("candidates", []) as Array).duplicate()
	var idx_before := int(GameState.pending_treasure.get("refresh_index", 0))
	prep._treasure._treasure_refresh_btn.pressed.emit()
	await _settle(3)
	_h.note("刷新实测：金币 1000 -> %d（费用 %d），refresh_index %d -> %d"
		% [GameState.gold, cost, idx_before,
			int(GameState.pending_treasure.get("refresh_index", 0))])
	_h.expect(GameState.gold == 1000 - cost, "tc_refresh_cost_wrong",
		"一次刷新后金币 %d，应为 %d（扣 %d）" % [GameState.gold, 1000 - cost, cost])
	_h.expect(int(GameState.pending_treasure.get("refresh_index", 0)) == idx_before + 1,
		"tc_refresh_index_wrong", "refresh_index 没有 +1")
	_h.expect((GameState.pending_treasure.get("candidates", []) as Array) != cands_before,
		"tc_refresh_candidates_same", "刷新之后候选没变")
	_h.expect(_tc_entries() == 1, "tc_refresh_closed_layer",
		"刷新一次把面板关掉了")

	# --- 9 金币不足：零变化 ---------------------------------------------------
	var poor_cost := TreasureService.refresh_cost(
		int(GameState.pending_treasure.get("refresh_index", 0)), TreasureService.has_set("money"))
	GameState.gold = poor_cost - 1
	prep._treasure.refresh()
	await _settle(2)
	var poor_idx := int(GameState.pending_treasure.get("refresh_index", 0))
	var poor_cands: Array = (GameState.pending_treasure.get("candidates", []) as Array).duplicate()
	prep._treasure._treasure_refresh_btn.pressed.emit()
	await _settle(3)
	_h.expect(GameState.gold == poor_cost - 1, "tc_refresh_charged_when_poor",
		"金币不足时仍然扣了钱：%d != %d" % [GameState.gold, poor_cost - 1])
	_h.expect(int(GameState.pending_treasure.get("refresh_index", 0)) == poor_idx,
		"tc_refresh_indexed_when_poor", "金币不足时 refresh_index 仍然前进了")
	_h.expect((GameState.pending_treasure.get("candidates", []) as Array) == poor_cands,
		"tc_refresh_rolled_when_poor", "金币不足时候选仍然被重摇了")

	# --- 9 Money 四件套：费用为 0 ---------------------------------------------
	var money_ids := _tc_money_ids(4)
	if money_ids.size() == 4:
		# 直接写 owned，不走 add_owned —— 那条路会 mark_seen 并落盘 profile.json。
		for tid in money_ids:
			GameState.owned_treasures.append(str(tid))
		_h.expect(TreasureService.has_set("money"), "tc_money_set_not_detected",
			"塞了 4 件 money 类宝物，has_set(\"money\") 仍是 false")
		_h.expect(TreasureService.refresh_cost(
				int(GameState.pending_treasure.get("refresh_index", 0)), true) == 0,
			"tc_money_cost_not_free", "Money 套装下刷新费用不是 0")
		GameState.gold = 0
		GameState.pending_treasure.candidates = TreasureService.roll_candidates(3)
		prep._treasure.refresh()
		await _settle(2)
		_h.expect(not prep._treasure._treasure_refresh_btn.disabled,
			"tc_money_refresh_disabled",
			"Money 套装时费用为 0，刷新按钮却因为没钱被禁用了")
		_h.expect(prep._treasure._treasure_refresh_btn.text == tr("ui_treasure_refresh_free"),
			"tc_money_refresh_text", "Money 套装时刷新按钮没有显示免费文案")
		GameState.owned_treasures.clear()
	else:
		_h.note("数据表里 money 类宝物不足 4 件，Money 免费这一组跳过")

	# --- 8 联机：不乐观入袋，一次意图合同 -------------------------------------
	# request_treasure_choice 内部有 `multiplayer_peer != null` 守卫，
	# headless 下是空操作 —— 不会发真实 RPC、不改协议。
	NetworkService.team_active = true
	GameState.gold = 1000
	GameState.owned_treasures.clear()
	_tc_arm_pending(prep)
	await _settle(3)
	var intents := [0]
	var counter := func(_tid: String) -> void: intents[0] += 1
	prep._treasure.pick_requested.connect(counter)
	var net_cards := _tc_cards(prep)
	if net_cards.size() > 0 and net_cards[0] is BaseButton:
		for i in 5:
			(net_cards[0] as BaseButton).pressed.emit()
		await _settle(3)
		_h.expect(intents[0] == 1, "tc_online_multiple_intents",
			"联机等待 grant 期间连点 5 次发出了 %d 次选择意图，应只有 1 次" % intents[0])
		_h.expect(GameState.owned_treasures.is_empty(), "tc_online_optimistic_grant",
			"联机选宝乐观入袋了 %d 件 —— 必须等服务端 grant" % GameState.owned_treasures.size())
		_h.expect(bool(GameState.pending_treasure.get("active", false)),
			"tc_online_cleared_pending", "联机只发了意图，pending 就被清成 false 了")
		_h.expect(_tc_entries() == 1, "tc_online_closed_layer",
			"联机只发了意图，面板就关掉了 —— 服务端还没授权")
		_h.expect(GameState.claimed_treasure_rounds.is_empty(), "tc_online_claimed_early",
			"联机只发了意图就把这一轮 claim 掉了")
		# UI 自愈不是服务端结算：Back / close_all 关闭并恢复同一轮候选时，
		# 首次选择意图仍在等待 grant/deny，不能因此解锁再发第二份。
		ModalStack.handle_back_request()
		await _settle(6)
		var back_cards := _tc_cards(prep)
		if not back_cards.is_empty() and back_cards[0] is BaseButton:
			for i in 5:
				(back_cards[0] as BaseButton).pressed.emit()
		await _settle(3)
		_h.expect(intents[0] == 1, "tc_online_back_unlocked_pending",
			"联机等待 grant/deny 时按 Back 并恢复后又发出选择意图（共 %d 次）" % intents[0])

		ModalStack.close_all()
		await _settle(6)
		var close_all_cards := _tc_cards(prep)
		if not close_all_cards.is_empty() and close_all_cards[0] is BaseButton:
			for i in 5:
				(close_all_cards[0] as BaseButton).pressed.emit()
		await _settle(3)
		_h.expect(intents[0] == 1, "tc_online_close_all_unlocked_pending",
			"联机等待 grant/deny 时 close_all 并恢复后又发出选择意图（共 %d 次）" % intents[0])
		# 待定锁必须能解开，否则一次丢包就把三张卡永久锁死。
		prep._treasure.clear_pick_pending()
		if not close_all_cards.is_empty() and close_all_cards[0] is BaseButton:
			(close_all_cards[0] as BaseButton).pressed.emit()
		await _settle(2)
		_h.expect(intents[0] == 2, "tc_lock_never_clears",
			"clear_pick_pending() 之后再点仍然发不出意图 —— 网络失败会把按钮永久锁死")
		# 没回包也不能永久锁死：超过生产合同的 5 秒后，玩家再次点击可重试一次。
		prep._treasure._pick_pending_since_msec = Time.get_ticks_msec() - 5001
		if not close_all_cards.is_empty() and close_all_cards[0] is BaseButton:
			(close_all_cards[0] as BaseButton).pressed.emit()
		await _settle(2)
		_h.expect(intents[0] == 3, "tc_lock_retry_timeout_missing",
			"选择意图 5 秒无回包后仍不能有限重试（共 %d 次，应为 3）" % intents[0])
	else:
		_h.note("联机用例没有拿到候选卡，这一组跳过")
	prep._treasure.pick_requested.disconnect(counter)
	NetworkService.team_active = false

	# --- 7 单机真实选一次：只加一件、只 claim 一次、层关闭且不自愈 -------------
	GameState.owned_treasures.clear()
	GameState.claimed_treasure_rounds.clear()
	GameState.gold = 1000
	_tc_arm_pending(prep)
	await _settle(3)
	var pick_cards := _tc_cards(prep)
	if pick_cards.size() > 0 and pick_cards[0] is BaseButton:
		var picked_tid := str((GameState.pending_treasure.get("candidates", []) as Array)[0])
		var stale_card := pick_cards[0] as BaseButton
		stale_card.pressed.emit()
		await _settle(4)
		_h.expect(GameState.owned_treasures.size() == 1, "tc_pick_owned_delta_wrong",
			"选一件之后持有 %d 件，应恰好 1 件" % GameState.owned_treasures.size())
		_h.expect(GameState.owned_treasures.has(picked_tid), "tc_pick_wrong_treasure",
			"入袋的不是点的那一件（点了 %s，袋里是 %s）"
				% [picked_tid, str(GameState.owned_treasures)])
		_h.note("单机选宝实测：选中 %s，持有 0 -> %d 件，claim %d 次，active=%s，栈内 %d 层"
			% [picked_tid, GameState.owned_treasures.size(),
				GameState.claimed_treasure_rounds.size(),
				str(GameState.pending_treasure.get("active", false)), _tc_entries()])
		_h.expect(GameState.claimed_treasure_rounds.size() == 1, "tc_claim_count_wrong",
			"claim 了 %d 次，应恰好 1 次" % GameState.claimed_treasure_rounds.size())
		_h.expect(not bool(GameState.pending_treasure.get("active", true)),
			"tc_pick_left_pending_active", "选完之后 pending 仍是 active")
		_h.expect(_tc_entries() == 0, "tc_pick_left_layer_open",
			"选完之后面板没关")
		# 自愈只在「还没选」时生效：选完了再等几帧也不能把层放回来。
		await _settle(8)
		_h.expect(_tc_entries() == 0, "tc_reopened_after_pick",
			"选完之后强制层又自己回来了 —— 玩家会被要求再选一次")
		# 关层后四个瞬时引用都必须真的置空。⚠️ Godot 4 里「已释放对象 == null」
		# 也是 true，只能用 typeof 区分：真 null 是 TYPE_NIL，悬空指针仍是 TYPE_OBJECT。
		_h.expect(typeof(prep._treasure._treasure_overlay) == TYPE_NIL,
			"tc_overlay_ref_not_cleared", "关层后 _treasure_overlay 仍指向已释放节点")
		_h.expect(typeof(prep._treasure._treasure_choice_row) == TYPE_NIL,
			"tc_row_ref_not_cleared", "关层后 _treasure_choice_row 仍指向已释放节点")
		_h.expect(typeof(prep._treasure._treasure_timer_lbl) == TYPE_NIL,
			"tc_title_ref_not_cleared", "关层后 _treasure_timer_lbl 仍指向已释放节点")
		_h.expect(typeof(prep._treasure._treasure_refresh_btn) == TYPE_NIL,
			"tc_refresh_ref_not_cleared", "关层后 _treasure_refresh_btn 仍指向已释放节点")
		# 迟到/重复点击：旧卡已随 content 销毁，不得再加第二件。
		if is_instance_valid(stale_card):
			stale_card.pressed.emit()
			await _settle(3)
		_h.expect(GameState.owned_treasures.size() == 1, "tc_late_click_granted_second",
			"迟到的重复点击又发了一件宝物（现在 %d 件）" % GameState.owned_treasures.size())
	else:
		_h.note("单机选宝用例没有拿到候选卡，这一组跳过")

	# --- 12 连续 20 次开/正常关，零增长 ---------------------------------------
	# 先热身一轮吸收首次走这条路径的一次性懒初始化，与本文件既有方法论一致。
	GameState.owned_treasures.clear()
	GameState.claimed_treasure_rounds.clear()
	_tc_arm_pending(prep)
	await _settle(3)
	GameState.pending_treasure.active = false
	prep._treasure.refresh()
	await _settle(4)
	var cycle_baseline := _snapshot()
	_h.note("宝藏层热身后的基线：%s" % JSON.stringify(cycle_baseline))
	for i in MEASURED_CYCLES:
		GameState.pending_treasure.active = true
		prep._treasure.refresh()
		await _settle(2)
		GameState.pending_treasure.active = false
		prep._treasure.refresh()
		await _settle(2)
	await _settle(6)
	var after_cycles := _snapshot()
	_h.note("宝藏层 %d 轮后：%s" % [MEASURED_CYCLES, JSON.stringify(after_cycles)])
	_h.expect(int(after_cycles["modal_depth"]) == base_depth, "tc_cycle_depth_drift",
		"%d 轮开关后 depth=%d，应回到 %d"
			% [MEASURED_CYCLES, int(after_cycles["modal_depth"]), base_depth])
	var grew := _growth(cycle_baseline, after_cycles)
	_h.expect(grew.is_empty(), "tc_cycle_left_residue",
		"%d 轮开关之后相对热身基线仍有残留：%s" % [MEASURED_CYCLES, _describe(grew)])

	# --- 6 owner 在 active 时释放：清栈不清 pending ---------------------------
	_tc_arm_pending(prep)
	await _settle(3)
	if _h.expect(_tc_entries() == 1, "tc_owner_case_setup_failed",
			"owner 用例前置：面板没打开"):
		prep.queue_free()
		await _settle(10)
		_h.expect(_tc_entries() == 0, "tc_survived_owner",
			"owner 已释放，栈里仍有 %s" % TREASURE_ID)
		_h.expect(ModalStack.depth() == base_depth, "tc_depth_after_owner_freed",
			"owner 释放后 depth=%d，应回到 %d" % [ModalStack.depth(), base_depth])
		var orphan := 0
		for child in get_tree().root.get_children():
			if str(child.name) == "Modal_%s" % TREASURE_ID:
				orphan += 1
		_h.expect(orphan == 0, "tc_orphan_host",
			"root 下还挂着 %d 个 Modal_%s CanvasLayer" % [orphan, TREASURE_ID])
		_h.expect(ModalStack.find_invisible_stop_controls().is_empty(),
			"tc_owner_left_invisible_stop", "owner 释放后残留了不可见 STOP 控件")
		_h.expect(bool(GameState.pending_treasure.get("active", false)),
			"tc_owner_freed_cleared_pending",
			"owner 释放把 pending 清了 —— 玩家重进备战页就再也抽不到这一轮")
	else:
		prep.queue_free()
		await _settle(6)

	# ⚠️ 后面还有 _check_page_cycles_leave_nothing 要建 22 次备战页。
	# pending 留在 active 会让强制层次次弹出、close_all 又把它救回来，整套断言崩掉。
	GameState.pending_treasure = {"active": false, "round": 0, "candidates": [], "refresh_index": 0}
	ModalStack.close_all()
	await _settle(6)
	_h.expect(_tc_entries() == 0, "tc_still_open_at_teardown",
		"用例收尾时 %s 还在栈上" % TREASURE_ID)

	# --- 13 生产源码不再用 visible 管生命周期 ---------------------------------
	var src := FileAccess.get_file_as_string("res://scenes/prep/panels/TreasureChoicePanel.gd")
	_h.expect(not src.is_empty(), "tc_source_unreadable", "读不到 TreasureChoicePanel.gd")
	_h.expect(not src.contains("_treasure_overlay.visible = active"),
		"tc_visible_lifecycle_returned",
		"源码里又出现了 `_treasure_overlay.visible = active` —— 生命周期回到了 visible 开关")

	# --- 还原：先运行时状态，再三个用户文件，最后逐字校验 ---------------------
	GameState.gold = gold_before
	GameState.owned_treasures.clear()
	for tid in owned_before:
		GameState.owned_treasures.append(str(tid))
	GameState.claimed_treasure_rounds.clear()
	for r in claimed_before:
		GameState.claimed_treasure_rounds.append(int(r))
	GameState.pending_treasure = pending_before.duplicate(true)
	NetworkService.team_active = team_before
	_tc_restore_files(files_before)
	var drift := _tc_file_drift(files_before)
	_h.expect(drift.is_empty(), "tc_user_files_not_restored",
		"测试结束后用户文件没有逐字还原：%s" % ", ".join(drift))
	_h.expect(GameState.gold == gold_before, "tc_gold_not_restored",
		"测试结束后金币未还原：%d != %d" % [GameState.gold, gold_before])
	_h.expect(GameState.owned_treasures.size() == owned_before.size(),
		"tc_owned_not_restored", "测试结束后持有宝物数未还原")
	_h.expect(not bool(GameState.pending_treasure.get("active", false)),
		"tc_pending_left_active", "测试结束时 pending 仍是 active，会污染后面的用例")


func _run_one_cycle(index: int) -> void:
	# menu -> dialog -> close -> leave
	var menu := _instantiate(MENU_SCENE)
	if menu != null:
		add_child(menu)
		await _settle(2)
		var did: String = DialogService.confirm({
			"title": "cycle", "body": "%d" % index, "owner": menu,
			"request_id": "cycle_menu_%d" % index,
		})
		await get_tree().process_frame
		DialogService.close(did)
		await get_tree().process_frame
		menu.queue_free()
		await _settle(3)

	# prep -> dialog closed properly, plus a plain modal closed by Back -> leave
	var prep := _instantiate(PREP_SCENE)
	if prep != null:
		add_child(prep)
		await _settle(2)
		var pid: String = DialogService.confirm({
			"title": "cycle", "body": "%d" % index, "owner": prep,
			"request_id": "cycle_prep_%d" % index,
		})
		await get_tree().process_frame
		DialogService.close(pid)
		await get_tree().process_frame

		# Back is exercised on a bare ModalStack modal here so the cycle covers both
		# service-managed dialogs and the lower-level ModalStack contract.
		var content := Control.new()
		content.name = "CycleModal_%d" % index
		ModalStack.push(content, {"id": "cycle_modal_%d" % index, "owner": prep})
		await get_tree().process_frame
		ModalStack.handle_back_request()
		await get_tree().process_frame

		prep.queue_free()
		await _settle(3)


func _instantiate(path: String) -> Node:
	var packed := load(path) as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "%s 加载不出来" % path):
		return null
	var node := packed.instantiate()
	if not _h.expect(node != null, "scene_instantiate_failed", "%s 实例化失败" % path):
		return null
	return node


func _check_page_cycles_leave_nothing() -> void:
	for i in WARMUP_CYCLES:
		await _run_one_cycle(i)
	await _settle(8)

	# Baseline taken AFTER warm-up: one-time caches are already paid for.
	var baseline := _snapshot()
	_h.note("热身 %d 轮后的基线：%s" % [WARMUP_CYCLES, JSON.stringify(baseline)])

	var worst := {}
	for i in MEASURED_CYCLES:
		await _run_one_cycle(WARMUP_CYCLES + i)
		await _settle(4)
		var after := _snapshot()

		# Per-cycle: nothing may be left open at all.
		_h.expect(int(after["modal_depth"]) == 0, "cycle_left_modal_open",
			"第 %d 轮结束时模态栈还有 %d 层" % [i + 1, int(after["modal_depth"])])
		_h.expect(int(after["dialog_open"]) == 0, "cycle_left_dialog_open",
			"第 %d 轮结束时还有 %d 个对话框没关" % [i + 1, int(after["dialog_open"])])
		_h.expect(int(after["invisible_stop"]) == 0, "cycle_left_invisible_stop",
			"第 %d 轮结束时树上有 %d 个不可见 STOP 控件，之后的点击会被它吃掉"
				% [i + 1, int(after["invisible_stop"])])
		_h.expect(int(after["async_active"]) == 0, "cycle_left_action_active",
			"第 %d 轮结束时还有 %d 个动作停在 PRESSED/PENDING"
				% [i + 1, int(after["async_active"])])

		for key in METRICS:
			var delta := int(after.get(key, 0)) - int(baseline.get(key, 0))
			if delta > int(worst.get(key, 0)):
				worst[key] = delta

	# Cumulative: a one-node-per-cycle leak is invisible round to round and
	# obvious across twenty.
	var final := _snapshot()
	var drift := _diff(baseline, final)
	for key in METRICS:
		_h.item()
		var delta := int(drift.get(key, 0))
		_h.expect(delta <= 0, "cycle_metric_grew",
			("%d 轮「菜单↔备战↔弹窗」之后 %s 增长了 %+d（峰值 %+d）。"
			+ "每轮泄漏一个的话，这里就是 +%d。热身 %d 轮之后取的基线，"
			+ "所以一次性缓存已经排除。")
				% [MEASURED_CYCLES, key, delta, int(worst.get(key, 0)),
					MEASURED_CYCLES, WARMUP_CYCLES])

	_h.note("%d 轮后相对基线的漂移：%s" % [MEASURED_CYCLES,
		"无" if drift.is_empty() else _describe(drift)])


# --- 5. nothing left behind for the next check in the suite --------------------

func _check_final_state_is_clean() -> void:
	ModalStack.close_all()
	await _settle(4)

	_h.expect(ModalStack.depth() == 0, "residual_modal_depth",
		"跑完之后模态栈还有 %d 层" % ModalStack.depth())
	_h.expect(DialogService.open_count() == 0, "residual_dialog",
		"跑完之后还有 %d 个对话框" % DialogService.open_count())
	var stop: Array = ModalStack.find_invisible_stop_controls()
	_h.expect(stop.is_empty(), "residual_invisible_stop",
		"跑完之后残留 %d 个不可见 STOP 控件：%s" % [stop.size(), ", ".join(stop)])

	var hosts := 0
	for child in get_tree().root.get_children():
		if str(child.name).begins_with("Modal_"):
			hosts += 1
	_h.expect(hosts == 0, "residual_modal_host",
		"root 下还挂着 %d 个 Modal_* CanvasLayer" % hosts)

	var dump: Dictionary = AsyncActionController.dump_action_state()
	_h.expect(int(dump.get("active_count", -1)) == 0, "residual_active_action",
		"跑完之后还有 %s 个动作是活跃的" % str(dump.get("active_count", "?")))

	# The suite runs checks in one process each, but a gate that writes saves or
	# leaves global run state dirty is still a landmine for whatever runs next.
	_h.expect(not FileAccess.file_exists("user://modal_lifecycle_check.save"),
		"gate_wrote_save", "门禁写了存档文件")


# --- V3 P0-07：房间面板的生产接线 ---------------------------------------------

# 迁移前 MainMenu 自己建了一个常驻 overlay（add_child + 自带 dim ColorRect），
# 用 visible 开关。那样有三个后果：
#   * Back 键到不了它 —— ModalStack.handle_back_request() 不知道它存在
#   * 它的 dim 不参与「只有栈顶 backdrop 吃输入」的合同，会和别的层叠成两层黑
#   * owner 释放 / close_all 都结算不到它
#
# 这里断言的是**生产代码的接线**，不是 ModalStack 夹具：夹具早就绿了，
# 而漏的正好是没接上去的那一个。
func _check_room_panel_is_modal() -> void:
	var source := FileAccess.get_file_as_string("res://scenes/menu/MainMenu.gd")
	if not _h.expect(not source.is_empty(), "main_menu_unreadable", "读不到 MainMenu.gd"):
		return

	# 断言限定在 _show_room_overlay 的**函数体**里，而不是「整个文件出现过」。
	# 前者是代码，后者会被注释里的同名字符串满足 —— 本轮已经在
	# android_smoke 的 cache_condition、VFXWarmup 的 memory_warning 上各栽过一次，
	# 这是第三次。散文里提到一个 API 名太常见了，contains 挡不住。
	var show_at := source.find("func _show_room_overlay() -> void:")
	if not _h.expect(show_at >= 0, "room_show_missing", "找不到 _show_room_overlay()"):
		return
	var show_end := source.find("\nfunc ", show_at + 1)
	if show_end < 0:
		show_end = source.length()
	var show_body := source.substr(show_at, show_end - show_at)

	_h.expect(show_body.contains("ModalStack.push(content, {"),
		"room_panel_not_pushed",
		"房间面板没有走 ModalStack.push —— Back 键和 close_all 都结算不到它")
	_h.expect(source.contains("const ROOM_MODAL_ID :="),
		"room_modal_id_missing", "房间面板没有稳定的 modal id，去重和关闭都无从下手")
	# 带缩进和冒号的完整判断行，注释里不可能长这样。
	_h.expect(show_body.contains("\tif ModalStack.has(ROOM_MODAL_ID):"),
		"room_panel_no_dedupe",
		"开层前没有 has() 去重 —— 连点两次「自定房间」会开出两层")
	_h.expect(source.contains("\tModalStack.pop(ROOM_MODAL_ID)"),
		"room_panel_not_popped",
		"关闭没有走 ModalStack.pop，栈里会留下一条永远关不掉的记录")

	# 常驻 overlay 的痕迹必须清干净。留着 visible 开关就等于两套显示逻辑并存。
	_h.expect(not source.contains("_room_overlay.visible"),
		"room_panel_still_visibility_toggled",
		"房间面板还在用 visible 开关 —— 那条路径绕过了 ModalStack")
	_h.expect(not source.contains("_room_overlay = Control.new()"),
		"room_panel_still_persistent",
		"房间面板仍然是常驻节点，切界面时会被连带删掉")

	# 自建 dim 必须去掉：backdrop 归 ModalStack，两层黑叠在一起是可见缺陷。
	var build_at := source.find("func _build_room_panel() -> Control:")
	if not _h.expect(build_at >= 0, "room_panel_builder_missing",
			"找不到 _build_room_panel()"):
		return
	var build_end := source.find("\nfunc ", build_at + 1)
	if build_end < 0:
		build_end = source.length()
	var build_body := source.substr(build_at, build_end - build_at)
	_h.expect(not build_body.contains("ColorRect.new()"),
		"room_panel_builds_own_dim",
		"房间面板自己建了 dim —— 会和 ModalStack 的 backdrop 叠成两层黑")
	_h.expect(build_body.contains("return center"),
		"room_panel_builder_returns_nothing",
		"_build_room_panel() 没有把面板返回给调用方")
