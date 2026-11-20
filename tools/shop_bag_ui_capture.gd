extends Node

# 商店 / 背包的真实控件截图。固定数据只存在这个工具里，不进入玩家存档或网络请求。
# 必须使用真实渲染后端：
#   Godot_v4.7-stable_win64_console.exe --path . res://tools/shop_bag_ui_capture.tscn

const SHOP := preload("res://scenes/menu/ShopScreen.gd")
const DIAMOND_STORE := preload("res://scenes/menu/DiamondStoreDialog.gd")
const PET_DRAW := preload("res://scenes/menu/PetDrawDialog.gd")
const BAG := preload("res://scenes/menu/BagScreen.gd")
const RACE_TRIAL := preload("res://ui/components/RaceTrialDialog.gd")
const MAIL := preload("res://scenes/menu/MailScreen.tscn")
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
	await _capture_shop_frames()
	await _capture_shop_diamonds()
	await _capture_pet_draw()
	await _capture_shop_event()
	await _capture_shop_appearance()
	await _capture_bag_trials()
	await _capture_bag_empty_tab()
	await _capture_race_trial_dialog()
	await _capture_mail()
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
			"currency": "coin", "price": 500, "name": "蘑菇", "name_en": "Mushroom"},
		{"id": "shop_pet_cat", "kind": "pet", "grants": "pet_cat",
			"currency": "coin", "price": 500, "name": "猫", "name_en": "Cat"},
		{"id": "shop_pet_rabbit", "kind": "pet", "grants": "pet_rabbit",
			"currency": "coin", "price": 500, "name": "兔子", "name_en": "Rabbit"},
	])
	shop.set("_active_pet", "pet_mushroom")
	shop.set("_selected_item_id", "shop_pet_cat")
	_show(shop)
	await _settle_and_shot("shop_pets_1280")
	_clear_screen()


func _capture_shop_frames() -> void:
	var shop := SHOP.new()
	shop.set_meta("ui_capture_fixture", true)
	shop.set("_loading", false)
	shop.set("_coin", 1250)
	shop.set("_active_category", "frame")
	shop.set("_owned", {"preset:avatar_frame_shop_01": true})
	shop.set("_selected_item_id", "shop_frame_frost")
	_show(shop)
	await _settle_and_shot("shop_frames_1280")
	_clear_screen()


func _capture_shop_diamonds() -> void:
	var dialog := DIAMOND_STORE.new()
	dialog.set_meta("ui_capture_fixture", true)
	dialog.set("_balance", 500)
	_show(dialog)
	await _settle_and_shot("diamond_store_dialog_1280")
	_clear_screen()
	# Steam 电脑版：价格是服务器给的 steam_charge；等确认窗口等久了，底下多出「改用浏览器付款」。
	dialog = DIAMOND_STORE.new()
	dialog.set_meta("ui_capture_fixture", true)
	dialog.set("_balance", 500)
	_show(dialog)
	dialog.set("_prices", DIAMOND_STORE.steam_prices([
		{"id": "diamond_pack_1", "steam_charge": {"currency": "MYR", "amount": 500}},
		{"id": "diamond_pack_2", "steam_charge": {"currency": "MYR", "amount": 2000}},
		{"id": "diamond_pack_3", "steam_charge": {"currency": "MYR", "amount": 5000}},
	]))
	dialog.call("_render")
	dialog.call("_set_foot", "请在 Steam 弹出的窗口里确认付款。")
	(dialog.get("_web_button") as Control).visible = true
	await _settle_and_shot("diamond_store_steam_waiting_1280")
	_clear_screen()


func _capture_pet_draw() -> void:
	var dialog := PET_DRAW.new()
	_show(dialog)
	await _settle_and_shot("pet_draw_dialog_1280")
	_clear_screen()


func _capture_shop_event() -> void:
	var shop := _fixture_shop_special("seven_day")
	_show(shop)
	await _settle_and_shot("shop_seven_day_1280")
	_clear_screen()


func _capture_shop_appearance() -> void:
	var shop := _fixture_shop_special("prep_skin")
	_show(shop)
	await _settle_and_shot("shop_appearance_1280")
	_clear_screen()


func _fixture_shop_special(category: String) -> Control:
	var shop := SHOP.new()
	shop.set_meta("ui_capture_fixture", true)
	shop.set("_loading", false)
	shop.set("_diamond", 400)
	shop.set("_coin", 900)
	shop.set("_active_category", category)
	shop.set("_items", [{"id": "shop_pet_mushroom", "kind": "pet", "grants": "pet_mushroom",
		"currency": "coin", "price": 500, "name": "蘑菇", "name_en": "Mushroom"},
		{"id": "shop_pet_cat", "kind": "pet", "grants": "pet_cat",
		"currency": "coin", "price": 500, "name": "猫", "name_en": "Cat"},
		{"id": "shop_pet_rabbit", "kind": "pet", "grants": "pet_rabbit",
		"currency": "coin", "price": 500, "name": "兔子", "name_en": "Rabbit"}])
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(
		"res://data/seven_day_login.json"))
	var rewards: Array = (raw as Dictionary).get("rewards", [])
	# 10.01：claimed_days 必须写成 **float**。真实链路是
	# AccountManager.fetch_seven_day_login() -> JSON.parse_string()，Godot 把 JSON
	# 数字一律解析成 float；而 Godot 4 的 `int in Array` 是类型严格比较，恒为 false。
	# 原来这里写 [1, 2, 3]（int）正好绕开了那个 bug —— 截图永远是「正确」的，
	# 于是没人发现线上领过的天数一直显示「未解锁」。夹具要跟线上同型。
	shop.set("_login_state", {"current_day": 4, "claimed_days": [1.0, 2.0, 3.0],
		"claimable_today": true, "completed": false, "ice_skin_progress": 3,
		"rewards": rewards})
	return shop


func _capture_mail() -> void:
	MailService.apply_list([{
		"id": 1, "title_zh": "分发宝石金币", "body_zh": "分发宝石金币",
		"title_en": "Rewards", "body_en": "Your rewards are enclosed.",
		"diamond": 10000, "coin": 10000, "items": [], "age_sec": 64800,
		"expires_in_sec": 2505600, "read": true, "claimed": true,
	}])
	_show(MAIL.instantiate())
	await _settle_and_shot("mail_single_1280")
	_clear_screen()
	MailService.reset()


# 背包接口 body 的固定一份（BagScreen._adopt 吃的就是它）：三种体验卡、三种天数，一张目标已永久拥有。
const BAG_FIXTURE := {
	"cards": [
		{"target": "dark", "kind": "race", "days": 3, "count": 2, "sell_price": 200, "owned": false},
		{"target": "dark", "kind": "race", "days": 7, "count": 1, "sell_price": 300, "owned": false},
		{"target": "pet_tiger", "kind": "pet", "days": 1, "count": 1, "sell_price": 100, "owned": false},
		{"target": "prep_skin_sakura", "kind": "prep_skin", "days": 7, "count": 1, "sell_price": 300, "owned": true},
	],
	"trials": [{"target": "dark", "kind": "race", "expires_at": "2026-11-23T10:00:00Z"}],
	"server_now": "2026-11-20T10:00:00Z",
}


func _fixture_bag() -> Control:
	var bag := BAG.new()
	bag.set_meta("ui_capture_fixture", BAG_FIXTURE)
	return bag


func _capture_bag_trials() -> void:
	_show(_fixture_bag())
	await _settle_and_shot("bag_trials_1280")
	_clear_screen()


func _capture_bag_empty_tab() -> void:
	var bag := _fixture_bag()
	_show(bag)
	bag.call("_select_tab", "gifts")
	await _settle_and_shot("bag_empty_gifts_1280")
	_clear_screen()


func _capture_race_trial_dialog() -> void:
	var dialog: Control = RACE_TRIAL.new()
	dialog.call("configure", "dark")
	dialog.set_meta("ui_capture_fixture", true)
	_show(dialog)
	dialog.set("_coin", 250)
	dialog.set("_bought", [3])
	dialog.call("_render_offer")
	await _settle_and_shot("race_trial_dialog_1280")
	_clear_screen()

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
