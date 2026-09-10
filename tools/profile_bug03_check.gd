extends Node

const Harness := preload("res://tools/CheckHarness.gd")
const Rooms := preload("res://scripts/multiplayer/RoomService.gd")
const Tokens := preload("res://scripts/multiplayer/ReconnectService.gd")

class ProfileProbe:
	extends "res://scenes/menu/ProfileScreen.gd"
	var submitted: Dictionary = {}
	func _load() -> void:
		pass
	func _save_bio(payload: Dictionary) -> void:
		submitted = payload.duplicate(true)

class LobbyProbe:
	extends "res://scenes/menu/Team3v3Lobby.gd"
	var viewed := -1
	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_build()
		_refresh()
		_layout()
	func _view_seat_profile(index: int) -> void:
		viewed = index

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var h := Harness.new("profile_bug03")
	var saved_pet := PlayerProfile.active_pet
	var saved_profile := AccountManager.profile
	var saved_active := NetworkService.team_active
	var saved_seats := NetworkService.team_seat_profiles
	PlayerProfile.active_pet = "pet_cat"
	AccountManager.profile = {"player_name": "Me", "friend_code": "ABCDEFGH", "avatar": "preset:avatar_001"}
	NetworkService.team_active = false
	NetworkService.team_seat_profiles = {1: {"player_name": "Other", "friend_code": "BCDEFGHJ", "avatar": "preset:avatar_002"}}
	var profile := ProfileProbe.new()
	add_child(profile)
	profile._data = AccountManager.profile.duplicate(true)
	profile._refresh()
	h.expect(profile._pet_label.text.contains(profile._pet_display("pet_cat")), "active_pet", "Profile does not show local active pet")
	profile._month_pick.select(profile._month_pick.get_item_index(1))
	profile._rebuild_days()
	h.expect(profile._day_pick.get_item_index(31) >= 0, "day31", "January cannot select day 31")
	profile._day_pick._open_choices()
	await get_tree().process_frame
	if "--review" in OS.get_cmdline_user_args():
		await get_tree().create_timer(0.3).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://work/bug0909-03-review/birthday.png")
	profile._day_pick._choose(profile._day_pick.get_item_index(31))
	h.expect(profile._day_pick.get_selected_id() == 31, "touch_day31", "Touch picker did not select day 31")
	profile._gender_pick.select(1)
	profile._region_pick.select(2)
	profile._signature_edit.text = "saved signature"
	profile._on_save_bio_pressed()
	await get_tree().process_frame
	DialogService._on_dialog_resolved("confirmed", "profile_birthday_%d" % profile.get_instance_id())
	h.expect(profile.submitted.get("birth_day") == 31, "confirmation_callback", "Confirm did not dispatch birthday save")
	h.expect(profile.submitted.get("gender") == "female" and profile.submitted.get("region") == "CN" and profile.submitted.get("signature") == "saved signature", "all_bio_fields", "Bio save dropped fields")
	var response := AccountManager.profile.duplicate(true)
	response.merge(profile.submitted, true)
	profile._finish_submit({"code": 200, "body": response})
	h.expect(profile._day_pick.disabled and profile._signature_edit.text == "saved signature", "saved_response", "Saved response not reflected in controls")
	var feb := ProfileProbe.new()
	add_child(feb)
	feb._month_pick.select(feb._month_pick.get_item_index(2))
	feb._rebuild_days()
	h.expect(feb._day_pick.get_item_index(29) >= 0 and feb._day_pick.get_item_index(30) < 0, "february", "Invalid February days")
	var lobby := LobbyProbe.new()
	profile.hide()
	feb.hide()
	lobby._slot_states = ["player", "player", "empty", "dummy", "empty", "empty"]
	add_child(lobby)
	h.expect(lobby._slot_name_lbls[1].text.contains("Other"), "nickname", "Other player nickname missing")
	h.expect(lobby._slot_avatars[1].visible and lobby._slot_avatars[1].texture != null, "avatar", "Player avatar missing")
	h.expect(not lobby._slot_avatars[2].visible, "empty_slot", "Empty slot contains player avatar")
	lobby._on_slot_pressed(1)
	h.expect(lobby.viewed == 1, "avatar_click", "Occupied seat did not open profile")
	lobby._slot_ready[1] = true
	lobby._refresh()
	if "--review" in OS.get_cmdline_user_args():
		await get_tree().create_timer(0.3).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://work/bug0909-03-review/lobby.png")
	h.expect(lobby._slot_status_lbls[1].text in ["准备", "Ready"], "ready_status", "Ready status missing")
	var public_data := NetworkService.public_seat_identity({"friend_code": "ABCDEFGH", "player_name": "Me", "avatar": "preset:avatar_001", "birth_day": 31, "signature": "private", "access_token": "secret"})
	h.expect(public_data.size() == 3 and not public_data.has("birth_day") and not public_data.has("access_token"), "privacy", "Private fields leaked into lobby snapshot")
	var tokens := Tokens.new()
	tokens.configure(func(): return 1.0, func(_s): pass, {})
	var rooms := Rooms.new()
	rooms.configure(func(): return 1.0, func(): return 1.0, func(_s): pass, func(): return 0, {}, tokens)
	var room := {"id": 1, "seat_profiles": {0: public_data}}
	rooms.move_seat_metadata(room, 0, 2)
	h.expect((room.seat_profiles as Dictionary).has(2) and not (room.seat_profiles as Dictionary).has(0), "seat_move", "Profile did not move with seat")
	rooms.clear_seat_metadata(room, 2)
	h.expect((room.seat_profiles as Dictionary).is_empty(), "seat_clear", "Released seat retained previous profile")
	lobby.queue_free()
	profile.queue_free()
	feb.queue_free()
	await get_tree().process_frame
	PlayerProfile.active_pet = saved_pet
	AccountManager.profile = saved_profile
	NetworkService.team_active = saved_active
	NetworkService.team_seat_profiles = saved_seats
	h.finish(get_tree())
