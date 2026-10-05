extends SceneTree

const OUT_DIR := "C:/Users/Leno/Documents/Glory prep screen"
const AVATARS := preload("res://scripts/account/AvatarCatalog.gd")

func _initialize() -> void:
	call_deferred("_capture")

func _capture() -> void:
	root.size = Vector2i(1672, 941)
	root.get_node("/root/LocaleManager").call("set_locale", "zh_CN")
	var scene := load("res://scenes/menu/PartyLobby.tscn") as PackedScene
	for role in ["host", "guest"]:
		var lobby := scene.instantiate()
		lobby.configure_preview(role)
		root.add_child(lobby)
		for frame in range(150):
			await process_frame
		if role == "host":
			var seat_layer: Control = lobby.get("_seat_layer")
			var first_seat: Control = seat_layer.get_child(0)
			for visual in first_seat.get_children():
				if visual is TextureRect:
					print("PARTY_RECT ", visual.position, " ", visual.size,
						" minimum=", visual.get_combined_minimum_size(),
						" stretch=", visual.stretch_mode)
		var image := root.get_texture().get_image()
		var path := "%s/party_lobby_%s.png" % [OUT_DIR, role]
		var result := image.save_png(path)
		print("PARTY_CAPTURE ", path, " result=", result,
			" size=", image.get_size())
		if role == "host":
			lobby.call("_toggle_friends_drawer")
			for frame in range(5):
				await process_frame
			var friends_image := root.get_texture().get_image()
			var friends_path := "%s/party_lobby_friends.png" % OUT_DIR
			print("PARTY_CAPTURE ", friends_path, " result=", friends_image.save_png(friends_path))
			lobby.call("_toggle_friends_drawer")
			lobby.call("_toggle_chat")
			lobby.call("_toggle_pets_drawer")
			print("PARTY_CONTROLS chat_expanded=", lobby.get("_chat_expanded"),
				" pets_open=", (lobby.get("_pets_drawer") as Panel).visible)
		else:
			print("PARTY_CONTROLS guest_pet_button=", (lobby.get("_pet_toggle") as Button).visible)
		root.remove_child(lobby)
		lobby.queue_free()
	for frame in range(2):
		await process_frame
	root.size = Vector2i(1600, 720)
	var account := root.get_node("/root/AccountManager")
	account.set("player_name", "本机玩家")
	account.set("profile", {"friend_code": "TEST0001", "player_name": "本机玩家",
		"avatar": AVATARS.default_avatar(), "avatar_frame": AVATARS.default_frame()})
	var owned: Array = root.get_node("/root/PlayerProfile").get("owned_pets")
	owned.clear()
	owned.append_array(["pet_cat", "pet_rabbit", "pet_mushroom"])
	var fallback := scene.instantiate()
	root.add_child(fallback)
	for frame in range(30):
		await process_frame
	fallback.set("_load_error", "组队服务未更新（404）")
	fallback.call("_show_local_identity")
	for frame in range(150):
		await process_frame
	var fallback_image := root.get_texture().get_image()
	var fallback_path := "%s/party_lobby_local_fallback.png" % OUT_DIR
	print("PARTY_CAPTURE ", fallback_path, " result=", fallback_image.save_png(fallback_path))
	var live_pets: Array = (fallback.get("_stage") as Node).get("_pets")
	print("PARTY_LOCAL seat_count=", (fallback.get("_seat_layer") as Control).get_child_count(),
		" pet_count=", live_pets.size(),
		" action_disabled=", (fallback.get("_action") as Button).disabled)
	root.remove_child(fallback)
	fallback.queue_free()
	quit()
