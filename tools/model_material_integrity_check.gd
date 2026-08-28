extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const UnitVisualResolverScript := preload("res://effects/runtime/presentation/UnitVisualResolver.gd")

const CHECK_NAME := "model_material_integrity"
const WHITELIST_PATH := "res://data/qa/intentional_untextured_materials.json"
const REPORT_PATH := "res://reports/model_material_integrity.json"
const WHITE_FLOOR := 0.97

var _h: CheckHarness
var _whitelist_by_audit_key: Dictionary = {}
var _whitelist_by_material_path: Dictionary = {}
var _whitelist_entries: Array[Dictionary] = []
var _whitelist_hits: Dictionary = {}
var _rows: Array[Dictionary] = []
var _seen_model_paths: Dictionary = {}
var _summary := {
	"models": 0,
	"surfaces": 0,
	"materials": 0,
	"textures": 0,
	"scene_load_failed": 0,
	"material_missing": 0,
	"missing_texture": 0,
	"white_material_suspect": 0,
	"whitelisted_untextured": 0,
}


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	if not _load_whitelist():
		_write_report()
		_h.finish(get_tree())
		return

	var entries := UnitVisualResolverScript.all_combat_entries()
	if entries.is_empty():
		_h.fail("combat_entries_empty", "UnitVisualResolver 没有枚举到可战斗单位")
	else:
		for definition in entries:
			var unit_id := str(definition.get("id", ""))
			for model_path in UnitVisualResolverScript.all_model_paths(definition):
				if _seen_model_paths.has(model_path):
					continue
				_seen_model_paths[model_path] = unit_id
				await _audit_model(unit_id, str(definition.get("visual_kind", "unit")), model_path)

	_check_stale_whitelist_entries()
	_write_report()
	print("MODEL_MATERIAL_INTEGRITY models=%d surfaces=%d materials=%d textures=%d scene_load_failed=%d material_missing=%d missing_texture=%d white_material_suspect=%d whitelisted=%d report=%s" % [
		int(_summary.models), int(_summary.surfaces), int(_summary.materials), int(_summary.textures),
		int(_summary.scene_load_failed), int(_summary.material_missing), int(_summary.missing_texture),
		int(_summary.white_material_suspect), int(_summary.whitelisted_untextured), REPORT_PATH,
	])
	_h.finish(get_tree())


func _audit_model(unit_id: String, kind: String, model_path: String) -> void:
	_h.item()
	var scene := ResourceLoader.load(model_path) as PackedScene
	if scene == null:
		_summary.scene_load_failed = int(_summary.scene_load_failed) + 1
		_h.fail("scene_load_failed", "%s 场景无法加载：%s" % [unit_id, model_path])
		_rows.append({"unit_id": unit_id, "kind": kind, "scene_path": model_path, "status": "SCENE_LOAD_FAILED"})
		return

	var instance := scene.instantiate()
	if not (instance is Node3D):
		_summary.scene_load_failed = int(_summary.scene_load_failed) + 1
		_h.fail("scene_root_not_node3d", "%s 场景根节点不是 Node3D：%s" % [unit_id, model_path])
		if instance != null:
			instance.queue_free()
		_rows.append({"unit_id": unit_id, "kind": kind, "scene_path": model_path, "status": "ROOT_NOT_NODE3D"})
		return

	var model := instance as Node3D
	# Material integrity must include every resident action model. Several wrappers
	# load separate idle / attack / run FBXs, and a healthy idle material must not
	# hide a broken attack texture.
	add_child(model)
	for _frame in 2:
		await get_tree().process_frame

	_summary.models = int(_summary.models) + 1
	var model_row := {
		"unit_id": unit_id,
		"kind": kind,
		"scene_path": model_path,
		"status": "PASS",
		"surface_count": 0,
		"material_count": 0,
		"texture_count": 0,
		"suspect_white_count": 0,
		"missing_material_count": 0,
		"missing_texture_count": 0,
		"surfaces": [],
	}
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is MeshInstance3D:
			_audit_mesh(model, node as MeshInstance3D, model_path, model_row)

	if int(model_row.surface_count) == 0:
		model_row.status = "NO_MESH_SURFACES"
		_h.fail("no_mesh_surfaces", "%s 没有可审计的 MeshInstance3D surface：%s" % [unit_id, model_path])
	elif int(model_row.suspect_white_count) > 0 or int(model_row.missing_material_count) > 0 \
			or int(model_row.missing_texture_count) > 0:
		model_row.status = "FAIL"
	_rows.append(model_row)
	remove_child(model)
	model.free()
	await get_tree().process_frame


func _audit_mesh(model_root: Node3D, mesh_instance: MeshInstance3D, model_path: String, model_row: Dictionary) -> void:
	if mesh_instance.mesh == null:
		return
	var node_path := str(model_root.get_path_to(mesh_instance))
	for surface_index in range(mesh_instance.mesh.get_surface_count()):
		_h.item()
		_summary.surfaces = int(_summary.surfaces) + 1
		model_row.surface_count = int(model_row.surface_count) + 1
		var audit_key := "%s::%s::surface=%d" % [model_path, node_path, surface_index]
		var resolved := _resolve_material(mesh_instance, surface_index)
		var material := resolved.material as Material
		var surface_row := {
			"audit_key": audit_key,
			"node_path": node_path,
			"surface": surface_index,
			"source": str(resolved.source),
			"material_class": "",
			"material_path": "",
			"vertex_color": _surface_has_vertex_color(mesh_instance.mesh, surface_index),
			"white_material_suspect": false,
			"whitelisted": false,
			"textures": [],
		}
		if material == null:
			_summary.material_missing = int(_summary.material_missing) + 1
			model_row.missing_material_count = int(model_row.missing_material_count) + 1
			_h.fail("material_missing", "%s 没有最终生效材质" % audit_key)
			(model_row.surfaces as Array).append(surface_row)
			continue

		_summary.materials = int(_summary.materials) + 1
		model_row.material_count = int(model_row.material_count) + 1
		surface_row.material_class = material.get_class()
		surface_row.material_path = material.resource_path
		var material_result := _inspect_material_chain(material, bool(surface_row.vertex_color))
		surface_row.textures = material_result.textures
		surface_row.color_evidence = material_result.color_evidence
		surface_row.albedo = material_result.albedo
		var texture_count := (material_result.textures as Array).size()
		_summary.textures = int(_summary.textures) + texture_count
		model_row.texture_count = int(model_row.texture_count) + texture_count
		var missing_count := int(material_result.missing_texture_count)
		if missing_count > 0:
			_summary.missing_texture = int(_summary.missing_texture) + missing_count
			model_row.missing_texture_count = int(model_row.missing_texture_count) + missing_count
			_h.fail("missing_texture", "%s 有 %d 张贴图无法加载" % [audit_key, missing_count])

		if bool(material_result.white_suspect):
			var whitelist := _whitelist_for(audit_key, material.resource_path)
			if whitelist.is_empty():
				surface_row.white_material_suspect = true
				_summary.white_material_suspect = int(_summary.white_material_suspect) + 1
				model_row.suspect_white_count = int(model_row.suspect_white_count) + 1
				_h.fail("white_material_suspect", "%s 使用近白材质、无颜色贴图且无有效 vertex color（material=%s class=%s）" % [
					audit_key, material.resource_path if not material.resource_path.is_empty() else "<embedded>", material.get_class(),
				])
			else:
				surface_row.whitelisted = true
				surface_row.whitelist_reason = str(whitelist.reason)
				_summary.whitelisted_untextured = int(_summary.whitelisted_untextured) + 1
		(model_row.surfaces as Array).append(surface_row)


func _resolve_material(mesh_instance: MeshInstance3D, surface_index: int) -> Dictionary:
	if mesh_instance.material_override != null:
		return {"material": mesh_instance.material_override, "source": "material_override"}
	var surface_override := mesh_instance.get_surface_override_material(surface_index)
	if surface_override != null:
		return {"material": surface_override, "source": "surface_override"}
	return {"material": mesh_instance.mesh.surface_get_material(surface_index), "source": "mesh_surface"}


func _inspect_material_chain(material: Material, has_vertex_color: bool) -> Dictionary:
	var textures: Array[Dictionary] = []
	var seen_materials: Dictionary = {}
	var has_color_texture := false
	var has_nonwhite_color := false
	var uses_vertex_color := false
	var albedo_text := ""
	var current: Material = material
	while current != null:
		var material_id := current.get_instance_id()
		if seen_materials.has(material_id):
			break
		seen_materials[material_id] = true
		if current is BaseMaterial3D:
			var base := current as BaseMaterial3D
			var albedo := base.albedo_color
			albedo_text = albedo.to_html(true)
			has_nonwhite_color = has_nonwhite_color or not _is_near_white(albedo)
			uses_vertex_color = uses_vertex_color or (has_vertex_color and base.vertex_color_use_as_albedo)
			if base.albedo_texture != null:
				has_color_texture = true
			_record_texture(base.albedo_texture, "albedo", textures)
			_record_texture(base.normal_texture, "normal", textures)
			_record_texture(base.orm_texture, "orm", textures)
			_record_texture(base.metallic_texture, "metallic", textures)
			_record_texture(base.roughness_texture, "roughness", textures)
			_record_texture(base.emission_texture, "emission", textures)
		elif current is ShaderMaterial:
			var shader_material := current as ShaderMaterial
			for property in shader_material.get_property_list():
				var property_name := str(property.get("name", ""))
				if not property_name.begins_with("shader_parameter/"):
					continue
				var value: Variant = shader_material.get(property_name)
				if value is Texture2D:
					var slot := property_name.trim_prefix("shader_parameter/")
					if _is_color_texture_slot(slot):
						has_color_texture = true
					_record_texture(value as Texture2D, slot, textures)
				elif value is Color and _is_color_value_slot(property_name) and not _is_near_white(value as Color):
					has_nonwhite_color = true
			var shader := shader_material.shader
			uses_vertex_color = uses_vertex_color or (has_vertex_color and shader != null and shader.code.contains("COLOR"))
		current = current.next_pass

	var missing_texture_count := 0
	for texture_row in textures:
		if not bool(texture_row.loadable):
			missing_texture_count += 1
	return {
		"textures": textures,
		"missing_texture_count": missing_texture_count,
		"white_suspect": not has_color_texture and not has_nonwhite_color and not uses_vertex_color,
		"color_evidence": {
			"color_texture": has_color_texture,
			"nonwhite_color": has_nonwhite_color,
			"vertex_color_present": has_vertex_color,
			"vertex_color_used": uses_vertex_color,
		},
		"albedo": albedo_text,
	}


func _record_texture(texture: Texture2D, slot: String, out: Array[Dictionary]) -> void:
	if texture == null:
		return
	var path := texture.resource_path
	var loadable := texture.get_width() > 0 and texture.get_height() > 0
	if not path.is_empty():
		loadable = loadable and (ResourceLoader.exists(path) or FileAccess.file_exists(path))
	var import_info := _texture_import_info(path)
	out.append({
		"slot": slot,
		"path": path if not path.is_empty() else "<embedded>",
		"class": texture.get_class(),
		"width": texture.get_width(),
		"height": texture.get_height(),
		"loadable": loadable,
		"import": import_info,
	})


func _texture_import_info(texture_path: String) -> Dictionary:
	if texture_path.is_empty() or not texture_path.begins_with("res://"):
		return {}
	var import_path := texture_path + ".import"
	if not FileAccess.file_exists(import_path):
		return {}
	var config := ConfigFile.new()
	if config.load(import_path) != OK:
		return {"metadata_read_failed": true}
	return {
		"compress_mode": config.get_value("params", "compress/mode", -1),
		"compress_high_quality": config.get_value("params", "compress/high_quality", false),
		"mipmaps_generate": config.get_value("params", "mipmaps/generate", false),
		"process_fix_alpha_border": config.get_value("params", "process/fix_alpha_border", false),
	}


func _surface_has_vertex_color(mesh: Mesh, surface_index: int) -> bool:
	if mesh == null:
		return false
	var arrays := mesh.surface_get_arrays(surface_index)
	return arrays.size() > Mesh.ARRAY_COLOR and arrays[Mesh.ARRAY_COLOR] != null \
		and (arrays[Mesh.ARRAY_COLOR] as PackedColorArray).size() > 0


func _is_color_texture_slot(slot: String) -> bool:
	var lowered := slot.to_lower()
	for excluded in ["normal", "rough", "metal", "orm", "emission", "mask", "height", "depth", "ao"]:
		if lowered.contains(excluded):
			return false
	return lowered.contains("albedo") or lowered.contains("diffuse") or lowered.contains("base") \
		or lowered.contains("color") or lowered.contains("texture") or lowered.contains("tex")


func _is_color_value_slot(slot: String) -> bool:
	var lowered := slot.to_lower().trim_prefix("shader_parameter/")
	for excluded in ["emission", "outline", "rim", "shadow", "specular", "highlight", "glow", "mask"]:
		if lowered.contains(excluded):
			return false
	return lowered.contains("albedo") or lowered.contains("diffuse") or lowered.contains("base") \
		or lowered.contains("body") or lowered.contains("main") or lowered.contains("color") or lowered.contains("tint")


func _is_near_white(color: Color) -> bool:
	return color.a > 0.01 and color.r >= WHITE_FLOOR and color.g >= WHITE_FLOOR and color.b >= WHITE_FLOOR


func _load_whitelist() -> bool:
	if not FileAccess.file_exists(WHITELIST_PATH):
		_h.fail("whitelist_missing", "%s 不存在" % WHITELIST_PATH)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(WHITELIST_PATH))
	if not (parsed is Dictionary):
		_h.fail("whitelist_parse_failed", "%s 不是合法 JSON object" % WHITELIST_PATH)
		return false
	var entries: Variant = (parsed as Dictionary).get("entries", [])
	if not (entries is Array):
		_h.fail("whitelist_schema_invalid", "%s.entries 必须是数组" % WHITELIST_PATH)
		return false
	var valid := true
	var today := Time.get_date_string_from_system()
	for value in entries:
		if not (value is Dictionary):
			_h.fail("whitelist_schema_invalid", "白名单条目必须是 object")
			valid = false
			continue
		var entry := value as Dictionary
		entry = entry.duplicate(true)
		entry["_index"] = _whitelist_entries.size()
		_whitelist_entries.append(entry)
		for field in ["audit_key", "material_path", "reason", "screenshot_baseline", "owner", "expires"]:
			if not entry.has(field):
				_h.fail("whitelist_schema_invalid", "白名单条目缺少 %s：%s" % [field, JSON.stringify(entry)])
				valid = false
		var audit_key := str(entry.get("audit_key", ""))
		var material_path := str(entry.get("material_path", ""))
		var reason := str(entry.get("reason", "")).strip_edges()
		var screenshot_baseline := str(entry.get("screenshot_baseline", "")).strip_edges()
		var owner := str(entry.get("owner", "")).strip_edges()
		if audit_key.is_empty() and material_path.is_empty():
			_h.fail("whitelist_schema_invalid", "白名单条目必须精确指定 audit_key 或 material_path")
			valid = false
		if reason.is_empty() or screenshot_baseline.is_empty() or owner.is_empty():
			_h.fail("whitelist_schema_invalid", "白名单理由、截图基线和负责人不能为空：%s" % audit_key)
			valid = false
		elif not _evidence_path_exists(screenshot_baseline):
			_h.fail("whitelist_evidence_missing", "白名单截图基线不存在：%s" % screenshot_baseline)
			valid = false
		if _contains_glob(audit_key) or _contains_glob(material_path):
			_h.fail("whitelist_glob_forbidden", "白名单不允许通配符：%s / %s" % [audit_key, material_path])
			valid = false
		var expires := str(entry.get("expires", ""))
		if not _is_iso_date(expires) or expires < today:
			_h.fail("whitelist_expired", "白名单条目已过期或缺日期：%s expires=%s" % [audit_key, expires])
			valid = false
		if not audit_key.is_empty():
			if _whitelist_by_audit_key.has(audit_key):
				_h.fail("whitelist_duplicate", "audit_key 重复：%s" % audit_key)
				valid = false
			_whitelist_by_audit_key[audit_key] = entry
		if not material_path.is_empty():
			if _whitelist_by_material_path.has(material_path):
				_h.fail("whitelist_duplicate", "material_path 重复：%s" % material_path)
				valid = false
			_whitelist_by_material_path[material_path] = entry
	return valid


func _contains_glob(value: String) -> bool:
	return value.contains("*") or value.contains("?") or value.contains("[") or value.contains("]")


func _is_iso_date(value: String) -> bool:
	if value.length() != 10 or value[4] != "-" or value[7] != "-":
		return false
	for index in range(value.length()):
		if index == 4 or index == 7:
			continue
		if not value[index].is_valid_int():
			return false
	return true


func _evidence_path_exists(path: String) -> bool:
	if path.begins_with("res://"):
		return ResourceLoader.exists(path) or FileAccess.file_exists(path)
	return FileAccess.file_exists(path)


func _whitelist_for(audit_key: String, material_path: String) -> Dictionary:
	if _whitelist_by_audit_key.has(audit_key):
		var entry := _whitelist_by_audit_key[audit_key] as Dictionary
		_whitelist_hits[int(entry.get("_index", -1))] = true
		return entry
	if not material_path.is_empty() and _whitelist_by_material_path.has(material_path):
		var entry := _whitelist_by_material_path[material_path] as Dictionary
		_whitelist_hits[int(entry.get("_index", -1))] = true
		return entry
	return {}


func _check_stale_whitelist_entries() -> void:
	for index in range(_whitelist_entries.size()):
		if _whitelist_hits.has(index):
			continue
		var entry := _whitelist_entries[index]
		_h.fail("whitelist_stale", "白名单条目本次没有命中，应复核或删除：%s / %s" % [
			str(entry.get("audit_key", "")), str(entry.get("material_path", "")),
		])


func _write_report() -> void:
	var absolute_dir := ProjectSettings.globalize_path("res://reports")
	var mkdir_error := DirAccess.make_dir_recursive_absolute(absolute_dir)
	if mkdir_error != OK and mkdir_error != ERR_ALREADY_EXISTS:
		_h.fail("report_directory_failed", "无法创建报告目录：%s error=%d" % [absolute_dir, mkdir_error])
		return
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file == null:
		_h.fail("report_write_failed", "无法写入 %s" % REPORT_PATH)
		return
	var report := {
		"schema_version": 1,
		"generated_utc": Time.get_datetime_string_from_system(true),
		"godot_version": Engine.get_version_info(),
		"renderer_method": str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "mobile")),
		"whitelist_path": WHITELIST_PATH,
		"summary": _summary,
		"models": _rows,
	}
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
