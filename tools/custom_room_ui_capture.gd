extends Node

# 「自定义房间」面板（方案C · 雾林夜幕）的真图截图。
#
# 为什么要有它：门禁能断言「按钮多高、三态底色不一样」，但回答不了「好不好看」。
# 设计稿在 桌面\自定义功能界面布局\（方案C_设计规范.md + c_empty/c_rooms/c_spec.png），
# 这里按**生产代码**渲染同一组状态出图，交给人眼跟设计稿对。
#
# 必须**不带** --headless：headless 是 dummy 渲染后端，抓出来是空图
#   （同 ui_gallery_capture.gd / startup_ui_capture.gd 的既有约束）。
#   godot --path . res://tools/custom_room_ui_capture.tscn
# 输出：reports/custom_room/*.png

const MainMenuScene := preload("res://scenes/menu/MainMenu.tscn")
const MainMenuScript := preload("res://scenes/menu/MainMenu.gd")

const OUT_DIR := "res://reports/custom_room"
const VIEWPORT_SIZE := Vector2i(1600, 900)
# 面板入场是淡入 + 缩放，抓早了会拍到半透明的中间帧。
const SETTLE_FRAMES := 10

var _shots := 0


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("custom_room_ui_capture 需要真实渲染后端，请去掉 --headless")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	get_window().size = VIEWPORT_SIZE
	await _capture_all()
	print("CUSTOM_ROOM_CAPTURE shots=%d dir=%s" % [_shots, OUT_DIR])
	get_tree().quit(0)


func _capture_all() -> void:
	for locale in ["zh", "en"]:
		LocaleManager.set_locale(locale)
		await _capture_states(locale)


func _capture_states(locale: String) -> void:
	# 主菜单留在树里当背景：设计稿里面板是压在暗色丛林背景上的，纯色背景对不出
	# 「深色半透明」到底融不融得进去。
	var menu: MainMenuScript = MainMenuScene.instantiate()
	add_child(menu)
	await _settle(SETTLE_FRAMES)

	var panel: Control = menu._build_room_panel()
	var modal_id := ModalStack.push(panel, {
		"id": MainMenuScript.ROOM_MODAL_ID,
		"owner": menu,
		"priority": MainMenuScript.ROOM_MODAL_PRIORITY,
		"dismiss_on_backdrop": true,
	})
	await _settle(SETTLE_FRAMES)

	# ① 空列表态
	menu.show_room_list([])
	await _settle(SETTLE_FRAMES)
	await _shot("custom_room_empty_%s" % locale)

	# ② 有房间：常态 / 悬停 / 满员三态各一行
	menu.show_room_list([
		{"id": 101, "players": 2, "max": 6},
		{"id": 202, "players": 4, "max": 6},
		{"id": 303, "players": 6, "max": 6},
	])
	await _settle(SETTLE_FRAMES)
	await _shot("custom_room_rooms_%s" % locale)

	# ③ 悬停第一行（人数变亮金、底板提到白 @11%）。push_input 一条鼠标移动事件，
	#    真机上这条路径由操作系统喂进来，截图里只能自己造。
	var row := _first_row(menu)
	if row != null:
		var center := row.get_global_rect().get_center()
		var motion := InputEventMouseMotion.new()
		motion.position = center
		motion.global_position = center
		get_viewport().push_input(motion)
		await _settle(4)
		print("  row_hovered=%s at %s" % [str(row.get_global_rect().has_point(center)), str(center)])
		await _shot("custom_room_hover_%s" % locale)

	# ④ 失败提示（左栏状态行）
	menu.show_room_error("room_full")
	await _settle(3)
	await _shot("custom_room_status_%s" % locale)

	ModalStack.pop(modal_id, "capture")
	await _settle(3)
	menu.queue_free()
	await _settle(2)


func _first_row(menu: MainMenuScript) -> Button:
	var box = menu.get("_room_list_box")
	if box == null:
		return null
	for child in (box as Node).get_children():
		if child is Button:
			return child as Button
	return null


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	var err := image.save_png(path)
	if err == OK:
		_shots += 1
		print("  saved %s (%dx%d)" % [path, image.get_width(), image.get_height()])
	else:
		push_error("保存失败 %s: %d" % [path, err])
