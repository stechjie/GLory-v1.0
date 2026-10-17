extends Node

var failures: Array[String] = []
var results: Array = []

func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func(): get_tree().quit(2))
	await get_tree().process_frame
	TutorialMode.start()
	var prep := load("res://scenes/prep/PrepScreen.tscn").instantiate() as Control
	add_child(prep)
	for i in 8:
		await get_tree().process_frame
	var shop = prep.get("_shop")
	if not shop.picker_open:
		shop.toggle_picker()
	for i in 3:
		await get_tree().process_frame
	var open_rect: Rect2 = shop.open_button.get_global_rect()
	print("SHOP_GEOMETRY viewport=", get_viewport().get_visible_rect(), " open=", open_rect)
	for index in 4:
		var rect: Rect2 = shop.buttons[index].get_global_rect()
		var points := [rect.get_center(), rect.position + rect.size * Vector2(0.25, 0.75), rect.position + rect.size * Vector2(0.75, 0.75)]
		var overlap := rect.intersection(open_rect)
		if overlap.has_area():
			points.append(overlap.get_center())
		for point in points:
			if not shop.picker_open:
				shop.toggle_picker()
			shop.selected = -1
			await get_tree().create_timer(0.2).timeout
			_tap(point)
			await get_tree().process_frame
			var ok: bool = shop.picker_open and shop.selected == index
			results.append({"card": index, "point": str(point), "selected": shop.selected, "open": shop.picker_open, "ok": ok, "hover": str(get_viewport().gui_get_hovered_control()), "rect": str(shop.buttons[index].get_global_rect())})
			if not ok:
				failures.append("card %d point %s selected=%d open=%s" % [index, point, shop.selected, shop.picker_open])
	# Opening remains possible after closing; purchasing uses the real GUI money button.
	if not shop.picker_open:
		shop.toggle_picker()
	_tap(shop.buttons[1].get_global_rect().get_center())
	_tap(shop.buy_button.get_global_rect().get_center())
	await get_tree().process_frame
	if not bool(GameState.shop_sold[1]):
		failures.append("second card purchase through GUI")
	shop.close_picker()
	_tap(shop.open_button.get_global_rect().get_center())
	await get_tree().process_frame
	if not shop.picker_open:
		failures.append("closed scroll reopens shop")
	var report := {"os": OS.get_name(), "viewport": str(get_viewport().get_visible_rect().size), "results": results, "failures": failures}
	var f := FileAccess.open("user://ipad_shop_touch_result.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	print("SHOP_TOUCH_RESULT ", JSON.stringify(report))
	get_tree().quit(0 if failures.is_empty() else 1)

func _tap(point: Vector2) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.pressed = true
	event.position = get_viewport().get_final_transform() * point
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	var up := InputEventScreenTouch.new()
	up.index = 0
	up.position = event.position
	Input.parse_input_event(up)
	Input.flush_buffered_events()
