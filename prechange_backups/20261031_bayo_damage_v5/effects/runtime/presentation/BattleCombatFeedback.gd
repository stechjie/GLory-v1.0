extends Control
## Event-driven, input-transparent battle accents. The battle screen owns counting,
## local-lane eligibility and SafeArea.track(); this module owns the clear accent.
## No simulation, time scale or hit-stop is changed here.

const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")
const Fonts := preload("res://ui/fonts/UIFontFallback.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const SfxService := preload("res://ui/services/SfxService.gd")

const EARLY_DAMAGE_TIERS := [1000, 3000, 5000, 10000]
const DISPLAY_FONT := preload("res://ui/fonts/BarlowCondensed-BlackItalic.ttf")
const DAMAGE_TIERS := [10000, 20000, 40000, 80000, 160000, 320000]
const DAMAGE_COLORS := [Color("eee8dc"), Color("ffd066"), Color("ff9252"), Color("ff5365"), Color("cf91ff"), Color("72e5ff"), Color("fff0c0")]
const EARLY_DAMAGE_COLORS := [Color("eee8dc"), Color("ffd066"), Color("ff9252"), Color("ff5365"), Color("fff0c0")]
const FLAME_SHADER := preload("res://shaders/damage_counter_fire.gdshader")
const CLEAR_HOLD_SEC := 0.68
const CLEAR_FADE_SEC := 0.20
const GOLD := Color(1.0, 0.86, 0.51)
const CLEAR_GOLD := Color(1.0, 0.91, 0.65)

var _damage_title: Label
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


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	z_index = 112
	_damage_title = _make_label("DamageTitle", Color("baa98d"))
	_damage_title.text = "D A M A G E"
	_damage_depth = _make_label("DamageDepth", Color("423829"))
	_damage_label = _make_label("Damage", GOLD)
	for label in [_damage_title, _damage_depth, _damage_label]:
		label.add_theme_font_override("font", DISPLAY_FONT)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_fire = ColorRect.new()
	_fire.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fire_material = ShaderMaterial.new()
	_fire_material.shader = FLAME_SHADER
	_fire.material = _fire_material
	add_child(_fire)
	move_child(_fire, 0)
	_clear_label = _make_label("LaneClear", CLEAR_GOLD)
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
	_damage_label.position = Vector2(22, 169) * factor
	_damage_label.size = Vector2(252, 62) * factor
	_damage_label.pivot_offset = _damage_label.size * 0.5
	_damage_title.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_damage_title.position = Vector2(24, 151) * factor
	_damage_title.size = Vector2(200, 22) * factor
	_damage_title.add_theme_font_size_override("font_size", roundi(18 * factor))
	_damage_depth.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_damage_depth.position = _damage_label.position + Vector2(1, 4) * factor
	_damage_depth.size = _damage_label.size
	_damage_depth.pivot_offset = _damage_label.pivot_offset
	_fire.position = Vector2(8, 131) * factor
	_fire.size = Vector2(286, 112) * factor
	_place_label(_clear_label, 620.0 * factor, top + 64.0 * factor, 58.0 * factor)
	_damage_label.add_theme_font_size_override("font_size", roundi(46.0 * factor))
	_damage_depth.add_theme_font_size_override("font_size", roundi(46.0 * factor))
	_clear_label.add_theme_font_size_override("font_size", roundi(43.0 * factor))


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
	_damage_label.add_theme_color_override("font_color", accent)
	_refresh_text()
	_fire.visible = tier > 0
	if promoted and animate and _motion_allowed() and Presentation.flash_allowed():
		if _accent_tween != null:
			_accent_tween.kill()
		_fire_material.set_shader_parameter("promotion", 1.0)
		_fire_material.set_shader_parameter("sweep", 0.0)
		_accent_tween = create_tween().set_parallel(true)
		_accent_tween.tween_property(_fire_material, "shader_parameter/promotion", 0.0, 0.32)
		_accent_tween.tween_property(_fire_material, "shader_parameter/sweep", 1.0, 0.26)
	elif not animate:
		_fire_material.set_shader_parameter("promotion", 0.0)
		_fire_material.set_shader_parameter("sweep", 1.0)
	_fire_material.set_shader_parameter("tier", float(tier) * (1.5 if early else 1.0))
	_fire_material.set_shader_parameter("flame_color", accent)
	_fire_material.set_shader_parameter("motion", 1.0 if _motion_allowed() else 0.0)
	_fire_material.set_shader_parameter("simple", 1.0 if not Presentation.flash_allowed() else 0.0)
	if changed and animate and _motion_allowed():
		if _damage_tween != null:
			_damage_tween.kill()
		_damage_label.scale = Vector2.ONE * (1.11 if promoted else 1.025)
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
func show_lane_clear() -> void:
	if _clear_label == null or _clear_shown:
		return
	_clear_shown = true
	_refresh_text()
	if _clear_tween != null:
		_clear_tween.kill()
	_clear_label.show()
	_clear_label.modulate.a = 1.0
	_clear_label.scale = Vector2.ONE
	_clear_tween = create_tween()
	# Keep a steady gold caption when flashing is disabled; never blink it.
	if _motion_allowed() and Presentation.flash_allowed():
		_clear_label.scale = Vector2.ONE * 1.06
		_clear_tween.tween_property(_clear_label, "scale", Vector2.ONE, 0.10).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_clear_tween.tween_interval(CLEAR_HOLD_SEC)
	_clear_tween.tween_property(_clear_label, "modulate:a", 0.0, CLEAR_FADE_SEC)
	_clear_tween.tween_callback(_clear_label.hide)
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
	if is_instance_valid(_fire):
		_fire.hide()
	_clear_shown = false
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
	_clear_label.text = "LANE CLEAR" if english else "本路已清"


func _on_locale_changed(_locale: String) -> void:
	_refresh_text()
