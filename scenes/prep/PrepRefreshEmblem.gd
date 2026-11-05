extends Control
## 商店刷新按钮中间的图案（11.05）：空心金框 btn_refresh_blank.png 中间这一块用代码画。
##
## 按棋盘皮肤换图案，跟刷新特效（PrepSkin.refresh_fx）是同一套 kind：
##   fire  = 青草地（默认）火焰    frost = 冰雪 雪花
##   petal = 樱花 樱花             wisp  = 夜荧光 月牙 + 萤火
## 画法照 11.04 定的美术统一：低多边形切面 —— 每个形状沿中线劈两半，朝左上的那半亮、
## 另一半主色，每段按哈希浮动一点明暗；只留半透明同色深边，中线一道细亮棱。不画金属渐变。
##
## 皮肤晚到 / 换皮肤：PrepUI.reapply_prep_skin 会调 sync()。
## 点刷新：kick() 先往回缩一下再转一圈回弹（预备 + 过冲）。

const PrepSkin := preload("res://scenes/prep/PrepSkin.gd")
const LIGHT_DIR := Vector2(-0.6, -0.8)     # 光从左上来（屏幕坐标 y 向下）
const OUTLINE_ALPHA := 0.55
# 图案中心相对按钮中心的偏移（占半径比例）。价格已挪到框外，图案居中。
const CENTER_SHIFT := Vector2(0.0, 0.0)
const EMBLEM_RADIUS := 0.56                # 图案半径 / 按钮半边长

# 每种图案三色：[亮面, 主色, 暗面, 描边]
const PALETTES := {
	"fire": [Color("ffd45c"), Color("ff8a2a"), Color("d8461b"), Color("5a1806")],
	"fire_core": [Color("fff6c4"), Color("ffe066"), Color("ffb732"), Color("8a3a08")],
	"frost": [Color("ffffff"), Color("bfe6ff"), Color("6aaee0"), Color("1d4a78")],
	"petal": [Color("ffe4ec"), Color("f7a3c0"), Color("d0628a"), Color("6b1f3a")],
	"petal_core": [Color("fff4b8"), Color("ffd24d"), Color("e09a2a"), Color("6b1f3a")],
	"wisp": [Color("fff6c8"), Color("f5cf62"), Color("c08f30"), Color("4a3210")],
}

var kind := "fire"
var _t := 0.0
var _spin := 0.0                           # kick 时的额外转角（弧度）
var _pop := 1.0                            # kick 时的额外缩放
var _kick_tween: Tween = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	sync()


## 按当前皮肤选图案。
func sync() -> void:
	set_kind(PrepSkin.refresh_fx())


func set_kind(new_kind: String) -> void:
	kind = new_kind if new_kind in PrepSkin.REFRESH_FX_KINDS else "fire"
	queue_redraw()


## 点刷新时的反馈：往回拧 18°、缩一点（预备），再转满一圈带过冲落回。
func kick() -> void:
	if _kick_tween != null and _kick_tween.is_valid():
		_kick_tween.kill()
	_spin = 0.0
	_pop = 1.0
	_kick_tween = create_tween()
	_kick_tween.tween_method(_set_spin, 0.0, deg_to_rad(-18.0), 0.07) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_kick_tween.parallel().tween_method(_set_pop, 1.0, 0.86, 0.07)
	_kick_tween.tween_method(_set_spin, deg_to_rad(-18.0), TAU, 0.42) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_kick_tween.parallel().tween_method(_set_pop, 0.86, 1.0, 0.42) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_kick_tween.tween_callback(func(): _spin = 0.0)


func _set_spin(v: float) -> void:
	_spin = v


func _set_pop(v: float) -> void:
	_pop = v


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_t += delta
	queue_redraw()


func _draw() -> void:
	var half := minf(size.x, size.y) * 0.5
	if half <= 1.0:
		return
	var r := half * EMBLEM_RADIUS
	var center := size * 0.5 + CENTER_SHIFT * half
	# 呼吸：缩放 ±3%，0.5 Hz；各图案自己的待机动作在下面各自的函数里。
	var breathe := 1.0 + 0.03 * sin(_t * TAU * 0.5)
	var rot := _spin
	match kind:
		"frost":
			rot += _t * 0.35                            # 雪花慢慢自转
		"petal":
			rot += 0.10 * sin(_t * TAU * 0.35)          # 樱花左右轻摆
	draw_set_transform(center, rot, Vector2.ONE * breathe * _pop)
	match kind:
		"frost":
			_draw_snowflake(r)
		"petal":
			_draw_sakura(r)
		"wisp":
			_draw_wisp(r)
		_:
			_draw_flame(r)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# ───────────── 通用：沿一条弯曲中线画「劈两半」的切面叶片 ─────────────
#
# base → tip 是二次贝塞尔中线（ctrl 是控制点）；profile 是 [t, 半宽占 width 的比例] 序列，
# 最后一个点的 t 是中线终点（樱花瓣的缺口就是让终点缩回去、两侧还有宽度）。
func _leaf(base: Vector2, ctrl: Vector2, tip: Vector2, width: float, profile: Array,
		pal: Array, seed: int, ridge := true) -> void:
	var axis: Array[Vector2] = []
	var left: Array[Vector2] = []
	var right: Array[Vector2] = []
	for p in profile:
		var t := float(p[0])
		var w := float(p[1]) * width
		var a := _bez(base, ctrl, tip, t)
		var n := _bez_normal(base, ctrl, tip, t)
		axis.append(a)
		left.append(a + n * w)
		right.append(a - n * w)
	var mid_n := _bez_normal(base, ctrl, tip, 0.5)
	_half(axis, left, mid_n, pal, seed)
	_half(axis, right, -mid_n, pal, seed + 17)
	# 外轮廓：左边一路上去，右边一路下来。
	var outline := PackedVector2Array()
	for p2 in left:
		outline.append(p2)
	if left[left.size() - 1].distance_to(right[right.size() - 1]) > 0.5:
		outline.append(axis[axis.size() - 1])
	for i in range(right.size() - 1, -1, -1):
		outline.append(right[i])
	outline.append(left[0])
	var edge: Color = pal[3]
	draw_polyline(outline, Color(edge.r, edge.g, edge.b, OUTLINE_ALPHA), maxf(1.2, width * 0.12), true)
	if ridge and axis.size() >= 3:
		var hi: Color = pal[0]
		var ridge_pts := PackedVector2Array()
		for i in range(1, axis.size() - 1):
			ridge_pts.append(axis[i])
		if ridge_pts.size() >= 2:
			draw_polyline(ridge_pts, Color(hi.r, hi.g, hi.b, 0.75), maxf(1.0, width * 0.07), true)


# 半片：按段切成四边形，朝光的半片用亮面，背光的用主色 / 暗面，每段哈希浮动 ±7%。
func _half(axis: Array[Vector2], side: Array[Vector2], side_normal: Vector2, pal: Array, seed: int) -> void:
	var lit := side_normal.normalized().dot(LIGHT_DIR.normalized())
	var base_col: Color
	if lit > 0.25:
		base_col = pal[0]
	elif lit > -0.25:
		base_col = pal[1]
	else:
		base_col = pal[2]
	if lit > -0.25 and lit <= 0.25:
		base_col = (pal[1] as Color).lerp(pal[0] if lit > 0.0 else pal[2], absf(lit) * 2.0)
	for i in range(axis.size() - 1):
		var quad := [axis[i], axis[i + 1], side[i + 1], side[i]]
		var jitter := (_hash(seed * 31 + i) - 0.5) * 0.14
		var col := base_col.lightened(jitter) if jitter > 0.0 else base_col.darkened(-jitter)
		_poly(quad, col)


# ───────────── 四种图案 ─────────────

func _draw_flame(r: float) -> void:
	var pal: Array = PALETTES["fire"]
	var core: Array = PALETTES["fire_core"]
	# 三条火舌按相位摆（不是随机抖），中间那条最慢。
	var s1 := sin(_t * TAU * 0.9) * 0.10 * r
	var s2 := sin(_t * TAU * 1.1 + 1.7) * 0.10 * r
	var s3 := sin(_t * TAU * 0.7 + 3.1) * 0.08 * r
	var prof := [[0.0, 0.55], [0.18, 0.95], [0.42, 0.85], [0.68, 0.50], [0.88, 0.20], [1.0, 0.02]]
	# 两侧小火舌先画，底座压在它们根部上面，中间大火舌再盖住底座上沿 —— 拼起来是一整团火。
	_leaf(Vector2(-0.30 * r, 0.40 * r), Vector2(-0.72 * r, 0.10 * r), Vector2(-0.62 * r + s1, -0.48 * r),
		0.26 * r, prof, pal, 3)
	_leaf(Vector2(0.30 * r, 0.40 * r), Vector2(0.74 * r, 0.05 * r), Vector2(0.58 * r + s2, -0.60 * r),
		0.26 * r, prof, pal, 5)
	_flame_base(Vector2(0.0, 0.36 * r), 0.50 * r, pal)
	_leaf(Vector2(0.0, 0.62 * r), Vector2(-0.48 * r, -0.05 * r), Vector2(0.08 * r + s3, -1.0 * r),
		0.50 * r, prof, pal, 7)
	_leaf(Vector2(0.0, 0.70 * r), Vector2(-0.26 * r, 0.30 * r), Vector2(0.02 * r - s3 * 0.6, -0.30 * r),
		0.30 * r, prof, core, 11, false)


# 火焰圆底：下半圆按 6 块扇形切面，朝左下的亮、朝右下的暗；只描下沿。
func _flame_base(c: Vector2, rad: float, pal: Array) -> void:
	var segs := 6
	var arc := PackedVector2Array()
	for i in segs + 1:
		var a := lerpf(-0.15, PI + 0.15, float(i) / segs)
		arc.append(c + Vector2(cos(a), sin(a)) * rad)
	for i in segs:
		var mid := ((arc[i] + arc[i + 1]) * 0.5 - c).normalized()
		# 底座整体背光，左侧受光的一块用主色，其余压暗
		var col: Color = pal[1] if mid.x < -0.3 else pal[2]
		var jitter := (_hash(90 + i) - 0.5) * 0.12
		col = col.lightened(jitter) if jitter > 0.0 else col.darkened(-jitter)
		_poly([c, arc[i], arc[i + 1]], col)
	var edge: Color = pal[3]
	draw_polyline(arc, Color(edge.r, edge.g, edge.b, OUTLINE_ALPHA), maxf(1.2, rad * 0.06), true)


func _draw_snowflake(r: float) -> void:
	var pal: Array = PALETTES["frost"]
	var arm_prof := [[0.0, 0.35], [0.12, 0.9], [0.5, 0.7], [0.82, 0.55], [1.0, 0.02]]
	var twig_prof := [[0.0, 0.6], [0.45, 0.9], [1.0, 0.02]]
	for k in 6:
		var a := -PI * 0.5 + k * TAU / 6.0
		var d := Vector2(cos(a), sin(a))
		var n := Vector2(-d.y, d.x)
		var root := d * 0.16 * r
		var tip := d * 1.0 * r
		_leaf(root, (root + tip) * 0.5, tip, 0.12 * r, arm_prof, pal, 20 + k)
		# 两对侧枝：0.48 处长的、0.74 处短的，各朝外斜 50°
		for pair in [[0.48, 0.40], [0.74, 0.24]]:
			var at := d * float(pair[0]) * r
			var length := float(pair[1]) * r
			for sgn: float in [-1.0, 1.0]:
				var dir: Vector2 = (d * cos(deg_to_rad(50.0)) + n * sgn * sin(deg_to_rad(50.0))).normalized()
				var end: Vector2 = at + dir * length
				_leaf(at, (at + end) * 0.5, end, 0.085 * r, twig_prof, pal, 40 + k * 4 + int(sgn), false)
	# 中心六边形：按朝光分六块
	var hex_r := 0.24 * r
	for k in 6:
		var a0 := -PI * 0.5 + k * TAU / 6.0
		var a1 := a0 + TAU / 6.0
		var mid := Vector2(cos((a0 + a1) * 0.5), sin((a0 + a1) * 0.5))
		var lit := mid.dot(LIGHT_DIR.normalized())
		var col: Color = (pal[1] as Color).lerp(pal[0] if lit > 0.0 else pal[2], clampf(absf(lit), 0.0, 1.0))
		_poly([Vector2.ZERO, Vector2(cos(a0), sin(a0)) * hex_r, Vector2(cos(a1), sin(a1)) * hex_r], col)
	var ring := PackedVector2Array()
	for k in 7:
		var a := -PI * 0.5 + k * TAU / 6.0
		ring.append(Vector2(cos(a), sin(a)) * hex_r)
	var edge: Color = pal[3]
	draw_polyline(ring, Color(edge.r, edge.g, edge.b, OUTLINE_ALPHA), maxf(1.2, r * 0.035), true)


func _draw_sakura(r: float) -> void:
	var pal: Array = PALETTES["petal"]
	# 花瓣：根部窄、中段最宽、末端留一个 V 形缺口（终点 t=0.84，两侧在 0.98 还有宽度）
	var prof := [[0.0, 0.10], [0.22, 0.62], [0.52, 0.92], [0.80, 0.80], [0.98, 0.40], [0.84, 0.0]]
	for k in 5:
		var a := -PI * 0.5 + k * TAU / 5.0
		var d := Vector2(cos(a), sin(a))
		var root := d * 0.10 * r
		var tip := d * 1.0 * r
		_leaf(root, (root + tip) * 0.5, tip, 0.42 * r, prof, pal, 60 + k)
	# 花心：五瓣之间的深粉小星 + 五根花蕊
	var core: Array = PALETTES["petal_core"]
	var star := []
	for k in 10:
		var a := -PI * 0.5 + k * TAU / 10.0 + TAU / 10.0
		star.append(Vector2(cos(a), sin(a)) * (0.26 * r if k % 2 == 0 else 0.12 * r))
	_poly(star, pal[2])
	for k in 5:
		var a := -PI * 0.5 + k * TAU / 5.0 + TAU / 10.0
		var tip := Vector2(cos(a), sin(a)) * 0.34 * r
		var edge: Color = core[3]
		draw_line(Vector2.ZERO, tip, Color(edge.r, edge.g, edge.b, 0.65), maxf(1.0, r * 0.04), true)
		draw_circle(tip, 0.075 * r, core[1])
		draw_circle(tip + Vector2(-0.025, -0.025) * r, 0.035 * r, core[0])
	draw_circle(Vector2.ZERO, 0.09 * r, core[2])


func _draw_wisp(r: float) -> void:
	var pal: Array = PALETTES["wisp"]
	# 月牙：外圆减去往右上偏的内圆。按 12 段切面，每段看外沿法线朝不朝光。
	var c1 := Vector2(-0.12 * r, 0.04 * r)
	var r1 := 0.78 * r
	var c2 := c1 + Vector2(0.36 * r, -0.22 * r)
	var r2 := 0.66 * r
	var arc := _crescent_arc(c1, r1, c2, r2)
	if arc.size() >= 2:
		var segs := 12
		var outer: Array[Vector2] = []
		var inner: Array[Vector2] = []
		var mid: Array[Vector2] = []
		for i in segs + 1:
			var th := lerpf(arc[0], arc[1], float(i) / segs)
			var dir := Vector2(cos(th), sin(th))
			var po := c1 + dir * r1
			var din := _ray_circle_near(c1, dir, c2, r2)
			var pi_ := c1 + dir * clampf(din, 0.0, r1)
			outer.append(po)
			inner.append(pi_)
			mid.append((po + pi_) * 0.5)
		for i in segs:
			var th := lerpf(arc[0], arc[1], (i + 0.5) / segs)
			var dir := Vector2(cos(th), sin(th))
			var lit := dir.dot(LIGHT_DIR.normalized())
			var jitter := (_hash(80 + i) - 0.5) * 0.12
			# 外半段按朝光取亮 / 主 / 暗；内半段一律压一档
			var outer_col: Color = (pal[1] as Color).lerp(pal[0] if lit > 0.0 else pal[2], clampf(absf(lit) * 1.3, 0.0, 1.0))
			outer_col = outer_col.lightened(jitter) if jitter > 0.0 else outer_col.darkened(-jitter)
			var inner_col := outer_col.darkened(0.14)
			_poly([outer[i], outer[i + 1], mid[i + 1], mid[i]], outer_col)
			_poly([mid[i], mid[i + 1], inner[i + 1], inner[i]], inner_col)
		var hi: Color = pal[0]
		var ridge := PackedVector2Array()
		for i in range(2, segs - 1):
			ridge.append(mid[i])
		draw_polyline(ridge, Color(hi.r, hi.g, hi.b, 0.7), maxf(1.0, r * 0.035), true)
		var line := PackedVector2Array()
		for p in outer:
			line.append(p)
		for i in range(inner.size() - 1, -1, -1):
			line.append(inner[i])
		line.append(outer[0])
		var edge: Color = pal[3]
		draw_polyline(line, Color(edge.r, edge.g, edge.b, OUTLINE_ALPHA), maxf(1.2, r * 0.045), true)
	# 三颗萤火：在月牙的缺口里绕圈慢飘，按相位一亮一暗；最亮那一下出柔和十字星。
	var glow: Color = PrepSkin.FIREFLY_DEFAULT
	var orbs := [[Vector2(0.36, -0.30), 0.16, 0.0], [Vector2(0.58, 0.20), 0.11, 2.1], [Vector2(0.18, 0.40), 0.09, 4.2]]
	for o in orbs:
		var ph := float(o[2])
		var pos := (o[0] as Vector2) * r + Vector2(sin(_t * 1.3 + ph), cos(_t * 1.1 + ph)) * 0.06 * r
		var rad := float(o[1]) * r
		var pulse := 0.5 + 0.5 * sin(_t * TAU * 0.6 + ph)
		draw_circle(pos, rad * 2.2, Color(glow.r, glow.g, glow.b, 0.10 + 0.10 * pulse))
		draw_circle(pos, rad * 1.45, Color(glow.r, glow.g, glow.b, 0.22 + 0.15 * pulse))
		draw_circle(pos, rad, Color("fff3b0"))
		draw_circle(pos + Vector2(-0.3, -0.3) * rad, rad * 0.45, Color("fffdf0"))
		if pulse > 0.7:
			var k := (pulse - 0.7) / 0.3
			var arm := rad * (1.6 + 1.2 * k)
			var c := Color(1.0, 0.98, 0.85, 0.75 * k)
			draw_line(pos - Vector2(arm, 0), pos + Vector2(arm, 0), c, maxf(1.0, rad * 0.22), true)
			draw_line(pos - Vector2(0, arm), pos + Vector2(0, arm), c, maxf(1.0, rad * 0.22), true)


# ───────────── 几何小工具 ─────────────

func _bez(a: Vector2, c: Vector2, b: Vector2, t: float) -> Vector2:
	var u := 1.0 - t
	return a * u * u + c * 2.0 * u * t + b * t * t


func _bez_normal(a: Vector2, c: Vector2, b: Vector2, t: float) -> Vector2:
	var tan := (c - a) * 2.0 * (1.0 - t) + (b - c) * 2.0 * t
	if tan.length_squared() < 0.000001:
		tan = b - a
	tan = tan.normalized()
	return Vector2(-tan.y, tan.x)


# 外圆 c1 上不被内圆 c2 盖住的那段弧（起止角，弧度，按增大方向）。
func _crescent_arc(c1: Vector2, r1: float, c2: Vector2, r2: float) -> Array:
	var d := c1.distance_to(c2)
	if d <= 0.0001 or d >= r1 + r2 or d <= absf(r1 - r2):
		return []
	var a := (r1 * r1 - r2 * r2 + d * d) / (2.0 * d)
	var h := sqrt(maxf(0.0, r1 * r1 - a * a))
	var base_dir := (c2 - c1) / d
	var ang := base_dir.angle()
	var spread := atan2(h, a)
	# 盖住的是朝 c2 那一侧 [ang-spread, ang+spread]，剩下的是另一侧
	return [ang + spread, ang + TAU - spread]


# 从 c1 沿 dir 出发，到圆 (c2, r2) 的近交点距离；没交点就返回外圆半径以外（=不挖）。
func _ray_circle_near(origin: Vector2, dir: Vector2, c2: Vector2, r2: float) -> float:
	var oc := origin - c2
	var b := oc.dot(dir)
	var c := oc.length_squared() - r2 * r2
	var disc := b * b - c
	if disc < 0.0:
		return INF
	var s := sqrt(disc)
	var t1 := -b - s
	var t2 := -b + s
	# origin 在内圆外：取近交点；在内圆里：取出口
	return t1 if t1 > 0.0 else t2


func _poly(points: Array, col: Color) -> void:
	var out := PackedVector2Array()
	for p in points:
		var v := p as Vector2
		if out.is_empty() or out[out.size() - 1].distance_squared_to(v) > 0.01:
			out.append(v)
	if out.size() >= 3 and out[0].distance_squared_to(out[out.size() - 1]) <= 0.01:
		out.remove_at(out.size() - 1)
	if out.size() < 3:
		return
	draw_colored_polygon(out, col)


func _hash(i: int) -> float:
	var x := (i * 374761393 + 668265263) & 0x7fffffff
	x = ((x ^ (x >> 13)) * 1274126177) & 0x7fffffff
	return float(x & 0xffff) / 65535.0
