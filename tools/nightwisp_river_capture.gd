extends Node

# 夜荧光河面流光的前后对比截图（11.16）。
# 跑法：godot --path . --resolution 1600x720 res://tools/nightwisp_river_capture.tscn -- --out <绝对目录>
# 每种做法（before = 旧的滑图，after = 原地流光）隔 0.12 秒截 16 帧，只留下河面那一条。

const PrepSkin := preload("res://scenes/prep/PrepSkin.gd")
const REVIEW_SCENE := "res://scenes/debug/PrepSkinReview.tscn"
const DEFAULT_SKIN := "prep_skin_nightwisp"
const FRAMES := 16
const FRAME_GAP := 0.12


func _ready() -> void:
	var out_dir := "user://nightwisp_river"
	var skin_id := DEFAULT_SKIN
	var wait := -1.0
	var frames := FRAMES
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--out" and i + 1 < args.size():
			out_dir = args[i + 1]
		if args[i] == "--wait" and i + 1 < args.size():   # 进摆放界面后等几秒再截（等花吹雪）
			wait = float(args[i + 1])
		if args[i] == "--frames" and i + 1 < args.size():
			frames = int(args[i + 1])
		if args[i] == "--skin" and i + 1 < args.size():    # 看别的皮肤（配 --full）
			skin_id = args[i + 1]
	DirAccess.make_dir_recursive_absolute(out_dir)
	DataRegistry.ensure_loaded()
	var review: Control = (load(REVIEW_SCENE) as PackedScene).instantiate()
	add_child(review)
	await get_tree().create_timer(1.0).timeout
	var entry := PrepSkin.entry(skin_id)
	var style: Variant = entry.get("river_glow_style", null)
	var full := "--full" in args     # 只截改后的整屏（看左边树下那套特效）
	for label in (["full"] if full else ["before", "after"]):
		if label == "before":
			entry.erase("river_glow_style")
		elif style != null:
			entry["river_glow_style"] = style
		await review.show_skin(skin_id)
		review.get("_toolbar_layer").visible = false
		await get_tree().create_timer(wait if wait >= 0.0 else (7.0 if full else 2.0)).timeout    # 整屏模式多等一会儿，等落花掉下来
		for i in frames:
			await RenderingServer.frame_post_draw
			var image := get_viewport().get_texture().get_image()
			var h := image.get_height()
			if not full:
				image = image.get_region(Rect2i(0, int(h * 0.62), image.get_width(), h - int(h * 0.62)))
			image.save_png("%s/%s_%d.png" % [out_dir, label, i])
			await get_tree().create_timer(FRAME_GAP).timeout
	if full:
		# 特效层开 / 关各量一次整帧的绘制批次数，看它多占了几批
		var fx := review.find_child("PrepNightFx", true, false) as CanvasItem
		for on in [true, false]:
			if fx != null:
				fx.visible = on
			for _i in 12:
				await get_tree().process_frame
			print("NIGHTWISP_FX draw_calls fx=%s -> %d" % [str(on),
				int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))])
	print("NIGHTWISP_RIVER_CAPTURE done -> ", out_dir)
	get_tree().quit(0)
