extends Node

var checked := 0
var failures := 0

func expect(ok: bool, message: String) -> void:
	checked += 1
	if not ok:
		failures += 1
		push_error(message)

func hover_at(point: Vector2) -> Control:
	var event := InputEventMouseMotion.new()
	event.position = point
	Input.parse_input_event(event)
	await get_tree().process_frame
	return get_viewport().gui_get_hovered_control()

func _ready() -> void:
	for dimensions in [Vector2i(1600, 720), Vector2i(1600, 900), Vector2i(1600, 1200)]:
		get_window().size = dimensions
		SafeArea.set_test_insets(Vector4(44, 0, 44, 24))
		GameState.reset_run()
		GameState.tutorial_mode = false
		NetworkService.team_active = false
		var screen: Node = load("res://scenes/prep/PrepScreen.tscn").instantiate()
		add_child(screen)
		# Enable the production chat geometry without opening an online connection.
		screen._build_chat_record_window()
		for i in 20:
			await get_tree().process_frame
		var hud: Node = screen.get("_board_hud")
		for cell in hud.bench_buttons:
			for offset in [Vector2.ZERO, Vector2(0, -30), Vector2(0, 30), Vector2(-30, 0), Vector2(30, 0)]:
				var point: Vector2 = cell.get_global_rect().get_center() + offset
				var hovered := await hover_at(point)
				expect(hovered == cell, "%s bench %d touch %s intercepted by %s" % [dimensions, cell.bench_index, point, hovered])
		for cell in hud.buttons:
			var hovered := await hover_at(cell.get_global_rect().get_center())
			expect(hovered == cell, "Board center remains reachable: %s" % dimensions)
		var typing: Control = screen.get("_chat_record_input")
		var point := typing.get_global_rect().position + Vector2(typing.size.x - 18, typing.size.y * 0.5)
		expect(await hover_at(point) == typing, "Chat input remains clickable outside formation cells")
		var history: Control = screen.get("_chat_record_scroll")
		point = history.get_global_rect().end - Vector2(24, 18)
		var hovered := await hover_at(point)
		expect(hovered == history or history.is_ancestor_of(hovered), "Chat scrolling remains reachable")
		# A native touch gesture on the last card still enters the existing drag state.
		var last: Control = hud.bench_buttons[7]
		last.drag_payload = {"kind": "bench", "index": 7}
		var touch := InputEventScreenTouch.new()
		touch.index = 0
		touch.pressed = true
		touch.position = last.size * 0.5
		last.gui_input.emit(touch)
		var drag := InputEventScreenDrag.new()
		drag.index = 0
		drag.position = touch.position + Vector2(-50, -50)
		last.gui_input.emit(drag)
		expect(last._gesture_drag_launched, "Last bench native touch gesture launches drag")
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.position = Vector2(20, 300)
		Input.parse_input_event(release)
		await get_tree().process_frame
		screen.queue_free()
		await get_tree().process_frame
	SafeArea.set_test_insets(Vector4.ZERO)
	print("PREP_BENCH_TOUCH checked=", checked, " failures=", failures)
	get_tree().quit(1 if failures else 0)
