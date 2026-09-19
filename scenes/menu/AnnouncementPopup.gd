extends Control

# 登录弹窗（docs/公告系统设计.md）。进主菜单时由 Main 按 AnnouncementService.next_popup() 弹，
# 与公告栏共用同一张 2:1 的图。
#
# 遮罩归 ModalStack（点外面可以关），这里只管卡片 —— 同 GloryConfirmDialog 的分工。
# 先 ModalStack.push 再 configure：图片要等下载，节点得已经在树上。

signal details_requested(id: int)
signal dismissed

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const Text := preload("res://scripts/account/AnnouncementText.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")

const IMAGE_WIDTH := 640.0
const IMAGE_ASPECT := 2.0
const BODY_LINES := 3

var _id := 0
var _image_frame: Panel
var _image_rect: TextureRect


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 卡片之外不吃输入 —— 那是 ModalStack 的 backdrop 该管的事。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = Theming.get_theme()


func configure(item: Dictionary) -> void:
	_id = int(item.get("id", 0))
	_build(item)
	_show_image(item.get("image", null))


func _build(item: Dictionary) -> void:
	var english := LocaleManager.get_locale().begins_with("en")
	var center := CenterContainer.new()
	center.name = "PopupCenter"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var card := PanelContainer.new()
	card.name = "PopupCard"
	card.add_theme_stylebox_override("panel", Tokens.panel_box())
	center.add_child(card)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Tokens.GAP_M)
	card.add_child(box)

	_image_frame = Panel.new()
	_image_frame.name = "ImageFrame"
	_image_frame.custom_minimum_size = Vector2(IMAGE_WIDTH, IMAGE_WIDTH / IMAGE_ASPECT)
	_image_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_image_frame.add_theme_stylebox_override("panel",
		Tokens.flat_box(Tokens.BG_DEEP, Tokens.BORDER, 1, Tokens.RADIUS_SMALL))
	box.add_child(_image_frame)
	_image_rect = TextureRect.new()
	_image_rect.name = "Image"
	_image_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_image_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_image_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_image_frame.add_child(_image_rect)

	var title := Label.new()
	title.name = "Title"
	title.text = Text.pick_text(item, "title", english)
	title.custom_minimum_size = Vector2(IMAGE_WIDTH, 0)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Tokens.GOLD)
	box.add_child(title)

	var preview := Text.plain_text(Text.pick_text(item, "body", english))
	if not preview.is_empty():
		var body := Label.new()
		body.name = "Body"
		body.text = preview
		body.custom_minimum_size = Vector2(IMAGE_WIDTH, 0)
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.max_lines_visible = BODY_LINES
		body.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		body.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
		body.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
		box.add_child(body)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", Tokens.GAP_M)
	box.add_child(actions)

	var close: Button = ACTION_BUTTON.instantiate()
	close.name = "Close"
	close.text = "Got it" if english else "知道了"
	close.custom_minimum_size = Vector2(Tokens.BUTTON_MIN_WIDTH, Tokens.BUTTON_HEIGHT)
	close.pressed.connect(func() -> void: dismissed.emit())
	actions.add_child(close)

	var details: Button = ACTION_BUTTON.instantiate()
	details.name = "Details"
	details.text = "Details" if english else "查看详情"
	details.custom_minimum_size = Vector2(Tokens.BUTTON_MIN_WIDTH, Tokens.BUTTON_HEIGHT)
	details.pressed.connect(func() -> void: details_requested.emit(_id))
	actions.add_child(details)


func _show_image(image: Variant) -> void:
	_image_frame.visible = image is Dictionary
	if not (image is Dictionary):
		return
	var texture: Texture2D = await AnnouncementService.images.texture_for(image)
	if not is_inside_tree():
		return
	_image_rect.texture = texture
	# 加载失败就只剩文字，不留一个空框。
	_image_frame.visible = texture != null
