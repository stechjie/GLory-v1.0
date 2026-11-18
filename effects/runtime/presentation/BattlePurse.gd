extends Control
## 战斗左下角的钱袋：这一场战斗自己赚到的钱，从 0 开始（11-18 用户定）。
## 只算两样：杀怪 / 杀棋子的击杀金（自己拿到的那份，跨路帮杀是一半），和前三名奖励。
## 其它收入（胜负奖励、安慰金、商人、宝藏、利息、营地）照旧在结算面板里，不进钱袋。
## 战斗中的击杀金由调用方按服务器同一套公式逐只算出来（add_kill），战斗结束用服务器结算的准确数
## set_total 刷一次，保证最后的数和到账一致。
## 调用方注意：Boss 局服务器不发击杀金 → 不调 add_kill；第 21 回合（最后一回合）不显示钱袋。

const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Fonts := preload("res://ui/fonts/UIFontFallback.gd")
const DISPLAY_FONT := preload("res://ui/fonts/LibreBaskerville-Variable.ttf")
## 对局内金币统一用这张。运行时 load：战斗服务器包不带导入过的贴图。
const COIN_PATH := "res://assets/ui/unit_detail/icon_gold_stack.png"

const PURSE_SIZE := Vector2(176, 58)
const ICON_SIZE := 64.0
## 连杀合并：上一次跳字后这么久之内的击杀，加进同一个「+N」。和击杀金币音效的合并同一个思路。
const MERGE_SEC := 1.0
const COUNT_SEC := 0.35
const FLY_COINS := 7
const FLY_SEC := 0.5

var _total := 0
var _shown := 0.0
var _icon: TextureRect
var _number: Label
var _caption: Label
## 钱袋右边弹出的进账签：「击杀 +45」「伤害第 1 名 +150」。说清楚钱是哪来的。
var _toast: Panel
var _toast_style: StyleBoxFlat
var _toast_reason: Label
var _toast_amount: Label
var _float_amount := 0
var _float_msec := -100000
var _float_tween: Tween
var _count_tween: Tween
var _bump_tween: Tween
var _coin_tex: Texture2D
var _display_font: FontVariation


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	size = PURSE_SIZE
	custom_minimum_size = PURSE_SIZE


func _ready() -> void:
	if ResourceLoader.exists(COIN_PATH):
		_coin_tex = load(COIN_PATH) as Texture2D
	_display_font = FontVariation.new()
	_display_font.base_font = DISPLAY_FONT
	_display_font.variation_opentype = {"wght": 600.0}
	_display_font.opentype_features = {"lnum": 1, "tnum": 1}
	# 底：深胡桃木色胶囊 + 金边，和伤害木牌同一路；金币图标压在左端往外探。
	var pill := Panel.new()
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.position = Vector2(ICON_SIZE * 0.45, 8)
	pill.size = Vector2(PURSE_SIZE.x - ICON_SIZE * 0.45, PURSE_SIZE.y - 12)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.20, 0.10, 0.035, 0.90)
	style.border_color = Color("d4a23c")
	style.set_border_width_all(2)
	style.set_corner_radius_all(int(pill.size.y * 0.5))
	style.shadow_color = Color(0, 0, 0, 0.4)
	style.shadow_size = 4
	style.shadow_offset = Vector2(0, 2)
	pill.add_theme_stylebox_override("panel", style)
	add_child(pill)
	_caption = Label.new()
	_caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_caption.position = Vector2(ICON_SIZE * 0.92, 9)
	_caption.size = Vector2(80, 16)
	_caption.text = "This battle" if _english() else "本局收入"
	_caption.add_theme_font_size_override("font_size", 12)
	_caption.add_theme_color_override("font_color", Color("d9c193"))
	var bold := Fonts.bold_font()
	if bold != null:
		_caption.add_theme_font_override("font", bold)
	add_child(_caption)
	_number = Label.new()
	_number.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_number.position = Vector2(ICON_SIZE * 0.92, 20)
	_number.size = Vector2(PURSE_SIZE.x - ICON_SIZE * 0.92 - 14, 34)
	_number.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_number.add_theme_font_override("font", _display_font)
	_number.add_theme_font_size_override("font_size", 26)
	_number.add_theme_color_override("font_color", Color("ffe08a"))
	_number.add_theme_color_override("font_outline_color", Color("2a1406"))
	_number.add_theme_constant_override("outline_size", 4)
	add_child(_number)
	_icon = TextureRect.new()
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.size = Vector2.ONE * ICON_SIZE
	_icon.position = Vector2(0, (PURSE_SIZE.y - ICON_SIZE) * 0.5 - 2)
	_icon.pivot_offset = _icon.size * 0.5
	_icon.texture = _coin_tex
	add_child(_icon)
	_build_toast()
	_render_number()


func reset() -> void:
	_total = 0
	_shown = 0.0
	_float_amount = 0
	_float_msec = -100000
	for t in [_float_tween, _count_tween, _bump_tween]:
		if t != null:
			(t as Tween).kill()
	if _toast != null:
		_toast.hide()
	if _number != null:
		_render_number()


## 杀了一只（或几只同时）：钱袋数字往上滚，右边弹「击杀 +N」；MERGE_SEC 内连杀合并成一个数。
func add_kill(amount: int) -> void:
	if amount <= 0:
		return
	_total += amount
	var now := Time.get_ticks_msec()
	if now - _float_msec <= int(MERGE_SEC * 1000.0) and _toast.visible:
		_float_amount += amount
	else:
		_float_amount = amount
	_float_msec = now
	_show_toast("Kills" if _english() else "击杀", _float_amount, false)
	_count_to(_total)
	_bump(1.12)


## 前三名奖励：一串金币从 from_global（名次木牌 / 绶带）飞进钱袋，到了再弹「reason +N」。
## reason 由调用方给，如「伤害第 1 名」「清路第 2 名」。
func fly_in(from_global: Vector2, amount: int, reason: String) -> void:
	if amount <= 0:
		return
	_total += amount
	if not _motion_allowed() or _coin_tex == null:
		_show_toast(reason, amount, true)
		_count_to(_total)
		_bump(1.25)
		return
	var target := _icon.position + _icon.size * 0.5
	var start := from_global - global_position
	for i in FLY_COINS:
		var coin := TextureRect.new()
		coin.mouse_filter = Control.MOUSE_FILTER_IGNORE
		coin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		coin.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		coin.texture = _coin_tex
		coin.size = Vector2.ONE * 38.0
		coin.pivot_offset = coin.size * 0.5
		coin.z_index = 50
		var jitter := Vector2(randf_range(-18, 18), randf_range(-12, 12))
		coin.position = start + jitter - coin.size * 0.5
		coin.modulate.a = 0.0
		add_child(coin)
		# 先往外弹开一点，再沿弧线落进钱袋；一枚枚错开出发，像一串金币。
		var delay := float(i) * 0.06
		var spread := start + jitter * 2.2 + Vector2(randf_range(-10, 10), -26.0)
		var tween := coin.create_tween()
		tween.tween_interval(delay)
		tween.tween_property(coin, "modulate:a", 1.0, 0.08)
		tween.tween_property(coin, "position", spread - coin.size * 0.5, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_method(func(t: float) -> void:
			var a := spread
			var b := target
			var control := Vector2(lerpf(a.x, b.x, 0.25), minf(a.y, b.y) - 60.0)
			var p := a.lerp(control, t).lerp(control.lerp(b, t), t)
			coin.position = p - coin.size * 0.5
			coin.scale = Vector2.ONE * lerpf(1.0, 0.7, t), 0.0, 1.0, FLY_SEC).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tween.tween_callback(coin.queue_free)
		if i == 0:
			tween.tween_callback(func() -> void:
				_show_toast(reason, amount, true)
				_count_to(_total)
				_bump(1.25))
		elif i < FLY_COINS - 1:
			tween.tween_callback(func() -> void: _bump(1.08))


## 战斗结束：用服务器结算的准确数刷一次（击杀金 + 排名奖励）。
func set_total(exact: int) -> void:
	_total = maxi(0, exact)
	_count_to(_total)


func total() -> int:
	return _total


func _count_to(value: int) -> void:
	if _count_tween != null:
		_count_tween.kill()
	if not _motion_allowed():
		_shown = float(value)
		_render_number()
		return
	_count_tween = create_tween()
	_count_tween.tween_method(func(v: float) -> void:
		_shown = v
		_render_number(), _shown, float(value), COUNT_SEC).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _render_number() -> void:
	_number.text = str(roundi(_shown))


func _bump(peak: float) -> void:
	if not _motion_allowed():
		return
	if _bump_tween != null:
		_bump_tween.kill()
	_icon.scale = Vector2.ONE * peak
	_bump_tween = create_tween()
	_bump_tween.tween_property(_icon, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _build_toast() -> void:
	_toast = Panel.new()
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_style = StyleBoxFlat.new()
	_toast_style.set_border_width_all(2)
	_toast_style.set_corner_radius_all(14)
	_toast_style.shadow_color = Color(0, 0, 0, 0.4)
	_toast_style.shadow_size = 4
	_toast_style.shadow_offset = Vector2(0, 2)
	_toast_style.content_margin_left = 12
	_toast_style.content_margin_right = 12
	_toast.add_theme_stylebox_override("panel", _toast_style)
	_toast_reason = Label.new()
	_toast_reason.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_reason.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toast_reason.add_theme_color_override("font_color", Color("f3e3c0"))
	var bold := Fonts.bold_font()
	if bold != null:
		_toast_reason.add_theme_font_override("font", bold)
	_toast.add_child(_toast_reason)
	_toast_amount = Label.new()
	_toast_amount.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_amount.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toast_amount.add_theme_font_override("font", _display_font)
	_toast_amount.add_theme_color_override("font_color", Color("ffe08a"))
	_toast_amount.add_theme_color_override("font_outline_color", Color("2a1406"))
	_toast_amount.add_theme_constant_override("outline_size", 4)
	_toast.add_child(_toast_amount)
	_toast.hide()
	add_child(_toast)


# 进账签从钱袋右边滑出来，停一下再淡掉。big = 排名奖励：签子大一号、暖红底亮金边、停得久。
func _show_toast(reason: String, amount: int, big: bool) -> void:
	if _float_tween != null:
		_float_tween.kill()
	var reason_size := 15 if big else 13
	var amount_size := 26 if big else 20
	var height := 40.0 if big else 32.0
	_toast_style.bg_color = Color(0.36, 0.11, 0.05, 0.94) if big else Color(0.20, 0.10, 0.035, 0.90)
	_toast_style.border_color = Color("ffd45c") if big else Color("b98a32")
	_toast_style.set_corner_radius_all(int(height * 0.5))
	_toast_reason.text = reason
	_toast_reason.add_theme_font_size_override("font_size", reason_size)
	_toast_amount.text = "+%d" % amount
	_toast_amount.add_theme_font_size_override("font_size", amount_size)
	var reason_w := _toast_reason.get_theme_font("font").get_string_size(reason, HORIZONTAL_ALIGNMENT_LEFT, -1, reason_size).x
	var amount_w := _display_font.get_string_size(_toast_amount.text, HORIZONTAL_ALIGNMENT_LEFT, -1, amount_size).x
	var pad := 12.0
	var gap := 6.0 if not reason.is_empty() else 0.0
	_toast.size = Vector2(pad + reason_w + gap + amount_w + pad + 4.0, height)
	_toast_reason.position = Vector2(pad, 0)
	_toast_reason.size = Vector2(reason_w + 2.0, height)
	_toast_amount.position = Vector2(pad + reason_w + gap, -1)
	_toast_amount.size = Vector2(amount_w + 6.0, height)
	var base := Vector2(PURSE_SIZE.x + 6.0, (PURSE_SIZE.y - height) * 0.5 + 2.0)
	_toast.pivot_offset = Vector2(0, height * 0.5)
	_toast.position = base
	_toast.modulate = Color.WHITE
	_toast.scale = Vector2.ONE
	_toast.show()
	_float_tween = create_tween()
	if not _motion_allowed():
		_float_tween.tween_interval(1.6 if big else 1.0)
		_float_tween.tween_callback(_toast.hide)
		return
	# 同一个签子连杀刷新数字时只轻跳一下，不重新滑出。
	var refresh: bool = not big and bool(_toast.get_meta("kill_live", false))
	_toast.set_meta("kill_live", not big)
	if refresh:
		_toast.scale = Vector2.ONE * 1.08
		_float_tween.tween_property(_toast, "scale", Vector2.ONE, 0.15)
	else:
		_toast.position = base - Vector2(18, 0)
		_toast.modulate.a = 0.0
		_toast.scale = Vector2(0.85, 0.85)
		_float_tween.set_parallel(true)
		_float_tween.tween_property(_toast, "position", base, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_float_tween.tween_property(_toast, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_float_tween.tween_property(_toast, "modulate:a", 1.0, 0.12)
		if big and Presentation.flash_allowed():
			_float_tween.chain().tween_property(_toast, "modulate", Color(1.5, 1.35, 1.05, 1.0), 0.08)
			_float_tween.chain().tween_property(_toast, "modulate", Color.WHITE, 0.35)
		_float_tween.set_parallel(false)
	_float_tween.tween_interval(1.5 if big else 0.7)
	_float_tween.tween_property(_toast, "modulate:a", 0.0, 0.3)
	_float_tween.tween_callback(func() -> void:
		_toast.hide()
		_toast.set_meta("kill_live", false))


func _english() -> bool:
	return LocaleManager.get_locale().begins_with("en")


func _motion_allowed() -> bool:
	return not Presentation._toggle("reduced_motion") and not Tokens.reduced_motion()
