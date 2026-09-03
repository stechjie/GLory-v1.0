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
