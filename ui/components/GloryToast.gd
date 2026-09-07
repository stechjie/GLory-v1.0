class_name GloryToast
extends RefCounted

# V3 P1-04：全局瞬时提示。仓里唯一的 toast 实现。
#
# 迁移之前有三套互不相干的写法，而「拒绝动作要说明原因」这条要求
# 正好卡在它们之间：备战页拖拽买不起时一声不吭，商店面板买不起却有提示。
#
# ## 为什么照抄 Main._show_back_exit_hint()
#
# 那一处是**真机上验过**的写法，它的注释记着两条踩出来的经验：
#
#   1. 必须自带 CanvasLayer。第一版直接挂父节点，真机上被商店按钮压住 ——
#      「提示本身没被看见，等于没提示」。
#   2. 底板用 PanelContainer + 实心 StyleBox，**不靠描边**。描边在浅色水面上
#      一样糊。备战页的背景恰好就是浅蓝水面（ColorRect 0.38/0.70/0.88），
#      而旧的 PrepUI.show_message 用的正是 5px 描边。
#
# 所以这次迁移顺带修掉了备战页提示的可读性 —— 那是一个能看见的观感变化，
# 不是纯重构。
#
# ## 层级
#
# TOAST_LAYER 必须高于 ModalStack.BASE_LAYER + 栈深：拒绝动作**就发生在**
# 打开的模态里（确认框里点了不该点的），原因盖在模态底下等于没写。
# CanvasLayer.layer 是视口级全局排序，与挂在树的哪个位置无关。
#
# ## 生命周期
#
# 挂在 get_tree().current_scene（Bootstrap 走 change_scene_to_packed，
# 所以那就是 Main）。Main._clear() 会释放自己所有子节点，页面切换时
# 层和计时器一起没，回调落不到已释放的节点上 —— 不需要在 Main 里加钩子。

const Tokens := preload("res://ui/theme/GloryTokens.gd")

const LAYER_NAME := "GloryToastLayer"
const TOAST_LAYER := 1500

# 沿用 PrepUI.show_message 调好的位置与时长，不做未经请求的观感改动。
# 0.34 而不是底部居中：备战页底部全是商店 UI，这个高度是对着本作 HUD 调过的。
const ANCHOR_Y := 0.34
const DWELL_SEC := 1.3
const FADE_SEC := 0.6

# 门禁接缝。计数只增不减，reset 只给检查用。
static var _shown := 0
static var _last_text := ""


# 显示一条提示。重复调用是**替换**，不是堆叠 —— 连点时屏幕上永远只有一条。
static func show_text(text: String) -> bool:
	if text.is_empty():
		return false
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return false
	var host: Node = tree.current_scene
	if host == null or not is_instance_valid(host):
		host = tree.root as Node
	if host == null:
		return false

	_shown += 1
	_last_text = text

	var layer := host.get_node_or_null(LAYER_NAME) as CanvasLayer
	if layer == null or not is_instance_valid(layer):
		layer = _build_layer()
		host.add_child(layer)

	var label := layer.get_node_or_null("Panel/Text") as Label
	if label == null:
		return false
	label.text = text
	var panel := layer.get_node_or_null("Panel") as PanelContainer
	if panel != null:
		panel.modulate = Color(1, 1, 1, 1)

	# 计时器挂在层自己身上：页面一切换两者一起释放，回调不会落到野指针上。
	var timer := layer.get_node_or_null("Life") as Timer
	if timer == null:
		return false
	timer.stop()
	timer.wait_time = maxf(0.05, DWELL_SEC + Tokens.motion(FADE_SEC))
	timer.start()

	# 必须先 has_meta：Godot 4.7 里 get_meta(key, default) 取不到 key 时
	# 仍然会打一条引擎 ERROR，而 run_check.ps1 把这类 ERROR 直接算失败
	# （那条匹配规则是当初对着 135 条真机日志加出来的）。
	if layer.has_meta("tween"):
		var meta: Variant = layer.get_meta("tween")
		if meta is Tween and (meta as Tween).is_valid():
			(meta as Tween).kill()
	var fade := Tokens.motion(FADE_SEC)
	if fade > 0.0 and panel != null:
		var tween := layer.create_tween()
		tween.tween_interval(DWELL_SEC)
		tween.tween_property(panel, "modulate:a", 0.0, fade)
		layer.set_meta("tween", tween)
	return true


static func _build_layer() -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.name = LAYER_NAME
	layer.layer = TOAST_LAYER

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 底板走令牌，不自己 StyleBoxFlat.new() —— 那是 P1-08 棘轮盯的调用，
	# 而 ui/ 就在它的扫描范围里。
	var box := Tokens.flat_box(Color(0.04, 0.04, 0.06, 0.88), Tokens.GOLD_EDGE, 0, 10)
	box.set_content_margin_all(14)
	box.content_margin_left = 26.0
	box.content_margin_right = 26.0
	panel.add_theme_stylebox_override("panel", box)
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = ANCHOR_Y
	panel.anchor_bottom = ANCHOR_Y
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	var label := Label.new()
	label.name = "Text"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.7))
	panel.add_child(label)
	layer.add_child(panel)

	var timer := Timer.new()
	timer.name = "Life"
	timer.one_shot = true
	timer.timeout.connect(func(): dismiss())
	layer.add_child(timer)
	return layer


static func dismiss() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for host_value in [tree.current_scene, tree.root]:
		var host := host_value as Node
		if host == null or not is_instance_valid(host):
			continue
		var layer := host.get_node_or_null(LAYER_NAME)
		if layer != null and is_instance_valid(layer):
			layer.queue_free()


# --- 门禁接缝 ---------------------------------------------------------------

static func shown_count() -> int:
	return _shown


static func last_text() -> String:
	return _last_text


# 「玩家现在能看见一条提示」——层被外部释放掉也要如实返回 false，
# 所以查的是 is_inside_tree，不是引用非空。
static func is_showing() -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return false
	for host_value in [tree.current_scene, tree.root]:
		var host := host_value as Node
		if host == null or not is_instance_valid(host):
			continue
		var layer := host.get_node_or_null(LAYER_NAME)
		if layer != null and is_instance_valid(layer) and layer.is_inside_tree():
			return true
	return false


static func reset_counters_for_check() -> void:
	_shown = 0
	_last_text = ""
