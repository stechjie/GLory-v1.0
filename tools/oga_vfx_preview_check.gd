extends SceneTree

const CATALOG := preload("res://effects/vfx3d/units/OgaChessVFXCatalog.gd")

func _initialize() -> void:
	var failures := PackedStringArray()
	var projectile_paths := {}
	var impact_paths := {}
	if CATALOG.PLAYER_CHESS_UNITS.size() != 32:
		failures.append("expected_32_player_chess_units")
	if CATALOG.RANGED_UNIT_ORDER.size() != 12:
		failures.append("expected_12_ranged_units")
	for unit_id in CATALOG.RANGED_UNIT_ORDER:
		var spec: Dictionary = CATALOG.projectile_for(unit_id)
		if spec.is_empty():
			failures.append("missing_spec:%s" % unit_id)
			continue
		_check_unique_path(unit_id, str(spec.get("path", "")), projectile_paths, failures, "projectile")
		_check_unique_path(unit_id, str(spec.get("impact_path", "")), impact_paths, failures, "impact")
		for required_key in ["columns", "rows", "frame_count", "fps", "size", "speed", "impact_columns", "impact_rows", "impact_frames", "impact_fps", "impact_size"]:
			if not spec.has(required_key):
				failures.append("missing_key:%s:%s" % [unit_id, required_key])
	var melee_count := 0
	for unit_id in CATALOG.PLAYER_CHESS_UNITS:
		if unit_id in CATALOG.RANGED_UNIT_ORDER:
			continue
		var race := unit_id.get_slice("_", 0)
		var melee_spec: Dictionary = CATALOG.melee_for(unit_id, race)
		if melee_spec.is_empty():
			failures.append("missing_melee_spec:%s" % unit_id)
			continue
		melee_count += 1
		for path_key in ["path", "impact_path"]:
			var resource_path := str(melee_spec.get(path_key, ""))
			if resource_path.is_empty() or not ResourceLoader.exists(resource_path):
				failures.append("missing_melee_resource:%s:%s" % [unit_id, resource_path])
	for skill_id in ["random_ally_damage_reduction", "black_hole", "judgement_strike"]:
		var skill_spec: Dictionary = CATALOG.formal_skill_for(skill_id)
		var resource_path := str(skill_spec.get("path", ""))
		if resource_path.is_empty() or not ResourceLoader.exists(resource_path):
			failures.append("missing_formal_skill:%s:%s" % [skill_id, resource_path])
	var manifest_path := "res://assets/vfx/oga/atlas_manifest.json"
	if not FileAccess.file_exists(manifest_path):
		failures.append("missing_atlas_manifest")
	else:
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
		if typeof(parsed) != TYPE_DICTIONARY:
			failures.append("invalid_atlas_manifest")
		elif not bool((parsed as Dictionary).get("formal_battle_integration", false)):
			failures.append("formal_integration_must_be_true")
	if failures.is_empty():
		print("[oga_vfx_preview_check] PASS ranged=12 projectile_paths=12 impact_paths=12 melee=%d skills=3 formal_integration=true" % melee_count)
		quit(0)
	else:
		for failure in failures:
			push_error("[oga_vfx_preview_check] %s" % failure)
		quit(1)

func _check_unique_path(unit_id: String, path: String, seen: Dictionary, failures: PackedStringArray, kind: String) -> void:
	if path.is_empty() or not ResourceLoader.exists(path):
		failures.append("missing_%s:%s:%s" % [kind, unit_id, path])
	elif seen.has(path):
		failures.append("duplicate_%s:%s:%s" % [kind, seen[path], unit_id])
	else:
		seen[path] = unit_id
