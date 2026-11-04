extends "res://scenes/prep/effects/creatures/PrepBoardCreature2D.gd"

# 宝藏联动「压迫反击」在备战棋盘上的符文巨蟹（11.04）。通用的游动 / 点燃 / 发光都在底座里。
#
# 依据：
#   · 生物 = 符文巨蟹（Leno 11.04 选的；之前的「重甲犀牛」被否：「效果很差，再换」——
#     四足动物俯视只是一个圆团加几个凸起，像乌龟；螃蟹俯视轮廓和蝎子一样好认）；
#     联动效果是「我方棋子受击时，攻击者攻击 -25%」——把来犯者压下去，双钳往下一拍正合；
#   · 配色与点缀取自 assets/ui/treasure_logos/压迫反击.png：往上冲的亮红箭头 + 洋红符文法阵 →
#     暗红蟹壳，壳上刻洋红符文环 + 红箭头（随呼吸明暗），钳尖亮红，外圈洋红柔光；
#   · 画法按 11.04 定的美术统一：低多边形切面明暗、淡边、柔光。
#
# 动起来不僵（game-feel）：
#   · **横着走**：螃蟹的正面朝侧边（局部 +y），沿身体横向（局部 +x = 前进方向）蹿 —— 最有辨识度的动作；
#   · 八条腿交替划动，步频跟着走过的距离；身体随步伐轻颠；
#   · 钳子平时慢慢开合；蓄力（gather）时双钳高举、张到最大、身体往下一沉（预备）；
#   · 掠过棋子（中档）：双钳往下一拍（overshoot 再回弹），脚下亮起洋红符文法阵，红箭头往下压。

const ARROW_PAL := {
	"edge": Color(0.20, 0.02, 0.03), "main": Color(0.94, 0.18, 0.14),
	"hot": Color(1.0, 0.52, 0.42), "white": Color(1.0, 0.86, 0.80), "halo": Color(1.0, 0.25, 0.30),
}
const C_RUNE := Color(0.95, 0.30, 0.65)        # logo 法阵的洋红
const SLAM_SEC := 0.35

var _walk := 0.0
var _slam_t := 9.0
var _shell := {}                                # 本帧蟹壳：{c, ang, rx, ry}
var _claw_tongues: Array[Dictionary] = []
var _eyes: Array[Vector2] = []


func _init() -> void:
	creature_name = "PrepCrab"
	col_edge = Color(0.10, 0.02, 0.03)
	col_main = Color(0.55, 0.12, 0.12)      # 暗红壳
	col_hot = Color(0.86, 0.36, 0.28)
	col_white = Color(1.0, 0.78, 0.70)
	col_halo = Color(0.78, 0.20, 0.50)      # logo 法阵的洋红
	col_thread = C_RUNE
	cruise_speed = 0.8
	turn_rate = 1.7
	flap_hz = 0.8
	body_scale = 0.80                        # 0.62 时整只太小、钳子看不清


func _process(delta: float) -> void:
	super._process(delta)
	var d := minf(delta, 0.05)
	_walk += _vel.length() * d / maxf(cell_px * body_scale * 0.16, 1.0)
	_slam_t += d


func _ignite(index: int, at: Vector2) -> void:
	_slam_t = 0.0
	super._ignite(index, at)


func _build_shape(s: float) -> void:
	_claw_tongues.clear()
	_eyes.clear()
	var gather := maxf(0.0, _fold)
	var slam := sin(PI * clampf(_slam_t / SLAM_SEC, 0.0, 1.0)) if _slam_t < SLAM_SEC else 0.0
	var grow := lerpf(0.3, 1.0, _unfold)
	var bob := 0.04 * sin(_walk * PI * 2.0) * s
	var crouch := 1.0 - 0.10 * gather                         # 蓄力往下一沉
	var front := Vector2(0, 1)                                  # 螃蟹正面朝局部 +y（横着走）
	# 1) 腿：两侧（局部 ±x）各四条，交替划动；前进那侧伸、后面那侧收
	for side: float in [-1.0, 1.0]:
		for i in 4:
			var root := Vector2(side * s * 0.30, s * (0.12 - 0.11 * float(i)) + bob)
			var phase := _walk * PI + float(i) * PI * 0.5 + (0.0 if side > 0.0 else PI)
			var swing := sin(phase) * 0.35
			var ang := lerpf(-0.55, 0.55, float(i) / 3.0) + swing
			var dir := Vector2(side * cos(ang), -sin(ang) * 0.6 + 0.15).normalized()
			_add_tongue(_spine(_w(root), _wd(dir), s * 0.42 * grow, -side * 0.7, float(i) + side), s * 0.075, false)
	# 2) 蟹壳：宽扁（横向 rx 大）
	_shell = {"c": _w(Vector2(0, bob)), "ang": _heading, "rx": s * 0.46 * crouch, "ry": s * 0.32 * crouch}
	# 3) 眼柄：正面两只小凸起（不画瞳孔）
	for side: float in [-1.0, 1.0]:
		_eyes.append(_w(Vector2(side * s * 0.09, s * 0.33 + bob)))
	# 4) 钳子：从正面两角伸出；平时慢慢开合，蓄力高举张开，拍下时往前一砸
	var open := lerpf(0.20 + 0.15 * sin(_t * 2.3), 0.75, gather) * (1.0 - 0.8 * slam)
	var reach := (1.0 + 0.25 * gather + 0.35 * slam) * grow
	for side: float in [-1.0, 1.0]:
		var shoulder := Vector2(side * s * 0.30, s * 0.20 + bob)
		var arm_dir := Vector2(side * 0.55, 1.0).normalized().rotated(-side * 0.25 * gather)
		# 大钳子是螃蟹第一眼的特征：臂粗、钳大（第一版钳子太小，整只像蜘蛛）
		_claw_tongues.append({"spine": _spine(_w(shoulder), _wd(arm_dir), s * 0.32 * reach, side * 0.4, 4.0 + side), "width": s * 0.18, "highlight": false})
		var wrist := shoulder + arm_dir * s * 0.30 * reach
		var claw_dir := front.rotated(side * 0.25)
		# 大指：胖的弯钩；小指：细一点，开合
		_claw_tongues.append({"spine": _spine(_w(wrist), _wd(claw_dir.rotated(side * open * 0.5)), s * 0.46 * reach, -side * 0.75, 5.0 + side), "width": s * 0.36, "highlight": true})
		_claw_tongues.append({"spine": _spine(_w(wrist), _wd(claw_dir.rotated(-side * open)), s * 0.34 * reach, side * 0.6, 6.0 + side), "width": s * 0.18, "highlight": false})
	# 底座以「有没有形状」决定画不画；腿放进 _tongues 里了


func _draw() -> void:
	if _scale <= 0.001 or _tongues.is_empty() or _shell.is_empty():
		return
	var s := cell_px * _scale * body_scale
	_soft_glow(self, _pos, s * 1.4, Color(col_halo, 0.24 * _strength))
	var pad := cell_px * 0.03 * _scale * body_scale
	_draw_tongues_layered(self, _tongues, pad)                 # 腿
	_faceted_ellipse(self, _shell["c"], float(_shell["ang"]), float(_shell["rx"]), float(_shell["ry"]))
	_draw_shell_spikes(s)
	_draw_runes(s)
	for e in _eyes:
		draw_circle(e, s * 0.055, Color(col_edge, 0.5 * _strength))
		draw_circle(e, s * 0.045, Color(col_hot, _strength))
		draw_circle(e + Vector2(-1, -1) * s * 0.012, s * 0.018, Color(col_white, _strength))
	# 钳子：大指尖用亮红箭头配色
	_with_palette(ARROW_PAL, func() -> void: _draw_tongues_layered(self, _claw_tongues, pad))


# 蟹壳前缘一排短刺（朝正面）
func _draw_shell_spikes(s: float) -> void:
	var c: Vector2 = _shell["c"]
	var ang := float(_shell["ang"])
	var rx := float(_shell["rx"])
	var ry := float(_shell["ry"])
	var spikes: Array[Dictionary] = []
	for i in 5:
		var t := lerpf(0.35, PI - 0.35, float(i) / 4.0)       # 前半圈（局部 +y 那侧）
		var local := Vector2(cos(t) * rx, sin(t) * ry)
		var p := c + local.rotated(ang)
		var out := Vector2(cos(t) / rx, sin(t) / ry).normalized().rotated(ang)
		spikes.append({"spine": _spine(p - out * s * 0.03, out, s * 0.12, 0.0, float(i)), "width": s * 0.09, "highlight": false})
	_draw_tongues_layered(self, spikes, 0.0)


# 壳上的洋红符文环 + 三支红箭头，随呼吸明暗（logo 的法阵）
func _draw_runes(s: float) -> void:
	var c: Vector2 = _shell["c"]
	var ang := float(_shell["ang"])
	var pulse := 0.55 + 0.45 * sin(_t * 2.4)
	var a := _strength
	var r := s * 0.20
	draw_set_transform(c, ang, Vector2(1.0, 0.75))
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 32, Color(C_RUNE, (0.45 + 0.4 * pulse) * a), maxf(1.0, s * 0.025), true)
	for i in 6:
		var t := TAU * float(i) / 6.0 + _t * 0.5
		var d := Vector2.from_angle(t)
		draw_line(d * r * 0.82, d * r * 1.12, Color(1.0, 0.78, 0.90, 0.8 * pulse * a), maxf(1.0, s * 0.02), true)
	# 三支朝正面（局部 +y）的小红箭头
	for i in 3:
		var x := (float(i) - 1.0) * r * 0.55
		var tip := Vector2(x, r * 0.45)
		var pts := PackedVector2Array([tip + Vector2(-r * 0.18, -r * 0.30), tip, tip + Vector2(r * 0.18, -r * 0.30)])
		draw_polyline(pts, Color(ARROW_PAL["main"], (0.6 + 0.4 * pulse) * a), maxf(1.0, s * 0.03), true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# 切面椭圆：一圈顶点，从偏向光源的一点扇形连三角；每个三角按外法线朝光 + 哈希浮动取色。
func _faceted_ellipse(layer: CanvasItem, c: Vector2, ang: float, rx: float, ry: float) -> void:
	if rx <= 0.5 or ry <= 0.5:
		return
	var n := 16
	var ring: Array[Vector2] = []
	for i in n:
		var t := TAU * float(i) / float(n)
		ring.append(c + Vector2(cos(t) * rx, sin(t) * ry).rotated(ang))
	var apex := c + LIGHT_TO_SOURCE * minf(rx, ry) * 0.25
	var lit := col_hot.lerp(col_white, 0.2)
	var shade := col_main.darkened(0.25)
	var a := _strength
	var edge := PackedVector2Array()
	for p in ring:
		edge.append(c + (p - c) * 1.04)
	edge.append(edge[0])
	layer.draw_polyline(edge, Color(col_edge, 0.5 * a), 1.4, true)
	for i in n:
		var p0 := ring[i]
		var p1 := ring[(i + 1) % n]
		var nrm := ((p0 + p1) * 0.5 - c).normalized()
		var jit := (fposmod(sin(float(i * 31) + 3.7) * 43758.5453, 1.0) - 0.5) * 0.18
		var b := clampf(0.5 + 0.5 * nrm.dot(LIGHT_TO_SOURCE) + jit, 0.0, 1.0)
		layer.draw_colored_polygon(PackedVector2Array([apex, p0, p1]), Color(shade.lerp(lit, b), a))


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


func _draw_extra(_s: float, _beat: float) -> void:
	pass


# 掠过棋子 / 登场：洋红符文法阵 overshoot 弹开 + 一道地面震波外扩 + 五道亮红箭头从四周往棋子上一压。
func _draw_ignite(f: Dictionary) -> void:
	var age := float(f["age"])
	var k := age / float(f["life"])
	var size := float(f["size"]) * cell_px
	var at: Vector2 = f["pos"]
	var a := (1.0 - smoothstep(0.55, 1.0, k)) * _strength
	var pop := _ease_out_back(clampf(age / 0.22, 0.0, 1.0))
	_soft_glow(_fx_layer, at, size * 0.6 * pop, Color(C_RUNE, 0.30 * a))
	var r := size * 0.40 * pop
	var spin := age * 0.8 + float(f["seed"])
	_fx_layer.draw_arc(at, r, 0.0, TAU, 48, Color(C_RUNE, 0.85 * a), maxf(1.5, size * 0.025), true)
	_fx_layer.draw_arc(at, r * 0.72, 0.0, TAU, 40, Color(C_RUNE, 0.6 * a), maxf(1.0, size * 0.015), true)
	for i in 12:
		var ang := spin + TAU * float(i) / 12.0
		var d := Vector2.from_angle(ang)
		var tick := 0.10 if i % 3 == 0 else 0.05
		_fx_layer.draw_line(at + d * r * 0.76, at + d * r * (0.86 + tick), Color(1.0, 0.75, 0.88, 0.8 * a), maxf(1.0, size * 0.014), true)
	var wave_k := clampf(age / 0.5, 0.0, 1.0)
	if wave_k < 1.0:
		_fx_layer.draw_arc(at, size * lerpf(0.2, 0.75, _ease_out(wave_k)), 0.0, TAU, 48,
			Color(col_white, 0.6 * (1.0 - wave_k) * _strength), maxf(1.0, size * 0.04 * (1.0 - wave_k)), true)
	var press := _ease_in(clampf((age - 0.05) / 0.25, 0.0, 1.0))
	var arrows: Array[Dictionary] = []
	for i in 5:
		var ang := TAU * float(i) / 5.0 + float(f["seed"]) * 0.5 - PI * 0.5
		var out := Vector2.from_angle(ang)
		var root := at + out * size * lerpf(0.95, 0.42, press)
		arrows.append({"spine": _spine(root, -out, size * 0.26, 0.0, float(i)), "width": size * 0.16, "highlight": true})
	if a > 0.02:
		_with_palette(ARROW_PAL, func() -> void: _draw_tongues_layered(_fx_layer, arrows, cell_px * 0.02))
