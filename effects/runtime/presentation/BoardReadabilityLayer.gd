class_name BoardReadabilityLayer
extends Control

enum LayerMode {
	PREP,
	BATTLE,
}

const DEFAULT_STYLE := preload("res://data/presentation/board_readability_default.tres")

@export var style: BoardReadabilityStyle = DEFAULT_STYLE

var _mode := LayerMode.PREP
var _guides_enabled := true
var _low_quality := false

var _prep_cells: Array[PackedVector2Array] = []
var _prep_selected_index := -1
var _prep_range_indices := PackedInt32Array()
var _prep_drop_active := false
var _prep_drop_hover_index := -1
var _prep_player_color := Color(0.28, 0.86, 0.86)

var _battle_zones: Array[Dictionary] = []
var _battle_center_line := PackedVector2Array()
var _battle_focus_id := ""
var _battle_source := Vector2.ZERO
var _battle_target := Vector2.ZERO
var _battle_has_target := false
var _battle_range_polygon := PackedVector2Array()
var _battle_focus_color := Color(0.28, 0.86, 0.86)

var _front_text := ""
var _back_text := ""
var _friendly_text := ""
var _enemy_text := ""
var _focus_strength := 1.0
var _focus_tween: Tween


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE


func configure_prep() -> void:
	_mode = LayerMode.PREP
	queue_redraw()


func configure_battle() -> void:
	_mode = LayerMode.BATTLE
	queue_redraw()


func set_guides_enabled(enabled: bool) -> void:
	_guides_enabled = enabled
	visible = enabled
	queue_redraw()


func set_low_quality(enabled: bool) -> void:
	_low_quality = enabled
	queue_redraw()


func set_direction_texts(front_text: String, back_text: String, friendly_text: String = "", enemy_text: String = "") -> void:
	_front_text = front_text
	_back_text = back_text
	_friendly_text = friendly_text
	_enemy_text = enemy_text
	queue_redraw()


func set_prep_cells(cells: Array) -> void:
	_prep_cells.clear()
	for value in cells:
		if value is PackedVector2Array:
			_prep_cells.append((value as PackedVector2Array).duplicate())
	queue_redraw()


func set_prep_state(selected_index: int, range_indices: PackedInt32Array, drop_active: bool, drop_hover_index: int, player_color: Color) -> void:
	if selected_index != _prep_selected_index:
		_restart_focus_fade(selected_index >= 0)
	_prep_selected_index = selected_index
	_prep_range_indices = range_indices.duplicate()
	_prep_drop_active = drop_active
	_prep_drop_hover_index = drop_hover_index
	_prep_player_color = player_color
	queue_redraw()


func set_battle_geometry(zones: Array, center_line: PackedVector2Array) -> void:
	_battle_zones.clear()
	for value in zones:
		if typeof(value) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = value
		var polygon_value = entry.get("polygon", PackedVector2Array())
		if not (polygon_value is PackedVector2Array):
			continue
		_battle_zones.append({
			"polygon": (polygon_value as PackedVector2Array).duplicate(),
			"friendly": bool(entry.get("friendly", false)),
		})
	_battle_center_line = center_line.duplicate()
	queue_redraw()


func set_battle_focus(focus_id: String, source: Vector2, range_polygon: PackedVector2Array, target: Vector2, has_target: bool, focus_color: Color) -> void:
	if focus_id != _battle_focus_id:
		_restart_focus_fade(not focus_id.is_empty())
	_battle_focus_id = focus_id
	_battle_source = source
	_battle_range_polygon = range_polygon.duplicate()
	_battle_target = target
	_battle_has_target = has_target
	_battle_focus_color = focus_color
	queue_redraw()


func clear_battle_focus() -> void:
	set_battle_focus("", Vector2.ZERO, PackedVector2Array(), Vector2.ZERO, false, Color.WHITE)


func contract_snapshot() -> Dictionary:
	return {
		"mode": _mode,
		"guides_enabled": _guides_enabled,
		"prep_cell_count": _prep_cells.size(),
		"prep_selected_index": _prep_selected_index,
		"prep_range_count": _prep_range_indices.size(),
		"battle_zone_count": _battle_zones.size(),
		"battle_focus_id": _battle_focus_id,
		"battle_range_point_count": _battle_range_polygon.size(),
		"battle_has_target": _battle_has_target,
	}


func _restart_focus_fade(entering: bool) -> void:
	if _focus_tween != null and _focus_tween.is_valid():
		_focus_tween.kill()
	_focus_strength = 0.35 if entering else 0.0
	if not is_inside_tree() or not entering:
		queue_redraw()
		return
	_focus_tween = create_tween()
	_focus_tween.tween_method(func(value: float) -> void:
		_focus_strength = value
		queue_redraw(), _focus_strength, 1.0, 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _draw() -> void:
	if not _guides_enabled or style == null:
		return
	if _mode == LayerMode.PREP:
		_draw_prep()
	else:
		_draw_battle()


func _draw_prep() -> void:
	for index in _prep_cells.size():
		var polygon := _prep_cells[index]
		if polygon.size() < 3:
			continue
		var fill_alpha := style.prep_drag_fill_alpha if _prep_drop_active else style.prep_rest_fill_alpha
		var line_alpha := style.prep_drag_line_alpha if _prep_drop_active else style.prep_rest_line_alpha
		var fill_color := _alpha(_prep_player_color, fill_alpha)
		var line_color := _alpha(_prep_player_color, line_alpha)
		if _prep_range_indices.has(index):
			fill_color = _alpha(style.range_color, style.prep_range_fill_alpha * _focus_strength)
			line_color = _alpha(style.range_color, style.prep_range_line_alpha * _focus_strength)
		if index == _prep_selected_index:
			fill_color = _alpha(style.selection_color, style.prep_selected_fill_alpha * _focus_strength)
			line_color = _alpha(style.selection_color, style.prep_selected_line_alpha * _focus_strength)
		draw_colored_polygon(polygon, fill_color)
		var outline := _closed(polygon)
		if index == _prep_selected_index:
			draw_polyline(outline, _alpha(style.selection_color, 0.18 * _focus_strength), 12.0, true)
		elif _prep_range_indices.has(index):
			draw_polyline(outline, _alpha(style.range_color, 0.09 * _focus_strength), 7.0, true)
		else:
			draw_polyline(outline, _alpha(_prep_player_color, 0.18), 8.0, true)
		draw_polyline(outline, line_color, style.prep_line_width + (1.0 if index == _prep_selected_index else 0.0), true)
		if _prep_drop_active and index == _prep_drop_hover_index:
			_draw_drop_beam(polygon)
	_draw_prep_direction_labels()


func _draw_drop_beam(polygon: PackedVector2Array) -> void:
	var bounds := _polygon_bounds(polygon)
	var center := bounds.get_center()
	var source_y := bounds.position.y + bounds.size.y * 0.46
	var beam_top_y := bounds.position.y - maxf(18.0, bounds.size.y * 0.95)
	var source_half := bounds.size.x * 0.12
	var top_half := bounds.size.x * 0.42
	var beam := PackedVector2Array([
		Vector2(center.x - source_half, source_y),
		Vector2(center.x - top_half, beam_top_y),
		Vector2(center.x + top_half, beam_top_y),
		Vector2(center.x + source_half, source_y),
	])
	draw_colored_polygon(beam, _alpha(_prep_player_color, 0.10))
	draw_line(Vector2(center.x, source_y), Vector2(center.x, beam_top_y), _alpha(_prep_player_color, 0.28), 2.0, true)
	draw_polyline(_closed(polygon), _alpha(_prep_player_color, 0.98), 3.0, true)


func _draw_prep_direction_labels() -> void:
	var bounds := _all_prep_bounds()
	if bounds.size == Vector2.ZERO:
		return
	var label_x := bounds.position.x - 10.0
	var label_width := 118.0
	if not _front_text.is_empty():
		_draw_centered_label("↑  %s" % _front_text, Vector2(label_x, bounds.position.y + 12.0), label_width)
	if not _back_text.is_empty():
		_draw_centered_label("↓  %s" % _back_text, Vector2(label_x, bounds.end.y - 6.0), label_width)


func _draw_battle() -> void:
	var friendly_bounds := Rect2()
	var enemy_bounds := Rect2()
	var has_friendly := false
	var has_enemy := false
	for entry in _battle_zones:
		var polygon: PackedVector2Array = entry.get("polygon", PackedVector2Array())
		if polygon.size() < 3:
			continue
		var friendly := bool(entry.get("friendly", false))
		var base_color := style.friendly_color if friendly else style.enemy_color
		if not _low_quality or style.low_quality_zone_fills:
			draw_colored_polygon(polygon, _alpha(base_color, style.battle_zone_fill_alpha))
		draw_polyline(_closed(polygon), _alpha(base_color, style.battle_zone_line_alpha), style.battle_line_width, true)
		var bounds := _polygon_bounds(polygon)
		if friendly:
			friendly_bounds = bounds if not has_friendly else friendly_bounds.merge(bounds)
			has_friendly = true
		else:
			enemy_bounds = bounds if not has_enemy else enemy_bounds.merge(bounds)
			has_enemy = true
	if _battle_center_line.size() >= 2:
		draw_polyline(_battle_center_line, _alpha(style.guide_text_color, 0.24), 1.5, true)
	if has_enemy and not _enemy_text.is_empty():
		_draw_centered_label(_enemy_text, Vector2(enemy_bounds.end.x - 96.0, enemy_bounds.end.y - 15.0), 170.0)
	if has_friendly and not _friendly_text.is_empty():
		_draw_centered_label(_friendly_text, Vector2(friendly_bounds.end.x - 96.0, friendly_bounds.position.y + 22.0), 170.0)
	if _battle_focus_id.is_empty():
		return
	if _battle_range_polygon.size() >= 3:
		if not _low_quality:
			draw_colored_polygon(_battle_range_polygon, _alpha(style.range_color, style.battle_range_fill_alpha * _focus_strength))
		draw_polyline(_closed(_battle_range_polygon), _alpha(style.range_color, style.battle_range_line_alpha * _focus_strength), style.battle_line_width, true)
	if _battle_has_target:
		_draw_target_line()
	var selection := _ellipse_polygon(_battle_source, Vector2(30.0, 11.0), 28)
	draw_polyline(_closed(selection), _alpha(style.selection_color, 0.22 * _focus_strength), 11.0, true)
	draw_polyline(_closed(selection), _alpha(style.selection_color, 0.96 * _focus_strength), 3.0, true)


func _draw_target_line() -> void:
	var delta := _battle_target - _battle_source
	if delta.length() < 8.0:
		return
	draw_line(_battle_source, _battle_target, _alpha(style.guide_shadow_color, 0.72), style.target_line_width + 3.0, true)
	draw_dashed_line(_battle_source, _battle_target, _alpha(_battle_focus_color, 0.70 * _focus_strength), style.target_line_width, 9.0, true, true)
	var direction := delta.normalized()
	var normal := Vector2(-direction.y, direction.x)
	var tip := _battle_target - direction * 13.0
	var arrow := PackedVector2Array([
		_battle_target,
		tip + normal * 6.0,
		tip - normal * 6.0,
	])
	draw_colored_polygon(arrow, _alpha(_battle_focus_color, 0.86 * _focus_strength))
	var target_ring := _ellipse_polygon(_battle_target, Vector2(18.0, 7.0), 22)
	draw_polyline(_closed(target_ring), _alpha(_battle_focus_color, 0.68 * _focus_strength), 2.0, true)


func _draw_centered_label(text: String, center: Vector2, width: float) -> void:
	var font := ThemeDB.fallback_font
	var origin := Vector2(center.x - width * 0.5, center.y + 5.0)
	draw_string(font, origin + Vector2(1.5, 1.5), text, HORIZONTAL_ALIGNMENT_CENTER, width, 15, style.guide_shadow_color)
	draw_string(font, origin, text, HORIZONTAL_ALIGNMENT_CENTER, width, 15, style.guide_text_color)


func _all_prep_bounds() -> Rect2:
	var result := Rect2()
	var has_result := false
	for polygon in _prep_cells:
		if polygon.is_empty():
			continue
		var bounds := _polygon_bounds(polygon)
		result = bounds if not has_result else result.merge(bounds)
		has_result = true
	return result if has_result else Rect2()


func _polygon_bounds(polygon: PackedVector2Array) -> Rect2:
	if polygon.is_empty():
		return Rect2()
	var bounds := Rect2(polygon[0], Vector2.ZERO)
	for point in polygon:
		bounds = bounds.expand(point)
	return bounds


func _ellipse_polygon(center: Vector2, radii: Vector2, segments: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	for index in maxi(8, segments):
		var angle := TAU * float(index) / float(maxi(8, segments))
		points.append(center + Vector2(cos(angle) * radii.x, sin(angle) * radii.y))
	return points


func _closed(points: PackedVector2Array) -> PackedVector2Array:
	var result := points.duplicate()
	if not result.is_empty():
		result.append(result[0])
	return result


func _alpha(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, clampf(alpha, 0.0, 1.0))
