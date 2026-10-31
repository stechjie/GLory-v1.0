extends Control

# 皮肤祈愿：钻石抽碎片，集满 10 片自动解锁那张棋盘皮肤（docs/樱花祈愿.md）。
# 一个弹窗、多套主题：打开前设 skin_id（Main 里做），背景 / 卷轴 / 文案 / 配色 / 粒子按 _themes() 换。
#   prep_skin_sakura     樱花祈愿：夕阳樱花祭坛，花瓣
#   prep_skin_nightwisp  夜荧光祈愿：月夜星光祭坛，黄色星星当碎片 + 暖黄荧光点
#
# 画面：主题背景里的祭坛正中，皮肤自己的卷轴（shop_button 那张图）悬在祭坛上方轻轻浮动，
# 十片碎片围成一道花冠挂在卷轴上空 —— 抽到的碎片从卷轴里飞出来，嵌进花冠。
#
# 结果全部由账号服务器决定（backend/app/skin_draw.py）。这一页只负责：
#   · 显示进度（碎片几片、还要几抽保底）和概率公示；
#   · 发「抽一次」，带一个防重复扣费的 id（断网重发用同一个）；
#   · 把服务器给的结果演出来 —— 动画从来不决定奖励。
#
# 演出按分量分三档（game-feel：小事小动静，大事大动静）：
#   等结果     卷轴蓄力：抖、发亮；
#   没出碎片   小：游戏币数字从卷轴前升起；
#   出碎片     中：卷轴迸出粒子，碎片一片片飞进花冠，格子弹一下；
#   集满解锁   大：白光一闪 + 满屏粒子 + 解锁卡片（可以当场装上）。
#
# 🔴 下面的规则文字和 PRICE / TARGET 是公示给玩家的，真规则在 skin_draw.py；
#    backend/tests/test_skin_draw.py 钉着两边一致。改概率两边一起改（所有主题共用一份规则）。

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const Currency := preload("res://scripts/account/Currency.gd")
const SfxService := preload("res://ui/services/SfxService.gd")
const PrepSkin := preload("res://scenes/prep/PrepSkin.gd")
const PetalTexture := preload("res://scenes/prep/effects/PrepPetalTexture.gd")
const FxTextures := preload("res://scenes/prep/effects/PrepRefreshFxTextures.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")

const DEFAULT_SKIN := "prep_skin_sakura"
const PRICE := 100
const TARGET := 10
const PITY := 10
const CANVAS := Vector2(1600, 720)
# 背景图（1672×941）按画布宽铺满后高 900，上下各裁 90。祭坛 / 卷轴 / 花冠的位置每套背景不同，见 _themes()。
const BG_RECT := Rect2(0, -90, 1600, 900)
const SCROLL_WIDTH := 440.0
const BOB_PIXELS := 9.0
# 花冠：卷轴上空一道弧，十片碎片沿弧排开（圆心在主题里）
const CROWN_RADIUS := Vector2(300, 165)
const CROWN_FROM_DEG := 198.0
const CROWN_TO_DEG := 342.0
const SLOT_SIZE := 50.0

signal draw_finished

# 打开前设好（Main 里 new() 之后、add_child 之前）。不认识的 id 当樱花。
var skin_id := DEFAULT_SKIN
var _th: Dictionary

var _shards := -1
var _draws := 0
var _owned := false
var _diamond := -1
var _busy := false
var _loading := false
var _charging := false
var _pending_draw_id := ""
var _time := 0.0

var _canvas: Control
var _balance: Label
var _draw_button: Button
var _retry: Button
var _pity_label: Label
var _progress_label: Label
var _notice: Label
var _owned_badge: Control
# 卷轴用 Sprite2D 不用 TextureRect：界面控件的位置会被吸附到整像素（snap_controls_to_pixels），
# 几个像素的浮动会一格一格地跳；Sprite2D 按小数像素走，浮得顺。
var _scroll: Sprite2D
var _scroll_base_scale := Vector2.ONE
var _scroll_glow: TextureRect
var _scroll_shadow: TextureRect
var _scroll_petals: CPUParticles2D
var _slots: Array[TextureRect] = []
var _halos: Array[TextureRect] = []   # 只有夜荧光有：和 _slots 一一对应
var _overlay: Control


# 每套主题：背景、祭坛位置、文案、配色、粒子。坐标都是 1600×720 画布坐标。
#   altar_top     祭坛台面中心（卷轴投影落在这里）
#   scroll_center 卷轴悬浮中心；crown_center 花冠圆心
#   bits          petal = 花瓣（普通混合）；wisp = 荧光点（加亮混合）+ 黄色星星当花冠
static func _themes() -> Dictionary:
	return {
		"prep_skin_sakura": {
			"bg": "res://assets/ui/shop/sakura_wish_bg.png",
			"title": ["樱花祈愿", "Sakura Wish"],
			"name": ["樱花棋盘", "Sakura Board"],
			"shard": ["樱花碎片", "Sakura shards"],
			"desc": ["整片棋盘落满樱花：摆放界面飘起花瓣，刷新商店时卷轴化作花瓣随风吹散。",
				"Blossoms across your board: drifting petals in preparation, and a shop scroll that scatters into petals."],
			"altar_top": Vector2(800, 392), "scroll_center": Vector2(800, 262), "crown_center": Vector2(800, 292),
			"bits": "petal",
			"glass": Tokens.SAKURA_GLASS, "edge": Tokens.SAKURA_EDGE, "accent": Tokens.SAKURA_PINK,
			"text": Tokens.SAKURA_TEXT, "muted": Tokens.SAKURA_TEXT_MUTED, "text_edge": Tokens.SAKURA_TEXT_EDGE,
			"socket": Tokens.SAKURA_SOCKET, "slot_empty": Tokens.SAKURA_SLOT_EMPTY,
			"flash": Tokens.SAKURA_FLASH, "glow": Tokens.SAKURA_PINK, "bit_color": Color.WHITE,
		},
		"prep_skin_nightwisp": {
			"bg": "res://assets/ui/shop/nightwisp_wish_bg.png",
			"title": ["夜荧光祈愿", "Night Wisp Wish"],
			"name": ["夜荧光棋盘", "Night Wisp Board"],
			"shard": ["荧光碎片", "Wisp shards"],
			"desc": ["月夜下的荧光森林：星光萤火满场飘浮，水晶萝卜与星光祭坛，刷新商店时卷轴化作黄色荧光飞散。",
				"A moonlit glowing forest: violet wisps drift over your board, crystal carrot and starlit altar, and a shop scroll that dissolves into golden wisps."],
			"altar_top": Vector2(813, 438), "scroll_center": Vector2(813, 300), "crown_center": Vector2(813, 330),
			"bits": "wisp",
			"glass": Tokens.NIGHT_GLASS, "edge": Tokens.NIGHT_EDGE, "accent": Tokens.NIGHT_ACCENT,
			"text": Tokens.NIGHT_TEXT, "muted": Tokens.NIGHT_TEXT_MUTED, "text_edge": Tokens.NIGHT_TEXT_EDGE,
			"socket": Tokens.NIGHT_SOCKET, "slot_empty": Tokens.NIGHT_SLOT_EMPTY,
			"flash": Tokens.NIGHT_FLASH, "glow": Tokens.NIGHT_GLOW, "bit_color": Tokens.NIGHT_STAR,
		},
	}


func _txt(key: String) -> String:
	var pair: Array = _th[key]
	return _t(str(pair[0]), str(pair[1]))


func _wisp() -> bool:
	return str(_th.bits) == "wisp"


# 花冠格子和飞进花冠的那一片：樱花 = 花瓣，夜荧光 = 发光的黄星星
func _slot_texture() -> Texture2D:
	return FxTextures.star() if _wisp() else PetalTexture.get_texture()


# 满屏飘的、卷轴身边冒的、迸发的小粒子：樱花 = 花瓣，夜荧光 = 发光的荧光点
func _bit_texture() -> Texture2D:
	return FxTextures.spark() if _wisp() else PetalTexture.get_texture()


# 夜荧光的粒子用加亮混合：荧光点叠在深色夜景上才会「发光」
func _style_bits(p: CPUParticles2D) -> void:
	p.color = _th.bit_color
	if _wisp():
		var mat := CanvasItemMaterial.new()
		mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		p.material = mat


func _ready() -> void:
	_th = _themes().get(skin_id, _themes()[DEFAULT_SKIN])
	theme = Theming.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	_fit_canvas()
	_load_state()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _canvas != null:
		_fit_canvas()


func _fit_canvas() -> void:
	var factor := minf(size.x / CANVAS.x, size.y / CANVAS.y)
	_canvas.scale = Vector2.ONE * factor
	_canvas.position = (size - CANVAS * factor) * 0.5


# 卷轴浮动、光晕呼吸；蓄力时抖得更快、更亮。
func _process(delta: float) -> void:
	if _scroll == null:
		return
	_time += delta
	var bob := sin(_time * 1.6) * BOB_PIXELS
	var sway := sin(_time * 1.1) * 0.025
	var glow := 0.75 + 0.2 * sin(_time * 2.0)
	var jitter := Vector2.ZERO
	if _charging:
		jitter = Vector2(sin(_time * 53.0), cos(_time * 47.0)) * 3.0
		sway += sin(_time * 31.0) * 0.02
		glow = 0.95
	_scroll.position = _th.scroll_center + Vector2(0, bob) + jitter
	_scroll.rotation = sway
	_scroll_glow.modulate.a = glow
	# 光晕不跟着浮：它也是界面控件，会被吸附到整像素；软光不动只呼吸，看不出来
	_scroll_glow.position = _th.scroll_center - _scroll_glow.size * 0.5
	_scroll_petals.position = _th.scroll_center + Vector2(0, bob)
	# 往上浮 → 影子收小变淡；往下沉 → 影子放大变实
	var lift := (bob + BOB_PIXELS) / (2.0 * BOB_PIXELS)
	_scroll_shadow.scale = Vector2.ONE * lerpf(1.08, 0.9, 1.0 - lift)
	_scroll_shadow.modulate.a = lerpf(0.22, 0.34, lift)


# --- 骨架 ---------------------------------------------------------------------

func _build() -> void:
	var shrine := load(str(_th.bg)) as Texture2D
	# 整屏垫一层（画布缩放后屏幕边上留下的空白也是祭坛），画布里再放一层对齐坐标的
	var edge_bg := TextureRect.new()
	edge_bg.texture = shrine
	edge_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	edge_bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	edge_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	edge_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(edge_bg)

	_canvas = Control.new()
	_canvas.size = CANVAS
	_canvas.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_canvas)
	var bg := TextureRect.new()
	bg.texture = shrine
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect(bg, BG_RECT.position.x, BG_RECT.position.y, BG_RECT.size.x, BG_RECT.size.y)
	_canvas.add_child(bg)
	_canvas.add_child(_ambient_petals())

	_build_scroll()
	_build_crown()
	_build_cards()
	_build_bottom()

	var title := _label(_txt("title"), 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rect(title, 560, 14, 480, 52)
	_canvas.add_child(title)
	var balance_row := HBoxContainer.new()
	balance_row.alignment = BoxContainer.ALIGNMENT_END
	balance_row.add_theme_constant_override("separation", 7)
	_rect(balance_row, 1250, 22, 250, 40)
	_canvas.add_child(balance_row)
	var diamond_icon := TextureRect.new()
	diamond_icon.texture = Currency.icon("diamond")
	diamond_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	diamond_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	diamond_icon.custom_minimum_size = Vector2(32, 32)
	diamond_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	balance_row.add_child(diamond_icon)
	_balance = _label("", 21)
	_balance.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	balance_row.add_child(_balance)
	var close := _button("✕", Vector2(56, 56))
	_rect(close, 1520, 14, 56, 56)
	close.pressed.connect(_close)
	_canvas.add_child(close)
	_refresh_ui()


# 悬浮的卷轴：背后一圈加亮的光晕，身边一直有花瓣 / 荧光点慢慢冒出来。
func _build_scroll() -> void:
	_scroll_shadow = TextureRect.new()
	_scroll_shadow.texture = FxTextures.disc()
	_scroll_shadow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_scroll_shadow.stretch_mode = TextureRect.STRETCH_SCALE
	_scroll_shadow.size = Vector2(SCROLL_WIDTH * 0.72, 38)
	_scroll_shadow.pivot_offset = _scroll_shadow.size * 0.5
	_scroll_shadow.position = _th.altar_top - _scroll_shadow.size * 0.5
	_scroll_shadow.self_modulate = _th.text_edge
	_scroll_shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(_scroll_shadow)

	_scroll_glow = TextureRect.new()
	_scroll_glow.texture = FxTextures.glow()
	_scroll_glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_scroll_glow.stretch_mode = TextureRect.STRETCH_SCALE
	_scroll_glow.size = Vector2(SCROLL_WIDTH * 1.5, SCROLL_WIDTH * 0.7)
	_scroll_glow.modulate = Color(1, 1, 1, 0.6)
	_scroll_glow.self_modulate = _th.glow
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_scroll_glow.material = add
	_scroll_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(_scroll_glow)

	_scroll_petals = CPUParticles2D.new()
	_scroll_petals.texture = _bit_texture()
	_scroll_petals.amount = 14
	_scroll_petals.lifetime = 3.2
	_scroll_petals.preprocess = 3.2
	_scroll_petals.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	_scroll_petals.emission_rect_extents = Vector2(SCROLL_WIDTH * 0.45, 30)
	_scroll_petals.direction = Vector2(0, 1)
	_scroll_petals.spread = 70.0
	_scroll_petals.initial_velocity_min = 12.0
	_scroll_petals.initial_velocity_max = 36.0
	_scroll_petals.gravity = Vector2(6, 18)
	_scroll_petals.angle_max = 360.0
	_scroll_petals.angular_velocity_min = -90.0
	_scroll_petals.angular_velocity_max = 90.0
	_scroll_petals.scale_amount_min = 0.25
	_scroll_petals.scale_amount_max = 0.5
	_scroll_petals.color_ramp = _fade_ramp()
	_style_bits(_scroll_petals)
	if _wisp():
		# 荧光点往上飘（花瓣往下落）
		_scroll_petals.direction = Vector2(0, -1)
		_scroll_petals.gravity = Vector2(4, -14)
		_scroll_petals.scale_amount_min = 0.6
		_scroll_petals.scale_amount_max = 1.3
	_canvas.add_child(_scroll_petals)

	_scroll = Sprite2D.new()
	_scroll.texture = load(PrepSkin.path_for(skin_id, "shop_button")) as Texture2D
	if _scroll.texture != null:
		_scroll_base_scale = Vector2.ONE * (SCROLL_WIDTH / float(_scroll.texture.get_width()))
	_scroll.scale = _scroll_base_scale
	_scroll.position = _th.scroll_center
	_canvas.add_child(_scroll)


func _crown_point(i: int) -> Vector2:
	var t := float(i) / float(TARGET - 1)
	var a := deg_to_rad(lerpf(CROWN_FROM_DEG, CROWN_TO_DEG, t))
	return _th.crown_center + Vector2(cos(a) * CROWN_RADIUS.x, sin(a) * CROWN_RADIUS.y)


func _build_crown() -> void:
	for i in TARGET:
		# 深色圆底：花冠挂在花树前，没有底衬的话亮起来的碎片会被背景吃掉
		var socket := TextureRect.new()
		socket.texture = FxTextures.disc()
		socket.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		socket.stretch_mode = TextureRect.STRETCH_SCALE
		socket.self_modulate = _th.socket
		socket.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var c := _crown_point(i)
		_rect(socket, c.x - SLOT_SIZE * 0.78, c.y - SLOT_SIZE * 0.78, SLOT_SIZE * 1.56, SLOT_SIZE * 1.56)
		_canvas.add_child(socket)
		var p := _crown_point(i)
		if _wisp():
			# 亮起来的星星背后一圈加亮的暖黄光：星星在发光，没亮的就只剩深色空位
			var halo := TextureRect.new()
			halo.texture = FxTextures.glow()
			halo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			halo.stretch_mode = TextureRect.STRETCH_SCALE
			halo.self_modulate = _th.bit_color
			var add := CanvasItemMaterial.new()
			add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
			halo.material = add
			halo.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_rect(halo, p.x - SLOT_SIZE * 0.9, p.y - SLOT_SIZE * 0.9, SLOT_SIZE * 1.8, SLOT_SIZE * 1.8)
			halo.visible = false
			_canvas.add_child(halo)
			_halos.append(halo)
		var slot := TextureRect.new()
		slot.name = "Shard%d" % i
		slot.texture = _slot_texture()
		slot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		slot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 星星贴图外圈是柔光，实心部分比花瓣小一圈，放大一些才一样醒目
		var slot_size := SLOT_SIZE * (1.3 if _wisp() else 1.0)
		_rect(slot, p.x - slot_size * 0.5, p.y - slot_size * 0.5, slot_size, slot_size)
		slot.pivot_offset = Vector2(slot_size, slot_size) * 0.5
		# 尖朝外：沿花冠的法线方向，像一圈向外绽开的花 / 放射的星光
		slot.rotation = (p - _th.crown_center).angle() + PI * 0.5
		_canvas.add_child(slot)
		_slots.append(slot)


func _build_cards() -> void:
	# 左：解锁后长什么样
	var left := PanelContainer.new()
	left.add_theme_stylebox_override("panel", Tokens.panel_box(
		_th.glass, _th.edge, 14))
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect(left, 36, 96, 392, 0)
	_canvas.add_child(left)
	var lcol := VBoxContainer.new()
	lcol.add_theme_constant_override("separation", 8)
	left.add_child(lcol)
	var eyebrow := _label(_t("限定棋盘皮肤", "LIMITED BOARD SKIN"), 16)
	eyebrow.add_theme_color_override("font_color", _th.accent)
	lcol.add_child(eyebrow)
	var name_label := _label(_txt("name"), 34)
	lcol.add_child(name_label)
	var art_frame := Control.new()
	art_frame.custom_minimum_size = Vector2(364, 205)
	art_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lcol.add_child(art_frame)
	var art := TextureRect.new()
	var preview_path := PrepSkin.preview_path(skin_id)
	art.texture = load(preview_path) as Texture2D if ResourceLoader.exists(preview_path) else null
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art_frame.add_child(art)
	var badge := PanelContainer.new()
	badge.add_theme_stylebox_override("panel", Tokens.panel_box(
		_th.glass, _th.edge, 8))
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.position = Vector2(10, 10)
	badge.add_child(_label(_t("已永久拥有", "Owned forever"), 17))
	art_frame.add_child(badge)
	_owned_badge = badge
	var desc := _label(_txt("desc"), 16)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_color_override("font_color", _th.muted)
	desc.custom_minimum_size.x = 364
	lcol.add_child(desc)

	# 右：概率公示（付款前必须看得到）
	var right := PanelContainer.new()
	right.add_theme_stylebox_override("panel", Tokens.panel_box(
		_th.glass, _th.edge, 14))
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect(right, 1172, 96, 392, 0)
	_canvas.add_child(right)
	var rcol := VBoxContainer.new()
	rcol.add_theme_constant_override("separation", 8)
	right.add_child(rcol)
	var rule_title := _label(_t("概率公示", "Odds"), 22)
	rule_title.add_theme_color_override("font_color", _th.accent)
	rcol.add_child(rule_title)
	var rule_text := _label(_t(
		"每次祈愿消耗 100 钻石\n碎片 ×1  30%\n碎片 ×2  21%\n碎片 ×3  9%\n游戏币 200～300  40%（按 10 一档随机）\n\n第 10 抽碎片不足 10 片时直接补满；集满自动解锁，拥有后不能再祈愿。",
		"100 gems per wish\n1 shard  30%\n2 shards  21%\n3 shards  9%\nCoins 200–300  40% (in steps of 10)\n\nDraw 10 tops you up to 10 shards. Unlocks automatically; no more wishes once owned."), 17)
	rule_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rule_text.custom_minimum_size.x = 364
	rule_text.add_theme_color_override("font_color", _th.muted)
	rcol.add_child(rule_text)


func _build_bottom() -> void:
	_progress_label = _label("", 24)
	_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rect(_progress_label, 500, 520, 600, 34)
	_canvas.add_child(_progress_label)
	_pity_label = _label("", 18)
	_pity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pity_label.add_theme_color_override("font_color", _th.text)
	_rect(_pity_label, 500, 554, 600, 28)
	_canvas.add_child(_pity_label)
	_draw_button = _button("", Vector2(380, 76))
	_draw_button.theme_type_variation = Theming.VARIATION_PRIMARY
	_draw_button.add_theme_font_size_override("font_size", 27)
	_rect(_draw_button, 610, 594, 380, 76)
	_draw_button.pressed.connect(_on_draw_pressed)
	_canvas.add_child(_draw_button)
	_notice = _label("", 17)
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rect(_notice, 450, 676, 700, 28)
	_canvas.add_child(_notice)
	_retry = _button(_t("重试读取", "Retry"), Vector2(170, 52))
	_rect(_retry, 1010, 606, 170, 52)
	_retry.pressed.connect(_load_state)
	_canvas.add_child(_retry)


# 满屏慢慢飘的粒子：樱花是落花（和摆放界面同一张贴图），夜荧光是往上飘的荧光点。
func _ambient_petals() -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.name = "AmbientPetals"
	p.texture = _bit_texture()
	p.amount = 24
	p.lifetime = 9.0
	p.preprocess = 9.0
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = Vector2(0.3, 1.0)
	p.spread = 20.0
	p.initial_velocity_min = 30.0
	p.initial_velocity_max = 60.0
	p.gravity = Vector2(10.0, 12.0)
	p.angular_velocity_min = -90.0
	p.angular_velocity_max = 90.0
	p.angle_max = 360.0
	p.scale_amount_min = 0.35
	p.scale_amount_max = 0.7
	p.color = Color(1, 1, 1, 0.85)
	p.position = Vector2(700, -40)
	p.emission_rect_extents = Vector2(1000, 10)
	if _wisp():
		# 荧光点：从下半屏冒出来慢慢往上飘、忽明忽暗
		_style_bits(p)
		p.color_ramp = _fade_ramp()
		p.position = Vector2(800, 640)
		p.emission_rect_extents = Vector2(900, 120)
		p.direction = Vector2(0.1, -1.0)
		p.gravity = Vector2(0, -6)
		p.initial_velocity_min = 10.0
		p.initial_velocity_max = 30.0
		p.lifetime = 7.0
		p.preprocess = 7.0
		p.amount = 40
		p.scale_amount_min = 0.6
		p.scale_amount_max = 1.5
	return p


static func _fade_ramp() -> Gradient:
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.12, 0.75, 1.0])
	ramp.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0.9), Color(1, 1, 1, 0)])
	return ramp


# --- 状态 ---------------------------------------------------------------------

func _load_state() -> void:
	if _loading:
		return
	_loading = true
	_notice.text = _t("正在读取…", "Loading…")
	_refresh_ui()
	var state: Dictionary = await AccountManager.fetch_skin_draw_state(skin_id)
	if not is_inside_tree():
		return
	if int(state.get("code", 0)) / 100 != 2:
		_loading = false
		_notice.text = _t("祈愿暂不可用：%s", "Wish unavailable: %s") % str(state.get("error", "HTTP 500"))
		_refresh_ui()
		return
	var wallet: Dictionary = await AccountManager.fetch_wallet()
	if not is_inside_tree():
		return
	var body: Dictionary = state.get("body", {})
	_shards = int(body.get("shards", 0))
	_draws = int(body.get("draws", 0))
	_owned = bool(body.get("owned", false))
	_loading = false
	if int(wallet.get("code", 0)) / 100 != 2:
		_diamond = -1
		_notice.text = _t("余额读取失败，请重试", "Could not load balance; please retry")
	else:
		_diamond = int((wallet.get("body", {}) as Dictionary).get("diamond", -1))
		_notice.text = ""
	_refresh_ui()


func _refresh_ui() -> void:
	if _draw_button == null:
		return
	var ready := _shards >= 0
	_balance.text = Currency.comma(_diamond) if _diamond >= 0 else ""
	_retry.visible = not _loading and (not ready or _diamond < 0)
	_owned_badge.visible = _owned
	var lit := TARGET if _owned else maxi(_shards, 0)
	for i in _slots.size():
		_set_slot_lit(_slots[i], i < lit)
	if not ready and not _owned:
		_progress_label.text = "%s  — / %d" % [_txt("shard"), TARGET]
	else:
		_progress_label.text = "%s  %d / %d" % [_txt("shard"), lit, TARGET]
	var in_use := PrepSkin.active_id == skin_id
	if _owned:
		_draw_button.text = _t("使用中", "In use") if in_use else _t("立即使用", "Equip now")
		_draw_button.disabled = _busy or in_use
		_pity_label.text = _t("已集齐，%s永久属于你", "Collected — the %s is yours") % _txt("name")
	else:
		var poor := _diamond >= 0 and _diamond < PRICE
		_draw_button.text = _t("钻石不足", "Not enough gems") if poor else _t(
			"祈愿 · %d 钻石" % PRICE, "Wish · %d gems" % PRICE)
		_draw_button.disabled = _busy or _loading or not ready or _diamond < PRICE
		var left := maxi(1, PITY - _draws)
		_pity_label.text = _t("最多再祈愿 %d 次必定集齐" % left, "Guaranteed within %d more wishes" % left) if ready else ""


func _set_slot_lit(slot: TextureRect, lit: bool) -> void:
	slot.modulate = Color.WHITE if lit else _th.slot_empty
	var i := _slots.find(slot)
	if i >= 0 and i < _halos.size():
		_halos[i].visible = lit


# --- 抽 -----------------------------------------------------------------------

func _on_draw_pressed() -> void:
	if _busy or _overlay != null:
		return
	if _owned:
		_equip()
		return
	if _diamond < PRICE or _shards < 0:
		return
	_commit_draw()


func _commit_draw() -> void:
	if _busy:
		return
	_busy = true
	_charging = true
	_notice.text = _t("卷轴正在回应你的祈愿…", "The scroll answers your wish…")
	_refresh_ui()
	if _pending_draw_id.is_empty():
		_pending_draw_id = AccountManager.new_client_order_id()
	var before := _shards
	var started := Time.get_ticks_msec()
	var result: Dictionary = await AccountManager.draw_skin_shard(skin_id, _pending_draw_id)
	if not is_inside_tree():
		return
	# 蓄力至少演 0.5 秒：网络太快时结果会「啪」一下就出来，没有期待感
	var remaining := Tokens.motion(0.5) - float(Time.get_ticks_msec() - started) / 1000.0
	if remaining > 0.0:
		await get_tree().create_timer(remaining).timeout
		if not is_inside_tree():
			return
	_charging = false
	var code := int(result.get("code", 0))
	if code / 100 != 2:
		_busy = false
		# 断网 / 服务器出错：保留同一个 id，再点一次就是重发，服务器不会重复扣钱。
		if not (code == 0 or code >= 500):
			_pending_draw_id = ""
		_notice.text = str(result.get("error", _t("祈愿失败", "Wish failed")))
		SfxService.play(SfxService.CUE_UI_REJECT)
		_refresh_ui()
		if code == 409:
			_load_state()   # 已经拥有（别的设备抽满了）：按服务器的状态重读
		return
	_pending_draw_id = ""
	var receipt: Dictionary = result.get("body", {})
	var replayed := bool(receipt.get("replayed", false))
	_diamond = int(receipt.get("diamond", _diamond))
	var gained := int(receipt.get("shards_gained", 0))
	var coin := int(receipt.get("coin_reward", 0))
	var after := int(receipt.get("shards", before))
	_draws = int(receipt.get("draws", _draws))
	var unlocked := bool(receipt.get("unlocked", false))
	if not replayed:
		SfxService.play(SfxService.CUE_UI_CURRENCY_SPEND)
	_notice.text = ""
	draw_finished.emit()
	# 演出期间按钮保持锁住：花冠还没亮完就能再点，下一抽的结果会和这一抽的动画叠在一起。
	if gained > 0:
		await _play_shards(clampi(before, 0, TARGET), clampi(after, 0, TARGET))
	else:
		_shards = after
		_refresh_ui()
		await _play_coin(coin)
	if not is_inside_tree():
		return
	_shards = after
	if unlocked:
		_owned = true
		_busy = false
		_refresh_ui()
		await _celebrate()
	else:
		_busy = false
		_refresh_ui()


func _scroll_center() -> Vector2:
	return _scroll.position


# 中档：卷轴迸出花瓣，花瓣一片接一片飞进花冠，到了格子弹一下。
func _play_shards(from: int, to: int) -> void:
	var start := _scroll_center()
	_burst(start, 30, 1.0)
	_kick_scroll()
	SfxService.play(SfxService.CUE_UI_CONFIRM)
	var flights: Array[Tween] = []
	for i in range(from, to):
		var slot := _slots[i]
		var petal := TextureRect.new()
		petal.texture = _slot_texture()
		petal.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		petal.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		petal.mouse_filter = Control.MOUSE_FILTER_IGNORE
		petal.size = Vector2(SLOT_SIZE, SLOT_SIZE) * 1.5
		petal.pivot_offset = petal.size * 0.5
		petal.position = start - petal.size * 0.5
		petal.scale = Vector2.ONE * 0.3
		_canvas.add_child(petal)
		var delay := Tokens.motion(0.13) * float(i - from)
		var fly_time := Tokens.motion(0.48)
		var tw := create_tween()
		tw.tween_interval(delay)
		tw.tween_property(petal, "scale", Vector2.ONE, Tokens.motion(0.16)).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(petal, "position", slot.position + (slot.size - petal.size) * 0.5, fly_time) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.parallel().tween_property(petal, "rotation", slot.rotation + TAU, fly_time)
		tw.parallel().tween_property(petal, "scale", Vector2.ONE * (SLOT_SIZE / petal.size.x), fly_time)
		tw.tween_callback(func() -> void:
			petal.queue_free()
			_set_slot_lit(slot, true)
			slot.scale = Vector2.ONE * 1.7
			var pop := create_tween()
			pop.tween_property(slot, "scale", Vector2.ONE, Tokens.motion(0.28)).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			_burst(slot.position + slot.size * 0.5, 8, 0.5)
			SfxService.play(SfxService.CUE_UI_CURRENCY_GAIN))
		flights.append(tw)
	_progress_label.text = "%s +%d" % [_txt("shard"), to - from]
	if not flights.is_empty():
		await flights[-1].finished
	await get_tree().create_timer(Tokens.motion(0.3)).timeout


# 卷轴被「顶」一下：先压扁再弹回（squash & stretch）。
func _kick_scroll() -> void:
	_scroll.scale = _scroll_base_scale * Vector2(1.12, 0.86)
	var tw := create_tween()
	tw.tween_property(_scroll, "scale", _scroll_base_scale, Tokens.motion(0.35)).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


# 小档：没出碎片，游戏币数字从卷轴前升起。
func _play_coin(coin: int) -> void:
	var pop := _label(_t("游戏币 +%d", "Coins +%d") % coin, 34)
	pop.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	pop.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var center := _scroll_center()
	_rect(pop, center.x - 200, center.y + 30, 400, 48)
	pop.pivot_offset = pop.size * 0.5
	pop.scale = Vector2.ONE * 0.6
	_canvas.add_child(pop)
	SfxService.play(SfxService.CUE_UI_CURRENCY_GAIN)
	var tw := create_tween()
	tw.tween_property(pop, "scale", Vector2.ONE, Tokens.motion(0.18)).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(pop, "position:y", pop.position.y - 60, Tokens.motion(0.9)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(pop, "modulate:a", 0.0, Tokens.motion(0.35))
	tw.tween_callback(pop.queue_free)
	_notice.text = _t("这次没有碎片，获得 %d 游戏币", "No shard this time — %d coins") % coin
	await get_tree().create_timer(Tokens.motion(0.5)).timeout


# 大档：集满。白光一闪、卷轴炸出满屏花瓣，然后弹解锁卡片。
func _celebrate() -> void:
	# 白光和遮罩铺满整个屏幕，不跟画布走：画布按比例缩放后上下 / 左右会留边
	var flash := ColorRect.new()
	flash.color = _th.flash
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(flash)
	var fade := create_tween()
	fade.tween_property(flash, "modulate:a", 0.0, Tokens.motion(0.45)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	fade.tween_callback(flash.queue_free)
	_kick_scroll()
	_burst(_scroll_center(), 110, 2.3)
	SfxService.play(SfxService.CUE_SYNERGY_ACTIVATE)
	await get_tree().create_timer(Tokens.motion(0.4)).timeout
	if is_inside_tree():
		_show_unlocked()


func _show_unlocked() -> void:
	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_overlay)
	var shade := ColorRect.new()
	shade.color = Tokens.BACKDROP
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(shade)
	# 卡片按画布坐标摆，和画布同一个缩放
	var layer := Control.new()
	layer.mouse_filter = Control.MOUSE_FILTER_PASS
	layer.size = CANVAS
	layer.scale = _canvas.scale
	layer.position = _canvas.position
	_overlay.add_child(layer)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", Tokens.panel_box(
		_th.glass, _th.edge, 24))
	_rect(card, 480, 110, 640, 0)
	layer.add_child(card)
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", Tokens.GAP_M)
	card.add_child(col)
	var head := _label(_t("%s  已解锁！", "%s unlocked!") % _txt("name"), 36)
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(head)
	var art := TextureRect.new()
	var preview_path := PrepSkin.preview_path(skin_id)
	art.texture = load(preview_path) as Texture2D if ResourceLoader.exists(preview_path) else null
	art.custom_minimum_size = Vector2(520, 292)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	col.add_child(art)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", Tokens.GAP_L)
	col.add_child(buttons)
	var later := _button(_t("稍后", "Later"), Vector2(180, 60))
	later.pressed.connect(_dismiss_overlay)
	buttons.add_child(later)
	var equip := _button(_t("立即使用", "Equip now"), Vector2(240, 60))
	equip.theme_type_variation = Theming.VARIATION_PRIMARY
	equip.pressed.connect(func() -> void:
		_dismiss_overlay()
		_equip())
	buttons.add_child(equip)
	card.pivot_offset = Vector2(320, 230)
	card.scale = Vector2.ONE * 0.8
	card.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(card, "scale", Vector2.ONE, Tokens.motion(0.3)).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(card, "modulate:a", 1.0, Tokens.motion(0.2))


func _dismiss_overlay() -> void:
	if _overlay != null:
		_overlay.queue_free()
		_overlay = null
	_refresh_ui()


func _equip() -> void:
	if _busy:
		return
	_busy = true
	_refresh_ui()
	var code: int = await PlayerProfile.set_prep_skin(skin_id)
	if not is_inside_tree():
		return
	_busy = false
	_notice.text = (_t("%s已使用，下一局摆放时就能看到", "%s equipped — see it next match") % _txt("name")) if code / 100 == 2 \
		else _t("使用失败，请稍后再试", "Could not equip; try again later")
	_refresh_ui()


# 一次性花瓣迸发。strength 放大速度和尺寸（中档 1，大档 2 左右）。
func _burst(at: Vector2, amount: int, strength: float) -> void:
	var p := CPUParticles2D.new()
	p.texture = _bit_texture()
	p.amount = amount
	p.lifetime = 0.9 + 0.3 * strength
	p.one_shot = true
	p.explosiveness = 0.92
	p.direction = Vector2(0, -1)
	p.spread = 180.0
	p.initial_velocity_min = 140.0 * strength
	p.initial_velocity_max = 320.0 * strength
	p.damping_min = 120.0
	p.damping_max = 220.0
	p.gravity = Vector2(0, 260)
	p.angular_velocity_min = -360.0
	p.angular_velocity_max = 360.0
	p.angle_max = 360.0
	p.scale_amount_min = 0.35 * maxf(1.0, strength * 0.7)
	p.scale_amount_max = 0.7 * maxf(1.0, strength * 0.7)
	p.color_ramp = _fade_ramp()
	_style_bits(p)
	if _wisp():
		# 荧光点贴图小：放大一些，迸发才看得见
		p.scale_amount_min *= 2.2
		p.scale_amount_max *= 2.2
		p.gravity = Vector2(0, -40)
	p.position = at
	p.emitting = true
	_canvas.add_child(p)
	p.finished.connect(p.queue_free)


func _close() -> void:
	if not _busy:
		queue_free()


# --- 小工具 -------------------------------------------------------------------

func _rect(node: Control, x: float, y: float, w: float, h: float) -> void:
	node.position = Vector2(x, y)
	node.size = Vector2(w, h)


func _label(value: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", _th.text)
	label.add_theme_color_override("font_outline_color", _th.text_edge)
	label.add_theme_constant_override("outline_size", 4)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _button(value: String, minimum: Vector2) -> Button:
	var button: Button = ACTION_BUTTON.instantiate()
	button.text = value
	button.custom_minimum_size = minimum
	return button


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _overlay != null:
			_dismiss_overlay()
		else:
			_close()
		get_viewport().set_input_as_handled()


func _t(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale().begins_with("en") else zh
