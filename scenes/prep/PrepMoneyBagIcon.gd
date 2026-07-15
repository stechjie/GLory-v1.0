extends Control


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var bag_color := Color(0.92, 0.68, 0.18, 1.0)
	var bag_shadow := Color(0.38, 0.22, 0.04, 0.95)
	var body := PackedVector2Array([
		Vector2(center.x - 10.0, center.y - 3.0),
		Vector2(center.x - 13.0, center.y + 10.0),
		Vector2(center.x - 8.0, center.y + 14.0),
		Vector2(center.x + 8.0, center.y + 14.0),
		Vector2(center.x + 13.0, center.y + 10.0),
		Vector2(center.x + 10.0, center.y - 3.0),
	])
	draw_colored_polygon(body, bag_color)
	draw_polyline(body, bag_shadow, 2.0, true)
	draw_rect(Rect2(center.x - 8.0, center.y - 7.0, 16.0, 5.0), bag_shadow, true)
	draw_line(Vector2(center.x - 7.0, center.y - 10.0), Vector2(center.x + 7.0, center.y - 10.0), bag_color, 4.0)
	draw_circle(Vector2(center.x, center.y + 6.0), 4.2, Color(1.0, 0.86, 0.34, 1.0))
	draw_line(Vector2(center.x, center.y + 2.5), Vector2(center.x, center.y + 9.5), bag_shadow, 1.5)
