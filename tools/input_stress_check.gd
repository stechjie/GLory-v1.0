extends Node

# V3 P2-03 input-stress gate: the input and modal layer.
#
# Scope note, because this looks adjacent to async_action_check and is not:
#   async_action_check (174 assertions) owns the CONTROLLER layer — request
#   identity, 100-tap dedup while PRESSED, timeout, cancel policy, owner exit,
#   busy button, late result after success.
#   This gate owns the INPUT layer — which control actually receives a tap, what
#   a backdrop click routes to, whether one physical tap can close two modals,
#   Back / ui_cancel, suspend/resume, and the exhaustive rule that every refused
#   action leaves a reason behind.
# Overlap is deliberate in exactly one place (repeat taps) and even there the
# state differs: async_action_check taps while PRESSED, this one taps while
# PENDING, which is the state a player actually sits in while a spinner shows.
#
# No production seam was added. ModalStack and AsyncActionController already
# expose dump_modal_stack() / find_invisible_stop_controls() / dump_action_state()
# / recent_breadcrumbs(), which is everything this file reads.
#
# Both services are instantiated locally rather than driven through the autoload
# singletons: a gate that mutates global modal state would leave the next check
# in the suite standing on whatever it forgot to clean up.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const ModalStackScript := preload("res://ui/services/ModalStack.gd")
const ControllerScript := preload("res://ui/controllers/AsyncActionController.gd")

const CHECK_NAME := "input_stress"

# How many taps to fire at a control that is already busy. The controller must
# answer every one of them, so this is also the size of the breadcrumb audit.
const PENDING_TAP_COUNT := 50

var _h: CheckHarness
var _stack: Node
var _controller: Node
var _stop_baseline: Array = []


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)

	_stack = ModalStackScript.new()
	_stack.name = "ModalStackUnderTest"
	add_child(_stack)
	_controller = ControllerScript.new()
	_controller.name = "AsyncActionUnderTest"
	add_child(_controller)
	await get_tree().process_frame

	# Anything already invisible-and-STOP before we touch the tree is not ours.
	# Record it so the leak assertions below measure growth, not the starting state.
	_stop_baseline = _stack.find_invisible_stop_controls()
	if not _stop_baseline.is_empty():
		_h.note("入场时树上已有 %d 个不可见 STOP 控件，以下断言测的是增量：%s"
			% [_stop_baseline.size(), ", ".join(_stop_baseline)])

	await _check_backdrop_stop_ownership()
	await _check_duplicate_push_is_a_repeat_tap()
	await _check_one_tap_closes_one_modal()
	await _check_backdrop_click_routing()
	await _check_back_request()
	await _check_owner_lifecycle()
	await _check_taps_while_pending()
	await _check_late_results_after_cancel()
	await _check_suspend_resume()
	_check_every_refusal_has_a_reason()
	await _check_no_residue()

	_controller.queue_free()
	_stack.queue_free()
	_h.finish(get_tree())


# --- helpers -------------------------------------------------------------------

func _content(tag: String) -> Control:
	var c := Control.new()
	c.name = "Content_%s" % tag
	c.mouse_filter = Control.MOUSE_FILTER_STOP
	return c


func _entry_for(id: String) -> Dictionary:
	for row in _stack.dump_modal_stack():
		if str(row.get("id", "")) == id:
			return row
	return {}


func _new_stop_controls() -> Array:
	var out: Array = []
	for path in _stack.find_invisible_stop_controls():
		if not _stop_baseline.has(path):
			out.append(path)
	return out


func _mouse_release() -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = false
	return ev


func _mouse_press() -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	return ev


func _touch_release() -> InputEventScreenTouch:
	var ev := InputEventScreenTouch.new()
	ev.index = 0
	ev.pressed = false
	return ev


func _touch_press() -> InputEventScreenTouch:
	var ev := InputEventScreenTouch.new()
	ev.index = 0
	ev.pressed = true
	return ev


# Fires the event through the real connected handler on the real backdrop node,
# so the guards under test (_is_primary_release, top-index, dismiss flag) all run.
func _send_to_backdrop(id: String, event: InputEvent) -> void:
	var backdrop := _backdrop_node(id)
	if backdrop != null:
		backdrop.gui_input.emit(event)


func _backdrop_node(id: String) -> Control:
	# dump_modal_stack() reports the filter but not the node, so walk the host.
	var host := get_tree().root.get_node_or_null(NodePath("Modal_%s" % id))
	if host == null:
		return null
	return host.get_node_or_null(NodePath("ModalRoot/Backdrop")) as Control


# --- 1. only the top backdrop may eat input ------------------------------------

func _check_backdrop_stop_ownership() -> void:
	var ids: Array[String] = []
	for i in 3:
		ids.append(_stack.push(_content("stop_%d" % i), {"id": "stop_%d" % i}))
	await get_tree().process_frame

	_h.expect(_stack.depth() == 3, "push_depth_wrong",
		"连开三个模态后 depth=%d，应为 3" % _stack.depth())

	var rows: Array = _stack.dump_modal_stack()
	var stop_count := 0
	for row in rows:
		_h.item()
		if str(row.get("backdrop_filter", "")) == "STOP":
			stop_count += 1
		_h.expect(bool(row.get("in_tree", false)), "modal_not_in_tree",
			"模态 %s 记在栈上却不在树里，玩家看不到它" % str(row.get("id", "")))
	_h.expect(stop_count == 1, "multiple_stop_backdrops",
		"同时有 %d 块 STOP 遮罩；只有栈顶那块可以吃输入，否则下层泄漏的遮罩会吞掉点击"
			% stop_count)
	if not rows.is_empty():
		_h.expect(str(rows[rows.size() - 1].get("backdrop_filter", "")) == "STOP",
			"top_backdrop_not_stop", "栈顶遮罩不是 STOP，点击会漏到下面的界面")

	# Teardown must detach in the SAME frame. Asserted before any await on
	# purpose: queue_free() collects at end of frame, so awaiting first would
	# make a queue_free-only teardown look identical to a correct one — the
	# assertion would then be unable to fail, which mutation testing caught.
	var doomed := str(rows[rows.size() - 1].get("id", ""))
	_stack.close_top()
	_h.expect(get_tree().root.get_node_or_null(NodePath("Modal_%s" % doomed)) == null,
		"teardown_not_same_frame",
		("pop() 之后 Modal_%s 仍挂在 root 上。只 queue_free 不摘树的话，"
		+ "这一帧剩下的输入还会打到那块已经关掉的遮罩上。") % doomed)

	# Closing the top must hand STOP to the new top, not leave zero.
	await get_tree().process_frame
	rows = _stack.dump_modal_stack()
	var stop_after := 0
	for row in rows:
		if str(row.get("backdrop_filter", "")) == "STOP":
			stop_after += 1
	_h.expect(stop_after == 1, "stop_not_reassigned_after_pop",
		"关掉栈顶后 STOP 遮罩数为 %d，应仍为 1（新栈顶接手）" % stop_after)

	_stack.close_all()
	await get_tree().process_frame
	_h.expect(_stack.depth() == 0, "close_all_left_entries",
		"close_all() 之后 depth=%d" % _stack.depth())


# --- 2. a repeated tap must not stack a second copy ----------------------------

func _check_duplicate_push_is_a_repeat_tap() -> void:
	var first: String = _stack.push(_content("dup"), {"id": "dup"})
	await get_tree().process_frame
	_h.expect(not first.is_empty(), "first_push_rejected", "第一次入栈就被拒")

	var leaked: Array[Control] = []
	for i in 20:
		var content := _content("dup_%d" % i)
		leaked.append(content)
		var again: String = _stack.push(content, {"id": "dup"})
		_h.expect(again.is_empty(), "duplicate_id_accepted",
			"第 %d 次重复点击又开了一个同 id 模态，返回 %s" % [i + 1, again])
	_h.expect(_stack.depth() == 1, "duplicate_push_grew_stack",
		"20 次重复点击后 depth=%d，应为 1" % _stack.depth())

	# push() takes ownership even on the rejected path — that branch is the one
	# callers forget, and a forgotten Control here is a real node leak.
	await get_tree().process_frame
	await get_tree().process_frame
	var still_alive := 0
	for c in leaked:
		if is_instance_valid(c):
			still_alive += 1
	_h.expect(still_alive == 0, "rejected_content_leaked",
		"被拒的 20 个 content 里还有 %d 个活着，push() 没有在失败分支收尾" % still_alive)

	_stack.close_all()
	await get_tree().process_frame


# --- 3. one physical tap closes exactly one modal ------------------------------

func _check_one_tap_closes_one_modal() -> void:
	# Desktop delivers a single tap as BOTH MouseButton and ScreenTouch. Handling
	# both is how two stacked modals vanish on one tap (V3 P0-07 item 4).
	for i in 2:
		_stack.push(_content("tap_%d" % i), {"id": "tap_%d" % i, "dismiss_on_backdrop": true})
	await get_tree().process_frame
	_h.expect(_stack.depth() == 2, "tap_setup_depth", "用例前置：depth 应为 2")

	# One physical tap, both event families, each delivered to whatever backdrop
	# is on top at that instant — which is how the engine actually routes it, and
	# the only way the cascade can be observed. Addressing the captured id would
	# send the second pair to an already-popped node and quietly prove nothing;
	# mutation testing caught that.
	_send_to_backdrop(_stack.top_id(), _mouse_press())
	_send_to_backdrop(_stack.top_id(), _mouse_release())
	_send_to_backdrop(_stack.top_id(), _touch_press())
	_send_to_backdrop(_stack.top_id(), _touch_release())
	await get_tree().process_frame

	_h.expect(_stack.depth() == 1, "one_tap_closed_two_modals",
		("一次点击（鼠标+触摸各一对）后 depth=%d，应为 1。桌面上同一下点击会同时来 "
		+ "MouseButton 和 ScreenTouch，两条都处理就会一次关掉两层模态。") % _stack.depth())

	# Same tap in the other order, in case emulate_mouse_from_touch is off.
	_send_to_backdrop(_stack.top_id(), _touch_press())
	_send_to_backdrop(_stack.top_id(), _touch_release())
	_send_to_backdrop(_stack.top_id(), _mouse_press())
	_send_to_backdrop(_stack.top_id(), _mouse_release())
	await get_tree().process_frame
	_h.expect(_stack.depth() == 0, "reverse_order_tap_did_not_close",
		"触摸在前、鼠标在后的同一次点击没有关掉模态，depth=%d" % _stack.depth())

	_stack.close_all()
	await get_tree().process_frame


# --- 4. backdrop clicks route only where they should ---------------------------

func _check_backdrop_click_routing() -> void:
	var sticky: String = _stack.push(_content("sticky"),
		{"id": "sticky", "dismiss_on_backdrop": false})
	await get_tree().process_frame
	_send_to_backdrop(sticky, _mouse_press())
	_send_to_backdrop(sticky, _mouse_release())
	await get_tree().process_frame
	_h.expect(_stack.depth() == 1, "sticky_modal_dismissed_by_backdrop",
		"dismiss_on_backdrop=false 的模态被点外面关掉了；危险确认不该这样消失")

	# Press with no release must do nothing: a drag that starts inside and ends
	# outside would otherwise dismiss.
	var loose: String = _stack.push(_content("loose"),
		{"id": "loose", "dismiss_on_backdrop": true})
	await get_tree().process_frame
	_send_to_backdrop(loose, _mouse_press())
	await get_tree().process_frame
	_h.expect(_stack.depth() == 2, "press_without_release_dismissed",
		"只按下未松开就关掉了模态，depth=%d" % _stack.depth())

	# Right button must not dismiss.
	var rmb := InputEventMouseButton.new()
	rmb.button_index = MOUSE_BUTTON_RIGHT
	rmb.pressed = false
	_send_to_backdrop(loose, rmb)
	await get_tree().process_frame
	_h.expect(_stack.depth() == 2, "right_button_dismissed",
		"右键松开关掉了模态，depth=%d" % _stack.depth())

	# A click on a NON-top backdrop must not close it. Only the top is STOP, so
	# this cannot happen through real routing, but the guard is what keeps a
	# stale connection from reaching through.
	_send_to_backdrop(sticky, _mouse_release())
	await get_tree().process_frame
	_h.expect(_stack.has("sticky"), "non_top_backdrop_closed_itself",
		"非栈顶的遮罩响应了点击并关掉了自己")

	# Now it is on top and dismissible.
	_send_to_backdrop(_stack.top_id(), _mouse_release())
	await get_tree().process_frame
	_h.expect(_stack.depth() == 1, "top_dismissible_did_not_close",
		"栈顶且 dismiss_on_backdrop=true 的模态没有被点外面关掉，depth=%d" % _stack.depth())

	_stack.close_all()
	await get_tree().process_frame


# --- 5. Back / ui_cancel -------------------------------------------------------

func _check_back_request() -> void:
	_h.expect(not _stack.handle_back_request(), "back_consumed_on_empty_stack",
		"栈空时 handle_back_request() 返回 true，会让调用方以为返回键被消费，页面退不出去")

	for i in 3:
		_stack.push(_content("back_%d" % i), {"id": "back_%d" % i})
	await get_tree().process_frame

	for expected in [2, 1, 0]:
		var consumed: bool = _stack.handle_back_request()
		await get_tree().process_frame
		_h.expect(consumed, "back_not_consumed",
			"栈非空时 handle_back_request() 返回 false")
		_h.expect(_stack.depth() == expected, "back_closed_wrong_count",
			"一次返回键后 depth=%d，应为 %d（一次只关一层）" % [_stack.depth(), expected])

	_h.expect(not _stack.handle_back_request(), "back_consumed_after_drain",
		"关完所有模态后返回键仍被消费，玩家会觉得返回键失灵")
	_h.expect(_new_stop_controls().is_empty(), "stop_leak_after_back",
		"用返回键关完之后树上多了不可见 STOP 控件：%s" % ", ".join(_new_stop_controls()))


# --- 6. owner lifecycle --------------------------------------------------------

func _check_owner_lifecycle() -> void:
	var owner_a := Node.new()
	owner_a.name = "OwnerA"
	add_child(owner_a)
	var owner_b := Node.new()
	owner_b.name = "OwnerB"
	add_child(owner_b)

	_stack.push(_content("a1"), {"id": "a1", "owner": owner_a})
	_stack.push(_content("a2"), {"id": "a2", "owner": owner_a})
	_stack.push(_content("b1"), {"id": "b1", "owner": owner_b})
	await get_tree().process_frame

	var closed: int = _stack.close_all_for_owner(owner_a)
	await get_tree().process_frame
	_h.expect(closed == 2, "close_for_owner_wrong_count",
		"close_all_for_owner 关了 %d 个，应为 2" % closed)
	_h.expect(_stack.has("b1"), "close_for_owner_hit_other_owner",
		"close_all_for_owner 连别的 owner 的模态一起关了")

	# Free the owner without telling the stack: the per-frame backstop must
	# notice, because a page that switched away must not leave a modal behind.
	owner_b.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(_stack.depth() == 0, "orphan_modal_survived_owner",
		("owner 被 free 之后模态还在，depth=%d。根因在 ModalStack.gd:228："
		+ "`var owner_obj: Object = entry.get(\"owner\", null)` —— 给**带类型**的 Object "
		+ "变量赋一个已释放的引用，Godot 4 会抛 Trying to assign invalid previously freed "
		+ "instance，_process 当帧中断，下一行的 is_instance_valid 兜底永远执行不到。"
		+ "类注释里的规则 3「owner 被 free 时自动关掉它的模态」因此是死代码。"
		+ "改法是去掉类型标注（`var owner_obj = ...`）或改用 owner_id + instance_from_id。"
		+ "该文件属 UI 代码，不在本工作包范围内，故留红不修。") % _stack.depth())
	_h.expect(_new_stop_controls().is_empty(), "stop_leak_after_owner_freed",
		"owner 被 free 后残留不可见 STOP 控件：%s" % ", ".join(_new_stop_controls()))

	owner_a.queue_free()
	await get_tree().process_frame


# --- 7. taps while the spinner is up -------------------------------------------

func _check_taps_while_pending() -> void:
	var accepted := [0]
	_controller.action_state_changed.connect(
		func(action: String, _rid: String, state: String, _snap: Dictionary) -> void:
			if action == "pending_taps" and state == ControllerScript.STATE_PRESSED:
				accepted[0] = int(accepted[0]) + 1)

	_controller.record_input_received("pending_taps", "check/confirm")
	var rid: String = _controller.begin("pending_taps", {
		"owner": self, "control_id": "check/confirm",
		"timeout_msec": 30000, "cancellable": true,
	})
	_h.expect(_controller.mark_pending(rid), "pending_setup_failed",
		"用例前置：无法进入 PENDING")

	# The player is now looking at a spinner and tapping the button again.
	var before: int = _rejection_count()
	for i in PENDING_TAP_COUNT:
		var again: String = _controller.begin("pending_taps", {
			"owner": self, "control_id": "check/confirm",
		})
		_h.expect(again == rid, "pending_tap_new_request",
			"PENDING 期间第 %d 次点击生成了新 request id" % (i + 1))
	_h.expect(int(accepted[0]) == 1, "pending_tap_multiple_accepts",
		"PENDING 期间 %d 次点击产生 %d 次 accepted，应为 1"
			% [PENDING_TAP_COUNT, int(accepted[0])])

	var snap: Dictionary = _controller.snapshot_for("pending_taps")
	_h.expect(str(snap.get("state", "")) == ControllerScript.STATE_PENDING,
		"pending_state_lost", "连点之后状态不再是 PENDING，成了 %s" % str(snap.get("state", "")))
	_h.expect(str(snap.get("request_id", "")) == rid, "pending_request_replaced",
		"连点把当前 request 换掉了")

	var dump: Dictionary = _controller.dump_action_state()
	_h.expect(int(dump.get("active_count", -1)) == 1, "pending_active_count",
		"连点后 active_count=%s，应为 1" % str(dump.get("active_count", "?")))

	# Every one of those taps has to be answered, not silently dropped.
	var gained: int = _rejection_count() - before
	_h.expect(gained >= mini(PENDING_TAP_COUNT, ControllerScript.BREADCRUMB_KEEP),
		"pending_taps_unlogged",
		"%d 次被拒的点击只留下 %d 条 action_rejected 面包屑" % [PENDING_TAP_COUNT, gained])

	_controller.succeed(rid)
	await get_tree().process_frame


# --- 8. results that arrive after the player already cancelled -----------------

func _check_late_results_after_cancel() -> void:
	var rid: String = _controller.begin("late_cancel", {
		"owner": self, "timeout_msec": 30000, "cancellable": true,
	})
	_controller.mark_pending(rid)
	_h.expect(_controller.cancel(rid, "user_cancelled"), "cancel_rejected",
		"可取消的 request 被拒绝取消")

	# async_action_check covers late FAIL after SUCCESS. The mirror case — a
	# late SUCCESS after CANCEL — is the one that silently starts a battle the
	# player already backed out of.
	_h.expect(not _controller.succeed(rid), "late_success_after_cancel_accepted",
		"玩家取消之后迟到的成功回调仍被接受")
	_h.expect(not _controller.fail(rid, "LATE"), "late_fail_after_cancel_accepted",
		"取消之后迟到的失败回调仍被接受")
	_h.expect(not _controller.mark_pending(rid), "late_pending_after_cancel_accepted",
		"取消之后仍能把 request 推回 PENDING")

	var snap: Dictionary = _controller.snapshot_for("late_cancel")
	_h.expect(str(snap.get("state", "")) == ControllerScript.STATE_CANCELLED,
		"cancel_state_overwritten",
		"迟到回调改写了终态，现在是 %s" % str(snap.get("state", "")))

	# Unknown request ids must be refused with a reason, not crash or pass.
	_h.expect(not _controller.cancel("no_such_request"), "unknown_cancel_accepted",
		"取消一个不存在的 request 返回 true")
	_h.expect(not _controller.mark_pending("no_such_request"),
		"unknown_pending_accepted", "把不存在的 request 推进 PENDING 返回 true")
	_h.expect(not _controller.succeed("no_such_request"), "unknown_success_accepted",
		"不存在的 request 的成功回调被接受")

	# A non-cancellable action must refuse cancel and say why.
	var locked: String = _controller.begin("locked", {"owner": self, "cancellable": false})
	_controller.mark_pending(locked)
	_h.expect(not _controller.cancel(locked), "noncancellable_cancelled",
		"不可取消的动作被取消了")
	_h.expect(_controller.cancel(locked, "forced", true), "forced_cancel_rejected",
		"force=true 的取消被拒")
	await get_tree().process_frame


# --- 9. background / resume ----------------------------------------------------

func _check_suspend_resume() -> void:
	# While the app is backgrounded _process stops, so the watchdog never runs.
	# On resume the stale request must time out rather than accept whatever the
	# network finally answered.
	var rid: String = _controller.begin("suspend", {
		"owner": self, "timeout_msec": 500, "cancellable": true,
	})
	_controller.mark_pending(rid)
	var deadline: int = int(_controller.snapshot_for("suspend").get("timeout_msec", 500))

	# No polling at all: this is the suspended window.
	_h.expect(str(_controller.snapshot_for("suspend").get("state", ""))
			== ControllerScript.STATE_PENDING,
		"suspend_state_drifted", "未 poll 期间状态自己变了")

	# Resume: poll with the wall clock as it would be after the gap.
	_controller.poll(int(Time.get_ticks_msec()) + deadline + 1)
	var snap: Dictionary = _controller.snapshot_for("suspend")
	_h.expect(str(snap.get("state", "")) == ControllerScript.STATE_TIMED_OUT,
		"resume_did_not_time_out",
		"切后台超时后恢复，状态是 %s，应为 timed_out" % str(snap.get("state", "")))
	_h.expect(not _controller.succeed(rid), "resume_accepted_stale_result",
		"恢复后迟到的成功结果被接受，玩家会突然被拖进一场早已放弃的战斗")

	# Input arriving during the suspended window must not be lost silently.
	var before: int = _rejection_count()
	_controller.record_input_received("suspend", "check/resume")
	_h.expect(_controller.recent_breadcrumbs(4).size() > 0, "resume_input_unlogged",
		"恢复后的输入没有留下任何面包屑")
	# A fresh action after resume must be accepted — the timed-out one must not
	# wedge the category shut.
	var fresh: String = _controller.begin("suspend", {"owner": self, "cancellable": true})
	_h.expect(not fresh.is_empty() and fresh != rid, "resume_blocked_new_action",
		"超时之后同一类动作再也开不起来，returned=%s" % fresh)
	# The breadcrumb ring is deliberately bounded, so a *count* of rejections is
	# free to fall as newer events push older ones out. What must hold is that the
	# ring stays inside its bound and that the newest event is actually the newest.
	var ring: Array = _controller.recent_breadcrumbs(ControllerScript.BREADCRUMB_KEEP)
	_h.expect(ring.size() <= ControllerScript.BREADCRUMB_KEEP, "breadcrumb_ring_unbounded",
		"面包屑环长 %d，超过上限 %d —— 发布版会无限增长"
			% [ring.size(), ControllerScript.BREADCRUMB_KEEP])
	_h.expect(not ring.is_empty()
			and str(ring[ring.size() - 1].get("action", "")) == "suspend",
		"breadcrumb_newest_wrong",
		"最新一条面包屑不是刚发生的 suspend 动作，环的顺序反了")
	_h.expect(before >= 0, "rejection_count_negative", "拒绝计数为负")
	_controller.cancel(fresh, "cleanup", true)
	await get_tree().process_frame


# --- 10. exhaustive rule: no refusal without a reason --------------------------

func _rejection_count() -> int:
	var n := 0
	for row in _controller.recent_breadcrumbs(ControllerScript.BREADCRUMB_KEEP):
		if str(row.get("event", "")) == "action_rejected":
			n += 1
	return n


func _check_every_refusal_has_a_reason() -> void:
	# Drive each refusal path once more, in a window small enough that the ring
	# buffer cannot drop any of them, and audit the lot.
	var rid: String = _controller.begin("audit", {"owner": self, "cancellable": false})
	_controller.mark_pending(rid)

	var refusals := 0
	if _controller.begin("audit", {"owner": self}) == rid:
		refusals += 1                                   # duplicate_pending
	if not _controller.cancel(rid):
		refusals += 1                                   # not_cancellable
	if not _controller.cancel("ghost_request"):
		refusals += 1                                   # stale_cancel
	if not _controller.mark_pending("ghost_request"):
		refusals += 1                                   # stale_transition
	if not _controller.succeed("ghost_request"):
		refusals += 1                                   # stale_result
	_controller.cancel(rid, "cleanup", true)
	if not _controller.succeed(rid):
		refusals += 1                                   # late_result
	if not _controller.mark_pending(rid):
		refusals += 1                                   # late_transition

	var crumbs: Array = _controller.recent_breadcrumbs(ControllerScript.BREADCRUMB_KEEP)
	var rejected: Array = []
	for row in crumbs:
		if str(row.get("event", "")) == "action_rejected":
			rejected.append(row)

	_h.expect(rejected.size() >= refusals, "refusal_without_breadcrumb",
		"本轮拒绝了 %d 次动作，但面包屑里只有 %d 条 action_rejected —— 有动作被静默丢弃"
			% [refusals, rejected.size()])

	var seen_reasons := {}
	for row in rejected:
		_h.item()
		var reason := str(row.get("reason", ""))
		_h.expect(not reason.is_empty(), "rejection_without_reason",
			"一条 action_rejected 面包屑没有 reason：%s" % str(row))
		_h.expect(not str(row.get("event", "")).is_empty(), "breadcrumb_without_event",
			"面包屑没有 event 字段")
		seen_reasons[reason] = true

	# Every distinct refusal the controller can produce should be reachable from
	# the input layer; a reason that never appears is a path nobody can observe.
	for want in ["duplicate_pending", "not_cancellable", "stale_cancel",
			"stale_transition", "stale_result", "late_result", "late_transition"]:
		_h.expect(seen_reasons.has(want), "refusal_reason_missing",
			"拒绝原因 %s 在本轮一次都没出现，说明这条路径从输入层观察不到" % want)

	# Breadcrumbs are shipped in release builds, so they must stay privacy-safe.
	for row in crumbs:
		for key in row.keys():
			_h.expect(str(key) != "position" and str(key) != "text",
				"breadcrumb_leaks_input", "面包屑里出现了 %s 字段" % str(key))


# --- 11. nothing left behind ---------------------------------------------------

func _check_no_residue() -> void:
	_stack.close_all()
	await get_tree().process_frame
	await get_tree().process_frame

	_h.expect(_stack.depth() == 0, "residual_modal",
		"跑完之后还剩 %d 个模态" % _stack.depth())
	var leaked := _new_stop_controls()
	_h.expect(leaked.is_empty(), "residual_invisible_stop",
		"跑完之后树上多了 %d 个不可见 STOP 控件：%s" % [leaked.size(), ", ".join(leaked)])

	var orphan_hosts := 0
	for child in get_tree().root.get_children():
		if str(child.name).begins_with("Modal_"):
			orphan_hosts += 1
	_h.expect(orphan_hosts == 0, "residual_modal_host",
		"root 下还挂着 %d 个 Modal_* CanvasLayer" % orphan_hosts)

	var dump: Dictionary = _controller.dump_action_state()
	_h.expect(int(dump.get("active_count", -1)) == 0, "residual_active_action",
		"跑完之后还有 %s 个动作停在 PRESSED/PENDING" % str(dump.get("active_count", "?")))
