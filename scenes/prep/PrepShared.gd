extends Control

signal battle_requested

const BoardReadabilityLayerScene := preload("res://effects/runtime/presentation/BoardReadabilityLayer.tscn")

@export_group("4x4 Board Layout")
@export var cell_size := Vector2(149.5, 84.0)
@export var board_grid_offset := Vector2.ZERO
@export_group("4x4 Board Perspective")
@export var board_top_left := Vector2(0.32, 0.0)
@export var board_top_right := Vector2(0.68, 0.0)
@export var board_bottom_right := Vector2(1.0, 1.0)
@export var board_bottom_left := Vector2(0.0, 1.0)
@export var board_foreshorten := 0.5
# 常态：16 个圆圈格子平时就画亮（#3）——始终可见的青色环。
@export var board_cell_rest_fill := Color(0.20, 0.80, 0.74, 0.06)
@export var board_cell_rest_line := Color(0.48, 1.0, 0.92, 0.55)
# 拖动放置时非目标格（更亮一点，让 16 格全部亮起）。
@export var board_cell_idle_fill := Color(0.20, 0.85, 0.80, 0.14)
@export var board_cell_idle_line := Color(0.48, 1.0, 0.92, 0.78)
# 放置目标格（#2）——高亮 + 发光。
@export var board_cell_hover_fill := Color(0.20, 1.0, 1.0, 0.42)
@export var board_cell_hover_line := Color(0.60, 1.0, 1.0, 1.0)
@export var board_origin := Vector3(-0.01, 0.035, -0.005)
@export var board_rotation := Vector3.ZERO
@export var board_scale := Vector3.ONE
@export var board_cell_spacing := Vector2(0.17, 0.18)
@export_range(0.45, 0.75, 0.01) var unit_visual_scale := 0.56
@export var unit_cell_anchor_offset := Vector2.ZERO
@export_range(-0.08, 0.20, 0.005) var unit_y_offset := 0.0

@export_group("Standby Bench Layout")
@export var standby_origin := Vector3.ZERO
@export var standby_rotation := Vector3.ZERO
@export var standby_unit_scale := 0.46
@export_range(-0.08, 0.20, 0.005) var standby_unit_y_offset := 0.0
@export var standby_face_battlefield := false
@export_range(-180.0, 180.0, 1.0) var standby_facing_yaw_offset := 0.0
@export var standby_idle_fill := Color(0.22, 0.74, 0.62, 0.0)
@export var standby_idle_line := Color(0.42, 0.94, 0.78, 0.0)
@export var standby_hover_line := Color(0.40, 1.0, 0.82, 0.92)

class DragButton:
	extends Button
	var drag_payload: Dictionary = {}
	var drag_enabled := true
	var drag_owner: Control

	func _get_drag_data(_at_position: Vector2) -> Variant:
		if disabled or not drag_enabled or drag_payload.is_empty():
			return null
		if has_meta("long_press_timer"):
			var timer = get_meta("long_press_timer")
			if timer is Timer:
				timer.stop()
		set_meta("long_press_cancelled", true)
		set_meta("dragging", true)
		if drag_owner != null and drag_owner.has_method("_on_drag_started"):
			drag_owner._on_drag_started(drag_payload)
		var preview := Label.new()
		preview.text = str(get_meta("drag_preview_text", text))
		preview.modulate = Color(1.0, 0.95, 0.65)
		preview.add_theme_font_size_override("font_size", 14)
		set_drag_preview(preview)
		return drag_payload.duplicate(true)

	func _notification(what: int) -> void:
		if what == NOTIFICATION_DRAG_END and drag_owner != null and drag_owner.has_method("_on_drag_ended"):
			drag_owner._on_drag_ended()

class BoardCellButton:
	extends DragButton
	var board_index := -1
	var screen: Control
	var cell_polygon := PackedVector2Array()
	var deployment_visible := false
	var deployment_hovered := false

	func _ready() -> void:
		mouse_exited.connect(_on_mouse_exited)

	func configure_polygon(points: PackedVector2Array) -> void:
		cell_polygon = points
		queue_redraw()

	func set_deployment_highlight(enabled: bool, hovered: bool = false) -> void:
		deployment_visible = enabled
		deployment_hovered = enabled and hovered
		queue_redraw()

	func _has_point(point: Vector2) -> bool:
		if cell_polygon.size() < 3:
			return false
		if Geometry2D.is_point_in_polygon(point, cell_polygon):
			return true
		# (10) The perspective-tilted board makes edge columns (esp. the far right)
		# a thin sliver — hard to tap on Android. Enlarge the hit rect so every
		# cell, including the rightmost column, is reliably touchable.
		var minx := cell_polygon[0].x
		var miny := cell_polygon[0].y
		var maxx := minx
		var maxy := miny
		for p in cell_polygon:
			minx = minf(minx, p.x)
			miny = minf(miny, p.y)
			maxx = maxf(maxx, p.x)
			maxy = maxf(maxy, p.y)
		return Rect2(minx, miny, maxx - minx, maxy - miny).grow(16.0).has_point(point)

	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		var can_drop: bool = screen != null and screen.has_method("_can_drop_on_board") and screen._can_drop_on_board(board_index, data)
		if screen != null and screen.has_method("_set_board_drop_hover"):
			screen._set_board_drop_hover(board_index if can_drop else -1)
		return can_drop

	func _drop_data(_at_position: Vector2, data: Variant) -> void:
		if screen != null and screen.has_method("_drop_on_board"):
			screen._drop_on_board(board_index, data)

	func _on_mouse_exited() -> void:
		if deployment_visible and screen != null and screen.has_method("_set_board_drop_hover"):
			screen._set_board_drop_hover(-1)

	func _draw() -> void:
		# BoardReadabilityLayer owns all board guide rendering in one CanvasItem.
		# This button keeps only touch/drag hit testing, so the 16 cells no longer
		# duplicate guide draw calls or drift away from the shared style resource.
		pass

class RelationProgressOverlay:
	extends Control
	var relation_states: Array = []

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_relation_states(next_states: Array) -> void:
		relation_states = next_states.duplicate(true)
		queue_redraw()

	func _draw() -> void:
		var visible_count := mini(3, relation_states.size())
		for row in visible_count:
			var state_value = relation_states[row]
			if typeof(state_value) != TYPE_DICTIONARY:
				continue
			var state: Dictionary = state_value
			var progress := clampi(int(state.get("progress", 0)), 0, RaceRelationService.MAX_PROGRESS)
			if bool(state.get("active", false)) or progress >= RaceRelationService.MAX_PROGRESS:
				continue
			var color := Color(1.0, 0.78, 0.18, 0.96) if str(state.get("kind", "")) == "friendly" else Color(0.66, 0.72, 0.80, 0.96)
			var y := size.y - 5.0 - float(row) * 6.0
			var gap := 2.0
			var total_width := size.x - 8.0
			var segment_width := (total_width - gap * 2.0) / 3.0
			for segment in 3:
				var segment_rect := Rect2(
					4.0 + float(segment) * (segment_width + gap),
					y,
					segment_width,
					4.0
				)
				draw_rect(segment_rect, Color(0.02, 0.03, 0.04, 0.82), true)
				if segment < progress:
					draw_rect(segment_rect, color, true)

class BenchCellButton:
	extends DragButton
	var bench_index := -1
	var screen: Control
	var cell_polygon := PackedVector2Array()
	var standby_visible := false
	var standby_hovered := false

	func _ready() -> void:
		mouse_exited.connect(_on_mouse_exited)

	func configure_polygon(points: PackedVector2Array) -> void:
		cell_polygon = points
		queue_redraw()

	func set_standby_highlight(enabled: bool, hovered: bool = false) -> void:
		standby_visible = enabled
		standby_hovered = enabled and hovered
		queue_redraw()

	func _has_point(point: Vector2) -> bool:
		if cell_polygon.size() < 3:
			return false
		if Geometry2D.is_point_in_polygon(point, cell_polygon):
			return true
		# Square touch area centered on the circle: the projected ellipses get very
		# flat near the top rows, so use max(width, height) as the side length to
		# keep every bench spot reliably tappable on Android.
		var minx := cell_polygon[0].x
		var miny := cell_polygon[0].y
		var maxx := minx
		var maxy := miny
		for p in cell_polygon:
			minx = minf(minx, p.x)
			miny = minf(miny, p.y)
			maxx = maxf(maxx, p.x)
			maxy = maxf(maxy, p.y)
		var center := Vector2((minx + maxx) * 0.5, (miny + maxy) * 0.5)
		var side := maxf(maxx - minx, maxy - miny) + 16.0
		return Rect2(center - Vector2(side, side) * 0.5, Vector2(side, side)).has_point(point)

	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		if screen != null and screen.has_method("_set_standby_drop_hover"):
			screen._set_standby_drop_hover(bench_index)
		return screen != null and screen.has_method("_can_drop_on_bench") and screen._can_drop_on_bench(bench_index, data)

	func _drop_data(_at_position: Vector2, data: Variant) -> void:
		if screen != null and screen.has_method("_drop_on_bench"):
			screen._drop_on_bench(bench_index, data)

	func _on_mouse_exited() -> void:
		if standby_visible and screen != null and screen.has_method("_set_standby_drop_hover"):
			screen._set_standby_drop_hover(-1)

	func _draw() -> void:
		if not standby_visible or cell_polygon.size() < 3 or screen == null:
			return
		var player_color: Color = screen.standby_hover_line
		if screen.has_method("_board_player_color"):
			var color_value = screen.call("_board_player_color")
			if typeof(color_value) == TYPE_COLOR:
				player_color = color_value
		var fill: Color = Color(player_color.r, player_color.g, player_color.b, 0.25) if standby_hovered else screen.standby_idle_fill
		var line: Color = Color(player_color.r, player_color.g, player_color.b, 0.92) if standby_hovered else screen.standby_idle_line
		var outline := cell_polygon.duplicate()
		outline.append(cell_polygon[0])
		if standby_hovered:
			var bounds := Rect2(cell_polygon[0], Vector2.ZERO)
			for p in cell_polygon:
				bounds = bounds.expand(p)
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
			var beam_core := PackedVector2Array([
				Vector2(center.x - source_half * 0.45, source_y),
				Vector2(center.x - top_half * 0.36, beam_top_y),
				Vector2(center.x + top_half * 0.36, beam_top_y),
				Vector2(center.x + source_half * 0.45, source_y),
			])
			draw_colored_polygon(beam, Color(line.r, line.g, line.b, 0.10))
			draw_colored_polygon(beam_core, Color(line.r, line.g, line.b, 0.18))
			draw_line(Vector2(center.x, source_y), Vector2(center.x, beam_top_y), Color(line.r, line.g, line.b, 0.26), 2.5, true)
		draw_colored_polygon(cell_polygon, fill)
		draw_polyline(outline, line, 2.5 if standby_hovered else 1.25, true)
		if standby_hovered:
			draw_polyline(outline, Color(line.r, line.g, line.b, 0.26), 7.0, true)

class SellDropPanel:
	extends PanelContainer
	var screen: Control
	# 仅显式标记的面板才接受卖出放置（当前只有商店红色覆盖层）。顶栏/左面板/商店底板
	# 也用此类做布局面板，但不应作为隐性出售区，避免空白处松手误卖。
	var is_sell_zone := false

	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		if not is_sell_zone:
			return false
		return screen != null and screen.has_method("_can_drop_to_sell") and screen._can_drop_to_sell(data)

	func _drop_data(_at_position: Vector2, data: Variant) -> void:
		if not is_sell_zone:
			return
		if screen != null and screen.has_method("_drop_to_sell"):
			screen._drop_to_sell(data)

# 调试：把所有按钮的点击判定区域用线条画出来（多边形格子按真实多边形，普通按钮按矩形）。
# 满屏覆盖、不吃输入、z 极高，永远画在最上层。由 SHOW_HIT_AREAS 常量控制是否创建。
class HitAreaDebugOverlay:
	extends Control
	var scan_root: Control

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		z_index = 900

	func _process(_delta: float) -> void:
		# 格子跟随 3D 投影每帧移动，必须每帧重画。
		queue_redraw()

	func _draw() -> void:
		if scan_root == null:
			return
		var inv := get_global_transform().affine_inverse()
		_scan(scan_root, inv)

	func _scan(node: Node, inv: Transform2D) -> void:
		for child in node.get_children():
			if not (child is Control):
				continue
			var c := child as Control
			if not c.visible:
				continue
			if c is Button:
				_draw_button(c as Button, inv)
			_scan(c, inv)

	func _draw_button(btn: Button, inv: Transform2D) -> void:
		# IGNORE 的按钮不参与输入拾取，跳过。
		if btn.mouse_filter == Control.MOUSE_FILTER_IGNORE:
			return
		var xf := inv * btn.get_global_transform()
		var poly := PackedVector2Array()
		if "cell_polygon" in btn:
			poly = btn.get("cell_polygon")
		if poly.size() >= 3:
			# 多边形判定（棋盘圆/待命格）——绿色。
			var pts := PackedVector2Array()
			for p in poly:
				pts.append(xf * p)
			pts.append(pts[0])
			draw_polyline(pts, Color(0.25, 1.0, 0.45, 0.95), 1.5)
		else:
			# 矩形判定（普通按钮）——品红。
			var r := Rect2(Vector2.ZERO, btn.size)
			var corners := PackedVector2Array([
				xf * r.position,
				xf * Vector2(r.end.x, r.position.y),
				xf * r.end,
				xf * Vector2(r.position.x, r.end.y),
				xf * r.position,
			])
			draw_polyline(corners, Color(1.0, 0.35, 0.85, 0.95), 1.5)

# 满屏覆盖、不吃输入、z 高，扫描整棵界面树，把每个可见控件的矩形（空间框）画成黑边。
# 由 SHOW_SPACE_FRAMES 常量控制是否创建。判定框(z900)画在它上面。
class SpaceFrameDebugOverlay:
	extends Control
	var scan_root: Control

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		z_index = 899

	func _process(_delta: float) -> void:
		# 有些框跟随 3D 投影/布局每帧变化，直接每帧重画。
		queue_redraw()

	func _draw() -> void:
		if scan_root == null:
			return
		var inv := get_global_transform().affine_inverse()
		_scan(scan_root, inv)

	func _scan(node: Node, inv: Transform2D) -> void:
		for child in node.get_children():
			if not (child is Control):
				continue
			var c := child as Control
			if not c.visible:
				continue
			if c.name.ends_with("DebugOverlay"):
				continue   # 跳过调试层自身
			_draw_frame(c, inv)
			_scan(c, inv)

	func _draw_frame(c: Control, inv: Transform2D) -> void:
		if c.size.x <= 0.0 or c.size.y <= 0.0:
			return
		var xf := inv * c.get_global_transform()
		var r := Rect2(Vector2.ZERO, c.size)
		var corners := PackedVector2Array([
			xf * r.position,
			xf * Vector2(r.end.x, r.position.y),
			xf * r.end,
			xf * Vector2(r.position.x, r.end.y),
			xf * r.position,
		])
		draw_polyline(corners, Color(0.0, 0.0, 0.0, 0.9), 1.0)

var _player_formation_art: FormationCrystal
var _enemy_formation_art: FormationCrystal
var _start_battle_label: Label
var _start_battle_button: Button
var _round_info_label: Label
var _ready_indicator: Control
var _ready_dots: Array = []
var _toast_label: Label
var _toast_tween: Tween
var _player_formation_bar: TextureProgressBar
var _enemy_formation_bar: TextureProgressBar
var _player_formation_hp_label: Label
var _enemy_formation_hp_label: Label
var _board_grid: Control
var _bench_row: Control
var _standby_frame: Control
var _shop_row: HBoxContainer
var _shop_panel: SellDropPanel
var _shop_open_button: Button
var _buy_shop_button: Button      # 钱袋 A 上的透明「采购」热区，教学箭头要指它
var _shop_picker_open := false
var _shop_sell_overlay: PanelContainer
var _shop_side_controls: Control  # 商店"外挂"控件层（钱袋A购买键 + 刷新），挂屏幕上、不受商店面板矩形限制
var _closed_money_bag: Control    # 商店关闭时的钱袋按钮（商店按钮左边）
var _closed_gold_label: Label
var _refresh_shop_button: Button
var _refresh_shop_icon: Label
var _refresh_shop_cost_label: Label
var _gold_amount_label: Label
var _left_panel: VBoxContainer
var _merc_scroll: ScrollContainer
var _merc_panel: VBoxContainer
var _merc_overlay: PanelContainer
var _merc_overlay_grid: GridContainer
var _merc_count_label: Label
var _merc_button: Button
var _merc_picker_open := false
var _team_mercs_overlay: PanelContainer
var _team_mercs_viewport: SubViewport
var _team_mercs_stage_root: Node3D
var _team_mercs_empty_label: Label
var _team_mercs_render_timer: Timer
var _team_mercs_open := false
var _team_mercs_stage_signature := "unset"
var _treasure_overlay: ColorRect
var _treasure_timer_lbl: Label
var _treasure_choice_row: HBoxContainer
var _treasure_refresh_btn: Button
var _owned_treasure_box: GridContainer
var _board_buttons: Array[BoardCellButton] = []
var _board_readability_layer: BoardReadabilityLayer
var _board_relation_overlays: Array[RelationProgressOverlay] = []
var _board_cell_captions: Array[Label] = []   # 棋盘格子下方的「名字 ★星级」标签（有棋子才显示）
var _bench_buttons: Array[BenchCellButton] = []
var _bench_card_labels: Array[Label] = []
var _shop_buttons: Array[DragButton] = []
var _shop_portraits: Array[TextureRect] = []
var _shop_card_frames: Array[TextureRect] = []
var _shop_card_labels: Array[Label] = []
var _shop_price_labels: Array[Label] = []
var _shop_race_icons: Array[Control] = []
var _shop_reason_labels: Array[Label] = []
var _selected_shop := -1
var _selected_board := -1
var _selected_bench := -1
var _detail: PopupPanel
var _detail_text: RichTextLabel
var _stats_popup: PopupPanel
var _stats_text: RichTextLabel
var _stats_group := "player"
var _detail_waiting_for_release := false
var _detail_release_seen_press := false
var _gold_interest_detail_open := false
var _shop_drag_sell_mode := false
var _active_drag_payload: Dictionary = {}   # for snap-to-nearest-cell on release
var _drop_consumed := false
var _battle_launch_emitted := false
var _board_empty_style: StyleBoxFlat
var _board_hover_style: StyleBoxFlat
var _board_occupied_style: StyleBoxFlat
var _board_drop_style: StyleBoxFlat
var _board_drop_highlight_active := false
var _board_drop_hover_index := -1
var _standby_drop_highlight_active := false
var _standby_drop_hover_index := -1

func _board_player_color() -> Color:
	if NetworkService.team_active and NetworkService.team_local_slot >= 0:
		return GameConstants.team_slot_color(NetworkService.team_local_slot)
	return board_cell_rest_line
func _board_grid_size() -> Vector2:
	return Vector2(
		cell_size.x * float(GameConstants.BOARD_COLUMNS),
		cell_size.y * float(GameConstants.BOARD_ROWS)
	)

func _board_perspective_point(u: float, v: float, board_size: Vector2) -> Vector2:
	var v_fore := v / (1.0 + board_foreshorten * (1.0 - v))
	var top := board_top_left.lerp(board_top_right, u)
	var bottom := board_bottom_left.lerp(board_bottom_right, u)
	var normalized := top.lerp(bottom, v_fore)
	return normalized * board_size

func _board_cell_quad(index: int, board_size: Vector2) -> PackedVector2Array:
	var column := index % GameConstants.BOARD_COLUMNS
	var row := floori(float(index) / float(GameConstants.BOARD_COLUMNS))
	var u0 := float(column) / float(GameConstants.BOARD_COLUMNS)
	var u1 := float(column + 1) / float(GameConstants.BOARD_COLUMNS)
	var v0 := float(row) / float(GameConstants.BOARD_ROWS)
	var v1 := float(row + 1) / float(GameConstants.BOARD_ROWS)
	return PackedVector2Array([
		_board_perspective_point(u0, v0, board_size),
		_board_perspective_point(u1, v0, board_size),
		_board_perspective_point(u1, v1, board_size),
		_board_perspective_point(u0, v1, board_size),
	])

# Cross-layer hooks keep the original single-instance method dispatch intact.
func _build() -> void:
	pass

func _refresh_all() -> void:
	pass

func _auto_combine_all() -> void:
	pass

func _refresh_board() -> void:
	pass

func _setup_board_cell_styles() -> void:
	pass

func _sync_prep_board_readability_geometry() -> void:
	pass

func _sync_prep_board_readability_state() -> void:
	pass

func _load_board_art_texture() -> Texture2D:
	return null

func _refresh_bench() -> void:
	pass

func _refresh_shop() -> void:
	pass

func _refresh_left_panel() -> void:
	pass

func _refresh_merc_panel() -> void:
	pass

func _toggle_merc_picker() -> void:
	pass

func _close_merc_picker() -> void:
	pass

func _toggle_shop_picker() -> void:
	pass

func _close_shop_picker() -> void:
	pass

func _refresh_shop_picker() -> void:
	pass

func _refresh_treasure_panel() -> void:
	pass

func _maybe_start_pending_treasure() -> void:
	pass

func _pick_treasure(tid: String) -> void:
	pass

func _refresh_treasure_candidates() -> void:
	pass

func _claim_pending_treasure_round() -> void:
	pass

func _can_drop_on_board(board_index: int, data: Variant) -> bool:
	return false

func _drop_on_board(board_index: int, data: Variant) -> void:
	pass

func _can_drop_on_bench(bench_index: int, data: Variant) -> bool:
	return false

func _drop_on_bench(bench_index: int, data: Variant) -> void:
	pass

func _can_drop_to_sell(data: Variant) -> bool:
	return false

func _drop_to_sell(data: Variant) -> void:
	pass

func _on_drag_started(payload: Dictionary) -> void:
	pass

func _on_drag_ended() -> void:
	pass

func _set_board_drop_hover(board_index: int) -> void:
	pass

func _set_standby_drop_hover(bench_index: int) -> void:
	pass

func _set_shop_sell_mode(enabled: bool) -> void:
	pass

func _on_start_battle() -> void:
	pass

func _emit_battle_request_once() -> void:
	pass

func _has_any_board_unit() -> bool:
	return false

func _mark_online_board_changed() -> void:
	pass

func _on_network_session_changed() -> void:
	pass

func _on_hire_mercenary(index: int) -> void:
	pass

func _can_hire_mercenary(index: int) -> bool:
	return false

func _hire_mercenary_to_slot(index: int, mercenary_index: int) -> void:
	pass

func _on_shop_pressed(index: int) -> void:
	pass

func _on_buy_selected_shop() -> void:
	pass

func _on_board_pressed(index: int) -> void:
	pass

func _on_bench_pressed(index: int) -> void:
	pass

func _buy_or_merge_shop_to_board(shop_index: int, board_index: int) -> void:
	pass

func _buy_or_merge_shop_to_bench(shop_index: int, bench_index: int) -> void:
	pass

func _has_unique_board_unit(unit_id: String) -> bool:
	return false

func _move_or_merge_board(from_index: int, to_index: int) -> void:
	pass

func _move_or_merge_board_to_bench(from_index: int, bench_index: int) -> void:
	pass

func _move_or_merge_bench_to_board(from_index: int, board_index: int) -> void:
	pass

func _move_or_merge_bench(from_index: int, to_index: int) -> void:
	pass

func _on_sell_selected() -> void:
	pass

func _sell_board_index(index: int) -> void:
	pass

func _sell_bench_index(index: int) -> void:
	pass

func _first_empty_board_slot() -> int:
	return 0

func _first_empty_bench_slot() -> int:
	return 0

func _first_empty_mercenary_slot() -> int:
	return 0

func _bench_count() -> int:
	return 0

func _can_merge_cells(target: Dictionary, incoming: Dictionary) -> bool:
	return false

func _merge_three_into_cell(target: Dictionary, incoming: Dictionary, excluded_board: Array = [], excluded_bench: Array = []) -> bool:
	return false

func _take_extra_merge_piece(id: String, star: int, excluded_board: Array, excluded_bench: Array) -> Dictionary:
	return {}

func _preserve_unique_king_growth_on_merge(target: Dictionary, incoming: Dictionary, extra: Dictionary) -> void:
	pass

func _unique_king_growth_score(d: Dictionary) -> float:
	return 0.0

func _is_merge_piece(cell: Variant, id: String, star: int) -> bool:
	return false

func _sell_refund_for_cell(cell: Dictionary) -> int:
	return 0

func _on_golden_altar() -> void:
	pass

func _on_generous_fate_gamble() -> void:
	pass

func _on_refresh_shop() -> void:
	pass

func _roll_shop() -> void:
	pass

func _roll_shop_tier(rng: RandomNumberGenerator) -> int:
	return 0

func _shop_unit_cost(unit_def: Dictionary) -> int:
	return 0

func _add_current_synergy_widgets() -> void:
	pass

func _add_power_recommendation_widgets() -> void:
	pass

func _show_last_battle_stats() -> void:
	pass

func _show_power_recommendation() -> void:
	pass

func _set_stats_group(group: String) -> void:
	pass

func _refresh_stats_popup() -> void:
	pass

func _last_battle_result_for_stats() -> Dictionary:
	return {}

func _stats_group_label(group: String) -> String:
	return ""

func _entry_stats_group(entry: Dictionary) -> String:
	return ""

func _sanitize_stats_cell(text: String) -> String:
	return ""

func _format_status_bucket(value: Variant) -> String:
	return ""

func _format_seconds(seconds: float) -> String:
	return ""

func _status_display_name(kind: String) -> String:
	return ""

func _current_player_power() -> float:
	return 0.0

func _next_enemy_power_text() -> String:
	return ""

func _estimated_pve_power(count: int) -> float:
	return 0.0

func _estimated_boss_power() -> float:
	return 0.0

func _unit_power_from_def(d: Dictionary) -> float:
	return 0.0

func _skill_dps_from_def(d: Dictionary, atk: float) -> float:
	return 0.0

func _format_power(value: float) -> String:
	return ""

func _race_name(race: String) -> String:
	return ""

func _race_synergy_entries(race: String) -> Array:
	return []

func _format_synergy_detail(race: String, count: int) -> String:
	return ""

func _show_shop_detail(index: int) -> void:
	pass

func _show_board_detail(index: int) -> void:
	pass

func _show_bench_detail(index: int) -> void:
	pass

func _format_unit_def(d: Dictionary, star: int = 1) -> String:
	return ""

func _unit_race_name(race: String) -> String:
	return ""

func _unit_element_name(element: String) -> String:
	return ""

func _strip_bbcode(text: String) -> String:
	return ""

func _format_skill_detail(d: Dictionary) -> String:
	return ""

func _skill_cd_text(d: Dictionary) -> String:
	return ""

func _pct(value: float) -> String:
	return ""

func _show_treasure_detail(tid: String) -> void:
	pass

func _show_linkage_detail(link_id: String) -> void:
	pass

func _format_treasure_detail(t: Dictionary) -> String:
	return ""

func _treasure_category_name(category: String) -> String:
	return ""

func _treasure_set_status(category: String) -> String:
	return ""

func _treasure_linkage_status(tid: String) -> Array[String]:
	return []

func _treasure_set_effect_text(category: String) -> String:
	return ""

func _treasure_effect_text(tid: String) -> String:
	return ""

func _treasure_link_effect_text(link_id: String) -> String:
	return ""

func _format_dict_detail(d: Dictionary) -> String:
	return ""

func _show_text_detail(text: String) -> void:
	pass

func _hide_detail() -> void:
	pass

func _update_detail_release_state() -> void:
	pass

func _attach_long_press(btn: BaseButton, cb: Callable) -> void:
	pass
