extends "res://scenes/prep/effects/creatures/PrepBoardCreature2D.gd"

# 宝藏联动「瘫痪枷锁」在备战棋盘上的冰链（11.04）。通用的游动 / 点燃 / 发光都在底座里。
#
# 依据：
#   · 生物 = 冰链（Leno 11.04 认可的方案：像蛇一样游走、经过处结冰晶）；
#   · 配色与点缀取自 assets/ui/treasure_logos/瘫痪枷锁.png：人影被两条带尖头的冰链交叉捆住、雪花、蓝紫底 →
#     链环是冰蓝的分层发光（深海军蓝 → 冰蓝 → 亮冰蓝 → 近白），链头是冰晶箭头，外圈是 logo 底色的紫光；
#     游过处留下几朵慢慢化掉的雪花；掠过棋子时两条冰链交叉成 X 锁住它（logo 的画面）+ 一朵大雪花。
#   · 亮法和前几只同一套（共鸣光：分层 + 柔光晕）。
#
# 动起来不僵（game-feel）：
#   · 链子像蛇一样有一道波从头传到尾，但链环是硬的：摆幅比蛇小，每个链环沿脊线切向摆正；
#   · 链环一平一立交替（真锁链就是这样），每个平环按自己的相位闪一下高光，像冰在反光；
#   · 蓄力（gather）：链子收紧盘起、链环挤在一起；冲刺（dash）：像甩出去的链子一样绷直；
#   · 掠过棋子（中档）：两条冰链从外面滑进来（ease-out，过冲一点再回位）交叉成 X 锁住棋子 →
#     中间一朵大雪花弹出 → 冰晶碎片四散 → 链子化掉。

const SPINE_POINTS := 26
const LINKS := 11
const C_FROST := Color(0.82, 0.94, 1.0)

var _spine_pts: Array[Vector2] = []
var _frost: Array[Dictionary] = []        # 地上的雪花
var _frost_timer := 0.3


func _init() -> void:
	creature_name = "PrepIceChain"
	col_edge = Color(0.04, 0.08, 0.22)      # 深海军蓝
	col_main = Color(0.30, 0.62, 1.0)       # 冰蓝
	col_hot = Color(0.68, 0.89, 1.0)        # 亮冰蓝
	col_white = Color(0.95, 0.99, 1.0)      # 近白
	col_halo = Color(0.60, 0.42, 1.0)       # logo 底色的紫：蓝链在绿草地上靠它托出来
	col_thread = Color(0.75, 0.90, 1.0)
	cruise_speed = 0.75
	turn_rate = 1.5
	flap_hz = 0.9
	body_scale = 0.95


func _process(delta: float) -> void:
	super._process(delta)
	var d := minf(delta, 0.05)
	_frost_timer -= d
	if _frost_timer <= 0.0 and _scale > 0.5 and not _leaving and _spine_pts.size() == SPINE_POINTS:
		_frost_timer = _rng.randf_range(0.28, 0.5)
		var at := _spine_pts[_rng.randi_range(SPINE_POINTS / 2, SPINE_POINTS - 1)]
		_frost.append({"pos": at, "age": 0.0, "life": _rng.randf_range(1.8, 2.8),
			"r": _rng.randf_range(0.05, 0.09), "rot": _rng.randf() * TAU})
	for i in range(_frost.size() - 1, -1, -1):
		_frost[i]["age"] = float(_frost[i]["age"]) + d
		if float(_frost[i]["age"]) >= float(_frost[i]["life"]):
			_frost.remove_at(i)


func _build_shape(s: float) -> void:
	var coil := maxf(0.0, _fold)
	var whip := maxf(0.0, -_fold)
	# 链环是硬的：摆幅比蛇小；蓄力时盘紧（摆幅变大、长度变短），冲刺时甩直
	var amp := s * 0.12 * lerpf(0.6, 1.0, _flap_amount) * (1.0 + 1.1 * coil) * (1.0 - 0.8 * whip)
	var length := s * 2.0 * (1.0 - 0.30 * coil) * lerpf(0.4, 1.0, _unfold)
	_spine_pts.clear()
	for i in SPINE_POINTS:
		var k := float(i) / float(SPINE_POINTS - 1)
		var x := s * 0.6 - length * k
		var wave := sin(_flap_phase - k * TAU * 1.2) * amp * (0.2 + 0.8 * smoothstep(0.0, 0.3, k))
		var bend := -_bank * s * 0.32 * k * k
		_spine_pts.append(_w(Vector2(x, wave + bend)))
	# 冰链自己画（链环不是火舌形），这里放一个占位让底座知道「有东西要画」
	_add_tongue([_pos, _pos, _pos] as Array[Vector2], 0.0, false)


# --- 绘制 -------------------------------------------------------------------

func _draw() -> void:
	# 地上的雪花在最下面
	for fr in _frost:
		var k := float(fr["age"]) / float(fr["life"])
		var a := (1.0 - smoothstep(0.35, 1.0, k)) * 0.85 * _strength
		var grow := _ease_out(clampf(k / 0.2, 0.0, 1.0))
		_snowflake(self, fr["pos"], cell_px * float(fr["r"]) * grow, float(fr["rot"]), a)
	if _scale <= 0.001 or _spine_pts.size() < SPINE_POINTS:
		return
	var s := cell_px * _scale * body_scale
	# 整条链下面一层紫色柔光
	for i in range(0, SPINE_POINTS, 4):
		_soft_glow(self, _spine_pts[i], s * 0.55, Color(col_halo, 0.26 * _strength))
	_draw_chain(self, _spine_pts, s, 1.0, true)


# 沿一条折线均匀摆链环：一平（椭圆环）一立（胶囊短条）交替，从尾画到头；head = 是否画冰晶箭头。
func _draw_chain(layer: CanvasItem, pts: Array[Vector2], s: float, alpha: float, head: bool) -> void:
	var total := 0.0
	var seg_len: Array[float] = []
	for i in pts.size() - 1:
		var l := pts[i].distance_to(pts[i + 1])
		seg_len.append(l)
		total += l
	if total <= 1.0:
		return
	var link_len := total / float(LINKS)
	var a := alpha * _strength
	# 两遍：先画立环（在下），再画平环（压在上面），交叠处才像扣住
	var order: Array[int] = []
	for n in range(LINKS - 1, -1, -1):
		if n % 2 == 1:
			order.append(n)
	for n in range(LINKS - 1, -1, -1):
		if n % 2 == 0:
			order.append(n)
	for n in order:
		var at_len := (float(n) + 0.5) * link_len
		var pd := _sample(pts, seg_len, at_len)
		var p: Vector2 = pd[0]
		var ang: float = pd[1]
		layer.draw_set_transform(p, ang, Vector2.ONE)
		# 链环比间距长、首尾重叠才像环环相扣（第一版 0.62 倍间距，留了空隙，看着像一串珠子）
		var L := link_len * 1.35
		if n % 2 == 0:
			# 平环：沿链条方向拉长的椭圆环，暗边 → 冰蓝 → 亮冰蓝 → 白高光（上半弧按相位闪）
			var w := L * 0.30
			# 11.04 美术统一：粗深边改淡；环身沿圆周按朝光渐变（左上亮、右下暗），像切面反光
			_ellipse_ring(layer, L, w, s * 0.052, Color(col_edge, 0.45 * a))
			_ellipse_ring_lit(layer, L, w, s * 0.040, ang, a)
			var glint := 0.5 + 0.5 * sin(_t * 3.4 - float(n) * 0.8)
			layer.draw_arc(Vector2.ZERO, L * 0.5, PI * 1.15, PI * 1.75, 10, Color(col_white, (0.4 + 0.6 * glint) * a), maxf(1.0, s * 0.016), true)
		else:
			# 立环：侧面看是一根细长条，两头插进前后两个平环里
			var r := s * 0.045
			_capsule(layer, L * 1.03, r * 1.2, Color(col_edge, 0.45 * a))
			_capsule(layer, L * 1.0, r, Color(col_main.darkened(0.2), a))
			# 亮面：往光那侧偏一点的窄条
			var toward := LIGHT_TO_SOURCE.rotated(-ang)
			layer.draw_set_transform(p + (toward * r * 0.35).rotated(ang), ang, Vector2.ONE)
			_capsule(layer, L * 0.85, r * 0.5, Color(col_hot.lerp(col_white, 0.3), a))
		layer.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if head:
		var hd := _sample(pts, seg_len, 0.0)
		_arrowhead(layer, pts[0], hd[1], s * 0.30, a)


# 折线上按弧长取点：返回 [位置, 切线角]
func _sample(pts: Array[Vector2], seg_len: Array[float], at_len: float) -> Array:
	var acc := 0.0
	for i in seg_len.size():
		if acc + seg_len[i] >= at_len or i == seg_len.size() - 1:
			var t := clampf((at_len - acc) / maxf(seg_len[i], 0.0001), 0.0, 1.0)
			return [pts[i].lerp(pts[i + 1], t), (pts[i] - pts[i + 1]).angle()]
		acc += seg_len[i]
	return [pts[0], 0.0]


func _ellipse_ring(layer: CanvasItem, length: float, width: float, thick: float, color: Color) -> void:
	var ring := PackedVector2Array()
	for i in 21:
		var t := TAU * float(i) / 20.0
		ring.append(Vector2(cos(t) * length * 0.5, sin(t) * width))
	layer.draw_polyline(ring, color, maxf(1.0, thick), true)


# 环身按朝光渐变：每一小段的外法线朝左上越多越亮（局部坐标里要把光转回去）
func _ellipse_ring_lit(layer: CanvasItem, length: float, width: float, thick: float, ang: float, a: float) -> void:
	var light_local := LIGHT_TO_SOURCE.rotated(-ang)
	var lit := col_hot.lerp(col_white, 0.3)
	var shade := col_main.darkened(0.25)
	var prev := Vector2(length * 0.5, 0)
	for i in range(1, 21):
		var t := TAU * float(i) / 20.0
		var cur := Vector2(cos(t) * length * 0.5, sin(t) * width)
		var mid_t := TAU * (float(i) - 0.5) / 20.0
		var nrm := Vector2(cos(mid_t), sin(mid_t))
		var b := clampf(0.5 + 0.5 * nrm.dot(light_local), 0.0, 1.0)
		layer.draw_line(prev, cur, Color(shade.lerp(lit, b), a), maxf(1.0, thick), true)
		prev = cur


func _capsule(layer: CanvasItem, length: float, r: float, color: Color) -> void:
	var h := length * 0.5
	layer.draw_line(Vector2(-h + r, 0), Vector2(h - r, 0), color, r * 2.0, true)
	layer.draw_circle(Vector2(-h + r, 0), r, color)
	layer.draw_circle(Vector2(h - r, 0), r, color)


# 冰晶箭头（logo 里锁链的尖头）：菱形长尖，暗边 → 冰蓝 → 亮面
func _arrowhead(layer: CanvasItem, at: Vector2, angle: float, size: float, a: float) -> void:
	layer.draw_set_transform(at, angle, Vector2.ONE)
	var tip := PackedVector2Array([Vector2(size, 0), Vector2(size * 0.05, size * 0.30), Vector2(-size * 0.25, 0), Vector2(size * 0.05, -size * 0.30)])
	var out := PackedVector2Array()
	for p in tip:
		out.append(p * 1.22 + Vector2(-size * 0.05, 0))
	layer.draw_colored_polygon(out, Color(col_edge, 0.45 * a))
	layer.draw_colored_polygon(tip, Color(col_main, a))
	layer.draw_colored_polygon(PackedVector2Array([Vector2(size * 0.9, 0), Vector2(size * 0.05, -size * 0.24), Vector2(0, 0)]), Color(col_hot, a))
	layer.draw_line(Vector2(0, 0), Vector2(size * 0.8, 0), Color(col_white, 0.9 * a), maxf(1.0, size * 0.05), true)
	layer.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# 六瓣雪花：六根主枝，每根两对小枝
func _snowflake(layer: CanvasItem, at: Vector2, r: float, rot: float, a: float) -> void:
	if r <= 0.5 or a <= 0.01:
		return
	for i in 6:
		var d := Vector2.from_angle(rot + TAU * float(i) / 6.0)
		var n := d.orthogonal()
		layer.draw_line(at, at + d * r, Color(col_edge, 0.6 * a), maxf(1.5, r * 0.22), true)
		layer.draw_line(at, at + d * r, Color(C_FROST, a), maxf(1.0, r * 0.10), true)
		for b in [0.45, 0.72]:
			var root: Vector2 = at + d * r * float(b)
			for sgn in [-1.0, 1.0]:
				layer.draw_line(root, root + (d * 0.6 + n * float(sgn) * 0.6).normalized() * r * 0.28, Color(C_FROST, a), maxf(1.0, r * 0.08), true)
	layer.draw_circle(at, r * 0.14, Color(col_white, a))


func _draw_extra(_s: float, _beat: float) -> void:
	pass


# 掠过棋子 / 登场：两条冰链从外面滑进来交叉成 X 锁住棋子（logo 的画面），过冲一点再回位；
# 中间一朵大雪花弹出；冰晶碎片四散；最后整体化掉。
func _draw_ignite(f: Dictionary) -> void:
	var age := float(f["age"])
	var k := age / float(f["life"])
	var size := float(f["size"]) * cell_px
	var at: Vector2 = f["pos"]
	var fade := 1.0 - smoothstep(0.55, 1.0, k)
	var slide := _ease_out_back(clampf(age / 0.28, 0.0, 1.0))
	_soft_glow(_fx_layer, at, size * 0.55, Color(col_halo, 0.4 * fade * _strength))
	var s := cell_px * body_scale * 0.7
	for c in 2:
		var ang := PI * 0.25 + PI * 0.5 * float(c) + float(f["seed"]) * 0.15
		var dir := Vector2.from_angle(ang)
		var half := size * 0.42
		# 从外面滑进来：起点在外面，slide 到 1 时中点正好压在棋子上
		var offset := dir * size * 0.9 * (1.0 - slide)
		var line: Array[Vector2] = []
		for i in 6:
			var t := float(i) / 5.0
			line.append(at + offset + dir * lerpf(half, -half, t))
		_draw_chain(_fx_layer, line, s, fade, false)
	_snowflake(_fx_layer, at, size * 0.22 * _ease_out_back(clampf((age - 0.18) / 0.25, 0.0, 1.0)), float(f["seed"]), fade)
	var shards := 10 if bool(f["rebirth"]) else 7
	for i in shards:
		var ang := TAU * float(i) / float(shards) + float(f["seed"])
		var dist := size * lerpf(0.1, 0.6, _ease_out(clampf((age - 0.2) / 0.6, 0.0, 1.0)))
		if age < 0.2:
			continue
		_arrowhead(_fx_layer, at + Vector2.from_angle(ang) * dist, ang, size * 0.09, fade * _strength)
