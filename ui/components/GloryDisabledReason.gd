class_name GloryDisabledReason
extends RefCounted

# V3 P1-04 第 4 条：禁用态可以问原因，但不触发业务。
#
# 「禁用态不该完全像可点」那一半早就做完了（主题给 disabled 单独的
# StyleBox，ui_component 的六态可区分断言钉着）。缺的是另一半：
# **点下去应该能知道为什么点不动**。今天点一个禁用按钮的结果是绝对的
# 无事发生——而最常被点的禁用按钮恰好是异步进行中的那颗，玩家的本能
# 正是「没反应？再点一下」。
#
# ## 机制
#
# 禁用的 BaseButton **仍然会派发 gui_input**（实测：连发按下+抬起两个事件，
# gui_input 收到 2 次，pressed 收到 0 次）。C++ 侧 Control::_call_gui_input
# 先发信号再调虚函数，而 BaseButton::gui_input 在 disabled 时提前返回 ——
# 所以挂 gui_input 既能收到点击，又绝不会触发业务。这不是绕过禁用，
# 是在禁用之上加一条只读的解释通道。
#
# ## 长按
#
# 验收原文写的是「点击/长按可显示解释」——**或**。只做点击就满足了，
# 每颗按钮再挂一个长按计时器是白给自己加一处泄漏面。这是有意的取舍，
# 不是漏做。

const Toast := preload("res://ui/components/GloryToast.gd")

const META_KEY := "glory_disabled_reason"


static func attach(button: BaseButton, reason: String) -> void:
	if button == null or not is_instance_valid(button):
		return
	button.set_meta(META_KEY, reason)
	if not button.gui_input.is_connected(_on_gui_input):
		button.gui_input.connect(_on_gui_input.bind(button))


static func clear(button: BaseButton) -> void:
	if button == null or not is_instance_valid(button):
		return
	if button.has_meta(META_KEY):
		button.remove_meta(META_KEY)


# **必须先 has_meta。** Godot 4.7 里 get_meta(key, default) 取不到 key 时
# 仍然会打一条引擎 ERROR，而 run_check.ps1 把这类 ERROR 直接算失败
# （那条匹配规则是对着 135 条真机日志加出来的）。带默认值也救不了。
static func reason_for(button: BaseButton) -> String:
	if button == null or not is_instance_valid(button):
		return ""
	if not button.has_meta(META_KEY):
		return ""
	return str(button.get_meta(META_KEY))


static func _on_gui_input(event: InputEvent, button: BaseButton) -> void:
	if button == null or not is_instance_valid(button) or not button.disabled:
		return
	if not _is_primary_release(event):
		return
	var reason := reason_for(button)
	if reason.is_empty():
		return
	button.accept_event()
	Toast.show_text(reason)


# 只认「松开」这一下。按下+松开是两个事件，两个都认就等于一次点击弹两条。
# 触摸与鼠标各有一条路（Android 上 emulate_mouse_from_touch 默认开着，
# 一次触摸会同时来 touch 和模拟出来的 mouse），但两条路都只在松开时命中，
# 而 accept_event() 会把这次事件吃掉，后面那一路不会再走到这里。
static func _is_primary_release(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		return mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed
	if event is InputEventScreenTouch:
		return not (event as InputEventScreenTouch).pressed
	return false
