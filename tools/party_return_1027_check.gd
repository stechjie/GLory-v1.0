extends Node

const Harness := preload("res://tools/CheckHarness.gd")
const FinalPanel := preload("res://scenes/menu/FinalSettlementPanel.gd")

class MainProbe extends "res://scenes/main/Main.gd":
	var routed: Dictionary = {}
	func _ready() -> void:
		pass
	func _process(_delta: float) -> void:
		pass
	func _show_party_lobby(mode: String, invite_id: String = "", restore_existing: bool = false) -> void:
		routed = {"mode":mode,"invite":invite_id,"restore":restore_existing}

class PartyProbe extends "res://scenes/menu/PartyLobby.gd":
	func _my_code() -> String:
		return "HOST0001"

var h := Harness.new("party_return_1027")

func _ready() -> void:
	NetworkService.set_process(false)
	for locale in ["zh", "en"]:
		LocaleManager.set_locale(locale)
		for mode in ["ranked", "casual"]:
			var main := MainProbe.new()
			main._final_settlement_data = {"mode":mode}
			NetworkService.team_active = true
			GameState.team_mode = true
			var panel := FinalPanel.new()
			panel.data = {"mode":mode,"can_return_party":true,"can_return_room":false}
			panel.return_party_requested.connect(main._return_to_party_room)
			add_child(panel)
			h.expect(panel._party_buttons.size()==2,"both_return_rows","Both settlement return rows exist")
			# Translation keys are the actual UI contract; English wording may evolve.
			h.expect(panel._party_buttons[0].text==tr("settle_back_party"),"localized_return","Return action follows the active language")
			h.expect(panel._party_buttons[0].visible and not panel._return_buttons[0].visible,"party_not_custom","Matched games use the account party action")
			panel._party_buttons[0].pressed.emit()
			h.expect(main.routed.get("mode")==mode and bool(main.routed.get("restore",false)),"original_party_route","Actual button requests the existing account party")
			h.expect(not NetworkService.team_active and not GameState.team_mode,"completed_transport_released","Old battle session is detached on return")
			# Also cover legacy callers of the generic return-room handler.
			main.routed={}
			main._return_from_settlement()
			h.expect(bool(main.routed.get("restore",false)),"legacy_return_route","Generic matched return cannot create a custom room")
			panel.queue_free()
			main.free()
			await get_tree().process_frame
		var lobby := PartyProbe.new()
		var normal := {"state":"room","mode":"casual_normal","host_code":"HOST0001","members":[{}],"queued":false}
		lobby.configure("casual","",true)
		h.expect(not lobby._should_align_existing_mode(normal),"normal_mode_preserved","Returning solo normal-mode player keeps Normal instead of switching to Seedling")
		lobby.configure("casual","",false)
		h.expect(lobby._should_align_existing_mode(normal),"menu_mode_selection_unchanged","A fresh menu-mode choice still behaves as before")
		lobby.free()
	h.finish(get_tree())
