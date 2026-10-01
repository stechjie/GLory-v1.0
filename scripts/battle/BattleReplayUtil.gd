extends RefCounted

static func terminal_without_units(replay: Dictionary) -> bool:
	var result: Variant = replay.get("result")
	if not result is Dictionary or typeof(result.get("player_wins")) != TYPE_BOOL:
		return false
	if typeof(result.get("player_alive")) != TYPE_INT or typeof(result.get("enemy_alive")) != TYPE_INT:
		return false
	if int(result.player_alive) < 0 or int(result.enemy_alive) < 0:
		return false
	return (str(result.get("reason", "")) == "no_player_units" and int(result.player_alive) == 0 and not result.player_wins) \
		or (str(result.get("reason", "")) == "no_enemy_units" and int(result.enemy_alive) == 0 and result.player_wins)


static func normalize_terminal_replay(replay: Dictionary) -> void:
	# Older server snapshots contain zero frames when simulation ends at t=0.
	# Preserve the authoritative result; one empty presentation frame lets the
	# normal battle UI build and finish, without inventing units or an outcome.
	if replay.get("frames") is Array and replay.frames.is_empty() \
			and replay.get("roster") is Dictionary and terminal_without_units(replay):
		replay["frames"] = [[]]
		replay["frame_events"] = [[]]


static func valid_team_replay(replay: Dictionary) -> bool:
	if replay.is_empty() or typeof(replay.get("frames", null)) != TYPE_ARRAY or typeof(replay.get("roster", null)) != TYPE_DICTIONARY or typeof(replay.get("result", null)) != TYPE_DICTIONARY:
		return false
	var frames: Array = replay.get("frames", [])
	if frames.is_empty():
		return false
	if (replay.get("roster", {}) as Dictionary).is_empty() and not terminal_without_units(replay):
		return false
	for frame in frames:
		if typeof(frame) != TYPE_ARRAY:
			return false
		for entry in (frame as Array):
			if typeof(entry) != TYPE_ARRAY or (entry as Array).size() < 5:
				return false
	return true
