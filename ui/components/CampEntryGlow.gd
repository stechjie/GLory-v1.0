extends Control

# 「营地入口呼吸光」：在按钮**背后**画一圈柔和的同色系光环，会慢慢呼吸；
# 「从不满足到满足」的那一刻可以 `pulse()` 弹一下。
#
# 10.18 口径：入口原来挂的是 StarBurst（冰蓝白、10 根星芒、`radius_scale 1.3`），
# 星芒压在橙色徽章**上面**，看着像贴纸 / 镜头光斑，冷暖还打架。改成光环之后：
#   · 光在徽章**背后**（调用方把本节点 `move_child` 到 0 号位），不压图；
#   · 颜色跟着提示等级走（一级柔和同色系、二级转金），不再固定冰蓝白；
#   · 形状是「环」不是「星」—— 峰值落在徽章边缘附近，往里往外都衰减，
#     所以它读起来是「按钮在发光」，而不是「按钮上贴了个光斑」。
#
# 纯 `_draw()` 画，**刻意不用 `Panel` + `StyleBoxFlat` / 贴图** —— 本仓有
# procedural_ui_ratchet 棘轮（业务代码里的 `StyleBoxFlat.new()` / `Button.new()`
# 只能下降，按文件记账）。同先例：ui/components/SoftEdgeGlow.gd、StarBurst.gd。
#
# 呼吸是**常驻**的（挂着就得一直呼吸），所以动效自己 `_process` 推进，
# 不等调用方每帧来喂；不可见时直接 return —— 挂着 = 零成本，除非真的亮着。

# 环由几道同心弧叠出来（够软，又不至于糊成一团）。
const RING_COUNT := 9
# 峰值落在半径的多少倍上：内外各留一截衰减带。
const RING_INNER_RATIO := 0.74
const RING_OUTER_RATIO := 1.26
# 单道弧的线宽。叠加之后才是「一圈光」而不是「一条线」。
const RING_WIDTH := 7.0
const ARC_POINTS := 56
# 极慢呼吸：一个完整明暗周期约 4.5 秒（跟 StarBurst 的 5 秒同量级，不抢戏）。
const BREATH_PERIOD_SEC := 4.5
# 呼吸最暗时保留的比例。不调成 0：要「柔和」，不是闪烁。
const BREATH_FLOOR := 0.58
# 弹一下的时长与幅度（只在「从不满足变满足」那一刻用）。
const PULSE_SEC := 0.55
const PULSE_RADIUS_GAIN := 0.22
const PULSE_ALPHA_GAIN := 0.55

var glow_color := Color(1.0, 0.78, 0.36)
# 光环峰值半径 = min(size) * 0.5 * radius_scale。1.0 = 正好压在控件边缘上，
# 入口按钮里那枚徽章几乎填满方框，所以默认略微探出一点。
var radius_scale := 1.06
var base_alpha := 0.5
# 宿主是**扁长**的控件（例如营地面板那两个页签）时打开：光环跟着控件的长宽比压成
# 椭圆，绕着整个按钮走。不打开的话，圆环的半径由短边决定 —— 在 132×44 的页签上
# 正好是一坨圆光糊在文字正中间（10.18 第一版就是这样，字都看不清了）。
var fit_aspect := false

var _phase := 0.0
var _pulse := 0.0


func _ready() -> void:
	# 光的本体不该吃输入 —— 按钮的点击必须照常落到按钮上。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func setup(color: Color, alpha: float = 0.5, scale: float = 1.06, aspect: bool = false) -> void:
	glow_color = color
	base_alpha = alpha
	radius_scale = scale
	fit_aspect = aspect
	queue_redraw()


# 「从不满足到满足」那一刻弹一下。重复调用会重新起跳（不叠加）。
func pulse() -> void:
	_pulse = 1.0
	queue_redraw()


func _process(delta: float) -> void:
	if not visible:
		return
	_phase += delta * TAU / BREATH_PERIOD_SEC
	if _phase > TAU:
		_phase -= TAU
	if _pulse > 0.0:
		_pulse = maxf(0.0, _pulse - delta / PULSE_SEC)
	queue_redraw()


func _breath() -> float:
	return BREATH_FLOOR + (1.0 - BREATH_FLOOR) * (0.5 + 0.5 * sin(_phase))


func _draw() -> void:
	var peak := minf(size.x, size.y) * 0.5 * radius_scale
	if peak <= 1.0:
		return
	# 弹一下：缓出（平方）—— 起跳猛、收得稳，不会像线性那样「啪」地断掉。
	var pulse_ease := _pulse * _pulse
	peak *= 1.0 + PULSE_RADIUS_GAIN * pulse_ease
	var alpha := base_alpha * _breath() + PULSE_ALPHA_GAIN * pulse_ease
	var center := size * 0.5
	if fit_aspect:
		# 把画布按长宽比拉开，再照常画正圆 —— 画出来就是贴着控件形状的椭圆。
		# 拉开之后坐标系也跟着变了，所以圆心退回原点。
		var shorter := minf(size.x, size.y)
		if shorter > 1.0:
			draw_set_transform(center, 0.0, Vector2(size.x / shorter, size.y / shorter))
			center = Vector2.ZERO
	var r_in := peak * RING_INNER_RATIO
	var r_out := peak * RING_OUTER_RATIO
	for i in RING_COUNT:
		var t := float(i) / float(RING_COUNT - 1)
		# 三角形衰减：峰值在正中那道弧，往内往外都淡下去 ⇒ 读成「一圈光」。
		var falloff := 1.0 - absf(t - 0.5) * 2.0
		if falloff <= 0.0:
			continue
		var ring_alpha := clampf(alpha * falloff, 0.0, 1.0)
		draw_arc(center, lerpf(r_in, r_out, t), 0.0, TAU, ARC_POINTS,
			Color(glow_color.r, glow_color.g, glow_color.b, ring_alpha), RING_WIDTH, true)
