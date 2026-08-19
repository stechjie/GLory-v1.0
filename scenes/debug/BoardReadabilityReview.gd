extends Control

const LAYER_SCENE := preload("res://effects/runtime/presentation/BoardReadabilityLayer.tscn")
const PREP_BACKGROUND := preload("res://assets/board/prep_2_5d/glory_grass_base_2560x1440.png")
const BATTLE_BACKGROUND := preload("res://assets/board/2_5d/battlefield_jungle_pve.png")


func _ready() -> void:
	_build_review()
	if "--capture-board-readability" in OS.get_cmdline_user_args():
		_capture_after_frames.call_deferred()


func _build_review() -> void:
	var background := ColorRect.new()
	background.color = Color(0.018, 0.025, 0.022)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)

	var title := Label.new()
	title.text = "E1-E  BoardReadabilityLayer  ·  1280×720 Forward Mobile Review"
	title.position = Vector2(24, 14)
	title.size = Vector2(1232, 42)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.96, 0.90, 0.68))
	title.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	title.add_theme_constant_override("outline_size", 5)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(title)

	_build_prep_panel(Rect2(20, 66, 600, 630))
	_build_battle_panel(Rect2(660, 66, 600, 630))


func _build_prep_panel(rect: Rect2) -> void:
	_add_panel_background(rect, PREP_BACKGROUND, Color(0.76, 0.90, 0.62, 0.92), "PREP · TRUE 4×4")
	var layer := LAYER_SCENE.instantiate() as BoardReadabilityLayer
	layer.name = "PrepReadabilityReview"
	layer.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	layer.position = rect.position
	layer.size = rect.size
	layer.configure_prep()
	layer.set_direction_texts("前排", "后排")
	add_child(layer)
	var cells: Array[PackedVector2Array] = []
	for index in 16:
		var col := index % 4
		var row := floori(float(index) / 4.0)
		var v := (float(row) + 0.5) / 4.0
		var near_width := lerpf(255.0, 440.0, v)
		var center := Vector2(300.0 + (float(col) - 1.5) * near_width / 4.0, 118.0 + float(row) * 112.0)
		cells.append(_ellipse(center, Vector2(41.0 + float(row) * 4.0, 21.0 + float(row) * 2.0), 24))
	layer.set_prep_cells(cells)
	layer.set_prep_state(5, PackedInt32Array([1, 4, 5, 6, 9]), true, 6, Color(0.28, 0.86, 0.86))


func _build_battle_panel(rect: Rect2) -> void:
	_add_panel_background(rect, BATTLE_BACKGROUND, Color(0.58, 0.76, 0.50, 0.94), "BATTLE · 3 LANES × 2 HALVES")
	var layer := LAYER_SCENE.instantiate() as BoardReadabilityLayer
	layer.name = "BattleReadabilityReview"
	layer.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	layer.position = rect.position
	layer.size = rect.size
	layer.configure_battle()
	layer.set_direction_texts("", "", "我方半场  FRIENDLY", "敌方半场  ENEMY")
	add_child(layer)
	var zones: Array[Dictionary] = []
	var x0 := 42.0
	var x1 := 558.0
	var top := 92.0
	var middle := 314.0
	var bottom := 550.0
	for lane in 3:
		var left := lerpf(x0, x1, float(lane) / 3.0)
		var right := lerpf(x0, x1, float(lane + 1) / 3.0)
		zones.append({"polygon": PackedVector2Array([Vector2(left, top), Vector2(right, top), Vector2(right, middle), Vector2(left, middle)]), "friendly": false})
		zones.append({"polygon": PackedVector2Array([Vector2(left, middle), Vector2(right, middle), Vector2(right, bottom), Vector2(left, bottom)]), "friendly": true})
	layer.set_battle_geometry(zones, PackedVector2Array([Vector2(x0, middle), Vector2(x1, middle)]))
	layer.set_battle_focus(
		"review_archer",
		Vector2(230, 435),
		_ellipse(Vector2(230, 435), Vector2(142, 82), 40),
		Vector2(372, 214),
		true,
		Color(0.30, 0.86, 0.92)
	)


func _add_panel_background(rect: Rect2, texture: Texture2D, tint: Color, caption_text: String) -> void:
	var frame := Panel.new()
	frame.position = rect.position
	frame.size = rect.size
	frame.clip_contents = true
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.05, 0.035)
	style.border_color = Color(0.66, 0.52, 0.20, 0.82)
	style.set_border_width_all(2)
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	frame.add_theme_stylebox_override("panel", style)
	add_child(frame)
	var image := TextureRect.new()
	image.texture = texture
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	image.modulate = tint
	image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(image)
	var shade := ColorRect.new()
	shade.color = Color(0.01, 0.02, 0.015, 0.18)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(shade)
	var caption := Label.new()
	caption.text = caption_text
	caption.position = Vector2(18, 14)
	caption.size = Vector2(rect.size.x - 36.0, 30.0)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 17)
	caption.add_theme_color_override("font_color", Color(1.0, 0.91, 0.58))
	caption.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.92))
	caption.add_theme_constant_override("outline_size", 4)
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(caption)


func _ellipse(center: Vector2, radii: Vector2, segments: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	for index in segments:
		var angle := TAU * float(index) / float(segments)
		points.append(center + Vector2(cos(angle) * radii.x, sin(angle) * radii.y))
	return points


func _capture_after_frames() -> void:
	for _frame in 4:
		await get_tree().process_frame
	var image := get_viewport().get_texture().get_image()
	var path := "user://board_readability_review.png"
	var error := image.save_png(path)
	print("BOARD_READABILITY_REVIEW_CAPTURE path=%s error=%d" % [ProjectSettings.globalize_path(path), error])
	get_tree().quit(0 if error == OK else 1)
