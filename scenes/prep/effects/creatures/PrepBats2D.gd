extends "res://scenes/prep/effects/creatures/PrepBoardCreature2D.gd"

# 宝藏联动「血之契约」在备战棋盘上的血蝠群（11.04）。通用的游动 / 点燃 / 发光都在底座里。
#
# 依据：
#   · 生物 = 三只血蝠（Leno 11.04 认可的方案）；
#   · 配色与点缀取自 assets/ui/treasure_logos/血之契约.png：一颗大血滴 + 一圈火焰法阵（五芒星）+ 往下滴血 →
#     蝙蝠是血红的分层发光（近黑暗红 → 血红 → 亮红 → 暖白），外圈是 logo 里的红橙火光；
#     飞过时滴血、在棋盘上留下渐淡的血迹；掠过棋子时脚下亮起火焰法阵 + 五芒星 + 中心血花。
#   · 亮法和前几只同一套（共鸣光：四层 + 柔光晕）。
#
# 动起来不僵（game-feel）：
#   · 一群，不是三个复制品：领头那只走底座的转向追目标，另外两只沿领头**飞过的路线**稍晚跟上、
#     左右错开、个头小一点，扇翅相位各不相同；
#   · 扇翅快（蝙蝠），翼展大幅伸缩、指骨张合；一阵扇翅接一小段滑翔；
#   · 蓄力（gather）：两只跟随的收拢到领头身边（像盘旋聚拢）；冲刺（dash）：排成一列俯冲、翅膀收紧；
#   · 掠过棋子（中档）：火焰法阵 + 五芒星线条亮起（overshoot 弹出）、中心血滴溅出一圈血花。

const HISTORY_SEC := 1.2
# 第一版 delay 0.28 / 0.50、侧距 0.42 格：三只叠成一团。拉开。
const FOLLOWERS := [
	{"delay": 0.45, "side": -1.0, "scale": 0.80, "phase": 1.9},
	{"delay": 0.85, "side": 1.0, "scale": 0.70, "phase": 3.7},
]
const C_STAIN := Color(0.30, 0.01, 0.02)

var _history: Array[Dictionary] = []      # 领头最近的位置 / 朝向（新的在前）
var _stains: Array[Dictionary] = []       # 棋盘上的血迹
var _drip_timer := 0.4


func _init() -> void:
	creature_name = "PrepBats"
	col_edge = Color(0.10, 0.01, 0.02)      # 近黑暗红
	col_main = Color(0.64, 0.03, 0.06)      # 血红
	col_hot = Color(0.96, 0.20, 0.12)       # 亮红
	col_white = Color(1.0, 0.80, 0.66)      # 暖白
	col_halo = Color(1.0, 0.32, 0.10)       # logo 里法阵的红橙火光
	col_thread = Color(1.0, 0.45, 0.25)
	cruise_speed = 1.0
	turn_rate = 2.3                          # 蝙蝠转得急
	flap_hz = 2.6                            # 扇得快
	body_scale = 0.46                        # 预览 0.55 太小挤成一团；真棋盘 0.68 三只铺满半个棋盘 → 0.46


func _process(delta: float) -> void:
	super._process(delta)
	var d := minf(delta, 0.05)
	_history.push_front({"pos": _pos, "heading": _heading, "t": _t})
	while _history.size() > 2 and _t - float(_history[_history.size() - 1]["t"]) > HISTORY_SEC:
		_history.pop_back()
	# 滴血：飞的时候每隔一小会儿从某只蝙蝠身上滴一滴，落地成一小滩，慢慢淡掉
	_drip_timer -= d
	if _drip_timer <= 0.0 and _scale > 0.5 and not _leaving:
		_drip_timer = _rng.randf_range(0.25, 0.55)
		var who := _rng.randi_range(0, FOLLOWERS.size())
		var at := _pos if who == 0 else _follower_pose(FOLLOWERS[who - 1])["pos"] as Vector2
		_stains.append({"pos": at + Vector2(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * cell_px * 0.06,
			"age": 0.0, "life": _rng.randf_range(2.0, 3.2), "r": _rng.randf_range(0.035, 0.06), "rot": _rng.randf() * TAU})
	for i in range(_stains.size() - 1, -1, -1):
		_stains[i]["age"] = float(_stains[i]["age"]) + d
		if float(_stains[i]["age"]) >= float(_stains[i]["life"]):
			_stains.remove_at(i)


# 跟随者此刻的位置 / 朝向：取领头 delay 秒前的位置，往侧面错开；蓄力时收拢、冲刺时排成一列。
func _follower_pose(f: Dictionary) -> Dictionary:
	var delay := float(f["delay"]) * lerpf(1.0, 0.55, maxf(0.0, -_fold))
	var target_t := _t - delay
	var p := _pos
	var h := _heading
	for e in _history:
		if float(e["t"]) <= target_t:
			p = e["pos"]
			h = float(e["heading"])
			break
	var spread := cell_px * 0.70 * lerpf(1.0, 0.35, maxf(0.0, _fold)) * lerpf(1.0, 0.15, maxf(0.0, -_fold))
	var side := Vector2.from_angle(h).orthogonal() * float(f["side"])
	# 侧向再加一点自己的漂移，免得像焊在队形上
	var drift := sin(_t * 1.7 + float(f["phase"])) * cell_px * 0.10
	return {"pos": p + side * (spread + drift), "heading": h}


var _bat_poses: Array[Dictionary] = []     # 本帧要画的蝙蝠：{pos, heading, s, phase}


# 蝙蝠不用火舌拼（第一、二版用火舌：尖头一簇簇，像红叶子 / 尖刺，认不出是蝙蝠），
# 每只按骨架直接画成整块多边形，见 _bat_wing()。这里只记下本帧每只的位置。
func _build_shape(s: float) -> void:
	_bat_poses.clear()
	for f in FOLLOWERS:
		var pose := _follower_pose(f)
		_bat_poses.append({"pos": pose["pos"], "heading": float(pose["heading"]), "s": s * float(f["scale"]), "phase": float(f["phase"])})
	_bat_poses.append({"pos": _pos, "heading": _heading, "s": s, "phase": 0.0})
	# 底座的 _draw 以「有没有形状」判断要不要画；蝙蝠自己画，这里放一个占位，_draw 里不用它
	_add_tongue([_pos, _pos, _pos] as Array[Vector2], 0.0, false)


# 一侧蝙蝠翼（局部坐标：x 朝前，side = +1 右 / -1 左）。返回 {poly, bones}。
# 骨架：肩 → 臂骨到腕（前缘平直）→ 三根指骨从腕张开；指尖之间的膜往里凹成弧（扇贝状后缘）。
func _bat_wing(s: float, side: float, span: float, sweep: float) -> Dictionary:
	var shoulder := Vector2(s * 0.06, side * s * 0.10)
	var wrist := shoulder + Vector2(s * (0.12 - sweep * 0.25), side * s * 0.62 * span)
	var tips: Array[Vector2] = []
	for i in 3:
		var k := float(i) / 2.0
		var ang := lerpf(0.75, 2.05, k) + sweep * 0.7
		var length := s * lerpf(0.70, 0.62, k) * lerpf(0.55, 1.0, span)
		tips.append(wrist + Vector2(cos(ang), side * sin(ang)) * length)
	var hind := Vector2(-s * 0.40, side * s * 0.12)
	var poly := PackedVector2Array()
	poly.append(shoulder)
	poly.append((shoulder + wrist) * 0.5 + Vector2(s * 0.05, 0))
	poly.append(wrist)
	poly.append(tips[0])
	var chain: Array[Vector2] = [tips[0], tips[1], tips[2], hind]
	for j in 3:
		var a := chain[j]
		var b := chain[j + 1]
		var ctrl := (a + b) * 0.5 + (wrist - (a + b) * 0.5) * 0.42   # 往腕部凹
		for q in range(1, 6):
			var t := float(q) / 6.0
			poly.append(a.lerp(ctrl, t).lerp(ctrl.lerp(b, t), t))
		poly.append(b)
	return {"poly": poly, "bones": [[shoulder, wrist], [wrist, tips[0]], [wrist, tips[1]], [wrist, tips[2]]]}


func _draw_bat(pose: Dictionary) -> void:
	var s := float(pose["s"])
	var ph := _flap_phase + float(pose["phase"])
	var flap := sin(ph)
	var span := lerpf(0.94 + 0.04 * sin(_t * 6.0 + float(pose["phase"])), 0.40 + 0.60 * (flap * 0.5 + 0.5), _flap_amount)
	span *= lerpf(0.2, 1.0, _unfold) * (1.0 + 0.5 * minf(0.0, _fold))
	var sweep := 0.30 * cos(ph) * _flap_amount + 0.5 * maxf(0.0, -_fold)
	var a := _strength
	draw_set_transform(pose["pos"], float(pose["heading"]), Vector2.ONE)
	_soft_glow(self, Vector2.ZERO, s * 1.3, Color(col_halo, 0.30 * a))
	for side: float in [-1.0, 1.0]:
		var wing := _bat_wing(s, side, span, sweep)
		var poly: PackedVector2Array = wing["poly"]
		if Geometry2D.triangulate_polygon(poly).is_empty():
			continue
		# 11.04 美术统一：膜翼按三角面分明暗（低多边形切面，和场景一致），不再是黑粗边 + 平涂。
		# 每个三角按「重心相对翼中心朝光的程度」+ 哈希浮动取亮 / 暗之间的颜色。
		var tris := Geometry2D.triangulate_polygon(poly)
		var center: Vector2 = (wing["bones"][0][1] as Vector2) * 0.75 + Vector2(-s * 0.05, 0)
		var light_local := LIGHT_TO_SOURCE.rotated(-float(pose["heading"]))
		var lit := col_hot.lerp(col_white, 0.25)
		var shade := col_main.darkened(0.25)
		for t in range(0, tris.size(), 3):
			var p0 := poly[tris[t]]
			var p1 := poly[tris[t + 1]]
			var p2 := poly[tris[t + 2]]
			var cen := (p0 + p1 + p2) / 3.0
			var jit := (fposmod(sin(float(t * 13) + side * 7.0) * 43758.5453, 1.0) - 0.5) * 0.24
			var b := clampf(0.5 + 0.45 * (cen - center).normalized().dot(light_local) + jit, 0.0, 1.0)
			draw_colored_polygon(PackedVector2Array([p0, p1, p2]), Color(shade.lerp(lit, b), a))
		var outline := poly.duplicate()
		outline.append(poly[0])
		draw_polyline(outline, Color(col_edge, 0.5 * a), 1.2, true)
		for bone in wing["bones"]:
			draw_line(bone[0], bone[1], Color(col_hot, a), maxf(1.5, s * 0.04), true)
			draw_line(bone[0], (bone[0] as Vector2).lerp(bone[1], 0.6), Color(col_white, 0.9 * a), maxf(1.0, s * 0.016), true)
	# 身体 + 头 + 两只尖耳
	draw_set_transform(pose["pos"], float(pose["heading"]), Vector2(1.0, 0.62))
	draw_circle(Vector2(-s * 0.08, 0), s * 0.22, Color(col_edge, 0.45 * a))
	draw_circle(Vector2(-s * 0.08, 0), s * 0.20, Color(col_main, a))
	draw_circle(Vector2(-s * 0.04, 0), s * 0.11, Color(col_hot, a))
	draw_set_transform(pose["pos"], float(pose["heading"]), Vector2.ONE)
	var head := Vector2(s * 0.20, 0)
	for side: float in [-1.0, 1.0]:
		draw_colored_polygon(PackedVector2Array([head + Vector2(-s * 0.02, side * s * 0.03), head + Vector2(s * 0.16, side * s * 0.11), head + Vector2(s * 0.05, side * s * 0.09)]),
			Color(col_main.darkened(0.25), a))
	draw_circle(head, s * 0.09, Color(col_edge, 0.45 * a))
	draw_circle(head, s * 0.075, Color(col_main, a))
	draw_circle(head + Vector2(s * 0.02, 0), s * 0.035, Color(col_white, a))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# 血迹画在最下面（蝙蝠和光晕之下），所以覆盖 _draw：先画血迹再走底座。
func _draw() -> void:
	for st in _stains:
		var k := float(st["age"]) / float(st["life"])
		var a := (1.0 - smoothstep(0.4, 1.0, k)) * 0.75 * _strength
		var r := cell_px * float(st["r"]) * (0.6 + 0.4 * _ease_out(clampf(k / 0.15, 0.0, 1.0)))
		var at: Vector2 = st["pos"]
		draw_set_transform(at, float(st["rot"]), Vector2(1.0, 0.75))
		draw_circle(Vector2.ZERO, r * 1.2, Color(col_edge, a * 0.8))
		draw_circle(Vector2.ZERO, r, Color(C_STAIN, a))
		draw_circle(Vector2(-r * 0.25, -r * 0.25), r * 0.35, Color(col_main, a * 0.8))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if _scale <= 0.001:
		return
	for pose in _bat_poses:
		_draw_bat(pose)


# 蝙蝠不画胸口光核（三只都带会很乱），亮感靠分层和光晕。
func _draw_extra(_s: float, _beat: float) -> void:
	pass


# 掠过棋子 / 登场：照 logo —— 一圈红橙火焰法阵 + 五芒星线条亮起（overshoot）+ 中心血滴溅出一圈血花。
func _draw_ignite(f: Dictionary) -> void:
	_draw_flame_ring(f)
	var age := float(f["age"])
	var k := age / float(f["life"])
	var size := float(f["size"]) * cell_px
	var at: Vector2 = f["pos"]
	var fade := 1.0 - smoothstep(0.45, 1.0, k)
	var pop := _ease_out_back(clampf(age / 0.25, 0.0, 1.0))
	var a := fade * _strength
	# 五芒星：五个顶点隔一个连一笔，外层亮红、里层暖白
	var r := size * 0.34 * pop
	var star := PackedVector2Array()
	for i in 6:
		var ang := -PI * 0.5 + float((i * 2) % 5) * TAU / 5.0 + float(f["seed"]) * 0.2
		star.append(at + Vector2.from_angle(ang) * r)
	_fx_layer.draw_polyline(star, Color(col_hot, 0.85 * a), maxf(2.0, size * 0.035), true)
	_fx_layer.draw_polyline(star, Color(col_white, 0.9 * a), maxf(1.0, size * 0.012), true)
	_fx_layer.draw_arc(at, r * 1.05, 0.0, TAU, 40, Color(col_hot, 0.7 * a), maxf(1.5, size * 0.02), true)
	# 中心血滴 + 溅出的一圈血花（ease-out 往外，落地后变淡）
	var drop_r := size * 0.09 * pop
	_fx_layer.draw_circle(at, drop_r * 1.15, Color(col_edge, 0.45 * a))
	_fx_layer.draw_circle(at, drop_r, Color(col_main, a))
	_fx_layer.draw_circle(at + Vector2(-drop_r, -drop_r) * 0.3, drop_r * 0.4, Color(col_white, 0.8 * a))
	for i in 9:
		var ang := TAU * float(i) / 9.0 + float(f["seed"])
		var dist := size * lerpf(0.06, 0.30, _ease_out(clampf(k / 0.5, 0.0, 1.0)))
		var p := at + Vector2.from_angle(ang) * dist
		_fx_layer.draw_circle(p, size * 0.025 * (1.0 - 0.5 * k), Color(col_main, a))
