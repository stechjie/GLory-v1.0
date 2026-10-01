extends Node

const PROFILE := preload("res://scenes/menu/ProfileScreen.gd")
const TIERS := preload("res://scenes/menu/RankedTiers.gd")
const OUT := "res://reports/ranked_reward_ui/profile_tier_3_1600.png"


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Profile capture requires a rendering backend")
		get_tree().quit(2)
		return
	DisplayServer.window_set_size(Vector2i(1600, 720))
	var profile := PROFILE.new()
	profile.configure_self()
	add_child(profile)
	for _i in 20:
		await get_tree().process_frame
	var badge: TextureRect = profile.get("_rank_badge")
	var rank_value: Label = profile.get("_rank_value")
	if badge == null or rank_value == null:
		push_error("Profile rank controls were not built")
		get_tree().quit(2)
		return
	badge.texture = TIERS.badge_of(3)
	badge.visible = true
	rank_value.text = "天曜 · 50/200"
	for _i in 10:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var error := get_viewport().get_texture().get_image().save_png(OUT)
	if error != OK:
		push_error("Profile screenshot failed: %s" % error_string(error))
		get_tree().quit(2)
		return
	print("CAPTURED %s" % OUT)
	get_tree().quit(0)
