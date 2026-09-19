extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const UnitVisualResolver := preload("res://effects/runtime/presentation/UnitVisualResolver.gd")
const SkillVFXConfig := preload("res://effects/SkillVFXConfig.gd")

const CHECK_NAME := "non_ui_visual_baseline"
const POLICY_PATH := "res://data/qa/non_ui_visual_freeze_policy.json"
const OUTPUT_ROOT := "res://review_visual_20260912"

var _h: CheckHarness
var _policy: Dictionary = {}


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_policy = _load_json(POLICY_PATH)
	if _policy.is_empty():
		_h.fail("policy_invalid", "%s 不存在或不是合法JSON object" % POLICY_PATH)
		_h.finish(get_tree())
		return
	_h.expect(int(_policy.get("schema_version", 0)) == 1, "policy_schema", "视觉冻结策略版本必须为1")
	var mkdir_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_ROOT))
	_h.expect(mkdir_error in [OK, ERR_ALREADY_EXISTS], "output_directory", "无法创建 %s" % OUTPUT_ROOT)

	var frozen := _build_frozen_manifest()
	var routes := _build_model_routes()
	var inventory := _build_visual_inventory()
	var vfx_routes := _build_vfx_routes()
	_write_json(OUTPUT_ROOT.path_join("ui_freeze_manifest.json"), frozen)
	_write_json(OUTPUT_ROOT.path_join("model_routes.json"), routes)
	_write_json(OUTPUT_ROOT.path_join("visual_inventory.json"), inventory)
	_write_json(OUTPUT_ROOT.path_join("vfx_runtime_manifest.json"), vfx_routes)
	var summary := {
		"schema_version": 1,
		"generated_utc": Time.get_datetime_string_from_system(true),
		"baseline_id": str(_policy.get("baseline_id", "")),
		"godot_version": Engine.get_version_info(),
		"renderer_method": str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")),
		"policy_path": POLICY_PATH,
		"asset_manifest_sha256": FileAccess.get_sha256("res://assets.manifest.json"),
		"asset_bundle_sha256": FileAccess.get_sha256("res://assets.bundle.json"),
		"frozen_files": int(frozen.get("file_count", 0)),
		"frozen_bytes": int(frozen.get("total_bytes", 0)),
		"model_entries": int(routes.get("entry_count", 0)),
		"model_paths": int(routes.get("model_path_count", 0)),
		"model_paths_missing": int(routes.get("missing_count", 0)),
		"visual_files": int(inventory.get("file_count", 0)),
		"visual_bytes": int(inventory.get("total_bytes", 0)),
		"vfx_owner_entries": int(vfx_routes.get("owner_entry_count", 0)),
		"vfx_skill_ids": int(vfx_routes.get("skill_id_count", 0)),
		"vfx_fallback_review_required": int(vfx_routes.get("fallback_review_required", 0)),
		"pilot_ids": _policy.get("pilot_ids", []),
		"protected_gameplay": _policy.get("protected_gameplay", []),
	}
	_write_json(OUTPUT_ROOT.path_join("baseline_summary.json"), summary)
	print("NON_UI_VISUAL_BASELINE frozen=%d models=%d model_paths=%d missing=%d visual_files=%d output=%s" % [
		int(summary.frozen_files), int(summary.model_entries), int(summary.model_paths),
		int(summary.model_paths_missing), int(summary.visual_files), OUTPUT_ROOT,
	])
	_h.finish(get_tree())


func _build_frozen_manifest() -> Dictionary:
	var paths: Array[String] = []
	for root_value in _policy.get("frozen_roots", []):
		var root := str(root_value)
		_h.expect(DirAccess.dir_exists_absolute(root), "frozen_root_missing", "冻结目录不存在：%s" % root)
		_collect_files(root, paths)
	for path_value in _policy.get("frozen_exact", []):
		var path := str(path_value)
		_h.expect(FileAccess.file_exists(path), "frozen_file_missing", "冻结文件不存在：%s" % path)
		if FileAccess.file_exists(path) and not paths.has(path):
			paths.append(path)
	paths.sort()
	var rows: Array[Dictionary] = []
	var total_bytes := 0
	for path in paths:
		var size := _file_size(path)
		total_bytes += size
		rows.append({"path": path, "size": size, "sha256": FileAccess.get_sha256(path)})
		_h.item()
	_h.expect(not rows.is_empty(), "frozen_manifest_empty", "UI冻结清单为空")
	return {
		"schema_version": 1,
		"generated_utc": Time.get_datetime_string_from_system(true),
		"policy_path": POLICY_PATH,
		"file_count": rows.size(),
		"total_bytes": total_bytes,
		"files": rows,
	}


func _build_model_routes() -> Dictionary:
	var rows: Array[Dictionary] = []
	var unique_paths: Dictionary = {}
	var missing: Array[Dictionary] = []
	for definition_value in UnitVisualResolver.all_combat_entries():
		var definition := definition_value as Dictionary
		var paths := UnitVisualResolver.all_model_paths(definition)
		var route_paths: Array[Dictionary] = []
		for path in paths:
			var exists := UnitVisualResolver.resource_exists(path)
			route_paths.append({"path": path, "exists": exists})
			unique_paths[path] = true
			if not exists:
				missing.append({"id": str(definition.get("id", "")), "path": path})
		rows.append({
			"id": str(definition.get("id", "")),
			"kind": str(definition.get("visual_kind", "")),
			"element": str(definition.get("element", definition.get("series", ""))),
			"model_visual_scale": float(definition.get("model_visual_scale", 1.0)),
			"model_base_yaw": float(definition.get("model_base_yaw", 0.0)),
			"run_animation": str(definition.get("model_run_animation_name", "")),
			"paths": route_paths,
		})
		_h.item()
	# There are 74 definitions and 75 concrete paths: twin_gate selects a
	# different model by element. Keep both counts explicit so a lost variant
	# cannot hide behind the definition count.
	_h.expect(rows.size() == 74, "model_definition_count", "枚举到%d个战斗模型定义，预期74" % rows.size())
	_h.expect(unique_paths.size() == 75, "model_path_count", "枚举到%d条模型路径，预期75" % unique_paths.size())
	_h.expect(missing.is_empty(), "model_routes_missing", "%d条模型路径无法加载" % missing.size())
	return {
		"schema_version": 1,
		"generated_utc": Time.get_datetime_string_from_system(true),
		"entry_count": rows.size(),
		"model_path_count": unique_paths.size(),
		"missing_count": missing.size(),
		"missing": missing,
		"entries": rows,
	}


func _build_visual_inventory() -> Dictionary:
	var paths: Array[String] = []
	for root_value in _policy.get("visual_inventory_roots", []):
		var root := str(root_value)
		if DirAccess.dir_exists_absolute(root):
			_collect_files(root, paths)
		else:
			_h.fail("visual_root_missing", "视觉库存目录不存在：%s" % root)
	paths.sort()
	var rows: Array[Dictionary] = []
	var by_extension: Dictionary = {}
	var total_bytes := 0
	for path in paths:
		var size := _file_size(path)
		var ext := path.get_extension().to_lower()
		total_bytes += size
		by_extension[ext] = int(by_extension.get(ext, 0)) + 1
		rows.append({"path": path, "size": size, "sha256": FileAccess.get_sha256(path)})
		_h.item()
	return {
		"schema_version": 1,
		"generated_utc": Time.get_datetime_string_from_system(true),
		"roots": _policy.get("visual_inventory_roots", []),
		"file_count": rows.size(),
		"total_bytes": total_bytes,
		"by_extension": by_extension,
		"files": rows,
	}


func _build_vfx_routes() -> Dictionary:
	var composer_ids := _composer_skill_ids()
	var skill_ids: Dictionary = {}
	var rows: Array[Dictionary] = []
	var missing_textures: Array[Dictionary] = []
	var fallback_count := 0
	for definition_value in UnitVisualResolver.all_combat_entries():
		var definition := definition_value as Dictionary
		var owner_id := str(definition.get("id", ""))
		var skill_id := str(definition.get("skill_id", ""))
		if not skill_id.is_empty():
			skill_ids[skill_id] = true
		var textures: Array[Dictionary] = []
		for config_value in SkillVFXConfig.get_textures(owner_id):
			var config := config_value as Dictionary
			var path := str(config.get("path", ""))
			var exists := ResourceLoader.exists(path) or FileAccess.file_exists(path)
			textures.append({
				"path": path,
				"exists": exists,
				"role": str(config.get("role", "")),
				"delay": float(config.get("delay", 0.0)),
				"scale": float(config.get("scale", 1.0)),
				"duration": float(config.get("duration", 0.0)),
				"alpha": float(config.get("alpha", 1.0)),
				"particles": int(config.get("particles", 0)),
			})
			if not exists:
				missing_textures.append({"owner_id": owner_id, "path": path})
		var no_active_skill := skill_id.is_empty() or skill_id == "none"
		var procedural := composer_ids.has(skill_id)
		var route_status := "N_A_NO_ACTIVE_SKILL" if no_active_skill else (
			"TEXTURE_AND_PROCEDURAL" if procedural and not textures.is_empty() else (
				"PROCEDURAL" if procedural else ("OWNER_TEXTURES" if not textures.is_empty() else "FALLBACK_REVIEW_REQUIRED")))
		if route_status == "FALLBACK_REVIEW_REQUIRED":
			fallback_count += 1
		rows.append({
			"owner_id": owner_id,
			"kind": str(definition.get("visual_kind", "")),
			"skill_id": skill_id,
			"route_status": route_status,
			"composer_supported": procedural,
			"owner_textures": textures,
			"formal_consumers": [
				"res://scenes/battle/BattleVfx.gd",
				"res://effects/vfx3d/units/UnitSkillVFXComposer3D.gd",
			],
		})
		_h.item()
	for basic_id in [
		"basic_attack_ranged_god", "basic_attack_melee_god",
		"basic_attack_ranged_human", "basic_attack_melee_human",
		"basic_attack_ranged_dark", "basic_attack_melee_dark",
		"basic_attack_ranged_undead", "basic_attack_melee_undead",
	]:
		skill_ids[basic_id] = true
	_h.expect(not composer_ids.is_empty(), "composer_routes_empty", "Composer没有解析到任何skill_id")
	_h.expect(missing_textures.is_empty(), "vfx_texture_missing", "%d张正式VFX纹理无法加载" % missing_textures.size())
	return {
		"schema_version": 1,
		"generated_utc": Time.get_datetime_string_from_system(true),
		"owner_entry_count": rows.size(),
		"skill_id_count": skill_ids.size(),
		"composer_skill_id_count": composer_ids.size(),
		"fallback_review_required": fallback_count,
		"missing_texture_count": missing_textures.size(),
		"missing_textures": missing_textures,
		"entries": rows,
	}


func _composer_skill_ids() -> Dictionary:
	var out: Dictionary = {}
	var path := "res://effects/vfx3d/units/UnitSkillVFXComposer3D.gd"
	var text := FileAccess.get_file_as_string(path)
	var in_match := false
	var regex := RegEx.create_from_string("^[\\t ]{2}\\\"([^\\\"]+)\\\":")
	for line in text.split("\n"):
		if line.strip_edges() == "match skill_id:":
			in_match = true
			continue
		if not in_match:
			continue
		if line.begins_with("\t\t_:"):
			break
		var result := regex.search(line)
		if result != null:
			out[result.get_string(1)] = true
	return out


func _collect_files(root: String, out: Array[String]) -> void:
	var dir := DirAccess.open(root)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var path := root.path_join(entry)
			if dir.current_is_dir():
				_collect_files(path, out)
			elif not out.has(path):
				out.append(path)
		entry = dir.get_next()
	dir.list_dir_end()


func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_h.fail("file_read_failed", "无法读取：%s" % path)
		return 0
	var size := file.get_length()
	file.close()
	return size


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}


func _write_json(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_h.fail("report_write_failed", "无法写入：%s" % path)
		return
	file.store_string(JSON.stringify(value, "\t"))
	file.close()
