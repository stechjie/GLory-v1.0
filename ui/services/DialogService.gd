extends Node

# 业务层唯一的弹窗入口（V3 P1-03）。autoload。
#
# 存在的理由：复审时弹窗有三种写法 —— TutorialMode 现场拼 ColorRect，MainMenu 用
# Godot 默认 AcceptDialog，重连/宝藏各自另写。三者外观、输入语义、关闭时机都不同，
# 所以「统一确认框」不能只做一个漂亮组件，还得把调用点收到一个函数后面。
#
# 业务层只写：
#   DialogService.confirm({ "body": "...", "on_result": _on_result })
# 不碰节点、不碰 Theme、不碰 ModalStack。

signal dialog_resolved(request_id: String, result: String)

const DIALOG_SCENE := preload("res://ui/components/GloryConfirmDialog.tscn")
const Dialog := preload("res://ui/components/GloryConfirmDialog.gd")

const MODAL_PRIORITY := 100

# request_id -> { "modal_id": String, "on_result": Callable }
var _pending: Dictionary = {}
var _serial := 0


func _ready() -> void:
	# backdrop、Back、owner 释放和 close_all 都可以绕过本服务直接关掉模态。
	# 统一监听唯一出口，避免 ModalStack 已经空了而 _pending 永久残留。
	if not ModalStack.modal_closed.is_connected(_on_modal_closed):
		ModalStack.modal_closed.connect(_on_modal_closed)


# spec:
#   title / body     已本地化的最终文案
#   intent           GloryConfirmDialog.Intent，默认 NORMAL
#   confirm_text / cancel_text
#   owner            Object；被 free 时弹窗自动关闭
#   request_id       不给就自动生成。**同一 id 重复调用不会开第二个框**
#   on_result        Callable(result: String, request_id: String)
# 返回 request_id。
func confirm(spec: Dictionary) -> String:
	var request_id := str(spec.get("request_id", ""))
	if request_id.is_empty():
		_serial += 1
		request_id = "dlg_%d" % _serial
	# 重复请求合并：连点「跳过教学」不该叠出两个框。
	if _pending.has(request_id):
		return request_id

	var dialog: Control = DIALOG_SCENE.instantiate()
	dialog.resolved.connect(_on_dialog_resolved)

	var modal_id := ModalStack.push(dialog, {
		"id": "dialog_%s" % request_id,
		"owner": spec.get("owner", null),
		"priority": int(spec.get("priority", MODAL_PRIORITY)),
		# 危险确认点外面不消失：玩家需要明确选一边。
		"dismiss_on_backdrop": int(spec.get("intent", Dialog.Intent.NORMAL)) == Dialog.Intent.INFO,
	})
	if modal_id.is_empty():
		# push 被拒时已经把 dialog 收掉了（见 ModalStack.push 的所有权说明），
		# 这里不能再 free 一次。
		return request_id

	_pending[request_id] = {
		"modal_id": modal_id,
		"on_result": spec.get("on_result", Callable()),
	}
	# push 之后再 configure：configure 会起入场动画，需要节点已在树上。
	dialog.configure({
		"title": spec.get("title", ""),
		"body": spec.get("body", ""),
		"intent": spec.get("intent", Dialog.Intent.NORMAL),
		"confirm_text": spec.get("confirm_text", "确定"),
		"cancel_text": spec.get("cancel_text", "取消"),
		"request_id": request_id,
	})
	return request_id


# 只有一个「知道了」的提示框。取代 MainMenu 的 AcceptDialog。
func info(spec: Dictionary) -> String:
	var merged := spec.duplicate()
	merged["intent"] = Dialog.Intent.INFO
	merged["confirm_text"] = spec.get("confirm_text", "知道了")
	return confirm(merged)


func is_open(request_id: String) -> bool:
	return _pending.has(request_id)


func open_count() -> int:
	return _pending.size()


# 外部主动收掉（页面切换、动作已完成）。走 dismissed，不冒充玩家的选择。
func close(request_id: String) -> bool:
	if not _pending.has(request_id):
		return false
	# 先移出 pending，ModalStack.pop 发 modal_closed 时就不会重复结算。
	var entry := _take_pending(request_id)
	var modal_id := str(entry.get("modal_id", ""))
	ModalStack.pop(modal_id, ModalStack.REASON_PROGRAMMATIC)
	_emit_result(request_id, Dialog.RESULT_DISMISSED, entry)
	return true


func _on_dialog_resolved(result: String, request_id: String) -> void:
	if not _pending.has(request_id):
		return
	# resolved 与 modal_closed 会在同一调用栈里先后出现。先移出 pending，
	# 保证 modal_closed 监听器不会把 confirmed/cancelled 改成 dismissed。
	var entry := _take_pending(request_id)
	var modal_id := str(entry.get("modal_id", ""))
	# 先摘框再回调：回调里可能立刻开下一个框或切场景，
	# 那时这一个必须已经离开栈顶，否则新框会被压在下面。
	ModalStack.pop(modal_id, result)
	_emit_result(request_id, result, entry)


func _on_modal_closed(modal_id: String, _reason: String) -> void:
	var request_id := ""
	for key in _pending.keys():
		var entry: Dictionary = _pending.get(key, {})
		if str(entry.get("modal_id", "")) == modal_id:
			request_id = str(key)
			break
	if not request_id.is_empty():
		_finish(request_id, Dialog.RESULT_DISMISSED)


func _finish(request_id: String, result: String) -> void:
	if not _pending.has(request_id):
		return
	var entry := _take_pending(request_id)
	_emit_result(request_id, result, entry)


func _take_pending(request_id: String) -> Dictionary:
	var entry: Dictionary = _pending.get(request_id, {})
	_pending.erase(request_id)
	return entry


func _emit_result(request_id: String, result: String, entry: Dictionary) -> void:
	var cb: Callable = entry.get("on_result", Callable())
	if cb.is_valid():
		cb.call(result, request_id)
	dialog_resolved.emit(request_id, result)
