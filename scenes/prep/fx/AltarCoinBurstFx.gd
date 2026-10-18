extends Control

# 黄金祭坛的爆金币演出，约 1.3 秒，不挡操作（不接收鼠标）。
#
# 从顶栏正中（12 点方向）自家法阵水晶喷出一把金币：先一圈金光，金币向上、向两侧
# 抛出，翻转着落下淡出。自己献祭时水晶下方还会浮出「+N」；队友献祭时同队每个人
# 都在自己屏幕的水晶上看到同一把金币，只是不带数字（钱进的是队友的口袋）。
#
# 减弱动态效果时只有金光和数字，不抛金币。不用外部贴图，金币是 _draw() 画的。

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const SfxService := preload("res://ui/services/SfxService.gd")

signal finished

const LIFE := 1.3
const COIN_COUNT := 16
const GRAVITY := 900.0
const COIN_R := 13.0
const GOLD := Color(1.0, 0.80, 0.22)
const GOLD_LIGHT := Color(1.0, 0.95, 0.62)
const GOLD_DARK := Color(0.58, 0.34, 0.04)

var _t := 0.0
var _origin := Vector2.ZERO
var _amount_text := ""
var _reduced := false
var _coins: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	set_process(false)


# at：水晶中心（全局坐标）。gold_gain <= 0 表示队友献祭，只放金币不显示数字。
func play(at: Vector2, gold_gain: int, options: Dictionary = {}) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_origin = at - global_position
	_amount_text = ("+%d" % gold_gain) if gold_gain > 0 else ""
	_reduced = bool(options.get("reduced_motion", Tokens.reduced_motion()))
	_rng.randomize()
	if not _reduced:
		for i in COIN_COUNT:
			# 向下半圆以外的方向抛：水晶在顶栏，金币往下、往两侧洒才落在画面里。
			var a := lerpf(0.15 * PI, 0.85 * PI, _rng.randf())
			var speed := _rng.randf_range(260.0, 520.0)
			_coins.append({
				"p": _origin,
				"v": Vector2(cos(a) * speed, -sin(a) * speed * 0.55 + 120.0),
				"spin": _rng.randf_range(8.0, 16.0),
				"phase": _rng.randf() * TAU,
				"s": _rng.randf_range(0.75, 1.15),
				"delay": _rng.randf() * 0.12,
			})
	if bool(options.get("sound", true)):
		SfxService.play(SfxService.CUE_UI_CURRENCY_GAIN)
	_t = 0.0
	set_process(true)
	queue_redraw()


func _process(delta: float) -> void:
	_t += delta
	for c in _coins:
		if _t < float(c["delay"]):
			continue
		c["v"] = (c["v"] as Vector2) + Vector2(0, GRAVITY) * delta
		c["p"] = (c["p"] as Vector2) + (c["v"] as Vector2) * delta
	if _t >= LIFE:
		set_process(false)
		finished.emit()
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var k := clampf(_t / LIFE, 0.0, 1.0)
	# 金光：水晶处一圈扩散环 + 柔光底
	var flash := clampf(_t / 0.45, 0.0, 1.0)
	draw_circle(_origin, 70.0 * (0.6 + flash), Color(GOLD_LIGHT, 0.45 * (1.0 - flash)))
	draw_arc(_origin, 40.0 + 110.0 * flash, 0.0, TAU, 48, Color(GOLD, 0.9 * (1.0 - flash)), 6.0 * (1.0 - flash) + 1.5)
	for c in _coins:
		if _t < float(c["delay"]):
			continue
		var fade := 1.0 - smoothstep(0.7, 1.0, k)
		var flip := absf(cos(float(c["phase"]) + _t * float(c["spin"])))
		var r := COIN_R * float(c["s"])
		draw_set_transform(c["p"], 0.0, Vector2(maxf(0.15, flip), 1.0))
		draw_circle(Vector2.ZERO, r, Color(GOLD_DARK, fade))
		draw_circle(Vector2.ZERO, r * 0.82, Color(GOLD, fade))
		draw_circle(Vector2(-r * 0.25, -r * 0.3), r * 0.32, Color(GOLD_LIGHT, 0.85 * fade))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if not _amount_text.is_empty():
		var font := get_theme_default_font()
		var size := 34
		var w := font.get_string_size(_amount_text, HORIZONTAL_ALIGNMENT_CENTER, -1, size).x
		var fade := 1.0 - smoothstep(0.65, 1.0, k)
		var at := _origin + Vector2(-w * 0.5, 78.0 + 40.0 * k)
		draw_string_outline(font, at, _amount_text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 7, Color(0.08, 0.05, 0.02, fade))
		draw_string(font, at, _amount_text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(GOLD, fade))
