extends Control

# 「金色光粒子围着 UI 转」：几颗带十字光芒的金色小星，沿宿主控件的**圆角矩形边框**
# 绕圈跑，每颗自己闪烁，身后拖两三个渐淡的残影。
#
# Leno 10.18：营地面板里「升级石」页签的提醒，上一版是 CampEntryGlow 压成椭圆的一团
# 呼吸光，实际看着是一块糊在字后面的橙色雾。这次的口径是「更特别的金色光的粒子，
# 围着 UI 转」—— 光点**贴着按钮的边走**，不压字、边缘清楚，转动本身就是提醒。
#
# 纯 `_draw()`：不碰 StyleBoxFlat.new() / Button.new()（procedural_ui_ratchet 棘轮）。
# 不可见时不推进相位、不重绘 —— 挂着 = 零成本，除非真的亮着。
#
# 加色混合：面板是深色底，金色叠上去才「发光」。（备战棋盘那种亮草绿底上不要用加色，
# 会冲成淡黄 —— 见 PrepFourStarScreenFx 的说明。这里的宿主底色是深的，正好相反。）

const RoundedRectDraw := preload("res://ui/components/RoundedRectDraw.gd")

const SPARK_COUNT := 6
# 绕一圈的秒数。太快像跑马灯（廉价），太慢又看不出在转。
const LAP_SEC := 3.4
# 光点沿边框往外让出一点，绕的是「按钮外沿」，不压到按钮里的字。
const OUTSET := 3.0
const CORNER_RADIUS := 10.0
const SPARK_SIZE := 9.0
# 每颗身后几个残影、间隔多少圈。残影让「在转」这件事一眼可读。
const TRAIL_STEPS := 3
const TRAIL_GAP := 0.018

var spark_color := Color(1.0, 0.84, 0.40)

var _phase := 0.0
var _path := PackedVector2Array()
var _lengths := PackedFloat32Array()
var _total := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat
	resized.connect(_rebuild_path)
	_rebuild_path()


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_phase = fmod(_phase + delta / LAP_SEC, 1.0)
	queue_redraw()


# 圆角矩形边框（外扩 OUTSET）的折线 + 累计弧长，用来把「走了几分之几圈」换成坐标。
func _rebuild_path() -> void:
	var box := Rect2(Vector2(-OUTSET, -OUTSET), size + Vector2(OUTSET, OUTSET) * 2.0)
	_path = RoundedRectDraw.closed(RoundedRectDraw.rounded_rect(box, CORNER_RADIUS + OUTSET))
	_lengths = PackedFloat32Array()
	_total = 0.0
	_lengths.append(0.0)
	for i in range(1, _path.size()):
		_total += _path[i - 1].distance_to(_path[i])
		_lengths.append(_total)
	queue_redraw()


func _point_at(t: float) -> Vector2:
	if _path.size() < 2 or _total <= 0.0:
		return size * 0.5
	var target := fposmod(t, 1.0) * _total
	for i in range(1, _lengths.size()):
		if _lengths[i] >= target:
			var seg := _lengths[i] - _lengths[i - 1]
			var k := 0.0 if seg <= 0.0 else (target - _lengths[i - 1]) / seg
			return _path[i - 1].lerp(_path[i], k)
	return _path[_path.size() - 1]


func _draw() -> void:
	if _total <= 0.0:
		return
	for i in SPARK_COUNT:
		var t := _phase + float(i) / float(SPARK_COUNT)
		# 每颗各自闪：亮度与大小随自己的相位起伏，一圈里不会整齐划一。
		var twinkle := 0.55 + 0.45 * (0.5 + 0.5 * sin((_phase * 9.0 + float(i) * 1.7) * TAU))
		for k in range(TRAIL_STEPS, -1, -1):
			var fade := 1.0 - float(k) / float(TRAIL_STEPS + 1)
			var pos := _point_at(t - float(k) * TRAIL_GAP)
			var s := SPARK_SIZE * twinkle * (0.45 + 0.55 * fade)
			var c := spark_color
			c.a = twinkle * fade * (1.0 if k == 0 else 0.45)
			_draw_star(pos, s, c, k == 0)


# 一颗四角星：底下一层软光晕，上面一个细长的十字芒 + 亮核。
func _draw_star(center: Vector2, radius: float, color: Color, with_halo: bool) -> void:
	if with_halo:
		var halo := color
		halo.a *= 0.22
		draw_circle(center, radius * 1.3, halo)
	var inner := radius * 0.24
	var pts := PackedVector2Array()
	for j in 8:
		var angle := float(j) * PI * 0.25 - PI * 0.5
		var r := radius if j % 2 == 0 else inner
		pts.append(center + Vector2(cos(angle), sin(angle)) * r)
	draw_colored_polygon(pts, color)
	var core := Color(1.0, 0.98, 0.9, color.a)
	draw_circle(center, inner * 0.9, core)
