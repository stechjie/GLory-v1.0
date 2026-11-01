extends RefCounted

# 商店刷新特效用的小贴图，全部代码画（和 PrepPetalTexture 一样，第一次用时生成并缓存）。
#   flame_atlas()  写实火舌：4 格不同形状的软火舌，上半截被噪声扭弯撕碎，颜色交给粒子染；
#   glow()    大块柔光：火的暖光层；
#   disc()    实心软边圆：樱花祈愿的碎片底衬、卷轴投影；
#   streak()  火星拖尾：竖长亮条，配粒子 align_y 沿飞行方向拉长；
#   spark()   小光点：高斯软点；
#   shard()   冰碴：不规则的尖菱形，冰蓝的面 + 深蓝描边 + 一条白棱线（深描边才压得住冰雪底图）；
#   glint()   冰面闪光：白色亮心 + 冰蓝十字星芒，颜色直接画在图里。
# 图里「尖」都朝上（图片上方）。

const SUPERSAMPLE := 4

static var _cache := {}


static func flame_atlas() -> ImageTexture:
	return _cached_texture("flame_atlas", _draw_flame_atlas)


static func glow() -> ImageTexture:
	return _cached_texture("glow", _draw_glow)


static func streak() -> ImageTexture:
	return _cached_texture("streak", _draw_streak)


static func disc() -> ImageTexture:
	return _cached_texture("disc", _draw_disc)


static func star() -> ImageTexture:
	return _cached_texture("star", _draw_star)


# 发光的黄星星（夜荧光祈愿的碎片）：圆润的五角星，芯白、身暖黄，外面一圈柔光。颜色画在图里。
const STAR_CORE := Color(1.0, 0.98, 0.86)
const STAR_BODY := Color(1.0, 0.82, 0.30)
const STAR_GLOW := Color(1.0, 0.74, 0.22)


static func _draw_star() -> Image:
	var size := 64
	var n := SUPERSAMPLE
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var poly := PackedVector2Array()
	for k in 10:
		# 尖朝上；外半径 0.78、内半径 0.36（内半径大一点星星更胖、更可爱）
		var r := 0.78 if k % 2 == 0 else 0.36
		var a := -PI * 0.5 + PI * float(k) / 5.0
		poly.append(Vector2(cos(a), sin(a)) * r)
	for py in size:
		for px in size:
			var hits := 0
			for sy in n:
				for sx in n:
					var q := Vector2(
						((float(px) + (float(sx) + 0.5) / n) / size - 0.5) * 2.0,
						((float(py) + (float(sy) + 0.5) / n) / size - 0.5) * 2.0)
					if Geometry2D.is_point_in_polygon(q, poly):
						hits += 1
			var c := Vector2(((float(px) + 0.5) / size - 0.5) * 2.0, ((float(py) + 0.5) / size - 0.5) * 2.0)
			var d := c.length()
			var cover := float(hits) / float(n * n)
			var glow := exp(-d * d * 3.0) * 0.55
			var col := STAR_BODY.lerp(STAR_CORE, 1.0 - smoothstep(0.0, 0.42, d))
			var out := STAR_GLOW.lerp(col, cover)
			out.a = clampf(maxf(cover, glow), 0.0, 1.0)
			img.set_pixel(px, py, out)
	return img


static func spark() -> ImageTexture:
	return _cached_texture("spark", _draw_spark)


static func shard() -> ImageTexture:
	return _cached_texture("shard", _draw_shard)


static func glint() -> ImageTexture:
	return _cached_texture("glint", _draw_glint)


static func _cached_texture(key: String, maker: Callable) -> ImageTexture:
	if not _cache.has(key):
		_cache[key] = ImageTexture.create_from_image(maker.call())
	return _cache[key]


# 写实火舌：一张横排 FLAME_FRAMES 格的图，每格一个形状不同的软火舌（粒子随机取一格）。
# 底部宽而实，往上变窄，上半截被噪声扭弯、撕成几缕，边缘全是软的。
# 颜色交给粒子 color_ramp 染；图里只放「亮度」：芯亮、边暗一点，染出来芯黄边红，有体积感。
const FLAME_FRAMES := 4
const FLAME_W := 64
const FLAME_H := 96


static func _draw_flame_atlas() -> Image:
	var img := Image.create(FLAME_W * FLAME_FRAMES, FLAME_H, false, Image.FORMAT_RGBA8)
	var warp := FastNoiseLite.new()
	warp.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	warp.frequency = 0.035
	for f in FLAME_FRAMES:
		warp.seed = 11 + f * 7
		var lean := (float(f) / float(FLAME_FRAMES - 1) - 0.5) * 0.30   # 每格往左/右偏一点
		# 顶上分几个尖：每格不同（1~3 个），尖的位置和高低也不同
		var tips := 1 + (f * 2 + 1) % 3
		var phase := float(f) * 1.7
		for py in FLAME_H:
			for px in FLAME_W:
				var u := ((float(px) + 0.5) / FLAME_W - 0.5) * 2.0
				var t := (float(py) + 0.5) / FLAME_H          # 0 顶 .. 1 底
				var up := 1.0 - t
				# 外轮廓轻轻扭一下，越往上越弯，整体往一边歪
				u += warp.get_noise_2d(px, py) * 0.30 * up + lean * up * up
				# 底下圆胖、往上收；上半截按尖数起伏（尖之间凹下去）
				var half_w := 0.92 * pow(sin(PI * clampf(t * 0.92 + 0.08, 0.0, 1.0) * 0.62), 1.1)
				var ridge := 0.5 + 0.5 * cos(u * PI * float(tips) * 0.5 + phase)
				var top := lerpf(0.10, 0.0, ridge) * smoothstep(0.55, 0.0, t) * 2.2   # 凹口深度
				var d := absf(u) / maxf(half_w, 0.02)
				var a := (1.0 - smoothstep(0.15, 1.0, d)) * 0.9
				a *= smoothstep(top, top + 0.22, t)            # 顶端：在凹口处更早淡出，留下几个尖
				a *= 1.0 - smoothstep(0.88, 1.0, t)           # 底边软掉
				# 亮度：中下部最亮（火芯），外缘和尖端暗一点，染色后芯黄边红
				var core := (1.0 - smoothstep(0.0, 0.8, d)) * smoothstep(0.15, 0.7, t)
				var lum := lerpf(0.62, 1.0, core)
				img.set_pixel(f * FLAME_W + px, py, Color(lum, lum, lum, clampf(a, 0.0, 1.0)))
	return img


# 大块柔光（暖光层用）：比 spark 大，放大很多倍也不出马赛克。
static func _draw_glow() -> Image:
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for py in size:
		for px in size:
			var x := ((float(px) + 0.5) / size - 0.5) * 2.0
			var y := ((float(py) + 0.5) / size - 0.5) * 2.0
			var r2 := x * x + y * y
			var a := exp(-r2 * 3.2) * (1.0 - smoothstep(0.85, 1.0, sqrt(r2)))
			img.set_pixel(px, py, Color(1, 1, 1, a))
	return img


# 实心软边圆：中间实、只有外圈一小段柔化。底衬 / 投影用 —— glow 是高斯，中心被盖住后外圈太淡。
static func _draw_disc() -> Image:
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for py in size:
		for px in size:
			var x := ((float(px) + 0.5) / size - 0.5) * 2.0
			var y := ((float(py) + 0.5) / size - 0.5) * 2.0
			var a := 1.0 - smoothstep(0.62, 1.0, sqrt(x * x + y * y))
			img.set_pixel(px, py, Color(1, 1, 1, a))
	return img


# 火星拖尾：竖长的亮条，头亮尾淡（头在图片上方）。粒子开 align_y 后沿速度方向拉成一道。
static func _draw_streak() -> Image:
	var w := 8
	var h := 32
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for py in h:
		for px in w:
			var x := ((float(px) + 0.5) / w - 0.5) * 2.0
			var t := (float(py) + 0.5) / h
			var a := exp(-x * x * 5.0) * (1.0 - smoothstep(0.15, 1.0, t)) * smoothstep(0.0, 0.12, t)
			img.set_pixel(px, py, Color(1, 1, 1, a))
	return img


static func _draw_spark() -> Image:
	var size := 16
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for py in size:
		for px in size:
			var x := ((float(px) + 0.5) / size - 0.5) * 2.0
			var y := ((float(py) + 0.5) / size - 0.5) * 2.0
			var a := exp(-(x * x + y * y) * 4.0)
			img.set_pixel(px, py, Color(1, 1, 1, a))
	return img


# 冰碴的四个角（x -1..1，y -1 顶 .. 1 底）：一头长尖，偏一点不对称，像敲碎的冰片。
const SHARD_POLY := [Vector2(0.05, -0.95), Vector2(0.42, -0.05), Vector2(0.12, 0.92), Vector2(-0.36, 0.18)]
const SHARD_FACE := Color(0.62, 0.84, 1.0)
const SHARD_RIM := Color(0.14, 0.38, 0.78)
const SHARD_RIDGE := Color(1.0, 1.0, 1.0)


static func _draw_shard() -> Image:
	var size := 48
	var n := SUPERSAMPLE
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for py in size:
		for px in size:
			var hits := 0
			for sy in n:
				for sx in n:
					var p := Vector2(
						((float(px) + (float(sx) + 0.5) / n) / size - 0.5) * 2.0,
						((float(py) + (float(sy) + 0.5) / n) / size - 0.5) * 2.0)
					if Geometry2D.is_point_in_polygon(p, PackedVector2Array(SHARD_POLY)):
						hits += 1
			if hits == 0:
				img.set_pixel(px, py, Color(1, 1, 1, 0))
				continue
			var c := Vector2(((float(px) + 0.5) / size - 0.5) * 2.0, ((float(py) + 0.5) / size - 0.5) * 2.0)
			var edge_d := 9.0
			for i in SHARD_POLY.size():
				var a: Vector2 = SHARD_POLY[i]
				var b: Vector2 = SHARD_POLY[(i + 1) % SHARD_POLY.size()]
				edge_d = minf(edge_d, c.distance_to(Geometry2D.get_closest_point_to_segment(c, a, b)))
			# 棱线：长尖到底角
			var ridge_d := c.distance_to(Geometry2D.get_closest_point_to_segment(c, SHARD_POLY[0], SHARD_POLY[2]))
			# 左半边亮、右半边暗一点，看得出是块有厚度的冰
			var side := 0.88 if (c - SHARD_POLY[0]).cross(SHARD_POLY[2] - SHARD_POLY[0]) > 0.0 else 1.0
			var col := SHARD_FACE * side
			col = col.lerp(SHARD_RIM, 1.0 - smoothstep(0.03, 0.12, edge_d))
			col = col.lerp(SHARD_RIDGE, (1.0 - smoothstep(0.0, 0.06, ridge_d)) * 0.85)
			col.a = float(hits) / float(n * n) * 0.95
			img.set_pixel(px, py, col)
	return img


const GLINT_RAY := Color(0.30, 0.64, 1.0)


static func _draw_glint() -> Image:
	var size := 32
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for py in size:
		for px in size:
			var x := ((float(px) + 0.5) / size - 0.5) * 2.0
			var y := ((float(py) + 0.5) / size - 0.5) * 2.0
			var core := exp(-(x * x + y * y) * 14.0)
			var rays := exp(-absf(x) * 22.0) * (1.0 - absf(y)) + exp(-absf(y) * 22.0) * (1.0 - absf(x))
			var a := clampf(core + rays * 0.85, 0.0, 1.0)
			# 芯白，往外的星芒是冰蓝
			var col := GLINT_RAY.lerp(Color.WHITE, clampf(core * 1.6, 0.0, 1.0))
			col.a = a
			img.set_pixel(px, py, col)
	return img
