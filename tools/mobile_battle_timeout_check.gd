extends Node
const H := preload("res://tools/CheckHarness.gd")

class StuckDirector extends RefCounted:
	var pending := true
	func has_blocking_cues() -> bool:
		return pending
	func skip_to_result() -> void:
		pending = false
	func dispose() -> void:
		pass

class BattleProbe extends "res://scenes/battle/BattleScreen.gd":
	var failure := ""
	func _ready() -> void:
		set_process(false)
	func _exit_tree() -> void:
		pass
	func cue_release_corpses() -> void:
		pass
	func _fail_team_replay(reason: String) -> void:
		failure = reason

class MainProbe extends "res://scenes/main/Main.gd":
	var applied: Dictionary = {}
	var prep_shown := false
	var final_shown := false
	func _ready() -> void:
		pass
	func _apply_team_match_state_payload(payload: Dictionary, _result: Dictionary = {}) -> void:
		applied = payload
	func _show_prep() -> void:
		prep_shown = true
	func _show_game_over(_settlement: Dictionary = {}) -> void:
		final_shown = true

func _ready() -> void:
	call_deferred("run")

func run() -> void:
	var h := H.new("mobile_battle_timeout")
	NetworkService.set_process(false)
	NetworkService.team_active = true
	NetworkService.is_host = false
	var battle := BattleProbe.new()
	add_child(battle)
	battle._replay_mode = true
	battle._playback_deadline_msec = Time.get_ticks_msec() - 1
	battle._process(0.001)
	h.expect(battle.failure == "battle_playback_timeout", "wall_clock_playback", "Slow frames cannot extend playback forever")
	var director := StuckDirector.new()
	battle._presentation_director = director
	var start := Time.get_ticks_msec()
	await battle._await_presentation_drained()
	h.expect(not director.pending and Time.get_ticks_msec() - start < 4500,
		"stuck_effect_cancelled", "An effect that never completes is cancelled at the three-second deadline")
	battle.queue_free()
	var main := MainProbe.new()
	add_child(main)
	# This fixture has no socket. Suppress outbound ACK RPCs; this section
	# exercises production settlement selection/navigation, not transport.
	NetworkService.is_host = true
	GameState.round_index = 4
	NetworkService.state = NetworkService.SessionState.READY
	NetworkService.server_phase = "prep"
	NetworkService.server_round_index = 5
	NetworkService.latest_match_state = {"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
		"completed_round": 4, "round_index": 5, "battle_id": "fixture:4", "gold": 123, "run_over": false}
	await main._finish_server_authoritative_team_battle({"error": "battle_prepare_timeout"})
	h.expect(main.applied.get("gold") == 123 and main.prep_shown,
		"server_result_after_render_failure", "Loading failure applies received authority and enters confirmed preparation")
	h.expect(NetworkService.state == NetworkService.SessionState.READY,
		"no_reconnect_loop", "Known settlement does not redownload the same failing replay")
	var final := {"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION, "completed_round": 21,
		"run_over": true, "battle_id": "fixture:21", "gold": 456}
	main._on_resume_completed({"run_over": true, "completed_settlement": final})
	h.expect(main.final_shown and main.applied.get("gold") == 456,
		"final_resume", "Returning to a completed room shows server settlement instead of stale preparation")
	main.queue_free()
	h.finish(get_tree())
