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


# 交还一具**特定的**尸体时用这个，不要用 unregister_actor()。
#
# 召唤物会用同一个 uid 反复重生：镜像领主的 enemy_mirror_1/2/3 在上一具尸体的死亡
# 动画还没播完时就已经重新召唤，新 actor 注册到了同一个 uid 上。此时按 uid 无条件
# 注销，抹掉的是**活着的那一个**，它随后的死亡会被 Director 判成 missing_actor:source
# 丢弃 —— 玩家看到镜像凭空消失。固定第 20 回合因此丢过 3 条死亡演出。
#
# 规则放在注册表里而不是调用方，是因为调用方拿不到"注册表现在存的是谁"这个信息就
# 会想当然地按 uid 删；这里能拿到，也就不该让每个调用方各自记得做这件事。
func unregister_if_holds(uid: String, actor: Node3D) -> bool:
	if actor == null:
		return false
	if _actors.get(uid) != actor:
		return false
	_actors.erase(uid)
	return true


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
