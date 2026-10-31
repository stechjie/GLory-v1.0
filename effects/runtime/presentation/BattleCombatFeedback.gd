extends Control
## Event-driven, input-transparent battle accents. The battle screen owns counting,
## local-lane eligibility and SafeArea.track(); this module owns the clear accent.
## No simulation, time scale or hit-stop is changed here.

const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")
const Fonts := preload("res://ui/fonts/UIFontFallback.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const SfxService := preload("res://ui/services/SfxService.gd")

const EARLY_DAMAGE_TIERS := [1000, 3000, 5000, 10000]
const DISPLAY_FONT := preload("res://ui/fonts/LibreBaskerville-Variable.ttf")
const PLATE := preload("res://effects/runtime/presentation/DamageCounterPlate.gd")
const INK_SHADER := preload("res://shaders/damage_counter_ink.gdshader")
const DAMAGE_TIERS := [10000, 20000, 40000, 80000, 160000, 320000]
const DAMAGE_COLORS := [Color("a6b6e6"), Color("8eafff"), Color("72c7ff"), Color("9d9dff"), Color("b79fff"), Color("b4d8ff"), Color("e5efff")]
const EARLY_DAMAGE_COLORS := [Color("a6b6e6"), Color("8eafff"), Color("72c7ff"), Color("b09dff"), Color("e5efff")]
const FLAME_SHADER := preload("res://shaders/damage_counter_fire.gdshader")
# 10.31 清场字幕加强：原来 43px、0.68 秒、挤在顶部中间，雪地 / 冰蓝底上几乎读不到。
# 现在字号翻倍、落在本地那一路上方、冲击放大进场 + 一道横扫高光 + 深色底带，停 1.2 秒。
const CLEAR_HOLD_SEC := 1.2
const CLEAR_FADE_SEC := 0.28
const CLEAR_FONT_SIZE := 84.0
const CLEAR_WIDTH := 900.0
const CLEAR_HEIGHT := 110.0
const CLEAR_IMPACT_SCALE := 1.55
const CLEAR_IMPACT_SEC := 0.16
const CLEAR_SWEEP_SEC := 0.45
# 左侧伤害面板（x 8..294）与 Top ATK 列表的右边界，字幕不往这里压。
const CLEAR_HUD_LEFT_PX := 300.0
const CAPTION_SHADER := preload("res://shaders/lane_clear_caption.gdshader")
const CLEAR_BAND_SHADER_CODE := """shader_type canvas_item;
uniform float reveal = 1.0;
void fragment() {
	float x = abs(UV.x - 0.5) * 2.0;
	float y = abs(UV.y - 0.5) * 2.0;
	float body = (1.0 - smoothstep(0.55 * reveal, 1.0 * reveal, x)) * (1.0 - smoothstep(0.35, 1.0, y));
	float line = exp(-pow((y - 0.86) / 0.05, 2.0)) * (1.0 - smoothstep(0.3 * reveal, 0.95 * reveal, x));
	COLOR = vec4(mix(vec3(0.05, 0.03, 0.01), vec3(1.0, 0.76, 0.30), line), max(body * 0.62, line * 0.85) * COLOR.a);
}
"""
const GOLD := Color(1.0, 0.86, 0.51)
const CLEAR_GOLD := Color(1.0, 0.91, 0.65)

var _damage_title: Label
var _plate: Control
var _ink_materials: Array[ShaderMaterial] = []
var _damage_depth: Label
var _round_index := 11
var _current_tier := 0
var _accent_tween: Tween
var _damage_label: Label
var _clear_label: Label
var _damage_tween: Tween
var _clear_tween: Tween
var _damage_total := 0
var _fire: ColorRect
var _fire_material: ShaderMaterial
var _clear_shown := false
var _clear_band: ColorRect
var _clear_band_material: ShaderMaterial
var _clear_caption_material: ShaderMaterial
# 本地那一路在屏幕上的锚点（全局坐标）。INF = 没给，落回顶部中间。
var _clear_anchor := Vector2.INF


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	z_index = 112
	_plate = PLATE.new()
	add_child(_plate)
	_damage_title = _make_label("DamageTitle", Color.WHITE)
	_damage_title.text = "Damage"
	_damage_depth = _make_label("DamageDepth", Color("090d26"))
	_damage_label = _make_label("Damage", Color.WHITE)
	var face := FontVariation.new()
	face.base_font = DISPLAY_FONT
	face.variation_opentype = {"wght": 500.0}
	face.variation_transform = Transform2D(Vector2(0.78,0.0),Vector2(0.0,1.0),Vector2.ZERO)
	face.opentype_features = {"lnum":1,"tnum":1}
	for label in [_damage_title, _damage_depth, _damage_label]:
		label.add_theme_font_override("font", face)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		label.add_theme_color_override("font_outline_color",Color("070a1e"))
		label.add_theme_constant_override("outline_size",0 if label != _damage_depth else 1)
	var title_face := FontVariation.new()
	title_face.base_font = DISPLAY_FONT
	title_face.variation_opentype = {"wght":500.0}
	_damage_title.add_theme_font_override("font",title_face)
	_damage_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	for label in [_damage_title,_damage_label]:
		var ink := ShaderMaterial.new()
		ink.shader = INK_SHADER
		ink.set_shader_parameter("promotion",0.0)
		ink.set_shader_parameter("sweep",1.0)
		label.material = ink
		_ink_materials.append(ink)
	_damage_label.clip_text = true
	_damage_depth.clip_text = true
	_fire = ColorRect.new()
	_fire.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fire_material = ShaderMaterial.new()
	_fire_material.shader = FLAME_SHADER
	_fire.material = _fire_material
	add_child(_fire)
	_clear_band = ColorRect.new()
	_clear_band.name = "LaneClearBand"
	_clear_band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var band_shader := Shader.new()
	band_shader.code = CLEAR_BAND_SHADER_CODE
	_clear_band_material = ShaderMaterial.new()
	_clear_band_material.shader = band_shader
	_clear_band.material = _clear_band_material
	add_child(_clear_band)
	_clear_label = _make_label("LaneClear", CLEAR_GOLD)
	_clear_label.add_theme_color_override("font_outline_color", Color(0.16, 0.07, 0.0, 1.0))
	_clear_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.55))
	_clear_caption_material = ShaderMaterial.new()
	_clear_caption_material.shader = CAPTION_SHADER
	_clear_caption_material.set_shader_parameter("sweep", -1.0)
	_clear_label.material = _clear_caption_material
	resized.connect(_layout)
	LocaleManager.locale_changed.connect(_on_locale_changed)
	_layout()
	_refresh_text()
	reset_feedback()


func _make_label(node_name: String, color: Color) -> Label:
	var label := Label.new()
	label.name = node_name
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.focus_mode = Control.FOCUS_NONE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0.09, 0.055, 0.02, 0.94))
	label.add_theme_constant_override("outline_size", 3)
	var font := Fonts.bold_font()
	if font != null:
		label.add_theme_font_override("font", font)
	add_child(label)
	label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	return label


func _layout() -> void:
	if _damage_label == null or _clear_label == null:
		return
	var factor := clampf(minf(size.x / 1600.0, size.y / 720.0), 0.65, 1.4)
	# BattleArena reserves y10..42 for team HP and y48..84 for frenzy. Keep
	# this top gap even in a narrow window; the parent applies safe-area insets.
	var top := maxf(100.0, 100.0 * factor)
	_damage_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_plate.position = Vector2(8,143)*factor
	_plate.size = Vector2(286,84)*factor
	_damage_label.position = Vector2(30,170) * factor
	_damage_label.size = Vector2(222,58) * factor
	_damage_label.pivot_offset = _damage_label.size * 0.5
	_damage_title.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_damage_title.position = Vector2(95,145) * factor
	_damage_title.size = Vector2(156,30) * factor
	_damage_title.add_theme_font_size_override("font_size", roundi(26 * factor))
	_damage_depth.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_damage_depth.position = _damage_label.position + Vector2(0.7,1.1) * factor
	_damage_depth.size = _damage_label.size
	_damage_depth.pivot_offset = _damage_label.pivot_offset
	_fire.position = Vector2(8, 131) * factor
	_fire.size = Vector2(286, 112) * factor
	_place_clear_caption(factor, top)
	_damage_label.add_theme_font_size_override("font_size", roundi(36.0 * factor))
	_damage_depth.add_theme_font_size_override("font_size", roundi(36.0 * factor))
	_refresh_ink_metrics()
	_clear_label.add_theme_font_size_override("font_size", roundi(CLEAR_FONT_SIZE * factor))
	_clear_label.add_theme_constant_override("outline_size", maxi(6, roundi(11.0 * factor)))
	_clear_label.add_theme_constant_override("shadow_offset_y", maxi(2, roundi(4.0 * factor)))
	_clear_label.add_theme_constant_override("shadow_outline_size", maxi(4, roundi(9.0 * factor)))


# 字幕竖直位置固定在棋盘顶边（放到本路中间会压住我方棋子，10.31 截帧实测）；
# 有本路锚点时水平对准本路，但左边让开伤害面板 / Top ATK 列表（约 300 px 宽）。
func _place_clear_caption(factor: float, top: float) -> void:
	var width := minf(CLEAR_WIDTH * factor, size.x - 32.0)
	var height := CLEAR_HEIGHT * factor
	var text_width := width
	var font := _clear_label.get_theme_font("font")
	if font != null and not _clear_label.text.is_empty():
		text_width = minf(width, font.get_string_size(_clear_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			roundi(CLEAR_FONT_SIZE * factor)).x)
	var center := Vector2(size.x * 0.5, top + 64.0 * factor + height * 0.5)
	if _clear_anchor != Vector2.INF:
		var local := get_global_transform().affine_inverse() * _clear_anchor
		var half := text_width * 0.5 + 75.0 * factor
		var left_limit := maxf(half + 16.0, CLEAR_HUD_LEFT_PX * factor + half)
		center.x = clampf(local.x, minf(left_limit, size.x * 0.5), size.x - half - 16.0)
	# 标签是 CENTER_TOP 锚点，offset 以顶部中点为原点。
	_clear_label.offset_left = center.x - size.x * 0.5 - width * 0.5
	_clear_label.offset_right = center.x - size.x * 0.5 + width * 0.5
	_clear_label.offset_top = center.y - height * 0.5
	_clear_label.offset_bottom = center.y + height * 0.5
	_clear_label.pivot_offset = Vector2(width, height) * 0.5
	if _clear_caption_material != null:
		_clear_caption_material.set_shader_parameter("extent_x", width)
	if _clear_band != null:
		# 底带按字面实际宽度取，不按标签框（900）—— 否则会盖住左侧伤害面板。
		var band_size := Vector2(minf(text_width + 150.0 * factor, size.x), height * 1.25)
		_clear_band.position = center - band_size * 0.5
		_clear_band.size = band_size
		_clear_band.pivot_offset = band_size * 0.5


func _refresh_ink_metrics() -> void:
	var scan_left := _damage_label.position.x-_damage_label.size.x*0.10
	var scan_right := _damage_label.position.x+_damage_label.size.x*1.12
	for i in range(_ink_materials.size()):
		var label: Label = _damage_title if i == 0 else _damage_label
		var font_size := label.get_theme_font_size("font_size")
		var font := label.get_theme_font("font")
		var baseline := (label.size.y-font.get_height(font_size))*0.5+font.get_ascent(font_size)
		_ink_materials[i].set_shader_parameter("extent",label.size)
		_ink_materials[i].set_shader_parameter("ink_y",Vector2(baseline-float(font_size)*0.66,baseline))
		_ink_materials[i].set_shader_parameter("scan_range",Vector2(scan_left,scan_right)-Vector2.ONE*label.position.x)
		if i == 1:
			_fire_material.set_shader_parameter("focus_y",(_damage_label.position.y+baseline-float(font_size)*0.33-_fire.position.y)/_fire.size.y)
	_fire_material.set_shader_parameter("sweep_range",(Vector2(scan_left,scan_right)-Vector2.ONE*_fire.position.x)/_fire.size.x)


func _place_label(label: Label, width: float, top: float, height: float) -> void:
	label.offset_left = -width * 0.5
	label.offset_right = width * 0.5
	label.offset_top = top
	label.offset_bottom = top + height
	label.pivot_offset = Vector2(width, height) * 0.5


## Absolute authoritative per-round damage, never a hit-number accumulator.
func show_damage(total: int, animate := true, round_index := 11) -> void:
	if _damage_label == null:
		return
	var changed := total != _damage_total or _round_index != round_index
	_round_index = round_index
	if not changed and _damage_label.visible:
		return
	_damage_total = maxi(0, total)
	var tier := damage_tier(_damage_total, _round_index)
	var promoted := tier > _current_tier
	_current_tier = tier
	var early := _round_index >= 1 and _round_index <= 10
	var accent: Color = EARLY_DAMAGE_COLORS[tier] if early else DAMAGE_COLORS[tier]
	_damage_label.show()
	_damage_title.show()
	_damage_depth.show()
	_plate.show()
	_plate.call("set_accent",accent)
	for ink in _ink_materials:
		ink.set_shader_parameter("accent",accent)
	_refresh_text()
	_fire.visible = tier > 0
	if promoted and animate and _motion_allowed() and Presentation.flash_allowed():
		if _accent_tween != null:
			_accent_tween.kill()
		_fire_material.set_shader_parameter("promotion", 1.0)
		_fire_material.set_shader_parameter("sweep", 0.0)
		_accent_tween = create_tween().set_parallel(true)
		_accent_tween.tween_property(_fire_material, "shader_parameter/promotion", 0.0, 0.48).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		_accent_tween.tween_property(_fire_material, "shader_parameter/sweep", 1.0, 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		for ink in _ink_materials:
			ink.set_shader_parameter("promotion",1.0)
			ink.set_shader_parameter("sweep",0.0)
			_accent_tween.tween_property(ink,"shader_parameter/promotion",0.0,0.48).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
			_accent_tween.tween_property(ink,"shader_parameter/sweep",1.0,0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	elif not animate:
		if _accent_tween != null:
			_accent_tween.kill()
		_fire_material.set_shader_parameter("promotion", 0.0)
		_fire_material.set_shader_parameter("sweep", 1.0)
		for ink in _ink_materials:
			ink.set_shader_parameter("promotion",0.0)
			ink.set_shader_parameter("sweep",1.0)
	_fire_material.set_shader_parameter("tier", float(tier) * (1.5 if early else 1.0))
	_fire_material.set_shader_parameter("flame_color", accent)
	_fire_material.set_shader_parameter("motion", 1.0 if _motion_allowed() else 0.0)
	_fire_material.set_shader_parameter("simple", 1.0 if not Presentation.flash_allowed() else 0.0)
	if changed and animate and _motion_allowed():
		if _damage_tween != null:
			_damage_tween.kill()
		_damage_label.scale = Vector2.ONE * (1.035 if promoted else 1.008)
		_damage_tween = create_tween()
		_damage_tween.tween_property(_damage_label, "scale", Vector2.ONE, 0.12)

static func damage_tier(total: int, round_index := 11) -> int:
	var result := 0
	for threshold in (EARLY_DAMAGE_TIERS if round_index >= 1 and round_index <= 10 else DAMAGE_TIERS):
		if total >= threshold:
			result += 1
	return result

## The owner calls once when the local lane is confirmed clear. Repeated calls
## are ignored until reset_feedback(), including while the subtitle is fading.
## anchor_global：本地那一路在屏幕上的位置（全局坐标），字幕对准它；不给就在顶部中间。
func show_lane_clear(anchor_global := Vector2.INF) -> void:
	if _clear_label == null or _clear_shown:
		return
	_clear_shown = true
	_clear_anchor = anchor_global
	_refresh_text()
	_layout()
	if _clear_tween != null:
		_clear_tween.kill()
	_clear_label.show()
	_clear_band.show()
	for node in [_clear_label, _clear_band]:
		node.modulate.a = 1.0
		node.scale = Vector2.ONE
	_clear_band_material.set_shader_parameter("reveal", 1.0)
	_clear_caption_material.set_shader_parameter("sweep", -1.0)
	_clear_tween = create_tween()
	# Keep a steady gold caption when flashing is disabled; never blink it.
	if _motion_allowed() and Presentation.flash_allowed():
		# 冲击进场：大字从 1.55 倍砸回原大，底带同时从中间展开，然后一道高光横扫过字面。
		_clear_label.scale = Vector2.ONE * CLEAR_IMPACT_SCALE
		_clear_label.modulate.a = 0.0
		_clear_band_material.set_shader_parameter("reveal", 0.05)
		_clear_tween.set_parallel(true)
		_clear_tween.tween_property(_clear_label, "scale", Vector2.ONE, CLEAR_IMPACT_SEC) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_clear_tween.tween_property(_clear_label, "modulate:a", 1.0, CLEAR_IMPACT_SEC * 0.5)
		_clear_tween.tween_property(_clear_band_material, "shader_parameter/reveal", 1.0, CLEAR_IMPACT_SEC * 1.4) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_clear_tween.tween_method(func(v: float) -> void: _clear_caption_material.set_shader_parameter("sweep", v),
			0.0, 1.0, CLEAR_SWEEP_SEC).set_delay(CLEAR_IMPACT_SEC * 0.6)
		_clear_tween.chain().tween_interval(CLEAR_HOLD_SEC - CLEAR_IMPACT_SEC)
	else:
		_clear_tween.tween_interval(CLEAR_HOLD_SEC)
	_clear_tween.chain().set_parallel(true)
	_clear_tween.tween_property(_clear_label, "modulate:a", 0.0, CLEAR_FADE_SEC)
	_clear_tween.tween_property(_clear_band, "modulate:a", 0.0, CLEAR_FADE_SEC)
	_clear_tween.chain().tween_callback(func() -> void:
		_clear_label.hide()
		_clear_band.hide())
	SfxService.play_battle(SfxService.CUE_LANE_CLEAR_ACCENT)


func reset_feedback() -> void:
	if _damage_tween != null:
		_damage_tween.kill()
	if _clear_tween != null:
		_clear_tween.kill()
	_damage_tween = null
	_clear_tween = null
	_damage_total = 0
	_current_tier = 0
	if _accent_tween != null:
		_accent_tween.kill()
	if _fire_material != null:
		_fire_material.set_shader_parameter("promotion",0.0)
		_fire_material.set_shader_parameter("sweep",1.0)
	for ink in _ink_materials:
		ink.set_shader_parameter("promotion",0.0)
		ink.set_shader_parameter("sweep",1.0)
	if is_instance_valid(_fire):
		_fire.hide()
	if is_instance_valid(_plate):
		_plate.hide()
	_clear_shown = false
	_clear_anchor = Vector2.INF
	if is_instance_valid(_clear_band):
		_clear_band.hide()
		_clear_band.modulate.a = 1.0
	if _clear_caption_material != null:
		_clear_caption_material.set_shader_parameter("sweep", -1.0)
	for label in [_damage_title, _damage_depth, _damage_label, _clear_label]:
		if is_instance_valid(label):
			label.hide()
			label.scale = Vector2.ONE
			label.modulate.a = 1.0


func _motion_allowed() -> bool:
	return not Presentation._toggle("reduced_motion") and not Tokens.reduced_motion()


func _refresh_text() -> void:
	var english := LocaleManager.get_locale().begins_with("en")
	var digits := str(_damage_total)
	var grouped := ""
	for index in range(digits.length()):
		if index > 0 and (digits.length() - index) % 3 == 0:
			grouped += ","
		grouped += digits[index]
	_damage_label.text = "× " + grouped
	_damage_depth.text = _damage_label.text
	# Keep the complete total inside the approved width as digit count grows.
	var factor := clampf(minf(size.x/1600.0,size.y/720.0),0.65,1.4)
	var font := _damage_label.get_theme_font("font")
	var font_size := roundi(36.0*factor)
	var text_width := font.get_string_size(_damage_label.text,HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x
	if text_width > _damage_label.size.x:
		font_size = maxi(roundi(18.0*factor),floori(float(font_size)*_damage_label.size.x/text_width))
	_damage_label.add_theme_font_size_override("font_size",font_size)
	_damage_depth.add_theme_font_size_override("font_size",font_size)
	_refresh_ink_metrics()
	_clear_label.text = "LANE CLEAR" if english else "本路已清"


func _on_locale_changed(_locale: String) -> void:
	_refresh_text()
