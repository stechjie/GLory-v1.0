extends Node

# V2 P1-09 专项门禁：教程遮挡与安全区适配。
#
# 验收线（来自 V2 清单）：
#   16:9、20:9、2640×1216、1280×720 四种分辨率下，
#   **目标可见面积 ≥90%**，**气泡/按钮不出界**。
#
# 为什么这四种分辨率会得出不同版面：项目基准视口是 1600×720，
# `stretch/mode=canvas_items`、`stretch/aspect=expand` —— canvas 高度恒为 720，
# 宽度随设备宽高比在 **1280（16:9）到 1600（20:9）** 之间变化。
# 也就是说窄屏设备拿到的是**更窄的画布**，而不是等比缩小的同一张画布。
#
# 这条门禁只验**版面**，不验流程（流程由 tutorial_step15_flow 覆盖），
# 所以直接把 step 摆到每一档再 update_overlay()，不去真的玩一遍教程。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const TutorialScript := preload("res://scripts/tutorial/TutorialMode.gd")
const PrepScript := preload("res://scenes/prep/PrepScreen.gd")

const CHECK_NAME := "tutorial_overlay_layout"
const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"

# V2 验收点名的四种分辨率。
const RESOLUTIONS: Array = [
	{"name": "16:9 1920x1080", "size": Vector2i(1920, 1080)},
	{"name": "20:9 2400x1080", "size": Vector2i(2400, 1080)},
	{"name": "2640x1216", "size": Vector2i(2640, 1216)},
	{"name": "1280x720", "size": Vector2i(1280, 720)},
]

# 目标至少要露出这么多面积。
const MIN_TARGET_VISIBLE := 0.90
# 浮点与 1px 取整的容差。
const EPS := 1.5

var _h: CheckHarness
var _restore_size := Vector2i.ZERO


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_restore_size = get_window().size

	for entry in RESOLUTIONS:
		await _check_resolution(entry as Dictionary)

	get_window().size = _restore_size
	TutorialMode.finish()
	GameState.reset_run()
	await _settle(3)
	_h.finish(get_tree())


func _check_resolution(entry: Dictionary) -> void:
	var label := str(entry["name"])
	get_window().size = entry["size"] as Vector2i
	await _settle(4)

	TutorialMode.start()
	var prep := _new_prep()
	if prep == null:
		return
	await _settle(3)
	TutorialMode.attach(prep.tutorial_target_provider())
	await _settle(2)

	var overlay: Control = TutorialMode._overlay
	if not _h.expect(overlay != null and is_instance_valid(overlay),
			"overlay_missing", "%s：教程 overlay 没建起来" % label):
		prep.queue_free()
		await _settle(3)
		return
	_h.expect(overlay.get_global_rect().position.is_equal_approx(Vector2.ZERO),
		"overlay_not_at_origin",
		"%s：overlay 不在原点，下面的安全区比对会失去意义" % label)

	var canvas := overlay.size
	_h.note("%s -> canvas %.0fx%.0f" % [label, canvas.x, canvas.y])
	var safe := _expected_safe(canvas)
	_h.expect(safe.size.x > 0.0 and safe.size.y > 0.0, "safe_rect_degenerate",
		"%s：安全区算成了 %s" % [label, str(safe)])

	var measured := 0
	for step in _walkable_steps():
		TutorialMode.step = step
		TutorialMode.update_overlay()
		await _settle(1)
		var step_key := TutorialMode.step_key()
		var target := TutorialMode._target_control()
		if target == null or not is_instance_valid(target) or not target.is_visible_in_tree():
			continue
		var target_rect := target.get_global_rect()
		if target_rect.size.x <= 0.0 or target_rect.size.y <= 0.0:
			continue
		measured += 1
		var where := "%s · %s" % [label, step_key]

		# Equivalent to ten seconds at 60 fps: the production PrepScreen calls
		# update_overlay every frame. Repeated identical inputs must be a true no-op.
		var stable_position := TutorialMode._bubble.position
		var debug_before := TutorialMode.layout_debug_snapshot()
		for idle_frame in 600:
			TutorialMode.update_overlay()
			if idle_frame % 60 == 59:
				await get_tree().process_frame
		_h.expect(TutorialMode._bubble.position.is_equal_approx(stable_position),
			"idle_bubble_drift",
			"%s：模拟静止 10 秒后气泡从 %s 漂到 %s" % [
				where, str(stable_position), str(TutorialMode._bubble.position)])
		var debug_after := TutorialMode.layout_debug_snapshot()
		_h.expect(int(debug_after.get("recompute_count", -1))
				== int(debug_before.get("recompute_count", -2)),
			"idle_layout_recomputed",
			"%s：输入没变却重复重排，before=%s after=%s" % [
				where, str(debug_before), str(debug_after)])

		# --- 不出界 -----------------------------------------------------------
		_expect_inside(TutorialMode._bubble.get_global_rect(), safe, where, "气泡")
		_expect_inside(_arrow_rect(), safe, where, "箭头")
		_expect_inside(TutorialMode._skip_btn.get_global_rect(), safe, where, "跳过按钮")

		# --- 目标可见面积 ≥90% ------------------------------------------------
		var target_area := target_rect.size.x * target_rect.size.y
		var covered := _overlap(TutorialMode._bubble.get_global_rect(), target_rect)
		var visible_ratio := 1.0 - covered / maxf(1.0, target_area)
		_h.expect(visible_ratio >= MIN_TARGET_VISIBLE, "target_occluded",
			"%s：气泡盖住了目标 %.1f%%，可见面积只剩 %.1f%%（要求 ≥%.0f%%）"
				% [where, 100.0 * covered / maxf(1.0, target_area),
					100.0 * visible_ratio, 100.0 * MIN_TARGET_VISIBLE])

		# --- 不得压住主按钮 / 待命区 / 宝藏刷新 --------------------------------
		# 判据与目标可见度同一条线：禁区被盖住的面积不得超过一成。
		# 不写「绝对零重叠」是因为 1600×720 的画布上，商店类目标下方就是待命区，
		# 四个方向 ×3 个对齐档全部试完仍可能剩下几像素的接缝 ——
		# 把线画在零，门禁就会因为一条 5px 的窄缝常年红，而按钮其实照样点得到。
		for blocked in prep.tutorial_target_provider().keep_clear_rects():
			var hit := _overlap(TutorialMode._bubble.get_global_rect(), blocked)
			var blocked_area := maxf(1.0, blocked.size.x * blocked.size.y)
			_h.expect(hit / blocked_area <= 1.0 - MIN_TARGET_VISIBLE, "keep_clear_occluded",
				"%s：气泡压住了禁区 %.1f%%（%.0f px² / %.0f px²），上限 %.0f%%"
					% [where, 100.0 * hit / blocked_area, hit, blocked_area,
						100.0 * (1.0 - MIN_TARGET_VISIBLE)])

	_h.expect(measured >= 6, "too_few_targets_measured",
		"%s：只量到 %d 个可解析目标，这一档等于没验" % [label, measured])

	TutorialMode.set_overlay_suppressed(true)
	_h.expect(not TutorialMode._overlay.visible, "detail_does_not_pause_tutorial",
		"%s：顶层详情打开时教程气泡仍在遮挡阅读" % label)
	TutorialMode.set_overlay_suppressed(false)
	_h.expect(TutorialMode._overlay.visible, "tutorial_does_not_resume_after_detail",
		"%s：关闭详情后教程气泡没有恢复" % label)

	await _check_treasure_row(prep, label, safe)

	prep.queue_free()
	await _settle(4)


# 宝藏三选一是唯一一个宽度写死、可能横向出界的面板（V2 P1-09 点名）。
func _check_treasure_row(prep: PrepScript, label: String, safe: Rect2) -> void:
	GameState.owned_treasures.clear()
	GameState.pending_treasure = {
		"active": true, "round": 2,
		"candidates": TreasureService.roll_candidates(3), "refresh_index": 0,
	}
	prep._treasure.refresh()
	await _settle(3)
	var row: Control = prep._treasure._treasure_choice_row
	if not _h.expect(row != null and is_instance_valid(row) and row.get_child_count() == 3,
			"treasure_row_missing", "%s：宝藏三选一没建出三张卡" % label):
		GameState.pending_treasure = {"active": false, "round": 0, "candidates": [], "refresh_index": 0}
		prep._treasure.refresh()
		await _settle(2)
		return

	var total := 0.0
	var card_h := 0.0
	for child in row.get_children():
		var card := child as Control
		if card == null:
			continue
		total += card.custom_minimum_size.x
		card_h = maxf(card_h, card.custom_minimum_size.y)
	total += TreasureChoiceScript.TREASURE_CARD_SEPARATION * 2.0
	_h.expect(total <= safe.size.x + EPS, "treasure_row_overflows",
		"%s：三张宝藏卡合计 %.0f px 宽，安全区只有 %.0f px —— 两侧的卡会被切掉"
			% [label, total, safe.size.x])
	_h.expect(card_h + TreasureChoiceScript.TREASURE_CHROME_HEIGHT <= safe.size.y + EPS,
		"treasure_column_overflows",
		"%s：卡面 %.0f px 高加上标题与刷新按钮超过安全区高度 %.0f px"
			% [label, card_h, safe.size.y])
	_h.expect(card_h > 0.0, "treasure_card_collapsed", "%s：卡面高度算成了 0" % label)

	GameState.pending_treasure = {"active": false, "round": 0, "candidates": [], "refresh_index": 0}
	prep._treasure.refresh()
	await _settle(2)


const TreasureChoiceScript := preload("res://scenes/prep/panels/TreasureChoicePanel.gd")


# 跳过 DONE 与需要先开面板才有目标的步；后者在下面按 target==null 自然过滤。
func _walkable_steps() -> Array:
	var out: Array = []
	for step in [
		TutorialScript.Step.BUY_3, TutorialScript.Step.PLACE_3,
		TutorialScript.Step.START_PVE_1, TutorialScript.Step.UPGRADE_2,
		TutorialScript.Step.START_PVE_2, TutorialScript.Step.TAKE_TREASURE_1,
		TutorialScript.Step.UPGRADE_3, TutorialScript.Step.UPGRADE_OTHERS,
		TutorialScript.Step.BOND_HINT, TutorialScript.Step.VIEW_TREASURE,
		TutorialScript.Step.START_BOSS, TutorialScript.Step.TAKE_TREASURE_2,
		TutorialScript.Step.HIRE_MERC, TutorialScript.Step.FILL_7,
		TutorialScript.Step.FORMATION_HP, TutorialScript.Step.START_PVP,
	]:
		out.append(step)
	return out


# ⚠️ 这里**刻意不调用** `TutorialMode._safe_rect()`。
# 第一版调了，结果「去掉安全区」那次反向变异是绿的 —— 变异同时改掉了实现和门禁
# 读到的期望值，两边一起动就永远对得上，成了同义反复。
# 这里独立把契约算一遍：canvas ∩ 显示安全区，再内缩 BUBBLE_EDGE_MARGIN。
func _expected_safe(canvas: Vector2) -> Rect2:
	var full := Rect2(Vector2.ZERO, canvas)
	var safe := DisplayServer.get_display_safe_area()
	var win := DisplayServer.window_get_size()
	if safe.size.x > 0 and safe.size.y > 0 and win.x > 0 and win.y > 0:
		var sx := canvas.x / float(win.x)
		var sy := canvas.y / float(win.y)
		var mapped := Rect2(
			Vector2(float(safe.position.x) * sx, float(safe.position.y) * sy),
			Vector2(float(safe.size.x) * sx, float(safe.size.y) * sy))
		var clipped := full.intersection(mapped)
		if clipped.size.x > 0.0 and clipped.size.y > 0.0:
			full = clipped
	var inset := minf(TutorialScript.BUBBLE_EDGE_MARGIN, minf(full.size.x, full.size.y) * 0.25)
	return full.grow(-inset)


func _arrow_rect() -> Rect2:
	var arrow: Control = TutorialMode._arrow
	if arrow == null or not is_instance_valid(arrow):
		return Rect2()
	# 箭头是自由摆放的 Label，size 可能还没被容器算过，用常量兜底。
	var size := arrow.size
	if size.x <= 0.0 or size.y <= 0.0:
		size = Vector2(TutorialScript.ARROW_WIDTH, TutorialScript.ARROW_HEIGHT)
	return Rect2(arrow.global_position, size)


func _expect_inside(rect: Rect2, bounds: Rect2, where: String, what: String) -> void:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var inside := rect.position.x >= bounds.position.x - EPS \
		and rect.position.y >= bounds.position.y - EPS \
		and rect.position.x + rect.size.x <= bounds.position.x + bounds.size.x + EPS \
		and rect.position.y + rect.size.y <= bounds.position.y + bounds.size.y + EPS
	_h.expect(inside, "out_of_safe_area",
		"%s：%s 出界了。它是 %s，安全区是 %s" % [where, what, str(rect), str(bounds)])


func _overlap(a: Rect2, b: Rect2) -> float:
	var hit := a.intersection(b)
	if hit.size.x <= 0.0 or hit.size.y <= 0.0:
		return 0.0
	return hit.size.x * hit.size.y


func _new_prep() -> PrepScript:
	var packed := load(PREP_SCENE) as PackedScene
	if not _h.expect(packed != null, "prep_scene_load_failed", "%s 加载不出来" % PREP_SCENE):
		return null
	var prep: PrepScript = packed.instantiate() as PrepScript
	if not _h.expect(prep != null, "prep_wrong_type", "实例化出来的不是 PrepScreen"):
		return null
	add_child(prep)
	return prep


func _settle(frames: int = 2) -> void:
	for i in frames:
		await get_tree().process_frame
