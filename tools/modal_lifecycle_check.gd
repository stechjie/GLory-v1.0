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
# Deliberately NOT covered here: the implicit "owner was freed without closing
# its modal" backstop. That path is broken in ModalStack._process (see
# input_stress_check's orphan_modal_survived_owner) and one defect should produce
# one red, not two. This gate closes its modals the way correct app code does.

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "modal_lifecycle"

const MENU_SCENE := "res://scenes/menu/MainMenu.tscn"
const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"

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
	DialogService.confirm({
		"title": "t", "body": "b", "owner": owner_node,
		"request_id": RID, "intent": 2,
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
		+ "根因：DialogService 从不监听 ModalStack.modal_closed，_pending 只在 close() "
		+ "或对话框自己发 resolved 时才清。凡是绕过这两条路的关闭 —— 点框外、返回键、"
		+ "owner 释放、close_all —— 都会留下一条永久条目。") % RID)

	# The consequence that a player actually feels.
	DialogService.confirm({
		"title": "t", "body": "b", "owner": owner_node,
		"request_id": RID, "intent": 2,
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

		# Back is exercised on a bare ModalStack modal rather than on a
		# DialogService dialog: closing a dialog through ModalStack leaks a
		# _pending entry (see dialog_pending_survived_modal_close above), and
		# routing the cycle through that known defect would bury every other
		# leak this loop is supposed to find under +1 dialog_open per round.
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
