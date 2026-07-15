extends Node

const TABLES := [
	{"kind": "unit", "path": "res://data/units/race_units.json", "key": "units"},
	{"kind": "merc", "path": "res://data/mercenary/mercenaries.json", "key": "mercenaries"},
]

func _ready() -> void:
	var rows: Array[Dictionary] = []
	var broken: Array[String] = []
	for table in TABLES:
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(table.path)))
		if not (parsed is Dictionary):
			broken.append("%s: JSON parse failed" % str(table.path))
			continue
		for item in (parsed as Dictionary).get(str(table.key), []):
			var def := item as Dictionary
			var model_path := str(def.get("model", ""))
			if model_path.is_empty():
				continue
			var scene := load(model_path) as PackedScene
			if scene == null:
				broken.append("%s missing scene %s" % [str(def.get("id", "")), model_path])
				continue
			var node := scene.instantiate()
			if not (node is Node3D):
				broken.append("%s scene is not Node3D %s" % [str(def.get("id", "")), model_path])
				node.queue_free()
				continue
			var model := node as Node3D
			model.set_meta("load_idle_only", true)
			add_child(model)
			for _i in 3:
				await get_tree().process_frame
			var bounds := _node3d_bounds(model)
			var span := maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z))
			var scale := float(def.get("model_visual_scale", 1.0))
			rows.append({
				"kind": str(table.kind),
				"id": str(def.get("id", "")),
				"name": str(def.get("name", "")),
				"name_en": str(def.get("name_en", "")),
				"path": model_path,
				"span": span,
				"scale": scale,
				"final": span * scale,
			})
			model.queue_free()
			await get_tree().process_frame
	rows.sort_custom(_sort_by_final_desc)
	print("MODEL_BOUNDS_TOP")
	for i in range(rows.size()):
		var row := rows[i]
		print("%s\t%s\t%s\tspan=%.3f\tscale=%.3f\tfinal=%.3f\t%s" % [
			str(row.kind),
			str(row.id),
			str(row.name_en) if not str(row.name_en).is_empty() else str(row.name),
			float(row.span),
			float(row.scale),
			float(row.final),
			str(row.path),
		])
	print("MODEL_BOUNDS_BROKEN count=%d" % broken.size())
	for item in broken:
		print(item)
	get_tree().quit()

func _sort_by_final_desc(a: Dictionary, b: Dictionary) -> bool:
	return float(a.final) > float(b.final)

func _node3d_bounds(root_node: Node3D) -> AABB:
	var bounds := AABB()
	var has_bounds := false
	var root_inv := root_node.global_transform.affine_inverse()
	var stack: Array[Node] = [root_node]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is MeshInstance3D:
			var mesh_node := node as MeshInstance3D
			if mesh_node.mesh == null or not mesh_node.is_visible_in_tree():
				continue
			var mesh_bounds := _transformed_aabb(mesh_node.get_aabb(), root_inv * mesh_node.global_transform)
			if not has_bounds:
				bounds = mesh_bounds
				has_bounds = true
			else:
				bounds = bounds.merge(mesh_bounds)
	return bounds if has_bounds else AABB()

func _transformed_aabb(box: AABB, transform: Transform3D) -> AABB:
	var p := box.position
	var s := box.size
	var corners := [
		p,
		p + Vector3(s.x, 0.0, 0.0),
		p + Vector3(0.0, s.y, 0.0),
		p + Vector3(0.0, 0.0, s.z),
		p + Vector3(s.x, s.y, 0.0),
		p + Vector3(s.x, 0.0, s.z),
		p + Vector3(0.0, s.y, s.z),
		p + s,
	]
	var out := AABB(transform * corners[0], Vector3.ZERO)
	for i in range(1, corners.size()):
		out = out.expand(transform * corners[i])
	return out
