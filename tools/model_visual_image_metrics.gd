extends RefCounted

# Renderer-independent image checks used by the model matrix gate. The saved
# frame contains a diagnostic title bar, so metrics deliberately ignore that
# strip and inspect only the rendered stage.

const HASH_SIZE := 16
const HISTOGRAM_BINS := 16
const HEX_DIGITS := "0123456789abcdef"


static func analyze(image: Image, expected_background: Color, policy: Dictionary) -> Dictionary:
	if image == null or image.is_empty():
		return {
			"status": "FAIL",
			"failures": ["image_empty"],
			"perceptual_hash": "",
			"brightness_histogram": [],
		}
	var width := image.get_width()
	var height := image.get_height()
	var label_height := clampi(int(policy.get("label_height_px", 72)), 0, maxi(0, height - 1))
	var stride := maxi(1, int(policy.get("analysis_sample_stride", 4)))
	var distance_floor := float(policy.get("foreground_color_distance", 0.055))
	var observed_background := expected_background
	if width > 2 and height > label_height + 2:
		observed_background = image.get_pixel(1, label_height + 1)

	var sampled := 0
	var opaque := 0
	var foreground := 0
	var near_white := 0
	var near_black := 0
	var min_x := width
	var min_y := height
	var max_x := -1
	var max_y := -1
	var histogram: Array[int] = []
	histogram.resize(HISTOGRAM_BINS)
	histogram.fill(0)
	for y in range(label_height, height, stride):
		for x in range(0, width, stride):
			var color := image.get_pixel(x, y)
			sampled += 1
			if color.a >= 0.98:
				opaque += 1
			if _color_distance(color, observed_background) < distance_floor:
				continue
			foreground += 1
			min_x = mini(min_x, x)
			min_y = mini(min_y, y)
			max_x = maxi(max_x, x)
			max_y = maxi(max_y, y)
			var luminance := _luminance(color)
			var bin_index := clampi(int(floor(luminance * float(HISTOGRAM_BINS))), 0, HISTOGRAM_BINS - 1)
			histogram[bin_index] += 1
			if luminance >= float(policy.get("near_white_luminance", 0.94)):
				near_white += 1
			if luminance <= float(policy.get("near_black_luminance", 0.035)):
				near_black += 1

	var foreground_ratio := float(foreground) / float(maxi(1, sampled))
	var white_ratio := float(near_white) / float(maxi(1, foreground))
	var black_ratio := float(near_black) / float(maxi(1, foreground))
	var opaque_ratio := float(opaque) / float(maxi(1, sampled))
	var bounds := Rect2i()
	if foreground > 0:
		bounds = Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)

	var failures: Array[String] = []
	if foreground_ratio < float(policy.get("foreground_ratio_min", 0.008)):
		failures.append("foreground_area_too_small")
	if foreground_ratio > float(policy.get("foreground_ratio_max", 0.62)):
		failures.append("foreground_area_too_large")
	var margin_values: Array = policy.get("safe_frame_margins_px", [32, 24, 32, 20])
	var safe_left := int(margin_values[0])
	var safe_top := label_height + int(margin_values[1])
	var safe_right := width - int(margin_values[2])
	var safe_bottom := height - int(margin_values[3])
	if foreground > 0 and (min_x < safe_left or min_y < safe_top or max_x >= safe_right or max_y >= safe_bottom):
		failures.append("foreground_outside_safe_frame")
	if white_ratio > float(policy.get("mostly_white_ratio_max", 0.88)):
		failures.append("mostly_white")
	if black_ratio > float(policy.get("mostly_black_ratio_max", 0.96)):
		failures.append("mostly_black")
	if opaque_ratio < float(policy.get("opaque_ratio_min", 0.99)):
		failures.append("unexpected_transparency")
	return {
		"status": "PASS" if failures.is_empty() else "FAIL",
		"failures": failures,
		"sample_stride": stride,
		"sampled_pixels": sampled,
		"foreground_pixels": foreground,
		"foreground_screen_ratio": snappedf(foreground_ratio, 0.000001),
		"foreground_bounds": [bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y],
		"safe_frame": [safe_left, safe_top, safe_right - safe_left, safe_bottom - safe_top],
		"near_white_ratio": snappedf(white_ratio, 0.000001),
		"near_black_ratio": snappedf(black_ratio, 0.000001),
		"opaque_ratio": snappedf(opaque_ratio, 0.000001),
		"brightness_histogram": histogram,
		"perceptual_hash": _average_hash(image, label_height),
		"observed_background": observed_background.to_html(true),
	}


static func write_contact_sheets(
		image_paths: Array[String], output_dir: String, prefix: String, row_count: int = 4) -> Array[String]:
	var pages: Array[String] = []
	var rows := maxi(1, row_count)
	var columns := 4
	var tile_size := Vector2i(320, 180)
	var per_page := rows * columns
	DirAccess.make_dir_recursive_absolute(output_dir)
	for page_start in range(0, image_paths.size(), per_page):
		var canvas := Image.create(tile_size.x * columns, tile_size.y * rows, false, Image.FORMAT_RGBA8)
		canvas.fill(Color("181818"))
		for local_index in range(per_page):
			var source_index := page_start + local_index
			if source_index >= image_paths.size():
				break
			var source := Image.load_from_file(image_paths[source_index])
			if source == null or source.is_empty():
				continue
			if source.get_format() != Image.FORMAT_RGBA8:
				source.convert(Image.FORMAT_RGBA8)
			source.resize(tile_size.x, tile_size.y, Image.INTERPOLATE_LANCZOS)
			var column := local_index % columns
			var row := floori(float(local_index) / float(columns))
			canvas.blit_rect(source, Rect2i(Vector2i.ZERO, tile_size), Vector2i(column * tile_size.x, row * tile_size.y))
		var page_number := floori(float(page_start) / float(per_page)) + 1
		var path := output_dir.path_join("%s_page_%02d.png" % [prefix, page_number])
		if canvas.save_png(path) == OK:
			pages.append(path)
	return pages


static func _average_hash(image: Image, label_height: int) -> String:
	var usable_height := maxi(1, image.get_height() - label_height)
	var thumb := image.get_region(Rect2i(0, label_height, image.get_width(), usable_height))
	thumb.resize(HASH_SIZE, HASH_SIZE, Image.INTERPOLATE_LANCZOS)
	var values: Array[float] = []
	var total := 0.0
	for y in HASH_SIZE:
		for x in HASH_SIZE:
			var value := _luminance(thumb.get_pixel(x, y))
			values.append(value)
			total += value
	var mean := total / float(maxi(1, values.size()))
	var out := ""
	for nibble_start in range(0, values.size(), 4):
		var nibble := 0
		for bit in 4:
			nibble <<= 1
			if values[nibble_start + bit] >= mean:
				nibble |= 1
		out += HEX_DIGITS[nibble]
	return out


static func _color_distance(a: Color, b: Color) -> float:
	return maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b)))


static func _luminance(color: Color) -> float:
	return clampf(color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722, 0.0, 1.0)
