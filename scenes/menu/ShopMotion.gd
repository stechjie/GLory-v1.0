extends RefCounted
# 主菜单商店的动效（11.05「整个 UI 太死」）。全部是静态工具函数，ShopScreen 只管在对的时机调用。
#
#   entry()        切分类 / 首次载入：卡片依次淡入 + 轻微回弹放大（每张错开 0.04 秒）
#   bob()          物品图缓慢上下浮动（每张相位不同）
#   attach_press() 悬停微放大、按下缩一下、松开弹回
#   selected_pulse() 当前选中卡的边框一明一暗
#   celebrate()    购买成功：卡片弹跳 + 一圈金色十字星 + 「已拥有」盖章落下
#   roll_label()   顶部余额数字滚动到新值并闪一下
#
# 画风跟用户定的走：柔和十字星、暖色，不做金属光。每段动画 ≤ 0.35 秒（循环的呼吸 / 浮动除外）。
# enabled() 为假（玩家开了「减少动态」）时全部不动，界面直接是最终状态。

const ENTRY_STAGGER := 0.04
const ENTRY_TIME := 0.3
const HOVER_SCALE := 1.03
const PRESS_SCALE := 0.97
const SPARK_GOLD := Color("ffd56a")
const SPARK_WARM := Color("fff1c4")

const Tokens := preload("res://ui/theme/GloryTokens.gd")


static func enabled() -> bool:
	return not Tokens.reduced_motion()


# 卡片依次入场。容器会改写 position，所以只动 modulate 与 scale（scale 不受容器管）。
static func entry(nodes: Array, base_delay: float = 0.0) -> void:
	if not enabled():
		return
	var i := 0
	for raw in nodes:
		var node := raw as Control
		if node == null or not is_instance_valid(node):
			continue
		node.modulate.a = 0.0
		node.scale = Vector2.ONE * 0.92
		_set_center_pivot(node)
		var tw := node.create_tween().set_parallel(true)
		var delay := base_delay + ENTRY_STAGGER * float(i)
		tw.tween_property(node, "modulate:a", 1.0, ENTRY_TIME * 0.8).set_delay(delay)
		tw.tween_property(node, "scale", Vector2.ONE, ENTRY_TIME).set_delay(delay) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		i += 1


# 物品图浮动：node 必须挂在非容器父节点下（否则容器会把 position 改回去）。
#
# ★ node 要传 Node2D，不要传 Control（11.05 用户反馈「物品浮动很卡」）：
# 工程开着 gui/common/snap_controls_to_pixels（默认值），Control 的位置会被取整到整像素。
# 4px 的慢浮动于是变成「停住不动 → 跳 1 像素 → 再停住」，一个来回只有 8 档。
# 实测：动画从 -3.57 走到 -4.00 的整段，屏幕上的图一个像素都没动；关掉取整后连续移动。
# Node2D 的位置不被取整，所以把物品图挂在一个 Node2D 下面、动这个 Node2D。
# （不全局关掉取整：那会让全游戏的 UI 文字发虚。）
static func bob(node: CanvasItem, amplitude: float, phase: float) -> void:
	if not enabled() or node == null:
		return
	var base_y: float = node.position.y
	var period := 2.6 + fmod(phase * 0.37, 0.8)
	var tw := node.create_tween().set_loops()
	# 先按相位走到起点，避免所有卡同一时刻从同一高度出发
	node.position.y = base_y + sin(phase) * amplitude
	tw.tween_property(node, "position:y", base_y - amplitude, period * 0.5) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(node, "position:y", base_y + amplitude, period * 0.5) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


# 悬停微放大、按下缩一下、松开弹回。触屏没有悬停，按下 / 松开照样有反馈。
static func attach_press(card: Control) -> void:
	if not enabled() or card == null:
		return
	card.mouse_entered.connect(func() -> void: _scale_to(card, HOVER_SCALE, 0.12))
	card.mouse_exited.connect(func() -> void: _scale_to(card, 1.0, 0.15))
	card.gui_input.connect(func(event: InputEvent) -> void:
		var pressed := false
		var released := false
		if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			pressed = event.pressed
			released = not event.pressed
		elif event is InputEventScreenTouch:
			pressed = event.pressed
			released = not event.pressed
		if pressed:
			_scale_to(card, PRESS_SCALE, 0.06)
		elif released:
			var hovering := card.get_global_rect().has_point(card.get_global_mouse_position())
			var tw := _scale_to(card, 1.06 if not hovering else HOVER_SCALE + 0.03, 0.08)
			tw.tween_property(card, "scale", Vector2.ONE * (HOVER_SCALE if hovering else 1.0), 0.14) \
				.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT))


# 选中卡：只调 self_modulate（只影响面板自己的底和边框，不影响里面的图和字），一明一暗。
static func selected_pulse(panel: Control) -> void:
	if not enabled() or panel == null:
		return
	var tw := panel.create_tween().set_loops()
	# 11.11 卡片换成浅色羊皮纸：原来的 1.35 倍在浅底上直接变成刺眼的黄，收成轻微的暖光呼吸
	tw.tween_property(panel, "self_modulate", Color(1.07, 1.04, 0.95), 0.9) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(panel, "self_modulate", Color.WHITE, 0.9) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


# 购买成功：卡片弹跳 + 卡中心爆一圈金色十字星（挂在 overlay_parent 上，不被卡片裁切）+ 「已拥有」章盖下。
static func celebrate(card: Control, overlay_parent: Control, badge: Control) -> void:
	if card == null or not is_instance_valid(card):
		return
	if not enabled():
		return
	_set_center_pivot(card)
	var tw := card.create_tween()
	tw.tween_property(card, "scale", Vector2.ONE * 1.1, 0.1).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(card, "scale", Vector2.ONE, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if overlay_parent != null:
		var burst := SparkleBurst.new()
		overlay_parent.add_child(burst)
		var rect := card.get_global_rect()
		burst.position = rect.get_center() - overlay_parent.global_position
		burst.radius = maxf(rect.size.x, rect.size.y) * 0.55
	if badge != null and is_instance_valid(badge):
		badge.pivot_offset = badge.size * 0.5
		badge.scale = Vector2.ONE * 1.9
		badge.modulate.a = 0.0
		var bt := badge.create_tween().set_parallel(true)
		bt.tween_property(badge, "scale", Vector2.ONE, 0.22).set_delay(0.12) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		bt.tween_property(badge, "modulate:a", 1.0, 0.1).set_delay(0.12)


# 余额数字从 from 滚到 to，期间闪一下金色。
static func roll_label(label: Label, from: int, to: int, formatter: Callable) -> void:
	if label == null or from == to:
		return
	if not enabled():
		label.text = str(formatter.call(to))
		return
	label.pivot_offset = label.size * 0.5
	var tw := label.create_tween().set_parallel(true)
	tw.tween_method(func(v: float) -> void: label.text = str(formatter.call(int(round(v)))),
		float(from), float(to), 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	label.modulate = Color(1.6, 1.4, 0.8)
	tw.tween_property(label, "modulate", Color.WHITE, 0.5)
	label.scale = Vector2.ONE * 1.18
	tw.tween_property(label, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


static func _scale_to(card: Control, k: float, time: float) -> Tween:
	_set_center_pivot(card)
	if card.has_meta("_press_tween"):
		var old: Tween = card.get_meta("_press_tween")
		if old != null and old.is_valid():
			old.kill()
	var tw := card.create_tween()
	tw.tween_property(card, "scale", Vector2.ONE * k, time).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	card.set_meta("_press_tween", tw)
	return tw


static func _set_center_pivot(node: Control) -> void:
	node.pivot_offset = node.size * 0.5
	if not node.resized.is_connected(_on_resized.bind(node)):
		node.resized.connect(_on_resized.bind(node))


static func _on_resized(node: Control) -> void:
	if is_instance_valid(node):
		node.pivot_offset = node.size * 0.5


# 一次性的金色十字星爆散：十几颗十字星从中心向外飞、旋转、缩小淡出，0.7 秒后自毁。
class SparkleBurst extends Control:
	const LIFE := 0.7
	const COUNT := 16
	var radius := 120.0
	var _t := 0.0
	var _dirs: Array[Vector2] = []
	var _sizes: Array[float] = []

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		top_level = false
		for i in COUNT:
			var a := TAU * float(i) / float(COUNT) + randf_range(-0.2, 0.2)
			_dirs.append(Vector2(cos(a), sin(a)) * randf_range(0.55, 1.0))
			_sizes.append(randf_range(11.0, 21.0))

	func _process(delta: float) -> void:
		_t += delta
		if _t >= LIFE:
			queue_free()
			return
		queue_redraw()

	func _draw() -> void:
		var u := _t / LIFE
		var ease_out := 1.0 - pow(1.0 - u, 3.0)
		# 中心一团暖光
		var flash := maxf(0.0, 1.0 - u * 2.2)
		for k in 6:
			draw_circle(Vector2.ZERO, radius * (0.25 + 0.12 * float(k)) * (0.6 + 0.4 * ease_out),
				Color(SPARK_GOLD.r, SPARK_GOLD.g, SPARK_GOLD.b, 0.07 * flash))
		for i in COUNT:
			var p: Vector2 = _dirs[i] * radius * ease_out
			var s: float = _sizes[i] * (1.0 - u * 0.7)
			var a := 1.0 - u
			_cross(p, s, a, u * 3.0 + float(i))

	func _cross(c: Vector2, r: float, a: float, rot: float) -> void:
		var w := r * 0.18
		for k in 4:
			var ang := rot * 0.5 + PI * 0.5 * float(k)
			var d := Vector2(cos(ang), sin(ang))
			var n := Vector2(-d.y, d.x)
			draw_colored_polygon(PackedVector2Array([c + n * w, c + d * r, c - n * w]), Color(SPARK_GOLD.r, SPARK_GOLD.g, SPARK_GOLD.b, 0.9 * a))
		draw_circle(c, w * 1.3, Color(SPARK_WARM.r, SPARK_WARM.g, SPARK_WARM.b, a))
