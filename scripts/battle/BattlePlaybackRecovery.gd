extends RefCounted

const ReplayUtil := preload("res://scripts/battle/BattleReplayUtil.gd")

# Network identity stays outside simulation frames and presentation event hashes.
static func replay_battle_id(replay: Dictionary) -> String:
	var transport_id := str(replay.get("battle_id", ""))
	if not transport_id.is_empty():
		return transport_id
	for bucket in replay.get("frame_events", []):
		if not (bucket is Array):
			continue
		for event in bucket:
			if event is Dictionary:
				var id := str(event.get("battle_id", ""))
				if not id.is_empty():
					# Presentation events distinguish the two team perspectives; room
					# identity does not (BattleSimulator._presentation_battle_id).
					return id.trim_suffix(":team0").trim_suffix(":team1")
	return ""


# Protocol 32 servers omit battle_id/battle_round in room_state and expose the
# next preparation round during RESULT. Wait for its authoritative match_state
# rather than treating that next round as the replay round.
static func resolve_resume(payload: Dictionary, match_state: Dictionary) -> Dictionary:
	if not needs_replay(payload):
		return payload
	if not str(payload.get("battle_id", "")).is_empty() and int(payload.get("battle_round", -1)) > 0:
		return payload
	var result_id := str(match_state.get("battle_id", ""))
	var completed := int(match_state.get("completed_round", -1))
	if result_id.is_empty() or completed <= 0:
		return {}
	if payload.has("battle_round") and completed != int(payload.battle_round):
		return {}
	if not str(payload.get("battle_id", "")).is_empty() and result_id != str(payload.battle_id):
		return {}
	var phase := str(payload.get("phase", ""))
	if phase == "battle" and completed != int(payload.get("round_id", -1)):
		return {}
	if phase == "result":
		if int(match_state.get("round_index", -1)) != int(payload.get("round_id", -1)):
			return {}
		# The last two rounds share next-round FINAL_ROUND; run_over distinguishes them.
		if payload.has("run_over") and bool(payload.run_over) != bool(match_state.get("run_over", false)):
			return {}
	var resolved := payload.duplicate(true)
	resolved["battle_id"] = result_id
	resolved["battle_round"] = completed
	return resolved


static func same_battle(active_id: String, active_round: int, payload: Dictionary) -> bool:
	return not active_id.is_empty() and active_id == str(payload.get("battle_id", "")) \
		and active_round == int(payload.get("battle_round", payload.get("round_id", -1)))


static func needs_replay(payload: Dictionary) -> bool:
	if str(payload.get("phase", "")) not in ["battle", "result"]:
		return false
	# Missing availability on older servers is unknown, not proof of no replay.
	return bool(payload.get("replay_available", true)) or bool(payload.get("replay_pending", false))


static func ready(expected_id: String, expected_round: int, received_id: String,
		replay: Dictionary, match_state: Dictionary) -> bool:
	if not ReplayUtil.valid_team_replay(replay):
		return false
	if int(match_state.get("completed_round", -1)) != expected_round:
		return false
	var result_id := str(match_state.get("battle_id", ""))
	if result_id.is_empty() or (not expected_id.is_empty() and expected_id != result_id):
		return false
	var replay_id := received_id if not received_id.is_empty() else replay_battle_id(replay)
	return replay_id == result_id
