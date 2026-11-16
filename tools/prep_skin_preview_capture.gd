extends Node

# 不开编辑器、直接重拍棋盘皮肤卡片用的 preview.png（11.16 换萝卜 / 卷轴后用）。
# 走的就是皮肤预览场景（scenes/debug/PrepSkinReview）的「生成预览图」那一套：真的摆放界面 + 固定棋子。
# 跑法（要渲染，别加 --headless；分辨率要和预览场景截图的裁剪框对得上）：
#   godot --path . --resolution 1600x720 res://tools/prep_skin_preview_capture.tscn -- prep_skin_sakura prep_skin_nightwisp
# 写完要再跑一次 `godot --headless --path . --import`，新图才会被导入。

const REVIEW_SCENE := "res://scenes/debug/PrepSkinReview.tscn"
const SETTLE_SEC := 3.0   # 等棋子、特效、河面都动起来再拍


func _ready() -> void:
	DataRegistry.ensure_loaded()
	var args := Array(OS.get_cmdline_user_args())
	# --shots <目录>：只截整屏核对（商店关着 / 打开各一张），不写 preview.png
	var shots_dir := ""
	var at := args.find("--shots")
	if at >= 0 and at + 1 < args.size():
		shots_dir = str(args[at + 1])
		args.remove_at(at + 1)
		args.remove_at(at)
	var skins := args
	if skins.is_empty():
		push_error("要给皮肤 id，例如 -- prep_skin_sakura")
		get_tree().quit(1)
		return
	var review: Control = (load(REVIEW_SCENE) as PackedScene).instantiate()
	add_child(review)
	await get_tree().create_timer(1.0).timeout
	var failed := 0
	for skin_id in skins:
		await review.show_skin(str(skin_id))
		await get_tree().create_timer(SETTLE_SEC).timeout
		if not shots_dir.is_empty():
			DirAccess.make_dir_recursive_absolute(shots_dir)
			for open in [false, true]:
				review.shop_open_box.button_pressed = open
				await get_tree().create_timer(1.2).timeout
				review.get("_toolbar_layer").visible = false
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png("%s/%s_%s.png" % [shots_dir, skin_id, "shop_open" if open else "shop_closed"])
				review.get("_toolbar_layer").visible = true
			review.shop_open_box.button_pressed = false
			print("PREP_SKIN_SHOTS %s" % skin_id)
			continue
		var path: String = await review.save_preview()
		print("PREP_SKIN_PREVIEW %s -> %s" % [skin_id, path if not path.is_empty() else "FAILED"])
		if path.is_empty():
			failed += 1
	get_tree().quit(1 if failed > 0 else 0)
