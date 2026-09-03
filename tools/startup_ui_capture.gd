extends Node

# V3 P2-01 截图回归：抓真图。
#
# 覆盖清单点名的几个状态：splash（Bootstrap 首帧）、Bootstrap 正常态、
# Bootstrap 失败态、语言选择、主菜单、战斗加载层、错误页。先做一档
# viewport/locale/quality（1600×900、zh、high）——清单要求的完整矩阵
# （16:9/19.5:9/20:9/平板 × zh/en × 三档画质）留给下一批按同一套写法批量加。
#
# 必须**不带** --headless 运行：headless 是 dummy 渲染后端，抓出来的是空图
# （同 ui_gallery_capture.gd 的既有约束）。
#   godot --path . res://tools/startup_ui_capture.tscn -- --update-baseline
#   godot --path . res://tools/startup_ui_capture.tscn
#
# 不带 --update-baseline：写到 CURRENT_DIR，供 startup_ui_regression_check 去跟
# 已经提交的基准图比对。带 --update-baseline：直接写到 BASELINE_DIR ——
# 这一步必须显式触发 + 人工审查新图，不能被 CI 自愈（同 asset_manifest 的合同）。
#
# 动态区域（Bootstrap 呼吸的 logo、加载层的转圈动效）不适合逐像素比对——同一份
# 代码跑两次，呼吸相位不一样就会整张图"不同"。这里不在截图阶段做遮罩，遮罩留给
# judge 阶段用固定矩形跳过（每个截图各自的动态区域坐标写在 MASKS 里，两边共享
# 同一份定义，capture 端不需要关心）。

const BootstrapScene := preload("res://scenes/bootstrap/Bootstrap.tscn")
const BootstrapScript := preload("res://scenes/bootstrap/Bootstrap.gd")
const MainMenuScene := preload("res://scenes/menu/MainMenu.tscn")
const LoadingOverlayScene := preload("res://ui/components/GloryLoadingOverlay.tscn")

const BASELINE_DIR := "res://data/qa/startup_ui_baseline"
const CURRENT_DIR := "res://reports/startup_ui_current"
const VIEWPORT_SIZE := Vector2i(1600, 900)

var _shots := 0
var _out_dir := ""


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("startup_ui_capture 需要真实渲染后端，请去掉 --headless")
		get_tree().quit(2)
		return

	var update := OS.get_cmdline_user_args().has("--update-baseline")
	_out_dir = BASELINE_DIR if update else CURRENT_DIR
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))

	get_window().size = VIEWPORT_SIZE
	LocaleManager.set_locale("zh")
	# 主菜单有环境动画（水面、粒子、宠物待机）——两次渲染之间天然会有像素抖动，
	# 而且抖动散布在大半张图上，不是一小块能遮罩掉的区域。冻结引擎时间让所有
	# 按 delta 推进的动画停在同一帧，两次抓图才能真正逐像素一致。
	Engine.time_scale = 0.0
	await get_tree().process_frame

	await _capture_bootstrap_ready()
	await _capture_bootstrap_failed()
	await _capture_main_menu()
	await _capture_battle_loading_pending()
	await _capture_battle_loading_failed()

	print("STARTUP_UI_CAPTURE shots=%d dir=%s update_baseline=%s"
		% [_shots, _out_dir, update])
	get_tree().quit(0)


func _capture_bootstrap_ready() -> void:
	var boot: BootstrapScript = BootstrapScene.instantiate()
	boot.auto_start = false
	boot.auto_transition = false
	add_child(boot)
	await _settle(4)
	# 不真的走线程加载（那会切场景把 Bootstrap 自己冲掉），只摆出「准备完成」
	# 这一帧的视觉状态——截图要的是这一刻的排版，不是完整的加载流程。
	boot._set_phase(BootstrapScript.Phase.READY,
		boot._tr_text("准备完成", "Ready"),
		boot._tr_text("正在进入 Glory", "Entering Glory"), 1.0)
	await _settle(2)
	await _shot("bootstrap_ready", boot)
	boot.queue_free()
	await _settle(2)


func _capture_bootstrap_failed() -> void:
	var boot: BootstrapScript = BootstrapScene.instantiate()
	boot.auto_start = false
	boot.auto_transition = false
	add_child(boot)
	await _settle(4)
	boot._fail("BOOT-DEMO", boot._tr_text(
		"截图演示用错误文案。", "Demo error text for screenshot capture."))
	await _settle(2)
	await _shot("bootstrap_failed", boot)
	boot.queue_free()
	await _settle(2)


func _capture_main_menu() -> void:
	var menu: Control = MainMenuScene.instantiate()
	add_child(menu)
	await _settle(6)
	await _shot("main_menu", menu)
	menu.queue_free()
	await _settle(2)


func _capture_battle_loading_pending() -> void:
	var overlay := LoadingOverlayScene.instantiate()
	add_child(overlay)
	await _settle(2)
	overlay.configure({
		"request_id": "capture_1",
		"title": overlay.tr("battle_load_title") if overlay.has_method("tr") else "Battle Preparation",
		"stage_key": "wait_server",
		"stage_text": "等待服务器",
		"cancellable": true,
	})
	overlay.set_progress(0.4, "3/8")
	await _settle(3)
	await _shot("battle_loading_pending", overlay)
	overlay.queue_free()
	await _settle(2)


func _capture_battle_loading_failed() -> void:
	var overlay := LoadingOverlayScene.instantiate()
	add_child(overlay)
	await _settle(2)
	overlay.configure({"request_id": "capture_2", "title": "Battle Preparation"})
	overlay.set_failed("NET_TIMEOUT_60S", "与服务器的连接中断了。", true)
	await _settle(3)
	await _shot("battle_loading_failed", overlay)
	overlay.queue_free()
	await _settle(2)


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame


func _shot(shot_name: String, _node: Node) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [_out_dir, shot_name]
	var err := image.save_png(path)
	if err == OK:
		_shots += 1
		print("  saved %s (%dx%d)" % [path, image.get_width(), image.get_height()])
	else:
		push_error("save_png failed for %s: %d" % [shot_name, err])
