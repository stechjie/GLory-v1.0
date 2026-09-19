extends Node

# 把公告界面、登录弹窗、顶部横条、启动画面的维护说明真渲染出来存图（docs/公告系统设计.md）。
#
# 为什么需要它：tools/announcement_check 验的是合同（白名单、常量、弹不弹），
# 回答不了「摆得好不好看、图有没有被拉伸、长标题有没有被截」。同 chat_ui_capture 的理由。
#
# ⚠️ **必须不带 --headless 运行**：headless 是 dummy 渲染后端，抓出来是空图。
#   Godot_v4.7.1-stable_win64_console.exe --path . res://tools/announcement_ui_capture.tscn
# 输出：reports/announcement_ui/*.png
#
# 不联网：样例图直接写进本机图片缓存（哈希对得上就不会去下载），跑完删掉；「看过」的记录不落盘。

const SCREEN_SCENE := preload("res://scenes/menu/AnnouncementScreen.tscn")
const MENU_SCENE_PATH := "res://scenes/menu/MainMenu.tscn"
const BOOTSTRAP_SCENE := preload("res://scenes/bootstrap/Bootstrap.tscn")
const PopupScript := preload("res://scenes/menu/AnnouncementPopup.gd")
const Images := preload("res://scripts/account/AnnouncementImages.gd")
const Service := preload("res://scripts/autoload/AnnouncementService.gd")

const OUT_DIR := "res://reports/announcement_ui"
const SETTLE_FRAMES := 20
const REFERENCE := Vector2i(1672, 941)
# 矮窗口：同 chat_ui_capture 的 PREP_WINDOW，941 高时看不出的挤压在 720 高才出来。
const SHORT := Vector2i(1280, 720)

# 标题上限 60 字（database/008 的 announcement_title_zh），取接近上限的长度看截断。
const LONG_TITLE := "夏日限定活动：连续登录七天领取限定头像框与大量萝卜，第七天还有额外惊喜等你来拿"
const LONG_BODY := "本次更新内容：\n1. 新增公告栏与登录弹窗。\n2. 修复备战界面商店按钮在部分机型上被遮挡的问题。\n3. 调整四星技能的数值，详见图鉴。\n4. 优化弱网环境下的重连体验。\n5. 修复语音在切换耳机后没有声音的问题。\n6. 其它若干稳定性改进。\n\n[b]注意[/b]：更新后首次启动需要重新下载部分资源，请在 Wi-Fi 环境下更新。\n如遇问题请在设置里提交问题报告。"

var _shots := 0
var _cache_files: Array[String] = []


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("announcement_ui_capture 需要真实渲染后端，请去掉 --headless")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	AnnouncementService.seen_file = ""
	var wide := _cache_image(1200, 600)
	var square := _cache_image(800, 800)
	AnnouncementService.apply_list(_fixture(wide, square))
	# 列表里有一条紧急公告，apply_list 会顺手出横条；前面几张图不要它，最后单独拍。
	AnnouncementService.hide_banner()

	DisplayServer.window_set_size(REFERENCE)
	await _capture_menu()
	await _capture_screen("screen_event_with_image", 901)
	await _capture_screen("screen_long_body", 902)
	await _capture_screen("screen_square_image_preview", 903)
	await _capture_banner()

	DisplayServer.window_set_size(SHORT)
	await _capture_screen("screen_1280x720", 901)
	await _capture_popup("popup_1280x720", 901)

	var previous_locale := LocaleManager.get_locale()
	LocaleManager.set_locale("en")
	DisplayServer.window_set_size(REFERENCE)
	await _capture_screen("screen_english", 901)
	LocaleManager.set_locale(previous_locale)

	await _capture_maintenance()

	for path in _cache_files:
		DirAccess.remove_absolute(path)
	AnnouncementService.reset()
	AnnouncementService.seen_file = Service.SEEN_FILE
	print("ANNOUNCEMENT_UI_CAPTURE shots=%d dir=%s" % [_shots, OUT_DIR])
	get_tree().quit(0)


# 渐变底 + 8 像素白边 + 正中一个白色正方形：正方形被压扁 / 拉长一眼就看得出。
func _cache_image(width: int, height: int) -> Dictionary:
	var image := Image.create_empty(width, height, false, Image.FORMAT_RGB8)
	var top := Color(0.93, 0.62, 0.22)
	var bottom := Color(0.18, 0.26, 0.55)
	for y in height:
		image.fill_rect(Rect2i(0, y, width, 1), top.lerp(bottom, float(y) / float(height - 1)))
	for edge in [Rect2i(0, 0, width, 8), Rect2i(0, height - 8, width, 8), Rect2i(0, 0, 8, height), Rect2i(width - 8, 0, 8, height)]:
		image.fill_rect(edge, Color.WHITE)
	image.fill_rect(Rect2i(width / 2 - 60, height / 2 - 60, 120, 120), Color.WHITE)
	var bytes := image.save_png_to_buffer()
	var sha := Images.sha256_hex(bytes)
	var path := Images.cache_path(sha, "png")
	DirAccess.make_dir_recursive_absolute(Images.CACHE_DIR)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	_cache_files.append(path)
	return {"url": "/media/%s.png" % sha, "sha256": sha, "width": width, "height": height, "size": bytes.size()}


func _fixture(wide: Dictionary, square: Dictionary) -> Array:
	var now := int(Time.get_unix_time_from_system())
	var list := [
		{"id": 901, "revision": 1, "kind": "event", "title_zh": LONG_TITLE, "title_en": "Summer login event",
			"body_zh": "活动期间每天登录都能领奖励。\n[b]第 7 天[/b]额外送 [color=#FFCC00]限定头像框[/color]。\n[url=glory://prep]去备战看看[/url]\n[img]res://icon.svg[/img] 这一段是被白名单挡掉的图片标签。",
			"body_en": "Log in every day during the event for rewards.\n[b]Day 7[/b] adds a [color=#FFCC00]limited avatar frame[/color].\n[url=glory://prep]Go to Prep[/url]",
			"image": wide, "popup": true, "starts_at": now - 3600, "ends_at": now + 7 * 86400,
			"preview": false, "problem": ""},
		{"id": 902, "revision": 1, "kind": "update", "title_zh": "9 月 20 日版本更新说明", "title_en": "",
			"body_zh": LONG_BODY, "body_en": "", "image": null, "popup": false,
			"starts_at": now - 7200, "ends_at": null, "preview": false, "problem": ""},
		{"id": 903, "revision": 1, "kind": "news", "title_zh": "图片比例不对的草稿", "title_en": "",
			"body_zh": "正方形的图放进 2:1 的框里，应当居中留边，不拉伸。", "body_en": "", "image": square,
			"popup": false, "starts_at": now + 86400, "ends_at": null, "preview": true,
			"problem": "预览好友码格式不对：12345"},
		{"id": 904, "revision": 1, "kind": "urgent", "title_zh": "10 分钟后停服维护，请勿开新局", "title_en": "",
			"body_zh": "", "body_en": "", "image": null, "popup": false,
			"starts_at": now - 60, "ends_at": now + 1800, "preview": false, "problem": ""},
	]
	for i in 6:
		list.append({"id": 910 + i, "revision": 1, "kind": "news", "title_zh": "系统公告第 %d 条" % (i + 1),
			"title_en": "", "body_zh": "占位正文。", "body_en": "", "image": null, "popup": false,
			"starts_at": now - 86400 * (i + 1), "ends_at": null, "preview": false, "problem": ""})
	return list


func _settle() -> void:
	for _i in SETTLE_FRAMES:
		await get_tree().process_frame


func _capture_menu() -> void:
	var scene := load(MENU_SCENE_PATH) as PackedScene
	var menu := scene.instantiate() as Control
	menu.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(menu)
	await _settle()
	await _shot("menu_news_dot")
	var popup = PopupScript.new()
	var modal_id := ModalStack.push(popup, {"id": "capture_popup", "owner": menu, "priority": 20,
		"dismiss_on_backdrop": true})
	popup.configure(AnnouncementService.find_item(901))
	await _settle()
	await _shot("popup_over_menu")
	ModalStack.pop(modal_id)
	remove_child(menu)
	menu.queue_free()
	await get_tree().process_frame


func _capture_screen(shot_name: String, focus_id: int) -> void:
	var screen = SCREEN_SCENE.instantiate()
	screen.configure(focus_id)
	add_child(screen)
	await _settle()
	await _shot(shot_name)
	remove_child(screen)
	screen.queue_free()
	await get_tree().process_frame


func _capture_popup(shot_name: String, focus_id: int) -> void:
	var bg := TextureRect.new()
	bg.texture = preload("res://assets/ui/main_menu_live/background.png")
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var popup = PopupScript.new()
	var modal_id := ModalStack.push(popup, {"id": "capture_popup", "priority": 20, "dismiss_on_backdrop": true})
	popup.configure(AnnouncementService.find_item(focus_id))
	await _settle()
	await _shot(shot_name)
	ModalStack.pop(modal_id)
	remove_child(bg)
	bg.queue_free()


func _capture_banner() -> void:
	var screen = SCREEN_SCENE.instantiate()
	screen.configure(901)
	add_child(screen)
	AnnouncementService.show_banner({"id": 999, "revision": 1,
		"title_zh": "10 分钟后停服维护，请尽快结束对局。维护预计 30 分钟，结束后自动恢复，不用重新下载。"})
	await _settle()
	await _shot("banner_over_screen")
	AnnouncementService.hide_banner()
	remove_child(screen)
	screen.queue_free()
	await get_tree().process_frame


func _capture_maintenance() -> void:
	var boot = BOOTSTRAP_SCENE.instantiate()
	boot.auto_start = false
	boot.auto_transition = false
	boot.entry_gate = false
	add_child(boot)
	await _settle()
	boot._service_status = {"title_zh": "服务器维护中", "message_zh": "预计 18:00 恢复。维护期间无法进入游戏。",
		"title_en": "", "message_en": ""}
	boot._show_entry({"state": "maintenance", "actions": true})
	await _settle()
	await _shot("bootstrap_maintenance")
	boot._service_status = {"title_zh": "", "message_zh": "", "title_en": "", "message_en": ""}
	boot._show_entry({"state": "maintenance", "actions": true})
	await _settle()
	await _shot("bootstrap_maintenance_defaults")
	remove_child(boot)
	boot.queue_free()


func _shot(shot_name: String) -> void:
	for _i in 3:
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
