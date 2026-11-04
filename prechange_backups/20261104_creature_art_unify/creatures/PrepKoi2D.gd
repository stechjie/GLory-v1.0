extends "res://scenes/prep/effects/creatures/PrepBoardCreature2D.gd"

# 宝藏联动「富裕之路」在备战棋盘上的金锦鲤（11.04）。通用的游动 / 点燃 / 发光都在底座里。
#
# 依据：
#   · 生物 = 锦鲤（Leno 11.04 认可的方案）；
#   · 配色与点缀取自 assets/ui/treasure_logos/富裕之路.png：一堆金币 + 蓝色闪电 →
#     身体是金币金的分层发光（暗铜 → 金 → 亮金 → 暖白），背上三枚方孔金币当鳞，
#     光丝和身上偶尔闪过的电弧是 logo 里的电蓝；
#   · 亮法和凤凰同一套（共鸣光：四层 + 柔光晕 + 光核光丝）。
#
# 游起来不僵（game-feel）：
#   · 身体一道波从头传到尾（行波，越往尾摆幅越大），这是鱼真正的游法，不是整条平移；
#   · 一阵摆尾发力接一段滑行；摆尾时胸鳍跟着划水；
#   · 转弯时身体朝弯里弯、尾巴甩出去（跟随动作）；
#   · 蓄力（gather）：身体弯成 C 形（鱼起跳前的预备）；冲刺（dash）：绷直、鳍收紧；
#   · 掠过棋子：迸出一圈旋转飞散的金币 + 几道蓝白电弧（这条联动本身就是「伤害时概率得金」）。

const BODY_POINTS := 14
const C_BOLT := Color(0.45, 0.82, 1.0)        # logo 里的电蓝
const C_BOLT_CORE := Color(0.88, 0.97, 1.0)

var _body: Array[Vector2] = []       # 本帧的身体脊线（头 → 尾），画金币鳞和电弧用


func _init() -> void:
	creature_name = "PrepKoi"
	col_edge = Color(0.24, 0.12, 0.02)      # 暗铜
	col_main = Color(0.96, 0.66, 0.12)      # 金
	col_hot = Color(1.0, 0.85, 0.36)        # 亮金
	col_white = Color(1.0, 0.97, 0.84)      # 暖白
	col_halo = Color(1.0, 0.74, 0.18)
	col_thread = C_BOLT
	cruise_speed = 0.8
	turn_rate = 1.6
	flap_hz = 1.6                            # 摆尾比凤凰扇翅快
	# 第一版 0.62 + 身宽 0.48：预览里像一弯细月牙，不像锦鲤；放大、加胖
	body_scale = 0.75
	core_offset = 0.48                       # 光核在头部，别压住背上的金币鳞


func _build_shape(s: float) -> void:
	# 身体脊线：头在前（+x），尾在后。行波：y = A(k)·sin(相位 − k·波数)，A 随 k 增大。
	var swim := lerpf(0.35, 1.0, _flap_amount)
	var c_curl := maxf(0.0, _fold)            # 蓄力：弯成 C
	var straight := 1.0 - 0.6 * maxf(0.0, -_fold)   # 冲刺：绷直
	_body.clear()
	for i in BODY_POINTS:
		var k := float(i) / float(BODY_POINTS - 1)
		var x := lerpf(0.60, -0.62, k) * s
		var wave := sin(_flap_phase - k * 2.4) * s * 0.13 * pow(k, 1.4) * swim * straight
		var bend := -_bank * s * 0.30 * k * k            # 转弯：朝弯里弯
		var curl := c_curl * s * 0.42 * sin(k * PI) * (1.0 if _bank >= 0.0 else -1.0)
		_body.append(_w(Vector2(x, wave + bend + curl)))
	var tail := _body[BODY_POINTS - 1]
	var tail_dir := (_body[BODY_POINTS - 1] - _body[BODY_POINTS - 3]).normalized()
	var fin_open := lerpf(0.55, 1.0, _unfold) * lerpf(1.0, 0.55, maxf(0.0, -_fold))
	# 1) 尾鳍：两片飘逸的长叶 + 中间一片短的，跟着尾巴方向，各自摆动（画在最后面）
	for side: float in [-1.0, 1.0]:
		var dir := tail_dir.rotated(side * 0.50 * fin_open)
		_add_tongue(_spine(tail, dir, s * 1.0 * fin_open, side * 0.65, 1.0 + side, side * 0.30), s * 0.44, true)
	_add_tongue(_spine(tail, tail_dir, s * 0.45, 0.0, 3.0), s * 0.22, false)
	# 2) 胸鳍：身体前段两侧，摆尾时一前一后划水
	var row := sin(_flap_phase * 2.0) * 0.35 * _flap_amount
	var chest := _body[3]
	var body_dir := (_body[2] - _body[4]).normalized()
	for side: float in [-1.0, 1.0]:
		# 指向两侧略偏后（第二版 2.0 弧度几乎朝正后，整片被身体盖住看不见）；根在身体边缘
		var out := body_dir.rotated(side * (1.55 + row * side))
		_add_tongue(_spine(chest + body_dir.orthogonal() * side * s * 0.26, out, s * 0.55 * fin_open, side * 0.7, 4.0 + side), s * 0.32, true)
	# 腹鳍：小一点，靠后
	var belly := _body[8]
	var belly_dir := (_body[7] - _body[9]).normalized()
	for side: float in [-1.0, 1.0]:
		var out := belly_dir.rotated(side * 2.3)
		_add_tongue(_spine(belly + belly_dir.orthogonal() * side * s * 0.06, out, s * 0.24 * fin_open, side * 0.4, 6.0 + side), s * 0.14, false)
	# 3) 身体：一整条，头圆、三成处最鼓、往尾收（底座的外形曲线正好是鱼形）
	_add_tongue(_body.duplicate(), s * 0.66, true)
	# 4) 须：嘴边两根细须往前外飘
	var head := _body[0]
	var head_dir := (_body[0] - _body[2]).normalized()
	for side: float in [-1.0, 1.0]:
		_add_tongue(_spine(head + head_dir.orthogonal() * side * s * 0.05, head_dir.rotated(side * 0.6), s * 0.26, side * 0.9, 7.0 + side), s * 0.05, false)


# 本体之上：背上三枚方孔金币鳞 + 身上偶尔闪过的电弧 + 光核（光丝是电蓝）。
func _draw_extra(s: float, beat: float) -> void:
	if _body.size() < BODY_POINTS:
		return
	for j in 3:
		var i := 4 + j * 2
		var at := _body[i]
		var r := s * (0.11 - 0.015 * float(j))
		_coin(self, at, r, 1.0, 1.0)
	# 电弧：大约每 1.3 秒在身上闪一次、持续 0.18 秒；位置和形状按时间段固定（不是每帧乱跳）
	var cycle := fposmod(_t, 1.3)
	if cycle < 0.18:
		var seed_i := int(floor(_t / 1.3))
		var a := 1.0 - cycle / 0.18
		_bolt(self, _body[2], _body[BODY_POINTS - 2], s * 0.16, seed_i, a)
	# 光核缩小一点放在头部（鱼的光核和凤凰胸口那团不一样大）
	_draw_core(s * 0.7, beat)


# 一枚方孔金币：暗边 → 金 → 亮金高光，中间方孔。spin = 正面朝向（|cos|，转动时横向变窄）。
func _coin(layer: CanvasItem, at: Vector2, r: float, spin: float, alpha: float) -> void:
	var a := alpha * _strength
	var sx := maxf(0.15, absf(spin))
	layer.draw_set_transform(at, _heading, Vector2(sx, 1.0))
	layer.draw_circle(Vector2.ZERO, r * 1.18, Color(col_edge, 0.9 * a))
	layer.draw_circle(Vector2.ZERO, r, Color(col_main, a))
	layer.draw_circle(Vector2(-r * 0.15, -r * 0.15), r * 0.62, Color(col_hot, a))
	layer.draw_rect(Rect2(Vector2(-r, -r) * 0.30, Vector2(r, r) * 0.60), Color(col_edge, 0.95 * a))
	layer.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# 一道折线电弧：从 a 到 b，中间按种子固定地折几下；外层电蓝、里层近白。
func _bolt(layer: CanvasItem, from: Vector2, to: Vector2, jag: float, seed_i: int, alpha: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_i * 7919 + 13
	var pts := PackedVector2Array()
	var n := 7
	var d := to - from
	var normal := d.orthogonal().normalized()
	for i in n + 1:
		var k := float(i) / float(n)
		var off := 0.0 if i == 0 or i == n else rng.randf_range(-1.0, 1.0) * jag
		pts.append(from + d * k + normal * off)
	var a := alpha * _strength
	layer.draw_polyline(pts, Color(C_BOLT, 0.55 * a), maxf(2.0, jag * 0.35), true)
	layer.draw_polyline(pts, Color(C_BOLT_CORE, 0.95 * a), maxf(1.0, jag * 0.12), true)


# 掠过棋子 / 登场：一圈金币旋转着往外飞（ease-out，飞出去后转着落下变淡）+ 几道蓝白电弧（只亮前 0.35 秒）。
func _draw_ignite(f: Dictionary) -> void:
	var age := float(f["age"])
	var k := age / float(f["life"])
	var size := float(f["size"]) * cell_px
	var at: Vector2 = f["pos"]
	var fade := 1.0 - smoothstep(0.5, 1.0, k)
	var pop := _ease_out_back(clampf(age / 0.22, 0.0, 1.0))
	# 底下一圈金光（普通混合）
	_soft_glow(_fx_layer, at, size * 0.6 * pop, Color(col_halo, 0.45 * fade * _strength))
	var count := 14 if bool(f["rebirth"]) else 9
	for i in count:
		var ang := TAU * float(i) / float(count) + float(f["seed"])
		var dist := size * lerpf(0.05, 0.55, _ease_out(clampf(k / 0.7, 0.0, 1.0))) * (0.8 + 0.2 * sin(float(i) * 2.7))
		var p := at + Vector2.from_angle(ang) * dist
		var spin := cos(age * 14.0 + float(i) * 1.3)
		_coin(_fx_layer, p, size * 0.075 * pop, spin, fade)
	if age < 0.35:
		var ba := 1.0 - age / 0.35
		for i in 4:
			var ang := TAU * float(i) / 4.0 + float(f["seed"]) * 1.7
			_bolt(_fx_layer, at, at + Vector2.from_angle(ang) * size * 0.55, size * 0.08, int(float(f["seed"]) * 100.0) + i, ba)
