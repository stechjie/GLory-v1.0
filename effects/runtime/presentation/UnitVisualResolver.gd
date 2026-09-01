class_name UnitVisualResolver
extends RefCounted

# Pure presentation lookup for every fighter that can enter BattleRenderer.
# Gameplay statistics stay on the replay/cell definition; this resolver only
# refreshes visual fields and supplies the existing portrait fallback asset.

const UNIT_PORTRAIT_DIR := "res://assets/ui/unit_portraits/"
const MERC_PORTRAIT_DIR := "res://assets/ui/mercenary_portraits/"
const CODEX_PORTRAIT_DIR := "res://assets/ui/codex_portraits/"
const FRAME_COMMON := "res://assets/ui/shop/card_frame_common.png"
const FRAME_RARE := "res://assets/ui/shop/card_frame_rare.png"
const FRAME_EPIC := "res://assets/ui/shop/card_frame_epic.png"

const COMBAT_TABLES := [
	{"kind": "unit", "table": "race_units", "key": "units"},
	{"kind": "merc", "table": "mercenaries", "key": "mercenaries"},
	{"kind": "monster", "table": "pve_monsters", "key": "monsters"},
	{"kind": "boss", "table": "bosses", "key": "bosses"},
	{"kind": "ally", "table": "formation_allies", "key": "allies"},
]

const VISUAL_FIELDS := [
	"model",
	"model_visual_scale",
	"model_base_yaw",
	"model_frame_fill",
	"model_idle_animation",
	"model_idle_animation_name",
	"model_attack_animation_name",
	"model_attack_sync_seek",
	"model_attack_lock_time",
	"model_run_animation_name",
	"model_by_element",
	"tier",
]

static var _combat_index: Dictionary = {}
static var _warned_failures: Dictionary = {}
static var _failure_rows: Array[Dictionary] = []


static func resolve_for_fighter(fighter: Dictionary) -> Dictionary:
	var raw_value = fighter.get("def", {})
	var raw_def: Dictionary = raw_value if typeof(raw_value) == TYPE_DICTIONARY else {}
	var unit_id := str(fighter.get("id", raw_def.get("id", "")))
	return resolve_definition(unit_id, raw_def)


static func resolve_for_cell(cell: Dictionary) -> Dictionary:
	var raw_value = cell.get("def", {})
	var raw_def: Dictionary = raw_value if typeof(raw_value) == TYPE_DICTIONARY else {}
	var unit_id := str(cell.get("id", raw_def.get("id", "")))
	return resolve_definition(unit_id, raw_def)


static func resolve_definition(unit_id: String, raw_def: Dictionary = {}) -> Dictionary:
	_ensure_index()
	var out := raw_def.duplicate(true)
	var indexed_value = _combat_index.get(unit_id, {})
	var indexed: Dictionary = indexed_value if typeof(indexed_value) == TYPE_DICTIONARY else {}
	var canonical_value = indexed.get("definition", {})
	var canonical: Dictionary = canonical_value if typeof(canonical_value) == TYPE_DICTIONARY else {}
	if not canonical.is_empty():
		for field in VISUAL_FIELDS:
			if canonical.has(field):
				out[field] = canonical[field]
		# `range` 只在缺失时补：它既是战斗字段也是 archetype_for() 的依据，
		# fighter 自带的值优先，registry 只兜底。
		for field in ["id", "name", "name_en", "race", "range"]:
			if not out.has(field) and canonical.has(field):
				out[field] = canonical[field]
	if not unit_id.is_empty():
		out["id"] = unit_id
	var element := str(raw_def.get("element", out.get("element", canonical.get("element", ""))))
	if not element.is_empty():
		out["element"] = element
	out["model"] = effective_model_path(out, element)
	var visual_kind := str(indexed.get("kind", infer_kind(unit_id, out)))
	out["portrait"] = str(indexed.get("portrait", portrait_path_for_definition(out, visual_kind)))
	out["visual_kind"] = visual_kind
	var fallback_tier := int(out.get("tier", canonical.get("tier", 1)))
	if visual_kind == "boss":
		fallback_tier = maxi(fallback_tier, 3)
	elif visual_kind in ["monster", "ally"]:
		fallback_tier = maxi(fallback_tier, 2)
	out["fallback_frame"] = fallback_frame_for_tier(fallback_tier)
	return out


static func effective_model_path(definition: Dictionary, element_override: String = "") -> String:
	var variants_value = definition.get("model_by_element", {})
	if typeof(variants_value) == TYPE_DICTIONARY:
		var variants: Dictionary = variants_value
		var element := element_override
		if element.is_empty():
			element = str(definition.get("element", ""))
		var variant_path := str(variants.get(element, ""))
		if variant_path.begins_with("res://"):
			return variant_path
	return str(definition.get("model", ""))


static func all_model_paths(definition: Dictionary) -> Array[String]:
	var out: Array[String] = []
	_append_unique_path(out, str(definition.get("model", "")))
	var variants_value = definition.get("model_by_element", {})
	if typeof(variants_value) == TYPE_DICTIONARY:
		for value in (variants_value as Dictionary).values():
			_append_unique_path(out, str(value))
	return out


static func all_combat_entries() -> Array[Dictionary]:
	_ensure_index()
	var out: Array[Dictionary] = []
	var ids: Array = _combat_index.keys()
	ids.sort()
	for unit_id in ids:
		var indexed: Dictionary = _combat_index[unit_id]
		var definition: Dictionary = indexed.get("definition", {})
		out.append(resolve_definition(str(unit_id), definition))
	return out


static func portrait_path_for_definition(definition: Dictionary, kind: String = "") -> String:
	var unit_id := str(definition.get("id", ""))
	var resolved_kind := kind if not kind.is_empty() else infer_kind(unit_id, definition)
	match resolved_kind:
		"unit":
			return UNIT_PORTRAIT_DIR + unit_id + ".png"
		"merc":
			return MERC_PORTRAIT_DIR + unit_id + ".png"
		"monster", "boss", "ally":
			return CODEX_PORTRAIT_DIR + str(definition.get("name", "")) + ".png"
	return ""


static func fallback_frame_for_tier(tier: int) -> String:
	if tier >= 3:
		return FRAME_EPIC
	if tier == 2:
		return FRAME_RARE
	return FRAME_COMMON


# V2 P1-04 第 4 条：近战、远程、Boss 分别配置 scale/anchor，不允许所有角色共用
# 同一个高度常量。这里给出分类，锚点比例由 UnitActor3D 按分类取。
#
# 用 registry 里已有的 `range` 字段分近战/远程（实测 32 个单位：range 1 有 19 个、
# range 4 有 11 个、另有 1.5 和 2 各一个），不新造字段。Boss 单独一档，因为它的
# model_visual_scale 是 2.0，和其余单位不在一个量级。
const RANGED_MIN_RANGE := 2.0

static func archetype_for(definition: Dictionary) -> String:
	var unit_id := str(definition.get("id", ""))
	var kind := str(definition.get("visual_kind", infer_kind(unit_id, definition)))
	if kind == "boss":
		return "boss"
	if float(definition.get("range", 1.0)) >= RANGED_MIN_RANGE:
		return "ranged"
	return "melee"


static func infer_kind(unit_id: String, definition: Dictionary = {}) -> String:
	if unit_id.begins_with("merc_") or bool(definition.get("is_mercenary", false)):
		return "merc"
	if unit_id.begins_with("pve_"):
		return "monster"
	if unit_id.begins_with("boss_") or bool(definition.get("is_boss", false)):
		return "boss"
	if unit_id.begins_with("ally_") or bool(definition.get("is_formation_ally", false)):
		return "ally"
	return "unit"


static func resource_exists(path: String) -> bool:
	if path.is_empty():
		return false
	return ResourceLoader.exists(path) or FileAccess.file_exists(path)


static func report_failure(unit_id: String, resource_path: String, consumer: String, reason: String) -> void:
	var key := "%s|%s|%s|%s" % [unit_id, resource_path, consumer, reason]
	if _warned_failures.has(key):
		return
	_warned_failures[key] = true
	_failure_rows.append({
		"unit_id": unit_id,
		"resource_path": resource_path,
		"consumer": consumer,
		"reason": reason,
	})
	if OS.is_debug_build():
		push_warning("[UNIT_VISUAL] %s (%s) %s -> portrait fallback: %s" % [unit_id, consumer, reason, resource_path])


static func failure_rows() -> Array[Dictionary]:
	return _failure_rows.duplicate(true)


static func reset_failure_report() -> void:
	_warned_failures.clear()
	_failure_rows.clear()


static func _ensure_index() -> void:
	if not _combat_index.is_empty():
		return
	for spec in COMBAT_TABLES:
		var table: Dictionary = DataRegistry.get_table(str(spec.table))
		for value in table.get(str(spec.key), []):
			if typeof(value) != TYPE_DICTIONARY:
				continue
			var definition := value as Dictionary
			var unit_id := str(definition.get("id", ""))
			if unit_id.is_empty():
				continue
			_combat_index[unit_id] = {
				"kind": str(spec.kind),
				"definition": definition,
				"portrait": portrait_path_for_definition(definition, str(spec.kind)),
			}


static func _append_unique_path(out: Array[String], path: String) -> void:
	if not path.is_empty() and not out.has(path):
		out.append(path)
