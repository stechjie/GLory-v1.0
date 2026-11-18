extends Control

# 摆放界面「樱花」底图上的小动静（11.16）。对应青草地的 PrepLawnFx、夜荧光的 PrepNightFx：
#   · 树下石灯笼：烛光不规则摇曳，脚下一圈暖光，偶尔飘出几颗火星；
#   · 两三只白粉色的蝴蝶在树边的花丛之间飞，偶尔停下歇一会儿；
#   · 花吹雪：每隔十来秒来一阵风 —— 一大片花瓣从左往右斜着扫过**整片草地**，
#     同时一道淡亮的风带扫过底图、树影被吹开（shaders/prep_sakura_shade.gdshader），
#     满场慢慢落的那些花瓣（PrepPetalFall3D）也被往右带一把；
#   · 树影摇晃是底图上的 shader（apply_shade 挂），这里只负责喂阵风的两个参数。
#
# 坐标都写在底图的 UV 里（照 assets/skins/prep/prep_skin_sakura/board.png 量的），同 PrepLawnFx。
# 手机上省着跑：平时每秒只算 / 重画 30 次，阵风那几秒才每帧都算（花瓣飞得快，30 次会一顿一顿）；
# 阵风的花瓣是一个 MultiMesh，一次画完；不显示时（别的皮肤）连 _process 都停掉。
# 只给樱花皮肤用。挂在 _sky_background 下面、铺满它，在棋子和棋盘格的下面。

const SKIN_ID := "prep_skin_sakura"
const ASPECT := 1672.0 / 941.0

const PetalFall := preload("res://scenes/prep/effects/PrepPetalFall3D.gd")
const PetalTexture := preload("res://scenes/prep/effects/PrepPetalTexture.gd")
const SunDapple := preload("res://scenes/prep/PrepSunDapple.gd")
const PrepSkin := preload("res://scenes/prep/PrepSkin.gd")
const SHADE_SHADER := preload("res://shaders/prep_sakura_shade.gdshader")

const WARM := Color(1.0, 0.76, 0.36)
const WARM_LIGHT := Color(1.0, 0.94, 0.72)
const STONE_UV := Vector2(0.1700, 0.3880)     # 石灯笼的窗
const STONE_R := 0.016
const SPARK_COUNT := 7

const BUTTERFLY_COUNT := 3
const WING := Color(1.0, 0.97, 0.98)
const WING_EDGE := Color(1.0, 0.72, 0.82)
# 蝴蝶爱停的花丛（底图 UV）
const FLOWER_SPOTS := [
	Vector2(0.105, 0.245), Vector2(0.135, 0.400), Vector2(0.060, 0.520), Vector2(0.205, 0.470),
	Vector2(0.085, 0.720), Vector2(0.270, 0.170), Vector2(0.225, 0.300),
]

# 花吹雪
const GUST_PETALS := 240
const WIND_LINES := 20                       # 跟着风带一起扫过去的白色风线
const GUST_FIRST := 6.0                      # 进摆放界面后多久来第一阵
const GUST_EVERY := Vector2(11.0, 16.0)      # 之后每隔多久一阵
const GUST_FRONT_SEC := 2.4                  # 风带从最左扫到最右用多久
const GUST_FRONT_FROM := -0.25
const GUST_FRONT_SPAN := 1.6
const GUST_PETAL_LIFE := Vector2(1.2, 1.7)
const GUST_TOTAL := GUST_FRONT_SEC + 1.7

const REDRAW_HZ := 30.0

var _time := 0.0
var _acc := 0.0
var _rng := RandomNumberGenerator.new()
var _dot: Texture2D
var _sparks: Array[Dictionary] = []
var _butterflies: Array[Dictionary] = []
var _gust_mm: MultiMeshInstance2D
var _glow_layer: Control       # 灯笼的光单独一层、加色混合：白天的图上用普通混合盖一层暖色几乎看不出来
var _gust_petals: Array[Dictionary] = []
var _wind_lines: Array[Dictionary] = []
var _gust_wait := GUST_FIRST
var _gust_t := -1.0       # < 0 = 现在没有风


# 把树影 shader 挂到底图上（PrepUI 建板和换皮肤时调；别的皮肤由 PrepSunDapple.apply 负责摘掉）。
static func apply_shade(rect: CanvasItem, enabled: bool) -> void:
	if not enabled or rect == null or not is_instance_valid(rect):
		return
	var mat := rect.material as ShaderMaterial
	if mat == null or mat.shader != SHADE_SHADER:
		mat = ShaderMaterial.new()
		mat.shader = SHADE_SHADER
		mat.set_shader_parameter("noise_tex", SunDapple._noise_texture())
		rect.material = mat
	# 这个 shader 自己写 COLOR，底图的 self_modulate 进不来，皮肤的压暗倍数要单独喂。
	mat.set_shader_parameter("brightness", PrepSkin.brightness())


func _ready() -> void:
	name = "PrepSakuraFx"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dot = _make_dot()
	_rng.seed = 1116
	for i in SPARK_COUNT:
		var s := {"life": float(i) / SPARK_COUNT}
		_reset_spark(s)
		_sparks.append(s)
	for i in BUTTERFLY_COUNT:
		var spot: Vector2 = FLOWER_SPOTS[i * 2 % FLOWER_SPOTS.size()]
		_butterflies.append({"pos": spot, "vel": Vector2.ZERO, "target": _around(spot, 0.03), "rest": 0.0,
			"speed": _rng.randf_range(0.035, 0.05), "phase": _rng.randf() * TAU,
			"flap": _rng.randf_range(10.0, 13.0), "size": _rng.randf_range(12.0, 15.0), "heading": 0.0})
	_glow_layer = Control.new()
	_glow_layer.name = "LanternGlow"
	_glow_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glow_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_glow_layer.material = add
	_glow_layer.draw.connect(_draw_stone_lantern)
	add_child(_glow_layer)
	_build_gust_mesh()
	set_process(is_visible_in_tree())


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		var on := is_visible_in_tree()
		set_process(on)
		if not on:
			_end_gust()
	elif what == NOTIFICATION_PREDELETE or what == NOTIFICATION_EXIT_TREE:
		PetalFall.gust = 0.0


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


func _build_gust_mesh() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE    # 真实大小放在每片的 transform 里
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = GUST_PETALS
	_gust_mm = MultiMeshInstance2D.new()
	_gust_mm.name = "GustPetals"
	_gust_mm.multimesh = mm
	_gust_mm.texture = _pale_petal_texture()
	_gust_mm.visible = false
	add_child(_gust_mm)
	for i in GUST_PETALS:
		_gust_petals.append({})


# 阵风用的花瓣比满场落的那张更白：粉草地上粉花瓣一飞快就看不见了
func _pale_petal_texture() -> Texture2D:
	var img := PetalTexture.get_texture().get_image()
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			img.set_pixel(x, y, Color(lerpf(c.r, 1.0, 0.75), lerpf(c.g, 1.0, 0.75), lerpf(c.b, 1.0, 0.75), c.a))
	return ImageTexture.create_from_image(img)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_acc += delta
	# 平时 30 次/秒；阵风那几秒每帧都算
	if _gust_t < 0.0 and _acc < 1.0 / REDRAW_HZ:
		return
	delta = minf(_acc, 0.1)
	_acc = 0.0
	_time += delta
	for s in _sparks:
		s.life = float(s.life) + delta * float(s.speed)
		if float(s.life) >= 1.0:
			s.life = 0.0
			_reset_spark(s)
	for b in _butterflies:
		_step_butterfly(b, delta)
	_step_gust(delta)
	queue_redraw()
	_glow_layer.queue_redraw()


func _reset_spark(s: Dictionary) -> void:
	s.dx = _rng.randf_range(-0.5, 0.5)
	s.speed = _rng.randf_range(0.14, 0.24)
	s.size = _rng.randf_range(3.6, 5.6)


# 底图 UV → 本控件里的像素（同 KEEP_ASPECT_COVERED）
func _uv_to_px(uv: Vector2) -> Vector2:
	var bg := get_parent() as TextureRect
	if bg == null or bg.texture == null:
		return uv * size
	var tex := bg.texture.get_size()
	var k := maxf(size.x / tex.x, size.y / tex.y)
	var drawn := tex * k
	return (size - drawn) * 0.5 + uv * drawn


func _unit() -> float:
	return (_uv_to_px(Vector2.ONE) - _uv_to_px(Vector2.ZERO)).x


func _glow_oval(center: Vector2, half: Vector2, color: Color, alpha: float) -> void:
	if alpha <= 0.003:
		return
	_glow_layer.draw_texture_rect(_dot, Rect2(center - half, half * 2.0), false, Color(color, alpha))


func _glow(center: Vector2, radius: float, color: Color, alpha: float) -> void:
	_glow_oval(center, Vector2(radius, radius), color, alpha)


func _draw() -> void:
	for b in _butterflies:
		_draw_butterfly(b)
	_draw_wind_lines()


func _draw_stone_lantern() -> void:
	var c := _uv_to_px(STONE_UV)
	var r := STONE_R * _unit()
	# 烛光：几个互不成倍数的频率叠起来，看着不规则。白天，光比夜荧光那盏收着点
	var flicker := 0.72 + 0.14 * sin(_time * 7.3) + 0.09 * sin(_time * 17.1 + 1.3) + 0.05 * sin(_time * 29.0)
	# 再叠一个慢的明暗（约 3 秒一轮）：光晕一涨一缩，远看也看得出灯是亮着的
	var swell := 0.5 + 0.5 * sin(_time * TAU / 3.1)
	var k := flicker * (0.55 + 0.45 * swell)
	_glow(c, r * (5.5 + 1.5 * swell), WARM, 0.34 * k)                       # 照到石头和叶子上的一大圈
	_glow(c, r * 2.6, WARM_LIGHT, 0.55 * k)                                 # 窗口
	_glow_oval(c + Vector2(0.0, r * 3.2), Vector2(r * 6.5, r * 2.4), WARM, 0.36 * k)   # 脚下草地上的暖光
	for s in _sparks:
		var life := float(s.life)
		var p := c + Vector2(float(s.dx) * r * 1.4 + sin(life * 7.0 + float(s.dx) * 9.0) * r * 0.6,
			-r * 1.4 - life * r * 8.0)
		var a := sin(life * PI)
		_glow(p, float(s.size) * 2.6, WARM, 0.7 * a)
		_glow(p, float(s.size) * 0.9, WARM_LIGHT, 0.95 * a)


# ---- 蝴蝶 ----

func _around(center: Vector2, radius: float) -> Vector2:
	var ang := _rng.randf() * TAU
	var d := radius * sqrt(_rng.randf_range(0.1, 1.0))
	return center + Vector2(cos(ang) * d, sin(ang) * d * ASPECT)


func _step_butterfly(b: Dictionary, delta: float) -> void:
	if float(b.rest) > 0.0:
		b.rest = float(b.rest) - delta
		b.vel = Vector2(b.vel) * 0.85
		return
	var pos: Vector2 = b.pos
	var to: Vector2 = Vector2(b.target) - pos
	var to_n := Vector2(to.x, to.y / ASPECT)      # 换成横竖等长的空间再算
	if to_n.length() < 0.008:
		# 到了：多半在附近再换个点，有时飞去另一丛花，有时落在花上歇一会儿
		var spot: Vector2 = FLOWER_SPOTS[_rng.randi_range(0, FLOWER_SPOTS.size() - 1)]
		b.target = _around(spot, 0.035)
		if _rng.randf() < 0.35:
			b.rest = _rng.randf_range(1.0, 2.6)
		return
	var want := to_n.normalized() * float(b.speed)
	var vel: Vector2 = Vector2(b.vel).lerp(want, clampf(delta * 1.8, 0.0, 1.0))
	b.vel = vel
	var side := Vector2(-want.y, want.x).normalized()
	var flutter := sin(_time * 4.3 + float(b.phase)) * 0.6 + sin(_time * 7.1 + float(b.phase) * 2.0) * 0.4
	var drift := vel + side * flutter * float(b.speed) * 0.7
	b.pos = pos + Vector2(drift.x, drift.y * ASPECT) * delta
	b.heading = lerp_angle(float(b.heading), drift.angle(), clampf(delta * 5.0, 0.0, 1.0))


func _draw_butterfly(b: Dictionary) -> void:
	var pos := _uv_to_px(b.pos)
	var s := float(b.size)
	var resting := float(b.rest) > 0.0
	var fwd := Vector2.from_angle(float(b.heading))
	var out := Vector2(-fwd.y, fwd.x)
	# 翅膀开合：飞的时候扇得快，停着慢慢一开一合
	var wave := absf(sin(_time * float(b.flap) * (0.18 if resting else 1.0) + float(b.phase)))
	var open := 0.2 + 0.8 * wave
	for sd in [-1.0, 1.0]:
		var o: Vector2 = out * sd * open
		# 前翅大、后翅小
		draw_colored_polygon(PackedVector2Array([pos + fwd * s * 0.25, pos + fwd * s * 1.0 + o * s * 1.15,
			pos + fwd * s * 0.35 + o * s * 1.55, pos - fwd * s * 0.15 + o * s * 0.9]), Color(WING, 0.95))
		draw_colored_polygon(PackedVector2Array([pos, pos - fwd * s * 0.1 + o * s * 0.95,
			pos - fwd * s * 0.95 + o * s * 0.8, pos - fwd * s * 0.55]), Color(WING_EDGE, 0.9))
	draw_line(pos - fwd * s * 0.55, pos + fwd * s * 0.6, Color(0.55, 0.36, 0.40, 0.95), maxf(1.6, s * 0.2), true)


# ---- 花吹雪 ----

func _step_gust(delta: float) -> void:
	if _gust_t < 0.0:
		_gust_wait -= delta
		if _gust_wait <= 0.0:
			_start_gust()
		return
	_gust_t += delta
	if _gust_t >= GUST_TOTAL:
		_end_gust()
		return
	var strength := sin(clampf(_gust_t / GUST_TOTAL, 0.0, 1.0) * PI)
	var front := GUST_FRONT_FROM + GUST_FRONT_SPAN * _gust_t / GUST_FRONT_SEC
	PetalFall.gust = strength
	var bg := get_parent() as CanvasItem
	if bg != null and bg.material is ShaderMaterial:
		(bg.material as ShaderMaterial).set_shader_parameter("gust", strength)
		(bg.material as ShaderMaterial).set_shader_parameter("gust_front", front)
	var mm := _gust_mm.multimesh
	var hidden := Transform2D(0.0, Vector2.ZERO, 0.0, Vector2.ZERO)
	for i in GUST_PETALS:
		var p: Dictionary = _gust_petals[i]
		var lt := _gust_t - float(p.delay)
		if lt < 0.0 or lt > float(p.dur):
			mm.set_instance_transform_2d(i, hidden)
			continue
		var k := lt / float(p.dur)
		var vel: Vector2 = p.vel
		var uv: Vector2 = Vector2(p.start) + Vector2(vel.x * lt,
			(vel.y * lt + sin(lt * float(p.wob) + float(p.phase)) * 0.012) * ASPECT)
		var flip := absf(cos(lt * float(p.flip) + float(p.phase)))
		var sz := float(p.size)
		mm.set_instance_transform_2d(i, Transform2D(float(p.phase) + lt * float(p.spin),
			Vector2(sz * (0.3 + 0.7 * flip), sz * 1.3), 0.0, _uv_to_px(uv)))
		var tint: Color = p.tint
		mm.set_instance_color(i, Color(tint.r, tint.g, tint.b, minf(sin(k * PI) * 1.6, 1.0)))


# 风线：几道细长的白弧线贴着风带往右扫，淡入淡出 —— 整片草地一眼看得出「风来了」
func _draw_wind_lines() -> void:
	if _gust_t < 0.0:
		return
	var pts := PackedVector2Array()
	pts.resize(9)
	for w in _wind_lines:
		var lt := _gust_t - float(w.delay)
		if lt < 0.0 or lt > float(w.dur):
			continue
		var k := lt / float(w.dur)
		var head := Vector2(float(w.x) + float(w.speed) * lt, float(w.y))
		for i in 9:
			var back := float(i) / 8.0 * float(w.len)
			pts[i] = _uv_to_px(Vector2(head.x - back,
				head.y + sin((head.x - back) * float(w.curl) + float(w.phase)) * 0.012 * ASPECT))
		draw_polyline(pts, Color(1.0, 1.0, 1.0, 0.6 * sin(k * PI)), float(w.width), true)


# 一阵风：每片花瓣在风带扫到它那里的时候起飞，往右下飞一大段再淡掉 —— 起飞点铺满整片草地
func _start_gust() -> void:
	_gust_t = 0.0
	for p in _gust_petals:
		var start := Vector2(_rng.randf_range(-0.08, 0.95), _rng.randf_range(0.0, 0.82))
		p.start = start
		p.delay = maxf(0.0, (start.x + start.y * 0.25 - GUST_FRONT_FROM) / GUST_FRONT_SPAN * GUST_FRONT_SEC
			+ _rng.randf_range(-0.25, 0.1))
		p.dur = _rng.randf_range(GUST_PETAL_LIFE.x, GUST_PETAL_LIFE.y)
		p.vel = Vector2(_rng.randf_range(0.32, 0.52), _rng.randf_range(0.02, 0.10))
		p.wob = _rng.randf_range(5.0, 9.0)
		p.phase = _rng.randf() * TAU
		p.spin = _rng.randf_range(-7.0, 7.0)
		p.flip = _rng.randf_range(6.0, 11.0)
		p.size = _rng.randf_range(11.0, 25.0)
		p.tint = Color(1.0, 1.0, 1.0).lerp(Color(1.0, 0.90, 0.94), _rng.randf())
	_gust_mm.visible = true
	_wind_lines.clear()
	for i in WIND_LINES:
		var y := (float(i) + _rng.randf()) / WIND_LINES * 0.80 + 0.02
		var x := _rng.randf_range(-0.15, 0.55)
		_wind_lines.append({"x": x, "y": y, "len": _rng.randf_range(0.14, 0.26),
			"speed": _rng.randf_range(0.55, 0.75), "dur": _rng.randf_range(0.7, 1.1),
			"delay": maxf(0.0, (x + y * 0.25 - GUST_FRONT_FROM) / GUST_FRONT_SPAN * GUST_FRONT_SEC),
			"curl": _rng.randf_range(14.0, 26.0), "phase": _rng.randf() * TAU,
			"width": _rng.randf_range(1.5, 2.6)})


func _end_gust() -> void:
	_gust_t = -1.0
	_gust_wait = _rng.randf_range(GUST_EVERY.x, GUST_EVERY.y)
	PetalFall.gust = 0.0
	if _gust_mm != null:
		_gust_mm.visible = false
	var bg := get_parent() as CanvasItem
	if bg != null and bg.material is ShaderMaterial:
		(bg.material as ShaderMaterial).set_shader_parameter("gust", 0.0)
