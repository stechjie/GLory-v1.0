extends RefCounted

# 羊皮纸 UI 部件（11.11，跟主菜单 main_menu_v2 同一套画风）。子页面统一从这里拿：
#   box("panel")            九宫格面板 StyleBoxTexture
#   backdrop(page)          主菜单森林背景 + 压暗
#   title_banner("商店")     标题缎带
#   back_button(cb)         左上角圆形返回键
#   button("购买", cb)       金色主按钮 / plain=true 时是羊皮纸次按钮
#   tab("宠物", cb)          页签（选中金色、未选中羊皮纸）
#   ink(label)              深棕字 + 浅描边
# 按钮都会挂 UiJuice（悬停放大 / 按下缩小 / 松手回弹）。
#
# ★ 尺寸口径：项目逻辑分辨率 1600x720（canvas_items 拉伸）。贴图按约 2 倍清晰度存，
#   这里用 ImageTexture.set_size_override 按「逻辑尺寸」显示 —— StyleBoxTexture 的九宫格
#   边距是按贴图像素 1:1 画的，不缩的话面板四角会大一倍；直接存小图又会在高分屏上糊。
# ★ 放在 ui/theme/ 下：procedural_ui_ratchet 不数这个目录（统一样式工厂就该在这）。

const UiJuice := preload("res://ui/theme/UiJuice.gd")
const GloryThemeScript := preload("res://ui/theme/GloryTheme.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const DIR := "res://assets/ui/parchment_kit/"
const MENU_BACKGROUND := "res://assets/ui/main_menu_v2/background.png"

const INK := Color("4a2c14")
const INK_SOFT := Color("7a5634")
const INK_OUTLINE := Color(1.0, 0.95, 0.80, 0.75)
const INK_ON_GOLD := Color("4a2608")

# 名字 -> [文件, 显示缩放, 九宫格边距 L T R B（按原图像素量的，显示时乘缩放）]
# 边距是 python 逐列/逐行跟中线比出来的「装饰区」宽度，换图要重量。
const PIECES := {
	"panel": ["panel.png", 0.5, [146, 162, 148, 145]],
	"card": ["card.png", 0.5, [84, 112, 85, 95]],
	"slot": ["slot.png", 0.4, [65, 68, 65, 62]],
	"list_row": ["list_row.png", 0.32, [196, 54, 201, 67]],
	"list_row_gold": ["list_row_gold.png", 0.32, [196, 54, 201, 67]],
	"input": ["input.png", 0.26, [143, 95, 143, 50]],
	"input_gold": ["input_gold.png", 0.26, [143, 95, 143, 50]],
	# 按钮用的小底板：同一张图缩得更小，四角装饰才不会挤满一颗 48px 高的按钮
	"plate": ["input.png", 0.19, [143, 95, 143, 50]],
	"plate_gold": ["input_gold.png", 0.19, [143, 95, 143, 50]],
	"bubble_self": ["bubble_self.png", 0.32, [90, 85, 129, 95]],
	"bubble_other": ["bubble_other.png", 0.32, [115, 48, 91, 115]],
	# 下面这些不做九宫格（波浪卷轴 / 圆形），整张等比用。
	"title_banner": ["title_banner.png", 0.5, []],
	"button": ["button.png", 0.5, []],
	"button_gold": ["button_gold.png", 0.5, []],
	"tab": ["tab.png", 0.5, []],
	"tab_active": ["tab_active.png", 0.5, []],
	"back": ["back.png", 0.5, []],
	"close": ["close.png", 0.5, []],
	"tag": ["tag.png", 0.5, []],
	"separator": ["separator.png", 0.5, []],
	"versus": ["versus.png", 0.5, []],
	"banner_win": ["banner_win.png", 0.5, []],
	"banner_lose": ["banner_lose.png", 0.5, []],
	"banner_draw": ["banner_draw.png", 0.5, []],
	"medallion_frame": ["medallion_frame.png", 0.5, []],
}

static var _cache: Dictionary = {}


# 按逻辑尺寸显示的贴图（同一张图全局只建一次）。
static func tex(piece: String) -> Texture2D:
	if _cache.has(piece):
		return _cache[piece]
	var spec: Array = PIECES.get(piece, [])
	var path: String = DIR + (str(spec[0]) if not spec.is_empty() else piece + ".png")
	var scale_factor: float = float(spec[1]) if not spec.is_empty() else 0.5
	var source := load(path) as Texture2D
	if source == null:
		return null
	var image := source.get_image()
	if image.is_compressed():
		image.decompress()
	# 缩到一半时没有 mipmap 会有锯齿：生成一下（只在建缓存时做一次）。
	image.generate_mipmaps()
	var texture := ImageTexture.create_from_image(image)
	texture.set_size_override(Vector2i(roundi(image.get_width() * scale_factor),
		roundi(image.get_height() * scale_factor)))
	_cache[piece] = texture
	return texture


static func icon(name: String) -> Texture2D:
	return tex("icon_" + name)


# 九宫格面板。content 是内容离边框的额外留白（逻辑像素）。
static func box(piece: String, content := Vector4(-1, -1, -1, -1), modulate := Color.WHITE) -> StyleBoxTexture:
	var spec: Array = PIECES[piece]
	var k: float = spec[1]
	var m: Array = spec[2]
	var sb := StyleBoxTexture.new()
	sb.texture = tex(piece)
	sb.modulate_color = modulate
	if not m.is_empty():
		sb.texture_margin_left = m[0] * k
		sb.texture_margin_top = m[1] * k
		sb.texture_margin_right = m[2] * k
		sb.texture_margin_bottom = m[3] * k
	var pad := content
	if pad.x < 0.0:
		# 默认留白：边框内侧再缩一点，让文字不压到金边
		pad = Vector4(m[0] * k * 0.85, m[1] * k * 0.72, m[2] * k * 0.85, m[3] * k * 0.6) if not m.is_empty() else Vector4.ZERO
	sb.content_margin_left = pad.x
	sb.content_margin_top = pad.y
	sb.content_margin_right = pad.z
	sb.content_margin_bottom = pad.w
	sb.draw_center = true
	return sb


static func panel(piece := "panel") -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(piece))
	return p


static func ink(label: Control, font_size := 0, big := false, color := INK) -> void:
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("default_color", color)
	label.add_theme_color_override("font_outline_color", INK_OUTLINE)
	label.add_theme_constant_override("outline_size", 6 if big else 3)
	if font_size > 0:
		label.add_theme_font_size_override("font_size", font_size)
		label.add_theme_font_size_override("normal_font_size", font_size)


# 页面背景。scene 为空时用主菜单那张森林空地；否则用 page_backgrounds 里的专属场景：
#   friends_camp（好友 / 聊天）、inventory_storage（背包）、news_square（新闻）、
#   pets_courtyard（备战）、profile_hall（个人页）、rooms_arena（排位 / 自定义房间）、
#   shop_market_v2（商店）。
# 专属背景本身就偏亮、中间空，压暗得少一点；面板主体是羊皮纸，背景只当氛围。
static func backdrop(page: Control, scene := "", dim := -1.0) -> void:
	var bg := TextureRect.new()
	bg.name = "Backdrop"
	bg.texture = load(MENU_BACKGROUND if scene.is_empty() else "res://assets/ui/page_backgrounds/%s.png" % scene)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(bg)
	var shade := ColorRect.new()
	shade.name = "BackdropShade"
	shade.color = Color(0.08, 0.06, 0.03, dim if dim >= 0.0 else (0.38 if scene.is_empty() else 0.16))
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(shade)


# 标题缎带：图 + 居中的字。height 是逻辑高度，宽度按图比例。
static func title_banner(text: String, height := 86.0, font_size := 30) -> Control:
	var t := tex("title_banner")
	var holder := TextureRect.new()
	holder.name = "TitleBanner"
	holder.texture = t
	holder.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	holder.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	holder.custom_minimum_size = Vector2(height * t.get_width() / t.get_height(), height)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var label := Label.new()
	label.name = "TitleText"
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 缎带的纸面偏上，下面是卷边
	label.offset_bottom = -height * 0.16
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ink(label, font_size, true)
	holder.add_child(label)
	return holder


# 只有图、没有字的圆形键（返回 / 关闭 / 图标键）。
static func image_button(piece: String, cb: Callable, side := 64.0) -> Button:
	var t := tex(piece)
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.custom_minimum_size = Vector2(side * t.get_width() / t.get_height(), side)
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for state in ["normal", "hover", "pressed", "disabled"]:
		var sb := StyleBoxTexture.new()
		sb.texture = t
		if state == "hover":
			sb.modulate_color = Color(1.07, 1.07, 1.02)
		elif state == "pressed":
			sb.modulate_color = Color(0.88, 0.85, 0.78)
		elif state == "disabled":
			sb.modulate_color = Color(0.7, 0.7, 0.7, 0.7)
		b.add_theme_stylebox_override(state, sb)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	if cb.is_valid():
		b.pressed.connect(cb)
	UiJuice.attach(b)
	return b


static func back_button(cb: Callable, side := 62.0) -> Button:
	var b := image_button("back", cb, side)
	b.name = "Back"
	b.tooltip_text = "返回"
	return b


static func close_button(cb: Callable, side := 48.0) -> Button:
	var b := image_button("close", cb, side)
	b.name = "Close"
	return b


# 卷轴按钮：gold=金色主按钮，否则羊皮纸。height 逻辑高度，宽度按图比例。
static func button(text: String, cb: Callable, gold := true, height := 58.0, font_size := 22) -> Button:
	var b := image_button("button_gold" if gold else "button", cb, height)
	b.text = text
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(state, INK_ON_GOLD if gold else INK)
	b.add_theme_color_override("font_disabled_color", Color(0.4, 0.33, 0.25, 0.8))
	b.add_theme_color_override("font_outline_color", INK_OUTLINE)
	b.add_theme_constant_override("outline_size", 3)
	b.add_theme_font_size_override("font_size", font_size)
	return b


# 页签。用 toggle 按钮表达选中态，外部用 ButtonGroup 互斥即可。
static func tab(text: String, cb: Callable, height := 46.0, font_size := 19) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.text = text
	if cb.is_valid():
		b.pressed.connect(cb)
	style_tab(b, height, font_size)
	return b


# 把一个现成的按钮（页面自己实例化的组件）换成卷轴页签外观。
# 选中 = button_pressed（toggle_mode），未选中压暗一点。
static func style_tab(b: Button, height := 46.0, font_size := 19) -> void:
	var t := tex("tab")
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.custom_minimum_size = Vector2(height * t.get_width() / t.get_height(), height)
	var off := StyleBoxTexture.new()
	off.texture = t
	off.modulate_color = Color(0.86, 0.82, 0.76)
	var hover := StyleBoxTexture.new()
	hover.texture = t
	var on := StyleBoxTexture.new()
	on.texture = tex("tab_active")
	b.add_theme_stylebox_override("normal", off)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_stylebox_override("hover_pressed", on)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", INK_SOFT)
	b.add_theme_color_override("font_hover_color", INK)
	b.add_theme_color_override("font_pressed_color", INK_ON_GOLD)
	b.add_theme_color_override("font_hover_pressed_color", INK_ON_GOLD)
	b.add_theme_color_override("font_outline_color", INK_OUTLINE)
	b.add_theme_constant_override("outline_size", 3)
	b.add_theme_font_size_override("font_size", font_size)
	UiJuice.attach(b, 1.04, 0.95)


# 把一个现成的按钮换成羊皮纸小底板（gold=金色主操作）。会覆盖掉页面之前写的深色样式。
static func style_plate(b: Button, gold := false) -> void:
	var plate := Vector4(16, 6, 16, 6)
	var base := "plate_gold" if gold else "plate"
	b.add_theme_stylebox_override("normal", box(base, plate))
	b.add_theme_stylebox_override("hover", box(base, plate, Color(1.07, 1.06, 1.0)))
	b.add_theme_stylebox_override("pressed", box(base, plate, Color(0.88, 0.84, 0.78)))
	b.add_theme_stylebox_override("hover_pressed", box(base, plate, Color(0.88, 0.84, 0.78)))
	b.add_theme_stylebox_override("disabled", box("plate", plate, Color(0.75, 0.72, 0.68, 0.75)))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(c, INK_ON_GOLD if gold else INK)
	b.add_theme_color_override("font_disabled_color", Color(0.42, 0.35, 0.27, 0.75))
	b.add_theme_color_override("font_outline_color", INK_OUTLINE)
	b.add_theme_constant_override("outline_size", 2)
	UiJuice.attach(b)


# 列表卡片底（好友行、请求行等）：横向可拉长的纸条。
static func row_box() -> StyleBoxTexture:
	return box("list_row", Vector4(30, 10, 34, 12))


# 列表行的三态样式（常态羊皮纸、选中金色）。行本身由调用方的按钮组件出。
static func style_list_row(b: Button, font_size := 18) -> void:
	var normal := box("list_row", Vector4(26, 6, 30, 8))
	var hover := box("list_row", Vector4(26, 6, 30, 8), Color(1.06, 1.05, 1.0))
	var on := box("list_row_gold", Vector4(26, 6, 30, 8))
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_stylebox_override("hover_pressed", on)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for state in ["font_color", "font_hover_color", "font_focus_color"]:
		b.add_theme_color_override(state, INK)
	b.add_theme_color_override("font_pressed_color", INK_ON_GOLD)
	b.add_theme_color_override("font_hover_pressed_color", INK_ON_GOLD)
	b.add_theme_color_override("font_outline_color", INK_OUTLINE)
	b.add_theme_constant_override("outline_size", 2)
	b.add_theme_font_size_override("font_size", font_size)


# 分隔线：两端叶子不拉伸，中间金线拉长（NinePatchRect，边距按逻辑尺寸）。
static func separator(height := 30.0) -> NinePatchRect:
	var r := NinePatchRect.new()
	r.name = "Separator"
	r.texture = tex("separator")
	r.patch_margin_left = 60
	r.patch_margin_right = 60
	r.custom_minimum_size = Vector2(0, height)
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


# ── 羊皮纸版全局主题 ─────────────────────────────────────────────────────
# 在 GloryTheme 的基础上把常用控件换成羊皮纸外观。子页面 `theme = Kit.theme()` 就能
# 统一掉大部分普通按钮、文字、输入框、面板；页头 / 页签 / 背景再逐页手改。
# 三个按钮变体（GloryPrimary / Danger / Ghost）也一并覆盖，免得页面里冒出深色块。
#
# ★ 默认文字是深棕色 —— 压在背景上（不在面板里）的字要自己改成浅色，
#   用 on_backdrop(label)。
static var _theme: Theme = null

static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := GloryThemeScript.build()
	t.default_font_size = Tokens.FONT_BODY
	var plate := Vector4(16, 6, 16, 6)
	var normal := box("plate", plate)
	var hover := box("plate", plate, Color(1.06, 1.05, 1.0))
	var pressed := box("plate_gold", plate)
	var disabled := box("plate", plate, Color(0.75, 0.72, 0.68, 0.75))
	var gold := box("plate_gold", plate)
	var gold_hover := box("plate_gold", plate, Color(1.07, 1.06, 1.0))
	var gold_pressed := box("plate_gold", plate, Color(0.9, 0.86, 0.8))
	var danger := box("plate", plate, Color(1.0, 0.72, 0.66))
	# 键盘 / 手柄焦点：金色描边（不能留空，否则看不出当前选中哪颗）
	var focus := StyleBoxFlat.new()
	focus.draw_center = false
	focus.border_color = Color(0.93, 0.68, 0.16, 0.95)
	focus.set_border_width_all(3)
	focus.set_corner_radius_all(10)
	focus.set_expand_margin_all(3)
	for type_name in ["Button", "CheckButton", GloryThemeScript.VARIATION_GHOST]:
		t.set_stylebox("normal", type_name, normal)
		t.set_stylebox("hover", type_name, hover)
		t.set_stylebox("pressed", type_name, pressed)
		t.set_stylebox("hover_pressed", type_name, pressed)
		t.set_stylebox("disabled", type_name, disabled)
		t.set_stylebox("focus", type_name, focus)
	for spec in [[GloryThemeScript.VARIATION_PRIMARY, gold, gold_hover, gold_pressed],
			[GloryThemeScript.VARIATION_DANGER, danger, box("plate", plate, Color(1.05, 0.78, 0.72)), box("plate", plate, Color(0.9, 0.62, 0.56))]]:
		t.set_stylebox("normal", spec[0], spec[1])
		t.set_stylebox("hover", spec[0], spec[2])
		t.set_stylebox("pressed", spec[0], spec[3])
		t.set_stylebox("disabled", spec[0], disabled)
		t.set_stylebox("focus", spec[0], focus)
	for type_name in ["Button", "CheckButton", GloryThemeScript.VARIATION_GHOST,
			GloryThemeScript.VARIATION_PRIMARY, GloryThemeScript.VARIATION_DANGER, GloryThemeScript.VARIATION_BUSY]:
		for c in ["font_color", "font_hover_color", "font_focus_color", "font_hover_pressed_color"]:
			t.set_color(c, type_name, INK)
		t.set_color("font_pressed_color", type_name, INK_ON_GOLD)
		t.set_color("font_disabled_color", type_name, Color(0.42, 0.35, 0.27, 0.75))
		t.set_color("font_outline_color", type_name, INK_OUTLINE)
		t.set_constant("outline_size", type_name, 2)
	t.set_color("font_color", GloryThemeScript.VARIATION_DANGER, Color("7a1a10"))
	t.set_color("font_hover_color", GloryThemeScript.VARIATION_DANGER, Color("7a1a10"))
	# 文字
	t.set_color("font_color", "Label", INK)
	t.set_color("font_outline_color", "Label", INK_OUTLINE)
	t.set_constant("outline_size", "Label", 2)
	t.set_color("default_color", "RichTextLabel", INK)
	# 输入框：同一块底板压暗一点，像往里凹
	# 用小号底板：输入框只有 48 高，大号那张的上边装饰会压到字
	var field := box("plate", Vector4(20, 4, 20, 4), Color(0.93, 0.9, 0.84))
	var field_focus := box("plate", Vector4(20, 4, 20, 4), Color(1.0, 0.98, 0.92))
	t.set_stylebox("normal", "LineEdit", field)
	t.set_stylebox("hover", "LineEdit", field)
	t.set_stylebox("focus", "LineEdit", field_focus)
	t.set_stylebox("read_only", "LineEdit", box("plate", Vector4(20, 4, 20, 4), Color(0.8, 0.77, 0.72)))
	for type_name in ["LineEdit", "TextEdit"]:
		t.set_color("font_color", type_name, INK)
		t.set_color("font_placeholder_color", type_name, Color(INK_SOFT, 0.7))
		t.set_color("caret_color", type_name, INK)
		t.set_color("font_selected_color", type_name, INK_ON_GOLD)
		t.set_color("selection_color", type_name, Color(0.95, 0.72, 0.25, 0.5))
	t.set_stylebox("normal", "TextEdit", field)
	t.set_stylebox("focus", "TextEdit", field_focus)
	# 面板：默认给小号金框（四角 26px），大面板由页面显式用 box("panel")
	t.set_stylebox("panel", "PanelContainer", box("slot"))
	t.set_stylebox("panel", "Panel", box("slot"))
	t.set_stylebox("panel", "PopupPanel", box("panel"))
	# 滚动条：深棕细条
	for type_name in ["VScrollBar", "HScrollBar"]:
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color(0.29, 0.17, 0.08, 0.18)
		bg.set_corner_radius_all(4)
		bg.content_margin_left = 3
		bg.content_margin_right = 3
		var grab := StyleBoxFlat.new()
		grab.bg_color = Color(0.55, 0.36, 0.16, 0.85)
		grab.set_corner_radius_all(4)
		var grab_hi := grab.duplicate() as StyleBoxFlat
		grab_hi.bg_color = Color(0.85, 0.6, 0.2, 0.95)
		t.set_stylebox("scroll", type_name, bg)
		t.set_stylebox("grabber", type_name, grab)
		t.set_stylebox("grabber_highlight", type_name, grab_hi)
		t.set_stylebox("grabber_pressed", type_name, grab_hi)
	# 进度条：深棕槽 + 金色填充
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.29, 0.17, 0.08, 0.35)
	bar_bg.set_corner_radius_all(6)
	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color = Color(0.93, 0.68, 0.16)
	bar_fill.set_corner_radius_all(6)
	t.set_stylebox("background", "ProgressBar", bar_bg)
	t.set_stylebox("fill", "ProgressBar", bar_fill)
	t.set_color("font_color", "ProgressBar", INK)
	_theme = t
	return _theme


# 直接压在背景上（不在羊皮纸里）的字：浅色 + 深描边。
static func on_backdrop(label: Control) -> void:
	label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.82))
	label.add_theme_color_override("font_outline_color", Color(0.12, 0.07, 0.025, 0.95))
	label.add_theme_constant_override("outline_size", 5)


# 页头：左边返回键、中间标题缎带、右边可选的附加控件（与返回键等宽占位，保证标题居中）。
static func header(title: String, on_back: Callable, right: Control = null) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Header"
	row.add_theme_constant_override("separation", 12)
	var back := back_button(on_back)
	row.add_child(back)
	var slot := CenterContainer.new()
	slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slot.add_child(title_banner(title, 76.0, 28))
	row.add_child(slot)
	var right_box := HBoxContainer.new()
	right_box.name = "HeaderRight"
	right_box.alignment = BoxContainer.ALIGNMENT_END
	right_box.custom_minimum_size = Vector2(back.custom_minimum_size.x, 0)
	if right != null:
		right_box.add_child(right)
	row.add_child(right_box)
	return row


# ── 结算横幅（第二批图）────────────────────────────────────────────────
# 三张缎带的写字区不在图的正中：胜利上面有颗星、失败下面有把断剑、平局上面有两把剑。
# [纸面上沿, 纸面下沿]（占图高的比例，python 逐行量的），字放在这段的中间。
const RESULT_BANNER_TEXT_BAND := {
	"win": [0.43, 0.78],
	"lose": [0.12, 0.74],
	"draw": [0.52, 0.90],
}
# 失败缎带是灰蓝色，字用浅色；其余两张是浅色纸面，字用深色
const RESULT_TEXT_COLOR := {
	"win": Color("7a3e0c"),
	"lose": Color("f3ead8"),
	"draw": Color("3f4f5a"),
}


static func result_banner(result: String, text: String, height := 110.0, font_size := 42) -> TextureRect:
	var holder := TextureRect.new()
	holder.name = "ResultBanner"
	holder.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	holder.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var label := Label.new()
	label.name = "TitleText"
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ink(label, font_size, true)
	holder.add_child(label)
	set_result_banner(holder, result, height)
	return holder


# 结果变了（回执到了才知道最终输赢）就换图、挪字、换字色。
static func set_result_banner(holder: TextureRect, result: String, height := -1.0) -> void:
	var key := result if RESULT_BANNER_TEXT_BAND.has(result) else "lose"
	var t := tex("banner_" + key)
	holder.texture = t
	var h := height if height > 0.0 else holder.custom_minimum_size.y
	holder.custom_minimum_size = Vector2(h * t.get_width() / t.get_height(), h)
	var label := holder.get_node_or_null("TitleText") as Label
	if label == null:
		return
	var band: Array = RESULT_BANNER_TEXT_BAND[key]
	label.anchor_top = band[0]
	label.anchor_bottom = band[1]
	label.offset_top = 0
	label.offset_bottom = 0
	label.add_theme_color_override("font_color", RESULT_TEXT_COLOR[key])
	label.add_theme_color_override("font_outline_color",
		Color(0.15, 0.17, 0.22, 0.9) if key == "lose" else INK_OUTLINE)
