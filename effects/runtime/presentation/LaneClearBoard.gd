extends Control
## 打怪 / Boss 局右边的「清路前三」：谁先把自己那条路清完，谁就上榜，最多三个人。
## 竖着一列：头像（带头像框）+ 压在头像下沿的名次绶带（1st / 2nd / 3rd）+ 名字。
## 11-18 用户定：不显示用时、不显示进度，只要名次、头像、名字；不能挡右边玩家的战场。
## 所以整列宽度不超过右上角那列按钮（视角 / 语音，宽 120），接在按钮下面——那一列本来就是界面，
## 不多占战场。起点高度由调用方按有没有语音按钮决定。
## 名次在清完那一刻就定了（先清完的永远在前），所以这里不会超车；新上榜的从右边缘滑进来亮一下。
##
## 这里只管显示。名次和奖励（50 / 30 / 10）的真相在战斗服务器，战斗结束时调用方用同一份数据刷一次。

const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Fonts := preload("res://ui/fonts/UIFontFallback.gd")
const AvatarCatalog := preload("res://scripts/account/AvatarCatalog.gd")
const DISPLAY_FONT := preload("res://ui/fonts/LibreBaskerville-Variable.ttf")

const SHOWN := 3
## 一格的设计尺寸（和右上角按钮同宽）：头像在上，绶带压住头像下沿，名字在最下面。
const ROW_SIZE := Vector2(120, 92)
const AVATAR_BOX := 62.0
const RIBBON_SIZE := Vector2(74, 26)
const ROW_GAP := 2.0
const SLIDE_SEC := 0.35
const PLACE_DIGIT := ["1", "2", "3"]
const PLACE_SUFFIX := ["st", "nd", "rd"]
## 绶带金属色（亮 / 中 / 暗）：金 / 银 / 铜。
const PLACE_METAL := [
	[Color("fff1b0"), Color("e9b43a"), Color("94600f")],
	[Color("ffffff"), Color("c9d1da"), Color("6f7a86")],
	[Color("ffd7ab"), Color("c97a3e"), Color("6e3a18")],
]

var _rows: Dictionary = {}           # slot -> 行
var _place_font: FontVariation


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	_place_font = FontVariation.new()
	_place_font.base_font = DISPLAY_FONT
	_place_font.variation_opentype = {"wght": 700.0}


## entries：{slot, name, avatar, frame, clear_sec}，只给已经清完路的人；没清完的不传或 clear_sec < 0。
## 同用时按传进来的先后（调用方按清完的先后给）。
func update_entries(entries: Array, animate := true) -> void:
	var done: Array = []          # [clear_sec, 传进来的先后, entry]
	for e in entries:
		var t := float((e as Dictionary).get("clear_sec", -1.0))
		if t >= 0.0:
			done.append([t, done.size(), e])
	done.sort_custom(func(a, b) -> bool:
		if a[0] != b[0]:
			return a[0] < b[0]
		return a[1] < b[1])
	var shown: Array = []
	for item in done.slice(0, SHOWN):
		shown.append(item[2])
	var keep := {}
	for e in shown:
		keep[int(e.get("slot", -1))] = true
	for s in _rows.keys():
		if not keep.has(s):
			(_rows[s] as Control).queue_free()
			_rows.erase(s)
	for rank in shown.size():
		var e: Dictionary = shown[rank]
		var s := int(e.get("slot", -1))
		var row: Control = _rows.get(s)
		var fresh := row == null
		if fresh:
			row = _make_row(e)
			add_child(row)
			_rows[s] = row
		(row.get_meta("ribbon") as Ribbon).set_rank(rank)
		_place(row, rank, fresh, animate)


## 这个座位那一格的绶带在屏幕上的位置，前三名奖励金币从这里飞进钱袋。不在榜上返回 null。
func anchor_global(slot: int) -> Variant:
	var row: Control = _rows.get(slot)
	if row == null:
		return null
	var ribbon := row.get_meta("ribbon") as Control
	return ribbon.get_global_transform() * (ribbon.size * 0.5)


func reset() -> void:
	for s in _rows:
		(_rows[s] as Control).queue_free()
	_rows.clear()


func _make_row(e: Dictionary) -> Control:
	var row := Control.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.size = ROW_SIZE
	row.add_child(_make_avatar(str(e.get("avatar", "")), str(e.get("frame", ""))))
	# 名次绶带：横幅两头折到后面的燕尾，金属渐变，压在头像下沿。
	var ribbon := Ribbon.new()
	ribbon.font = _place_font
	ribbon.size = RIBBON_SIZE
	ribbon.position = Vector2((ROW_SIZE.x - RIBBON_SIZE.x) * 0.5, AVATAR_BOX - RIBBON_SIZE.y * 0.6)
	row.add_child(ribbon)
	row.set_meta("ribbon", ribbon)
	var name_label := Label.new()
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.position = Vector2(0, ribbon.position.y + RIBBON_SIZE.y - 1)
	name_label.size = Vector2(ROW_SIZE.x, ROW_SIZE.y - name_label.position.y)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.clip_text = true
	name_label.text = str(e.get("name", ""))
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.add_theme_color_override("font_color", Color("fff3d6"))
	name_label.add_theme_color_override("font_outline_color", Color("1c0e04"))
	name_label.add_theme_constant_override("outline_size", 4)
	var bold := Fonts.bold_font()
	if bold != null:
		name_label.add_theme_font_override("font", bold)
	row.add_child(name_label)
	return row


# 头像画法同 DamageRankCard / 教学头像：圆形遮罩里铺头像，框压在上面。
func _make_avatar(avatar: String, frame: String) -> Control:
	var badge := Control.new()
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.size = Vector2.ONE * AVATAR_BOX
	badge.position = Vector2((ROW_SIZE.x - AVATAR_BOX) * 0.5, 0)
	var mask := Panel.new()
	mask.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var inset := AVATAR_BOX * 0.17
	mask.offset_left = inset
	mask.offset_top = inset
	mask.offset_right = -inset
	mask.offset_bottom = -inset
	var circle := StyleBoxFlat.new()
	circle.bg_color = Color("2a1608")
	circle.set_corner_radius_all(int(AVATAR_BOX))
	mask.add_theme_stylebox_override("panel", circle)
	badge.add_child(mask)
	var portrait := TextureRect.new()
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.add_child(portrait)
	var frame_rect := TextureRect.new()
	frame_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	frame_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_child(frame_rect)
	AvatarCatalog.set_avatar_texture(portrait, AvatarCatalog.texture_for(avatar))
	AvatarCatalog.set_frame_texture(frame_rect, AvatarCatalog.frame_texture_for(frame))
	return badge


func _place(row: Control, rank: int, fresh: bool, animate: bool) -> void:
	var target := Vector2(0, float(rank) * (ROW_SIZE.y + ROW_GAP))
	var motion := animate and _motion_allowed()
	if not motion:
		row.position = target
		row.modulate = Color.WHITE
		return
	if fresh:
		# 新上榜：从屏幕右边缘滑进来，到位时亮一下。
		row.position = target + Vector2(80, 0)
		row.modulate = Color(1, 1, 1, 0)
		var tween := row.create_tween()
		tween.set_parallel(true)
		tween.tween_property(row, "position", target, SLIDE_SEC).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tween.tween_property(row, "modulate:a", 1.0, SLIDE_SEC * 0.6)
		if Presentation.flash_allowed():
			tween.chain().tween_property(row, "modulate", Color(1.45, 1.35, 1.1, 1.0), 0.08)
			tween.chain().tween_property(row, "modulate", Color.WHITE, 0.4).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	elif not row.position.is_equal_approx(target):
		row.create_tween().tween_property(row, "position", target, SLIDE_SEC).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _motion_allowed() -> bool:
	return not Presentation._toggle("reduced_motion") and not Tokens.reduced_motion()


## 名次绶带：中间一条横幅，两头各一截燕尾折在后面（颜色压暗），横幅上下金属渐变 + 顶部一道高光。
## 字是「1」大号 +「st」小号上标，白字配同色系深描边。
class Ribbon extends Control:
	const TAIL_W := 11.0
	const TAIL_DROP := 5.0
	var font: Font
	var _rank := 0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_rank(rank: int) -> void:
		var next_rank := clampi(rank, 0, 2)
		if _rank == next_rank:
			return
		_rank = next_rank
		queue_redraw()

	func _draw() -> void:
		var metal: Array = PLACE_METAL[_rank]
		var light: Color = metal[0]
		var mid: Color = metal[1]
		var dark: Color = metal[2]
		var line := Color("2c1606")
		var w := size.x
		var h := size.y
		var band_top := 0.0
		var band_bottom := h - TAIL_DROP
		var tail_top := TAIL_DROP
		# 两截燕尾：在横幅后面、往下错开，颜色比横幅暗。
		for side in [-1.0, 1.0]:
			var outer := 0.0 if side < 0.0 else w
			var inner := TAIL_W + 4.0 if side < 0.0 else w - TAIL_W - 4.0
			var notch := outer + 5.0 if side < 0.0 else outer - 5.0
			var pts := PackedVector2Array([
				Vector2(inner, tail_top), Vector2(outer, tail_top),
				Vector2(notch, (tail_top + h) * 0.5),
				Vector2(outer, h), Vector2(inner, h)])
			draw_colored_polygon(pts, dark.darkened(0.15))
			pts.append(pts[0])
			draw_polyline(pts, line, 1.5, true)
		# 横幅：上亮下暗的竖向渐变，两端略收成梯形，像布条绷紧。
		var x0 := TAIL_W
		var x1 := w - TAIL_W
		var band := PackedVector2Array([
			Vector2(x0, band_top), Vector2(x1, band_top),
			Vector2(x1 + 1.5, band_bottom), Vector2(x0 - 1.5, band_bottom)])
		draw_polygon(band, PackedColorArray([light, light, dark, dark]))
		var mid_band := PackedVector2Array([
			Vector2(x0 - 0.5, band_top + (band_bottom - band_top) * 0.35),
			Vector2(x1 + 0.5, band_top + (band_bottom - band_top) * 0.35),
			Vector2(x1 + 1.0, band_bottom - 3.0), Vector2(x0 - 1.0, band_bottom - 3.0)])
		draw_polygon(mid_band, PackedColorArray([mid, mid, mid.darkened(0.12), mid.darkened(0.12)]))
		draw_line(Vector2(x0 + 2.0, band_top + 2.0), Vector2(x1 - 2.0, band_top + 2.0), Color(1, 1, 1, 0.55), 1.0, true)
		var outline := band.duplicate()
		outline.append(band[0])
		draw_polyline(outline, line, 1.6, true)
		if font == null:
			return
		# 字：「1」+ 上标「st」，整体在横幅里居中。
		var digit: String = PLACE_DIGIT[_rank]
		var suffix: String = PLACE_SUFFIX[_rank]
		var big := 17
		var small := 10
		var dw := font.get_string_size(digit, HORIZONTAL_ALIGNMENT_LEFT, -1, big).x
		var sw := font.get_string_size(suffix, HORIZONTAL_ALIGNMENT_LEFT, -1, small).x
		var x := (w - dw - sw - 1.0) * 0.5
		var base := (band_top + band_bottom) * 0.5 + font.get_ascent(big) * 0.36
		var ink := dark.darkened(0.45)
		draw_string_outline(font, Vector2(x, base), digit, HORIZONTAL_ALIGNMENT_LEFT, -1, big, 4, ink)
		draw_string(font, Vector2(x, base), digit, HORIZONTAL_ALIGNMENT_LEFT, -1, big, Color("fffaf0"))
		var sx := x + dw + 1.0
		var sbase := base - big * 0.36
		draw_string_outline(font, Vector2(sx, sbase), suffix, HORIZONTAL_ALIGNMENT_LEFT, -1, small, 3, ink)
		draw_string(font, Vector2(sx, sbase), suffix, HORIZONTAL_ALIGNMENT_LEFT, -1, small, Color("fffaf0"))
