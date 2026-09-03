extends Node

# V3 P0-05 regression gate: request identity, 100-tap deduplication, timeout,
# cancellation policy, owner exit, stale callbacks, breadcrumbs and visible busy UI.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const ControllerScript := preload("res://ui/controllers/AsyncActionController.gd")
const BusyButtonScene := preload("res://ui/components/GloryBusyButton.tscn")
const Theming := preload("res://ui/theme/GloryTheme.gd")

const CHECK_NAME := "async_action"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var controller := ControllerScript.new()
	controller.name = "AsyncActionUnderTest"
	add_child(controller)
	await get_tree().process_frame

	await _check_rapid_taps_and_stale_result(controller)
	await _check_timeout(controller)
	await _check_cancel_policy(controller)
	await _check_owner_exit(controller)
	await _check_busy_button()
	_check_report_contract(controller)

	controller.queue_free()
	_h.finish(get_tree())


func _check_rapid_taps_and_stale_result(controller: Node) -> void:
	var pressed_count := [0]
	controller.action_state_changed.connect(func(action: String, _rid: String, state: String, _snapshot: Dictionary) -> void:
		if action == "rapid_start" and state == ControllerScript.STATE_PRESSED:
			pressed_count[0] = int(pressed_count[0]) + 1)
	controller.record_input_received("rapid_start", "check/start")
	var first := ""
	for i in 100:
		var rid: String = controller.begin("rapid_start", {
			"owner": self,
			"control_id": "check/start",
			"timeout_msec": 5000,
			"cancellable": true,
		})
		if i == 0:
			first = rid
		else:
			_h.expect(rid == first, "rapid_tap_new_request",
				"第 %d 次快速点击生成了不同 request id" % (i + 1))
	_h.expect(int(pressed_count[0]) == 1, "rapid_tap_multiple_accepts",
		"100 次快速点击产生 %d 次 accepted/PRESSED，应为 1" % int(pressed_count[0]))
	_h.expect(controller.mark_pending(first), "mark_pending_failed", "合法 request 无法进入 PENDING")
	_h.expect(str(controller.snapshot_for("rapid_start").get("state", "")) == ControllerScript.STATE_PENDING,
		"pending_state_missing", "mark_pending 后状态不是 PENDING")
	_h.expect(controller.succeed(first), "success_rejected", "当前 request 的成功结果被拒绝")
	_h.expect(not controller.fail(first, "LATE_RESULT"), "late_result_accepted",
		"同一个 request 结算后，迟到失败回调仍被接受")
	await get_tree().process_frame
	_h.expect(str(controller.snapshot_for("rapid_start").get("state", "")) == ControllerScript.STATE_IDLE,
		"terminal_not_returned_to_idle", "终态后没有回到 IDLE")

	# New request may start, but the old id can never settle it.
	var second: String = controller.begin("rapid_start", {"owner": self, "timeout_msec": 5000})
	controller.mark_pending(second)
	_h.expect(second != first, "request_id_reused", "重试复用了旧 request id")
	_h.expect(not controller.succeed(first), "old_callback_settled_retry",
		"旧 request 的迟到回调结算了新一轮动作")
	controller.cancel(second, "check_cleanup", true)
	await get_tree().process_frame
	controller.reset("rapid_start", second)


func _check_timeout(controller: Node) -> void:
	var rid: String = controller.begin("timeout_probe", {
		"owner": self,
		"timeout_msec": 10,
		"cancellable": true,
	})
	controller.mark_pending(rid)
	var before: Dictionary = controller.snapshot_for("timeout_probe")
	controller.poll(int(Time.get_ticks_msec()) + 1000)
	var after: Dictionary = controller.snapshot_for("timeout_probe")
	_h.expect(str(before.get("state", "")) == ControllerScript.STATE_PENDING,
		"timeout_probe_not_pending", "超时探针开始时不是 PENDING")
	_h.expect(str(after.get("state", "")) == ControllerScript.STATE_TIMED_OUT,
		"timeout_not_emitted", "超过 deadline 后不是 TIMED_OUT")
	_h.expect(str(after.get("error_code", "")) == "ACTION_TIMEOUT",
		"timeout_code_missing", "超时没有稳定错误码 ACTION_TIMEOUT")
	await get_tree().process_frame
	controller.reset("timeout_probe", rid)


func _check_cancel_policy(controller: Node) -> void:
	var rid: String = controller.begin("cancel_probe", {
		"owner": self,
		"timeout_msec": 5000,
		"cancellable": false,
		"cancel_reason": "server_commit",
	})
	controller.mark_pending(rid)
	_h.expect(not controller.cancel(rid), "noncancellable_cancelled",
		"不可取消阶段仍接受了普通取消")
	_h.expect(str(controller.snapshot_for("cancel_probe").get("state", "")) == ControllerScript.STATE_PENDING,
		"cancel_rejection_changed_state", "拒绝取消后动作没有保持 PENDING")
	_h.expect(controller.set_cancellable(rid, true), "cancel_policy_not_mutable",
		"进入可取消阶段后无法更新取消策略")
	_h.expect(controller.cancel(rid, "user_cancelled"), "cancel_failed", "可取消动作无法进入 CANCELLED")
	await get_tree().process_frame
	controller.reset("cancel_probe", rid)


func _check_owner_exit(controller: Node) -> void:
	var owner := Node.new()
	add_child(owner)
	var rid: String = controller.begin("owner_probe", {
		"owner": owner,
		"timeout_msec": 5000,
		"cancellable": true,
	})
	controller.mark_pending(rid)
	owner.free()
	controller.poll()
	_h.expect(str(controller.snapshot_for("owner_probe").get("state", "")) == ControllerScript.STATE_CANCELLED,
		"owner_exit_not_cancelled", "owner free 后 pending 动作没有取消")
	await get_tree().process_frame
	controller.reset("owner_probe", rid)


func _check_busy_button() -> void:
	var button = BusyButtonScene.instantiate()
	add_child(button)
	await get_tree().process_frame
	button.set_idle_text("Start Battle")
	# 带一个非默认变体进来：忙碌态结束后必须还回这个，而不是掉到默认样式。
	button.theme_type_variation = Theming.VARIATION_PRIMARY
	button.show_pending("busy_1", "Preparing Battle")
	var pending: Dictionary = button.action_snapshot()
	_h.expect(bool(pending.get("disabled", false)), "busy_button_not_disabled",
		"业务 pending 时按钮仍可重复触发")
	_h.expect(bool(pending.get("busy_text_visible", false)), "silent_disabled_button",
		"按钮 disabled 但没有可见 busy 动词")
	# V3 P1-01：只置 disabled 不够。「你点到了、正在做」和「这个按钮现在不能点」
	# 长得一模一样时，玩家读成后者就会去别处点，或者反复点这一个。
	_h.expect(bool(pending.get("looks_busy", false)), "busy_button_looks_disabled",
		"pending 时按钮外观仍是禁用态 —— 玩家分不出「按空了」和「在跑」")
	_h.expect(str(pending.get("state", "")) == ControllerScript.STATE_PENDING,
		"busy_button_wrong_state", "BusyButton 没显示 PENDING")
	button.show_terminal("busy_1", ControllerScript.STATE_FAILED, "Failed")
	_h.expect(not button.disabled, "terminal_button_still_disabled", "失败后按钮仍永久 disabled")
	_h.expect(str(button.action_snapshot().get("variation", ""))
			== Theming.VARIATION_PRIMARY,
		"terminal_variation_not_restored",
		"结算后没有还回原来的主题变体 —— 按钮跑完一次异步动作就永久变样")
	button.reset_idle("busy_1")
	_h.expect(button.text == "Start Battle", "busy_button_idle_text_not_restored",
		"回到 IDLE 后没有恢复原按钮文案")
	# reset_idle() 必须自己会还原，不能靠前面 show_terminal() 已经还过一次 ——
	# 取消这条路径上根本没有 terminal。（这条断言第一版就是被前面的还原盖住的，
	# 做不出能让它单独转红的变异。）
	button.show_pending("busy_2", "Preparing Battle")
	_h.expect(bool(button.action_snapshot().get("looks_busy", false)),
		"busy_look_not_reentrant", "第二次进入 pending 没有换成忙碌变体")
	button.reset_idle("busy_2")
	_h.expect(str(button.action_snapshot().get("variation", ""))
			== Theming.VARIATION_PRIMARY,
		"idle_variation_not_restored",
		"取消路径（pending 直接回 IDLE）没有还原主题变体")
	button.queue_free()


func _check_report_contract(controller: Node) -> void:
	var state: Dictionary = controller.dump_action_state()
	_h.expect(bool(state.get("available", false)), "action_dump_unavailable",
		"控制器存在但 dump_action_state 仍声称不可用")
	_h.expect(state.has("active") and state.has("recent"), "action_dump_fields_missing",
		"动作快照缺 active/recent")
	var crumbs: Array = controller.recent_breadcrumbs(10)
	_h.expect(not crumbs.is_empty(), "breadcrumbs_empty", "动作经过多条路径后 breadcrumb 仍为空")
	_h.expect(crumbs.size() <= 10, "breadcrumbs_limit_ignored", "recent_breadcrumbs(10) 返回超过 10 条")
	for crumb in crumbs:
		var entry: Dictionary = crumb
		for forbidden in ["position", "coordinates", "room_id", "token", "typed_text"]:
			_h.expect(not entry.has(forbidden), "breadcrumb_privacy_leak",
				"breadcrumb 包含禁止字段 %s" % forbidden)
