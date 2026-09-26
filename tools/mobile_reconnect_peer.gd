extends "res://tools/replay_test_peer.gd"
var resume_errors: Array[String] = []
var room_snapshots: Array[Dictionary] = []

func _ready() -> void:
	super._ready()
	_reconnect_service.configure(_now, _net_log, {"reserve_grace_sec": RESERVE_GRACE_SEC})
	_room_service.configure(_now, _wall_now, _net_log, func(): return 0, {
		"team_slots": TEAM_SLOTS, "room_lobby": ROOM_LOBBY, "room_result": ROOM_RESULT,
		"room_closed": ROOM_CLOSED, "room_prep": ROOM_PREP, "room_battle": ROOM_BATTLE,
		"reserve_grace_sec": RESERVE_GRACE_SEC, "lobby_empty_ttl_sec": LOBBY_EMPTY_TTL_SEC,
		"room_suspend_grace_sec": ROOM_SUSPEND_GRACE_SEC, "prep_timeout_sec": PREP_TIMEOUT_SEC,
		"battle_timeout_sec": BATTLE_TIMEOUT_SEC, "result_timeout_sec": RESULT_TIMEOUT_SEC,
	}, _reconnect_service)

@rpc("authority", "call_remote", "reliable")
func _rpc_resume_failed(reason: String) -> void:
	resume_errors.append(reason)

@rpc("authority", "call_remote", "reliable")
func _rpc_room_state(envelope: Dictionary) -> void:
	room_snapshots.append(envelope)
