extends Node

# Unified lifecycle for user-triggered asynchronous work (V3 P0-05).
#
# Business code owns the actual operation; this service owns request identity,
# duplicate suppression, timeout/cancel policy, stale-result rejection and the
# small privacy-safe trail included in IssueReport.

signal action_state_changed(action: String, request_id: String, state: String, snapshot: Dictionary)
signal action_resolved(action: String, request_id: String, state: String, snapshot: Dictionary)

const Breadcrumb := preload("res://scripts/telemetry/InputBreadcrumb.gd")

const STATE_IDLE := "idle"
const STATE_PRESSED := "pressed"
const STATE_PENDING := "pending"
const STATE_SUCCEEDED := "succeeded"
const STATE_FAILED := "failed"
const STATE_CANCELLED := "cancelled"
const STATE_TIMED_OUT := "timed_out"

const ACTIVE_STATES := [STATE_PRESSED, STATE_PENDING]
const TERMINAL_STATES := [STATE_SUCCEEDED, STATE_FAILED, STATE_CANCELLED, STATE_TIMED_OUT]
const DEFAULT_TIMEOUT_MSEC := 30000
const BREADCRUMB_KEEP := 32
const HISTORY_KEEP := 16

var _actions: Dictionary = {} # action category -> current entry
var _breadcrumbs: Array[Dictionary] = []
var _history: Array[Dictionary] = []
var _serial := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	poll()


# Records touch/button-down before the business callback runs. It intentionally
# has no request id yet; begin() supplies action_accepted for the paired request.
func record_input_received(action: String, control_id: String = "") -> void:
	_record_breadcrumb(action, "", 0, "input_received", {"control_id": control_id})
	_record_breadcrumb(action, "", 0, "control_hit", {"control_id": control_id})


# spec: request_id, timeout_msec, cancellable, cancel_reason, owner, control_id.
# Duplicate begin calls while PRESSED/PENDING return the existing request id and
# never emit a second accepted transition.
func begin(action: String, spec: Dictionary = {}) -> String:
	var category := action.strip_edges()
	if category.is_empty():
		return ""
	if _actions.has(category):
		var current: Dictionary = _actions[category]
		if ACTIVE_STATES.has(str(current.get("state", STATE_IDLE))):
			_record_breadcrumb(category, str(current.get("request_id", "")),
				int(current.get("started_at_ms", 0)), "action_rejected", {
					"reason": "duplicate_pending",
					"state": str(current.get("state", "")),
					"control_id": str(spec.get("control_id", "")),
				})
			return str(current.get("request_id", ""))

	_serial += 1
	var now := int(Time.get_ticks_msec())
	var request_id := str(spec.get("request_id", ""))
	if request_id.is_empty():
		request_id = "act_%d_%d" % [_serial, now]
	var timeout_msec := maxi(1, int(spec.get("timeout_msec", DEFAULT_TIMEOUT_MSEC)))
	var owner_obj: Object = spec.get("owner", null)
	var entry := {
		"action": category,
		"request_id": request_id,
		"state": STATE_PRESSED,
		"started_at_ms": now,
		"updated_at_ms": now,
		"deadline_ms": now + timeout_msec,
		"timeout_msec": timeout_msec,
		"cancellable": bool(spec.get("cancellable", false)),
		"cancel_reason": str(spec.get("cancel_reason", "")),
		"stage": str(spec.get("stage", "")),
		"progress": -1.0,
		"error_code": "",
		"retryable": false,
		"_owner_ref": weakref(owner_obj) if owner_obj != null else null,
	}
	_actions[category] = entry
	_record_breadcrumb(category, request_id, now, "action_accepted", {
		"state": STATE_PRESSED,
		"control_id": str(spec.get("control_id", "")),
	})
	_emit_changed(entry)
	return request_id


func mark_pending(request_id: String) -> bool:
	return _transition_active(request_id, STATE_PENDING)


func succeed(request_id: String) -> bool:
	return _resolve(request_id, STATE_SUCCEEDED, {})


func fail(request_id: String, error_code: String, retryable: bool = true) -> bool:
	return _resolve(request_id, STATE_FAILED, {
		"error_code": error_code,
		"retryable": retryable,
	})


func cancel(request_id: String, reason: String = "user_cancelled", force: bool = false) -> bool:
	var found := _find_by_request(request_id)
	if found.is_empty():
		_record_breadcrumb("unknown", request_id, 0, "action_rejected", {"reason": "stale_cancel"})
		return false
	var entry: Dictionary = found["entry"]
	if not force and not bool(entry.get("cancellable", false)):
		_record_breadcrumb(str(entry.get("action", "")), request_id,
			int(entry.get("started_at_ms", 0)), "action_rejected", {
				"reason": "not_cancellable",
				"state": str(entry.get("state", "")),
			})
		return false
	return _resolve(request_id, STATE_CANCELLED, {"reason": reason})


func set_cancellable(request_id: String, value: bool, reason: String = "") -> bool:
	var found := _find_by_request(request_id)
	if found.is_empty():
		return false
	var entry: Dictionary = found["entry"]
	if not ACTIVE_STATES.has(str(entry.get("state", ""))):
		return false
	entry["cancellable"] = value
	entry["cancel_reason"] = reason
	entry["updated_at_ms"] = int(Time.get_ticks_msec())
	_actions[str(found["action"])] = entry
	_emit_changed(entry)
	return true


# Only report-safe fields are accepted. Player text, coordinates and network
# identifiers cannot accidentally leak into IssueReport through this API.
func update_context(request_id: String, patch: Dictionary) -> bool:
	var found := _find_by_request(request_id)
	if found.is_empty():
		return false
	var entry: Dictionary = found["entry"]
	if not ACTIVE_STATES.has(str(entry.get("state", ""))):
		return false
	if patch.has("stage"):
		entry["stage"] = str(patch["stage"])
	if patch.has("progress"):
		var incoming := float(patch["progress"])
		if incoming < 0.0:
			entry["progress"] = -1.0
		else:
			entry["progress"] = maxf(float(entry.get("progress", 0.0)), clampf(incoming, 0.0, 1.0))
	entry["updated_at_ms"] = int(Time.get_ticks_msec())
	_actions[str(found["action"])] = entry
	_emit_changed(entry)
	return true


func annotate(request_id: String, event_name: String, detail: Dictionary = {}) -> bool:
	var found := _find_by_request(request_id)
	if found.is_empty():
		_record_breadcrumb("unknown", request_id, 0, "action_rejected", {"reason": "stale_annotation"})
		return false
	var entry: Dictionary = found["entry"]
	_record_breadcrumb(str(found["action"]), request_id,
		int(entry.get("started_at_ms", 0)), event_name, detail)
	return true


func is_current(request_id: String) -> bool:
	var found := _find_by_request(request_id)
	if found.is_empty():
		return false
	return ACTIVE_STATES.has(str((found["entry"] as Dictionary).get("state", "")))


func snapshot_for(action: String) -> Dictionary:
	if not _actions.has(action):
		return {"action": action, "state": STATE_IDLE}
	return _public_snapshot(_actions[action])


func dump_action_state() -> Dictionary:
	var active: Array = []
	for action in _actions.keys():
		var entry: Dictionary = _actions[action]
		if ACTIVE_STATES.has(str(entry.get("state", ""))):
			active.append(_public_snapshot(entry))
	active.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("action", "")) < str(b.get("action", "")))
	return {
		"available": true,
		"active": active,
		"active_count": active.size(),
		"recent": _history.duplicate(true),
	}


func recent_breadcrumbs(limit: int = 10) -> Array:
	var wanted := clampi(limit, 0, BREADCRUMB_KEEP)
	var start := maxi(0, _breadcrumbs.size() - wanted)
	return _breadcrumbs.slice(start).duplicate(true)


# Public test seam and deterministic watchdog entry point. Production _process()
# calls it with the real monotonic clock.
func poll(now_msec: int = -1) -> void:
	var now := int(Time.get_ticks_msec()) if now_msec < 0 else now_msec
	for action in _actions.keys().duplicate():
		if not _actions.has(action):
			continue
		var entry: Dictionary = _actions[action]
		if not ACTIVE_STATES.has(str(entry.get("state", ""))):
			continue
		var owner_ref: WeakRef = entry.get("_owner_ref", null)
		if owner_ref != null and owner_ref.get_ref() == null:
			_resolve(str(entry.get("request_id", "")), STATE_CANCELLED, {"reason": "owner_freed"})
			continue
		if now >= int(entry.get("deadline_ms", now + 1)):
			_resolve(str(entry.get("request_id", "")), STATE_TIMED_OUT, {"error_code": "ACTION_TIMEOUT"})


func reset(action: String, request_id: String = "") -> bool:
	if not _actions.has(action):
		return true
	var entry: Dictionary = _actions[action]
	if not request_id.is_empty() and str(entry.get("request_id", "")) != request_id:
		return false
	if ACTIVE_STATES.has(str(entry.get("state", ""))):
		return false
	_actions.erase(action)
	return true


func clear_for_owner(owner_obj: Object, reason: String = "owner_exit") -> int:
	if owner_obj == null:
		return 0
	var closed := 0
	for action in _actions.keys().duplicate():
		var entry: Dictionary = _actions[action]
		var owner_ref: WeakRef = entry.get("_owner_ref", null)
		if owner_ref != null and owner_ref.get_ref() == owner_obj \
				and ACTIVE_STATES.has(str(entry.get("state", ""))):
			if cancel(str(entry.get("request_id", "")), reason, true):
				closed += 1
	return closed


func _transition_active(request_id: String, next_state: String) -> bool:
	var found := _find_by_request(request_id)
	if found.is_empty():
		_record_breadcrumb("unknown", request_id, 0, "action_rejected", {"reason": "stale_transition"})
		return false
	var entry: Dictionary = found["entry"]
	if not ACTIVE_STATES.has(str(entry.get("state", ""))):
		_record_breadcrumb(str(found["action"]), request_id,
			int(entry.get("started_at_ms", 0)), "action_rejected", {"reason": "late_transition"})
		return false
	entry["state"] = next_state
	entry["updated_at_ms"] = int(Time.get_ticks_msec())
	_actions[str(found["action"])] = entry
	_record_breadcrumb(str(found["action"]), request_id,
		int(entry.get("started_at_ms", 0)), "pending", {"state": next_state})
	_emit_changed(entry)
	return true


func _resolve(request_id: String, terminal_state: String, patch: Dictionary) -> bool:
	var found := _find_by_request(request_id)
	if found.is_empty():
		_record_breadcrumb("unknown", request_id, 0, "action_rejected", {"reason": "stale_result"})
		return false
	var action := str(found["action"])
	var entry: Dictionary = found["entry"]
	if not ACTIVE_STATES.has(str(entry.get("state", ""))):
		_record_breadcrumb(action, request_id, int(entry.get("started_at_ms", 0)),
			"action_rejected", {"reason": "late_result", "state": str(entry.get("state", ""))})
		return false
	entry["state"] = terminal_state
	entry["updated_at_ms"] = int(Time.get_ticks_msec())
	for key in patch:
		entry[key] = patch[key]
	_actions[action] = entry
	var event_name := "completed"
	if terminal_state == STATE_FAILED:
		event_name = "failed"
	elif terminal_state == STATE_CANCELLED:
		event_name = "cancelled"
	elif terminal_state == STATE_TIMED_OUT:
		event_name = "timed_out"
	_record_breadcrumb(action, request_id, int(entry.get("started_at_ms", 0)), event_name, {
		"state": terminal_state,
		"reason": str(entry.get("reason", "")),
		"error_code": str(entry.get("error_code", "")),
		"stage": str(entry.get("stage", "")),
	})
	var snapshot := _public_snapshot(entry)
	_history.append(snapshot)
	while _history.size() > HISTORY_KEEP:
		_history.remove_at(0)
	action_state_changed.emit(action, request_id, terminal_state, snapshot)
	action_resolved.emit(action, request_id, terminal_state, snapshot)
	_return_to_idle.call_deferred(action, request_id)
	return true


func _return_to_idle(action: String, request_id: String) -> void:
	if not _actions.has(action):
		return
	var entry: Dictionary = _actions[action]
	if str(entry.get("request_id", "")) != request_id \
			or not TERMINAL_STATES.has(str(entry.get("state", ""))):
		return
	entry["state"] = STATE_IDLE
	entry["updated_at_ms"] = int(Time.get_ticks_msec())
	_actions[action] = entry
	_emit_changed(entry)


func _find_by_request(request_id: String) -> Dictionary:
	for action in _actions.keys():
		var entry: Dictionary = _actions[action]
		if str(entry.get("request_id", "")) == request_id:
			return {"action": str(action), "entry": entry}
	return {}


func _emit_changed(entry: Dictionary) -> void:
	action_state_changed.emit(str(entry.get("action", "")), str(entry.get("request_id", "")),
		str(entry.get("state", STATE_IDLE)), _public_snapshot(entry))


func _record_breadcrumb(
	action: String,
	request_id: String,
	started_at_msec: int,
	event_name: String,
	detail: Dictionary
) -> void:
	_breadcrumbs.append(Breadcrumb.make(event_name, action, request_id, started_at_msec, detail))
	while _breadcrumbs.size() > BREADCRUMB_KEEP:
		_breadcrumbs.remove_at(0)


func _public_snapshot(entry: Dictionary) -> Dictionary:
	var now := int(Time.get_ticks_msec())
	return {
		"action": str(entry.get("action", "")),
		"request_id": str(entry.get("request_id", "")),
		"state": str(entry.get("state", STATE_IDLE)),
		"stage": str(entry.get("stage", "")),
		"progress": float(entry.get("progress", -1.0)),
		"elapsed_ms": maxi(0, now - int(entry.get("started_at_ms", now))),
		"timeout_msec": int(entry.get("timeout_msec", 0)),
		"cancellable": bool(entry.get("cancellable", false)),
		"cancel_reason": str(entry.get("cancel_reason", "")),
		"error_code": str(entry.get("error_code", "")),
		"retryable": bool(entry.get("retryable", false)),
	}
