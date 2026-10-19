extends Control

# 升 4★ 那一瞬间的**全屏**特效。只在**自己**升 4★ 时放（Leno 10.18：队友升不打断你）。
#
# ## 三种属性，接 FourStarAuraV3 的三种风格
#
#   天 sky  = 一阵羽毛从屏幕外被风卷向棋子（最轻柔）
#   地 land = 屏幕外的橙色碎晶向棋子收拢，到了轻轻一震
#   人 ren  = 一道闪电从屏幕顶劈到棋子，到了一震（最「重」）
#
# 三种都在 IMPACT_SEC 汇到棋子上，那一刻发 impact 信号：调用方在这一刻才放 3D 爆发、
# 压扁回弹、★★★★ 回弹 —— 全屏的东西「落到」棋子上，棋子才炸开，前后是一个动作。
#
# ## Leno 10.18 明确不要的
#
#   · **不压暗**（原提的「聚光灯」）—— 会盖住倒计时和商店。
#   · **不闪白**（原提的「人·雷电白闪」）。
#   所以这里没有任何全屏铺色：唯一盖满整屏的是这个 Control 本身，而它什么都不铺，
#   只在元素所在的位置画东西。
#
# ## 约束
#
#   · 不挡点击：mouse_filter = IGNORE，玩家在特效期间照样能拖棋子、点商店。
#   · 不动 Engine.time_scale：备战倒计时会被一起拖慢。
#   · 纯 _draw()：不碰 StyleBoxFlat.new() / Button.new()（procedural_ui_ratchet 棘轮）。
#   · 贴图全部复用 FourStarAuraV3 的程序生成图（羽毛 / 碎晶 / 闪电 / 余烬 / 星点），
#     不新增贴图内存 —— 手机卡的根因是贴图内存，见记忆里的实测结论。

signal impact(element: String)

const DURATION := 1.0
const IMPACT_SEC := 0.36

const FEATHER_COUNT := 18
const SHARD_COUNT := 16
const SPARK_COUNT := 14
# 入场元素从多远飞进来：屏幕对角线的这个比例。> 0.5 才能保证起点在屏幕外。
const ENTRY_RADIUS_RATIO := 0.62

var element := "sky"
var target := Vector2.ZERO
var palette: Array = [Color.BLACK, Color.WHITE, Color.WHITE]   # [dark, body, core]
var textures: Dictionary = {}

var _age := 0.0
var _impacted := false
var _bolt_points := PackedVector2Array()
var _bolt_reroll := 0.0
var _rng := RandomNumberGenerator.new()
var _items: Array[Dictionary] = []
var _sparks: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pass


func play(p_element: String, p_target: Vector2, p_palette: Array, p_textures: Dictionary) -> void:
	element = p_element
	target = p_target
	palette = p_palette
	textures = p_textures
	# 混合方式按属性分。备战棋盘底下是亮草绿：
	#   · 天·羽毛是近白色，加色混合下才「发光」；正常混合在浅绿上发灰、一点都不亮。
	#   · 地·碎晶是橙色，加色混合会被草绿冲成一片淡黄 —— 第一次真棋盘截图里碎晶
	#     几乎看不见，就是这个原因。人·雷电同理（红色要保住是红色）。
	if element == "sky":
		var mat := CanvasItemMaterial.new()
		mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		material = mat
	else:
		material = null
	_age = 0.0
	_impacted = false
	_rng.seed = hash("four_star_screen_%s" % element)
	_items.clear()
	_sparks.clear()
	var radius := get_viewport_rect().size.length() * ENTRY_RADIUS_RATIO
	match element:
		"sky":
			for i in FEATHER_COUNT:
				var a := TAU * float(i) / float(FEATHER_COUNT) + _rng.randf_range(-0.2, 0.2)
				_items.append({
					"from": target + Vector2(cos(a), sin(a)) * radius * _rng.randf_range(0.8, 1.1),
					# 弯的那一下：控制点往切向偏，羽毛是被风「卷」进来的，不是直线射进来。
					"bend": Vector2(-sin(a), cos(a)) * radius * _rng.randf_range(0.25, 0.45),
					"delay": _rng.randf_range(0.0, 0.10),
					"spin": _rng.randf_range(-6.0, 6.0),
					"size": _rng.randf_range(30.0, 46.0),
				})
		"land":
			for i in SHARD_COUNT:
				var a := TAU * float(i) / float(SHARD_COUNT) + _rng.randf_range(-0.15, 0.15)
				_items.append({
					# 碎晶从**屏幕内**起飞（半径收到羽毛的六成）：第一版从屏幕外直线加速飞进来，
					# 大半程都在画面外，真正在屏幕上的只有最后一两帧 —— 截图里一片都没拍到。
					"from": target + Vector2(cos(a), sin(a)) * radius * _rng.randf_range(0.42, 0.62),
					"bend": Vector2.ZERO,
					"delay": _rng.randf_range(0.0, 0.08),
					"spin": _rng.randf_range(-10.0, 10.0),
					"size": _rng.randf_range(24.0, 38.0),
				})
		"ren":
			_reroll_bolt()
	queue_redraw()


func _process(delta: float) -> void:
	_age += delta
	if not _impacted and _age >= IMPACT_SEC:
		_impacted = true
		_spawn_impact_sparks()
		impact.emit(element)
	if element == "ren":
		_bolt_reroll -= delta
		if _bolt_reroll <= 0.0:
			_reroll_bolt()
	for spark in _sparks:
		spark["pos"] = (spark["pos"] as Vector2) + (spark["vel"] as Vector2) * delta
		spark["vel"] = (spark["vel"] as Vector2) * pow(0.04, delta)   # 很快减速，像被空气拖住
	queue_redraw()
	if _age >= DURATION:
		queue_free()


# 闪电每 0.045 秒重新抖一次折线 —— 一条静止的折线读起来是「一根裂缝」，抖起来才是电。
func _reroll_bolt() -> void:
	_bolt_reroll = 0.045
	var top := Vector2(target.x + _rng.randf_range(-60.0, 60.0), -20.0)
	var segments := 11
	_bolt_points = PackedVector2Array()
	for i in segments + 1:
		var t := float(i) / float(segments)
		var p := top.lerp(target, t)
		if i > 0 and i < segments:
			# 中段抖得最厉害，两端收拢 —— 起点贴着屏幕顶、终点一定落在棋子上。
			p.x += _rng.randf_range(-1.0, 1.0) * 46.0 * sin(t * PI)
		_bolt_points.append(p)


# 冲击那一刻往外迸一圈属性色的星点。三种属性都有这一下：它是「落到了」的确认。
func _spawn_impact_sparks() -> void:
	for i in SPARK_COUNT:
		var a := TAU * float(i) / float(SPARK_COUNT) + _rng.randf_range(-0.25, 0.25)
		_sparks.append({
			"pos": target,
			"vel": Vector2(cos(a), sin(a) * 0.7) * _rng.randf_range(260.0, 520.0),
			"size": _rng.randf_range(14.0, 26.0),
		})


func _draw() -> void:
	var body: Color = palette[1] if palette.size() > 1 else Color.WHITE
	var core: Color = palette[2] if palette.size() > 2 else Color.WHITE
	_draw_pulse(body)
	match element:
		"sky": _draw_flyers(textures.get("feather"), core, true)
		"land": _draw_flyers(textures.get("shard"), body, false)
		"ren": _draw_bolt(body, core)
	_draw_sparks(textures.get("toon_ember" if element == "ren" else "sparkle"), core)


# 冲击时从棋子往外扩的一圈属性色光晕。只在棋子周围，不铺满屏 —— 不压暗、不闪白。
func _draw_pulse(color: Color) -> void:
	var t := (_age - IMPACT_SEC) / 0.40
	if t < 0.0 or t > 1.0:
		return
	var grow := 1.0 - pow(1.0 - t, 2.2)
	var radius := lerpf(30.0, 240.0, grow)
	var fade := 1.0 - t
	for i in 6:
		var k := float(i) / 5.0
		var c := color
		c.a = 0.10 * fade * (1.0 - k)
		draw_circle(target, radius * (0.55 + 0.45 * k), c)


# 羽毛 / 碎晶：从屏幕外飞到棋子上。羽毛走弯线、慢进快到；碎晶走直线、越飞越快（ease-in）。
func _draw_flyers(tex: Texture2D, color: Color, curved: bool) -> void:
	if tex == null:
		return
	var travel := IMPACT_SEC
	for item in _items:
		var p := (_age - float(item["delay"])) / maxf(travel - float(item["delay"]), 0.05)
		if p < 0.0 or p > 1.0:
			continue
		var from: Vector2 = item["from"]
		var pos: Vector2
		if curved:
			var e := 1.0 - pow(1.0 - p, 1.6)
			var mid := from.lerp(target, 0.5) + (item["bend"] as Vector2)
			pos = from.lerp(mid, e).lerp(mid.lerp(target, e), e)
		else:
			# 先慢后快地收拢（p^1.4）。纯 p² 太陡：前七成时间几乎不动，最后一下才冲进来，
			# 屏幕上看不到「收拢」的过程。
			pos = from.lerp(target, pow(p, 1.4))
		var size := float(item["size"]) * lerpf(1.0, 0.55, p)
		var c := color
		c.a = smoothstep(0.0, 0.15, p) * (1.0 - smoothstep(0.85, 1.0, p))
		draw_set_transform(pos, float(item["spin"]) * _age, Vector2.ONE)
		draw_texture_rect(tex, Rect2(Vector2(-size, -size) * 0.5, Vector2(size, size)), false, c)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# 闪电：外层属性色粗线 + 内层亮芯细线。只在 [0.12, IMPACT_SEC] 这一段亮，劈下来就收。
func _draw_bolt(body: Color, core: Color) -> void:
	if _bolt_points.size() < 2:
		return
	var t := (_age - 0.12) / (IMPACT_SEC + 0.06 - 0.12)
	if t < 0.0 or t > 1.0:
		return
	# 从上往下「长」出来：只画到当前进度对应的那一截。
	var reach := clampi(int(ceil(float(_bolt_points.size() - 1) * minf(t * 1.6, 1.0))) + 1, 2, _bolt_points.size())
	var shown := _bolt_points.slice(0, reach)
	var fade := 1.0 - smoothstep(0.7, 1.0, t)
	var outer := body
	outer.a = 0.75 * fade
	var inner := core
	inner.a = 0.95 * fade
	draw_polyline(shown, outer, 9.0, true)
	draw_polyline(shown, inner, 3.0, true)


func _draw_sparks(tex: Texture2D, color: Color) -> void:
	if tex == null or _sparks.is_empty():
		return
	var t := clampf((_age - IMPACT_SEC) / (DURATION - IMPACT_SEC), 0.0, 1.0)
	var c := color
	c.a = 1.0 - smoothstep(0.35, 1.0, t)
	for spark in _sparks:
		var size := float(spark["size"]) * (1.0 - 0.5 * t)
		var pos: Vector2 = spark["pos"]
		draw_texture_rect(tex, Rect2(pos - Vector2(size, size) * 0.5, Vector2(size, size)), false, c)
