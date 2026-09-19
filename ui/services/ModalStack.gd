extends Node

# 全屏模态的唯一入口（V3 P0-07）。autoload。
#
# 要解决的是复审里「点了没反应」的一类具体成因：业务脚本各自 add_child 一个全屏
# ColorRect 当遮罩，关闭时忘了 queue_free 或只 hide()，于是屏幕上留着一块看不见
# 但 MOUSE_FILTER_STOP 的玻璃板，之后所有点击都被它吃掉。玩家看到的是「界面死了」。
#
# 所以这里把遮罩的所有权收走：调用方只交内容控件，遮罩由本类创建、由本类销毁。
# 规则：
#   1. 每个模态独占一个 CanvasLayer，层号按入栈顺序递增 —— 不依赖调用方设 z_index。
#   2. 只有栈顶的 backdrop 是 STOP，其余一律 IGNORE。栈顶那块本来就铺满全屏，
#      遮挡语义不变；这样即使某块遮罩泄漏了，它也不再是 STOP，吃不掉输入。
#   3. owner 被 free 时自动关掉它的模态 —— 页面切走不该留下弹窗。
#   4. 关闭同帧就把节点从树上摘掉，不等 queue_free 的下一帧。
#
# 不负责的事：动画、外观、按钮语义。那些在 GloryConfirmDialog 之类的组件里。

signal modal_opened(id: String)
signal modal_closed(id: String, reason: String)

const Tokens := preload("res://ui/theme/GloryTokens.gd")
# 9.17：弹窗音。这里是「全屏模态的唯一入口」，挂在这一处就覆盖了所有弹窗
# （DialogService 的确认框、宝物三选一、以及以后新增的任何模态）。
const SfxService := preload("res://ui/services/SfxService.gd")

const BASE_LAYER := 1000

# 关闭原因是给调用方和 IssueReport 看的，不要临时编新字符串。
const REASON_BACKDROP := "backdrop"
const REASON_BACK := "back"
const REASON_OWNER_FREED := "owner_freed"
const REASON_REPLACED := "replaced"
const REASON_CLOSED_ALL := "closed_all"
const REASON_PROGRAMMATIC := "programmatic"

var _entries: Array[Dictionary] = []
var _next_serial := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


# --- 入栈 / 出栈 ---------------------------------------------------------------

# opts:
#   id                   自定义 id；重复入栈同一 id 会被拒绝（返回空串），用于去重复点。
#   owner                Object。被 free 时自动关闭。
#   priority             int，越大越靠上。同优先级按入栈顺序。
#   dismiss_on_backdrop  bool，默认 false。危险确认不该点外面就消失。
#   backdrop_color       Color，默认 Tokens.BACKDROP。
#   popup_sfx            bool，默认 true。开模态时播一声弹窗音。
#                       调用方**自带**专属音效时置 false，否则两个音会叠在一起
#                       （宝物三选一就是这么用的：它有自己那条「进入选宝界面」）。
#
# 所有权：push 接管 content。成功时随模态一起销毁；被拒（重复 id）时立即 queue_free。
# 调用方不需要在失败分支自己收尾 —— 那是最容易漏掉、进而变成节点泄漏的地方。
func push(content: Control, opts: Dictionary = {}) -> String:
	if content == null or not is_instance_valid(content):
		push_error("ModalStack.push: content 为空")
		return ""
	var id := str(opts.get("id", ""))
	if id.is_empty():
		id = "modal_%d" % _next_serial
	if has(id):
		# 同 id 已在栈上：这是重复点击，不是新弹窗。
		content.queue_free()
		return ""
	_next_serial += 1

	# 只保留 instance id，不把 Object 引用放进 Dictionary。Node 被 free 后，
	# Dictionary 里的旧引用会变成 invalid instance；再把它赋给强类型 Object
	# 变量会在 is_instance_valid() 之前直接抛错，使自动清理永远到不了。
	var owner_obj = opts.get("owner", null)
	var owner_id := 0
	if owner_obj != null and is_instance_valid(owner_obj):
		owner_id = owner_obj.get_instance_id()
	var host := CanvasLayer.new()
	host.name = "Modal_%s" % id

	var root := Control.new()
	root.name = "ModalRoot"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.add_child(root)

	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = opts.get("backdrop_color", Tokens.BACKDROP)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(backdrop)

	root.add_child(content)

	var entry := {
		"id": id,
		"owner_id": owner_id,
		"priority": int(opts.get("priority", 0)),
		"serial": _next_serial,
		"host": host,
		"root": root,
		"backdrop": backdrop,
		"content": content,
		"dismiss_on_backdrop": bool(opts.get("dismiss_on_backdrop", false)),
	}
	_entries.append(entry)
	_entries.sort_custom(_by_priority_then_serial)

	backdrop.gui_input.connect(_on_backdrop_input.bind(id))
	_attach(host)
	_reindex()
	# 只在真的推上去了之后才响。上面「同 id 已在栈上」那条早退是重复点击，
	# 不是新弹窗，在那里响就是连点响一串。
	if bool(opts.get("popup_sfx", true)):
		SfxService.play(SfxService.CUE_UI_POPUP)
	modal_opened.emit(id)
	return id


# 从别的节点的 _ready() 里开弹窗是正常用法（教程、主菜单都会），但那一刻 root 可能
# 正在 setup children，直接 add_child 会被引擎拒绝并打一条 ERROR —— 弹窗于是不在树上，
# 而调用方拿到的却是成功的 id。所以这里判一次，必要时推迟到本帧末。
func _attach(host: CanvasLayer) -> void:
	var root_node := get_tree().root
	if root_node.is_node_ready():
		root_node.add_child(host)
	else:
		root_node.add_child.call_deferred(host)


func pop(id: String, reason: String = REASON_PROGRAMMATIC) -> bool:
	var idx := _index_of(id)
	if idx < 0:
		return false
	var entry: Dictionary = _entries[idx]
	_entries.remove_at(idx)
	_teardown(entry)
	_reindex()
	modal_closed.emit(id, reason)
	return true


func close_top(reason: String = REASON_PROGRAMMATIC) -> bool:
	if _entries.is_empty():
		return false
	return pop(str(_entries[_entries.size() - 1].get("id", "")), reason)


func replace(id: String, content: Control, opts: Dictionary = {}) -> String:
	pop(id, REASON_REPLACED)
	return push(content, opts)


func close_all_for_owner(owner_obj: Object, reason: String = REASON_OWNER_FREED) -> int:
	if owner_obj == null or not is_instance_valid(owner_obj):
		return 0
	var want := owner_obj.get_instance_id()
	var closed := 0
	for entry in _entries.duplicate():
		if int(entry.get("owner_id", 0)) == want:
			if pop(str(entry.get("id", "")), reason):
				closed += 1
	return closed


func close_all(reason: String = REASON_CLOSED_ALL) -> int:
	var closed := 0
	while not _entries.is_empty():
		if not close_top(reason):
			break
		closed += 1
	return closed


# Android 返回键 / ui_cancel 的接入点（V3 P0-09 会调它）。
# 返回 true 表示「这一下被模态消费了」，调用方不应再继续退页面。
func handle_back_request() -> bool:
	return close_top(REASON_BACK)


# --- 查询 ---------------------------------------------------------------------

func depth() -> int:
	return _entries.size()


func has(id: String) -> bool:
	return _index_of(id) >= 0


func top() -> Dictionary:
	if _entries.is_empty():
		return {}
	return _entries[_entries.size() - 1]


func top_id() -> String:
	return str(top().get("id", ""))


# 排障用：点击没反应时先看这里，再看泄漏扫描。
func dump_modal_stack() -> Array:
	var out: Array = []
	for i in _entries.size():
		var e: Dictionary = _entries[i]
		var content: Object = e.get("content", null)
		var owner_id := int(e.get("owner_id", 0))
		var host: CanvasLayer = e.get("host", null)
		out.append({
			"index": i,
			"id": str(e.get("id", "")),
			"priority": int(e.get("priority", 0)),
			"is_top": i == _entries.size() - 1,
			# 记在栈上但没进树 = 弹窗其实没显示出来。排障时先看这一列。
			"in_tree": host != null and is_instance_valid(host) and host.is_inside_tree(),
			"owner_valid": owner_id != 0 and is_instance_id_valid(owner_id),
			"backdrop_filter": _filter_name(e.get("backdrop", null)),
			"content": "" if content == null or not is_instance_valid(content) else str(content.name),
		})
	return out


# 泄漏检测：树上不该存在「看不见却仍然 STOP」的控件。
# ui_component_check 与排障都调它，所以放在这里而不是各写一份。
func find_invisible_stop_controls() -> Array:
	var out: Array = []
	var tree := get_tree()
	if tree == null or tree.root == null:
		return out
	_scan_stop(tree.root, out)
	return out


# --- 内部 ---------------------------------------------------------------------

func _process(_delta: float) -> void:
	# owner 被 free 掉而没人通知我们时兜底。每帧只扫栈内几项，代价可忽略。
	if _entries.is_empty():
		return
	for entry in _entries.duplicate():
		var owner_id := int(entry.get("owner_id", 0))
		if owner_id != 0 and not is_instance_id_valid(owner_id):
			pop(str(entry.get("id", "")), REASON_OWNER_FREED)


func _index_of(id: String) -> int:
	for i in _entries.size():
		if str(_entries[i].get("id", "")) == id:
			return i
	return -1


func _by_priority_then_serial(a: Dictionary, b: Dictionary) -> bool:
	var pa := int(a.get("priority", 0))
	var pb := int(b.get("priority", 0))
	if pa != pb:
		return pa < pb
	return int(a.get("serial", 0)) < int(b.get("serial", 0))


# 层号和 backdrop 的输入归属都只在这里改，避免两处状态各走各的。
func _reindex() -> void:
	for i in _entries.size():
		var entry: Dictionary = _entries[i]
		var host: CanvasLayer = entry.get("host", null)
		if host != null and is_instance_valid(host):
			host.layer = BASE_LAYER + i
		var backdrop: ColorRect = entry.get("backdrop", null)
		if backdrop != null and is_instance_valid(backdrop):
			backdrop.mouse_filter = (Control.MOUSE_FILTER_STOP
				if i == _entries.size() - 1
				else Control.MOUSE_FILTER_IGNORE)


func _teardown(entry: Dictionary) -> void:
	var host: CanvasLayer = entry.get("host", null)
	if host == null or not is_instance_valid(host):
		return
	# 先摘树再 queue_free：只 queue_free 的话这一帧剩下的输入仍会打到它身上。
	var parent := host.get_parent()
	if parent != null:
		parent.remove_child(host)
	host.queue_free()


func _on_backdrop_input(event: InputEvent, id: String) -> void:
	if not _is_primary_release(event):
		return
	var idx := _index_of(id)
	if idx < 0 or idx != _entries.size() - 1:
		return
	if not bool(_entries[idx].get("dismiss_on_backdrop", false)):
		return
	pop(id, REASON_BACKDROP)


# 鼠标与触摸只认一次：同一下点击在桌面会同时来 MouseButton 和 ScreenTouch，
# 两条都处理就会把两层模态一次关掉（V3 P0-07 第 4 条）。
func _is_primary_release(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		return mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		return st.index == 0 and not st.pressed and not _mouse_emulated()
	return false


func _mouse_emulated() -> bool:
	return bool(ProjectSettings.get_setting("input_devices/pointing/emulate_mouse_from_touch", true))


func _scan_stop(node: Node, out: Array) -> void:
	if node is Control:
		var c := node as Control
		if c.mouse_filter == Control.MOUSE_FILTER_STOP and not c.is_visible_in_tree():
			out.append(str(c.get_path()))
	for child in node.get_children():
		_scan_stop(child, out)


func _filter_name(control: Object) -> String:
	if control == null or not is_instance_valid(control) or not (control is Control):
		return "gone"
	match (control as Control).mouse_filter:
		Control.MOUSE_FILTER_STOP:
			return "STOP"
		Control.MOUSE_FILTER_PASS:
			return "PASS"
		_:
			return "IGNORE"
