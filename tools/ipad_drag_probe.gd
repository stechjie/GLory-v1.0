extends Node

# Real routed touch regression: buying while BUY_3 clears bench drag payloads.
# Closing the shop must rebuild them after the tutorial advances to PLACE_3.
# Run with a visible window at tablet/phone resolutions, not headless.
var failures: Array[String] = []
var results: Array[Dictionary] = []

func _ready() -> void:
	get_tree().create_timer(90.0).timeout.connect(func(): get_tree().quit(2))
	await get_tree().process_frame
	TutorialMode.start()
	var prep := load("res://scenes/prep/PrepScreen.tscn").instantiate() as Control
	add_child(prep)
	await get_tree().create_timer(3.0).timeout
	var shop = prep.get("_shop")
	if not shop.picker_open:
		shop.toggle_picker()
	for index in range(3):
		prep._on_shop_buy_requested(index)
	if OS.get_cmdline_user_args().has("--toggle-close"):
		shop.toggle_picker()
	else:
		shop.close_picker()
	await get_tree().create_timer(0.5).timeout
	_expect(TutorialMode.step == TutorialMode.Step.PLACE_3, "close advances tutorial")
	var hud = prep.get("_board_hud")
	for index in range(3):
		var source: Control = hud.bench_buttons[index]
		var target: Control = hud.buttons[12 + index]
		_expect(source.get("drag_payload") == {"kind": "bench", "index": index}, "bench %d payload restored" % index)
		var uid: String = str(GameState.bench_slots[index].get("uid", ""))
		await _drag(source.get_global_rect().get_center(), target.get_global_rect().get_center())
		var placed: Variant = GameState.board_slots[12 + index]
		var passed: bool = placed is Dictionary and str(placed.get("uid", "")) == uid
		_expect(passed, "bench %d routed touch drop" % index)
		results.append({"bench": index, "placed": passed})
	_expect(TutorialMode.step == TutorialMode.Step.START_PVE_1, "three drops advance tutorial")
	var report := {"os": OS.get_name(), "viewport": str(get_viewport().get_visible_rect().size), "results": results, "failures": failures}
	print("IPAD_DRAG_RESULT ", JSON.stringify(report))
	var file := FileAccess.open("user://ipad_drag_probe_result.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
	get_tree().quit(0 if failures.is_empty() else 1)

func _expect(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error(message)

func _drag(from: Vector2, to: Vector2) -> void:
	var transform := get_viewport().get_final_transform()
	var down := InputEventScreenTouch.new()
	down.index = 0
	down.pressed = true
	down.position = transform * from
	Input.parse_input_event(down)
	# Flush synthetic input before measuring state, including on slow simulators.
	Input.flush_buffered_events()
	for i in range(1, 11):
		var drag := InputEventScreenDrag.new()
		drag.index = 0
		drag.position = transform * from.lerp(to, float(i) / 10.0)
		drag.relative = transform.basis_xform((to - from) / 10.0)
		Input.parse_input_event(drag)
		await get_tree().process_frame
	_expect(get_viewport().gui_is_dragging(), "touch starts GUI drag")
	var up := InputEventScreenTouch.new()
	up.index = 0
	up.position = transform * to
	Input.parse_input_event(up)
	Input.flush_buffered_events()
	await get_tree().create_timer(0.3).timeout
