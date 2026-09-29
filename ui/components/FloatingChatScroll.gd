extends ScrollContainer

# 原生滚动负责鼠标滚轮与触摸拖动；独立浮动条不占内容宽度，显隐不触发文字重排。
var floating_bar: VScrollBar
var _syncing := false

func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	floating_bar = VScrollBar.new()
	floating_bar.name = "FloatingHistoryBar"
	floating_bar.top_level = true
	floating_bar.custom_minimum_size.x = 12.0
	floating_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	var track := StyleBoxEmpty.new()
	floating_bar.add_theme_stylebox_override("scroll", track)
	for state in ["grabber", "grabber_highlight", "grabber_pressed"]:
		var thumb := StyleBoxFlat.new()
		thumb.bg_color = Color(0.75, 0.57, 0.28, 0.85)
		thumb.set_corner_radius_all(4)
		thumb.content_margin_left = 6
		thumb.content_margin_right = 6
		floating_bar.add_theme_stylebox_override(state, thumb)
	add_child(floating_bar)
	floating_bar.value_changed.connect(_on_bar_value)
	get_v_scroll_bar().value_changed.connect(_on_scroll_value)
	_sync_bar()

func _process(_delta: float) -> void:
	_sync_bar()

func _on_bar_value(value: float) -> void:
	if not _syncing:
		scroll_vertical = roundi(value)

func _on_scroll_value(_value: float) -> void:
	_sync_bar()

func _sync_bar() -> void:
	if floating_bar == null:
		return
	var source := get_v_scroll_bar()
	_syncing = true
	floating_bar.min_value = source.min_value
	floating_bar.max_value = source.max_value
	floating_bar.page = source.page
	floating_bar.value = source.value
	_syncing = false
	floating_bar.global_position = global_position + Vector2(size.x - 12.0, 0)
	floating_bar.size = Vector2(12.0, size.y)
	floating_bar.visible = is_visible_in_tree() and source.max_value - source.page > 2.0 \
		and source.value < source.max_value - source.page - 2.0
