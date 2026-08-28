extends Node

# 把 Glory UI 组件的每种形态真渲染出来存图（V3 P1-01 验收：组件 gallery 覆盖
# 中英文、短/长文、各意图）。
#
# 为什么不能只靠 ui_component_check：那个检查验的是合同（按钮多高、状态是否可区分、
# 信号发几次），它永远回答不了「好不好看」。而复审里用户点名的就是外观。所以这里
# 出真图，交给人眼判。
#
# 必须**不带** --headless 运行：headless 是 dummy 渲染后端，抓出来的是空图。
#   godot --path . res://tools/ui_gallery_capture.tscn
# 输出：reports/ui_gallery/*.png

const Dialog := preload("res://ui/components/GloryConfirmDialog.gd")
const DIALOG_SCENE := preload("res://ui/components/GloryConfirmDialog.tscn")

const OUT_DIR := "res://reports/ui_gallery"
# 卡片入场是淡入，抓早了会拍到半透明的中间帧。
const SETTLE_FRAMES := 12

var _shots := 0


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("ui_gallery_capture 需要真实渲染后端，请去掉 --headless")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	await _capture_all()
	print("UI_GALLERY shots=%d dir=%s" % [_shots, OUT_DIR])
	get_tree().quit(0)


func _capture_all() -> void:
	# 背景要够亮才看得出 backdrop 的 84% 压住了多少。用纯黑背景截图会骗人：
	# 那样无论遮罩是 60% 还是 95% 看起来都一样。
	var bg := ColorRect.new()
	bg.color = Color(0.62, 0.48, 0.30)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	# 再放几块高对比方块，用来判断遮罩之后背景细节还剩多少可辨。
	for i in 6:
		var tile := ColorRect.new()
		tile.color = Color(0.10, 0.14, 0.22) if i % 2 == 0 else Color(0.86, 0.80, 0.66)
		tile.position = Vector2(60 + i * 250, 60)
		tile.size = Vector2(200, 600)
		add_child(tile)

	await _shot("confirm_danger_zh", {
		"intent": Dialog.Intent.DANGER,
		"title": "跳过新手教学",
		"body": "确定跳过整段新手教学吗？将直接回到主菜单。",
		"confirm_text": "跳过",
		"cancel_text": "继续教学",
	})
	await _shot("confirm_danger_en", {
		"intent": Dialog.Intent.DANGER,
		"title": "Skip Tutorial",
		"body": "Skip the whole tutorial and return to the main menu?",
		"confirm_text": "Skip",
		"cancel_text": "Keep Playing",
	})
	await _shot("confirm_normal_zh", {
		"intent": Dialog.Intent.NORMAL,
		"title": "退出对局",
		"body": "现在离开会保留本局进度，下次可以继续。",
		"confirm_text": "离开",
		"cancel_text": "留下",
	})
	await _shot("info_zh", {
		"intent": Dialog.Intent.INFO,
		"title": "敬请期待",
		"body": "这个功能还在开发中。",
		"confirm_text": "知道了",
	})
	# 长文必须能滚且不把按钮顶出安全区 —— 断线重连的错误文案就是这种长度。
	await _shot("confirm_long_body_zh", {
		"intent": Dialog.Intent.NORMAL,
		"title": "连接失败",
		"body": ("与服务器的连接在等待队友阶段中断了。可以重试一次；如果仍然失败，"
			+ "请检查网络后返回备战页重新开始。本局阵容已经保存，不会丢失。"
			+ "错误码 NET_TIMEOUT_60S，反馈时请一并提供。"),
		"confirm_text": "重试",
		"cancel_text": "返回备战",
	})


func _shot(shot_name: String, spec: Dictionary) -> void:
	var dialog: Control = DIALOG_SCENE.instantiate()
	var modal_id := ModalStack.push(dialog, {"id": "gallery_%s" % shot_name, "owner": self})
	var merged := spec.duplicate()
	merged["request_id"] = shot_name
	dialog.configure(merged)

	for _i in SETTLE_FRAMES:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	var err := image.save_png(path)
	if err == OK:
		_shots += 1
		print("  saved %s (%dx%d)" % [path, image.get_width(), image.get_height()])
	else:
		push_error("保存失败 %s: %d" % [path, err])

	ModalStack.pop(modal_id, "gallery")
	await get_tree().process_frame
