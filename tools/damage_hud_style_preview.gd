extends Node
## Visual QA only: official reference above the actual production HUD at 2.5x.
## Does not change player options, battle statistics or production resources.
const HUD := preload("res://effects/runtime/presentation/BattleCombatFeedback.gd")
var _out := ""

func _ready() -> void:
	call_deferred("_run")

func _heading(text: String, at: Vector2) -> void:
	var label := Label.new()
	label.text = text
	label.position = at
	label.add_theme_font_size_override("font_size",22)
	add_child(label)

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()-1):
		if args[i] == "--out":
			_out = ProjectSettings.globalize_path(args[i+1])
	if _out.is_empty() or DirAccess.dir_exists_absolute(_out):
		push_error("HUD_STYLE_PREVIEW requires fresh --out")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	var bg := ColorRect.new()
	bg.color = Color("131c31")
	bg.size = Vector2(1600,720)
	add_child(bg)
	_heading("OFFICIAL BAYONETTA 2 / Combo Points / reference image, enlarged 3x",Vector2(40,18))
	var source := Image.load_from_file(ProjectSettings.globalize_path("res://").path_join("reports/bayo_damage_v5/official_reference_07.jpg"))
	var atlas := AtlasTexture.new()
	atlas.atlas = ImageTexture.create_from_image(source)
	atlas.region = Rect2(806,125,198,74)
	var reference := TextureRect.new()
	reference.texture = atlas
	reference.position = Vector2(40,62)
	reference.size = Vector2(594,222)
	reference.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	add_child(reference)
	_heading("YOUR GAME / production Damage widget / enlarged 2.5x",Vector2(40,305))
	var wrapper := Control.new()
	wrapper.size = Vector2(1600,720)
	wrapper.scale = Vector2.ONE*2.5
	wrapper.position = Vector2(20,7.5)
	add_child(wrapper)
	var hud := HUD.new()
	wrapper.add_child(hud)
	hud.show_damage(320000,false,11)
	for i in range(8):
		await get_tree().process_frame
	await _capture("rest")
	hud.show_damage(160000,false,11)
	hud.show_damage(320000,true,11)
	await get_tree().create_timer(0.08).timeout
	await _capture("peak")
	await get_tree().create_timer(0.14).timeout
	await _capture("sweep")
	await get_tree().create_timer(0.40).timeout
	await _capture("settled")
	print("HUD_STYLE_PREVIEW PASS font=%s" % hud._damage_label.get_theme_font("font").get_font_name())
	get_tree().quit()

func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_out.path_join(name+".png"))
