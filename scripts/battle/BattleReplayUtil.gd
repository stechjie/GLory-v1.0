extends RefCounted

static func valid_team_replay(replay: Dictionary) -> bool:
	if replay.is_empty() or typeof(replay.get("frames", null)) != TYPE_ARRAY or typeof(replay.get("roster", null)) != TYPE_DICTIONARY or typeof(replay.get("result", null)) != TYPE_DICTIONARY:
		return false
	var frames: Array = replay.get("frames", [])
	if frames.is_empty() or (replay.get("roster", {}) as Dictionary).is_empty():
		return false
	for frame in frames:
		if typeof(frame) != TYPE_ARRAY:
			return false
		for entry in (frame as Array):
			if typeof(entry) != TYPE_ARRAY or (entry as Array).size() < 5:
				return false
	return true