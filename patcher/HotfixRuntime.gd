extends Node
## Full snapshots replace the effective set; never replay incremental commands.

const Context = preload("res://patcher/HotfixContext.gd")
var _active: Array[Dictionary] = []
var context_script: Script = Context


func _ready() -> void:
	get_tree().node_added.connect(_node_added)


func _node_added(node: Node) -> void:
	_apply_new_node.call_deferred(weakref(node))


func _apply_new_node(reference: WeakRef) -> void:
	var node: Node = reference.get_ref()
	if not is_instance_valid(node) or not node.is_inside_tree():
		return
	for item in _active:
		item.context.apply_to(node)


func replace(items: Array) -> bool:
	if items.size() > 12:
		return false
	var prepared: Array[Dictionary] = []
	var ids: Dictionary = {}
	for item in items:
		if not item is Dictionary or not item.get("source") is String:
			return false
		var source: String = item.source
		var ident := str(item.get("hotfix_id", ""))
		if ident.is_empty() or ids.has(ident) or source.to_utf8_buffer().size() > 131072:
			return false
		ids[ident] = true
		if source.sha256_text() != str(item.get("sha256", "")):
			return false
		var script := GDScript.new()
		script.source_code = source
		if script.reload() != OK or script.get_instance_base_type() != "RefCounted":
			return false
		prepared.append({"hotfix_id": ident, "source": source, "sha256": item.sha256, "script": script})
	var unchanged := prepared.size() == _active.size()
	if unchanged:
		for index in range(prepared.size()):
			if prepared[index].sha256 != _active[index].sha256 or prepared[index].hotfix_id != _active[index].hotfix_id:
				unchanged = false
				break
	if unchanged:
		return true
	var previous := _active.duplicate()
	clear()
	if _install(prepared):
		return true
	clear()
	if not _install(previous):
		clear()
	return false


func _install(items: Array[Dictionary]) -> bool:
	for item in items:
		var instance = item.script.new()
		if instance == null or not instance.has_method("apply"):
			return false
		var context = context_script.new()
		context.root = get_tree().root
		var result = instance.call("apply", context)
		if result != true or not context.valid:
			context.revert()
			return false
		context.apply_tree()
		if not context.valid:
			context.revert()
			return false
		_active.append({"hotfix_id": item.hotfix_id, "sha256": item.sha256,
			"source": item.source, "script": item.script, "instance": instance, "context": context})
	return true


func clear() -> void:
	_active.reverse()
	for item in _active:
		item.context.revert()
	_active.clear()


func _exit_tree() -> void:
	clear()
