extends Control
## 战斗左下角的钱袋：这一场战斗自己赚到的钱，从 0 开始（11-18 用户定）。
## 只算两样：杀怪 / 杀棋子的击杀金（自己拿到的那份，跨路帮杀是一半），和前三名奖励。
## 其它收入（胜负奖励、安慰金、商人、宝藏、利息、营地）照旧在结算面板里，不进钱袋。
## 战斗中的击杀金由调用方从回放的击杀金账本逐笔喂进来（add_kill），战斗结束用准确数
## set_total 刷一次，保证最后的数和到账一致。
## 进账提示（11-18 用户定）：不做横出来的签子，每一笔在钱袋数字正上方冒一个「+N」，
## 新的从下面冒、把旧的往上顶，叠成一串再一个个淡掉（A）；排名奖励是大号「+150」，
## 上面一行小字「伤害第 1 名」，竖着叠（B）。同一瞬间死几只是一笔（回放按帧记总数），字大一号。
## 调用方注意：Boss 局服务器不发击杀金 → 不调 add_kill；第 21 回合（最后一回合）不显示钱袋。

const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Fonts := preload("res://ui/fonts/UIFontFallback.gd")
const DISPLAY_FONT := preload("res://ui/fonts/LibreBaskerville-Variable.ttf")
## 对局内金币统一用这张。运行时 load：战斗服务器包不带导入过的贴图。
const COIN_PATH := "res://assets/ui/unit_detail/icon_gold_stack.png"

const PURSE_SIZE := Vector2(176, 58)
const ICON_SIZE := 64.0
const COUNT_SEC := 0.35
## 一笔「+N」停留多久再淡掉；排名奖励停久一点。
const POP_LIFE := 0.9
const RANK_POP_LIFE := 1.8
const POP_FADE := 0.3
## 同时最多叠几个，再多就让最上面（最旧）那个提前淡掉，免得清怪快时叠成一长条挡战场。
const MAX_POPS := 5
const POP_GAP := 2.0
## 一笔达到这个数（同一瞬间死了好几只）字大一号。
const BIG_KILL := 30
const FLY_COINS := 7
const FLY_SEC := 0.5

var _total := 0
var _shown := 0.0
var _icon: TextureRect
var _number: Label
var _caption: Label
## 正在显示的「+N」，最新的在最前面。
var _pops: Array[Control] = []
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
	_render_number()


func reset() -> void:
	_total = 0
	_shown = 0.0
	for t in [_count_tween, _bump_tween]:
		if t != null:
			(t as Tween).kill()
	for pop in _pops:
		if is_instance_valid(pop):
			pop.queue_free()
	_pops.clear()
	if _number != null:
		_render_number()


## 一笔击杀金：钱袋数字往上滚，数字上方冒一个「+N」叠上去。
func add_kill(amount: int) -> void:
	if amount <= 0:
		return
	_total += amount
	_push_pop("", amount, false)
	_count_to(_total)
	_bump(1.12)


## 前三名奖励：一串金币从 from_global（名次木牌 / 绶带）飞进钱袋，到了再冒大号「+N」，上面一行 reason。
## reason 由调用方给，如「伤害第 1 名」「清路第 2 名」。
func fly_in(from_global: Vector2, amount: int, reason: String) -> void:
	if amount <= 0:
		return
	_total += amount
	if not _motion_allowed() or _coin_tex == null:
		_push_pop(reason, amount, true)
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
				_push_pop(reason, amount, true)
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


# 冒一个「+N」：新的落在数字正上方，已有的往上让出它的高度，叠成一串。
func _push_pop(reason: String, amount: int, rank: bool) -> void:
	var pop := Control.new()
	pop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pop.z_index = 40
	var big := rank or amount >= BIG_KILL
	var amount_size := 32 if rank else (26 if big else 22)
	var y := 0.0
	if rank and not reason.is_empty():
		var reason_label := Label.new()
		reason_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		reason_label.text = reason
		reason_label.add_theme_font_size_override("font_size", 14)
		reason_label.add_theme_color_override("font_color", Color("fff0cf"))
		reason_label.add_theme_color_override("font_outline_color", Color("2a1406"))
		reason_label.add_theme_constant_override("outline_size", 5)
		var bold := Fonts.bold_font()
		if bold != null:
			reason_label.add_theme_font_override("font", bold)
		reason_label.position = Vector2(2, 0)
		pop.add_child(reason_label)
		y = 18.0
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = "+%d" % amount
	label.position = Vector2(0, y - 4.0)
	label.add_theme_font_override("font", _display_font)
	label.add_theme_font_size_override("font_size", amount_size)
	label.add_theme_color_override("font_color", Color("ffd24a") if rank else Color("ffe08a"))
	label.add_theme_color_override("font_outline_color", Color("2a1406"))
	label.add_theme_constant_override("outline_size", 7 if big else 6)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.45))
	label.add_theme_constant_override("shadow_offset_y", 2)
	pop.add_child(label)
	var height := y + float(amount_size) * 1.05
	pop.size = Vector2(140, height)
	pop.set_meta("h", height)
	pop.pivot_offset = Vector2(0, height)
	add_child(pop)
	_pops.push_front(pop)
	# 太多就让最旧的那个提前走。
	while _pops.size() > MAX_POPS:
		_retire_pop(_pops.pop_back(), 0.12)
	_restack(pop)
	var motion := _motion_allowed()
	if motion:
		pop.scale = Vector2.ONE * (1.35 if big else 1.2)
		pop.modulate.a = 0.0
		var appear := pop.create_tween().set_parallel(true)
		appear.tween_property(pop, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		appear.tween_property(pop, "modulate:a", 1.0, 0.1)
		if rank and Presentation.flash_allowed():
			appear.chain().tween_property(pop, "modulate", Color(1.5, 1.35, 1.05, 1.0), 0.08)
			appear.chain().tween_property(pop, "modulate", Color.WHITE, 0.3)
	var life := pop.create_tween()
	life.tween_interval(RANK_POP_LIFE if rank else POP_LIFE)
	life.tween_callback(func() -> void:
		if _pops.has(pop):
			_pops.erase(pop)
			_retire_pop(pop, POP_FADE))


# 每个「+N」的目标高度：最新的贴着钱袋顶上，往上依次排。
func _restack(fresh: Control) -> void:
	var base_x := ICON_SIZE * 0.92
	var y := 4.0
	for pop in _pops:
		var h := float(pop.get_meta("h", 24.0))
		y -= h + POP_GAP
		var target := Vector2(base_x, y)
		if pop == fresh or not _motion_allowed():
			pop.position = target
			continue
		var old: Tween = pop.get_meta("move") if pop.has_meta("move") else null
		if old != null and old.is_valid():
			old.kill()
		var move := pop.create_tween()
		move.tween_property(pop, "position", target, 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		pop.set_meta("move", move)


func _retire_pop(pop: Control, sec: float) -> void:
	if not is_instance_valid(pop):
		return
	var move: Tween = pop.get_meta("move") if pop.has_meta("move") else null
	if move != null and move.is_valid():
		move.kill()
	if not _motion_allowed():
		pop.queue_free()
		return
	var fade := pop.create_tween().set_parallel(true)
	fade.tween_property(pop, "modulate:a", 0.0, sec)
	fade.tween_property(pop, "position:y", pop.position.y - 10.0, sec)
	fade.chain().tween_callback(pop.queue_free)


func _english() -> bool:
	return LocaleManager.get_locale().begins_with("en")


func _motion_allowed() -> bool:
	return not Presentation._toggle("reduced_motion") and not Tokens.reduced_motion()
