extends SceneTree

const OUT := "res://reports/main_menu_buttons_20261105/"
var textures: Dictionary = {}

func _initialize() -> void:
	run.call_deferred()

func replace_art(node: Node) -> void:
	if node is TextureRect and node.texture != null:
		var old: String = node.texture.resource_path
		if old.begins_with("res://assets/ui/main_menu_live/"):
			var key: String = old.get_file().get_basename()
			if textures.has(key):
				node.texture = textures[key]
	for child in node.get_children():
		replace_art(child)

func run() -> void:
	root.get_node("SaveManager").set("_save_pending", true)
	root.get_node("NetworkService").set_process(false)
	for key in ["background", "mail", "bag", "settings", "friends", "chat", "prep", "casual", "ranked", "custom", "gallery", "shop", "news", "profile_avatar", "profile_panel"]:
		textures[key] = ImageTexture.create_from_image(Image.load_from_file(OUT + key + ".png"))
	# Select the nameplate's painted region for layout; keep its source PNG intact.
	var profile_plate := AtlasTexture.new()
	profile_plate.atlas = textures["profile_panel"]
	profile_plate.region = Rect2(17, 156, 2133, 389)
	textures["profile_panel"] = profile_plate
	DisplayServer.window_set_size(Vector2i(1672, 941))
	var menu = load("res://tools/main_menu_art_preview_scene.gd").new()
	root.add_child(menu)
	menu.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await create_timer(2.0).timeout
	replace_art(menu)
	await create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OUT + "main_menu_profile_preview.png")
	print("MAIN_MENU_ART_PREVIEW_COMPLETE")
	menu.queue_free()
	await process_frame
	textures.clear()
	quit()
