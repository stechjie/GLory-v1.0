extends Node
# ============================================================================
# 2026-10-15 回归门禁：教学「步骤 2/22」待命区棋子拖不动。
#
# 【真机反馈】
#   「步骤 2/22（从待命区把 3 个棋子拖到棋盘）发现无法拖动操作」；把聚焦遮罩关掉
#   之后复测仍是「还是没法拖动」⇒ 说明遮罩从来不是元凶。
#
# 【根因（实测定案）】
#   待命格「此刻能不能拖」不是一个实时判据，而是 BoardHud.refresh_bench() 按
#   **那一刻的 step** 烘进按钮数据里的**快照**：
#       drag_payload = {} if (tutorial_mode and step == BUY_3) else {"kind":"bench","index":i}
#   BUY_3 期间为空是**设计**（先买再上阵）；PLACE_3 起必须能拖。
#   而 BUY_3 → PLACE_3 只由「关掉商店」这条生产事件推进
#   （TutorialMode.record_shop_toggled(false) → sync()），它此前**只改 step、不刷待命区**。
#   玩家买满 3 个时每次买入都会刷一遍待命区 —— 但那一刻 step 仍是 BUY_3，快照全落成 `{}`；
#   再点商店外面关店，step 走到 PLACE_3 却没有任何人再刷新 ⇒ 快照永远停在 `{}` ⇒
#   PrepDragButton._maybe_launch_drag() 里 `drag_payload.is_empty()` 直接早退 ⇒
#   棋子**永远拖不起来**。
#   实测（`_qa_1016/_diag_drag_block.tscn`）排除了「被遮挡」：待命格中心
#   `gui_get_hovered_control()` 返回的**就是待命格自己**，没有任何控件盖在上面；
#   把 step 手工改成 PLACE_3 但不刷 UI，payload 仍是 `{}`；一刷新就变
#   `{"kind":"bench","index":i}`。⇒ 铁证是**快照过期**，不是遮挡、也不是输入被吃。
#
# 【要钉住什么】
#   ① BUY_3 期间 payload 必须为空（**这是设计**，不许被"修"成永远非空）；
#   ② 关商店推进到 PLACE_3、等刷新落地后：3 个已占位待命格必须可拖
#      （payload 正确 + 未禁用 + 没被 IGNORE + 真实命中测试打到它自己）；
#   ③ 反例：把 step 硬拨回 BUY_3 再刷新，payload 必须重新变空 —— 证明它真的跟着 step 走，
#      而不是被无条件填满。
#
# 【跑法】
#   Godot_v4.7.2-stable_win64_console.exe --headless --path <工程根> \
#       _qa_1016/bench_drag_after_shop_close.tscn
#   退出码 0 = PASS / 1 = FAIL。

const CheckHarness := preload("res://_qa_1016/CheckHarness.gd")
const CHECK_NAME := "bench_drag_after_shop_close"
const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"
const VIEW := Vector2i(1600, 720)
## 造几个棋子（人类一级兵，最便宜的常见单位）。
const UNIT_ID := "human_militia"
const UNIT_COUNT := 3

var _h: CheckHarness
var _prep: Node


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	get_window().size = VIEW
	await _settle(4)

	GameState.reset_run()
	GameState.tutorial_mode = true
	TutorialMode.start()

	var packed := load(PREP_SCENE) as PackedScene
	if not _h.expect(packed != null, "prep_scene_load_failed",
			"%s 加载不出来" % PREP_SCENE):
		_h.finish(get_tree())
		return
	_prep = packed.instantiate()
	if not _h.expect(_prep != null, "prep_instantiate_failed", "PrepScreen 实例化失败"):
		_h.finish(get_tree())
		return
	add_child(_prep)
	await _settle(14)

	# 前提：provider 必须已经挂上 —— 修复靠的是 `_refresh_prep()` 走 provider 的
	# ACTION_REFRESH_VIEW 通道；provider 没挂上时"_refresh_prep 什么都不做"，
	# 门禁就变成在验证一条断掉的链路。
	if not _h.expect(TutorialMode.get("_target_provider") != null, "provider_not_attached",
			"TutorialMode 没挂上 target provider（PrepScreen 的 attach 前提不成立）"
			+ " —— 下面「请宿主刷新视图」这条链路根本没接通，测不出真东西"):
		_prep.queue_free()
		await _settle(3)
		_h.finish(get_tree())
		return

	var def := DataRegistry.canonical_unit_def(UNIT_ID)
	if not _h.expect(not def.is_empty(), "unit_def_missing",
			"取不到 %s 的单位定义，造不出待命区棋子" % UNIT_ID):
		_prep.queue_free()
		await _settle(3)
		_h.finish(get_tree())
		return
	for i in range(UNIT_COUNT):
		GameState.bench_slots[i] = {"def": def, "star": 1}
	_refresh()
	await _settle(4)

	# ── ① 起点必须是 BUY_3，且此刻不许拖 ───────────────────────────────────
	if not _h.expect(TutorialMode.step == TutorialMode.Step.BUY_3, "baseline_not_buy3",
			"起点不是 BUY_3（step=%s）—— 后面的推进判据全部失去意义"
				% str(TutorialMode.step_key())):
		_prep.queue_free()
		await _settle(3)
		_h.finish(get_tree())
		return
	for i in range(UNIT_COUNT):
		_assert_payload(i, false, "BUY_3 期间")

	# ── ② 关商店 → 推进到 PLACE_3 → 必须能拖 ───────────────────────────────
	TutorialMode.record_shop_toggled(false)
	await _settle(8)      # 等 `_refresh_all.call_deferred()` 落地
	if not _h.expect(TutorialMode.step == TutorialMode.Step.PLACE_3, "not_advanced_to_place3",
			"关商店之后 step 没推进到 PLACE_3（实际 %s）—— 前置条件不成立"
				% str(TutorialMode.step_key())):
		_prep.queue_free()
		await _settle(3)
		_h.finish(get_tree())
		return
	for i in range(UNIT_COUNT):
		_assert_payload(i, true, "关商店推进到 PLACE_3 之后")
	await _assert_hit(0)

	# ── ③ 反例：拨回 BUY_3 + 刷新 → 必须重新变空 ───────────────────────────
	TutorialMode.step = TutorialMode.Step.BUY_3
	_refresh()
	await _settle(2)
	_assert_payload(0, false, "拨回 BUY_3 并刷新之后")

	_prep.queue_free()
	await _settle(3)
	_h.finish(get_tree())


# ── 判据 ────────────────────────────────────────────────────────────────────

func _assert_payload(index: int, expect_draggable: bool, label: String) -> void:
	var buttons: Variant = _bench_buttons()
	if buttons == null:
		return
	if not _h.expect(index < buttons.size(), "bench_button_missing",
			"%s：_board_hud.bench_buttons 只有 %d 个，取不到第 %d 个"
				% [label, buttons.size(), index]):
		return
	var btn: Control = buttons[index]
	var where := "%s · 待命格[%d]" % [label, index]
	var payload: Dictionary = btn.get("drag_payload")
	if expect_draggable:
		_h.expect(not payload.is_empty(), "bench_payload_empty",
			"%s：drag_payload 是空的 —— PrepDragButton._maybe_launch_drag() 里的"
				% where + "`drag_payload.is_empty()` 会直接早退，棋子拖不起来"
			+ "（正是真机反馈的那个现象）")
		_h.expect(str(payload.get("kind", "")) == "bench", "bench_payload_kind",
			"%s：payload.kind 应为 bench，实际「%s」"
				% [where, str(payload.get("kind", ""))])
		_h.expect(int(payload.get("index", -1)) == index, "bench_payload_index",
			"%s：payload.index 应为 %d，实际 %d"
				% [where, index, int(payload.get("index", -1))])
		_h.expect(not btn.disabled, "bench_button_disabled",
			"%s：按钮是 disabled 的，起不了拖" % where)
		_h.expect(bool(btn.get("drag_enabled")), "bench_drag_disabled",
			"%s：drag_enabled 为 false，起不了拖" % where)
		_h.expect(btn.mouse_filter != Control.MOUSE_FILTER_IGNORE,
			"bench_button_ignores_mouse",
			"%s：mouse_filter 是 IGNORE，收不到任何鼠标事件（商店开着时会这样）" % where)
		_h.expect(btn.is_visible_in_tree(), "bench_button_invisible",
			"%s：按钮不可见，点不到" % where)
	else:
		_h.expect(payload.is_empty(), "bench_payload_should_be_empty",
			"%s：BUY_3 期间待命格**不该**能拖（要先买再上阵），payload 却非空：%s"
				% [where, str(payload)])


# 真实命中测试：光标停在待命格中心，GUI 拾取到的必须是它自己（或其子节点）。
# 这一步专门排除"被别的控件盖住"这种历史成因（10.15 问题 1 就是这一类）。
func _assert_hit(index: int) -> void:
	var buttons: Variant = _bench_buttons()
	if buttons == null or index >= buttons.size():
		return
	var btn: Control = buttons[index]
	var win_pt := _canvas_to_window(btn.get_global_rect().get_center())
	_move(win_pt)
	await get_tree().process_frame
	_move(win_pt)
	await get_tree().process_frame
	var hovered := get_viewport().gui_get_hovered_control()
	var where := "关商店推进到 PLACE_3 之后 · 待命格[%d]" % index
	_h.expect(hovered != null, "bench_hit_nothing",
		"%s：光标停在待命格中心，GUI 拾取到的却是空 —— 那里没有可接收输入的控件" % where)
	if hovered != null and hovered != btn:
		_h.expect(btn.is_ancestor_of(hovered) or hovered.is_ancestor_of(btn),
			"bench_hit_other_control",
			"%s：光标停在待命格中心，拾取到的却是 %s —— 有别的东西盖在上面"
				% [where, str(hovered.get_path())])


# 返回 Array（`_board_hud.bench_buttons`）；取不到 _board_hud 时记一条失败并返回 null。
# 返回类型写 Variant 而不是 Array：失败分支要能返回 null，写 Array 会编译不过。
func _bench_buttons() -> Variant:
	var hud = _prep.get("_board_hud")
	if hud == null:
		_h.fail("board_hud_missing", "PrepScreen 上取不到 _board_hud")
		return null
	return hud.get("bench_buttons")


func _refresh() -> void:
	var hud = _prep.get("_board_hud")
	if hud != null and hud.has_method("refresh_bench"):
		hud.refresh_bench()
	else:
		_h.fail("board_hud_missing", "取不到 _board_hud，刷不了待命区")


# ── 辅助 ────────────────────────────────────────────────────────────────────

func _canvas_to_window(pos: Vector2) -> Vector2:
	var vp := get_viewport()
	var canvas := vp.get_visible_rect().size
	var win := Vector2(vp.size)
	if canvas.x <= 0.0 or canvas.y <= 0.0:
		return pos
	return Vector2(pos.x * win.x / canvas.x, pos.y * win.y / canvas.y)


func _move(win_pos: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = win_pos
	m.global_position = win_pos
	get_viewport().push_input(m)


func _settle(frames: int = 2) -> void:
	for i in frames:
		await get_tree().process_frame
