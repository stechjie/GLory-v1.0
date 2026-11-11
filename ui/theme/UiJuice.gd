extends Node

# 按钮手感（11.11，从主菜单 _anim_group 那套抽出来给子页面用）：
#   悬停放大、按下缩小、松手弹簧回弹（带一点过冲）。
# 用法：UiJuice.attach(button)。挂成按钮的子节点，按钮释放时一起走，不用手动断开。
# 只改按钮自己的 scale / pivot_offset —— 容器排版时会把 scale 复位成 1，下一帧这里再写回，
# 所以放在 HBox / VBox / Grid 里也能用。
#
# pop_in(nodes)：页面打开时让一组控件依次弹出（缩放 + 淡入，TRANS_BACK 过冲）。

const SPRING_K := 420.0
const SPRING_DAMP := 16.0
const RELEASE_KICK := 3.2

var hover_scale := 1.05
var press_scale := 0.93
var _target: Control
var _hover := false
var _down := false
var _s := 1.0
var _v := 0.0


static func attach(control: Control, hover := 1.05, press := 0.93) -> void:
	if control.has_node("UiJuice"):
		return
	var juice: Node = load("res://ui/theme/UiJuice.gd").new()
	juice.name = "UiJuice"
	juice.hover_scale = hover
	juice.press_scale = press
	control.add_child(juice)


func _ready() -> void:
	_target = get_parent() as Control
	if _target == null:
		queue_free()
		return
	_target.mouse_entered.connect(func() -> void: _hover = true)
	_target.mouse_exited.connect(func() -> void:
		_hover = false
		_down = false)
	if _target is BaseButton:
		var b := _target as BaseButton
		b.button_down.connect(func() -> void: _down = true)
		b.button_up.connect(func() -> void:
			_down = false
			_v += RELEASE_KICK)
	set_process(true)


func _process(delta: float) -> void:
	if _target == null or not is_instance_valid(_target):
		return
	var disabled := _target is BaseButton and (_target as BaseButton).disabled
	var goal := 1.0
	if not disabled:
		goal = press_scale if _down else (hover_scale if _hover else 1.0)
	_v += (goal - _s) * SPRING_K * delta
	_v *= exp(-SPRING_DAMP * delta)
	_s += _v * delta
	# 静止时不写，避免每帧触发重绘
	if absf(_s - 1.0) < 0.0005 and absf(_v) < 0.001 and goal == 1.0:
		if _target.scale != Vector2.ONE:
			_target.scale = Vector2.ONE
		return
	_target.pivot_offset = _target.size * 0.5
	_target.scale = Vector2.ONE * _s


# 一组控件依次弹出。delay 是第一个的起始延迟，step 是相邻间隔。
static func pop_in(nodes: Array, delay := 0.0, step := 0.05, from_scale := 0.85) -> void:
	var i := 0
	for node in nodes:
		var c := node as Control
		if c == null or not is_instance_valid(c):
			continue
		c.modulate.a = 0.0
		c.scale = Vector2.ONE * from_scale
		var tw := c.create_tween()
		tw.tween_interval(delay + step * i)
		tw.tween_callback(func() -> void: c.pivot_offset = c.size * 0.5)
		# 不用 set_parallel(true)：那样后面的 tweener 会并进 interval 那一步，延迟被吃掉。
		tw.tween_property(c, "modulate:a", 1.0, 0.22)
		tw.parallel().tween_property(c, "scale", Vector2.ONE, 0.38).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		i += 1
