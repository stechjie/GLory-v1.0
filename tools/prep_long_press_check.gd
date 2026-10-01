extends Node

# 第 9 点（10.01 反馈）：iOS 商店里长按棋子不弹棋子详情。
#
# 根因是**两套坐标系混用**：
#   * button_down 里存的起点是按钮**局部**坐标（get_local_mouse_position）；
#   * 而 gui_input 收到的 InputEventScreenTouch.position /
#     InputEventScreenDrag.position 是**视口**坐标。
# 商店卡片在 1280x720 上离视口原点近 1000px，于是触摸路径下
# current.distance_to(start) 一算就 > 8 ⇒ 任何一次微小抖动都被判成
# 「移动超阈值」⇒ long_press_cancelled = true ⇒ 详情永远弹不出来。
# 桌面上鼠标路径两边都是局部坐标，所以一直看不出来 —— 只有 iOS 会中招。
#
# 三段：
#   A 源码结构：起点只由 gui_input 写、触摸分支自己启表、不再用局部坐标；
#   B 行为：真造按钮、真发触摸/鼠标事件序列，看 1px 抖动会不会误判、
#          120px 拖动会不会该取消就取消；
#   C 真实计时：真的等 0.7 秒，确认长按回调会被叫到（不是"看起来会"）。

const H := preload("res://tools/CheckHarness.gd")
const SRC := "res://scenes/prep/PrepDetailOverlay.gd"

var h


func _ready() -> void:
	h = H.new("prep_long_press")
	# ★ 必须先等一帧再动场景树：_ready() 执行期间树正在装配子节点，
	#   此时往 root 上 add_child() 会直接失败（"Parent node is busy
	#   setting up children"），按钮进不了树 ⇒ Timer.start() 报
	#   "not inside the scene tree" ⇒ 后面所有行为断言**无声失效**。
	await get_tree().process_frame
	_section_static()
	_section_behavior()
	_section_multitouch()
	await _section_timing()
	h.finish(get_tree())


# ── A. 源码结构 ─────────────────────────────────────────────────────────────

func _section_static() -> void:
	var src := FileAccess.get_file_as_string(SRC)
	if not h.expect(not src.is_empty(), "a0_src_readable", "PrepDetailOverlay.gd 可读"):
		return
	var body := func_body(src, "func attach_long_press(")
	h.expect(not body.is_empty(), "a1_body_found", "attach_long_press 函数体可定位")
	# ★ 核心：起点不许再来自按钮局部坐标（那正是 iOS 的近 1000px 假位移）。
	#   只匹配"起点赋值"这一片段 —— 别把注释里提到的 API 名也算进来。
	h.expect(not body.contains('long_press_start", btn.get_local_mouse_position()'),
		"a2_no_local_coordinate_start",
		"起点不许来自按钮局部坐标 —— 局部/视口混用就是这条 bug 的根因")
	h.expect(not body.contains("var current := btn.get_local_mouse_position()"),
		"a2b_no_local_coordinate_fallback",
		"移动比较的兜底默认值也不再用局部坐标")
	h.expect(body.contains("touch.position"), "a3_touch_uses_event_position",
		"触摸按下取事件自带的 position（视口坐标）")
	h.expect(body.contains("mb.position"), "a4_mouse_uses_event_position",
		"鼠标按下同样取事件 position，两条路径同一坐标系")

	# 触摸分支必须自己启表：不能指望 emulate_mouse_from_touch 一定开着。
	var touch_block := between(body, "if touch.pressed:", "elif touch.canceled:")
	h.expect(not touch_block.is_empty(), "a5_touch_block_found", "触摸按下分支可定位")
	h.expect(count(touch_block, "timer.start()") == 1, "a6_touch_starts_timer",
		"触摸按下分支自己启动计时器")
	h.expect(count(touch_block, "long_press_start") == 1, "a7_touch_records_start",
		"触摸按下分支记录起点（只此一处）")

	# button_down 不许再碰起点，否则谁先到就把谁的坐标系留下。
	var down_block := between(body, "btn.button_down.connect", "btn.button_up.connect")
	h.expect(not down_block.is_empty(), "a8_down_block_found", "button_down 块可定位")
	h.expect(not down_block.contains("long_press_start"), "a9_button_down_keeps_start",
		"button_down 不再写起点（两条路径谁先到都不影响结果）")
	h.expect(not down_block.contains("long_press_pointer"), "a10_button_down_keeps_pointer",
		"button_down 不再把 pointer 重置为 -1（会冲掉刚记下的 touch.index）")

	# 阈值仍然存在且是正数：不能靠"干脆不判移动"来让长按生效。
	h.expect(body.contains("> 8.0"), "a11_move_threshold_kept",
		"8px 移动阈值还在 —— 修的是坐标系，不是把判据删掉")


# ── B. 行为：真按钮 + 真事件序列 ────────────────────────────────────────────

func _section_behavior() -> void:
	var overlay = load(SRC).new()
	if not h.expect(overlay != null, "b0_overlay_instantiates", "PrepDetailOverlay 能实例化"):
		return
	var btn := Button.new()
	btn.position = Vector2(300, 200)
	btn.size = Vector2(120, 60)
	get_tree().root.add_child(btn)
	var hits := [0]
	overlay.attach_long_press(btn, func(): hits[0] += 1)

	var pos := Vector2(360, 240)

	# B1 触摸按下：起点必须与事件同坐标系（视口）。
	var touch_down := InputEventScreenTouch.new()
	touch_down.index = 0
	touch_down.pressed = true
	touch_down.position = pos
	btn.gui_input.emit(touch_down)
	var start: Vector2 = btn.get_meta("long_press_start", Vector2.ZERO)
	h.expect(start.distance_to(pos) < 1.0, "b1_start_matches_event_position",
		"起点等于事件的 position（同一坐标系）")

	# B2 触摸模拟出的 mouse down 不许改写起点（它带的是同一条视口坐标）。
	btn.button_down.emit()
	var after_down: Vector2 = btn.get_meta("long_press_start", Vector2.ZERO)
	h.expect(after_down.distance_to(start) < 1.0, "b2_button_down_keeps_start",
		"button_down 不改写起点")

	# B3 ★ 修复前必红：1 像素抖动曾被算成"移动了 ~1000px"。
	var drag_tiny := InputEventScreenDrag.new()
	drag_tiny.index = 0
	drag_tiny.position = pos + Vector2(1, 1)
	btn.gui_input.emit(drag_tiny)
	h.expect(not bool(btn.get_meta("long_press_cancelled", false)), "b3_tiny_drag_not_cancelled",
		"1px 抖动不取消长按（修好坐标系后，8px 阈值才有意义）")
	h.expect(float(btn.get_meta("long_press_timer", null).time_left) > 0.0,
		"b3b_timer_still_running", "抖动不该顺手把计时器停掉")

	# B4 鼠标路径（桌面回归）：同样 1px 不取消。
	var motion := InputEventMouseMotion.new()
	motion.position = pos + Vector2(1, 0)
	btn.gui_input.emit(motion)
	h.expect(not bool(btn.get_meta("long_press_cancelled", false)), "b4_mouse_motion_not_cancelled",
		"鼠标路径也统一到视口坐标，桌面行为不变")

	# B5 真移动要取消：阈值仍然有效，不能靠"不判移动"蒙混。
	var drag_far := InputEventScreenDrag.new()
	drag_far.index = 0
	drag_far.position = pos + Vector2(120, 0)
	btn.gui_input.emit(drag_far)
	h.expect(bool(btn.get_meta("long_press_cancelled", false)), "b5_real_drag_cancels",
		"移动 120px 仍被判定为拖拽，不弹详情")

	# B6 触摸取消（系统手势打断）要取消长按。
	var btn2 := Button.new()
	get_tree().root.add_child(btn2)
	overlay.attach_long_press(btn2, func(): hits[0] += 1)
	var cancel := InputEventScreenTouch.new()
	cancel.index = 0
	cancel.pressed = false
	cancel.canceled = true
	cancel.position = pos
	btn2.gui_input.emit(cancel)
	h.expect(bool(btn2.get_meta("long_press_cancelled", false)), "b6_touch_cancel_cancels",
		"触摸被系统取消时不弹详情")

	btn.queue_free()
	btn2.queue_free()


# ── C. 多指 ─────────────────────────────────────────────────────────────────

func _section_multitouch() -> void:
	var overlay = load(SRC).new()
	var btn := Button.new()
	get_tree().root.add_child(btn)
	overlay.attach_long_press(btn, func(): pass)

	var down := InputEventScreenTouch.new()
	down.index = 1
	down.pressed = true
	down.position = Vector2(360, 240)
	btn.gui_input.emit(down)
	btn.button_down.emit()
	h.expect(int(btn.get_meta("long_press_pointer", -1)) == 1, "c1_pointer_survives_button_down",
		"button_down 不再把 pointer 冲成 -1，多指跟踪保留")

	var other := InputEventScreenDrag.new()
	other.index = 2
	other.position = Vector2(900, 500)
	btn.gui_input.emit(other)
	h.expect(not bool(btn.get_meta("long_press_cancelled", false)), "c2_other_finger_ignored",
		"别的指头在屏幕另一头划，不该取消本次长按")

	var mine := InputEventScreenDrag.new()
	mine.index = 1
	mine.position = Vector2(480, 240)
	btn.gui_input.emit(mine)
	h.expect(bool(btn.get_meta("long_press_cancelled", false)), "c3_own_finger_cancels",
		"发起长按的那根指头移动超阈值，仍然取消")
	btn.queue_free()


# ── D. 真实计时：真的等 0.7 秒 ──────────────────────────────────────────────

func _section_timing() -> void:
	# D1 只发触摸事件、**不发** button_down：模拟 emulate_mouse_from_touch
	#    关掉的平台。触摸分支必须自己起表，否则长按永不触发。
	var overlay = load(SRC).new()
	var btn := Button.new()
	get_tree().root.add_child(btn)
	var hits := [0]
	overlay.attach_long_press(btn, func(): hits[0] += 1)
	var down := InputEventScreenTouch.new()
	down.index = 0
	down.pressed = true
	down.position = Vector2(360, 240)
	btn.gui_input.emit(down)
	var timer := btn.get_meta("long_press_timer", null) as Timer
	h.expect(timer != null and timer.time_left > 0.0, "d1_touch_alone_starts_timer",
		"只靠触摸事件也能起表，不依赖 emulate_mouse_from_touch")

	# D2 手指完全不动：0.7 秒后详情必须弹出来。
	await get_tree().create_timer(0.85).timeout
	h.expect(hits[0] == 1, "d2_long_press_fires",
		"按住 0.7 秒不动，长按回调恰好被调用一次")
	h.expect(bool(btn.get_meta("long_press_triggered", false)), "d3_triggered_flag_set",
		"long_press_triggered 置位 —— 松手时详情不会被顺手收掉")
	btn.queue_free()

	# D4 快速轻点不该触发（按下即松开）。
	var btn2 := Button.new()
	get_tree().root.add_child(btn2)
	var taps := [0]
	overlay.attach_long_press(btn2, func(): taps[0] += 1)
	btn2.gui_input.emit(down)
	btn2.button_up.emit()
	await get_tree().create_timer(0.85).timeout
	h.expect(taps[0] == 0, "d4_quick_tap_does_not_fire",
		"快速轻点不会误触发长按")
	btn2.queue_free()

	# D5 被判成拖拽之后，即使等满 0.7 秒也不许弹（否则拖着拖着冒出详情框）。
	var btn3 := Button.new()
	get_tree().root.add_child(btn3)
	var dragged := [0]
	overlay.attach_long_press(btn3, func(): dragged[0] += 1)
	var down3 := InputEventScreenTouch.new()
	down3.index = 0
	down3.pressed = true
	down3.position = Vector2(360, 240)
	btn3.gui_input.emit(down3)
	btn3.button_down.emit()
	var away := InputEventScreenDrag.new()
	away.index = 0
	away.position = Vector2(480, 240)
	btn3.gui_input.emit(away)
	# 前置体检：先确认这次真的被判成拖拽了，否则下面的"没弹"是空断言。
	h.expect(bool(btn3.get_meta("long_press_cancelled", false)), "d5_setup_cancelled",
		"（前置）120px 拖动确实把这次手势判成了拖拽")
	await get_tree().create_timer(0.85).timeout
	h.expect(dragged[0] == 0, "d6_cancelled_never_fires",
		"被判成拖拽的手势等满 0.7 秒也不弹详情")
	btn3.queue_free()

	# D6 竞态防御：**表还在跑**的时候被置了 cancelled（拖拽判定与计时器到点
	#    挤在同一帧），到点时也必须复核这个标志。上一段的取消路径会顺带把表
	#    停掉，看不出这个判据的作用，所以这里绕过 stop、直接置标志。
	var btn4 := Button.new()
	get_tree().root.add_child(btn4)
	var raced := [0]
	overlay.attach_long_press(btn4, func(): raced[0] += 1)
	var down4 := InputEventScreenTouch.new()
	down4.index = 0
	down4.pressed = true
	down4.position = Vector2(360, 240)
	btn4.gui_input.emit(down4)
	var t4 := btn4.get_meta("long_press_timer", null) as Timer
	h.expect(t4 != null and t4.time_left > 0.0, "d7_setup_timer_running",
		"（前置）计时器确实还在跑")
	btn4.set_meta("long_press_cancelled", true)
	await get_tree().create_timer(0.85).timeout
	h.expect(raced[0] == 0, "d8_cancelled_flag_blocks_fire",
		"到点时必须复核 long_press_cancelled —— 表停不掉的同帧竞态")
	btn4.queue_free()


# ── 辅助 ────────────────────────────────────────────────────────────────────

func func_body(src: String, header: String) -> String:
	var at := src.find(header)
	if at < 0:
		return ""
	var rest := src.substr(at)
	var nxt := rest.find("\nfunc ", 1)
	return rest if nxt < 0 else rest.substr(0, nxt)


func between(src: String, from: String, to: String) -> String:
	var a := src.find(from)
	if a < 0:
		return ""
	var b := src.find(to, a + from.length())
	if b < 0:
		return src.substr(a)
	return src.substr(a, b - a)


func count(hay: String, needle: String) -> int:
	if needle.is_empty():
		return 0
	var n := 0
	var at := hay.find(needle)
	while at >= 0:
		n += 1
		at = hay.find(needle, at + needle.length())
	return n
