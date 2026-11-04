extends "res://scenes/prep/effects/creatures/PrepBoardCreature2D.gd"

# 宝藏联动「剧毒爆发」在备战棋盘上的毒蛇（11.04）。通用的游动 / 点燃 / 发光都在底座里。
#
# 依据：
#   · 生物 = 毒蛇（Leno 11.04 认可的方案）；
#   · 配色与点缀取自 assets/ui/treasure_logos/剧毒爆发.png：紫色晶体炸开 + 绿色毒液 →
#     蛇身是毒绿的分层发光（暗墨绿 → 毒绿 → 亮黄绿 → 近白），背脊一排紫晶当鳞，光丝是紫色；
#   · 亮法和凤凰、锦鲤同一套（共鸣光：四层 + 柔光晕）。
#
# 游起来不僵（game-feel）：
#   · 一道 S 形波沿身体从头传到尾（比锦鲤更长、更绵，蛇身有一个半波长），身体跟着蜿蜒；
#   · 转弯时身体顺着弯；
#   · 蓄力（gather）：盘成更紧的 S、身体缩短 —— 蛇扑击前的盘曲；冲刺（dash）：绷直猛扑；
#   · 不时吐一下叉形信子（伸出 → 抖两下 → 缩回，ease-out / ease-in），不是一直伸着；
#   · 掠过棋子（中档）：照 logo，紫晶碎片旋转着四散 + 一圈不规则的绿毒液炸开。

const BODY_POINTS := 20
const C_CRYSTAL_EDGE := Color(0.16, 0.04, 0.28)   # 紫晶：暗边
const C_CRYSTAL := Color(0.56, 0.22, 0.88)        # 紫晶：主体
const C_CRYSTAL_HI := Color(0.86, 0.70, 1.0)      # 紫晶：高光面

var _body: Array[Vector2] = []


func _init() -> void:
	creature_name = "PrepSnake"
	col_edge = Color(0.03, 0.08, 0.01)      # 暗墨绿（压得更黑：绿蛇在绿草地上要靠轮廓立住）
	col_main = Color(0.40, 0.78, 0.08)      # 毒绿
	col_hot = Color(0.72, 0.98, 0.28)       # 亮黄绿
	col_white = Color(0.93, 1.0, 0.76)      # 近白
	# 光晕用 logo 背景的紫：第一版绿光晕在绿草地上几乎看不见，紫光把绿蛇托出来
	col_halo = Color(0.62, 0.30, 0.95)
	col_thread = C_CRYSTAL
	cruise_speed = 0.7
	turn_rate = 1.4
	flap_hz = 1.1
	body_scale = 0.85                        # 第一版 0.72 + 身宽 0.30 太细，像根草


func _build_shape(s: float) -> void:
	var coil := maxf(0.0, _fold)                    # 蓄力：盘紧
	var strike := maxf(0.0, -_fold)                 # 冲刺：绷直
	var amp := s * 0.16 * lerpf(0.55, 1.0, _flap_amount) * (1.0 + 0.9 * coil) * (1.0 - 0.7 * strike)
	var length := s * 1.9 * (1.0 - 0.25 * coil) * lerpf(0.5, 1.0, _unfold)
	_body.clear()
	for i in BODY_POINTS:
		var k := float(i) / float(BODY_POINTS - 1)
		var x := s * 0.55 - length * k
		# 头部摆幅小（蛇头稳），往后渐大；一个半波长
		var wave := sin(_flap_phase - k * TAU * 1.5) * amp * (0.25 + 0.75 * smoothstep(0.0, 0.35, k))
		var bend := -_bank * s * 0.35 * k * k
		_body.append(_w(Vector2(x, wave + bend)))
	# 身体：从脖子到尾尖一整条，脖子窄、身体前段最粗、往尾收成尖
	_add_tongue(_body.slice(1), s * 0.42, true)
	# 信子：每 1.6 秒吐一次，伸出 0.12 秒 → 抖 0.2 秒 → 缩回 0.12 秒；叉成两股
	var head := _body[0]
	var head_dir := (_body[0] - _body[2]).normalized()
	var cyc := fposmod(_t, 1.6)
	var out := 0.0
	if cyc < 0.12:
		out = _ease_out(cyc / 0.12)
	elif cyc < 0.32:
		out = 1.0
	elif cyc < 0.44:
		out = 1.0 - _ease_in((cyc - 0.32) / 0.12)
	if out > 0.02 and _scale > 0.5:
		var flick := sin(_t * 40.0) * 0.18 * (1.0 if cyc > 0.12 and cyc < 0.32 else 0.0)
		for side: float in [-1.0, 1.0]:
			var tip_dir := head_dir.rotated(side * 0.32 + flick)
			_add_tongue(_spine(head + head_dir * s * 0.12, tip_dir, s * 0.30 * out, side * 0.2, 9.0 + side), s * 0.045, false)
	# 头：菱形（比脖子宽），尖端朝前
	var head_root := head - head_dir * s * 0.10
	_add_tongue(_spine(head_root, head_dir, s * 0.38, 0.0, 0.0), s * 0.40, true)


# 本体之上：背脊一排紫晶鳞（从脖子到身体中段，越往后越小）。
func _draw_extra(_s: float, _beat: float) -> void:
	if _body.size() < BODY_POINTS:
		return
	var s := cell_px * _scale * body_scale
	for j in 6:
		var i := 3 + j * 2
		var dir := (_body[i - 1] - _body[i + 1]).normalized()
		var r := s * (0.085 - 0.009 * float(j))
		# 每颗晶体自己按相位亮一下，像在吸光
		var glint := 0.5 + 0.5 * sin(_t * 3.0 - float(j) * 0.9)
		_crystal(self, _body[i], dir.angle(), r, 1.0, glint)


# 一颗菱形紫晶：暗边 → 紫 → 高光面；spin = 正面朝向（|cos|，转动时变窄）；glint = 高光强度。
func _crystal(layer: CanvasItem, at: Vector2, angle: float, r: float, spin: float, glint: float, alpha: float = 1.0) -> void:
	var a := alpha * _strength
	var sx := maxf(0.15, absf(spin))
	layer.draw_set_transform(at, angle, Vector2(1.0, sx))
	var d := PackedVector2Array([Vector2(r * 1.5, 0), Vector2(0, r * 0.75), Vector2(-r * 1.1, 0), Vector2(0, -r * 0.75)])
	var outline := PackedVector2Array()
	for p in d:
		outline.append(p * 1.25)
	layer.draw_colored_polygon(outline, Color(C_CRYSTAL_EDGE, 0.9 * a))
	layer.draw_colored_polygon(d, Color(C_CRYSTAL, a))
	# 高光面：上半边一块亮三角
	layer.draw_colored_polygon(PackedVector2Array([Vector2(r * 1.2, 0), Vector2(0, -r * 0.6), Vector2(-r * 0.3, -r * 0.05)]),
		Color(C_CRYSTAL_HI, (0.55 + 0.45 * glint) * a))
	layer.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# 掠过棋子 / 登场：照 logo —— 紫晶碎片旋转着四散（ease-out）+ 一圈不规则的绿毒液往外炸（overshoot 后收）。
func _draw_ignite(f: Dictionary) -> void:
	var age := float(f["age"])
	var k := age / float(f["life"])
	var size := float(f["size"]) * cell_px
	var at: Vector2 = f["pos"]
	var fade := 1.0 - smoothstep(0.5, 1.0, k)
	var pop := _ease_out_back(clampf(age / 0.22, 0.0, 1.0))
	var seed_f := float(f["seed"])
	# 毒液：一圈长短不一的绿色毒舌往外炸，尖端甩出去
	var saved: Array[Dictionary] = _tongues.duplicate()
	_tongues.clear()
	var count := 13 if bool(f["rebirth"]) else 9
	for i in count:
		var ang := TAU * float(i) / float(count) + seed_f
		var dir := Vector2.from_angle(ang)
		var length := size * (0.30 + 0.22 * absf(sin(seed_f * 2.0 + float(i) * 1.9))) * pop * fade
		if length < 2.0:
			continue
		_add_tongue(_spine(at + dir * size * 0.08, dir, length, (0.6 if i % 2 == 0 else -0.6), float(i)), size * 0.17 * fade, true)
	_draw_tongues_layered(_fx_layer, _tongues, cell_px * 0.025)
	_tongues = saved
	# 紫晶碎片：往外飞、边飞边转，飞出去后变淡
	var shards := 10 if bool(f["rebirth"]) else 7
	for i in shards:
		var ang := TAU * float(i) / float(shards) + seed_f * 1.3 + 0.3
		var dist := size * lerpf(0.05, 0.62, _ease_out(clampf(k / 0.75, 0.0, 1.0))) * (0.75 + 0.25 * sin(float(i) * 2.3))
		var spin := cos(age * 11.0 + float(i) * 1.7)
		_crystal(_fx_layer, at + Vector2.from_angle(ang) * dist, ang, size * 0.07 * pop, spin, 1.0, fade)
