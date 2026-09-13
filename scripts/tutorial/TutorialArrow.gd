extends Control

# The visible tip has a fixed coordinate. Font fallback can change the ink and
# line metrics of a triangle glyph on Android, so it cannot anchor a pointer.
enum Direction { DOWN, UP, LEFT }

const EXTENT := Vector2(84.0, 84.0)
const INSET := 4.0
var direction: int = Direction.DOWN


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = EXTENT
	size = EXTENT


func set_direction(value: int) -> void:
	direction = value
	queue_redraw()


func tip_position() -> Vector2:
	match direction:
		Direction.UP:
			return Vector2(size.x * 0.5, INSET)
		Direction.LEFT:
			return Vector2(INSET, size.y * 0.5)
	return Vector2(size.x * 0.5, size.y - INSET)


func _draw() -> void:
	var points: PackedVector2Array
	match direction:
		Direction.UP:
			points = PackedVector2Array([tip_position(),
				Vector2(size.x - INSET, size.y - INSET), Vector2(INSET, size.y - INSET)])
		Direction.LEFT:
			points = PackedVector2Array([tip_position(),
				Vector2(size.x - INSET, INSET), Vector2(size.x - INSET, size.y - INSET)])
		_:
			points = PackedVector2Array([tip_position(),
				Vector2(INSET, INSET), Vector2(size.x - INSET, INSET)])
	draw_colored_polygon(points, Color(0.95, 0.13, 0.10))
	points.append(points[0])
	draw_polyline(points, Color(0.12, 0.0, 0.0), 3.0, true)
