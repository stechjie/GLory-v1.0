extends Control
# 三选一宝藏卡：代码画的卡框（TreasureCardFrame）上叠图标、名字、短效果和联动徽记。
#
# 11.04 起替代 assets/ui/treasure_cards/<名字>[_en].png 那 50 张烤字卡图：
#   · 字在图里，每加一种语言就要再出 25 张，改数值要重画（9.13 打断锁链、9.20 哀鸣共鸣都返工过），
#     而且卡上的数字早已和实际数值对不上；
#   · 卡底徽记是按旧联动表画死的，剧毒蔓延 / 折扣令牌 / 黄金祭坛 / 法阵回春四张对不上。
# 现在名字取数据表，效果取 LocaleManager 的 treasure_card_<id>，徽记按 treasures.json 的
# linkages 现算：属于两个联动的（狂怒阵容）并排画两个，不属于任何联动的（法阵回春）留空章。
#
# 坐标写在卡框的 600×800 卡面空间里，布局时按实际尺寸等比换算。

const PrepWidgets := preload("res://scenes/prep/PrepWidgets.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const UIFontFallback := preload("res://ui/fonts/UIFontFallback.gd")
const Frame := preload("res://scenes/prep/panels/TreasureCardFrame.gd")

const EMBLEM_DIR := "res://assets/ui/treasure_cards/emblems/"
const LOGO_DIR := "res://assets/ui/treasure_logos/"

const ICON_RECT := Rect2(150.0, 110.0, 300.0, 280.0)
const NAME_RECT := Rect2(60.0, 438.0, 480.0, 64.0)
const EFFECT_RECT := Rect2(72.0, 528.0, 456.0, 148.0)
# 徽记图是 310×330 的画布，徽记中心在 EMBLEM_CANVAS_CENTER；按比例缩进底部圆章。
const EMBLEM_CANVAS := Vector2(310.0, 330.0)
const EMBLEM_CANVAS_CENTER := Vector2(151.4, 160.7)
const EMBLEM_SCALE := 0.46
const DUAL_SCALE := 0.30
const DUAL_OFFSET_X := 27.0
# 徽记原图是灰石浮雕，提亮偏金，贴合金色圆章。
const EMBLEM_TINT := Color(1.55, 1.3, 0.85)

# 呼吸动画：整卡缩放幅度 / 图标上下浮动（卡面像素）/ 各自周期（弧度每秒）。
# 三张卡按 treasure_id 取不同相位，不会齐步走。系统开了「减少动态」则全部静止。
const BREATH_SCALE := 0.012
const BREATH_SPEED := 1.15
const ICON_BOB := 7.0
const ICON_BOB_SPEED := 1.7

const NAME_PX := 46.0
const NAME_MIN_PX := 28.0
const EFFECT_PX := 25.0
const EFFECT_MIN_PX := 17.0
const EFFECT_MAX_LINES := 3
const NAME_COLOR := Color("ffe3a3")
const EFFECT_COLOR := Color("eadfcb")

var treasure_id := ""

var _frame: Control
var _icon: TextureRect
var _name: Label
var _effect: Label
var _emblems: Array[TextureRect] = []
var _icon_base := Vector2.ZERO
var _scale := 1.0
var _time := 0.0
var _phase := 0.0
var _animate := false


static func create(tid: String) -> Control:
	var view: Control = (load("res://scenes/prep/panels/TreasureCardView.gd") as GDScript).new()
	view.set("treasure_id", tid)
	return view


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var t := TreasureService.treasure_by_id(treasure_id)
	_frame = Frame.new()
	_frame.set("category", str(t.get("category", "")))
	_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_frame)
	_icon = _add_texture(PrepWidgets.cached_texture(LOGO_DIR + str(t.get("name", treasure_id)) + ".png"))
	_icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	for link_id in linkages_of(treasure_id):
		var e := _add_texture(PrepWidgets.cached_texture(EMBLEM_DIR + link_id + ".png"))
		e.self_modulate = EMBLEM_TINT
		e.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		_emblems.append(e)
	_name = _add_label(PrepWidgets.unit_name(t) if not t.is_empty() else treasure_id, NAME_COLOR)
	_name.add_theme_font_override("font", UIFontFallback.bold_font())
	_name.add_theme_color_override("font_outline_color", Color(0.08, 0.05, 0.02, 0.9))
	_name.add_theme_constant_override("outline_size", 6)
	_effect = _add_label(card_effect_text(treasure_id), EFFECT_COLOR)
	_effect.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_effect.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	resized.connect(_layout)
	LocaleManager.locale_changed.connect(_on_locale_changed)
	_phase = float(absi(hash(treasure_id)) % 1000) / 1000.0 * TAU
	_animate = not Tokens.reduced_motion()
	_frame.set("animated", _animate)
	_frame.set("anim_phase", _phase)
	set_process(_animate)
	_layout()


func _process(delta: float) -> void:
	_time += delta
	pivot_offset = size * 0.5
	scale = Vector2.ONE * (1.0 + BREATH_SCALE * sin(_time * BREATH_SPEED + _phase))
	_icon.position = _icon_base + Vector2(0.0, sin(_time * ICON_BOB_SPEED + _phase * 1.3) * ICON_BOB * _scale)
	_frame.set("anim_time", _time)
	_frame.queue_redraw()


# 卡面短效果。只放一行能读完的概括；完整说明在长按详情里（TreasureChoicePanel.effect_text）。
static func card_effect_text(tid: String) -> String:
	var key := "treasure_card_" + tid
	var text := str(TranslationServer.translate(key))
	if text == key:
		return ""
	if tid == "money_golden_altar":
		text = text % TreasureService.golden_altar_hp_cost()
	return text


# 该宝藏参与的联动，按 treasures.json 里的顺序。
static func linkages_of(tid: String) -> Array[String]:
	var out: Array[String] = []
	for raw in DataRegistry.get_table("treasures").get("linkages", []):
		var link := raw as Dictionary
		if link != null and (link.get("requires", []) as Array).has(tid):
			out.append(str(link.get("id", "")))
	return out


func _on_locale_changed(_locale: String) -> void:
	var t := TreasureService.treasure_by_id(treasure_id)
	_name.text = PrepWidgets.unit_name(t) if not t.is_empty() else treasure_id
	_effect.text = card_effect_text(treasure_id)
	_layout()


func _add_texture(tex: Texture2D) -> TextureRect:
	var r := TextureRect.new()
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.texture = tex
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(r)
	return r


func _add_label(text: String, color: Color) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", color)
	add_child(l)
	return l


func _layout() -> void:
	if _frame == null:
		return
	var s := minf(size.x / Frame.CARD.x, size.y / Frame.CARD.y)
	if s <= 0.0:
		return
	var origin := (size - Frame.CARD * s) * 0.5
	_scale = s
	_place(_icon, ICON_RECT, origin, s)
	_icon_base = _icon.position
	var medal: Vector2 = Frame.MEDAL_CENTER
	if _emblems.size() == 1:
		_place(_emblems[0], _emblem_rect(medal, EMBLEM_SCALE), origin, s)
	elif _emblems.size() >= 2:
		# 两个联动：各缩小，左右并排（第三个起不画，目前没有这种宝藏）。
		_place(_emblems[0], _emblem_rect(medal - Vector2(DUAL_OFFSET_X, 0.0), DUAL_SCALE), origin, s)
		_place(_emblems[1], _emblem_rect(medal + Vector2(DUAL_OFFSET_X, 0.0), DUAL_SCALE), origin, s)
		for i in range(2, _emblems.size()):
			_emblems[i].visible = false
	# 先按目标尺寸定字号再设尺寸：Label 以默认字号的最小宽度为下限，
	# 先设尺寸会被撑宽（英文长句曾因此溢出卡框）。
	_name.add_theme_constant_override("outline_size", maxi(1, int(round(6.0 * s))))
	_fit_single_line(_name, NAME_RECT.size.x * s, NAME_PX * s, NAME_MIN_PX * s)
	_fit_wrapped(_effect, EFFECT_RECT.size * s, EFFECT_PX * s, EFFECT_MIN_PX * s)
	_place(_name, NAME_RECT, origin, s)
	_place(_effect, EFFECT_RECT, origin, s)


func _emblem_rect(centre: Vector2, k: float) -> Rect2:
	return Rect2(centre - EMBLEM_CANVAS_CENTER * k, EMBLEM_CANVAS * k)


func _place(node: Control, r: Rect2, origin: Vector2, s: float) -> void:
	node.position = origin + r.position * s
	node.size = r.size * s


# 名字：一行放下为止逐步缩小（俄语之类长名字也不会溢出卡面）。
func _fit_single_line(l: Label, width: float, start_px: float, min_px: float) -> void:
	var font := l.get_theme_font("font")
	var px := int(round(start_px))
	while px > int(min_px) and font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > width:
		px -= 1
	l.add_theme_font_size_override("font_size", maxi(px, 1))


# 效果：按宽度换行，行数超过 EFFECT_MAX_LINES 或高度放不下就缩小。
func _fit_wrapped(l: Label, box: Vector2, start_px: float, min_px: float) -> void:
	var font := l.get_theme_font("font")
	var px := int(round(start_px))
	while px > int(min_px):
		var h := font.get_multiline_string_size(l.text, HORIZONTAL_ALIGNMENT_CENTER, box.x, px).y
		if h <= box.y and h <= font.get_height(px) * EFFECT_MAX_LINES + 1.0:
			break
		px -= 1
	l.add_theme_font_size_override("font_size", maxi(px, 1))
