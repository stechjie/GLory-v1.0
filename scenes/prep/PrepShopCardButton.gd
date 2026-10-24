extends "res://scenes/prep/PrepDragButton.gd"
## Capture a short tap that starts on this card and slips just beyond its edge.
## The BaseButton remains the normal click source; the deferred fallback runs only
## if it did not emit pressed. Long presses, canceled touches and drags never buy.
var _tap_active := false
var _tap_origin := Vector2.ZERO
var _tap_pointer := -1
var _tap_max_distance := 0.0
var _pressed_count := 0

func _ready() -> void:
	pressed.connect(func() -> void: _pressed_count += 1)
	gui_input.connect(_capture_tap)

func _capture_tap(event: InputEvent) -> void:
	if event is InputEventScreenTouch and event.pressed:
		if _tap_active:
			return
		_start_tap(event.position, event.index)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if not _tap_active:
			_start_tap(event.position, -1)

func _start_tap(local_position: Vector2, pointer: int) -> void:
	if disabled:
		return
	_tap_active = true
	_tap_origin = get_global_transform_with_canvas() * local_position
	_tap_pointer = pointer
	_tap_max_distance = 0.0

func _input(event: InputEvent) -> void:
	if not _tap_active:
		return
	var position_in_view := Vector2.ZERO
	var released := false
	var canceled := false
	if event is InputEventScreenTouch:
		if _tap_pointer != event.index:
			return
		position_in_view = event.position
		released = not event.pressed
		canceled = event.canceled
	elif event is InputEventScreenDrag:
		if _tap_pointer != event.index:
			return
		position_in_view = event.position
	elif event is InputEventMouseButton:
		if _tap_pointer >= 0 or event.button_index != MOUSE_BUTTON_LEFT:
			return
		position_in_view = event.position
		released = not event.pressed
	elif event is InputEventMouseMotion:
		if _tap_pointer >= 0:
			return
		position_in_view = event.position
	else:
		return
	_tap_max_distance = maxf(_tap_max_distance, position_in_view.distance_to(_tap_origin))
	if not released:
		return
	_tap_active = false
	if canceled or _tap_max_distance >= DRAG_START_DISTANCE or _gesture_drag_launched or get_viewport().gui_is_dragging():
		return
	_finish_tap.call_deferred(_pressed_count)

func _finish_tap(count_before_release: int) -> void:
	if count_before_release != _pressed_count or disabled or not is_visible_in_tree():
		return
	if bool(get_meta("long_press_triggered", false)) or not formation_edit_allowed():
		return
	pressed.emit()
