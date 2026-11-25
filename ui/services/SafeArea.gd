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
#   iOS：项目引擎将 GodotView 放在连续可用区域内；DisplayServer 返回该 view 本地像素。
#     drawable、window_get_size、触点共用同一 view，不能再次按整块屏幕扣除半屏。
#   安卓：保持现有全屏窗口像素路径；这里不改 edge-to-edge 策略。
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
# iOS 在尺寸通知时立即刷新并逐帧测量；其他平台每 POLL_SEC 秒量一次。只有几何改变才发 changed。

signal changed
# 编辑可用区域独立于游戏安全区：键盘不推动整盘棋和其他页面。
signal editing_changed

const POLL_SEC := 0.25
const FLAG := "--safe-area="
const META := &"safe_area_base_offsets"

var _insets := Vector4.ZERO   # 左、上、右、下
var _test: Variant = null     # 测试用的假安全区（Vector4），null = 读真的
var _poll := 0.0
var _tracked: Array[WeakRef] = []
var _ios_test_geometry: Variant = null  # 明确注入 iOS 几何策略；不伪装 OS / 插件。
var _geometry_size := Vector2(-1, -1)
var _window_pixels := Vector2(-1, -1)
var _ios_safe_rect := Rect2()
var _keyboard_height := 0.0  # 根视口逻辑单位，仅停靠键盘与当前 GodotView 的底部交集。


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
	if uses_ios_layout():
		_connect_ios_resize()
	_refresh()


func _process(delta: float) -> void:
	if uses_ios_layout():
		# 原生布局/键盘会在开合动画中更新；只在测量改变时发信号，不逐帧重建 UI。
		_refresh()
		return
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
	if uses_ios_layout() and _test == null:
		return _ios_safe_rect
	var size := _view_size()
	return Rect2(_insets.x, _insets.y,
		maxf(0.0, size.x - _insets.x - _insets.z), maxf(0.0, size.y - _insets.y - _insets.w))


# 门禁 / 截图工具用：假装有刘海。null = 回到读真的。
func set_test_insets(value: Variant) -> void:
	_test = value
	_refresh()


# iOS 专用策略开关；桌面门禁仅通过具名测试入口注入几何，不修改 OS / feature。
func uses_ios_layout() -> bool:
	return OS.get_name() == "iOS" or _ios_test_geometry != null


func set_test_ios_geometry(value: Variant) -> void:
	assert(value == null or value is Dictionary, "iOS geometry must be a Dictionary or null")
	_ios_test_geometry = value
	if uses_ios_layout() and is_inside_tree():
		_connect_ios_resize()
	_refresh()


func _view_size() -> Vector2:
	if _ios_test_geometry != null:
		return Vector2((_ios_test_geometry as Dictionary).get("view_size", get_tree().root.get_visible_rect().size))
	return get_tree().root.get_visible_rect().size


func _ios_pixel_size() -> Vector2:
	if _ios_test_geometry != null:
		return Vector2((_ios_test_geometry as Dictionary).get("window_size", DisplayServer.window_get_size()))
	return Vector2(DisplayServer.window_get_size())


func _connect_ios_resize() -> void:
	var root := get_tree().root
	if not root.size_changed.is_connected(_on_ios_size_changed):
		root.size_changed.connect(_on_ios_size_changed)


func _on_ios_size_changed() -> void:
	if not uses_ios_layout():
		return
	_refresh()
	# Window 的通知可能早于 canvas_items 的伸缩刷新，再读一次本帧最终几何。
	_refresh.call_deferred()


# 当前焦点属于指定表单时才避让停靠键盘；不改全局 insets，不清草稿或重设焦点。
func editing_rect(owner: Node) -> Rect2:
	var safe := rect()
	if not uses_ios_layout() or owner == null or not owner.is_inside_tree():
		return safe
	var focus := owner.get_viewport().gui_get_focus_owner()
	if not (focus is LineEdit or focus is TextEdit):
		return safe
	if focus != owner and not owner.is_ancestor_of(focus):
		return safe
	return ios_editing_rect(safe, _view_size(), _keyboard_height)


static func ios_editing_rect(safe: Rect2, view: Vector2, keyboard_height: float) -> Rect2:
	var bottom := minf(safe.end.y, view.y - clampf(keyboard_height, 0.0, view.y))
	return Rect2(safe.position, Vector2(safe.size.x, maxf(0.0, bottom - safe.position.y)))


# 只在几何/焦点变化后调用。已有字段可见时不抢用户滚动，布局期间不触碰输入值或选区。
func reveal_ios_focus(scroll: ScrollContainer) -> void:
	if not uses_ios_layout() or not is_instance_valid(scroll) or not scroll.is_inside_tree():
		return
	var focus := scroll.get_viewport().gui_get_focus_owner()
	if not (focus is LineEdit or focus is TextEdit) or not scroll.is_ancestor_of(focus):
		return
	var visible := scroll.get_global_rect().intersection(editing_rect(scroll))
	if visible.has_area() and not visible.encloses(focus.get_global_rect()):
		scroll.ensure_control_visible(focus)


# 项目引擎返回 GodotView-local pixels。先在物理像素中向内取整，再映射到逻辑坐标；
# 不限制到三分之一，也不将真实空区域扩成全屏。无效/未就绪数据与 valid empty 分开。
static func map_ios_safe_area(safe: Rect2, pixels: Vector2, view: Vector2) -> Dictionary:
	if not pixels.is_finite() or not view.is_finite() or not safe.position.is_finite() or not safe.size.is_finite():
		return {"valid": false}
	if pixels.x <= 0.0 or pixels.y <= 0.0 or view.x <= 0.0 or view.y <= 0.0 or safe.size.x < 0.0 or safe.size.y < 0.0:
		return {"valid": false}
	var left := clampf(ceilf(safe.position.x), 0.0, pixels.x)
	var top := clampf(ceilf(safe.position.y), 0.0, pixels.y)
	var right := maxf(left, clampf(floorf(safe.end.x), 0.0, pixels.x))
	var bottom := maxf(top, clampf(floorf(safe.end.y), 0.0, pixels.y))
	var scale := view / pixels
	return {"valid": true, "rect": Rect2(Vector2(left, top) * scale, Vector2(right - left, bottom - top) * scale),
		"insets": Vector4(left * scale.x, top * scale.y,
		(pixels.x - right) * scale.x, (pixels.y - bottom) * scale.y)}


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
	if not is_inside_tree():
		return
	var next := _measure()
	var geometry_changed := false
	var keyboard_changed := false
	if uses_ios_layout():
		var view := _view_size()
		var pixels := _ios_pixel_size()
		geometry_changed = not view.is_equal_approx(_geometry_size) or not pixels.is_equal_approx(_window_pixels)
		_geometry_size = view
		_window_pixels = pixels
		var height := 0.0
		if _ios_test_geometry != null:
			height = float((_ios_test_geometry as Dictionary).get("keyboard_height", 0.0))
		else:
			height = float(DisplayServer.virtual_keyboard_get_height())
		var logical_height := _keyboard_height
		if is_finite(height) and pixels.y > 0.0 and view.y > 0.0:
			logical_height = clampf(ceilf(height), 0.0, pixels.y) * view.y / pixels.y
		keyboard_changed = not is_equal_approx(logical_height, _keyboard_height)
		_keyboard_height = logical_height
	var safe_changed := not next.is_equal_approx(_insets)
	if not safe_changed and not geometry_changed:
		if keyboard_changed:
			editing_changed.emit()
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
	if uses_ios_layout():
		editing_changed.emit()


func _measure() -> Vector4:
	var view := _view_size()
	if _test != null:
		return _sane(_test as Vector4, view)
	if uses_ios_layout():
		var safe := Rect2(DisplayServer.get_display_safe_area())
		if _ios_test_geometry != null:
			safe = Rect2((_ios_test_geometry as Dictionary).get("safe_rect", Rect2(Vector2.ZERO, _ios_pixel_size())))
		var mapped := map_ios_safe_area(safe, _ios_pixel_size(), view)
		if bool(mapped.get("valid", false)):
			_ios_safe_rect = mapped["rect"] as Rect2
			return mapped["insets"] as Vector4
		if not view.is_equal_approx(_geometry_size):
			_ios_safe_rect = Rect2()  # 新尺寸尚未就绪，不能继续暴露旧窗口的交互区域。
			return Vector4(0, 0, view.x, view.y)
		return _insets
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
