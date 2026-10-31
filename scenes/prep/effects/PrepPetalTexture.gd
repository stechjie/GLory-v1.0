extends RefCounted

# 樱花瓣贴图（代码画的占位版）。满场落花和商店刷新的花瓣吹散共用这一张。
# 以后有美术图就把 get_texture() 改成 load 那张图，两处一起换。
#
# 形状：根部窄，往上变宽，顶端圆，正中一个樱花瓣特有的小 V 缺口。
# 颜色：根部粉白 → 尖端粉，中间一条淡淡的瓣脉。图本身带颜色，用的时候再乘一点色差。
# 图里花瓣尖朝上（图片上方）。

const SIZE := 48
const SUPERSAMPLE := 4  # 每像素 4×4 采样做抗锯齿

const BASE_COLOR := Color(1.0, 0.90, 0.94)
const TIP_COLOR := Color(1.0, 0.60, 0.76)
const VEIN_COLOR := Color(0.92, 0.52, 0.68)

static var _cached: ImageTexture


static func get_texture() -> ImageTexture:
	if _cached == null:
		_cached = ImageTexture.create_from_image(_draw())
	return _cached


# u：横向 -1..1，v：0 根部 .. 1 尖端。
static func _inside(u: float, v: float) -> bool:
	if v < 0.0 or v > 1.0:
		return false
	var half_width: float
	if v < 0.62:
		half_width = 0.80 * pow(sin(PI * 0.5 * v / 0.62), 0.6)
	else:
		var t := (v - 0.62) / 0.40
		half_width = 0.80 * sqrt(maxf(0.0, 1.0 - t * t))
	if absf(u) > half_width:
		return false
	# 顶端 V 缺口：正中深 0.10，往两边 |u|≈0.25 处合上
	if v > 0.90 + 0.40 * absf(u):
		return false
	return true


static func _draw() -> Image:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	var n := SUPERSAMPLE
	for y in SIZE:
		for x in SIZE:
			var hits := 0
			for sy in n:
				for sx in n:
					var px := (float(x) + (float(sx) + 0.5) / float(n)) / float(SIZE)
					var py := (float(y) + (float(sy) + 0.5) / float(n)) / float(SIZE)
					# 图上方是尖端：v = 1 - py
					if _inside((px - 0.5) * 2.0, 1.0 - py):
						hits += 1
			if hits == 0:
				img.set_pixel(x, y, Color(1, 1, 1, 0))
				continue
			var u := ((float(x) + 0.5) / float(SIZE) - 0.5) * 2.0
			var v := 1.0 - (float(y) + 0.5) / float(SIZE)
			var col := BASE_COLOR.lerp(TIP_COLOR, smoothstep(0.05, 0.95, v))
			# 瓣脉：正中一条细线，根部明显、往上淡掉
			var vein := (1.0 - smoothstep(0.0, 0.05, absf(u))) * (1.0 - smoothstep(0.2, 0.8, v)) * 0.45
			col = col.lerp(VEIN_COLOR, vein)
			col.a = float(hits) / float(n * n)
			img.set_pixel(x, y, col)
	return img
