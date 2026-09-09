extends Node

const Harness := preload("res://tools/CheckHarness.gd")

class Probe:
	extends "res://scenes/prep/PrepFlowController.gd"
	var messages: Array[String] = []
	var launches := 0
	func show_message(text: String) -> void:
		messages.append(text)
	func _refresh_all() -> void:
		pass
	func _emit_battle_request_once() -> void:
		launches += 1

func _ready() -> void:
	var h := Harness.new("prep_empty_board")
	var saved_board := GameState.board_slots
	var saved_bench := GameState.bench_slots
	var saved_merc := GameState.mercenary_slots
	var saved_tutorial := GameState.tutorial_mode
	var saved_pending: bool = SaveManager._save_pending
	var net := {}
	for key in ["team_active", "team_local_slot", "team_ready", "is_host", "team_round_active", "_pending_ready"]:
		net[key] = NetworkService.get(key)
	# Synchronous test: prevent save_run scheduling a write of fixture state.
	SaveManager._save_pending = true
	GameState.tutorial_mode = false
	GameState.board_slots = [null, null]
	GameState.bench_slots = [{"id": "militia"}]
	GameState.mercenary_slots = [null]
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.team_ready = [false]
	NetworkService.is_host = true
	NetworkService.team_round_active = false
	NetworkService._pending_ready = -1
	var probe := Probe.new()
	probe._on_start_battle()
	h.expect(not bool(NetworkService.team_ready[0]), "empty_not_ready", "Empty board became ready")
	var expected := "At least 1 unit must be on the board before you can ready up" if LocaleManager.get_locale().begins_with("en") else "至少有1个棋子在棋盘上才能准备"
	h.expect(probe.messages == [expected], "empty_message", "Missing required empty-board hint")
	h.expect(probe.launches == 0, "no_empty_launch", "Empty board launched battle")
	NetworkService.team_ready = [true]
	probe._on_start_battle()
	h.expect(not bool(NetworkService.team_ready[0]), "can_cancel_empty", "Empty board blocked cancellation")
	NetworkService._pending_ready = 1
	probe._on_start_battle()
	h.expect(probe.messages.size() == 1, "inflight_cancel", "In-flight ready was treated as a new ready request")
	NetworkService._pending_ready = -1
	GameState.board_slots = [{"id": "militia"}, null]
	probe._on_start_battle()
	h.expect(bool(NetworkService.team_ready[0]), "one_unit_ready", "One board unit could not ready up")
	NetworkService.team_active = false
	probe._on_start_battle()
	h.expect(probe.launches == 1, "one_unit_offline", "One board unit could not start offline")
	GameState.board_slots = [null, null]
	probe._on_start_battle()
	h.expect(probe.launches == 1 and probe.messages.size() == 2, "empty_offline", "Offline empty board bypassed guard")
	GameState.mercenary_slots = [{"id": "militia"}]
	h.expect(probe._has_any_board_unit(), "deployed_mercenary", "Deployed mercenary not counted as a combat unit")
	# This focused probe never builds the UI that normally owns these panels.
	for key in ["_shop", "_synergy", "_stats", "_treasure", "_board_hud"]:
		(probe.get(key) as Node).free()
	probe.free()
	GameState.board_slots = saved_board
	GameState.bench_slots = saved_bench
	GameState.mercenary_slots = saved_merc
	GameState.tutorial_mode = saved_tutorial
	SaveManager._save_pending = saved_pending
	for key in net:
		NetworkService.set(key, net[key])
	h.finish(get_tree())
