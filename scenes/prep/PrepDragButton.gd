extends Button

# 可拖拽按钮 —— 商店卡片、棋盘格、待命格、佣兵卡都用它。
#
# D2 第三步从 PrepShared 的内部类里搬出来。搬的理由很具体：
# 商店面板要做成独立文件，而它的 `buttons: Array[DragButton]` 需要这个类型。
# 类型留在 PrepShared 里面板就引用不到，退成 Array[Button] 又会丢掉
# `drag_payload` 的静态检查（`btn.drag_payload` 直接编译不过）。
#
# 它本身零反向依赖：只认识 Control，对宿主的调用全部走 has_method 保护。
#
# ⚠️ 那几个 has_method 调用（_on_drag_started / _on_drag_ended）是编译器管不到的：
# 宿主那边一旦改名，这里会**静默不再通知**，拖拽看起来还能用但状态不同步。
# 由 tools/dynamic_call_check.tscn 守着。

var drag_payload: Dictionary = {}
var drag_enabled := true
var drag_owner: Control


func _get_drag_data(_at_position: Vector2) -> Variant:
	if disabled or not drag_enabled or drag_payload.is_empty():
		return null
	# 开始拖拽 = 这次不算长按。不停表的话，拖到一半会弹出详情框挡住视线。
	if has_meta("long_press_timer"):
		var timer = get_meta("long_press_timer")
		if timer is Timer:
			timer.stop()
	set_meta("long_press_cancelled", true)
	set_meta("dragging", true)
	if drag_owner != null and drag_owner.has_method("_on_drag_started"):
		drag_owner._on_drag_started(drag_payload)
	var preview := Label.new()
	preview.text = str(get_meta("drag_preview_text", text))
	preview.modulate = Color(1.0, 0.95, 0.65)
	preview.add_theme_font_size_override("font_size", 14)
	set_drag_preview(preview)
	return drag_payload.duplicate(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and drag_owner != null and drag_owner.has_method("_on_drag_ended"):
		drag_owner._on_drag_ended()
