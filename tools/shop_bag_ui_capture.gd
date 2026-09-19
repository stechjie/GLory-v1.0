extends Node

# 商店 / 背包的真实控件截图。固定数据只存在这个工具里，不进入玩家存档或网络请求。
# 必须使用真实渲染后端：
#   Godot_v4.7-stable_win64_console.exe --path . res://tools/shop_bag_ui_capture.tscn

const SHOP := preload("res://scenes/menu/ShopScreen.gd")
const BAG := preload("res://scenes/menu/BagScreen.gd")
const WINDOW := Vector2i(1280, 720)
const OUT_DIR := "res://reports/shop_bag_ui"
const SETTLE_FRAMES := 24

var _screen: Control = null


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("shop_bag_ui_capture needs a real rendering backend")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	DisplayServer.window_set_size(WINDOW)
	for _i in 5:
		await get_tree().process_frame

	await _capture_shop()
	await _capture_bag_pets()
	await _capture_bag_avatars()
	print("SHOP_BAG_UI_CAPTURE dir=%s" % OUT_DIR)
	get_tree().quit(0)


func _capture_shop() -> void:
	var shop := SHOP.new()
	shop.set_meta("ui_capture_fixture", true)
	shop.set("_loading", false)
	shop.set("_diamond", 500)
	shop.set("_coin", 1250)
	shop.set("_owned", {"pet_mushroom": true})
	shop.set("_items", [
		{"id": "shop_pet_mushroom", "kind": "pet", "grants": "pet_mushroom",
			"currency": "diamond", "price": 300, "name": "蘑菇", "name_en": "Mushroom"},
		{"id": "shop_pet_cat", "kind": "pet", "grants": "pet_cat",
			"currency": "diamond", "price": 300, "name": "猫", "name_en": "Cat"},
		{"id": "shop_pet_rabbit", "kind": "pet", "grants": "pet_rabbit",
			"currency": "diamond", "price": 800, "name": "兔子", "name_en": "Rabbit"},
		{"id": "shop_avatar_dragon", "kind": "avatar", "grants": "preset:avatar_005",
			"currency": "coin", "price": 900, "name": "暗黑巨龙", "name_en": "Dark Dragon"},
	])
	shop.set("_selected_item_id", "shop_pet_cat")
	_show(shop)
	await _settle_and_shot("shop_featured_1280")
	_clear_screen()


func _capture_bag_pets() -> void:
	var bag := _fixture_bag()
	bag.set("_active_tab", "pets")
	bag.set("_selected_pet", "pet_cat")
	_show(bag)
	await _settle_and_shot("bag_pets_1280")
	_clear_screen()


func _capture_bag_avatars() -> void:
	var bag := _fixture_bag()
	bag.set("_active_tab", "avatars")
	bag.set("_selected_avatar", "preset:avatar_005")
	_show(bag)
	await _settle_and_shot("bag_avatars_1280")
	_clear_screen()


func _fixture_bag() -> Control:
	var bag := BAG.new()
	bag.set_meta("ui_capture_fixture", true)
	bag.set("_loading", false)
	bag.set("_owned_pets", ["pet_mushroom", "pet_cat", "pet_rabbit"])
	bag.set("_active_pet", "pet_cat")
	bag.set("_paid_content", {})
	bag.set("_sold_content", {})
	return bag


func _show(screen: Control) -> void:
	_screen = screen
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(screen)


func _clear_screen() -> void:
	if _screen == null:
		return
	remove_child(_screen)
	_screen.queue_free()
	_screen = null


func _settle_and_shot(name: String) -> void:
	for _i in SETTLE_FRAMES:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name]
	var error := image.save_png(path)
	if error != OK:
		push_error("Could not save %s: %s" % [path, error_string(error)])
	else:
		print("CAPTURED %s" % path)
