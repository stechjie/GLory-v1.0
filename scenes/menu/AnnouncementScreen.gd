extends Control

# 公告界面（docs/公告系统设计.md）。入口：主菜单右侧「公告 / 活动」、登录弹窗的「查看详情」。
#
# 左边列表、右边详情。显示到哪条就标记哪条看过（红点灭）。
# 数据只从 AnnouncementService 拿；打开时强制刷新一次，到了就重画。
#
# 正文当 BBCode 显示，但先过 AnnouncementText.sanitize_bbcode 的白名单。
# 链接只许 [url=glory://prep] 这种游戏内页面，点了发 navigate_requested，由 Main 跳。

signal back_requested
signal navigate_requested(route: String)

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const Text := preload("res://scripts/account/AnnouncementText.gd")
# 新按钮一律实例化组件，不写 Button.new()：V3 P1-08 的棘轮盯着自绘按钮数，只能降。
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const MENU_BG_TEX := preload("res://assets/ui/main_menu_live/background.png")

# 公告图一律 2:1（与登录弹窗共用同一张）。框先按比例占好位置，图下下来时版面不跳。
const IMAGE_ASPECT := 2.0
const LIST_WIDTH := 420.0
const ROW_HEIGHT := 64.0

var _selected_id := 0
var _shown_sha := ""
var _image_serial := 0

var _list_box: VBoxContainer
var _detail_box: VBoxContainer
var _empty_label: Label
var _image_frame: Panel
var _image_rect: TextureRect
var _title_label: Label
var _time_label: Label
var _problem_label: Label
var _body_label: RichTextLabel


# 在 add_child 之前调：打开时定位到哪一条（0 = 第一条）。
func configure(focus_id: int) -> void:
	_selected_id = focus_id


func _ready() -> void:
	theme = Theming.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	# deferred：mark_seen 会发 changed，而它常常发生在列表按钮自己的 pressed 回调里 ——
	# 同步重画会在回调中途把那个按钮释放掉。
	AnnouncementService.changed.connect(_render, CONNECT_DEFERRED)
	_render()
	AnnouncementService.refresh(true)


func _exit_tree() -> void:
	# AnnouncementService 是 autoload，活得比这个界面久 —— 连接必须显式断开。
	if AnnouncementService.changed.is_connected(_render):
		AnnouncementService.changed.disconnect(_render)


func selected_id() -> int:
	return _selected_id


# 点列表里的一条。
func select(id: int) -> void:
	_selected_id = id
	_render.call_deferred()


# --- 骨架 ---------------------------------------------------------------------

func _build() -> void:
	var bg := TextureRect.new()
	bg.texture = MENU_BG_TEX
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var dim := ColorRect.new()
	dim.color = Tokens.BACKDROP
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, Tokens.PAD)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", Tokens.GAP_M)
	margin.add_child(root)
	root.add_child(_header())

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", Tokens.GAP_M)
	root.add_child(body)

	var list_panel := PanelContainer.new()
	list_panel.custom_minimum_size = Vector2(LIST_WIDTH, 0)
	list_panel.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE, Tokens.BORDER, Tokens.GAP_S))
	body.add_child(list_panel)
	var list_scroll := ScrollContainer.new()
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_panel.add_child(list_scroll)
	_list_box = VBoxContainer.new()
	_list_box.name = "List"
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override("separation", Tokens.GAP_S)
	list_scroll.add_child(_list_box)

	var detail_panel := PanelContainer.new()
	detail_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_panel.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE, Tokens.BORDER, Tokens.GAP_M))
	body.add_child(detail_panel)
	var detail_scroll := ScrollContainer.new()
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	detail_panel.add_child(detail_scroll)
	_detail_box = VBoxContainer.new()
	_detail_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_box.add_theme_constant_override("separation", Tokens.GAP_M)
	detail_scroll.add_child(_detail_box)

	_empty_label = Label.new()
	_empty_label.name = "Empty"
	_empty_label.text = _t("暂时没有公告", "No announcements right now")
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	_empty_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	_detail_box.add_child(_empty_label)

	# 图片框：宽度跟着详情栏，高度按 2:1 算（_fit_image_frame）。
	# 不用 AspectRatioContainer：它不会按宽度给自己报最小高度，放进 VBox 里会塌成 0 高。
	_image_frame = Panel.new()
	_image_frame.name = "ImageFrame"
	_image_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_image_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_image_frame.add_theme_stylebox_override("panel",
		Tokens.flat_box(Tokens.BG_DEEP, Tokens.BORDER, 1, Tokens.RADIUS_SMALL))
	_image_frame.resized.connect(_fit_image_frame)
	_detail_box.add_child(_image_frame)
	_image_rect = TextureRect.new()
	_image_rect.name = "Image"
	_image_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_image_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# 比例不对的图居中留边，不拉伸、不裁掉。
	_image_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_image_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_image_frame.add_child(_image_rect)

	_title_label = _label("Title", Tokens.FONT_TITLE, Tokens.GOLD)
	_time_label = _label("Time", Tokens.FONT_CAPTION, Tokens.TEXT_SECONDARY)
	# 只有预览账号会收到非空的 problem（服务器写回的图片问题等）。
	_problem_label = _label("Problem", Tokens.FONT_CAPTION, Tokens.DANGER)

	_body_label = RichTextLabel.new()
	_body_label.name = "Body"
	_body_label.bbcode_enabled = true
	_body_label.fit_content = true
	_body_label.scroll_active = false
	_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# PASS：点链接照样能点，手指按在正文上拖也能滚动外面的 ScrollContainer。
	_body_label.mouse_filter = Control.MOUSE_FILTER_PASS
	_body_label.add_theme_font_size_override("normal_font_size", Tokens.FONT_BODY)
	_body_label.add_theme_color_override("default_color", Tokens.TEXT_PRIMARY)
	_body_label.meta_clicked.connect(_on_meta_clicked)
	_detail_box.add_child(_body_label)


func _header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_M)

	var back: Button = ACTION_BUTTON.instantiate()
	back.name = "Back"
	back.text = _t("← 返回", "← Back")
	back.custom_minimum_size = Vector2(160, Tokens.TOUCH_MIN)
	back.pressed.connect(func() -> void: back_requested.emit())
	row.add_child(back)

	var title := Label.new()
	title.text = _t("公告 / 活动", "News / Events")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	row.add_child(title)

	# 与返回按钮等宽的占位，让标题真正居中。
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(160, 0)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)
	return row


func _label(node_name: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.name = node_name
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	_detail_box.add_child(label)
	return label


func _fit_image_frame() -> void:
	var want := floorf(_image_frame.size.x / IMAGE_ASPECT)
	if absf(_image_frame.custom_minimum_size.y - want) >= 1.0:
		_image_frame.custom_minimum_size = Vector2(0, want)


# --- 渲染 ---------------------------------------------------------------------

func _render() -> void:
	if _list_box == null or not is_inside_tree():
		return
	var list := AnnouncementService.items()
	if list.is_empty():
		_selected_id = 0
	elif AnnouncementService.find_item(_selected_id).is_empty():
		_selected_id = int((list[0] as Dictionary).get("id", 0))
	for child in _list_box.get_children():
		_list_box.remove_child(child)
		child.queue_free()
	for entry in list:
		_list_box.add_child(_list_row(entry as Dictionary))
	_render_detail()


func _list_row(item: Dictionary) -> Control:
	var id := int(item.get("id", 0))
	var button: Button = ACTION_BUTTON.instantiate()
	button.name = "Item_%d" % id
	button.toggle_mode = true
	button.button_pressed = id == _selected_id
	button.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.clip_text = true
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# PASS：手指按在按钮上拖也能滚动列表。
	button.mouse_filter = Control.MOUSE_FILTER_PASS
	button.text = Text.row_text(item, _english())
	button.pressed.connect(func() -> void: select(id))

	var dot := Label.new()
	dot.name = "UnreadDot"
	dot.text = "●"
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.add_theme_color_override("font_color", Tokens.UNREAD_DOT)
	dot.add_theme_font_size_override("font_size", 20)
	dot.visible = AnnouncementService.is_unread(item)
	button.add_child(dot)
	dot.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
	dot.position.x -= Tokens.GAP_S
	return button


func _render_detail() -> void:
	var item := AnnouncementService.find_item(_selected_id)
	var has_item := not item.is_empty()
	_empty_label.visible = not has_item
	_title_label.visible = has_item
	_time_label.visible = has_item
	_body_label.visible = has_item
	if not has_item:
		_problem_label.visible = false
		_image_frame.visible = false
		return
	var english := _english()
	_title_label.text = Text.pick_text(item, "title", english)
	_time_label.text = Text.time_text(int(item.get("starts_at", 0)), item.get("ends_at", null),
		int(Time.get_time_zone_from_system().get("bias", 0)), english)
	var problem := str(item.get("problem", ""))
	_problem_label.text = problem
	_problem_label.visible = not problem.is_empty()
	_body_label.text = Text.sanitize_bbcode(Text.pick_text(item, "body", english))
	_show_image(item.get("image", null))
	# 显示出来就算看过。mark_seen 没变化时不发 changed，所以不会来回重画。
	AnnouncementService.mark_seen(item)


func _show_image(image: Variant) -> void:
	var sha := str((image as Dictionary).get("sha256", "")) if image is Dictionary else ""
	if sha == _shown_sha and _image_rect.texture != null:
		_image_frame.visible = true
		return
	_image_serial += 1
	var serial := _image_serial
	_shown_sha = sha
	_image_rect.texture = null
	_image_frame.visible = not sha.is_empty()
	if sha.is_empty():
		return
	var texture: Texture2D = await AnnouncementService.images.texture_for(image)
	# 等下载的时候切到了别的公告、或者界面已经关了。
	if not is_inside_tree() or serial != _image_serial:
		return
	_image_rect.texture = texture
	# 加载失败只显示文字，不弹错误。
	_image_frame.visible = texture != null


func _on_meta_clicked(meta: Variant) -> void:
	var route := Text.link_route(str(meta))
	if not route.is_empty():
		navigate_requested.emit(route)


func _english() -> bool:
	return LocaleManager.get_locale().begins_with("en")


func _t(zh: String, en: String) -> String:
	return en if _english() else zh
