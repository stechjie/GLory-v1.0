extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const CHECK_NAME := "model_asset_budget"
const BUDGET_PATH := "res://data/presentation/model_asset_budgets.json"

const TABLES := [
	{"kind": "unit", "path": "res://data/units/race_units.json", "key": "units"},
	{"kind": "merc", "path": "res://data/mercenary/mercenaries.json", "key": "mercenaries"},
	{"kind": "monster", "path": "res://data/pve/pve_monsters.json", "key": "monsters"},
	{"kind": "boss", "path": "res://data/boss/bosses.json", "key": "bosses"},
	{"kind": "ally", "path": "res://data/formation/formation_allies.json", "key": "allies"},
]

var _h: CheckHarness
var _budget_config: Dictionary = {}


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	if not _load_budgets():
		_h.finish(get_tree())
		return
	var records := _collect_model_records()
	var rows: Array[Dictionary] = []
	for record in records:
		_h.item()
		var scene := ResourceLoader.load(str(record.path)) as PackedScene
		if scene == null:
			_h.fail("scene_load_failed", "%s 场景无法加载：%s" % [str(record.id), str(record.path)])
			continue
		var model := scene.instantiate() as Node3D
		if model == null:
			_h.fail("scene_instantiate_failed", "%s 根节点不是 Node3D：%s" % [str(record.id), str(record.path)])
			continue

		# Do not set load_idle_only here. Hidden attack/run children still occupy runtime
		# memory in the current wrappers and must count against the resident budget.
		add_child(model)
		for _frame in 2:
			await get_tree().process_frame
		var stats := _scan_model(model)
		var row := record.duplicate(true)
		row.merge(stats, true)
		rows.append(row)
		_apply_budget(row)
		remove_child(model)
		model.free()
		await get_tree().process_frame

	rows.sort_custom(_sort_by_resident_vertices_desc)
	print("MODEL_ASSET_BUDGET_TOP count=%d policy=%s" % [rows.size(), str(_budget_config.get("status", "unknown"))])
	for row in rows:
		print("%s\t%s\tvisible_v=%d\tresident_v=%d\tresident_tri=%d\tsurfaces=%d\tmaterials=%d\tskeletons=%d\tmax_bones=%d\ttexture_edge=%d\t%s" % [
			str(row.role), str(row.id), int(row.visible_vertices), int(row.resident_vertices),
			int(row.resident_triangles), int(row.surfaces), int(row.materials),
			int(row.skeletons), int(row.max_bones), int(row.max_texture_edge), str(row.path),
		])
	_h.finish(get_tree())


func _load_budgets() -> bool:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(BUDGET_PATH))
	if not (parsed is Dictionary):
		_h.fail("budget_parse_failed", "%s JSON 解析失败" % BUDGET_PATH)
		return false
	_budget_config = parsed as Dictionary
	if not (_budget_config.get("defaults", {}) is Dictionary) or not (_budget_config.get("roles", {}) is Dictionary):
		_h.fail("budget_schema_invalid", "%s 缺少 defaults 或 roles" % BUDGET_PATH)
		return false
	return true


func _collect_model_records() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen: Dictionary = {}
	for table in TABLES:
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(table.path)))
		if not (parsed is Dictionary):
			_h.fail("table_parse_failed", "%s JSON 解析失败" % str(table.path))
			continue
		for value in (parsed as Dictionary).get(str(table.key), []):
			if not (value is Dictionary):
				continue
			var definition := value as Dictionary
			var role := str(table.kind)
			if role == "unit" and int(definition.get("tier", 1)) >= 3:
				role = "hero"
			for model_ref in _model_refs_for_def(definition):
				var model_path := str(model_ref.path)
				if seen.has(model_path):
					continue
				seen[model_path] = true
				out.append({
					"id": str(definition.get("id", "")) + str(model_ref.suffix),
					"name": str(definition.get("name_en", definition.get("name", ""))),
					"role": role,
					"path": model_path,
				})
	return out


func _model_refs_for_def(definition: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen: Dictionary = {}
	var base_path := str(definition.get("model", ""))
	if not base_path.is_empty():
		out.append({"path": base_path, "suffix": ""})
		seen[base_path] = true
	var variants_value: Variant = definition.get("model_by_element", {})
	if variants_value is Dictionary:
		for element in (variants_value as Dictionary).keys():
			var variant_path := str((variants_value as Dictionary)[element])
			if variant_path.is_empty() or seen.has(variant_path):
				continue
			out.append({"path": variant_path, "suffix": "[%s]" % str(element)})
			seen[variant_path] = true
	return out


func _scan_model(model: Node3D) -> Dictionary:
	var stats := {
		"visible_vertices": 0,
		"resident_vertices": 0,
		"resident_triangles": 0,
		"surfaces": 0,
		"skeletons": 0,
		"max_bones": 0,
		"max_texture_edge": 0,
	}
	var material_ids: Dictionary = {}
	var texture_ids: Dictionary = {}
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is Skeleton3D:
			stats.skeletons += 1
			stats.max_bones = maxi(int(stats.max_bones), (node as Skeleton3D).get_bone_count())
		elif node is MeshInstance3D:
			_scan_mesh(node as MeshInstance3D, stats, material_ids, texture_ids)
	stats["materials"] = material_ids.size()
	stats["textures"] = texture_ids.size()
	return stats


func _scan_mesh(mesh_instance: MeshInstance3D, stats: Dictionary, material_ids: Dictionary, texture_ids: Dictionary) -> void:
	if mesh_instance.mesh == null:
		return
	var is_visible := mesh_instance.is_visible_in_tree()
	for surface_index in range(mesh_instance.mesh.get_surface_count()):
		stats.surfaces += 1
		var arrays := mesh_instance.mesh.surface_get_arrays(surface_index)
		var vertex_count := 0
		var index_count := 0
		if arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] != null:
			vertex_count = arrays[Mesh.ARRAY_VERTEX].size()
		if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null:
			index_count = arrays[Mesh.ARRAY_INDEX].size()
		stats.resident_vertices += vertex_count
		if is_visible:
			stats.visible_vertices += vertex_count
		if mesh_instance.mesh.surface_get_primitive_type(surface_index) == Mesh.PRIMITIVE_TRIANGLES:
			stats.resident_triangles += int((index_count if index_count > 0 else vertex_count) / 3)
		var material := mesh_instance.get_active_material(surface_index)
		if material == null:
			continue
		_collect_material_chain(material, material_ids, texture_ids, stats)


func _collect_material_chain(material: Material, material_ids: Dictionary, texture_ids: Dictionary, stats: Dictionary) -> void:
	if material == null:
		return
	var material_key := material.resource_path
	if material_key.is_empty():
		material_key = str(material.get_instance_id())
	if material_ids.has(material_key):
		return
	material_ids[material_key] = true
	_collect_material_textures(material, texture_ids, stats)
	_collect_material_chain(material.next_pass, material_ids, texture_ids, stats)


func _collect_material_textures(material: Material, texture_ids: Dictionary, stats: Dictionary) -> void:
	var base := material as BaseMaterial3D
	if base != null:
		for slot in [BaseMaterial3D.TEXTURE_ALBEDO, BaseMaterial3D.TEXTURE_NORMAL,
			BaseMaterial3D.TEXTURE_EMISSION, BaseMaterial3D.TEXTURE_ORM,
			BaseMaterial3D.TEXTURE_METALLIC, BaseMaterial3D.TEXTURE_ROUGHNESS]:
			_record_texture(base.get_texture(slot), texture_ids, stats)
		return
	if material is ShaderMaterial:
		# Shader parameters are dynamic properties; this also covers the project's
		# character_toon albedo_texture uniforms.
		for property in material.get_property_list():
			var property_name := str(property.get("name", ""))
			if not property_name.begins_with("shader_parameter/"):
				continue
			var value: Variant = material.get(property_name)
			if value is Texture2D:
				_record_texture(value as Texture2D, texture_ids, stats)


func _record_texture(texture: Texture2D, texture_ids: Dictionary, stats: Dictionary) -> void:
	if texture == null:
		return
	var key := texture.resource_path
	if key.is_empty():
		key = str(texture.get_instance_id())
	texture_ids[key] = true
	stats.max_texture_edge = maxi(int(stats.max_texture_edge), maxi(texture.get_width(), texture.get_height()))


func _apply_budget(row: Dictionary) -> void:
	var budget := _budget_for_role(str(row.role))
	if budget.is_empty():
		_h.fail("missing_role_budget", "%s 没有 role=%s 的预算" % [str(row.id), str(row.role)])
		return
	_check_metric(row, budget, "visible_vertices", "visible_vertices_soft", "visible_vertices_hard")
	_check_metric(row, budget, "resident_vertices", "resident_vertices_soft", "resident_vertices_hard")
	_check_metric(row, budget, "resident_triangles", "resident_triangles_soft", "resident_triangles_hard")
	_check_hard_metric(row, budget, "surfaces", "surfaces_hard")
	_check_hard_metric(row, budget, "materials", "materials_hard")
	_check_hard_metric(row, budget, "skeletons", "skeletons_hard")
	_check_hard_metric(row, budget, "max_bones", "bones_per_skeleton_hard")
	_check_metric(row, budget, "max_texture_edge", "texture_edge_soft", "texture_edge_hard")


func _budget_for_role(role: String) -> Dictionary:
	var result := (_budget_config.get("defaults", {}) as Dictionary).duplicate(true)
	var roles := _budget_config.get("roles", {}) as Dictionary
	if not roles.has(role):
		return {}
	var overrides := roles.get(role, {}) as Dictionary
	for key in overrides.keys():
		result[key] = overrides[key]
	return result


func _check_metric(row: Dictionary, budget: Dictionary, metric: String, soft_key: String, hard_key: String) -> void:
	var value := int(row.get(metric, 0))
	var hard_limit := int(budget.get(hard_key, 0))
	if hard_limit <= 0:
		_h.fail("budget_schema_invalid", "%s 缺少 %s" % [str(row.role), hard_key])
		return
	if value > hard_limit:
		_h.fail("%s_hard" % metric, "%s role=%s %s=%d > hard=%d (%s)" % [
			str(row.id), str(row.role), metric, value, hard_limit, str(row.path)])
		return
	var soft_limit := int(budget.get(soft_key, 0))
	if soft_limit > 0 and value > soft_limit:
		_h.note("软预算：%s role=%s %s=%d > soft=%d" % [str(row.id), str(row.role), metric, value, soft_limit])


func _check_hard_metric(row: Dictionary, budget: Dictionary, metric: String, hard_key: String) -> void:
	var value := int(row.get(metric, 0))
	var hard_limit := int(budget.get(hard_key, 0))
	if hard_limit <= 0:
		_h.fail("budget_schema_invalid", "%s 缺少 %s" % [str(row.role), hard_key])
	elif value > hard_limit:
		_h.fail("%s_hard" % metric, "%s role=%s %s=%d > hard=%d (%s)" % [
			str(row.id), str(row.role), metric, value, hard_limit, str(row.path)])


func _sort_by_resident_vertices_desc(a: Dictionary, b: Dictionary) -> bool:
	return int(a.resident_vertices) > int(b.resident_vertices)
