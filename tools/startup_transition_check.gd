extends Node

const MainScene := preload("res://scenes/main/Main.tscn")
const Loader := preload("res://scripts/assets/FrameResourceLoader.gd")
const StartupAssets := preload("res://scripts/assets/PrepStartupAssets.gd")
const PrepScript := preload("res://scenes/prep/PrepScreen.gd")
const CheckHarness := preload("res://tools/CheckHarness.gd")
var _h: CheckHarness
var _main: Control
var _last_frame_us := 0
var _max_frame_ms := 0.0
var _frames := 0
var _loading_frames := 0

func _ready() -> void:
	# This check changes onboarding. Refuse to run against a normal player's data.
	if not str(ProjectSettings.get_setting("application/config/custom_user_dir_name", "")).begins_with("GLory-Codex-QA-"):
		push_error("Run startup_transition_check with an isolated GLory-Codex-QA- user directory")
		get_tree().quit(2)
		return
	if OS.get_cmdline_user_args().has("--layout-soak"):
		get_window().size = Vector2i(2640, 1216)
		await get_tree().process_frame
	_h = CheckHarness.new("startup_transition")
	_check_current_round_assets()
	TutorialMode.clear_checkpoint()
	PlayerProfile.language_selected = false
	PlayerProfile.onboarding_status = PlayerProfile.ONBOARDING_NOT_STARTED
	_main = MainScene.instantiate()
	add_child(_main)
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(get_tree().root.get_node_or_null("VFXWarmup") == null,
		"eager_warmup", "Language selection must not run the full VFX catalog")
	# Cancel while threaded requests are in flight, then immediately re-enter.
	# The old continuation must neither mutate the new language nor mount a scene.
	_main._select_language("zh")
	for frame in 8:
		await get_tree().process_frame
	await _capture("startup_loading_zh")
	# Use the actual Android notification entry, not the cancel button handler:
	# generic ModalStack Back used to free the panel under the active coroutine.
	_main.notification(NOTIFICATION_WM_GO_BACK_REQUEST)
	_h.expect(not _main._startup_transition_running and not ModalStack.has("startup_preparation"),
		"android_back_cancel_failed", "Android Back during background loading left input blocked")
	_h.expect(_main._startup_loader == null and not TutorialMode.active,
		"android_back_kept_loader", "Android Back did not cancel the tutorial resource operation")
	# Desktop Esc reaches the same policy through the actual unhandled-input
	# callback. Re-enter after Back so this also checks a second cancellation.
	_main._select_language("zh")
	for frame in 4:
		await get_tree().process_frame
	_send_escape()
	_h.expect(not _main._startup_transition_running and not ModalStack.has("startup_preparation"),
		"escape_cancel_failed", "Esc during background loading left input blocked")
	_last_frame_us = Time.get_ticks_usec()
	var started := Time.get_ticks_msec()
	_main._select_language("en")
	_main._select_language("zh")
	_h.expect(LocaleManager.get_locale().begins_with("en"), "duplicate_selection", "A repeated tap replaced the in-flight language")
	_h.expect(ModalStack.has("startup_preparation"), "missing_ack", "The language tap did not open the loading indicator immediately")
	var checked_build_back := false
	while _main._startup_transition_running and Time.get_ticks_msec() - started < 120000:
		var overlay: Control = _main._startup_loading_overlay
		if not checked_build_back and is_instance_valid(overlay) and overlay._stage_key == "build":
			checked_build_back = true
			var serial: int = _main._startup_transition_serial
			_main.notification(NOTIFICATION_WM_GO_BACK_REQUEST)
			_send_escape()
			_h.expect(ModalStack.has("startup_preparation") and is_instance_valid(overlay),
				"build_back_dismissed_overlay", "Back/Esc dismissed the non-cancellable scene-construction stage")
			_h.expect(_main._startup_transition_running and _main._startup_transition_serial == serial,
				"build_back_cancelled_commit", "Back/Esc interrupted scene construction")
		_loading_frames += 1
		await get_tree().process_frame
	var elapsed := Time.get_ticks_msec() - started
	var startup_max_frame_ms := _max_frame_ms
	_h.expect(not _main._startup_transition_running, "startup_timeout", "Startup did not complete")
	_h.expect(checked_build_back, "build_back_not_exercised", "The real scene-construction stage was not checked")
	_h.expect(is_instance_valid(_main._prep), "prep_missing", "The tutorial preparation screen was not created")
	_h.expect(TutorialMode.active and GameState.tutorial_mode, "tutorial_state", "The tutorial state was not preserved")
	_h.expect(not ModalStack.has("startup_preparation"), "overlay_stuck", "The loading overlay remained after the first board frame")
	_h.expect(_loading_frames > 5, "no_render_yields", "Startup did not yield rendering frames while loading")
	for offer in GameState.shop_offers:
		if offer is Dictionary and not offer.is_empty():
			var path := str(offer.get("model", ""))
			if not path.is_empty():
				_h.expect(BattleAssetService.ready_count([path]) == 1,
					"offer_not_retained", "A current shop model would cold-load on first purchase")
	var missing_loader := Loader.new()
	var failure := await missing_loader.load_paths(get_tree(), ["res://tools/fixtures/missing_startup_resource.tscn"]) # asset-manifest-ignore
	_h.expect(not failure and missing_loader.failed_paths.size() == 1,
		"failure_handling", "An unavailable resource was silently treated as ready")
	await _capture("startup_tutorial_en")
	if OS.get_cmdline_user_args().has("--layout-soak"):
		await _check_shop_layout_stability()
	BattleAssetService.reset_stats()
	_h.expect(GameState.bench_slots[0] == null, "dirty_purchase_fixture", "The fresh tutorial unexpectedly restored a purchased unit")
	var purchase_started := Time.get_ticks_usec()
	_main._prep._on_shop_buy_requested(0)
	var purchase_ms := float(Time.get_ticks_usec() - purchase_started) / 1000.0
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(GameState.bench_slots[0] is Dictionary,
		"first_purchase_failed", "The first tutorial unit could not be bought")
	_h.expect(BattleAssetService.stats_line().contains("wait=0 cold=0"),
		"first_purchase_blocked", "Buying the first unit caused a blocking scene load")
	var report := {"purchase_handler_ms": purchase_ms, "elapsed_ms": elapsed, "max_frame_ms": startup_max_frame_ms, "loading_frames": _loading_frames,
		"asset_stats": BattleAssetService.stats_line(), "user_dir": OS.get_user_data_dir()}
	print("STARTUP_TRANSITION_RESULT ", JSON.stringify(report))
	var file := FileAccess.open("user://startup_transition_check.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
	TutorialMode.finish(false)
	BattleAssetService.reset_run()
	_main.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	_h.finish(get_tree())

func _process(_delta: float) -> void:
	if _last_frame_us == 0:
		return
	var now := Time.get_ticks_usec()
	_max_frame_ms = maxf(_max_frame_ms, float(now - _last_frame_us) / 1000.0)
	_last_frame_us = now
	_frames += 1

func _capture(label: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://%s.png" % label)


func _send_escape() -> void:
	var event := InputEventAction.new()
	event.action = &"ui_cancel"
	event.pressed = true
	_main._unhandled_input(event)


func _check_current_round_assets() -> void:
	var previous_step := TutorialMode.step
	var previous_team := GameState.team_mode
	var previous_round := GameState.round_index
	for state in [
		{"label": "fresh tutorial", "step": TutorialMode.Step.BUY_3, "team": false, "pvp": false},
		{"label": "restored tutorial boss", "step": TutorialMode.Step.START_BOSS, "team": false, "pvp": false},
		{"label": "restored tutorial PvP", "step": TutorialMode.Step.START_PVP, "team": false, "pvp": true},
		{"label": "team final", "step": TutorialMode.Step.BUY_3, "team": true, "pvp": true},
	]:
		TutorialMode.step = state.step
		GameState.team_mode = state.team
		GameState.round_index = GameState.FINAL_ROUND if state.team else 1
		var paths := StartupAssets.paths()
		var expected_music := PrepScript.PREP_PVP_MUSIC_PATH if state.pvp else PrepScript.PREP_MUSIC_PATH
		var unrelated_music := PrepScript.PREP_MUSIC_PATH if state.pvp else PrepScript.PREP_PVP_MUSIC_PATH
		_h.expect(paths.has(expected_music), "current_round_music_missing", state.label)
		_h.expect(not paths.has(unrelated_music), "unrelated_round_music_queued", state.label)
		_h.expect(paths.has(PrepScript.PVP_WARNING_FRAME_PATH) == state.pvp,
			"wrong_round_announcement", state.label)
	TutorialMode.step = previous_step
	GameState.team_mode = previous_team
	GameState.round_index = previous_round


func _check_shop_layout_stability() -> void:
	var button: Control = _main._prep._shop.open_button
	var host: Control = button.get_parent()
	var start := Time.get_ticks_msec()
	var max_error := Vector2.ZERO
	var button_size: Vector2 = _main._prep._shop.SHOP_BTN_SIZE
	while Time.get_ticks_msec() - start < 15000:
		var expected := Vector2(host.size.x * 0.5 - button_size.x * 0.5,
			host.size.y - button_size.y - 40.0)
		var error := (button.position - expected).abs()
		max_error.x = maxf(max_error.x, error.x)
		max_error.y = maxf(max_error.y, error.y)
		await get_tree().process_frame
	_h.expect(max_error.x < 1.0 and max_error.y < 4.0,
		"shop_button_drift", "The shop button left its bottom-center anchor over 15 seconds: %s" % max_error)
	print("STARTUP_SHOP_LAYOUT ", JSON.stringify({"window": str(get_window().size),
		"max_anchor_error": str(max_error), "button_rect": str(button.get_global_rect()),
		"font_fallback_loaded": get_tree().root.get_node_or_null("UIFontFallback") != null}))
	await _capture("startup_shop_after_15s")
	# Anchors must also survive a later window/orientation change. A captured
	# absolute position can appear correct initially and still fail this step.
	var original_size := get_window().size
	for window_size in [Vector2i(1600, 900), original_size]:
		get_window().size = window_size
		await get_tree().create_timer(1.8).timeout
		var expected := Vector2(host.size.x * 0.5 - button_size.x * 0.5,
			host.size.y - button_size.y - 40.0)
		_h.expect(absf(button.position.x - expected.x) < 1.0 and absf(button.position.y - expected.y) < 4.0,
			"shop_resize_drift", "The shop button lost its anchor after resizing: %s" % window_size)
