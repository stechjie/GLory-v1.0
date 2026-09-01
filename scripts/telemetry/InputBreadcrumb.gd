extends RefCounted

# One privacy-safe step in an asynchronous action's input-to-result trail.
#
# Release builds deliberately keep only the action category, event, state/reason
# and latency. Screen coordinates, typed text, room identifiers and arbitrary
# caller dictionaries never enter this object. Debug builds may additionally
# include a stable control id so a missed hit can be located in the scene.

const MAX_TOKEN_LENGTH := 64
const RELEASE_DETAIL_KEYS := ["state", "reason", "error_code", "stage"]


static func make(
	event_name: String,
	action_category: String,
	request_id: String,
	started_at_msec: int,
	detail: Dictionary = {}
) -> Dictionary:
	var now := int(Time.get_ticks_msec())
	var out := {
		"at_ms": now,
		"event": _safe_token(event_name),
		"action": _safe_token(action_category),
		"request_id": _safe_token(request_id),
		"latency_ms": maxi(0, now - started_at_msec) if started_at_msec > 0 else 0,
	}
	for key in RELEASE_DETAIL_KEYS:
		if detail.has(key):
			out[key] = _safe_token(str(detail[key]))
	if OS.is_debug_build() and detail.has("control_id"):
		out["control_id"] = _safe_token(str(detail["control_id"]))
	return out


static func _safe_token(value: String) -> String:
	var safe := value.strip_edges().replace("\n", " ").replace("\r", " ").replace("\t", " ")
	return safe.left(MAX_TOKEN_LENGTH)
