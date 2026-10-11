extends RefCounted
## Reversible UI rules, including nodes created after the hotfix was received.

var root: Node
var valid := true
var _rules: Array[Dictionary] = []
var _originals: Array[Dictionary] = []
var _seen: Dictionary = {}
const UI_PROPERTIES := ["visible", "position", "size", "scale", "rotation", "modulate",
	"self_modulate", "offset_left", "offset_top", "offset_right", "offset_bottom",
	"anchor_left", "anchor_top", "anchor_right", "anchor_bottom", "custom_minimum_size",
	"disabled", "text", "tooltip_text", "mouse_filter"]


func set_node_property(pattern: String, property: String, value: Variant) -> bool:
	if not pattern.begins_with("/root/") or not property in UI_PROPERTIES:
		valid = false
		return false
	_rules.append({"pattern": pattern, "property": property, "value": value})
	return true


func apply_to(node: Node) -> void:
	if not node is Control:
		return
	for rule in _rules:
		if not str(node.get_path()).match(rule.pattern):
			continue
		var found := false
		for info in node.get_property_list():
			if info.name == rule.property:
				if typeof(rule.value) != int(info.type):
					valid = false
					return
				found = true
				break
		if not found:
			valid = false
			continue
		var key := str(node.get_instance_id()) + ":" + str(rule.property)
		if not _seen.has(key):
			_seen[key] = true
			_originals.append({"node": weakref(node), "property": rule.property, "value": node.get(rule.property)})
		node.set(rule.property, rule.value)


func apply_tree() -> void:
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		apply_to(node)
		pending.append_array(node.get_children())


func revert() -> void:
	_originals.reverse()
	for saved in _originals:
		var node: Node = saved.node.get_ref()
		if is_instance_valid(node):
			node.set(saved.property, saved.value)
	_originals.clear()
	_seen.clear()
	_rules.clear()
