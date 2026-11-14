extends SceneTree

# Count actual CanvasItem draw signals, not calls to the implementation under test.
const LAYER_SCENE := preload("res://effects/runtime/presentation/BoardReadabilityLayer.tscn")
var draws := 0
var assertions := 0
var failures: Array[String] = []
var repeated_frames := 0
var redraw_measurements := {}
var baseline_script := ""
var out_path := ""

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--out" and i + 1 < args.size():
			out_path = args[i + 1]
		elif args[i] == "--layer-script" and i + 1 < args.size():
			baseline_script = args[i + 1]
	call_deferred("_run")

func _expect(ok: bool, message: String) -> void:
	assertions += 1
	if not ok:
		failures.append(message)

func _settle(frames := 3) -> void:
	for i in frames:
		await process_frame

func _changed(action: Callable, message: String) -> void:
	var before := draws
	action.call()
	await _settle()
	_expect(draws > before, message)

func _run() -> void:
	var layer = LAYER_SCENE.instantiate()
	if not baseline_script.is_empty():
		layer.set_script(load(baseline_script))
	layer.draw.connect(func() -> void: draws += 1)
	layer.size = Vector2(320, 240)
	layer.configure_battle()
	var zones: Array = []
	for i in 6:
		var x := float(i % 3) * 70.0
		var y := float(i / 3) * 60.0
		zones.append({"polygon": PackedVector2Array([Vector2(x, y), Vector2(x + 60, y), Vector2(x + 60, y + 50), Vector2(x, y + 50)]), "friendly": i >= 3})
	var center_line := PackedVector2Array([Vector2(0, 55), Vector2(200, 55)])
	layer.set_battle_geometry(zones, center_line)
	layer.set_direction_texts("", "", "Friendly", "Enemy")
	layer.clear_battle_focus()
	root.add_child(layer)
	await _settle()
	_expect(draws > 0, "first configuration must actually draw")
	_expect(layer.contract_snapshot().battle_zone_count == 6, "all six battlefield zones must remain")

	# Reproduce the renderer's steady-state calls across distinct rendered frames.
	var before_idle := draws
	for i in 20:
		layer.set_guides_enabled(true)
		layer.set_low_quality(false)
		layer.clear_battle_focus()
		await _settle(1)
		repeated_frames += 1
	await _settle()
	redraw_measurements["empty_focus_20_frames"] = draws - before_idle
	_expect(draws == before_idle, "20 identical renderer frames must retain Canvas commands")

	await _changed(func() -> void: layer.set_low_quality(true), "quality change must redraw")
	var before_same := draws
	layer.set_low_quality(true)
	layer.configure_battle()
	layer.set_direction_texts("", "", "Friendly", "Enemy")
	layer.set_battle_geometry(zones.duplicate(true), center_line.duplicate())
	await _settle()
	_expect(draws == before_same, "equal quality, mode, texts, and geometry must not redraw")
	await _changed(func() -> void: layer.set_low_quality(false), "quality restore must redraw")
	await _changed(func() -> void: layer.set_direction_texts("", "", "Allies", "Enemy"), "direction text change must redraw")
	zones[0].friendly = true
	await _changed(func() -> void: layer.set_battle_geometry(zones, center_line), "zone color affiliation change must redraw")
	center_line[0] = Vector2(1, 56)
	await _changed(func() -> void: layer.set_battle_geometry(zones, center_line), "center line geometry change must redraw")

	var polygon := PackedVector2Array([Vector2(20, 20), Vector2(70, 20), Vector2(70, 70), Vector2(20, 70)])
	await _changed(func() -> void: layer.set_battle_focus("unit", Vector2(40, 40), polygon, Vector2(80, 80), true, Color.CYAN), "new focus must redraw")
	await create_timer(0.25).timeout
	await _settle()
	_expect(is_equal_approx(layer.get("_focus_strength"), 1.0), "focus enter tween must still finish")
	before_same = draws
	for i in 10:
		layer.set_battle_focus("unit", Vector2(40, 40), polygon.duplicate(), Vector2(80, 80), true, Color.CYAN)
		await _settle(1)
		repeated_frames += 1
	await _settle()
	redraw_measurements["populated_focus_10_frames"] = draws - before_same
	_expect(draws == before_same, "equal populated focus must remain retained after tween")
	await _changed(func() -> void: layer.set_battle_focus("unit", Vector2(41, 40), polygon, Vector2(80, 80), true, Color.CYAN), "moving source must redraw")
	polygon[0] = Vector2(21, 20)
	await _changed(func() -> void: layer.set_battle_focus("unit", Vector2(41, 40), polygon, Vector2(80, 80), true, Color.CYAN), "range geometry change must redraw")
	await _changed(func() -> void: layer.set_battle_focus("unit", Vector2(41, 40), polygon, Vector2(81, 80), true, Color.CYAN), "moving target must redraw")
	await _changed(func() -> void: layer.set_battle_focus("unit", Vector2(41, 40), polygon, Vector2(81, 80), false, Color.CYAN), "target presence change must redraw")
	await _changed(func() -> void: layer.set_battle_focus("unit", Vector2(41, 40), polygon, Vector2(81, 80), false, Color.MAGENTA), "focus color change must redraw")
	await _changed(func() -> void: layer.clear_battle_focus(), "clearing existing focus must redraw")
	before_same = draws
	layer.clear_battle_focus()
	await _settle()
	_expect(draws == before_same, "clearing already empty focus must retain commands")

	layer.set_guides_enabled(false)
	await _settle()
	_expect(not layer.visible, "guides off must hide the whole layer")
	await _changed(func() -> void: layer.set_guides_enabled(true), "guides on must restore visible artwork")
	layer.visible = false
	layer.set_guides_enabled(true)
	await _settle()
	_expect(layer.visible, "guides setter must preserve its explicit visibility restoration")

	await _changed(func() -> void: layer.configure_prep(), "battle-to-prep mode change must redraw")
	var cells: Array = [polygon.duplicate(), PackedVector2Array([Vector2(100, 20), Vector2(150, 20), Vector2(150, 70), Vector2(100, 70)])]
	await _changed(func() -> void: layer.set_prep_cells(cells), "prep cell geometry initialization must redraw")
	layer.set_direction_texts("Front", "Back")
	layer.set_prep_state(-1, false, -1, Color.CYAN)
	await _settle()
	before_same = draws
	for i in 10:
		layer.configure_prep()
		layer.set_prep_cells(cells.duplicate(true))
		layer.set_direction_texts("Front", "Back")
		layer.set_prep_state(-1, false, -1, Color.CYAN)
		await _settle(1)
		repeated_frames += 1
	await _settle()
	redraw_measurements["prep_10_frames"] = draws - before_same
	_expect(draws == before_same, "equal prep state/text/geometry across frames must not redraw")
	await _changed(func() -> void: layer.set_prep_state(-1, true, 0, Color.CYAN), "starting drag must redraw")
	_expect(layer.contract_snapshot().prep_drawn_cell_count == 2, "drag must still reveal all valid drop cells")
	await _changed(func() -> void: layer.set_prep_state(-1, true, 1, Color.CYAN), "drag hover change must redraw")
	await _changed(func() -> void: layer.set_prep_state(-1, true, 1, Color.MAGENTA), "prep player color change must redraw")
	await _changed(func() -> void: layer.set_prep_state(0, false, -1, Color.MAGENTA), "selection and drag end must redraw")
	await create_timer(0.25).timeout
	await _settle()
	_expect(layer.contract_snapshot().prep_drawn_cell_count == 1, "prep selection must keep only selected cell visible")
	await _changed(func() -> void: layer.set_prep_state(1, false, -1, Color.MAGENTA), "changing selected cell must redraw")
	await create_timer(0.25).timeout
	await _settle()
	cells[0][0] = Vector2(22, 20)
	await _changed(func() -> void: layer.set_prep_cells(cells), "changed prep geometry must redraw")

	layer.queue_free()
	await _settle()
	var report := {"assertions": assertions, "failures": failures, "actual_draw_signals": draws, "identical_frames_checked": repeated_frames, "redraw_measurements": redraw_measurements, "baseline_script": baseline_script}
	if not out_path.is_empty():
		FileAccess.open(out_path, FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("BOARD_READABILITY_REDRAW ", JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)
