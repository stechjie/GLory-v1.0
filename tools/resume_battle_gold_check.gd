extends Node

const Harness := preload("res://tools/CheckHarness.gd")

class MainProbe extends "res://scenes/main/Main.gd":
	var shown := 0
	var replays := 0
	func _ready() -> void:
		set_process(false)
	func _team_run_state_is_fresh() -> bool:
		return false
	func _show_prep() -> void:
		shown += 1
	func _begin_resume_replay(_payload: Dictionary) -> void:
		replays += 1

func _ready() -> void:
	call_deferred("run")

func run() -> void:
	var h := Harness.new("resume_battle_gold")
	var main := MainProbe.new()
	add_child(main)
	GameState.round_index = 4
	GameState.gold = 100
	GameState.gold_spent_this_round = true
	var snapshot := {"phase": "prep", "round_id": 5, "gold": 135,
		"economy": {"authoritative": false, "gold": 999}}
	main._on_resume_completed(snapshot)
	h.expect(GameState.gold == 135, "missed_result", "Restore server settlement after crossing the result while backgrounded")
	h.expect(GameState.round_index == 5 and main.shown == 1, "next_preparation", "Enter the recovered next round")
	h.expect(not GameState.gold_spent_this_round, "new_round_interest", "Previous round spending does not suppress next round interest")
	# Spend after recovery; duplicate or same-round snapshots must not undo it.
	GameState.gold = 55
	GameState.gold_spent_this_round = true
	main._on_resume_completed(snapshot)
	h.expect(GameState.gold == 55, "duplicate_after_purchase", "Repeated recovery must not award again or undo purchases")
	h.expect(GameState.gold_spent_this_round, "same_round_spending", "Same-round recovery keeps spending state")
	GameState.gold = 80
	main._on_resume_completed(snapshot)
	h.expect(GameState.gold == 80, "same_round_sale", "Same-round recovery keeps sale income")
	snapshot.round_id = 8
	snapshot.gold = 300
	main._on_resume_completed(snapshot)
	h.expect(GameState.gold == 300 and GameState.round_index == 8, "multiple_rounds", "Several missed rounds restore the latest balance once")
	main._on_resume_completed(snapshot)
	h.expect(GameState.gold == 300, "duplicate_no_double_income", "Never add the same settlement twice")
	snapshot.round_id = 9
	snapshot.erase("gold")
	main._on_resume_completed(snapshot)
	h.expect(GameState.gold == 300, "missing_balance", "An incomplete old snapshot cannot zero the balance")
	snapshot.economy = {"authoritative": true, "gold": 72, "gold_spent_this_round": true}
	main._on_resume_completed(snapshot)
	h.expect(GameState.gold == 72 and GameState.gold_spent_this_round,
		"authoritative_ledger", "Fully authoritative ledger recovery keeps its original priority")
	# RESULT reports the next prep round even while its worker is still running.
	var result := {"phase": "result", "round_id": 10, "battle_round": 9, "battle_id": "42:9:1",
		"gold": 160, "replay_pending": true, "replay_available": false}
	main._on_resume_completed(result)
	h.expect(GameState.round_index == 9 and GameState.gold == 72 and main.replays == 1,
		"pending_result", "Unpublished results must not release the next round balance")
	# After a server restart the seat's published settlement survives but its replay does not.
	result.replay_pending = false
	main._on_resume_completed(result)
	h.expect(GameState.round_index == 10 and GameState.gold == 160 and not GameState.gold_spent_this_round,
		"result_without_replay", "Restore the published balance when returning directly to preparation")
	GameState.gold = 175
	GameState.gold_spent_this_round = true
	var late_result := {"completed_round": 9, "round_index": 10, "gold": 160, "battle_id": "42:9:1"}
	main._on_network_match_state_received(late_result)
	h.expect(GameState.gold == 175 and GameState.gold_spent_this_round,
		"delayed_result_after_sale", "A late settlement cannot revert same-round transactions")
	main._on_network_match_state_received({"completed_round": 7, "round_index": 8, "gold": 95})
	h.expect(GameState.round_index == 10 and GameState.gold == 175,
		"older_result_after_resume", "Old results cannot roll back a seat that recovered several rounds")
	var battle := {"phase": "battle", "round_id": 12, "battle_round": 12, "battle_id": "42:12:1",
		"gold": 355, "replay_pending": true}
	main._on_resume_completed(battle)
	h.expect(GameState.round_index == 12 and GameState.gold == 355 and main.replays == 2,
		"later_battle", "A later battle starts with the balance from the previous settled rounds")
	main.queue_free()
	h.finish(get_tree())
