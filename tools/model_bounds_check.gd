extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const CHECK_NAME := "model_bounds"

# 低于这个尺寸视为"能 load 但实际没有可见网格"。缺贴图/缺子资源的 FBX 在
# headless 下只往 stderr 吐 ERROR，load() 仍返回非 null，span 却是 0 ——
# 这种"假可加载"以前只体现在打印出来的表格里，没人会去逐行看。
const MIN_VALID_SPAN := 0.001

const TABLES := [
	{"kind": "unit", "path": "res://data/units/race_units.json", "key": "units"},
	{"kind": "merc", "path": "res://data/mercenary/mercenaries.json", "key": "mercenaries"},
	{"kind": "monster", "path": "res://data/pve/pve_monsters.json", "key": "monsters"},
	{"kind": "boss", "path": "res://data/boss/bosses.json", "key": "bosses"},
	{"kind": "ally", "path": "res://data/formation/formation_allies.json", "key": "allies"},
]

var _h: CheckHarness

func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var rows: Array[Dictionary] = []
	var broken: Array[String] = []
	for table in TABLES:
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(table.path)))
		if not (parsed is Dictionary):
			broken.append("%s: JSON parse failed" % str(table.path))
			_h.fail("table_parse_failed", "%s JSON 解析失败" % str(table.path))
			continue
		for item in (parsed as Dictionary).get(str(table.key), []):
			var def := item as Dictionary
			for model_ref in _model_refs_for_def(def):
				var model_path := str(model_ref.path)
				var display_id := str(def.get("id", "")) + str(model_ref.suffix)
				_h.item()
				var scene := load(model_path) as PackedScene
				if scene == null:
					broken.append("%s missing scene %s" % [display_id, model_path])
					_h.fail("broken_scene", "%s 场景无法加载：%s" % [display_id, model_path])
					continue
				var node := scene.instantiate()
				if not (node is Node3D):
					broken.append("%s scene is not Node3D %s" % [display_id, model_path])
					_h.fail("not_node3d", "%s 根节点不是 Node3D：%s" % [display_id, model_path])
					node.queue_free()
					continue
				var model := node as Node3D
				model.set_meta("load_idle_only", true)
				add_child(model)
				for _i in 3:
					await get_tree().process_frame
				var bounds := _node3d_bounds(model)
				var span := maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z))
				if span <= MIN_VALID_SPAN:
					_h.fail("span_zero", "%s 加载成功但没有可见网格（span=%.4f）：%s" % [
						display_id, span, model_path])
				var scale := float(def.get("model_visual_scale", 1.0))
				rows.append({
					"kind": str(table.kind),
					"id": display_id,
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
	_h.finish(get_tree())


func _model_refs_for_def(def: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen: Dictionary = {}
	var base_path := str(def.get("model", ""))
	if not base_path.is_empty():
		out.append({"path": base_path, "suffix": ""})
		seen[base_path] = true
	var variants_value = def.get("model_by_element", {})
	if typeof(variants_value) == TYPE_DICTIONARY:
		for element in (variants_value as Dictionary).keys():
			var variant_path := str((variants_value as Dictionary)[element])
			if variant_path.is_empty() or seen.has(variant_path):
				continue
			out.append({"path": variant_path, "suffix": "[%s]" % str(element)})
			seen[variant_path] = true
	return out

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
