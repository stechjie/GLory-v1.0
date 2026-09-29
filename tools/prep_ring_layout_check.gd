extends Node

# ── 备战界面「上阵光圈」对齐门禁 ──────────────────────────────────────────────
#
# 复现的用户实测（2026-09-30 报告第三条）：拿到宝物（如「慷慨命运」
# money_generous_fate）后，左侧羁绊面板会多出一个按钮 ⇒ HBox 把 board_frame
# 整体挤动 ⇒ 2D 格子层必须按**新的 grid 原点**重算，否则格子相对**固定**的
# 3D 石台整体偏移；用户点一次赌博（那条路径显式调了重排）才恢复原样。
#
# 判据为什么成立（不是自证）：
#   `_world_to_main_screen` 的三个输入 —— river 相机、river 视口尺寸
#   （`PREP_RIVER_VIEWPORT_SIZE` 常量）、主窗口尺寸 —— 全部与面板布局无关，
#   3D 石台在备战期间也固定不动。所以「格子的屏幕坐标」必须恒定：
#       screen = grid.global_position + cell.position
#   board_frame 被挤动而格子没跟着补偿，screen 就会漂。
#
# 三个用例**各用一个独立 PrepScreen 实例**：共用一个实例时，前一个用例留下的
# 偏差会被后一个用例的基准吸收，看起来「A 红 B 也红」但说不出各自的责任。
#   A  真实路径：宝物入袋走生产收尾函数 _finish_treasure_change
#   B  确定性挤动：往 board_frame 所在的 HBox 前插一个固定宽度 Control
#   C  **只挤动、不调任何重排**：验「靠 item_rect_changed 信号兜底」这一条
#      防线能不能独立成立。C 红了就说明信号兜底不可靠，必须补持续守卫。
#
# 前置体检（否则是假绿）：每个用例都必须**实测到 grid.global_position 真的
# 变了**。若没变，说明这台环境下面板挤不动棋盘，门禁什么都没测到 ⇒ 判 FAIL。

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "prep_ring_layout"
const MAX_DRIFT := 1.5          # px；屏幕坐标允许的最大漂移
const SETTLE_FRAMES := 45       # 每个用例观察的帧数（覆盖 2 帧等待 + 稳定轮询）
const TAIL_FRAMES := 10         # 「终态」取最后这么多帧 —— 布局刚变时的过渡帧不算偏
const MIN_EXPECTS := 9

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	await _run()
	# 体检断言：用例真的跑起来了（防「忘了 await」导致的无声失效）。
	_h.expect(_h.checked_count() >= MIN_EXPECTS, "harness_too_few_expects",
		"只检查了 %d 项，少于预期 %d —— 多半是用例没跑完" % [_h.checked_count(), MIN_EXPECTS])
	_h.finish(get_tree())


func _run() -> void:
	GameState.reset_run()
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	if not _h.expect(units.size() >= 3, "unit_table_missing", "race_units 读不到 3 只棋子"):
		return
	for i in 3:
		var d: Dictionary = (units[i] as Dictionary).duplicate(true)
		GameState.board_slots[i] = {"id": d.get("id", "u%d" % i), "star": 1, "def": d}

	await _case_treasure_grants_button()
	await _case_forced_panel_widen()
	await _case_signal_only_no_realign()


# 用例 A —— 用户实测路径：宝物入袋 ⇒ 左面板多一个按钮 ⇒ 棋盘被挤动。
func _case_treasure_grants_button() -> void:
	var prep := await _spawn_prep()
	if prep == null:
		return
	var grid := _grid_of(prep)
	if not _h.expect(grid != null, "case_a_grid_missing", "用例 A 拿不到 grid"):
		await _despawn(prep)
		return
	var base := _ring_screens(grid)
	if not _h.expect(base.size() >= 16, "case_a_cell_count_low",
			"用例 A 只找到 %d 个上阵格子" % base.size()):
		await _despawn(prep)
		return

	var bonus_before: Array = prep.call("_active_bonus_ids")
	if not GameState.owned_treasures.has("money_generous_fate"):
		GameState.owned_treasures.append("money_generous_fate")
	# 走**生产收尾函数**（与 _pick_treasure / _on_treasure_granted 同一条路）。
	prep.call("_finish_treasure_change", bonus_before)
	var result := await _watch(grid, base, prep)
	_h.expect(result["moved"], "case_a_board_not_moved",
		"授予慷慨命运后 grid 没移动 —— 本环境没挤动棋盘，用例测不到东西（peak=%.2f）" % result["peak"])
	# 判据看**终态**（尾窗口），不看峰值：布局刚变的那一两帧本来就没补偿，
	# 用户报的是「偏了之后一直被留着，点赌博才回正」，那才是 bug。
	_h.expect(result["tail"] <= MAX_DRIFT, "case_a_ring_drift",
		"宝物入袋后上阵光圈**终态**漂了 %.2fpx（> %.2f；峰值 %.2f）" % [
			result["tail"], MAX_DRIFT, result["peak"]])
	if result["tail"] > MAX_DRIFT:
		# 诊断（不影响判定）：偏了之后手动补一次对齐 —— 用来区分「重排根本没被
		# 调到」还是「调到了但算不对」。前者说明时序没覆盖，后者说明函数本身坏了。
		prep.call("_realign_prep_board_cells")
		await get_tree().process_frame
		_h.note("用例A 诊断：手动补一次 _realign_prep_board_cells 后 drift=%.2f（手动前 %.2f）"
			% [_max_drift(base, _ring_screens(grid)), result["tail"]])
	await _despawn(prep)


# 用例 B —— 不变量：**确定性地**把棋盘挤开（在 board_frame 所在的 HBox 里、
# 它的前面插一个固定宽度的空 Control），与「是哪个按钮引起的」无关。
func _case_forced_panel_widen() -> void:
	var prep := await _spawn_prep()
	if prep == null:
		return
	var grid := _grid_of(prep)
	if not _h.expect(grid != null, "case_b_grid_missing", "用例 B 拿不到 grid"):
		await _despawn(prep)
		return
	var base := _ring_screens(grid)
	var spacer := _push_board(prep, 120.0)
	if not _h.expect(spacer != null, "case_b_no_board_row",
			"用例 B 找不到 board_frame 所在的 BoxContainer"):
		await _despawn(prep)
		return
	var result := await _watch(grid, base, prep)
	_h.expect(result["moved"], "case_b_board_not_moved",
		"插入 120px 占位后 grid 仍未移动（peak=%.2f）" % result["peak"])
	_h.expect(result["tail"] <= MAX_DRIFT, "case_b_ring_drift",
		"棋盘被横向挤开 120px 后上阵光圈**终态**漂了 %.2fpx（> %.2f；峰值 %.2f）" % [
			result["tail"], MAX_DRIFT, result["peak"]])
	await _despawn(prep)


# 用例 C —— 只挤动、**不调用任何重排**（既不走生产收尾，也不手动补一刀）。
# 这条专门验「item_rect_changed 信号兜底」能不能独立成立：宝物入袋那一刻
# `_refresh_all()` 会连着刷商店/宝物栏/羁绊面板，可能连着发多次
# item_rect_changed，把 `_apply_prep_model_layout_after_frames` 的版本号反复
# 顶掉（协程互相 return），结果谁也没跑到底。
func _case_signal_only_no_realign() -> void:
	var prep := await _spawn_prep()
	if prep == null:
		return
	var grid := _grid_of(prep)
	if not _h.expect(grid != null, "case_c_grid_missing", "用例 C 拿不到 grid"):
		await _despawn(prep)
		return
	var base := _ring_screens(grid)
	var spacer := _push_board(prep, 96.0)
	if not _h.expect(spacer != null, "case_c_no_board_row",
			"用例 C 找不到 board_frame 所在的 BoxContainer"):
		await _despawn(prep)
		return
	var result := await _watch(grid, base, prep)
	_h.expect(result["moved"], "case_c_board_not_moved",
		"插入 96px 占位后 grid 仍未移动（peak=%.2f）" % result["peak"])
	_h.expect(result["tail"] <= MAX_DRIFT, "case_c_signal_realign_missing",
		"只靠 item_rect_changed 信号兜底时上阵光圈**终态**漂了 %.2fpx（> %.2f）—— "
		% [result["tail"], MAX_DRIFT] + "信号这条防线不足以自愈")
	await _despawn(prep)


# ── 基础设施 ────────────────────────────────────────────────────────────────

func _spawn_prep() -> Node:
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "prep_scene_load_failed", "PrepScreen.tscn 无法加载"):
		return null
	var prep: Node = packed.instantiate()
	add_child(prep)
	for _f in 10:
		await get_tree().process_frame
	return prep


func _despawn(prep: Node) -> void:
	# 先摘出树再释放，保证下一个用例起跑时树里只有一个 PrepScreen。
	remove_child(prep)
	prep.queue_free()
	for _f in 3:
		await get_tree().process_frame


func _grid_of(prep: Node) -> Control:
	var hud: Object = prep.get("_board_hud")
	return null if hud == null else hud.get("grid")


# 往 board_frame 所在的 BoxContainer 里、board_frame **前面**插一个固定宽度的
# 空 Control：HBox 必然把它排进去，board_frame 因此被横向挤开。
func _push_board(prep: Node, width: float) -> Control:
	var frame: Control = prep.get("_prep_board_frame")
	if frame == null:
		return null
	var row: Node = frame.get_parent()
	if not (row is BoxContainer):
		return null
	var spacer := Control.new()
	spacer.name = "RingCheckSpacer"
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.custom_minimum_size = Vector2(width, 1.0)
	spacer.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	row.add_child(spacer)
	row.move_child(spacer, frame.get_index())
	return spacer


# 逐帧观察：布局落定期间，格子的**屏幕坐标**相对基准的漂移。
#
# 三个量各有含义，别混：
#   * peak  全程最大漂移 —— 布局刚变的那一两帧本来就没补偿，属过渡，不作为判据
#   * tail  最后 TAIL_FRAMES 帧的最大漂移 —— **终态**，用户真正看到的稳态
#   * settled 首次回到阈值内的帧号（-1 = 一直没回正）
func _watch(grid: Control, base: Dictionary, prep: Node = null) -> Dictionary:
	var start := grid.global_position
	var frame := grid.get_parent() as Control
	var frame_start := Vector2.ZERO if frame == null else frame.global_position
	var moved := false
	var peak := 0.0
	var tail := 0.0
	var settled := -1
	var bad_frames := 0
	var last_d := 0.0
	# 版本号轨迹：`_apply_prep_model_layout_after_frames` 会因为 version 被顶掉
	# 而提前 return —— 这条轨迹能看出「一轮布局变化里重排被抢了几次」。
	# 可见性轨迹：那个协程**跑到最后**才会把 _prep_model_root 设回 true，
	# 所以它是「协程有没有跑完」的直接签名（比读派生统计可靠）。
	var vtrace := ""
	var vistrace := ""
	var last_v := -1
	var last_vis := true
	for f in SETTLE_FRAMES:
		await get_tree().process_frame
		if prep != null:
			var v := int(prep.get("_prep_layout_refresh_version"))
			if v != last_v:
				vtrace += "f%d:v%d " % [f, v]
				last_v = v
			var root = prep.get("_prep_model_root")
			if root != null:
				var vis := bool(root.visible)
				if vis != last_vis:
					vistrace += "f%d:%s " % [f, "on" if vis else "off"]
					last_vis = vis
		if not grid.global_position.is_equal_approx(start):
			moved = true
		var d := _max_drift(base, _ring_screens(grid))
		last_d = d
		peak = maxf(peak, d)
		if d > MAX_DRIFT:
			bad_frames += 1
			settled = -1
		elif settled < 0:
			settled = f
		if f >= SETTLE_FRAMES - TAIL_FRAMES:
			tail = maxf(tail, d)
	print("[%s] watch: grid %s -> %s moved=%s peak=%.2f tail=%.2f last=%.2f settled_at=%d over_threshold_frames=%d | versions: %s| model_visible: %s| frame %s -> %s (connected=%s)" % [
		CHECK_NAME, str(start), str(grid.global_position), str(moved),
		peak, tail, last_d, settled, bad_frames, vtrace, vistrace,
		str(frame_start), str(Vector2.ZERO if frame == null else frame.global_position),
		str(false if (prep == null or frame == null) else frame.item_rect_changed.is_connected(
			Callable(prep, "_queue_prep_model_layout_refresh")))])
	return {"moved": moved, "peak": peak, "tail": tail, "settled": settled, "bad": bad_frames}


func _ring_screens(grid: Control) -> Dictionary:
	var out := {}
	for child in grid.get_children():
		if not (child is Control) or not child.has_method("configure_polygon"):
			continue
		if not ("board_index" in child):
			continue
		out[int(child.board_index)] = grid.global_position + (child as Control).position
	return out


func _max_drift(base: Dictionary, now: Dictionary) -> float:
	var worst := 0.0
	for key in base.keys():
		if not now.has(key):
			continue
		worst = maxf(worst, (base[key] as Vector2).distance_to(now[key] as Vector2))
	return worst
