extends RefCounted
## Trusted server GDScript uses this journal to change live data reversibly.

var root: Node
var valid := true
var _undo: Array[Callable] = []


func table(key: String) -> Variant:
	var registry := root.get_node_or_null("DataRegistry")
	if registry == null:
		valid = false
		return {}
	return registry.call("get_table", key)


func replace_item(target: Dictionary, key: Variant, value: Variant) -> bool:
	var present := target.has(key)
	var previous: Variant = target.get(key)
	_undo.append(func():
		if present:
			target[key] = previous
		else:
			target.erase(key))
	target[key] = value
	return true


func replace_property(target: Object, property: String, value: Variant) -> bool:
	if not is_instance_valid(target):
		valid = false
		return false
	var found := false
	for info in target.get_property_list():
		if info.name == property:
			found = true
			break
	if not found:
		valid = false
		return false
	var previous: Variant = target.get(property)
	var reference: WeakRef = weakref(target)
	_undo.append(func():
		var original: Object = reference.get_ref()
		if is_instance_valid(original):
			original.set(property, previous))
	target.set(property, value)
	return true


func apply_tree() -> void:
	pass


func apply_to(_node: Node) -> void:
	pass


func revert() -> void:
	_undo.reverse()
	for operation in _undo:
		operation.call()
	_undo.clear()
