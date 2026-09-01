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
	#   MainMenu._show_coming_soon()     = "main_menu_coming_soon"   (9 hot zones)
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
