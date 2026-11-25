extends Node

const Harness := preload("res://tools/CheckHarness.gd")

class MainProbe extends "res://scenes/main/Main.gd":
	var shown := 0
	func _ready() -> void:
		set_process(false)
	func _team_run_state_is_fresh() -> bool:
		return false
	func _show_prep() -> void:
		shown += 1

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
	main.queue_free()
	h.finish(get_tree())
