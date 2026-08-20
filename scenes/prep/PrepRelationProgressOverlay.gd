extends Control

# 棋盘格上的种族关系进度环。纯绘制，零依赖。

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
