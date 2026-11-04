extends "res://scenes/prep/effects/creatures/PrepBoardCreature2D.gd"

# 宝藏联动「铁处女」在备战棋盘上的钢铁蝎子（11.04）。通用的游动 / 点燃 / 发光都在底座里。
#
# 依据：
#   · 生物 = 钢铁蝎子（Leno 11.04 选的；先前的「铁荆棘藤」被否：「这个造型不行，换掉」）；
#     联动效果是「我方棋子受击时，攻击者流血、防御 -50%」——带刺反伤，蝎子的尾刺正合这个意思；
#   · 配色与点缀取自 assets/ui/treasure_logos/铁处女.png：带金十字的银盾 + 紫色尖刺 →
#     钢色分节身体、头胸甲上印金十字、紫色尾刺、紫色柔光；
#   · 画法按 11.04 定的美术统一：低多边形切面明暗、淡边、柔光（底座 _draw_tongues_layered）。
#
# 动起来不僵（game-feel）：
#   · 四对腿按步态交替迈步（相邻腿错开半拍、左右反相），步频跟着走过的距离走 —— 跑起来是「蹿」；
#   · 钳子平时慢慢开合，尾巴轻轻摇，转弯时身体和尾巴往弯外甩（跟随）；
#   · 蓄力（gather）：钳子张大、尾巴往后绷紧（预备）；冲到棋子时尾刺往前猛扎一下再弹回（跟随）；
#   · 掠过棋子（中档）：尾刺扎下的同时，棋子四周从地里刺出一圈紫铁刺合拢（铁处女），中间闪一下银盾。

const THORN_PAL := {
	"edge": Color(0.16, 0.04, 0.26), "main": Color(0.54, 0.20, 0.86),
	"hot": Color(0.80, 0.60, 1.0), "white": Color(0.97, 0.92, 1.0), "halo": Color(0.62, 0.35, 0.95),
}
const C_GOLD := Color(1.0, 0.80, 0.30)
const C_GOLD_HI := Color(1.0, 0.95, 0.70)
const STRIKE_SEC := 0.38
const TAIL_SEGS := 6

var _walk := 0.0            # 走过的距离折成的步态相位
var _strike_t := 9.0        # 尾刺扎出去的计时（> STRIKE_SEC 表示没在扎）
var _tail_tongues: Array[Dictionary] = []
var _sting_tongues: Array[Dictionary] = []
var _cross_at := Vector2.ZERO
var _cross_size := 0.0


func _init() -> void:
	creature_name = "PrepScorpion"
	# 钢色压暗一档：真棋盘上贴地提亮会把浅灰冲成白，像纸不像铁
	col_edge = Color(0.05, 0.05, 0.09)      # 钢：暗
	col_main = Color(0.38, 0.41, 0.50)      # 钢
	col_hot = Color(0.68, 0.72, 0.82)       # 钢：亮
	col_white = Color(1.0, 1.0, 1.0)
	col_halo = Color(0.60, 0.35, 0.95)      # logo 的紫
	col_thread = C_GOLD
	cruise_speed = 0.75
	turn_rate = 1.8
	flap_hz = 0.6
	body_scale = 0.78


func _process(delta: float) -> void:
	super._process(delta)
	var d := minf(delta, 0.05)
	_walk += _vel.length() * d / maxf(cell_px * body_scale * 0.22, 1.0)
	_strike_t += d


func _ignite(index: int, at: Vector2) -> void:
	_strike_t = 0.0
	super._ignite(index, at)


func _build_shape(s: float) -> void:
	_tail_tongues.clear()
	_sting_tongues.clear()
	var fwd := Vector2.RIGHT
	var gather := maxf(0.0, _fold)
	var strike := sin(PI * clampf(_strike_t / STRIKE_SEC, 0.0, 1.0)) if _strike_t < STRIKE_SEC else 0.0
	var grow := lerpf(0.3, 1.0, _unfold)
	# 1) 腿：四对，按步态交替迈步（画在最下面）
	for side: float in [-1.0, 1.0]:
		for i in 4:
			var root := Vector2(s * (0.24 - 0.13 * float(i)), side * s * 0.13)
			var phase := _walk * PI + float(i) * PI * 0.5 + (0.0 if side > 0.0 else PI)
			var swing := sin(phase) * 0.32
			var base_ang := lerpf(0.55, 2.35, float(i) / 3.0)        # 前腿朝前外、后腿朝后外
			var dir := Vector2(cos(base_ang + swing), side * sin(base_ang + swing))
			_add_tongue(_spine(_w(root), _wd(dir), s * 0.36 * grow, -side * 0.6, float(i) + side), s * 0.07, false)
	# 2) 钳子：臂 + 两指，平时慢慢开合，蓄力时张大
	var open := lerpf(0.18 + 0.12 * sin(_t * 2.1), 0.65, gather)
	for side: float in [-1.0, 1.0]:
		var shoulder := Vector2(s * 0.40, side * s * 0.13)
		var arm_dir := Vector2(cos(0.55), side * sin(0.55))
		_add_tongue(_spine(_w(shoulder), _wd(arm_dir), s * 0.30 * grow, -side * 0.5, 4.0 + side), s * 0.13, false)
		var wrist := shoulder + arm_dir.rotated(-side * 0.25) * s * 0.30 * grow
		for finger: float in [-1.0, 1.0]:
			var fd := Vector2(1.0, 0.0).rotated(side * 0.15 + finger * open)
			_add_tongue(_spine(_w(wrist), _wd(fd), s * 0.27 * grow, -finger * 0.6, 5.0 + finger), s * 0.15, true)
	# 3) 身体：四节腹甲（后面的先画）+ 头胸甲；转弯时往弯外甩
	for j in range(3, -1, -1):
		var x := s * (0.02 - 0.15 * float(j))
		var y := -_bank * s * 0.06 * float(j)
		_add_tongue(_spine(_w(Vector2(x, y)), _wd(-fwd.rotated(_bank * 0.15 * float(j))), s * 0.24, 0.0, float(j)), s * (0.40 - 0.05 * float(j)), true)
	_add_tongue(_spine(_w(Vector2(s * 0.46, 0)), _wd(-fwd), s * 0.44, 0.0, 9.0), s * 0.44, true)
	_cross_at = _w(Vector2(s * 0.24, 0))
	_cross_size = s * 0.16
	# 4) 尾巴：从腹尾往后伸，再卷过背朝前；蓄力时往后绷紧、扎出时整条往前甩直
	var curl_total := lerpf(2.7 + 0.15 * sin(_t * 1.6), 3.3, gather)
	curl_total = lerpf(curl_total, PI * 1.02, strike)
	var seg_len := s * 0.17 * (1.0 + 0.55 * strike) * grow
	var p := Vector2(-s * 0.52, -_bank * s * 0.22)
	var ang := PI + _bank * 0.35
	var side_curl := 1.0                                  # 往右侧卷
	var pts: Array[Vector2] = [_w(p)]
	for i in TAIL_SEGS:
		ang += side_curl * curl_total / float(TAIL_SEGS) * -1.0
		p += Vector2.from_angle(ang) * seg_len
		pts.append(_w(p))
	for i in TAIL_SEGS:
		var a := pts[i]
		var b := pts[i + 1]
		var w := s * lerpf(0.22, 0.15, float(i) / float(TAIL_SEGS - 1))
		_tail_tongues.append({"spine": _spine(a, (b - a).normalized(), a.distance_to(b) * 1.25, 0.0, float(i) * 1.3), "width": w, "highlight": true})
	# 5) 尾刺：一个鼓包 + 一根往前弯钩的紫刺
	var tip := pts[TAIL_SEGS]
	var tip_dir := (pts[TAIL_SEGS] - pts[TAIL_SEGS - 1]).normalized()
	_sting_tongues.append({"spine": _spine(tip - tip_dir * s * 0.04, tip_dir, s * 0.20, 0.0, 11.0), "width": s * 0.20, "highlight": true})
	_sting_tongues.append({"spine": _spine(tip + tip_dir * s * 0.12, tip_dir, s * 0.24 * (1.0 + 0.4 * strike), -0.9, 12.0), "width": s * 0.08, "highlight": false})


func _draw() -> void:
	if _scale <= 0.001 or _tongues.is_empty():
		return
	var s := cell_px * _scale * body_scale
	_soft_glow(self, _pos, s * 1.5, Color(col_halo, 0.24 * _strength))
	var pad := cell_px * 0.03 * _scale * body_scale
	_draw_tongues_layered(self, _tongues, pad)
	_draw_cross(self, _cross_at, _heading, _cross_size, 1.0)
	_draw_tongues_layered(self, _tail_tongues, pad)
	_with_palette(THORN_PAL, func() -> void: _draw_tongues_layered(self, _sting_tongues, pad))


# 头胸甲上的金十字（logo 银盾上的那个）
func _draw_cross(layer: CanvasItem, at: Vector2, angle: float, size: float, alpha: float) -> void:
	var a := alpha * _strength
	var w := maxf(1.5, size * 0.28)
	var along := Vector2.from_angle(angle)
	var across := along.orthogonal()
	layer.draw_line(at - along * size, at + along * size * 1.1, Color(C_GOLD, a), w, true)
	layer.draw_line(at + along * size * 0.35 - across * size * 0.6, at + along * size * 0.35 + across * size * 0.6, Color(C_GOLD, a), w, true)
	layer.draw_line(at - along * size * 0.6, at + along * size * 0.9, Color(C_GOLD_HI, a), maxf(1.0, w * 0.35), true)


# 临时换一套配色画（紫刺用 logo 的紫，身体用钢）
func _with_palette(pal: Dictionary, fn: Callable) -> void:
	var saved := [col_edge, col_main, col_hot, col_white, col_halo]
	col_edge = pal["edge"]
	col_main = pal["main"]
	col_hot = pal["hot"]
	col_white = pal["white"]
	col_halo = pal["halo"]
	fn.call()
	col_edge = saved[0]
	col_main = saved[1]
	col_hot = saved[2]
	col_white = saved[3]
	col_halo = saved[4]


# 带金十字的小银盾（logo 主体）：左右两半分亮暗（切面），金十字，淡边。点燃时在棋子中心闪一下。
func _draw_shield(layer: CanvasItem, at: Vector2, size: float, alpha: float) -> void:
	var a := alpha * _strength
	var pts := PackedVector2Array([
		Vector2(-size * 0.42, -size * 0.50), Vector2(size * 0.42, -size * 0.50),
		Vector2(size * 0.40, size * 0.05), Vector2(0, size * 0.58), Vector2(-size * 0.40, size * 0.05)])
	layer.draw_set_transform(at, 0.0, Vector2.ONE)
	var lit := col_hot.lerp(col_white, 0.3)
	var shade := col_main.darkened(0.25)
	layer.draw_colored_polygon(PackedVector2Array([pts[0], Vector2(0, -size * 0.50), pts[3], pts[4]]), Color(lit, a))
	layer.draw_colored_polygon(PackedVector2Array([Vector2(0, -size * 0.50), pts[1], pts[2], pts[3]]), Color(shade, a))
	var outline := pts.duplicate()
	outline.append(pts[0])
	layer.draw_polyline(outline, Color(col_edge, 0.5 * a), 1.2, true)
	layer.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_cross(layer, at + Vector2(0, -size * 0.02), PI * 0.5, size * 0.30, alpha)


func _draw_extra(_s: float, _beat: float) -> void:
	pass


# 掠过棋子 / 登场：棋子四周从地里猛地刺出一圈紫铁刺并合拢（overshoot），中心银盾闪一下，然后刺缩回地里。
func _draw_ignite(f: Dictionary) -> void:
	var age := float(f["age"])
	var k := age / float(f["life"])
	var size := float(f["size"]) * cell_px
	var at: Vector2 = f["pos"]
	var up := _ease_out_back(clampf(age / 0.2, 0.0, 1.0)) * (1.0 - _ease_in(clampf((k - 0.55) / 0.45, 0.0, 1.0)))
	_soft_glow(_fx_layer, at, size * 0.6, Color(THORN_PAL["halo"], 0.35 * up * _strength))
	var count := 12 if bool(f["rebirth"]) else 9
	var spikes: Array[Dictionary] = []
	for i in count:
		var ang := TAU * float(i) / float(count) + float(f["seed"])
		var outward := Vector2.from_angle(ang)
		var root := at + outward * size * 0.40
		var dir := (-outward).rotated(0.35 * (1.0 if i % 2 == 0 else -1.0))
		var length := size * 0.32 * up * (0.85 + 0.15 * sin(float(i) * 2.3))
		if length < 2.0:
			continue
		spikes.append({"spine": _spine(root, dir, length, 0.0, float(i)), "width": size * 0.10, "highlight": true})
	_with_palette(THORN_PAL, func() -> void: _draw_tongues_layered(_fx_layer, spikes, cell_px * 0.02))
	var flash := _ease_out_back(clampf((age - 0.12) / 0.25, 0.0, 1.0)) * (1.0 - smoothstep(0.5, 1.0, k))
	if flash > 0.02:
		_draw_shield(_fx_layer, at, size * 0.30 * flash, flash)
