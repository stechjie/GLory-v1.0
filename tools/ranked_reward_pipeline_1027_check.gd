extends Node

# Isolated integration driver: fixture player IDs and reports stay outside the repo.
const Harness := preload("res://tools/CheckHarness.gd")

class RoomProbe extends "res://scripts/autoload/NetworkService.gd":
	func _peer_connected(_peer: int) -> bool:
		return true

var h := Harness.new("ranked_reward_pipeline_1027")

func _ready() -> void:
	NetworkService.set_process(false)
	var fixture_path := ""
	var receipt_path := ""
	var expect_missing := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--reward-fixture="):
			fixture_path = arg.trim_prefix("--reward-fixture=")
		if arg == "--expect-missing-key":
			expect_missing = true
		if arg.begins_with("--receipt-fixture="):
			receipt_path = arg.trim_prefix("--receipt-fixture=")
	if not receipt_path.is_empty():
		var receipts: Array = JSON.parse_string(FileAccess.get_file_as_string(receipt_path))
		for locale in ["zh", "en"]:
			LocaleManager.set_locale(locale)
			for receipt: Dictionary in receipts:
				var screen := preload("res://scenes/menu/RankedRewardScreen.gd").new()
				screen.data = {"preview_receipt":receipt}
				add_child(screen)
				h.expect(screen._amount.text == "+%d" % int(receipt.coin), "coin_shown", "Committed receipt amount is displayed")
				h.expect(screen._receipt_status.text == ("已加入账户钱包" if locale == "zh" else "Added to your account wallet"),
					"settled_shown", "The real receipt clears the verification placeholder in both languages")
				h.expect(not screen._confirm.disabled and not screen._retry.visible, "settled_actions", "The receipt releases confirmation without retrying")
				screen.free()
		h.finish(get_tree())
		return
	if not h.expect(FileAccess.file_exists(fixture_path), "fixture", "Provide isolated test player IDs"):
		h.finish(get_tree())
		return
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(fixture_path))
	var server := RoomProbe.new()
	add_child(server)
	server.set_process(false)
	server.enter_test_server_mode()
	server._server_epoch = 1
	var reports := []
	for rounds in [13,21]:
		var room: Dictionary = server._new_room()
		room.mode = "ranked"
		room.ruleset = "seedling" if rounds == 13 else "normal"
		room.round_index = rounds
		room.match_uid = "%032x" % rounds
		room.match_started_wall = int(Time.get_unix_time_from_system()) - 1200
		room.slot_states = ["player","player","player","player","player","player"]
		room.initial_seats = room.slot_states.duplicate()
		room.peer_slot = {}
		room.seat_pid = {}
		for i in range(6):
			room.peer_slot[100+i] = i
			room.seat_pid[i] = str(fixture.players[i])
		var wire: String = server._room_sign_report(room, rounds, 0, 50, 0, {"kind":"pvp"})
		h.expect(wire.is_empty() == expect_missing, "report_signing", "Missing signing configuration blocks the entire match's settlement")
		reports.append({"rounds":rounds,"wire":wire})
	fixture["reports"] = reports
	var file := FileAccess.open(fixture_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(fixture))
	file.close()
	server.free()
	h.finish(get_tree())
