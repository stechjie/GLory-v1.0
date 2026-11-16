extends Node

# 进摆放界面头几帧画的是哪张皮肤（11.16 查「选了皮肤进去先闪一下原皮」）。
# 跑法：godot --path . --resolution 1600x720 res://tools/prep_skin_first_frames_capture.tscn -- --out <绝对目录> [--skin id] [--staged]
# 皮肤在建界面之前就定好，然后从 add_child 那一帧起每帧截一张。

const PrepSkin := preload("res://scenes/prep/PrepSkin.gd")
const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"
const FRAMES := 24


func _ready() -> void:
	var out_dir := "user://skin_flash"
	var skin_id := "prep_skin_sakura"
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--out" and i + 1 < args.size():
			out_dir = args[i + 1]
		if args[i] == "--skin" and i + 1 < args.size():
			skin_id = args[i + 1]
	var staged := "--staged" in args
	DirAccess.make_dir_recursive_absolute(out_dir)
	DataRegistry.ensure_loaded()
	GameState.reset_run()
	GameState.round_index = 3
	GameState.last_harvest_round = 3
	PrepSkin.active_id = skin_id
	PrepSkin.loaded = true
	await get_tree().create_timer(0.5).timeout
	var prep: Control = (load(PREP_SCENE) as PackedScene).instantiate()
	prep.startup_staged = staged
	add_child(prep)
	for i in FRAMES:
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		image.resize(800, 360, Image.INTERPOLATE_BILINEAR)
		image.save_png("%s/%s_%02d.png" % [out_dir, "staged" if staged else "plain", i])
	print("PREP_SKIN_FIRST_FRAMES done -> ", out_dir)
	get_tree().quit(0)
