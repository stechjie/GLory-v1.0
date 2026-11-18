extends Control

# 摆放界面「夜荧光」底图上的小动静（11.16）。对应青草地的 PrepLawnFx（阳光 / 符文石 / 蝴蝶）：
#   · 树上三盏星星灯：暖黄光晕各自慢慢呼吸，星星偶尔闪一下十字星芒；
#   · 树下石灯笼：烛光不规则摇曳，脚下一圈暖光，偶尔飘出几颗火星往上升；
#   · 几只青白色的荧光蛾：绕着灯打转（趋光），偶尔换一盏灯或飞去蘑菇那边；
#   · 左下几丛发光蘑菇：伞盖呼吸发光，慢慢飘出紫色孢子；
#   · 树冠偶尔掉一两片紫色花瓣，打着转飘到草地上淡掉；
#   · 草地上几团慢慢游走的荧光（青 / 紫，拖一小段淡尾）—— 代替满场金色萤火虫
#     （皮肤的 ambient = "wisp" 时 PrepBoardModels 把萤火虫藏掉）。
#
# 坐标都写在底图的 UV 里（0~1，照 assets/skins/prep/prep_skin_nightwisp/board.png 量的），
# 按底图「保持比例铺满」的方式换算到屏幕，同 PrepLawnFx。整层用加色混合：都是光，叠在夜色上才亮。
# 手机上省着跑（11.16）：每秒只算 / 重画 30 次（同 3D 棋盘的刷新率）；光晕全用同一张小圆点图、
# 先画完再画线和多边形，整层合成两三批；不显示时（别的皮肤）连 _process 都停掉。
# 只给夜荧光皮肤用。挂在 _sky_background 下面、铺满它，在棋子和棋盘格的下面。

const SKIN_ID := "prep_skin_nightwisp"
const ASPECT := 1672.0 / 941.0     # 底图宽高比：横向 1 个 UV 的长度 = 纵向 ASPECT 个 UV

const WARM := Color(1.0, 0.78, 0.40)
const WARM_LIGHT := Color(1.0, 0.93, 0.70)
# 星星灯：uv = 星星中心，r = 玻璃球半径（横向 UV），period = 呼吸一轮多少秒
const LANTERNS := [
	{"uv": Vector2(0.1485, 0.1380), "r": 0.0230, "period": 4.6, "phase": 0.0},
	{"uv": Vector2(0.2450, 0.1650), "r": 0.0170, "period": 3.7, "phase": 2.1},
	{"uv": Vector2(0.1100, 0.2350), "r": 0.0130, "period": 5.3, "phase": 4.0},
]
const STONE_UV := Vector2(0.1700, 0.3720)     # 石灯笼的窗
const STONE_R := 0.020
const SPARK_COUNT := 5

const SHROOM_COLOR := Color(0.80, 0.56, 1.0)
const SHROOMS := [                            # 伞盖中心 + 半径（横向 UV）
	{"uv": Vector2(0.0470, 0.6070), "r": 0.034},
	{"uv": Vector2(0.0740, 0.6950), "r": 0.022},
	{"uv": Vector2(0.1930, 0.9000), "r": 0.026},
]
const SPORES_PER_SHROOM := 4

const PETAL_COUNT := 3
const PETAL_COLOR := Color(0.88, 0.64, 1.0)
const PETAL_SPAWN := Rect2(0.05, 0.11, 0.29, 0.11)   # 树冠下沿（宽屏上底图顶部会被裁掉，别从更高处出）

const REDRAW_HZ := 30.0

const MOTH_COUNT := 4
const MOTH_COLOR := Color(0.72, 0.95, 1.0)
const MOTH_TRAIL := 7
const MOTH_SWITCH_CHANCE := 0.18              # 每到一个点，有这么大概率换一盏灯
const MOTH_SHROOM_CHANCE := 0.25              # 换的时候去蘑菇那边的概率

const WISP_COUNT := 7
const WISP_FIELD := Rect2(0.30, 0.10, 0.66, 0.60)   # 草地（河岸以上、树以右）
const WISP_CYAN := Color(0.50, 0.95, 1.0)
const WISP_VIOLET := Color(0.80, 0.60, 1.0)
const WISP_TRAIL := 6
const WISP_TRAIL_STEP := 0.22

var _time := 0.0
var _rng := RandomNumberGenerator.new()
var _dot: Texture2D
var _sparks: Array[Dictionary] = []
var _spores: Array[Dictionary] = []
var _moths: Array[Dictionary] = []
var _wisps: Array[Dictionary] = []
var _petals: Array[Dictionary] = []
var _acc := 0.0


func _ready() -> void:
	name = "PrepNightFx"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = add
	_dot = _make_dot()
	_rng.seed = 1116
	for i in SPARK_COUNT:
		var s := {"life": float(i) / SPARK_COUNT}
		_reset_riser(s, 0.16, 0.28)
		_sparks.append(s)
	for i in SHROOMS.size() * SPORES_PER_SHROOM:
		var sp := {"life": _rng.randf(), "at": i / SPORES_PER_SHROOM}
		_reset_riser(sp, 0.09, 0.16)
		_spores.append(sp)
	for i in MOTH_COUNT:
		var anchor := i % (LANTERNS.size() + 1)
		var start := _around(_anchor_uv(anchor), 0.05)
		_moths.append({"anchor": anchor, "pos": start, "vel": Vector2.ZERO, "target": _around(_anchor_uv(anchor), 0.05),
			"speed": _rng.randf_range(0.050, 0.075), "phase": _rng.randf() * TAU,
			"flap": _rng.randf_range(17.0, 23.0), "size": _rng.randf_range(8.5, 10.5), "trail": []})
	for i in WISP_COUNT:
		var w := {}
		_reset_wisp(w)
		w.life = _rng.randf() * float(w.dur)    # 开场别一起亮一起灭
		_wisps.append(w)
	for i in PETAL_COUNT:
		var pt := {}
		_reset_petal(pt)
		_petals.append(pt)
	set_process(is_visible_in_tree())


# 别的皮肤下这层是藏着的：藏着就不跑 _process
func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		set_process(is_visible_in_tree())


func _make_dot() -> Texture2D:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.3, 1.0])
	grad.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.4), Color(1, 1, 1, 0)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 64
	tex.height = 64
	return tex


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_acc += delta
	if _acc < 1.0 / REDRAW_HZ:
		return
	delta = minf(_acc, 0.1)
	_acc = 0.0
	_time += delta
	for s in _sparks:
		s.life = float(s.life) + delta * float(s.speed)
		if float(s.life) >= 1.0:
			s.life = 0.0
			_reset_riser(s, 0.16, 0.28)
	for sp in _spores:
		sp.life = float(sp.life) + delta * float(sp.speed)
		if float(sp.life) >= 1.0:
			sp.life = 0.0
			_reset_riser(sp, 0.09, 0.16)
	for m in _moths:
		_step_moth(m, delta)
	for w in _wisps:
		_step_wisp(w, delta)
	for pt in _petals:
		if float(pt.wait) > 0.0:
			pt.wait = float(pt.wait) - delta
			continue
		pt.life = float(pt.life) + delta / float(pt.dur)
		if float(pt.life) >= 1.0:
			_reset_petal(pt)
	queue_redraw()


# 往上飘的小光点（火星 / 孢子）共用：横向偏移、速度、大小
func _reset_riser(r: Dictionary, speed_min: float, speed_max: float) -> void:
	r.dx = _rng.randf_range(-0.5, 0.5)
	r.speed = _rng.randf_range(speed_min, speed_max)
	r.size = _rng.randf_range(3.2, 5.0)


# 底图 UV → 本控件里的像素（同 KEEP_ASPECT_COVERED）
func _uv_to_px(uv: Vector2) -> Vector2:
	var bg := get_parent() as TextureRect
	if bg == null or bg.texture == null:
		return uv * size
	var tex := bg.texture.get_size()
	var k := maxf(size.x / tex.x, size.y / tex.y)
	var drawn := tex * k
	return (size - drawn) * 0.5 + uv * drawn


# 横向 1 个 UV 是多少像素（半径都按它算，圆才是圆）
func _unit() -> float:
	return (_uv_to_px(Vector2.ONE) - _uv_to_px(Vector2.ZERO)).x


func _glow(center: Vector2, radius: float, color: Color, alpha: float) -> void:
	_glow_oval(center, Vector2(radius, radius), color, alpha)


func _glow_oval(center: Vector2, half: Vector2, color: Color, alpha: float) -> void:
	if alpha <= 0.003:
		return
	draw_texture_rect(_dot, Rect2(center - half, half * 2.0), false, Color(color, alpha))


func _draw() -> void:
	_draw_wisps()
	_draw_shrooms()
	_draw_lanterns()
	_draw_stone_lantern()
	# 以上全是同一张圆点图（一批）；蛾子的光晕也先画，线和多边形留到最后，别把批次打断
	for m in _moths:
		_glow(_uv_to_px(m.pos), float(m.size) * 2.8, MOTH_COLOR, 0.42)
	for m in _moths:
		_draw_moth(m)
	_draw_petals()


func _draw_lanterns() -> void:
	var u := _unit()
	for l in LANTERNS:
		var c := _uv_to_px(l.uv)
		var r := float(l.r) * u
		var t := _time * TAU / float(l.period) + float(l.phase)
		var breathe := 0.5 + 0.35 * sin(t) + 0.15 * sin(t * 2.7 + 1.0)
		_glow(c, r * 4.2, WARM, 0.07 + 0.09 * breathe)          # 照到周围叶子上的一大圈
		_glow(c, r * 1.7, WARM_LIGHT, 0.12 + 0.20 * breathe)    # 玻璃球本身
		# 星芒：偶尔闪一下，横竖两道细长的光
		var flare := pow(maxf(0.0, sin(_time * 0.55 + float(l.phase) * 2.3)), 28.0)
		if flare > 0.01:
			_glow_oval(c, Vector2(r * 2.6, r * 0.22), WARM_LIGHT, 0.9 * flare)
			_glow_oval(c, Vector2(r * 0.22, r * 2.6), WARM_LIGHT, 0.9 * flare)
			_glow(c, r * 0.9, Color.WHITE, 0.5 * flare)


func _draw_stone_lantern() -> void:
	var u := _unit()
	var c := _uv_to_px(STONE_UV)
	var r := STONE_R * u
	# 烛光：几个互不成倍数的频率叠起来，看着不规则
	var flicker := 0.72 + 0.14 * sin(_time * 7.3) + 0.09 * sin(_time * 17.1 + 1.3) + 0.05 * sin(_time * 29.0)
	_glow(c, r * 1.5, WARM_LIGHT, 0.30 * flicker)
	_glow(c, r * 3.4, WARM, 0.13 * flicker)
	_glow_oval(c + Vector2(0.0, r * 2.6), Vector2(r * 4.2, r * 1.5), WARM, 0.12 * flicker)   # 脚下草地上的暖光
	for s in _sparks:
		var life := float(s.life)
		var p := c + Vector2(float(s.dx) * r * 1.4 + sin(life * 7.0 + float(s.dx) * 9.0) * r * 0.6,
			-r * 1.2 - life * r * 5.5)
		var a := sin(life * PI)
		_glow(p, float(s.size) * 2.4, WARM, 0.35 * a)
		_glow(p, float(s.size) * 0.9, WARM_LIGHT, 0.9 * a)


func _draw_shrooms() -> void:
	var u := _unit()
	for i in SHROOMS.size():
		var sh: Dictionary = SHROOMS[i]
		var c := _uv_to_px(sh.uv)
		var r := float(sh.r) * u
		var breathe := 0.5 + 0.5 * sin(_time * TAU / 5.5 + float(i) * 1.9)
		_glow_oval(c, Vector2(r * 1.9, r * 1.4), SHROOM_COLOR, 0.08 + 0.18 * breathe)
	for sp in _spores:
		var sh2: Dictionary = SHROOMS[int(sp.at)]
		var c2 := _uv_to_px(sh2.uv)
		var r2 := float(sh2.r) * u
		var life := float(sp.life)
		var p := c2 + Vector2(float(sp.dx) * r2 * 2.4 + sin(life * 5.0 + float(sp.dx) * 8.0) * r2 * 0.5,
			r2 * 0.5 - life * r2 * 4.0)
		var a := sin(life * PI)
		_glow(p, float(sp.size) * 4.2, SHROOM_COLOR, 0.55 * a)
		_glow(p, float(sp.size) * 1.5, Color(0.96, 0.88, 1.0), 0.95 * a)


# ---- 荧光蛾 ----

# 蛾子能绕的点：0~2 = 三盏星星灯，3 = 石灯笼，4 以后 = 蘑菇
func _anchor_uv(index: int) -> Vector2:
	if index < LANTERNS.size():
		return LANTERNS[index].uv
	if index == LANTERNS.size():
		return STONE_UV
	return SHROOMS[(index - LANTERNS.size() - 1) % SHROOMS.size()].uv


# 某个点周围随机挑一处（radius 是横向 UV）
func _around(center: Vector2, radius: float) -> Vector2:
	var ang := _rng.randf() * TAU
	var d := radius * sqrt(_rng.randf_range(0.15, 1.0))
	return center + Vector2(cos(ang) * d, sin(ang) * d * ASPECT)


func _step_moth(m: Dictionary, delta: float) -> void:
	var pos: Vector2 = m.pos
	var to: Vector2 = Vector2(m.target) - pos
	var to_n := Vector2(to.x, to.y / ASPECT)      # 换成横竖等长的空间再算距离和方向
	if to_n.length() < 0.008:
		if _rng.randf() < MOTH_SWITCH_CHANCE:
			if _rng.randf() < MOTH_SHROOM_CHANCE:
				m.anchor = LANTERNS.size() + 1 + _rng.randi_range(0, SHROOMS.size() - 1)
			else:
				m.anchor = _rng.randi_range(0, LANTERNS.size())
		m.target = _around(_anchor_uv(int(m.anchor)), 0.045)
		return
	var want := to_n.normalized() * float(m.speed)
	var vel: Vector2 = Vector2(m.vel).lerp(want, clampf(delta * 2.2, 0.0, 1.0))
	m.vel = vel
	# 蛾子飞得乱：垂直于前进方向来回抖
	var side := Vector2(-want.y, want.x).normalized()
	var flutter := sin(_time * 6.1 + float(m.phase)) * 0.6 + sin(_time * 10.3 + float(m.phase) * 2.0) * 0.4
	var drift := vel + side * flutter * float(m.speed) * 0.9
	m.pos = pos + Vector2(drift.x, drift.y * ASPECT) * delta
	m.heading = drift.angle()
	var trail: Array = m.trail
	trail.append(m.pos)
	if trail.size() > MOTH_TRAIL:
		trail.pop_front()


func _draw_moth(m: Dictionary) -> void:
	var pos := _uv_to_px(m.pos)
	var s := float(m.size)
	var trail: Array = m.trail
	for i in range(1, trail.size()):
		var k := float(i) / float(trail.size())
		draw_line(_uv_to_px(trail[i - 1]), _uv_to_px(trail[i]), Color(MOTH_COLOR, 0.38 * k), 1.0 + k * 2.5, true)
	var fwd := Vector2.from_angle(float(m.get("heading", 0.0)))
	var out := Vector2(-fwd.y, fwd.x)
	# 翅膀：两片三角，开合的幅度跟着扇动走
	var open := 0.25 + 0.75 * absf(sin(_time * float(m.flap) + float(m.phase)))
	for sd in [-1.0, 1.0]:
		var tip: Vector2 = pos + out * sd * s * 1.25 * open + fwd * s * 0.15
		var back: Vector2 = pos + out * sd * s * 0.75 * open - fwd * s * 0.85
		draw_colored_polygon(PackedVector2Array([pos + fwd * s * 0.45, tip, back, pos - fwd * s * 0.3]),
			Color(MOTH_COLOR, 0.75))
	draw_line(pos - fwd * s * 0.5, pos + fwd * s * 0.6, Color(0.95, 1.0, 1.0, 0.9), maxf(1.5, s * 0.28), true)


# ---- 树上落花 ----

func _reset_petal(pt: Dictionary) -> void:
	pt.start = Vector2(_rng.randf_range(PETAL_SPAWN.position.x, PETAL_SPAWN.end.x),
		_rng.randf_range(PETAL_SPAWN.position.y, PETAL_SPAWN.end.y))
	pt.fall = _rng.randf_range(0.30, 0.44)      # 落多远（纵向 UV）
	pt.dur = _rng.randf_range(5.5, 8.0)
	pt.wait = _rng.randf_range(0.5, 6.0)        # 「偶尔」：掉完隔一阵再掉下一片
	pt.life = 0.0
	pt.phase = _rng.randf() * TAU
	pt.spin = _rng.randf_range(-5.0, 5.0)
	pt.size = _rng.randf_range(5.0, 7.0)


func _draw_petals() -> void:
	for pt in _petals:
		if float(pt.wait) > 0.0:
			continue
		var k := float(pt.life)
		var inv := 1.0 - k
		# 越接近地面落得越慢；左右摆着往右下飘
		var uv: Vector2 = Vector2(pt.start) + Vector2(sin(k * 6.0 + float(pt.phase)) * 0.012 + k * 0.03,
			float(pt.fall) * (1.0 - inv * sqrt(inv)))
		var a := minf(k / 0.1, 1.0) * minf(inv / 0.25, 1.0)
		var pos := _uv_to_px(uv)
		var s := float(pt.size)
		var along := Vector2.from_angle(float(pt.phase) + k * float(pt.spin))
		# 打转：宽度跟着翻面一宽一窄
		var across := Vector2(-along.y, along.x) * (0.25 + 0.75 * absf(cos(k * 11.0 + float(pt.phase))))
		draw_colored_polygon(PackedVector2Array([pos + along * s, pos + along * s * 0.2 + across * s * 0.55,
			pos - along * s * 0.8, pos + along * s * 0.2 - across * s * 0.55]), Color(PETAL_COLOR, 0.8 * a))


# ---- 草地上游走的荧光团 ----

func _reset_wisp(w: Dictionary) -> void:
	w.pos = Vector2(_rng.randf_range(WISP_FIELD.position.x, WISP_FIELD.end.x),
		_rng.randf_range(WISP_FIELD.position.y, WISP_FIELD.end.y))
	w.heading = _rng.randf() * TAU
	w.speed = _rng.randf_range(0.012, 0.022)
	w.phase = _rng.randf() * TAU
	w.dur = _rng.randf_range(9.0, 15.0)
	w.life = 0.0
	w.size = _rng.randf_range(15.0, 22.0)
	w.color = WISP_CYAN.lerp(WISP_VIOLET, _rng.randf())
	w.trail = []
	w.trail_tick = 0.0


func _step_wisp(w: Dictionary, delta: float) -> void:
	w.life = float(w.life) + delta
	if float(w.life) >= float(w.dur):
		_reset_wisp(w)
		return
	# 慢慢拐弯，路线是弯的；快出草地了就往中间拐
	var turn := sin(_time * 0.37 + float(w.phase)) * 0.7 + sin(_time * 0.83 + float(w.phase) * 1.7) * 0.4
	var pos: Vector2 = w.pos
	if not WISP_FIELD.has_point(pos):
		var home := (WISP_FIELD.get_center() - pos)
		turn = signf(Vector2.from_angle(float(w.heading)).cross(Vector2(home.x, home.y / ASPECT))) * 1.6
	w.heading = float(w.heading) + turn * delta
	var dir := Vector2.from_angle(float(w.heading))
	w.pos = pos + Vector2(dir.x, dir.y * ASPECT) * float(w.speed) * delta
	w.trail_tick = float(w.trail_tick) + delta
	if float(w.trail_tick) >= WISP_TRAIL_STEP:
		w.trail_tick = 0.0
		var trail: Array = w.trail
		trail.append(w.pos)
		if trail.size() > WISP_TRAIL:
			trail.pop_front()


func _draw_wisps() -> void:
	for w in _wisps:
		var fade := sin(float(w.life) / float(w.dur) * PI)
		var a := fade * (0.8 + 0.2 * sin(_time * 2.3 + float(w.phase)))
		var col: Color = w.color
		var s := float(w.size)
		var trail: Array = w.trail
		for i in trail.size():
			var k := float(i + 1) / float(trail.size() + 1)
			_glow(_uv_to_px(trail[i]), s * (0.5 + 0.7 * k), col, 0.16 * k * a)
		var p := _uv_to_px(w.pos) + Vector2(0.0, sin(_time * 1.3 + float(w.phase)) * 3.0)
		_glow(p, s * 2.8, col, 0.20 * a)
		_glow(p, s * 1.0, col.lerp(Color.WHITE, 0.6), 0.75 * a)
