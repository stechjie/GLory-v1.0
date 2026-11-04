extends Control
# 卷轴商店棋子卡的卡框，用代码画（11.04 起替代 assets/ui/shop/card_frame_*.png 三张石框）。
#
# 画风跟用户的卡通美术走（11.04 金属版被打回「太金属感」）：
#   深棕粗描边 + 平涂两层明暗（光从左上：上 / 左边亮，下 / 右边暗）+ 按面切块，不用渐变、不用细亮线。
#   等级靠用户美术里本来就有的元素区分，而不是金属光泽：
#     T1 普通：灰褐石框，什么都不加；
#     T2 稀有：蓝灰石框，两个底角长蓝水晶簇；
#     T3 史诗：暖金框，两个底角长金水晶簇，卡顶一顶小金冠（嵌红宝石）。
#   卡顶星星数 = 阶（T1 一颗、T2 两颗、T3 金冠上三颗）。
#   呼吸光是框外一圈柔和光晕：T1 无、T2 慢、T3 快而亮。
# 升星提示（star_up）：卡顶 12 点方向一团绿色柔光 + 一颗呼吸的大十字星 + 往上飘的小十字星，可冲出卡顶。
#   判据由 ShopPanel 用 PrepRules.first_merge_target 算，和真正买入时一致。
# 种族 logo / 价格数字由 ShopPanel 叠在左上 / 右上角；这里画近战远程章和金币底。
# 近战 / 远程的判据与战斗表现一致：数据表射程 range <= 1 为近战（BattleVfx 同一口径）。
# 坐标写在 200×200 卡面空间里，按实际尺寸等比缩放；装饰可以画到卡外（slot 不裁切）。
# 「减少动态」时全部静止。

const CARD := Vector2(200.0, 200.0)

const OUTLINE := Color("3a2418")       # 深棕描边，和头像 / 宝藏图标的描边同色系
const CREAM := Color("f4e6c8")

# base = 主色，hi = 亮面（左上），lo = 暗面（右下），plate = 名字条，glow = 呼吸光
const TIER_STYLE := {
	1: {"base": Color("8e8679"), "hi": Color("c2b9a9"), "lo": Color("5e574d"), "plate": Color("4e4840"), "glow": Color("d8d0c0")},
	2: {"base": Color("5b7fae"), "hi": Color("98b8e0"), "lo": Color("365582"), "plate": Color("2f4a70"), "glow": Color("7fc4ff")},
	3: {"base": Color("d49a2e"), "hi": Color("fbd56a"), "lo": Color("9a6514"), "plate": Color("7a4f16"), "glow": Color("ffd56a")},
}
# 呼吸光晕：alpha = 最亮时最内层不透明度；layers × step = 宽度；speed = 弧度/秒；low = 最暗比例
const GLOW := {
	1: {"alpha": 0.0, "layers": 0, "step": 0.0, "speed": 0.0, "low": 1.0},
	2: {"alpha": 0.75, "layers": 6, "step": 2.6, "speed": 1.55, "low": 0.2},
	3: {"alpha": 1.0, "layers": 9, "step": 2.8, "speed": 3.0, "low": 0.1},
}
const CRYSTAL := {
	2: {"base": Color("4aa0ff"), "hi": Color("a8dcff"), "lo": Color("2a62c4")},
	3: {"base": Color("f2b630"), "hi": Color("ffe58a"), "lo": Color("c47f14")},
}
const GOLD := Color("eab53a")
const GOLD_HI := Color("ffdc72")
const GOLD_LO := Color("b9821e")

const OUTER_INSET := 3.0
const INNER_INSET := 17.0
const OUTER_RADIUS := 14.0
const INNER_RADIUS := 7.0
const NAME_TOP := 158.0
const COIN_CENTER := Vector2(181.0, 19.0)
const COIN_RADIUS := 18.0
const ROLE_CENTER := Vector2(21.0, 64.0)
const ROLE_RADIUS := 12.0
const STAR_UP_CENTER := Vector2(100.0, 0.0)   # 12 点方向
const STAR_UP_COLOR := Color("6dff9a")
const STAR_UP_SPARKS := 14

var tier := 1
var ranged := false        # true = 远程（弓），false = 近战（剑）
var star_up := false       # 买下即升星
var animated := true
var anim_time := 0.0
var anim_phase := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)
	_update_process()


# 一次设齐卡面状态（商店每次刷新调用）。
func configure(p_tier: int, p_ranged: bool, p_star_up: bool) -> void:
	tier = clampi(p_tier, 1, 3)
	ranged = p_ranged
	star_up = p_star_up
	_update_process()
	queue_redraw()


# 数据表射程格数 > 1 为远程。
static func is_ranged(unit_def: Dictionary) -> bool:
	return float(unit_def.get("range", 1.0)) > 1.0


# 只有会动的卡才每帧重画：T2 / T3 呼吸光、升星光效。T1 普通卡静止不耗帧。
func _update_process() -> void:
	set_process(animated and (tier >= 2 or star_up))


func _process(delta: float) -> void:
	anim_time += delta
	queue_redraw()


func card_scale() -> float:
	return minf(size.x / CARD.x, size.y / CARD.y)


func _draw() -> void:
	var s := card_scale()
	if s <= 0.0:
		return
	draw_set_transform((size - CARD * s) * 0.5, 0.0, Vector2(s, s))
	var st: Dictionary = TIER_STYLE[tier]
	var t := anim_time if animated else 0.0
	var full := Rect2(Vector2.ZERO, CARD)

	# 1. 框外呼吸光晕（柔和、等级色）
	var gl: Dictionary = GLOW[tier]
	var pulse := 1.0
	if animated and float(gl["speed"]) > 0.0:
		var w01 := 0.5 + 0.5 * sin(t * float(gl["speed"]) + anim_phase)
		pulse = lerpf(float(gl["low"]), 1.0, w01 * w01)
	var glow_col: Color = st["glow"]
	var layers := int(gl["layers"])
	for i in layers:
		var g := 1.0 + float(i) * float(gl["step"])
		var fall := 1.0 - float(i) / float(layers)
		_outline(_rounded(full.grow(g - OUTER_INSET), OUTER_RADIUS + g), Color(glow_col.r, glow_col.g, glow_col.b, float(gl["alpha"]) * pulse * fall * fall * 0.45), 3.2)

	# 2. 名字条：头像下方平涂一块，顶上一道深棕线
	var plate_col: Color = st["plate"]
	draw_rect(Rect2(INNER_INSET, NAME_TOP, CARD.x - INNER_INSET * 2.0, CARD.y - INNER_INSET - NAME_TOP), plate_col)
	draw_rect(Rect2(INNER_INSET, NAME_TOP, CARD.x - INNER_INSET * 2.0, 4.0), plate_col.lightened(0.14))
	draw_line(Vector2(INNER_INSET, NAME_TOP), Vector2(CARD.x - INNER_INSET, NAME_TOP), OUTLINE, 2.5)

	# 3. 框带：外圆角矩形与内圆角矩形之间的一圈，按面朝向平涂亮 / 主 / 暗
	_draw_band(st)

	# 4. 等级装饰：T2 / T3 底角水晶簇，T3 金冠，T1/T2 卡顶星星牌
	if tier >= 2:
		var cs: Dictionary = CRYSTAL[tier]
		_crystal_cluster(Vector2(6.0, CARD.y - 2.0), 1.0, cs)
		_crystal_cluster(Vector2(CARD.x - 6.0, CARD.y - 2.0), -1.0, cs)
	if tier == 3:
		_crown(Vector2(100.0, 4.0))
	else:
		_star_tab(tier, st)

	# 5. 近战 / 远程小章
	_disc(ROLE_CENTER, ROLE_RADIUS, Color("2b2230"), st["hi"])
	if ranged:
		_draw_bow(ROLE_CENTER, ROLE_RADIUS * 0.72)
	else:
		_draw_sword(ROLE_CENTER, ROLE_RADIUS * 0.78)

	# 6. 右上金币（数字由外面叠上）：平涂金 + 左上月牙亮面 + 深棕描边
	draw_circle(COIN_CENTER, COIN_RADIUS + 2.5, OUTLINE)
	draw_circle(COIN_CENTER, COIN_RADIUS, GOLD_LO)
	draw_circle(COIN_CENTER + Vector2(-1.2, -1.2), COIN_RADIUS - 2.0, GOLD)
	draw_arc(COIN_CENTER, COIN_RADIUS - 5.0, PI * 1.05, PI * 1.55, 12, GOLD_HI, 2.4, true)

	# 7. 升星
	if star_up:
		_draw_star_up(t)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# 框带：外 / 内两条同参数的圆角矩形轮廓，逐段连成四边形；
# 每段按朝向上色（朝上 / 朝左 = 亮，朝下 / 朝右 = 暗，拐角 = 主色），直边按段交替微调明暗做出切面。
func _draw_band(st: Dictionary) -> void:
	var outer := _rounded(Rect2(Vector2.ZERO, CARD).grow(-OUTER_INSET), OUTER_RADIUS, 6)
	var inner := _rounded(Rect2(Vector2.ZERO, CARD).grow(-INNER_INSET), INNER_RADIUS, 6)
	var n := outer.size()
	var hi: Color = st["hi"]
	var base: Color = st["base"]
	var lo: Color = st["lo"]
	var centre := CARD * 0.5
	for i in n:
		var j := (i + 1) % n
		var m := (outer[i] + outer[j]) * 0.5 - centre
		var col := base
		if m.y < -80.0 or m.x < -80.0:
			col = hi
		if m.y > 80.0 or m.x > 80.0:
			col = lo
		if (m.y < -80.0 and m.x > 80.0) or (m.y > 80.0 and m.x < -80.0):
			col = base
		if i % 2 == 1:
			col = col.darkened(0.10)
		draw_colored_polygon(PackedVector2Array([outer[i], outer[j], inner[j], inner[i]]), col)
	_outline(outer, OUTLINE, 3.6)
	_outline(inner, OUTLINE, 2.6)


# 圆角矩形轮廓点（顺时针，左上角起）。直边额外细分 subdiv 段，外 / 内两条点数一致，供框带逐段连接。
func _rounded(r: Rect2, radius: float, subdiv: int = 1) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var rad := maxf(0.5, minf(radius, minf(r.size.x, r.size.y) * 0.5))
	var centres := [
		r.position + Vector2(rad, rad),
		Vector2(r.end.x - rad, r.position.y + rad),
		r.end - Vector2(rad, rad),
		Vector2(r.position.x + rad, r.end.y - rad),
	]
	var starts := [PI, PI * 1.5, 0.0, PI * 0.5]
	var arc_steps := 4
	for ci in 4:
		var c: Vector2 = centres[ci]
		var a0: float = starts[ci]
		for k in arc_steps + 1:
			var a := a0 + PI * 0.5 * float(k) / float(arc_steps)
			pts.append(c + Vector2(cos(a), sin(a)) * rad)
		var nc: Vector2 = centres[(ci + 1) % 4]
		var na: float = starts[(ci + 1) % 4]
		var end_pt := nc + Vector2(cos(na), sin(na)) * rad
		var start_pt: Vector2 = pts[pts.size() - 1]
		for k in range(1, subdiv):
			pts.append(start_pt.lerp(end_pt, float(k) / float(subdiv)))
	return pts


# 水晶簇：三根长短不一的晶柱，从底角往上 / 往里斜长；每根沿中线劈两半（朝左上的一半亮），深棕描边。
# side = 1 左下角，-1 右下角。
func _crystal_cluster(root: Vector2, side: float, cs: Dictionary) -> void:
	# 尺寸按 180px 卡上能看清来定（11.04 细调：原尺寸太小）
	var specs := [
		[Vector2(side * 20.0, 3.0), 0.40, 28.0, 7.5],
		[Vector2(side * -3.0, -3.0), -0.50, 24.0, 7.0],
		[Vector2(side * 30.0, 4.0), 0.75, 16.0, 5.5],
		[Vector2(side * 6.0, 0.0), 0.0, 42.0, 9.5],
	]
	for sp in specs:
		var base_pt: Vector2 = root + (sp[0] as Vector2)
		var ang: float = -PI * 0.5 + float(sp[1]) * side
		var length: float = sp[2]
		var w: float = sp[3]
		var d := Vector2(cos(ang), sin(ang))
		var nrm := Vector2(-d.y, d.x)
		var tip := base_pt + d * length
		var shoulder := base_pt + d * (length - w * 1.1)
		var shape := PackedVector2Array([base_pt - nrm * w, base_pt + nrm * w, shoulder + nrm * w, tip, shoulder - nrm * w])
		var half_a := PackedVector2Array([base_pt, base_pt + nrm * w, shoulder + nrm * w, tip])
		var half_b := PackedVector2Array([base_pt, tip, shoulder - nrm * w, base_pt - nrm * w])
		var a_lit := nrm.x < 0.0
		_fill(shape, OUTLINE)
		_fill(half_a, cs["hi"] if a_lit else cs["lo"])
		_fill(half_b, cs["lo"] if a_lit else cs["hi"])
		# 主色面压在中间，留出亮 / 暗两条
		var mid_face := PackedVector2Array([base_pt + nrm * w * 0.25, shoulder + nrm * w * 0.25, tip, shoulder - nrm * w * 0.25, base_pt - nrm * w * 0.25])
		_fill(mid_face, cs["base"])
		_outline(shape, OUTLINE, 2.2)
		# 亮面上一点小高光
		draw_circle(shoulder + nrm * w * (-0.45 if nrm.x > 0.0 else 0.45), w * 0.18, Color(1, 1, 1, 0.75))


# 卡顶星星小牌（T1 一颗、T2 两颗）：平涂主色小牌 + 深棕描边。
func _star_tab(n: int, st: Dictionary) -> void:
	var half := 9.0 + 7.0 * float(n)
	var tab := _rounded(Rect2(100.0 - half, -5.0, half * 2.0, 18.0), 6.0)
	_fill(tab, st["base"])
	_fill(_rounded(Rect2(100.0 - half + 3.0, -3.0, half * 2.0 - 6.0, 5.0), 2.0), st["hi"])
	_outline(tab, OUTLINE, 2.4)
	var spacing := 14.0
	var x0 := 100.0 - spacing * float(n - 1) * 0.5
	for i in n:
		_star(Vector2(x0 + spacing * float(i), 4.0), 6.0)


# T3 小金冠：平涂金 + 左半亮面 + 底边暗带 + 深棕描边，中间红宝石，冠上三颗星。
func _crown(c: Vector2) -> void:
	var pts := PackedVector2Array([
		c + Vector2(-30, 10), c + Vector2(-34, -14), c + Vector2(-16, -2), c + Vector2(0, -24),
		c + Vector2(16, -2), c + Vector2(34, -14), c + Vector2(30, 10)])
	_fill(pts, GOLD)
	_fill(PackedVector2Array([c + Vector2(-30, 10), c + Vector2(-34, -14), c + Vector2(-16, -2), c + Vector2(0, -24), c + Vector2(0, 10)]), GOLD_HI)
	_fill(PackedVector2Array([c + Vector2(-30, 4), c + Vector2(30, 4), c + Vector2(30, 10), c + Vector2(-30, 10)]), GOLD_LO)
	_outline(pts, OUTLINE, 2.6)
	var g := c + Vector2(0, -6)
	var gem := PackedVector2Array([g + Vector2(0, -6), g + Vector2(5, 0), g + Vector2(0, 6), g + Vector2(-5, 0)])
	_fill(gem, Color("e2384f"))
	_fill(PackedVector2Array([g + Vector2(0, -6), g + Vector2(0, 0), g + Vector2(-5, 0)]), Color("ff8a98"))
	_outline(gem, OUTLINE, 1.6)
	for x in [-24.0, 24.0]:
		_star(c + Vector2(x, -5), 5.0)
	_star(c + Vector2(0, -26), 5.5)


# 五角星：亮黄平涂 + 左半亮面 + 深棕描边。
func _star(c: Vector2, r: float) -> void:
	var pts := PackedVector2Array()
	for i in 10:
		var ang := -PI * 0.5 + float(i) * PI / 5.0
		var rr := r if i % 2 == 0 else r * 0.46
		pts.append(c + Vector2(cos(ang), sin(ang)) * rr)
	_fill(pts, Color("ffcf3a"))
	var left := PackedVector2Array([c])
	for i in range(5, 11):
		left.append(pts[i % 10])
	_fill(left, Color("ffe98a"))
	_outline(pts, OUTLINE, 1.6)


# 圆章：深棕描边 + 等级亮色细圈 + 深色底。
func _disc(c: Vector2, r: float, fill: Color, ring: Color) -> void:
	draw_circle(c, r + 2.4, OUTLINE)
	draw_circle(c, r + 0.8, ring)
	draw_circle(c, r - 0.6, fill)


# 升星：12 点方向的绿色柔光 + 呼吸的大十字星 + 往上飘的小十字星（棋盘特效同款十字闪光），可冲出卡顶。
func _draw_star_up(t: float) -> void:
	var c := STAR_UP_CENTER
	var col := STAR_UP_COLOR
	var breath := (0.6 + 0.4 * sin(t * 3.0)) if animated else 0.85
	for i in 12:
		var k := float(i) / 11.0
		draw_circle(c, lerpf(70.0, 8.0, k) * (0.85 + 0.15 * breath), Color(col.r, col.g, col.b, (0.03 + 0.09 * k) * breath))
	_cross_star(c + Vector2(0, -8), 28.0 * (0.8 + 0.25 * breath), Color(1, 1, 1, 0.95), col, breath)
	if not animated:
		return
	for i in STAR_UP_SPARKS:
		var seed := float(i) * 2.399
		var period := 1.2 + fmod(seed * 0.7, 1.0)
		var u := fmod(t / period + fmod(seed, 1.0), 1.0)
		var spread := fmod(seed * 37.0, 110.0) - 55.0
		var x := c.x + spread * (0.2 + 0.8 * u) + sin(t * 2.4 + seed * 4.0) * 4.0
		var y := c.y + 6.0 - u * (95.0 + fmod(seed * 11.0, 40.0))
		var fade := sin(u * PI)
		var size_k := 5.0 + fmod(seed * 5.0, 6.0)
		_cross_star(Vector2(x, y), size_k * (0.7 + 0.3 * sin(t * 7.0 + seed * 5.0)), Color(1, 1, 1, 0.9 * fade), col, fade)


# 柔和十字星：四个细长尖角 + 中心亮点 + 外圈同色柔光。
func _cross_star(c: Vector2, r: float, core: Color, halo: Color, a: float) -> void:
	draw_circle(c, r * 0.55, Color(halo.r, halo.g, halo.b, 0.25 * a))
	var w := r * 0.16
	for d in [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)]:
		var n := Vector2(-d.y, d.x)
		draw_colored_polygon(PackedVector2Array([c + n * w, c + d * r, c - n * w]), Color(halo.r, halo.g, halo.b, 0.85 * a))
		draw_colored_polygon(PackedVector2Array([c + n * w * 0.5, c + d * r * 0.7, c - n * w * 0.5]), core)
	draw_circle(c, w * 1.2, core)


# 剑：斜放，剑身 + 剑尖 + 护手 + 柄 + 柄头。
func _draw_sword(c: Vector2, r: float) -> void:
	var d := Vector2(1, -1).normalized()     # 剑尖朝右上
	var n := Vector2(d.y, -d.x) * -1.0
	var tip := c + d * r
	var hilt := c - d * r * 0.35
	var w := r * 0.16
	draw_colored_polygon(PackedVector2Array([tip, hilt + n * w, hilt - n * w]), CREAM)
	draw_line(hilt + n * r * 0.42, hilt - n * r * 0.42, CREAM, maxf(1.4, r * 0.16), true)
	draw_line(hilt, c - d * r * 0.85, CREAM, maxf(1.2, r * 0.13), true)
	draw_circle(c - d * r * 0.92, r * 0.12, CREAM)


# 弓：弓身弧线 + 弦 + 一支箭。
func _draw_bow(c: Vector2, r: float) -> void:
	var w := maxf(1.3, r * 0.15)
	draw_arc(c + Vector2(-r * 0.35, 0.0), r, -PI * 0.42, PI * 0.42, 16, CREAM, w, true)
	var top := c + Vector2(-r * 0.35, 0.0) + Vector2(cos(-PI * 0.42), sin(-PI * 0.42)) * r
	var bot := c + Vector2(-r * 0.35, 0.0) + Vector2(cos(PI * 0.42), sin(PI * 0.42)) * r
	draw_line(top, bot, Color(CREAM.r, CREAM.g, CREAM.b, 0.75), maxf(1.0, w * 0.55), true)
	var a0 := c + Vector2(-r * 0.75, 0.0)
	var a1 := c + Vector2(r * 1.05, 0.0)
	draw_line(a0, a1, CREAM, maxf(1.0, w * 0.7), true)
	draw_colored_polygon(PackedVector2Array([a1 + Vector2(r * 0.12, 0.0), a1 - Vector2(r * 0.22, r * 0.2), a1 - Vector2(r * 0.22, -r * 0.2)]), CREAM)


func _fill(pts: PackedVector2Array, col: Color) -> void:
	draw_colored_polygon(pts, col)


func _outline(pts: PackedVector2Array, col: Color, width: float) -> void:
	var closed := pts.duplicate()
	closed.append(pts[0])
	draw_polyline(closed, col, width, true)
