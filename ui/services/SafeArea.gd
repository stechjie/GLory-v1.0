extends Node
# 屏幕安全区（灵动岛、刘海、圆角、手势条）—— 全游戏唯一的来源。
#
# 背景照样铺满全屏；按钮、文字这些要点、要看的东西放进安全区。
# 设计与取舍见 docs/安全区适配.md（缩减自 docs/GLORY_跨设备UI安全区与战斗适配改造清单_20260926.md）。
#
# ## 坐标
#
# 给出去的都是**根视口的逻辑坐标**：1600×720 + expand 之后页面上 Control 用的那一套。
#
#   手机（iOS / 安卓）：DisplayServer.get_display_safe_area() 是窗口像素。手机上游戏窗口就是整块屏幕、
#     原点为 0，按 视口 / 窗口 的比例换算是准的（新手教学 TutorialMode._safe_rect 一直这么算）。
#   电脑：**不读**。那个接口在电脑上给的是整块显示器去掉任务栏，不是这个窗口。安全区 = 整个窗口。
#
# 安卓现在的导出设置（edge_to_edge 关）本来就不画进挖孔，读出来四边都是 0，什么都不变。
# 受影响的是 iPhone 横屏：灵动岛 / 圆角那一侧，手机倒过来拿就换到另一侧，所以左右都要让。
#
# ## 测试
#
# `--safe-area=左,上,右,下`（逻辑单位）在电脑上假装有刘海；门禁用 set_test_insets()。
#
# ## 什么时候变
#
# 转屏（180° 翻转时宽高不变，只听 size_changed 不够）、窗口大小变、切回前台。
# 每 POLL_SEC 秒量一次，变了才发 changed —— 不是每帧重排。

signal changed

const POLL_SEC := 0.25
const FLAG := "--safe-area="
const META := &"safe_area_base_offsets"

var _insets := Vector4.ZERO   # 左、上、右、下
var _test: Variant = null     # 测试用的假安全区（Vector4），null = 读真的
var _poll := 0.0
var _tracked: Array[WeakRef] = []


func _ready() -> void:
	var args := OS.get_cmdline_args()
	if "--server" in args or "--dedicated-server" in args:
		set_process(false)
		return
	for arg in args + OS.get_cmdline_user_args():
		if str(arg).begins_with(FLAG):
			var parts := str(arg).substr(FLAG.length()).split(",")
			if parts.size() == 4:
				_test = Vector4(float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
	_refresh()


func _process(delta: float) -> void:
	_poll += delta
	if _poll < POLL_SEC:
		return
	_poll = 0.0
	_refresh()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED:
		_refresh()


# 四边各让多少（左、上、右、下），逻辑单位。
func insets() -> Vector4:
	return _insets


# 安全区在根视口里的矩形。
func rect() -> Rect2:
	var size := get_tree().root.get_visible_rect().size
	return Rect2(_insets.x, _insets.y,
		maxf(0.0, size.x - _insets.x - _insets.z), maxf(0.0, size.y - _insets.y - _insets.w))


# 门禁 / 截图工具用：假装有刘海。null = 回到读真的。
func set_test_insets(value: Variant) -> void:
	_test = value
	_refresh()


# 让一个「用锚点 + 偏移摆放、父节点铺满整屏」的节点跟着安全区走。
#
# 每条边按它自己的锚点比例挪进安全区：锚在左边（0）的边右移左侧那段，锚在右边（1）的左移右侧那段，
# 居中（0.5）的挪两侧之差的一半。于是铺满全屏的内容根四边各缩进、贴右的按钮整体左移、居中的不动。
# 等于把它的父节点换成了安全区 —— 不用改任何一个子节点。
#
# 以调用这一刻的偏移为基准。页面之后自己再改这几个偏移的话，要重新 track 一次。
# 父节点不是铺满整屏的（或者是 Container 管着位置的）不要用它。
func track(node: Control) -> void:
	node.set_meta(META, Vector4(node.offset_left, node.offset_top, node.offset_right, node.offset_bottom))
	for ref in _tracked:
		if ref.get_ref() == node:
			_apply(node)
			return
	_tracked.append(weakref(node))
	_apply(node)


func _apply(node: Control) -> void:
	var base: Vector4 = node.get_meta(META)
	var l := _insets.x
	var t := _insets.y
	var r := _insets.z
	var b := _insets.w
	node.offset_left = base.x + l * (1.0 - node.anchor_left) - r * node.anchor_left
	node.offset_top = base.y + t * (1.0 - node.anchor_top) - b * node.anchor_top
	node.offset_right = base.z + l * (1.0 - node.anchor_right) - r * node.anchor_right
	node.offset_bottom = base.w + t * (1.0 - node.anchor_bottom) - b * node.anchor_bottom


func _refresh() -> void:
	var next := _measure()
	if next.is_equal_approx(_insets):
		return
	_insets = next
	var alive: Array[WeakRef] = []
	for ref in _tracked:
		var node := ref.get_ref() as Control
		if node != null and node.has_meta(META):
			_apply(node)
			alive.append(ref)
	_tracked = alive
	changed.emit()


func _measure() -> Vector4:
	var view := get_tree().root.get_visible_rect().size
	if _test != null:
		return _sane(_test as Vector4, view)
	if not OS.has_feature("mobile"):
		return Vector4.ZERO
	var safe := DisplayServer.get_display_safe_area()
	var win := DisplayServer.window_get_size()
	if safe.size.x <= 0 or safe.size.y <= 0 or win.x <= 0 or win.y <= 0:
		# 启动那一刻、切前台那一刻可能读到 0：沿用上一次的，别让按钮闪到边上。
		return _insets
	var sx := view.x / float(win.x)
	var sy := view.y / float(win.y)
	return _sane(Vector4(
		float(safe.position.x) * sx,
		float(safe.position.y) * sy,
		float(win.x - safe.end.x) * sx,
		float(win.y - safe.end.y) * sy), view)


# 负数当 0；任何一边超过三分之一当成读错了（宁可贴边，也不把界面挤没）。取整，免得小数抖动反复重排。
func _sane(value: Vector4, view: Vector2) -> Vector4:
	return Vector4(
		roundf(clampf(value.x, 0.0, view.x / 3.0)),
		roundf(clampf(value.y, 0.0, view.y / 3.0)),
		roundf(clampf(value.z, 0.0, view.x / 3.0)),
		roundf(clampf(value.w, 0.0, view.y / 3.0)))
