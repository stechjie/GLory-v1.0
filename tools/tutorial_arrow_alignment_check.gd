extends Node

# Run in a disposable project with use_custom_user_dir=true. This check starts a
# tutorial, so it must never touch a player's normal save directory.
# Use a real renderer to also write the two placement screenshots at each size.
const CheckHarness := preload("res://tools/CheckHarness.gd")
const ProviderScript := preload("res://scripts/tutorial/TutorialTargetProvider.gd")
const TutorialScript := preload("res://scripts/tutorial/TutorialMode.gd")
const RESOLUTIONS := [Vector2i(1280, 720), Vector2i(1920, 1080),
	Vector2i(2400, 1080), Vector2i(2640, 1216)]
const EPS := 1.0
var _h: CheckHarness
var _slots_checked := 0


func _ready() -> void:
	if not bool(ProjectSettings.get_setting("application/config/use_custom_user_dir", false)):
		push_error("tutorial_arrow_alignment_check requires an isolated custom user directory")
		get_tree().quit(2)
		return
	_h = CheckHarness.new("tutorial_arrow_alignment")
	for resolution in RESOLUTIONS:
		await _check_resolution(resolution)
	await _check_canvas_transform()
	_h.expect(_slots_checked == RESOLUTIONS.size() * 24, "incomplete_slot_coverage",
		"checked %d projected slots; expected %d" % [_slots_checked, RESOLUTIONS.size() * 24])
	TutorialMode.finish()
	_h.finish(get_tree())


func _check_resolution(resolution: Vector2i) -> void:
	get_window().size = resolution
	await _settle(4)
	TutorialMode.start()
	var definition: Dictionary = DataRegistry.get_table("race_units").get("units", [])[0].duplicate(true)
	var unit := {"uid": "tutorial_pointer_check", "id": definition.id, "star": 1, "def": definition}
	GameState.bench_slots[0] = unit
	var prep := (load("res://scenes/prep/PrepScreen.tscn") as PackedScene).instantiate()
	if not _h.expect(prep.get_script() != null, "prep_script_missing", str(resolution)):
		prep.free()
		return
	add_child(prep)
	await _settle(20)
	# Freeze the state machine while checking each real projected slot. The view
	# and its hit polygons have already been laid out by the production scene.
	prep.process_mode = Node.PROCESS_MODE_DISABLED
	TutorialMode.step = TutorialScript.Step.PLACE_3
	prep._board_hud._selected_bench = -1
	_h.note("%s -> canvas %s" % [str(resolution), str(TutorialMode._overlay.size)])
	for index in prep._board_hud.bench_buttons.size():
		GameState.bench_slots.fill(null)
		GameState.bench_slots[index] = unit
		TutorialMode.update_overlay()
		var button: Control = prep._board_hud.bench_buttons[index]
		_check_slot(button, "%s bench %d" % [str(resolution), index])
		if index == 0:
			await _capture("%dx%d_bench" % [resolution.x, resolution.y])
	prep._board_hud._selected_bench = 0
	for index in prep._board_hud.buttons.size():
		GameState.board_slots.fill(unit)
		GameState.board_slots[index] = null
		TutorialMode.update_overlay()
		var button: Control = prep._board_hud.buttons[index]
		_check_slot(button, "%s board %d" % [str(resolution), index])
		if index == 8:
			await _capture("%dx%d_board" % [resolution.x, resolution.y])
	TutorialMode.finish()
	prep.queue_free()
	await _settle(3)


func _check_slot(button: Control, label: String) -> void:
	_slots_checked += 1
	_h.expect(TutorialMode._target_control() == button, "wrong_slot", label)
	var polygon: PackedVector2Array = button.get("cell_polygon")
	if not _h.expect(polygon.size() >= 3, "no_projected_ring", label):
		return
	# Read the geometry actually used to draw and hit-test the ring. A second
	# get_global_rect() assertion alone would reproduce the old wrong expectation.
	var screen_points := button.get_global_transform_with_canvas() * polygon
	var bounds := Rect2(screen_points[0], Vector2.ZERO)
	for point in screen_points:
		bounds = bounds.expand(point)
	var control_bounds := button.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, button.size)
	_h.expect(control_bounds.size.distance_to(bounds.size) < EPS,
		"stale_minimum_size", "%s control=%s ring=%s" % [label, str(control_bounds), str(bounds)])
	var actual_tip: Vector2 = TutorialMode._arrow.get_global_transform_with_canvas() \
		* TutorialMode._arrow.tip_position()
	var expected_tip := Vector2(bounds.get_center().x, bounds.position.y - TutorialScript.ARROW_UP_GAP)
	_h.expect(actual_tip.distance_to(expected_tip) < EPS, "arrow_misses_ring",
		"%s tip=%s expected=%s error=%.2f" % [label, str(actual_tip), str(expected_tip),
			actual_tip.distance_to(expected_tip)])


func _check_canvas_transform() -> void:
	TutorialMode.start()
	var host := Control.new()
	host.position = Vector2(32, 24)
	host.scale = Vector2(0.9, 0.9)
	host.size = Vector2(1500, 720)
	add_child(host)
	var layer := CanvasLayer.new()
	layer.transform = Transform2D(0.0, Vector2(160, 100))
	add_child(layer)
	var target := Control.new()
	target.position = Vector2(400, 300)
	target.scale = Vector2(1.2, 1.2)
	target.size = Vector2(120, 64)
	layer.add_child(target)
	var provider := ProviderScript.new("canvas_transform_check", host)
	provider.bind_target(ProviderScript.TARGET_PLACE_UNIT, func(): return target)
	TutorialMode.step = TutorialScript.Step.PLACE_3
	TutorialMode.attach(provider)
	await _settle(2)
	TutorialMode.update_overlay()
	var actual: Vector2 = TutorialMode._arrow.get_global_transform_with_canvas() * TutorialMode._arrow.tip_position()
	var edge := target.get_global_transform_with_canvas() * Vector2(target.size.x * 0.5, 0)
	var expected := edge - Vector2(0, TutorialScript.ARROW_UP_GAP * host.scale.y)
	_h.expect(actual.distance_to(expected) < EPS, "canvas_space_mismatch",
		"tip=%s expected=%s" % [str(actual), str(expected)])
	TutorialMode.finish()
	host.queue_free()
	layer.queue_free()
	await _settle(2)


func _capture(label: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var output := "res://reports/tutorial_arrows"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	await RenderingServer.frame_post_draw
	var picture := get_viewport().get_texture().get_image()
	_h.expect(picture.save_png(output.path_join(label + ".png")) == OK, "capture_failed", label)


func _settle(frames: int) -> void:
	for frame in frames:
		await get_tree().process_frame
