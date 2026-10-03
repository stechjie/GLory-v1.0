extends Node

# 10.04 bug 文档第 6 条：手机端备战商店「点一下没反应」。
#
# 症状：手机端点棋子卡有时完全没反应（选中态不切换）。
# 根因（实测，探针 work/_qa_shop/drag_mech_probe + drag_retry_probe）：
#   1. 引擎在按下后**累计位移超过 10px** 时会自动调一次 `_get_drag_data()`
#      （≤10px 根本不调，11px 才调 —— 引擎自带阈值）；
#   2. 那次调用一旦返回拖拽数据就起了拖拽，而起拖后的那一次松手
#      **再也不会发 `pressed`** ⇒ 十几像素的手抖把整次点击吞掉；
#   3. 四张卡的矩形/命中层级一致、无遮挡 ⇒「第 4 格格外不灵」只是拇指落点差异。
# 修法：`_get_drag_data()` 一律返回 null（引擎永不接管），拖拽改由
#      PrepDragButton 自己在 gui_input 里按位移 force_drag()。
# ★ 为什么不能只在 `_get_drag_data()` 里按位移返回 null：引擎这次尝试**只有一次
#   机会**（首次尝试后 drag_attempted 锁死，不再重试，实测 20px 的真拖拽也不再起拖），
#   而且 at_position 实测恒等于按下点，拿不到当前位移。
#
# ───────────────────────────────────────────────────────────────────────────
# 口径声明（读结论前先读这段）
#
#   ✅ 本检查覆盖：手势状态机（按下 → 位移 → 起拖/点击的判定）、源码合同、
#      三种按钮类型（基类 / 棋盘格 / 待命格）的钩子接线与驱动结果。
#   ❌ 本检查**覆盖不到**「事件路由」那一段 —— 引擎在 >10px 时自动尝试
#      `_get_drag_data` 并且起拖会吞掉 `pressed`，这属于引擎行为。这里用
#      `gui_input.emit()` 直接喂生产处理器，绕过了路由。那一段由**非 headless**
#      探针 `work/_qa_shop/drag_fix_probe.tscn` 覆盖（真窗口 1600x720 + 真
#      push_input 鼠标事件，24/24 OK）。
#   ❌ 也**判不了 `pressed` 到底发没发**：`gui_input.emit()` 只跑连在信号上的
#      脚本处理器，**不跑 BaseButton 的内建点击逻辑**（实测这里 pressed 恒为 0）。
#      所以本检查里不写任何 `pressed` 计数断言 —— 那会是恒真的空转断言。
#      「点击真的生效」由上面那个非 headless 探针判（tap 0/6/12/15 → pressed=1）。
#   ⚠️ 因此「把 _get_drag_data 改回 return drag_payload」这个回退会被本检查的
#      a2/a2b 与 b_*_engine_gets_null 抓住；行为侧的互补判据在那个探针里
#      （tap12 会从 pressed=1 变 pressed=0）。两条判据互补，缺一不可。
# ───────────────────────────────────────────────────────────────────────────

const H := preload("res://tools/CheckHarness.gd")
const SRC_BASE := "res://scenes/prep/PrepDragButton.gd"
const DRAG_BUTTON := preload("res://scenes/prep/PrepDragButton.gd")
const BOARD_CELL := preload("res://scenes/prep/PrepBoardCellButton.gd")
const BENCH_CELL := preload("res://scenes/prep/PrepBenchCellButton.gd")

var h


# 假宿主：只为收 has_method 保护的 _on_drag_started / _on_drag_ended。
class FakeOwner extends Control:
	var starts := 0
	var ends := 0
	func _on_drag_started(_payload: Dictionary) -> void:
		starts += 1
	func _on_drag_ended() -> void:
		ends += 1


func _ready() -> void:
	h = H.new("prep_drag_threshold")
	# ★ 必须先等一帧再动场景树：_ready() 执行期间树正在装配子节点，
	#   此时往 root 上 add_child() 会直接失败 ⇒ 按钮进不了树 ⇒
	#   NOTIFICATION_READY 不来 ⇒ 钩子没接上 ⇒ 后面所有行为断言**无声失效**。
	await get_tree().process_frame
	_section_static()
	_section_types()
	_section_threshold_edges()
	_section_touch()
	h.finish(get_tree())


# ── A. 源码合同 ─────────────────────────────────────────────────────────────

func _section_static() -> void:
	var src := FileAccess.get_file_as_string(SRC_BASE)
	if not h.expect(not src.is_empty(), "a0_src_readable", "PrepDragButton.gd 可读"):
		return

	var drag_body := _func_body(src, "func _get_drag_data(")
	if h.expect(not drag_body.is_empty(), "a1_drag_data_body_found", "_get_drag_data 函数体可定位"):
		# ★ 文本断言先剥掉整行注释：文件头正文就在讲 drag_payload /
		#   set_drag_preview 这些 API 名，把它们算成「代码里还有」会误报
		#   （prep_long_press_check 里记过这条教训）。
		var drag_code := _code_only(drag_body)
		h.expect(drag_code.count("return") == 1 and drag_code.contains("return null"),
			"a2_engine_gets_only_null",
			"_get_drag_data 代码里只能有一个 return，且必须是 `return null`（引擎永不接管）")
		# ★ 核心合同：引擎永远拿不到拖拽数据 ⇒ 它永远不会起拖 ⇒ pressed 不会被吞。
		h.expect(not drag_code.contains("drag_payload"), "a2b_engine_never_steals_drag",
			"_get_drag_data 里不许返回 drag_payload —— 返回了就是「抖过 10px 就吞点击」")
		h.expect(not drag_code.contains("set_drag_preview"), "a3_no_engine_preview",
			"预览也不再交给引擎的 set_drag_preview，改由 force_drag 一并给")
		h.expect(not drag_code.contains("_on_drag_started"), "a4_no_engine_owner_notify",
			"宿主通知只发生在自己发起的拖拽里")

	var dist := _const_float(src, "DRAG_START_DISTANCE")
	h.expect(dist > 10.0, "a5_threshold_above_engine",
		"DRAG_START_DISTANCE=%.1f，必须大于引擎自己的 10px（取 8 之类等于把吞点击的起点提前到 8px）" % dist)

	# ★ 钩子必须挂在 _notification(NOTIFICATION_READY) 上。
	#   两个子类覆写 _ready() 且不调 super，基类 _ready() 会被整个顶掉 ⇒ 静默失效。
	h.expect(not src.contains("func _ready("), "a6_no_ready_hook",
		"基类不许出现 _ready()：PrepBoardCellButton / PrepBenchCellButton 都覆写了它且不调 super._ready()")
	var ready_block := _between(src, "if what == NOTIFICATION_READY:", "if what == NOTIFICATION_DRAG_END:")
	h.expect(ready_block.contains("gui_input.connect(_on_drag_gesture_input)"), "a7_hooked_on_ready",
		"手势钩子在 NOTIFICATION_READY 分支里连上 gui_input")
	h.expect(src.contains("NOTIFICATION_DRAG_END") and src.contains("_on_drag_ended"),
		"a7b_drag_end_still_forwarded", "NOTIFICATION_DRAG_END 仍转发给宿主的 _on_drag_ended")

	# _launch_drag 必须保留原 _get_drag_data 的全部副作用，一条都不能少。
	var launch_body := _func_body(src, "func _launch_drag(")
	if h.expect(not launch_body.is_empty(), "a8_launch_body_found", "_launch_drag 函数体可定位"):
		var rows := [
			{"code": "a9_stops_long_press_timer", "needle": "long_press_timer",
				"why": "起拖要停长按表，否则拖到一半弹出详情框挡住视线"},
			{"code": "a10_marks_long_press_cancelled", "needle": 'set_meta("long_press_cancelled", true)',
				"why": "起拖即算取消长按"},
			{"code": "a11_marks_dragging", "needle": 'set_meta("dragging", true)',
				"why": "起拖要置 dragging，长按超时回调靠它兜底"},
			{"code": "a12_notifies_owner", "needle": "_on_drag_started",
				"why": "通知宿主开始拖拽（棋盘高亮、卖出模式都靠它）"},
			{"code": "a13_forces_drag", "needle": "force_drag(",
				"why": "由按钮自己发起拖拽"},
		]
		for row in rows:
			h.expect(launch_body.contains(str(row["needle"])), str(row["code"]), str(row["why"]))


# ── B. 三种按钮类型都真的按阈值工作 ──────────────────────────────────────────
# 棋盘格与待命格是专门为「基类钩子被 _ready 顶掉」这个坑准备的：它们在行为上
# 必须和商店卡一致，否则说明钩子只在基类实例上生效。

func _section_types() -> void:
	var types := [
		{"label": "base", "script": DRAG_BUTTON},
		{"label": "board", "script": BOARD_CELL},
		{"label": "bench", "script": BENCH_CELL},
	]
	for row in types:
		_assert_type(str(row["label"]), row["script"])


func _assert_type(label: String, script: Script) -> void:
	var made := _make(script)
	var btn: Control = made["btn"]
	var owner: FakeOwner = made["owner"]

	h.expect(_hook_connected(btn), "b_%s_hooked" % label,
		"%s：手势钩子已接上 gui_input（没接上 = 阈值静默失效）" % label)

	# ★ 真调用一次引擎取数入口：它必须拿不到任何东西。
	#   这一条是行为判据（不是读源码），"改回返回 drag_payload"会直接红。
	h.expect(btn.call("_get_drag_data", Vector2(10, 10)) == null, "b_%s_engine_gets_null" % label,
		"%s：_get_drag_data 一律返回 null，引擎拿不到数据就不会起拖" % label)

	# 够不到阈值：一次拖都不许起（于是那次松手不会被吞成"点了没反应"）。
	for n in [0, 6, 12, 15]:
		var before: int = owner.starts
		_gesture(btn, n)
		h.expect(owner.starts == before and not bool(btn.get("_gesture_drag_launched")),
			"b_%s_tap%d" % [label, n],
			"%s：位移 %dpx 判为点击（没起拖、宿主没收到通知）" % [label, n])

	# 到阈值：必须起拖，并且通知到宿主。
	for n in [16, 20, 48]:
		var before: int = owner.starts
		_gesture(btn, n)
		h.expect(owner.starts == before + 1, "b_%s_drag%d" % [label, n],
			"%s：位移 %dpx 起拖（宿主收到 _on_drag_started）" % [label, n])

	# ★ 先抖一下再拖：同一次手势里位移变大必须还能起拖。
	#   （引擎那次「不重试」的陷阱在本检查里被绕过，所以这条只是状态机护栏；
	#     真正的路由级判据在非 headless 探针的 ramp 用例里。）
	var before_ramp: int = owner.starts
	_mouse_down(btn, Vector2(100, 60))
	_mouse_move(btn, Vector2(112, 60))
	h.expect(owner.starts == before_ramp, "b_%s_ramp_mid_not_launched" % label,
		"%s：先抖 12px 时不起拖（还在点击区间）" % label)
	_mouse_move(btn, Vector2(140, 60))
	h.expect(owner.starts == before_ramp + 1, "b_%s_ramp_launches_later" % label,
		"%s：继续移到 40px 时起拖 —— 位移变大不许被锁死" % label)
	_mouse_up(btn, Vector2(140, 60))

	# 拖拽结束的转发（原实现就有，别在改写里丢掉）。
	var before_end: int = owner.ends
	btn.notification(Control.NOTIFICATION_DRAG_END)
	h.expect(owner.ends == before_end + 1, "b_%s_drag_end_forwarded" % label,
		"%s：NOTIFICATION_DRAG_END 仍转发给宿主" % label)

	btn.queue_free()


# ── C. 阈值判据的判别力自检 ─────────────────────────────────────────────────
# 直接调生产实现，把判据钉在边界两侧：谁把阈值改成 0 / 改小 / 删掉判断，
# 这几条就会红（不是"看着像在判"，而是真的判了）。

func _section_threshold_edges() -> void:
	var made := _make(DRAG_BUTTON)
	var btn: Control = made["btn"]
	var owner: FakeOwner = made["owner"]

	btn.call("_begin_gesture", Vector2(100, 60), -1)
	btn.call("_maybe_launch_drag", Vector2(115.99, 60))
	h.expect(owner.starts == 0 and not bool(btn.get("_gesture_drag_launched")), "c1_below_threshold_tap",
		"15.99px 仍判点击（阈值左闭，边界不许松）")

	btn.call("_maybe_launch_drag", Vector2(116.0, 60))
	h.expect(owner.starts == 1, "c2_at_threshold_drag", "16.0px 起拖（边界值本身算够）")

	btn.call("_maybe_launch_drag", Vector2(600, 600))
	h.expect(owner.starts == 1, "c3_single_launch_per_gesture",
		"一次手势最多起一次拖（不许被后续 motion 反复触发）")

	# 关掉拖拽 / 禁用按钮：都不许起拖（原实现返回 null，同样走点击）。
	btn.set("drag_enabled", false)
	btn.call("_begin_gesture", Vector2(100, 60), -1)
	btn.call("_maybe_launch_drag", Vector2(600, 60))
	h.expect(owner.starts == 1, "c4_drag_disabled_no_launch", "drag_enabled=false 时不起拖")
	btn.set("drag_enabled", true)

	btn.set("disabled", true)
	btn.call("_begin_gesture", Vector2(100, 60), -1)
	btn.call("_maybe_launch_drag", Vector2(600, 60))
	h.expect(owner.starts == 1, "c5_button_disabled_no_launch", "按钮 disabled 时不起拖")
	btn.set("disabled", false)

	btn.set("drag_payload", {})
	btn.call("_begin_gesture", Vector2(100, 60), -1)
	btn.call("_maybe_launch_drag", Vector2(600, 60))
	h.expect(owner.starts == 1, "c6_empty_payload_no_launch", "drag_payload 为空时不起拖")
	btn.set("drag_payload", {"kind": "shop", "index": 0})

	# 没按下时移动不许起拖（鼠标划过卡片就走这一条）。
	btn.call("_reset_gesture")
	btn.call("_maybe_launch_drag", Vector2(600, 60))
	h.expect(owner.starts == 1, "c7_motion_without_press_no_launch", "没按下时移动不起拖")

	btn.queue_free()


# ── D. 触摸路径（真触摸走 ScreenTouch + ScreenDrag，与鼠标是两套事件） ──────

func _section_touch() -> void:
	var made := _make(DRAG_BUTTON)
	var btn: Control = made["btn"]
	var owner: FakeOwner = made["owner"]

	_touch_down(btn, Vector2(100, 60), 0)
	_touch_drag(btn, Vector2(112, 60), 0)
	h.expect(owner.starts == 0 and bool(btn.get("_gesture_pressed")), "d1_touch_12px_tap",
		"触摸位移 12px 仍算点击")
	_touch_drag(btn, Vector2(120, 60), 0)
	h.expect(owner.starts == 1, "d2_touch_20px_drag", "触摸位移 20px 起拖")
	_touch_up(btn, Vector2(120, 60), 0)
	h.expect(not bool(btn.get("_gesture_pressed")), "d3_touch_release_resets",
		"触摸抬起清掉手势状态（否则下一次按下会沿用旧起点）")

	# 多指：别的指头在屏幕另一头划，不许影响本次手势。
	var made2 := _make(DRAG_BUTTON)
	var btn2: Control = made2["btn"]
	var owner2: FakeOwner = made2["owner"]
	_touch_down(btn2, Vector2(100, 60), 0)
	_touch_drag(btn2, Vector2(600, 400), 2)
	h.expect(owner2.starts == 0, "d4_other_finger_ignored", "别的指头的拖动不参与本次手势")
	_touch_drag(btn2, Vector2(120, 60), 0)
	h.expect(owner2.starts == 1, "d5_own_finger_still_launches", "发起手势那根指头仍能起拖")
	_touch_up(btn2, Vector2(120, 60), 0)

	btn.queue_free()
	btn2.queue_free()


# ── 工具 ───────────────────────────────────────────────────────────────────

func _make(script: Script) -> Dictionary:
	var btn: Control = script.new()
	var owner := FakeOwner.new()
	btn.set("drag_owner", owner)
	btn.set("drag_payload", {"kind": "shop", "index": 0})
	btn.position = Vector2(300, 200)
	btn.size = Vector2(200, 120)
	if btn.has_method("configure_polygon"):
		# 棋盘格/待命格靠 _has_point 判定命中区，空多边形点不中。
		btn.call("configure_polygon", PackedVector2Array([
			Vector2(0, 0), Vector2(200, 0), Vector2(200, 120), Vector2(0, 120)]))
	get_tree().root.add_child(btn)
	return {"btn": btn, "owner": owner}


func _hook_connected(btn: Control) -> bool:
	for row in btn.gui_input.get_connections():
		if str(row["callable"].get_method()) == "_on_drag_gesture_input":
			return true
	return false


# 一次完整的「按下 → 移动 dist → 松手」鼠标手势（局部坐标）。
func _gesture(btn: Control, dist: int) -> void:
	_mouse_down(btn, Vector2(100, 60))
	if dist > 0:
		_mouse_move(btn, Vector2(100 + dist, 60))
	_mouse_up(btn, Vector2(100 + dist, 60))


func _mouse_down(btn: Control, pos: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = pos
	btn.gui_input.emit(ev)


func _mouse_up(btn: Control, pos: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = false
	ev.position = pos
	btn.gui_input.emit(ev)


func _mouse_move(btn: Control, pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	btn.gui_input.emit(ev)


func _touch_down(btn: Control, pos: Vector2, index: int) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.pressed = true
	ev.position = pos
	btn.gui_input.emit(ev)


func _touch_up(btn: Control, pos: Vector2, index: int) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.pressed = false
	ev.position = pos
	btn.gui_input.emit(ev)


func _touch_drag(btn: Control, pos: Vector2, index: int) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = index
	ev.position = pos
	btn.gui_input.emit(ev)


# 去掉整行注释后再做文本断言：注释里会提到 drag_payload / set_drag_preview
# 这些 API 名（文件头就在讲它们），把它们算成"代码里还有"会误报。
static func _code_only(text: String) -> String:
	var nl := String.chr(10)
	var out: Array = []
	for line in text.split(nl):
		if (line as String).strip_edges().begins_with("#"):
			continue
		out.append(line)
	return nl.join(out)


# 取 "func xxx(" 所在函数的函数体（到下一个顶层 func 之前）。
# 换行用 String.chr(10) 显式拼 —— 本环境写文件会把 "\n" 这类转义字面量写坏。
static func _func_body(src: String, header: String) -> String:
	var nl := String.chr(10)
	var at := src.find(header)
	if at < 0:
		return ""
	var lines := src.substr(at).split(nl)
	var out: Array = []
	for i in lines.size():
		var line: String = lines[i]
		if i > 0 and line.begins_with("func "):
			break
		out.append(line)
	return nl.join(out)


# 取片段（含 from，不含 to）。找不到 to 时取到结尾。
static func _between(src: String, from: String, to: String) -> String:
	var i := src.find(from)
	if i < 0:
		return ""
	var j := src.find(to, i + from.length())
	if j < 0:
		return src.substr(i)
	return src.substr(i, j - i)


# 取 `const NAME := <number>` 的数值；取不到返回 -1。
static func _const_float(src: String, name: String) -> float:
	var at := src.find("const " + name + " :=")
	if at < 0:
		return -1.0
	var line: String = src.substr(at).split(String.chr(10))[0]
	var parts := line.split(":=")
	if parts.size() < 2:
		return -1.0
	return float(parts[1].strip_edges())
