class_name UnitActorRegistry
extends RefCounted

const REQUIRED_NODES := ["ActorRoot", "FootAnchor", "HeadAnchor", "CastAnchor", "HitAnchor", "Shadow"]

var _actors: Dictionary = {}


func register_actor(uid: String, actor: Node3D) -> bool:
	if uid.is_empty() or actor == null or not is_instance_valid(actor):
		return false
	if not has_complete_contract(actor):
		return false
	_actors[uid] = actor
	return true


func unregister_actor(uid: String) -> void:
	_actors.erase(uid)


func get_actor(uid: String) -> Node3D:
	var value = _actors.get(uid)
	if value is Node3D and is_instance_valid(value):
		return value as Node3D
	_actors.erase(uid)
	return null


func get_anchor(uid: String, anchor_name: String) -> Node3D:
	var actor := get_actor(uid)
	if actor == null:
		return null
	var canonical := anchor_name
	if canonical == "FeetAnchor":
		canonical = "FootAnchor"
	elif canonical == "BodyAnchor":
		canonical = "HitAnchor"
	var node := actor.get_node_or_null(canonical)
	return node as Node3D if node is Node3D else null


func clear() -> void:
	_actors.clear()


func size() -> int:
	return _actors.size()


func ids() -> Array:
	return _actors.keys()


static func has_complete_contract(actor: Node3D) -> bool:
	if actor == null or not is_instance_valid(actor):
		return false
	for node_name in REQUIRED_NODES:
		if actor.get_node_or_null(node_name) == null:
			return false
	return true
