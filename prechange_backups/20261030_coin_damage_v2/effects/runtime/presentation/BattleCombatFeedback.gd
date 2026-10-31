extends Control
## Event-driven, input-transparent battle accents. The battle screen owns counting,
## local-lane eligibility and SafeArea.track(); this module owns these two sounds.
## No simulation, time scale or hit-stop is changed here.

const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")
const Fonts := preload("res://ui/fonts/UIFontFallback.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const SfxService := preload("res://ui/services/SfxService.gd")

const KILLS_HOLD_SEC := 0.66
const KILLS_FADE_SEC := 0.18
const CLEAR_HOLD_SEC := 0.68
const CLEAR_FADE_SEC := 0.20
const GOLD := Color(1.0, 0.86, 0.51)
const CLEAR_GOLD := Color(1.0, 0.91, 0.65)

var _kills_label: Label
var _clear_label: Label
var _kills_tween: Tween
var _clear_tween: Tween
var _kills_count := 0
var _streak_tier := 0
var _clear_shown := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	z_index = 112
	_kills_label = _make_label("Kills", GOLD)
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
	if _kills_label == null or _clear_label == null:
		return
	var factor := clampf(minf(size.x / 1600.0, size.y / 720.0), 0.65, 1.4)
	# BattleArena reserves y10..42 for team HP and y48..84 for frenzy. Keep
	# this top gap even in a narrow window; the parent applies safe-area insets.
	var top := maxf(100.0, 100.0 * factor)
	_place_label(_kills_label, 360.0 * factor, top, 48.0 * factor)
	_place_label(_clear_label, 620.0 * factor, top + 64.0 * factor, 58.0 * factor)
	_kills_label.add_theme_font_size_override("font_size", roundi(30.0 * factor))
	_clear_label.add_theme_font_size_override("font_size", roundi(43.0 * factor))


func _place_label(label: Label, width: float, top: float, height: float) -> void:
	label.offset_left = -width * 0.5
	label.offset_right = width * 0.5
	label.offset_top = top
	label.offset_bottom = top + height
	label.pivot_offset = Vector2(width, height) * 0.5


## Supply the current merged kill count. A smaller value starts a fresh chain.
## Repeated delivery of the same count has no sound or animation side effects.
func show_kills(count: int) -> void:
	if _kills_label == null:
		return
	var next_count := maxi(0, count)
	if next_count == _kills_count:
		return
	if next_count < _kills_count:
		_streak_tier = 0
	_kills_count = next_count
	if _kills_tween != null:
		_kills_tween.kill()
	_kills_label.scale = Vector2.ONE
	if _kills_count < 2:
		_kills_label.hide()
		return
	_refresh_text()
	var tier := _tier_for(_kills_count)
	if tier > _streak_tier:
		_streak_tier = tier
		# One cue even when an AOE jumps across more than one threshold.
		SfxService.play_battle(SfxService.CUE_KILL_STREAK, float(tier - 3))
	_kills_label.show()
	_kills_label.modulate.a = 1.0
	_kills_tween = create_tween()
	if _motion_allowed():
		# A bounded pop of the same Label; no stacked cards or extra particles.
		_kills_label.scale = Vector2.ONE * (1.07 + float(tier) * 0.025)
		_kills_tween.tween_property(_kills_label, "scale", Vector2.ONE, 0.16).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_kills_tween.tween_interval(KILLS_HOLD_SEC)
	_kills_tween.tween_property(_kills_label, "modulate:a", 0.0, KILLS_FADE_SEC)
	_kills_tween.tween_callback(_kills_label.hide)


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
	if _kills_tween != null:
		_kills_tween.kill()
	if _clear_tween != null:
		_clear_tween.kill()
	_kills_tween = null
	_clear_tween = null
	_kills_count = 0
	_streak_tier = 0
	_clear_shown = false
	for label in [_kills_label, _clear_label]:
		if is_instance_valid(label):
			label.hide()
			label.scale = Vector2.ONE
			label.modulate.a = 1.0


func _tier_for(count: int) -> int:
	if count >= 10:
		return 3
	if count >= 5:
		return 2
	return 1 if count >= 3 else 0


func _motion_allowed() -> bool:
	return not Presentation._toggle("reduced_motion") and not Tokens.reduced_motion()


func _refresh_text() -> void:
	var english := LocaleManager.get_locale().begins_with("en")
	_kills_label.text = ("Kills ×%d" if english else "击杀 ×%d") % _kills_count
	_clear_label.text = "LANE CLEAR" if english else "本路已清"


func _on_locale_changed(_locale: String) -> void:
	_refresh_text()
