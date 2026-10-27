extends Node

# Feed the actual local account HTTP response through the game's purchase cards.
const Harness := preload("res://tools/CheckHarness.gd")
const Collection := preload("res://scripts/account/UnitCollection.gd")

class ShopProbe extends "res://scenes/menu/ShopScreen.gd":
	func _ready() -> void:
		pass

var h := Harness.new("local_shop_catalog")

func _ready() -> void:
	var path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--catalog-json="):
			path = arg.trim_prefix("--catalog-json=")
	if not h.expect(FileAccess.file_exists(path), "http_fixture", "Supply the actual account server catalog response"):
		h.finish(get_tree())
		return
	var body: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	h.expect(str(body.get("balance_version", "")) == str(DataRegistry.get_table("final_status").get("balance_version", "")),
		"balance_matches", "Account server and client must use the same balance version")
	var shop := ShopProbe.new()
	shop._items = body.get("items", [])
	shop._coin = 999999
	shop._loading = false
	add_child(shop)
	for locale in ["zh", "en"]:
		LocaleManager.set_locale(locale)
		var items := shop._unit_items()
		h.expect(items.size() == 24, "all_units", "All three races must have their eight shop units")
		for item in items:
			h.expect(not bool(item.get("_catalog_pending", false)), "no_pending", str(item.get("id")))
			var unit: Dictionary = Collection.unit_def(Collection.unit_id_of(str(item.get("grants", ""))))
			var card := shop._unit_card(unit, item)
			var buy := _button(card)
			h.expect(buy != null and not buy.disabled and buy.text == ("Buy" if locale == "en" else "购买"),
				"purchase_available", "Actual unowned unit card must offer its localized purchase button")
			card.free()
	shop.free()
	h.finish(get_tree())

func _button(node: Node) -> Button:
	if node is Button:
		return node as Button
	for child in node.get_children():
		var result := _button(child)
		if result != null:
			return result
	return null
