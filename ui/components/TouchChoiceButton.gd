extends Button

# In-scene choices: native PopupMenu scroll gestures vary between Android hosts.
signal item_selected(index: int)
var selected := -1
var _items: Array[Dictionary] = []
var _modal_id := ""

func _init() -> void:
	pressed.connect(_open_choices)

func add_item(label: String, id: int = -1) -> void:
	_items.append({"text": label, "id": id if id >= 0 else _items.size()})
	if selected < 0:
		select(0)

func clear() -> void:
	_items.clear()
	selected = -1
	text = ""

func select(index: int) -> void:
	if index >= 0 and index < _items.size():
		selected = index
		text = str(_items[index].text)

func get_selected_id() -> int:
	return int(_items[selected].id) if selected >= 0 and selected < _items.size() else -1

func get_item_index(id: int) -> int:
	for i in _items.size():
		if int(_items[i].id) == id:
			return i
	return -1

func get_item_count() -> int:
	return _items.size()

func _choose(index: int) -> void:
	select(index)
	ModalStack.pop(_modal_id)
	_modal_id = ""
	item_selected.emit(index)

func _open_choices() -> void:
	if disabled or not _modal_id.is_empty() and ModalStack.has(_modal_id):
		return
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.065, 0.075, 0.10, 1.0)
	background.border_color = Color(0.8, 0.65, 0.24)
	background.set_border_width_all(2)
	background.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", background)
	center.add_child(panel)
	var column := VBoxContainer.new()
	panel.add_child(column)
	var scroll := ScrollContainer.new()
	var available := get_viewport_rect().size * 0.85
	scroll.custom_minimum_size = Vector2(minf(560, available.x), minf(360, available.y - 56))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 7
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)
	for i in _items.size():
		var choice := Button.new()
		choice.text = str(_items[i].text)
		choice.custom_minimum_size = Vector2(48, 56)
		choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		choice.pressed.connect(_choose.bind(i))
		grid.add_child(choice)
	var cancel := Button.new()
	cancel.text = "关闭" if not LocaleManager.get_locale().begins_with("en") else "Close"
	cancel.custom_minimum_size.y = 48
	cancel.pressed.connect(func(): ModalStack.pop(_modal_id); _modal_id = "")
	column.add_child(cancel)
	_modal_id = ModalStack.push(center, {"id": "touch_choice_%d" % get_instance_id(), "owner": self, "priority": 60, "dismiss_on_backdrop": true})

func _exit_tree() -> void:
	if not _modal_id.is_empty():
		ModalStack.pop(_modal_id)
