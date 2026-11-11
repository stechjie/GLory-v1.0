extends Node

# Exercise the actual profile -> DialogService callback dispatch, without
# contacting an account server or deleting a real player's data.
const Harness := preload("res://tools/CheckHarness.gd")
const Sfx := preload("res://ui/services/SfxService.gd")

class ProfileProbe:
	extends "res://scenes/menu/ProfileScreen.gd"
	var actions: Array = []
	func _load() -> void:
		pass
	func _load_ranked() -> void:
		pass
	func _load_identities() -> void:
		pass
	func _run_delete(code: String) -> void:
		actions.append(["delete", code])
	func _run_switch(provider: String, token: String, nonce: String) -> void:
		actions.append(["switch", provider, token, nonce])
	func _sign_in_and_switch() -> void:
		actions.append(["sign_in"])

var h := Harness.new("profile_dialog")

func _ready() -> void:
	call_deferred("_run")

func _resolve(result: String) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var pending: Dictionary = DialogService.get("_pending")
	if not h.expect(pending.size() == 1, "one_dialog", "Profile must open exactly one confirmation"):
		return
	DialogService._on_dialog_resolved(result, str(pending.keys()[0]))

func _run() -> void:
	var saved_profile := AccountManager.profile
	AccountManager.profile = {"player_name": "Review QA", "friend_code": "ABCDEFGH"}
	var p := ProfileProbe.new()
	add_child(p)
	p._data = AccountManager.profile.duplicate(true)
	p._refresh()
	p._delete_code_edit.text = "abcdefgh"
	p._sync_delete_button()
	h.expect(not p._delete_btn.disabled, "matching_code", "Matching friend code must enable deletion")
	p._on_delete_pressed()
	await _resolve("cancelled")
	h.expect(p.actions.is_empty(), "cancel_deletion", "Cancel must not delete the account")
	p._on_delete_pressed()
	await _resolve("confirmed")
	h.expect(p.actions == [["delete", "ABCDEFGH"]], "confirm_deletion", "Confirm must dispatch deletion exactly once with the displayed friend code")
	p.actions.clear()
	p._confirm_switch_to_taken("google", "test-token", "test-nonce")
	await _resolve("confirmed")
	h.expect(p.actions == [["switch", "google", "test-token", "test-nonce"]], "confirm_taken_account", "Confirm must preserve provider credentials and dispatch account switching")
	p.actions.clear()
	p._on_switch_account()
	await _resolve("cancelled")
	h.expect(p.actions.is_empty(), "cancel_switch", "Cancel must not open sign-in")
	p._on_switch_account()
	await _resolve("confirmed")
	h.expect(p.actions == [["sign_in"]], "confirm_switch", "Confirm must open account sign-in exactly once")
	h.expect(DialogService.open_count() == 0, "dialogs_closed", "Resolved profile dialogs must leave no pending request")
	p.queue_free()
	await get_tree().process_frame
	Sfx.shutdown()
	await get_tree().create_timer(0.3).timeout
	AccountManager.profile = saved_profile
	h.finish(get_tree())
