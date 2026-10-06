extends SceneTree

# 真渲染回归：桌面、手机安全区与左右翻转；同时验证点击和对齐。
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _settle() -> void:
	for i in 45:
		await process_frame
	await RenderingServer.frame_post_draw

func _run() -> void:
	var state = root.get_node("GameState")
	var network = root.get_node("NetworkService")
	var safe = root.get_node("SafeArea")
	state.reset_run()
	state.tutorial_mode = false
	network.team_active = true
	network.is_host = false
	network.server_phase = network.ROOM_PREP
	var prep = load("res://scenes/prep/PrepScreen.tscn").instantiate()
	root.add_child(prep)
	var out := ProjectSettings.globalize_path("res://reports/prep_bottom_layout")
	DirAccess.make_dir_recursive_absolute(out)
	for fixture in [
		["editor", Vector2i(1600, 720), Vector4.ZERO],
		["ios", Vector2i(1748, 804), Vector4(0, 0, 62, 21)],
		["ios_rotated", Vector2i(1748, 804), Vector4(62, 0, 0, 21)],
		["android", Vector2i(1600, 720), Vector4(32, 0, 0, 24)],
	]:
		DisplayServer.window_set_size(fixture[1])
		safe.set_test_insets(fixture[2])
		await _settle()
		var shop = prep.get("_shop")
		var ready: Control = prep.get("_start_battle_button")
		var dock: Control = prep.get("_comms_dock")
		var settings: Control = prep.find_child("SettingsButton", true, false)
		var button: Control = shop.open_button
		_check(absf(button.get_global_rect().get_center().x - ready.get_global_rect().get_center().x) < 1.0, "%s scroll center" % fixture[0])
		_check(absf(dock.get_global_rect().end.x - settings.get_global_rect().end.x) < 1.0, "%s dock right" % fixture[0])
		_check(safe.rect().encloses(button.get_global_rect()), "%s scroll safe" % fixture[0])
		_check(safe.rect().encloses(dock.get_global_rect()), "%s dock safe" % fixture[0])
		root.get_texture().get_image().save_png(out.path_join(fixture[0] + "_closed.png"))
		button.pressed.emit()
		await _settle()
		_check(shop.picker_open, "%s scroll opens" % fixture[0])
		_check(safe.rect().encloses(shop.refresh_button.get_global_rect()), "%s refresh safe" % fixture[0])
		root.get_texture().get_image().save_png(out.path_join(fixture[0] + "_open.png"))
		print("LAYOUT %s scroll=%s ready=%s dock=%s refresh=%s" % [fixture[0], button.get_global_rect(), ready.get_global_rect(), dock.get_global_rect(), shop.refresh_button.get_global_rect()])
		_check(not dock.visible, "%s dock hidden in shop" % fixture[0])
		shop.close_picker()
		await process_frame
		_check(dock.visible, "%s dock restored" % fixture[0])
	print("PREP_BOTTOM_LAYOUT failures=%d" % failures)
	prep.queue_free()
	network.team_active = false
	await process_frame
	await process_frame
	quit(1 if failures else 0)
