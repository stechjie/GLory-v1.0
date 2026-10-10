extends Control

# 「柔和星爆」：由内向外衰减发射星芒的提醒特效。
#
# 10.11 第 8 条：萝卜营地里**存在升级石**时，营地入口按钮与对应的天 / 地 / 人升级石
# 要「散发柔和星爆（由内向外衰减发射星芒），光线柔和但引人注目，可加极慢呼吸明暗，
# 符合游戏风格」。
#
# 纯 `_draw()` 画，**刻意不用 `StyleBoxFlat` / 贴图** —— 本仓有 procedural_ui_ratchet
# 棘轮（业务代码里的 StyleBox 构造 / Button 构造只能下降，按文件记账）。
# 用 StyleBox 或生成贴图实现这层光会把棘轮顶红；走纯绘制就不进那个账。
# 同先例：ui/components/SoftEdgeGlow.gd。
#
# ## ★ 改动范围（10.11 用户口径，动参数前务必先读这段）
#
# 「只让你改的是萝卜营地这个 UI，没让你改天 / 地 / 人升级石」——
# 所以本组件**所有默认值都等于第一版**（`radius_scale = 1.0`、`inner_ratio = 0.0`、
# `RAY_COUNT = 10`、`HALO_STEPS = 4`、`DEFAULT_ALPHA = 0.62`、芒宽固定 3.4 / 2.1px、
# 星芒用原色），**只有萝卜营地入口按钮**在 `PrepUI` 里显式传参启用加强项。
# ⇒ 石头格那边一个像素都没变。以后要调风格，**加在调用方，别改这里的默认值**。
#
# 入口按钮（`PrepUI`）的最终口径 —— 用户 10.11 原话「换个明暗交替星爆 / 从图标中心
# 向外散发到图标外面一点 / 不要黄色 / 不够显眼」：
#   · `radius_scale = 1.3` —— 入口按钮 132×132 里那枚 512² 徽章几乎填满整个方框
#     （实测不透明像素半径 ≈ 65 / 66px，见 button_carrot_camp.png）⇒ 系数 1.0 时
#     星芒末端正好停在图标边缘，看着只是「压在图标上」；1.3 让末端多探出约 20px
#     ＝「向图标外面一点」。
#   · `inner_ratio` **不传（= 0.0）** —— 星芒从图标中心起画，正是「从图标中心向外散发」。
#     （旋钮保留：> 0 = 从图标边缘起画，留给以后别的面板用，当前无调用点。）
#   · `short_ray_alpha = 0.4` —— 长芒满亮、短芒压到 4 成 ⇒ 一圈亮一圈暗的「明暗交替」。
#   · `ray_width_scale = 1.5` —— 半径放大后细芒会显脏，加粗才撑得起星爆形状。
#   · 颜色换**冰蓝白** `Color(0.62, 0.86, 1.0)`，不用暖金 —— 徽章本身是暖橙、按钮又压在
#     亮草坪上，暖黄系两头被吃平；冰蓝白与暖橙互补，在绿底上最跳 ——「显眼」靠的是色相
#     对比，不是堆亮度。`base_alpha = 1.0` 把「亮 / 暗」的差距拉满。
#
# ## 与 SoftEdgeGlow 的分工
#
# SoftEdgeGlow 画的是**矩形外圈的呼吸亮边**（给按钮描边），呼吸交给调用方 Tween。
# 这里画的是**从中心往外射的星芒 + 核光**（给「有存货」的资源做提醒），
# 而且呼吸是**常驻**的（只要挂着就得一直呼吸）——所以动效只能自己 `_process` 推进，
# 不能等调用方每帧来喂。
#
# ## 什么时候画
#
# 调用方用 `visible` 控制开关（有石头才显示）。本节点在不可见时**不重绘**：
# `_process` 里先看 `visible`，不可见就 return（`queue_redraw()` 对不可见节点本就是空转，
# 但相位也就没必要再推进）。所以挂着它 = 零成本，除非真的亮着。

# 星芒条数（成对长短交替，10 条 = 5 长 5 短）。
const RAY_COUNT := 10
# 极慢呼吸：一个完整明暗周期约 5 秒（需求「可加极慢呼吸明暗」）。
const BREATH_PERIOD_SEC := 5.0
# 核光由内向外分几段衰减。
const HALO_STEPS := 4
# 每根星芒沿长度方向分几段（分段才能做出「由内向外衰减」的透明度）。
const RAY_SEGMENTS := 5
# 呼吸最暗时保留的比例（不调成 0：要「柔和但引人注目」，不是闪烁）。
const BREATH_FLOOR := 0.55
const DEFAULT_ALPHA := 0.62

# 星芒颜色（默认暖金，与营地 UI 同族；各元素石头可覆盖成自己的色）。
var burst_color := Color(1.0, 0.86, 0.42)
# 最长星芒占「控件短边一半」的比例。1.0 = 刚好到边；> 1 = 故意画到控件外面去。
var radius_scale := 1.0
# 星芒起点占半径的比例。**默认 0.0 = 从圆心起画**（第一版行为，也是入口按钮当前口径）。
# 传 > 0 = 改从图标边缘起画 —— 目前**没有调用点**在用，留作以后别的面板的旋钮。
var inner_ratio := 0.0
# 整体亮度系数（0~1），呼吸在这个值上下浮动。
var base_alpha := DEFAULT_ALPHA
# 短芒的亮度倍数。**默认 1.0 = 长短芒一样亮（第一版行为）**；
# 传 < 1 就变成「明暗交替星爆」——长芒亮、短芒暗，一圈亮一圈暗（用户 10.11 口径）。
var short_ray_alpha := 1.0
# 芒宽倍数。**默认 1.0 = 第一版固定 3.4 / 2.1px**。半径放大后要跟着加粗才看得清。
var ray_width_scale := 1.0

var _phase := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	# 光不该吃输入 —— 按钮的点击必须照常落到按钮上。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 星芒之间相位错开：否则同一屏里几个星爆一起亮、一起灭，像在闪。
	_rng.seed = hash(get_instance_id())
	_phase = _rng.randf() * TAU
	resized.connect(queue_redraw)


func _process(delta: float) -> void:
	if not visible:
		return
	_phase = fmod(_phase + delta * TAU / BREATH_PERIOD_SEC, TAU)
	queue_redraw()


# 一次性配置：颜色 + 半径系数（> 1 = 画到控件外）+ 星芒起点比例（0 = 从圆心起）。
func setup(color: Color, scale: float = 1.0, inner: float = 0.0) -> void:
	burst_color = color
	radius_scale = scale
	inner_ratio = inner
	queue_redraw()


# 呼吸系数（0~1）：需求「极慢呼吸明暗」。
func _breath() -> float:
	return BREATH_FLOOR + (1.0 - BREATH_FLOOR) * (0.5 + 0.5 * sin(_phase))


func _draw() -> void:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.5 * radius_scale
	if radius <= 1.0:
		return
	var breathe := _breath()
	# 星芒起点：inner_ratio = 0 时就是圆心（第一版行为，石头格走的就是这条）。
	var ray_start := radius * clampf(inner_ratio, 0.0, 0.9)

	# ① 柔软核光：几层同心圆，由内向外逐层变淡（先画最大最淡的一层）。
	for i in range(HALO_STEPS):
		var t := float(i + 1) / float(HALO_STEPS)
		var ring := burst_color
		ring.a = base_alpha * breathe * 0.34 * (1.0 - t + 0.15)
		draw_circle(center, radius * (0.22 + 0.46 * t), ring)

	# ② 星芒：长短交替，每根沿长度分段、越往外越细越淡 —— 这就是「由内向外衰减」。
	for i in range(RAY_COUNT):
		var angle := TAU * float(i) / float(RAY_COUNT)
		var is_long := (i % 2) == 0
		var length := radius * (1.0 if is_long else 0.6)
		var half_width := (3.4 if is_long else 2.1) * ray_width_scale
		# 短芒压暗就是「明暗交替」（short_ray_alpha = 1.0 时与第一版完全一致）。
		var ray_gain := 1.0 if is_long else short_ray_alpha
		# 长短芒各自的相位错开一点点，看起来像在缓慢旋转（很慢，不抢眼）。
		var spin := _phase * 0.06 * (1.0 if is_long else -1.0)
		var dir := Vector2.RIGHT.rotated(angle + spin)
		var perp := Vector2.DOWN.rotated(angle + spin)
		for s in range(RAY_SEGMENTS):
			var t0 := float(s) / float(RAY_SEGMENTS)
			var t1 := float(s + 1) / float(RAY_SEGMENTS)
			var p0 := center + dir * lerpf(ray_start, length, t0)
			var p1 := center + dir * lerpf(ray_start, length, t1)
			var w0 := half_width * (1.0 - t0)
			var w1 := half_width * (1.0 - t1)
			var ray := burst_color
			# 越靠外越淡；乘 (1-t0) 让尖端自然消失，不留硬边。
			# 再乘 ray_gain：短芒压暗 ⇒ 「明暗交替星爆」（short_ray_alpha = 1.0 时与第一版逐像素一致）。
			ray.a = base_alpha * breathe * (1.0 - t0) * 0.85 * ray_gain
			draw_polygon(PackedVector2Array([
				p0 - perp * w0, p1 - perp * w1, p1 + perp * w1, p0 + perp * w0,
			]), PackedColorArray([ray, ray, ray, ray]))

	# ③ 亮核：让中心更「引人注目」，同时不至于刺眼。
	var core := burst_color.lightened(0.4)
	core.a = base_alpha * breathe
	draw_circle(center, radius * 0.15, core)
