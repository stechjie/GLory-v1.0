extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BootstrapScript := preload("res://scenes/bootstrap/Bootstrap.gd")
const BootstrapScene := preload("res://scenes/bootstrap/Bootstrap.tscn")
const CHECK_NAME := "bootstrap"
const FIXTURE_PATH := "res://tools/fixtures/BootstrapTarget.tscn"
const MISSING_PATH := "res://tools/fixtures/BootstrapTargetMissing.tscn"  # asset-manifest-ignore

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_project_and_dependency_contract()
	_check_phase_honesty_and_ownership()
	_check_splash_continuity()
	await _check_success_path()
	await _check_failure_and_retry()
	_h.finish(get_tree())


func _check_project_and_dependency_contract() -> void:
	var project := FileAccess.get_file_as_string("res://project.godot")
	var source := FileAccess.get_file_as_string("res://scenes/bootstrap/Bootstrap.gd")
	var scene_text := FileAccess.get_file_as_string("res://scenes/bootstrap/Bootstrap.tscn")
	var export_template := FileAccess.get_file_as_string("res://export_presets.template.cfg")
	_h.expect(project.contains('run/main_scene="res://scenes/bootstrap/Bootstrap.tscn"'),
		"bootstrap_not_main", "project.godot 的主场景不是 Bootstrap")
	_h.expect(project.contains('boot_splash/image="res://ui/branding/glory_bootstrap.png"'),
		"project_splash_missing", "项目 boot splash 没有使用现有 Glory 图标")
	_h.expect(export_template.contains('splash_screen/icon="res://ui/branding/glory_bootstrap.png"')
		and export_template.contains('splash_screen/branding_image="res://ui/branding/glory_bootstrap.png"'),
		"android_splash_missing", "Android 模板没有接入同一 Glory 品牌图标")
	for forbidden in ["assets/models", "effects/vfx", "Node3D", "SubViewport", "GPUParticles"]:
		_h.expect(not source.contains(forbidden) and not scene_text.contains(forbidden),
			"heavy_bootstrap_dependency", "Bootstrap 引用了禁止的重依赖：%s" % forbidden)
	_h.expect(scene_text.contains('path="res://ui/branding/glory_bootstrap.png"'),
		"unapproved_brand_asset", "Bootstrap 没有复用由现有 icon.svg 转出的品牌 PNG")
	_h.expect(source.contains("load_threaded_request") and source.contains("load_threaded_get_status"),
		"main_load_not_threaded", "Main 不是通过 ResourceLoader 线程请求加载")
	_h.expect(source.contains("await RenderingServer.frame_post_draw"),
		"load_before_first_frame", "Bootstrap 没有等首帧显示就开始载入 Main")
	_h.expect(source.contains("func retry()") and source.contains("func exit_app()"),
		"failure_actions_missing", "启动失败没有重试/退出入口")


func _new_bootstrap(path: String) -> BootstrapScript:
	var bootstrap := BootstrapScene.instantiate() as BootstrapScript
	bootstrap.auto_start = false
	bootstrap.auto_transition = false
	bootstrap.next_scene_path = path
	add_child(bootstrap)
	return bootstrap


func _check_success_path() -> void:
	var bootstrap := _new_bootstrap(FIXTURE_PATH)
	await get_tree().process_frame
	bootstrap.start_loading()
	var loaded := await _wait_for_phase(bootstrap, "READY")
	_h.expect(loaded, "success_never_ready", "轻量目标场景没有完成线程加载")
	var snap := bootstrap.snapshot()
	_h.expect(bool(snap.get("loaded", false)), "success_resource_missing", "READY 时没有 PackedScene")
	_h.expect(is_equal_approx(float(snap.get("progress", 0.0)), 1.0),
		"success_progress_incomplete", "READY 时进度不是 100%")
	_h.expect(not bool(snap.get("error_visible", true)),
		"success_error_visible", "成功路径仍显示错误操作")
	bootstrap.queue_free()
	await get_tree().process_frame


func _check_failure_and_retry() -> void:
	var bootstrap := _new_bootstrap(MISSING_PATH)
	await get_tree().process_frame
	bootstrap.start_loading()
	var failed := await _wait_for_phase(bootstrap, "FAILED")
	_h.expect(failed, "missing_scene_not_failed", "缺失 Main 没有进入 FAILED")
	var failed_snap := bootstrap.snapshot()
	_h.expect(bool(failed_snap.get("error_visible", false)),
		"failure_actions_hidden", "失败后重试/退出操作没有显示")
	_h.expect(str(failed_snap.get("error_text", "")).contains("BOOT-MAIN-LOAD"),
		"failure_code_missing", "失败页没有稳定短错误码")

	bootstrap.next_scene_path = FIXTURE_PATH
	bootstrap.retry()
	var recovered := await _wait_for_phase(bootstrap, "READY")
	_h.expect(recovered, "retry_never_ready", "修正路径后 Retry 没有恢复")
	var recovered_snap := bootstrap.snapshot()
	_h.expect(bool(recovered_snap.get("loaded", false)),
		"retry_resource_missing", "Retry 完成但没有 PackedScene")
	bootstrap.queue_free()
	await get_tree().process_frame


func _wait_for_phase(bootstrap: BootstrapScript, wanted: String) -> bool:
	for _frame in 180:
		if not is_instance_valid(bootstrap):
			return false
		var snap := bootstrap.snapshot()
		if str(snap.get("phase_name", "")) == wanted:
			return true
		await get_tree().process_frame
	return false


# V3 P0-02 §6.1：Bootstrap 只能声明它真正执行的阶段。
#
# 任务书要求"补齐真正发生的存档/profile 恢复阶段；不得只显示一个假的『恢复存档』
# 字符串"。审计时发现前半句的前提不成立：PlayerProfile 是 autoload，排在
# [autoload] 第 5 位，它的 _ready() 直接读 user://profile.json —— 而 Godot 要等
# **所有 autoload 构造完**才加载第一个场景。也就是说 profile 恢复在 Bootstrap
# 画出第一帧之前就已经完成了。
#
# 所以照字面加一个"恢复存档"阶段，只能是假阶段 —— 正是同一句话禁止的东西。
# 这里改为把责任边界钉死：
#   * Bootstrap 不得自己读 profile / 存档（那会变成重复读档）
#   * Bootstrap 不得声明它没有执行的阶段
#
# 真正的选项是把 PlayerProfile 改成惰性、由 Bootstrap 显式驱动并显示真实阶段，
# 但那会改变启动时序并影响所有调用点，属于需要用户批准的改动，本批不做。
func _check_phase_honesty_and_ownership() -> void:
	var source := FileAccess.get_file_as_string("res://scenes/bootstrap/Bootstrap.gd")
	if not _h.expect(not source.is_empty(), "bootstrap_unreadable", "读不到 Bootstrap.gd"):
		return

	# 责任边界：读档不归 Bootstrap。
	for forbidden in ["PlayerProfile.load_profile", "SaveManager.load_run",
			"SaveManager.load_tutorial", "PlayerProfile.save_profile"]:
		_h.expect(not source.contains(forbidden),
			"bootstrap_reads_save",
			("Bootstrap 调用了 %s —— profile 在 autoload 阶段已经读过，"
				+ "这里再读一次是重复读档；存档归 Main/SaveManager") % forbidden)

	# 阶段诚实：每个 Phase 枚举值都必须有对应的 _set_phase 调用，
	# 否则就是一个声明了却从不进入的阶段。
	var enum_at := source.find("enum Phase {")
	if not _h.expect(enum_at >= 0, "phase_enum_missing", "找不到 Phase 枚举"):
		return
	var enum_end := source.find("}", enum_at)
	var enum_body := source.substr(enum_at, enum_end - enum_at)
	for raw in enum_body.trim_prefix("enum Phase {").split(","):
		var phase_name := raw.strip_edges()
		if phase_name.is_empty():
			continue
		_h.expect(source.contains("Phase.%s" % phase_name),
			"phase_declared_but_unused",
			"Phase.%s 声明了但没有任何地方进入它 —— 声明一个不发生的阶段就是假阶段" % phase_name)

	# 不得出现只有文案没有动作的"恢复存档"类阶段。
	for fake in ["恢复存档", "Restoring save", "读取存档", "Loading save"]:
		_h.expect(not source.contains(fake),
			"fake_restore_phase",
			("Bootstrap 显示了「%s」，但它并不执行读档 —— "
				+ "profile 在 autoload 阶段已完成，这个阶段是假的") % fake)


# V3 P0-02 §6.1：系统 splash -> Godot splash -> Bootstrap 的背景色必须一致，
# 否则玩家会看到两次底色切换，那正是"点了没反应"观感的一部分。
#
# 三者现在确实相同，但没有任何东西保证它继续相同 —— 改其中一个是单行改动。
func _check_splash_continuity() -> void:
	var project := FileAccess.get_file_as_string("res://project.godot")
	var scene_text := FileAccess.get_file_as_string("res://scenes/bootstrap/Bootstrap.tscn")

	var splash_color := _color_after(project, "boot_splash/bg_color=")
	_h.expect(not splash_color.is_empty(), "splash_bg_missing",
		"project.godot 没有声明 boot_splash/bg_color")

	# Bootstrap 场景里第一个 ColorRect 就是全屏背景。
	var bg_at := scene_text.find("[node name=\"Background\" type=\"ColorRect\"")
	if not _h.expect(bg_at >= 0, "bootstrap_background_missing",
			"Bootstrap 场景里没有名为 Background 的 ColorRect"):
		return
	var bg_color := _color_after(scene_text.substr(bg_at), "color = ")
	_h.expect(not bg_color.is_empty(), "bootstrap_bg_unreadable",
		"读不到 Bootstrap Background 的颜色")
	_h.expect(splash_color == bg_color, "splash_bg_mismatch",
		("Godot splash 底色 %s 与 Bootstrap 背景 %s 不一致 —— "
			+ "玩家会看到一次底色跳变") % [splash_color, bg_color])

	# 横屏必须是**声明**的，不能靠引擎默认值。默认值会随引擎版本变，
	# 而"竖屏启动一瞬再转横"正是这类问题最常见的表现。
	_h.expect(project.contains("window/handheld/orientation="),
		"orientation_not_declared",
		("project.godot 没有显式声明 window/handheld/orientation —— "
			+ "横屏靠的是引擎默认值，换版本就可能变"))


# 从 "<key>Color(a, b, c, d)" 里取出规范化的数字串，用于跨文件比较。
# 两个文件的写法不同（一个有空格一个没有），所以比数字而不是比原文。
func _color_after(text: String, key: String) -> String:
	var at := text.find(key)
	if at < 0:
		return ""
	var open_paren := text.find("(", at)
	var close_paren := text.find(")", open_paren)
	if open_paren < 0 or close_paren < 0:
		return ""
	var inner := text.substr(open_paren + 1, close_paren - open_paren - 1)
	var parts := PackedStringArray()
	for piece in inner.split(","):
		parts.append("%.5f" % float(piece.strip_edges()))
	return ",".join(parts)
