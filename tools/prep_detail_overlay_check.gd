extends Node

# 守「详情浮层真的能弹出来、能关掉、状态不串」。
#
# D2 第三步把长按详情/金币利息框抽成了 PrepDetailOverlay 组件。
# 抽之前这块**一条检查都没有** —— 节点树快照只证明弹窗节点被造出来了，
# 证明不了「长按能弹出内容」「点空白能关掉」。
#
# 而这个组件失效的方式恰好是静默的：
#   * bind() 没被调用 -> is_ready() 为 false -> 所有 show_* 直接 return，
#     表现是「长按没反应」，没有任何报错
#   * gold_interest_open 忘了复位 -> 金币一变就把当前详情内容覆盖成利息文本
#   * 关闭时序写错 -> 长按弹出后立刻被松手事件关掉，看起来像「闪一下就没了」
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/prep_detail_overlay_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
# 用 preload 常量当类型标注，这样下面全是**静态调用** ——
# 第一版用 ov.show_text(...) 写了 15 处按名字调用，
# 被 dynamic_call 的棘轮当场报警：检查工具自己也不该制造编译器管不到的调用。
const PrepDetailOverlay := preload("res://scenes/prep/PrepDetailOverlay.gd")

const CHECK_NAME := "prep_detail_overlay"

var _h: CheckHarness
var _prep: Node


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "PrepScreen.tscn 无法加载"):
		_h.finish(get_tree())
		return
	_prep = packed.instantiate()
	add_child(_prep)
	await get_tree().process_frame
	await get_tree().process_frame

	_case_bound()
	_case_show_and_hide()
	_case_gold_interest_isolation()
	_case_long_press_wiring()

	_h.finish(get_tree())


func _overlay() -> PrepDetailOverlay:
	return _prep.get("_overlay") as PrepDetailOverlay


# 组件必须在构建阶段就被 bind。没 bind 的话所有 show_* 静默失效。
func _case_bound() -> void:
	var ov := _overlay()
	if not _h.expect(ov != null, "overlay_missing", "PrepScreen 上没有 _overlay 成员"):
		return
	_h.expect(ov.is_ready(), "overlay_not_bound",
		"详情浮层没有 bind 到弹窗节点 —— 长按详情会静默失效，不会报错")


func _case_show_and_hide() -> void:
	var ov := _overlay()
	if ov == null or not ov.is_ready():
		return
	ov.hide_detail()
	_h.expect(not ov.is_showing(), "hide_failed", "hide_detail() 之后仍然可见")

	ov.show_text("PROBE_TEXT_ABC")
	_h.expect(ov.is_showing(), "show_text_failed",
		"_show_text_detail() 之后弹窗没有显示")
	var label: RichTextLabel = ov.text_label
	_h.expect(label != null and str(label.text) == "PROBE_TEXT_ABC",
		"show_text_content_wrong", "弹窗文本不是传进去的内容")
	_h.expect(not ov.gold_interest_open, "gold_flag_stuck",
		"显示普通详情时 gold_interest_open 应为 false")

	ov.hide_detail()
	_h.expect(not ov.is_showing(), "hide_after_show_failed",
		"_hide_detail() 之后弹窗仍然可见")


# 金币利息框是「活的」：金币变了要实时改写。但只有当前开着的就是它才可以改，
# 否则会把普通详情的内容覆盖掉。
func _case_gold_interest_isolation() -> void:
	var ov := _overlay()
	if ov == null or not ov.is_ready():
		return
	var label: RichTextLabel = ov.text_label

	# 开着普通详情时，刷新利息不得改动内容
	ov.show_text("KEEP_ME")
	ov.refresh_gold_interest("INTEREST_TEXT")
	_h.expect(str(label.text) == "KEEP_ME", "gold_refresh_overwrote_detail",
		"普通详情开着时，refresh_gold_interest 把内容覆盖了 —— 应当只在利息框开着时改写")

	# 开着利息框时，刷新利息必须生效
	ov.show_gold_interest("GOLD_PROBE")   # 内容由宿主格式化，这条用例只测组件时序
	_h.expect(ov.gold_interest_open, "gold_flag_not_set",
		"_show_gold_interest_detail() 之后 gold_interest_open 应为 true")
	ov.refresh_gold_interest("INTEREST_TEXT")
	_h.expect(str(label.text) == "INTEREST_TEXT", "gold_refresh_ignored",
		"利息框开着时 refresh_gold_interest 没有生效 —— 金币变化不会反映在框里")

	# 切回普通详情后标志必须复位
	ov.show_text("BACK_TO_NORMAL")
	_h.expect(not ov.gold_interest_open, "gold_flag_not_reset",
		"切回普通详情后 gold_interest_open 没复位 —— 之后金币一变就会覆盖详情内容")
	ov.hide_detail()


# 长按装配：三个 meta 缺一不可，缺了表现为「长按有时不灵」。
func _case_long_press_wiring() -> void:
	var ov := _overlay()
	if ov == null:
		return
	var btn := Button.new()
	add_child(btn)
	var fired := [false]
	ov.attach_long_press(btn, func(): fired[0] = true)
	_h.expect(btn.has_meta("long_press_timer"), "long_press_no_timer",
		"attach_long_press 没有挂上计时器")
	var timer: Timer = btn.get_meta("long_press_timer") as Timer
	_h.expect(timer != null and is_equal_approx(timer.wait_time, 0.7),
		"long_press_wrong_delay", "长按判定时长应为 0.7 秒")
	_h.expect(timer.one_shot, "long_press_not_one_shot",
		"长按计时器必须 one_shot，否则会反复触发")
	# 三个信号都必须连上：少一个都会让长按/拖拽判定失灵
	_h.expect(btn.button_down.get_connections().size() > 0, "long_press_no_down",
		"button_down 未连接 —— 长按永远不会开始计时")
	_h.expect(btn.button_up.get_connections().size() > 0, "long_press_no_up",
		"button_up 未连接 —— 松手不会停止计时")
	_h.expect(btn.gui_input.get_connections().size() > 0, "long_press_no_motion",
		"gui_input 未连接 —— 拖拽时不会取消长按，拖着拖着就弹出说明框")
	btn.queue_free()
