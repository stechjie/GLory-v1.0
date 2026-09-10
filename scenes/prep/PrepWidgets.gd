extends RefCounted

# 备战界面的**通用 UI 工具箱** —— D2 第一步。
#
# 这里的东西有一个共同点：**跟备战的业务状态无关**。
# 它们只负责「造一个按钮 / 取一张贴图 / 套一套样式 / 取一个本地化名字」，
# 不读也不写棋盘、商店、宝物那些成员变量。
#
# 为什么先抽它：
# README 的 D2 要把备战 UI 拆成 ShopPanel / BoardHud / TreasureChoicePanel /
# SynergyPanel / BattleStatsPanel 五个自治面板。实测五个面板对宿主的调用里，
# 有 7 个函数是**多个面板共用**的，而且全部不碰成员变量 ——
# 它们不是「面板依赖宿主」，只是「大家都需要的工具恰好放在宿主身上」。
#
# 把这批搬出来之后，面板剩下的对外调用才是真正需要变成信号的那些
# （买入、移动、刷新全屏这类**动作**）。不先做这一步，面板拆不干净。
#
# 全静态、不持任何界面状态。唯一的例外是 _texture_cache，
# 它在原处就是 static var，是进程级贴图缓存，搬过来语义不变。

const CAPTION_WIDTH := 112.0
const CAPTION_HEIGHT := 42.0


# --- 文本与本地化 -------------------------------------------------------------

static func is_en() -> bool:
	return UnitDetailFormat.is_en()


static func localized_name(d: Dictionary) -> String:
	return UnitDetailFormat.localized_name(d)


# 单位显示名统一委托给详情格式器；它会先按 id 取本地正式名称，
# 避免服务器或旧存档携带的历史名称重新出现在界面。
static func unit_name(d: Dictionary) -> String:
	return DataRegistry.unit_display_name(d, LocaleManager.get_locale() == "en")


# --- 贴图缓存 -----------------------------------------------------------------

# 进程级缓存：备战界面每次刷新都会重建大量按钮，不缓存的话同一张框图会被
# load() 几十次。原处就是 static，搬过来语义不变。
static var _texture_cache: Dictionary = {}


static func cached_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	var cached: Texture2D = _texture_cache.get(path)
	if cached != null:
		return cached
	if not ResourceLoader.exists(path):
		return null
	var tex := load(path) as Texture2D
	if tex != null:
		_texture_cache[path] = tex
	return tex


# --- 样式 ---------------------------------------------------------------------

static func apply_empty_button_styles(button: Button) -> void:
	var empty_style := StyleBoxEmpty.new()
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		button.add_theme_stylebox_override(state, empty_style)


static func apply_transparent_panel_style(panel: PanelContainer) -> void:
	panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())


static func apply_refresh_button_styles(button: Button) -> void:
	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = Color(0.025, 0.075, 0.055, 0.78)
	normal_style.border_color = Color(0.34, 0.52, 0.24, 0.82)
	normal_style.set_border_width_all(1)
	normal_style.set_corner_radius_all(4)
	var hover_style := normal_style.duplicate() as StyleBoxFlat
	hover_style.bg_color = Color(0.075, 0.19, 0.105, 0.92)
	hover_style.border_color = Color(0.72, 0.84, 0.36, 0.96)
	var pressed_style := hover_style.duplicate() as StyleBoxFlat
	pressed_style.bg_color = Color(0.04, 0.13, 0.075, 0.96)
	button.add_theme_stylebox_override("normal", normal_style)
	button.add_theme_stylebox_override("hover", hover_style)
	button.add_theme_stylebox_override("pressed", pressed_style)
	button.add_theme_stylebox_override("focus", hover_style)
	button.add_theme_stylebox_override("disabled", normal_style)


# 仿主界面「离线自测」按钮：深棕底 + 古铜边框 + 大圆角。所有备战按钮统一用它。
static func menu_button_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.11, 0.075, 0.035, 0.95)
	s.border_color = Color(0.78, 0.56, 0.24)
	s.set_border_width_all(2)
	s.set_corner_radius_all(16)
	return s


# --- 控件工厂 -----------------------------------------------------------------

# 立绘卡片的通用配置。
#
# on_hover 由调用方传进来（原本这里直接连宿主的 _on_portrait_card_hover）——
# 这正是抽出来的意义：工具箱不该知道宿主有哪些方法。
# 回调签名：func(card: Button, entered: bool)。
static func configure_unframed_portrait_card(card: Button, on_hover: Callable) -> void:
	card.focus_mode = Control.FOCUS_NONE
	card.pivot_offset = card.custom_minimum_size * 0.5
	apply_empty_button_styles(card)
	if on_hover.is_valid():
		card.mouse_entered.connect(on_hover.bind(card, true))
		card.mouse_exited.connect(on_hover.bind(card, false))


# 仿主界面「离线自测」样式按钮（深棕底 + 古铜圆角边框 + 浅金字）。
# 战力 / 统计 / 静音 / 队伍佣兵用它。
static func make_menu_button(label_text: String, size: Vector2, font_size: int, on_press: Callable) -> Button:
	var btn := Button.new()
	btn.text = label_text
	btn.custom_minimum_size = size
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.clip_text = true
	var style := menu_button_style()
	btn.add_theme_stylebox_override("normal", style)
	btn.add_theme_stylebox_override("hover", style)
	btn.add_theme_stylebox_override("pressed", style)
	btn.add_theme_color_override("font_color", Color(1.0, 0.90, 0.60))
	btn.add_theme_font_size_override("font_size", font_size)
	if on_press.is_valid():
		btn.pressed.connect(on_press)
	return btn


# 「带贴图框文字按钮」：高清框背景 + 居中文字。商店 / 佣兵用它（保留原贴图框）。
static func make_framed_text_button(label_text: String, frame_path: String, size: Vector2, font_size: int, on_press: Callable) -> Button:
	var btn := Button.new()
	btn.flat = true
	btn.custom_minimum_size = size
	if on_press.is_valid():
		btn.pressed.connect(on_press)
	var frame := TextureRect.new()
	frame.texture = cached_texture(frame_path)
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(frame)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.anchor_left = 0.14
	lbl.anchor_right = 0.86
	lbl.anchor_top = 0.30
	lbl.anchor_bottom = 0.66
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", Color(0.96, 0.97, 1.0))
	lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	lbl.add_theme_constant_override("outline_size", 3)
	btn.add_child(lbl)
	return btn


# 阵型血量显示：去掉石框和红条，只留血量数字（50/50）。
# 唯一子节点就是数字 Label（调用方按 get_child(0) 取）。
static func create_formation_health_bar(_mirrored: bool) -> Control:
	var stack := Control.new()
	stack.custom_minimum_size = Vector2(96, 56)
	stack.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stack.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var hp_label := Label.new()
	hp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_label.add_theme_font_size_override("font_size", 22)
	hp_label.add_theme_color_override("font_color", Color.WHITE)
	hp_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.96))
	hp_label.add_theme_constant_override("outline_size", 3)
	stack.add_child(hp_label)
	return stack


# 格子正下方的两行「名字\n★星级」标签（棋盘 / 待命共用）。默认隐藏，有棋子时才显示。
# 竖直方向文字居中于框、框中心固定（改字号不会让位置跑）；位置微调改 offset。
static func make_cell_caption() -> Label:
	var cap := Label.new()
	cap.name = "CellCaption"
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cap.anchor_left = 0.5
	cap.anchor_right = 0.5
	cap.anchor_top = 1.0
	cap.anchor_bottom = 1.0
	cap.offset_left = -56
	cap.offset_right = 56
	cap.offset_top = -4       # 名字贴近格子底部，星级落在名字正下方
	cap.offset_bottom = 38
	cap.add_theme_font_size_override("font_size", 16)   # 两行共用；短名在待命区保持完整可读
	cap.add_theme_constant_override("line_spacing", -2)
	cap.clip_text = true
	cap.add_theme_color_override("font_color", Color.WHITE)
	cap.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	cap.add_theme_constant_override("outline_size", 3)
	cap.z_index = 10
	cap.visible = false
	cap.set_meta("caption_w", CAPTION_WIDTH)   # 框宽/高：棋盘按圆心质心定位时用
	cap.set_meta("caption_h", CAPTION_HEIGHT)  # （_fit_cell_to_screen_polygon）
	return cap
