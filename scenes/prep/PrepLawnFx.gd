extends Control

# 摆放界面青草地底图上的小动静（11.12）：
#   · 左边树下那块蓝色符文石：背后一圈青色柔光呼吸 + 一颗颗光点从符文里慢慢升起来；
#     符文本身的明暗脉动在 shaders/prep_sun_dapple.gdshader 里（只提亮那几根青色线条）。
#   · 树那一侧几只金黄色发光蝴蝶：各自挑随机地点飞过去、一路扑腾、头朝飞的方向，偶尔停下歇一会儿；
#     身后拖一小段光，飞过就淡掉（不留常驻的线）。
#
# 坐标都写在底图的 UV 里（0~1），按底图「保持比例铺满」（KEEP_ASPECT_COVERED）的方式
# 换算到屏幕 —— 换任何屏幕比例，光都还是贴在石头和树上。
# 只给默认青草地皮肤用（别的皮肤没有这块石头、这棵树）。挂在 _sky_background 下面、铺满它。

const RUNE_UV := Vector2(0.1143, 0.5246)      # 符文中心（实测青色像素的中心）
const RUNE_SIZE_UV := Vector2(0.024, 0.067)   # 符文线条的范围
const RUNE_COLOR := Color(0.45, 1.0, 0.95)
const BUTTERFLY_COUNT := 5
# 11.12 照用户给的图：金黄色发光蝴蝶（前翅大、后翅小带尾），身后拖一小段会淡掉的光
const WING_GOLD := Color(1.0, 0.86, 0.38)        # 翅膀底色：淡金奶黄（照用户的图取色）
const WING_LIGHT := Color(1.0, 0.99, 0.86)       # 翅膀中间透光 / 外缘发亮
const WING_EDGE := Color(1.0, 0.86, 0.5)         # 翅脉 / 细描边
const GLOW_GOLD := Color(1.0, 0.85, 0.4)
const TRAIL_SECONDS := 1.1      # 光尾只留最近这么久的轨迹，飞过去就淡掉
const TRAIL_STEP := 0.035
const MOTE_COUNT := 12

var _time := 0.0
var _butterflies: Array[Dictionary] = []
var _motes: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	name = "PrepLawnFx"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rng.seed = 1112
	for i in BUTTERFLY_COUNT:
		_butterflies.append({
			# pos.x / pos.y = 底图 UV（屏幕上的位置），pos.z = 前后深度（-1 在树后面，+1 离镜头近）
			"home": i,
			"pos": _home_spot(i),
			"vel": Vector3.ZERO,
			"target": _home_spot(i),
			"rest": 0.0,
			"cruise": _rng.randf_range(0.035, 0.055),
			"phase": _rng.randf() * TAU,
			"flap": _rng.randf_range(11.0, 15.0),
			"size": _rng.randf_range(10.0, 12.5),
			"axis": Vector3(1, 0, 0),   # 身体朝向（水平面里），飞的时候慢慢转过去
			"trail": [],
			"trail_tick": 0.0,
		})
	for i in MOTE_COUNT:
		_motes.append({"life": float(i) / MOTE_COUNT, "dx": 0.0, "speed": 0.0})
		_reset_mote(_motes[i], false)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_time += delta
	for bf in _butterflies:
		_step_butterfly(bf, delta)
	for m in _motes:
		m.life = float(m.life) + delta * float(m.speed)
		if float(m.life) >= 1.0:
			_reset_mote(m, true)
	queue_redraw()


func _reset_mote(m: Dictionary, wrap: bool) -> void:
	if wrap:
		m.life = 0.0
	m.dx = _rng.randf_range(-0.5, 0.5)
	m.speed = _rng.randf_range(0.28, 0.45)
	m.size = _rng.randf_range(2.4, 3.8)


# 底图 UV → 本控件里的像素（同 KEEP_ASPECT_COVERED）
func _uv_to_px(uv: Vector2) -> Vector2:
	var bg := get_parent() as TextureRect
	if bg == null or bg.texture == null:
		return uv * size
	var tex := bg.texture.get_size()
	var k := maxf(size.x / tex.x, size.y / tex.y)
	var drawn := tex * k
	return (size - drawn) * 0.5 + uv * drawn


func _px_per_uv() -> Vector2:
	return _uv_to_px(Vector2.ONE) - _uv_to_px(Vector2.ZERO)


func _draw() -> void:
	_draw_rune()
	for b in _butterflies:
		_draw_butterfly(b)


func _draw_rune() -> void:
	var c := _uv_to_px(RUNE_UV)
	var span := RUNE_SIZE_UV * _px_per_uv()
	var r := maxf(span.x, span.y) * 0.75
	var pulse := 0.5 + 0.5 * sin(_time * TAU / 2.8)
	# 背后的青色柔光：几圈半透明圆叠出来，跟着脉动
	for i in 7:
		var t := float(i) / 7.0
		draw_circle(c, r * (1.6 - t * 1.1), Color(RUNE_COLOR, (0.04 + t * 0.045) * (0.6 + pulse * 0.8)))
	# 从符文里升起的光点：往上飘、左右轻摆、先亮后淡
	for m in _motes:
		var life := float(m.life)
		var p := c + Vector2(float(m.dx) * span.x + sin(life * 6.0 + float(m.dx) * 9.0) * span.x * 0.25,
			span.y * 0.3 - life * span.y * 1.9)
		var a := sin(life * PI)
		draw_circle(p, float(m.size) * 2.6, Color(RUNE_COLOR, 0.28 * a))
		draw_circle(p, float(m.size), Color(0.85, 1.0, 1.0, 0.85 * a))


# 11.12：每只蝴蝶有自己常待的一块（不会全挤在一起），偶尔飞去萝卜那边转一圈再回来。
# 区域是底图 UV：x 横向、y 纵向；深度大多在树前，偶尔绕到树后。
const HOME_ZONES := [
	Rect2(0.10, 0.20, 0.16, 0.14),   # 树冠下
	Rect2(0.03, 0.34, 0.10, 0.20),   # 树干左边
	Rect2(0.22, 0.30, 0.14, 0.18),   # 树干右边 / 蕨叶
	Rect2(0.12, 0.50, 0.16, 0.12),   # 树根草丛（符文石附近）
	Rect2(0.32, 0.22, 0.14, 0.30),   # 树旁草地
]
const CARROT_ZONE := Rect2(0.69, 0.33, 0.12, 0.13)   # 萝卜周围
const CARROT_TRIP_CHANCE := 0.12                     # 每到一个点，有这么大概率下一站飞去萝卜


func _spot_in(zone: Rect2) -> Vector3:
	var z := _rng.randf_range(-0.6, 1.0) if _rng.randf() < 0.25 else _rng.randf_range(0.0, 1.0)
	return Vector3(_rng.randf_range(zone.position.x, zone.end.x), _rng.randf_range(zone.position.y, zone.end.y), z)


func _home_spot(i: int) -> Vector3:
	return _spot_in(HOME_ZONES[i % HOME_ZONES.size()])


# 下一站：在萝卜那边的就回自己那块；否则大多在自己那块里换个点，偶尔去萝卜。
# 同一时间最多一只在萝卜那边，免得一起飞过去像排队。
func _next_target(bf: Dictionary) -> Vector3:
	if bool(bf.get("at_carrot", false)):
		bf.at_carrot = false
		return _home_spot(int(bf.home))
	if _rng.randf() < CARROT_TRIP_CHANCE and not _someone_at_carrot():
		bf.at_carrot = true
		return _spot_in(CARROT_ZONE)
	return _home_spot(int(bf.home))


func _someone_at_carrot() -> bool:
	for other in _butterflies:
		if bool(other.get("at_carrot", false)):
			return true
	return false


# 把树当成立体的来飞：蝴蝶在 (x, y, 深度) 里挑随机目标飞过去，一路扑腾；
# 到了换下一个目标，偶尔停下歇一会儿。深度往后就能绕到树干后面（被树干挡住，见 _behind_trunk）。
func _step_butterfly(bf: Dictionary, delta: float) -> void:
	var trail: Array = bf.trail
	for pt in trail:
		pt.age = float(pt.age) + delta
	while not trail.is_empty() and float(trail[0].age) > TRAIL_SECONDS:
		trail.pop_front()
	bf.trail_tick = float(bf.trail_tick) + delta
	if float(bf.rest) <= 0.0 and float(bf.trail_tick) >= TRAIL_STEP:
		bf.trail_tick = 0.0
		trail.append({"p": _screen_uv(bf.pos), "age": 0.0})
	if float(bf.rest) > 0.0:
		bf.rest = float(bf.rest) - delta
		bf.vel = Vector3(bf.vel) * 0.85
		return
	var pos: Vector3 = bf.pos
	var to: Vector3 = Vector3(bf.target) - pos
	# 换成「看起来一样」的比例：纵向 UV 比横向长，深度 1 ≈ 横向 0.12
	var to_n := Vector3(to.x, to.y * 0.56, to.z * 0.12)
	if to_n.length() < 0.012:
		bf.target = _next_target(bf)
		if _rng.randf() < 0.3:
			bf.rest = _rng.randf_range(0.8, 2.2)
		return
	var want := to_n.normalized() * float(bf.cruise)
	var vel: Vector3 = bf.vel
	vel = vel.lerp(want, clampf(delta * 1.6, 0.0, 1.0))
	bf.vel = vel
	# 扑腾：左右（垂直于前进方向）抖 + 上下颠
	var flat_want := Vector2(want.x, want.z)
	var side := Vector3(-want.z, 0.0, want.x).normalized() if flat_want.length() > 0.0001 else Vector3(0, 0, 1)
	var flutter := sin(_time * 4.3 + float(bf.phase)) * 0.6 + sin(_time * 7.1 + float(bf.phase) * 2.0) * 0.4
	var drift := vel + side * flutter * float(bf.cruise) * 0.6 + Vector3(0, sin(_time * 5.0 + float(bf.phase)) * 0.012, 0)
	# 跟别的蝴蝶离太近就互相让开一点（不挤成一团）
	for other in _butterflies:
		if other == bf:
			continue
		var d: Vector3 = pos - Vector3(other.pos)
		var dn := Vector2(d.x, d.y * 0.56)
		if dn.length() < 0.035 and dn.length() > 0.0001:
			drift += Vector3(dn.normalized().x, dn.normalized().y, 0.0) * float(bf.cruise) * 0.8
	bf.pos = pos + Vector3(drift.x, drift.y / 0.56, drift.z / 0.12) * delta
	# 身体朝向：水平面里的前进方向（屏幕 x 往右、深度往镜头），慢慢转过去
	var flat := Vector3(drift.x, 0.0, drift.z * 0.6)
	if flat.length() > 0.004:
		bf.axis = Vector3(bf.axis).slerp(flat.normalized(), clampf(delta * 4.0, 0.0, 1.0)).normalized()


# 深度对屏幕的影响：越近（z 大）越往下一点
func _screen_uv(p: Vector3) -> Vector2:
	return Vector2(p.x, p.y + p.z * 0.03)


# 树干遮挡：蝴蝶在树后（z < 0）且屏幕上落在树干（棕色像素）上时，被树干挡住
var _bg_image: Image

func _behind_trunk(uv: Vector2, z: float) -> float:
	if z > -0.1:
		return 1.0
	var bg := get_parent() as TextureRect
	if bg == null or bg.texture == null:
		return 1.0
	if _bg_image == null:
		_bg_image = bg.texture.get_image()
		if _bg_image != null and _bg_image.is_compressed():
			_bg_image.decompress()
	if _bg_image == null:
		return 1.0
	var px := Vector2i(clampi(int(uv.x * _bg_image.get_width()), 0, _bg_image.get_width() - 1),
		clampi(int(uv.y * _bg_image.get_height()), 0, _bg_image.get_height() - 1))
	var c := _bg_image.get_pixelv(px)
	var trunk := c.r > 0.3 and c.r - c.b > 0.15 and c.g < c.r * 0.92
	if not trunk:
		return 1.0
	return clampf(1.0 - (-z - 0.1) * 3.0, 0.0, 1.0)


# 立体的蝴蝶：身体是一根沿 axis 的短棍，两侧翅膀是绕身体转轴扇动的两片板，
# 再用一个稍微往下看的镜头投到屏幕上。所以往左右飞时看到的是侧面（翅膀竖着一上一下），
# 朝镜头 / 背着镜头飞时看到的是张开的翅膀 —— 跟真的蝴蝶在立体的树旁边飞一样。
func _draw_butterfly(b: Dictionary) -> void:
	var p3: Vector3 = b.pos
	var suv := _screen_uv(p3)
	var vis := _behind_trunk(suv, p3.z)
	if vis <= 0.01:
		return
	var pos := _uv_to_px(suv)
	var s := float(b.size) * (1.0 + p3.z * 0.25)
	var resting := float(b.rest) > 0.0
	_draw_trail(b, s * vis)
	var axis: Vector3 = b.axis
	var up := Vector3.UP
	var side := up.cross(axis).normalized()
	# 扇翅角度：-0.25 = 翅膀略往下，1.35 = 两片翅膀在背上几乎合拢竖起；停着时慢慢在半合拢附近开合
	var flap_speed := float(b.flap) * (0.2 if resting else 1.0)
	var wave := 0.5 + 0.5 * sin(_time * flap_speed + float(b.phase))
	var ang := lerpf(0.9, 1.4, wave) if resting else lerpf(-0.25, 1.35, wave)
	for i in 4:
		var k := float(i) / 4.0
		draw_circle(pos, s * (1.8 - k * 1.1), Color(GLOW_GOLD, (0.03 + k * 0.03) * vis))
	var wings: Array = []
	for sd in [-1.0, 1.0]:
		var w_dir: Vector3 = side * sd * cos(ang) + up * sin(ang)
		wings.append({"dir": w_dir, "depth": w_dir.z})
	wings.sort_custom(func(wa, wb): return float(wa.depth) < float(wb.depth))
	var fore := [Vector2(0.05, 0.15), Vector2(0.35, 0.75), Vector2(0.75, 1.0), Vector2(1.08, 0.85), Vector2(1.12, 0.45), Vector2(0.85, 0.05), Vector2(0.35, -0.08)]
	var hind := [Vector2(0.05, -0.05), Vector2(0.55, -0.05), Vector2(0.85, -0.3), Vector2(0.8, -0.65), Vector2(0.5, -0.95), Vector2(0.32, -1.25), Vector2(0.18, -0.85), Vector2(0.05, -0.5)]
	var drew_body := false
	for w in wings:
		if not drew_body and float(w.depth) > 0.0:
			_draw_body3(pos, axis, s, vis)
			drew_body = true
		_wing3(pos, axis, w.dir, hind, s, 0.88 * vis)
		_wing3(pos, axis, w.dir, fore, s, vis)
	if not drew_body:
		_draw_body3(pos, axis, s, vis)


# 3D → 屏幕：x 往右、y 往上、z 朝镜头；镜头稍微往下看，所以朝镜头的方向在屏幕上偏下一点
func _proj(v: Vector3, s: float) -> Vector2:
	return Vector2(v.x, -v.y * 0.92 + v.z * 0.38) * s


func _draw_body3(pos: Vector2, axis: Vector3, s: float, vis: float) -> void:
	var head := pos + _proj(axis * 0.55, s)
	var tail := pos + _proj(-axis * 0.6, s)
	draw_line(tail, head, Color(1.0, 0.93, 0.62, vis), maxf(2.0, s * 0.13), true)
	var across := Vector3.UP.cross(axis)
	var ant_l := axis * 0.95 + Vector3.UP * 0.35 + across * 0.25
	var ant_r := axis * 0.95 + Vector3.UP * 0.35 - across * 0.25
	draw_line(head, pos + _proj(ant_l, s), Color(1.0, 0.95, 0.72, 0.85 * vis), 1.0, true)
	draw_line(head, pos + _proj(ant_r, s), Color(1.0, 0.95, 0.72, 0.85 * vis), 1.0, true)


# 一片翅膀：shape 里 x = 往外（沿翅膀方向 w_dir），y = 往前（沿身体 axis）
func _wing3(pos: Vector2, axis: Vector3, w_dir: Vector3, shape: Array, s: float, alpha: float) -> void:
	var raw := PackedVector2Array()
	for v in shape:
		var p: Vector3 = w_dir * float(v.x) + axis * float(v.y)
		raw.append(pos + _proj(p, s))
	# 侧着看翅膀会变成一条线：面积太小就只画一道亮线（也避免三角化失败）
	var area := 0.0
	for i in raw.size():
		var pa := raw[i]
		var pb := raw[(i + 1) % raw.size()]
		area += pa.x * pb.y - pb.x * pa.y
	if absf(area) < 6.0:
		draw_polyline(raw, Color(WING_LIGHT, 0.8 * alpha), maxf(1.2, s * 0.08), true)
		return
	var pts := _smooth(raw)
	draw_colored_polygon(pts, Color(WING_GOLD, 0.95 * alpha))
	var center := Vector2.ZERO
	for v in pts:
		center += v
	center /= pts.size()
	var core := PackedVector2Array()
	for v in pts:
		core.append(center.lerp(v, 0.55).lerp(pos, 0.15))
	draw_colored_polygon(core, Color(WING_LIGHT, 0.7 * alpha))
	var ring := pts.duplicate()
	ring.append(pts[0])
	draw_polyline(ring, Color(WING_LIGHT, 0.9 * alpha), maxf(1.2, s * 0.08), true)
	draw_polyline(ring, Color(WING_EDGE, 0.5 * alpha), 1.0, true)
	draw_line(pos, raw[2], Color(WING_EDGE, 0.4 * alpha), 1.0, true)


# 闭合 Catmull-Rom 圆滑（翅膀是弧边）
func _smooth(raw: PackedVector2Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := raw.size()
	for i in n:
		var p0 := raw[(i - 1 + n) % n]
		var p1 := raw[i]
		var p2 := raw[(i + 1) % n]
		var p3 := raw[(i + 2) % n]
		for k in 3:
			var t := float(k) / 3.0
			var t2 := t * t
			var t3 := t2 * t
			pts.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))
	return pts


# 身后那段光：越老越淡越细，头一段最亮
func _draw_trail(b: Dictionary, s: float) -> void:
	var trail: Array = b.trail
	if trail.size() < 2:
		return
	var prev := _uv_to_px(trail[0].p)
	for i in range(1, trail.size()):
		var cur := _uv_to_px(trail[i].p)
		var k := 1.0 - float(trail[i].age) / TRAIL_SECONDS
		if k > 0.0:
			draw_line(prev, cur, Color(GLOW_GOLD, 0.3 * k), s * 0.6 * k + 1.5, true)
			draw_line(prev, cur, Color(WING_LIGHT, 0.95 * k), maxf(1.2, s * 0.2 * k), true)
		prev = cur
	# 接到蝴蝶身上
	var head := _uv_to_px(_screen_uv(b.pos))
	draw_line(prev, head, Color(WING_LIGHT, 0.6), maxf(1.0, s * 0.18), true)
	# 尾巴上零星几颗小光点
	for i in range(0, trail.size(), 6):
		var k2 := 1.0 - float(trail[i].age) / TRAIL_SECONDS
		draw_circle(_uv_to_px(trail[i].p) + Vector2(sin(float(i) * 2.3) * 3.0, cos(float(i) * 1.7) * 3.0), 1.4 + k2, Color(WING_LIGHT, 0.7 * k2))


