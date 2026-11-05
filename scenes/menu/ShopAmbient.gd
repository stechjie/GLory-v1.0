extends Control
# 商店背景的氛围层（11.05）：叠在背景图和压暗层之间。
#   · 挂灯 / 水晶处一团暖光在呼吸（灯是画死在背景图里的，没法单独摇，所以只让光动）；
#   · 空中缓慢飘几颗光尘（柔和十字星 + 圆点，跟棋盘特效同一种闪光）。
# 灯的位置按背景图原图坐标（0~1）写，再按 TextureRect 的 KEEP_ASPECT_COVERED 换算到屏幕。
# 只在商城原图（MENU_BG_TEX）上画灯光；换成种族图 / 祈愿棋盘图时只留光尘。
# 「减少动态」时整层不画。

const Tokens := preload("res://ui/theme/GloryTokens.gd")

# 原图 1870×841 上的灯 / 水晶位置（归一化）与光团大小（相对屏幕高）、颜色。
const LIGHTS := [
	[Vector2(0.134, 0.131), 0.10, Color("ffcf6a")],
	[Vector2(0.255, 0.190), 0.11, Color("ffcf6a")],
	[Vector2(0.032, 0.310), 0.08, Color("ffcf6a")],
	[Vector2(0.813, 0.167), 0.11, Color("ffcf6a")],
	[Vector2(0.888, 0.405), 0.09, Color("ffcf6a")],
	[Vector2(0.134, 0.464), 0.08, Color("7fe0ff")],
	[Vector2(0.982, 0.560), 0.08, Color("7fe0ff")],
]
const MOTES := 26

var background: TextureRect      # 用来取当前贴图与换算坐标
var shop_texture: Texture2D      # 商城原图；当前贴图是它时才画灯光
var _t := 0.0
var _seeds: Array[Vector3] = []  # x, y 起点（0~1）, 速度系数


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1105
	for i in MOTES:
		_seeds.append(Vector3(rng.randf(), rng.randf(), rng.randf_range(0.6, 1.4)))
	set_process(not Tokens.reduced_motion())
	visible = not Tokens.reduced_motion()


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	var view := size
	if background != null and background.texture != null and background.texture == shop_texture:
		var tex_size := background.texture.get_size()
		var k := maxf(view.x / tex_size.x, view.y / tex_size.y)
		var drawn := tex_size * k
		var origin := (view - drawn) * 0.5
		for i in LIGHTS.size():
			var l: Array = LIGHTS[i]
			var p: Vector2 = origin + (l[0] as Vector2) * drawn
			var r: float = float(l[1]) * view.y
			var col: Color = l[2]
			var breath := 0.55 + 0.45 * sin(_t * (1.3 + 0.17 * float(i)) + float(i) * 1.9)
			for s in 7:
				var u := float(s) / 6.0
				draw_circle(p, r * lerpf(1.0, 0.18, u) * (0.9 + 0.1 * breath), Color(col.r, col.g, col.b, (0.018 + 0.03 * u) * breath))
	# 光尘：从下往上慢慢飘、左右摆、淡入淡出；少数画成小十字星
	for i in _seeds.size():
		var sd: Vector3 = _seeds[i]
		var period := 14.0 / sd.z
		var u := fmod(_t / period + sd.y, 1.0)
		var x := sd.x * view.x + sin(_t * 0.6 * sd.z + float(i) * 2.3) * 18.0
		var y := view.y * (1.05 - u * 1.1)
		var fade := sin(u * PI)
		var twinkle := 0.6 + 0.4 * sin(_t * 3.0 + float(i) * 1.7)
		var a := 0.55 * fade * twinkle
		var c := Vector2(x, y)
		draw_circle(c, 5.0, Color(1.0, 0.9, 0.6, 0.10 * a))
		if i % 4 == 0:
			var r := 6.0 * (0.8 + 0.2 * twinkle)
			for d in [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)]:
				var n := Vector2(-d.y, d.x)
				draw_colored_polygon(PackedVector2Array([c + n * 1.1, c + d * r, c - n * 1.1]), Color(1.0, 0.94, 0.75, a))
		draw_circle(c, 1.6, Color(1.0, 0.97, 0.85, a))
