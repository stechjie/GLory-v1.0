extends PanelContainer

# A transparent history window must yield to formation cells under its children,
# including the scroll container and typing button. Clipping checks this shape
# before Godot searches the children; IGNORE on the background alone cannot do it.
var formation_cells: Array = []

func _has_point(point: Vector2) -> bool:
	if not Rect2(Vector2.ZERO, size).has_point(point):
		return false
	var global_point := get_global_transform() * point
	for cell in formation_cells:
		if not is_instance_valid(cell) or not cell.is_visible_in_tree():
			continue
		var local_point: Vector2 = cell.get_global_transform().affine_inverse() * global_point
		if cell._has_point(local_point):
			return false
	return true
