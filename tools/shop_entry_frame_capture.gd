extends Node

# 真渲染检查商店入口三张手绘图和资料页头像框选择器。
const MENU := preload("res://scenes/menu/MainMenu.tscn")
const FRAME_PICKER := preload("res://scenes/menu/FramePickerPanel.gd")
const PROFILE := preload("res://scenes/menu/ProfileScreen.gd")
const OUT_DIR := "res://reports/shop_entry_frame_ui"


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Real renderer required")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	DisplayServer.window_set_size(Vector2i(1600, 720))
	var menu := MENU.instantiate() as Control
	menu.set_meta("ui_capture_fixture", true)
	add_child(menu)
	await _settle()
	menu.remove_meta("ui_capture_fixture")
	menu.call("_refresh_shop_preview")
	_shot("shop_entry_cat")
	await get_tree().create_timer(3.05).timeout
	_shot("shop_entry_rabbit")
	await get_tree().create_timer(3.05).timeout
	_shot("shop_entry_mushroom")
	var old_profile: Dictionary = AccountManager.profile
	AccountManager.profile = {
		"avatar": "preset:avatar_001", "avatar_frame": "preset:avatar_frame_shop_03",
		"player_name": "玩家", "friend_code": "FRAME01", "days_since_created": 12,
	}
	menu.call("_refresh_profile_plate")
	await _settle()
	_shot("shop_entry_owned_frame")
	AccountManager.profile = old_profile
	remove_child(menu)
	menu.queue_free()
	await _settle()
	var owned := {}
	for i in range(1, 6):
		owned["preset:avatar_frame_shop_%02d" % i] = true
	owned["preset:avatar_frame_7day_01"] = true
	var picker := FRAME_PICKER.new() as Control
	picker.call("configure", "preset:avatar_frame_shop_03", owned)
	add_child(picker)
	await _settle()
	_shot("profile_frame_picker")
	remove_child(picker)
	picker.queue_free()
	await _settle()
	var profile := PROFILE.new() as Control
	profile.call("configure_self")
	add_child(profile)
	await _settle()
	profile.set("_data", {
		"avatar": "preset:avatar_001", "avatar_frame": "preset:avatar_frame_shop_03",
		"player_name": "玩家", "friend_code": "FRAME01", "days_since_created": 12,
	})
	profile.call("_refresh")
	await _settle()
	_shot("profile_equipped_frame")
	get_tree().quit(0)


func _settle() -> void:
	for _i in 24:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _shot(name: String) -> void:
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name]
	var error := image.save_png(path)
	if error != OK:
		push_error("Capture failed: %s" % path)
	else:
		print("CAPTURED %s" % path)
