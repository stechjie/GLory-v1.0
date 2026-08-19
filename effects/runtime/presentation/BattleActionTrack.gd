extends RefCounted

# One deterministic presentation queue per simulation source uid. The track is
# pure data: it never touches actors, scene nodes, combat state, or wall-clock
# time. BattlePresentationDirector owns all adapter calls and lifecycle changes.

const ATTACK_EVENT_TYPES := {
	"attack_start": true,
	"projectile_spawn": true,
	"impact": true,
}

var source_uid: String

var _active: Dictionary = {}
var _pending: Array[Dictionary] = []
var _source_dead := false
var _disposed := false


func _init(p_source_uid: String) -> void:
	source_uid = p_source_uid


func enqueue(event: Dictionary) -> bool:
	if _disposed:
		return false
	if _source_dead and is_attack_event(event):
		return false
	_pending.append(event.duplicate(true))
	return true


func take_next() -> Dictionary:
	if _disposed or not _active.is_empty() or _pending.is_empty():
		return {}
	_active = _pending.pop_front()
	return _active


func complete_active(event_key: String) -> Dictionary:
	if _active.is_empty() or str(_active.get("event_key", "")) != event_key:
		return {}
	var completed := _active
	_active = {}
	return completed


func mark_source_dead() -> Array[Dictionary]:
	_source_dead = true
	return cancel_pending_attacks()


func cancel_pending_attacks() -> Array[Dictionary]:
	var cancelled: Array[Dictionary] = []
	var kept: Array[Dictionary] = []
	for event in _pending:
		if is_attack_event(event):
			cancelled.append(event)
		else:
			kept.append(event)
	_pending = kept
	return cancelled


func cancel_all() -> Array[Dictionary]:
	var cancelled: Array[Dictionary] = []
	if not _active.is_empty():
		cancelled.append(_active)
	for event in _pending:
		cancelled.append(event)
	_active = {}
	_pending.clear()
	return cancelled


func reset_for_seek() -> Array[Dictionary]:
	var cancelled := cancel_all()
	_source_dead = false
	return cancelled


func dispose() -> Array[Dictionary]:
	var cancelled := cancel_all()
	_disposed = true
	_source_dead = false
	return cancelled


func has_active() -> bool:
	return not _active.is_empty()


func active_event() -> Dictionary:
	return _active


func pending_events() -> Array[Dictionary]:
	return _pending


func pending_count() -> int:
	return _pending.size()


func is_empty() -> bool:
	return _active.is_empty() and _pending.is_empty()


static func is_attack_event(event: Dictionary) -> bool:
	return ATTACK_EVENT_TYPES.has(str(event.get("type", "")))
