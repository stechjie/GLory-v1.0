extends ScrollContainer

# Observe touch before child buttons consume it. A tap remains a tap; a vertical
# gesture cancels child presses and scrolls even when it starts on an item icon.
const DRAG_THRESHOLD := 6.0
var _finger := -1
var _start := Vector2.ZERO
var _start_scroll := 0
var _dragging := false

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		_finger = -1
		return
	if event is InputEventScreenTouch:
		if event.pressed and _finger < 0 and get_global_rect().has_point(event.position):
			_finger = event.index
			_start = event.position
			_start_scroll = scroll_vertical
			_dragging = false
		elif not event.pressed and event.index == _finger:
			if _dragging:
				get_viewport().set_input_as_handled()
				propagate_notification(NOTIFICATION_SCROLL_END)
			_finger = -1
			_dragging = false
	elif event is InputEventScreenDrag and event.index == _finger:
		var movement: Vector2 = event.position - _start
		if not _dragging and absf(movement.y) >= DRAG_THRESHOLD and absf(movement.y) > absf(movement.x):
			_dragging = true
			propagate_notification(NOTIFICATION_SCROLL_BEGIN)
		if _dragging:
			scroll_vertical = _start_scroll - roundi(movement.y / maxf(0.01, get_global_transform().get_scale().y))
			get_viewport().set_input_as_handled()
