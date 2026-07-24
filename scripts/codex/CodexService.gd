class_name CodexService
extends RefCounted
# Normalises the eight data tables into one entry shape so the codex UI only ever
# deals with a single structure. Nothing here reads from PrepScreen or mutates
# game state; it is a pure read layer over DataRegistry plus PlayerProfile.

const TEXT_PATH := "res://data/codex/treasure_text.json"
const PORTRAIT_DIR := "res://assets/ui/codex_portraits/"
const UNIT_PORTRAIT_DIR := "res://assets/ui/unit_portraits/"
const MERC_PORTRAIT_DIR := "res://assets/ui/mercenary_portraits/"
const TREASURE_ICON_DIR := "res://assets/ui/treasure_logos/"
const RACE_LOGO_DIR := "res://assets/ui/race_logos/"
const STATUS_ICON_DIR := "res://assets/vfx/status/"

# Tab order as shown to the player. Pieces are split by race, matching the four
# race logos the game already ships.
const CATEGORIES := [
	{"key": "god", "kind": "unit", "race": "god"},
	{"key": "human", "kind": "unit", "race": "human"},
	{"key": "dark", "kind": "unit", "race": "dark"},
	{"key": "undead", "kind": "unit", "race": "undead"},
	{"key": "merc", "kind": "merc"},
	{"key": "treasure", "kind": "treasure"},
	{"key": "link", "kind": "link"},
	{"key": "monster", "kind": "monster"},
	{"key": "boss", "kind": "boss"},
	{"key": "ally", "kind": "ally"},
	{"key": "pet", "kind": "pet"},
	{"key": "status", "kind": "status"},
]

# Status effects are reference material rather than a collection goal, so they are
# always readable. Icons are the same textures the battle HUD uses.
const STATUSES := [
	{"id": "shield", "buff": true, "icon": "status_shield_aura.png"},
	{"id": "stun", "buff": false, "icon": "status_stun_icon_v2.png"},
	{"id": "silence", "buff": false, "icon": "status_silence_icon_v2.png"},
	{"id": "poison", "buff": false, "icon": "status_poison_icon_v2.png"},
	{"id": "bleed", "buff": false, "icon": "status_bleed_icon_v2.png"},
	{"id": "burn", "buff": false, "icon": "status_burn_icon_v2.png"},
	{"id": "slow", "buff": false, "icon": "status_slow_icon_v2.png"},
	{"id": "attack_down", "buff": false, "icon": "status_attack_down_icon_v2.png"},
	{"id": "defense_down", "buff": false, "icon": "status_defense_down_icon_v2.png"},
	{"id": "interrupt", "buff": false, "icon": "status_interrupt_icon_v2.png"},
	{"id": "heal_reduction", "buff": false, "icon": "status_heal_reduction_icon_v2.png"},
	{"id": "fear", "buff": false, "icon": "status_fear_icon_v2.png"},
	{"id": "ice_affected", "buff": false, "icon": "status_ice_affected_icon_v2.png"},
	{"id": "ice_vulnerable", "buff": false, "icon": "status_ice_vulnerable_icon_v2.png"},
]

# Linkage display names live only as icon filenames; the data table has ids alone.
const LINK_ART_NAME := {
	"link_phoenix": "凤凰涅槃",
	"link_money_magic": "金钱魔法",
	"link_blood_covenant": "血之契约",
	"link_paralysis_shackles": "瘫痪枷锁",
	"link_oppression_counter": "压迫反击",
	"link_fraud_fate": "诡诈命运",
	"link_iron_maiden": "铁处女",
	"link_toxic_burst": "剧毒爆发",
	"link_rich_path": "富裕之路",
	"link_clearance_sale": "清仓特卖",
	"link_hu_pai_master": "胡牌手",
}

# Pet art was delivered under nicknames that do not match the data table ids.
const PET_ART_NAME := {
	"pet_mushroom": "小菇",
	"pet_cat": "小喵",
	"pet_rabbit": "小兔",
}

static var _text_cache: Dictionary = {}

static func _text_table() -> Dictionary:
	if not _text_cache.is_empty():
		return _text_cache
	if not FileAccess.file_exists(TEXT_PATH):
		push_warning("Codex text table missing: %s" % TEXT_PATH)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(TEXT_PATH))
	if typeof(parsed) == TYPE_DICTIONARY:
		_text_cache = parsed
	return _text_cache

# --- entries -------------------------------------------------------------

static func entries_for(category_key: String) -> Array[Dictionary]:
	var meta := _category(category_key)
	match str(meta.get("kind", "")):
		"unit": return _units(str(meta.get("race", "")))
		"merc": return _mercs()
		"treasure": return _treasures()
		"link": return _linkages()
		"monster": return _monsters()
		"boss": return _bosses()
		"ally": return _allies()
		"pet": return _pets()
		"status": return _statuses()
	return []

static func _category(key: String) -> Dictionary:
	for c in CATEGORIES:
		if str(c.get("key", "")) == key:
			return c
	return {}

static func _units(race: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw in DataRegistry.get_table("race_units").get("units", []):
		var d := raw as Dictionary
		if d == null or str(d.get("race", "")) != race:
			continue
		out.append({
			"id": str(d.get("id", "")),
			"name": str(d.get("name", "")),
			"name_en": str(d.get("name_en", "")),
			"portrait": UNIT_PORTRAIT_DIR + str(d.get("id", "")) + ".png",
			"race": race,
			"element": str(d.get("element", "")),
			"tier": int(d.get("tier", 0)),
			"cost": int(d.get("cost", 0)),
			"stats": _stats(d),
			"skill_id": str(d.get("skill_id", "")),
			"collectible": true,
		})
	return out

static func _mercs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw in DataRegistry.get_table("mercenaries").get("mercenaries", []):
		var d := raw as Dictionary
		if d == null:
			continue
		out.append({
			"id": str(d.get("id", "")),
			"name": str(d.get("name", "")),
			"name_en": str(d.get("name_en", "")),
			"portrait": MERC_PORTRAIT_DIR + str(d.get("id", "")) + ".png",
			"cost": int(d.get("cost", 0)),
			"stats": _stats(d),
			"skill_id": str(d.get("skill_id", "")),
			"collectible": true,
		})
	return out

static func _monsters() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw in DataRegistry.get_table("pve_monsters").get("monsters", []):
		var d := raw as Dictionary
		if d == null:
			continue
		out.append({
			"id": str(d.get("id", "")),
			"name": str(d.get("name", "")),
			"name_en": str(d.get("name_en", "")),
			"portrait": PORTRAIT_DIR + str(d.get("name", "")) + ".png",
			"series": str(d.get("series", "")),
			"stats": _stats(d),
			"skill_id": str(d.get("skill_id", "")),
			"collectible": true,
		})
	return out

# Bosses show their skill but never their numbers — the codex prints an infinity
# glyph instead, so players are left to judge them by reputation.
static func _bosses() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw in DataRegistry.get_table("bosses").get("bosses", []):
		var d := raw as Dictionary
		if d == null:
			continue
		out.append({
			"id": str(d.get("id", "")),
			"name": str(d.get("name", "")),
			"name_en": str(d.get("name_en", "")),
			"portrait": PORTRAIT_DIR + str(d.get("name", "")) + ".png",
			"element": str(d.get("element", "")),
			"skill_id": str(d.get("skill_id", "")),
			"hide_stats": true,
			"collectible": true,
		})
	return out

static func _allies() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw in DataRegistry.get_table("formation_allies").get("allies", []):
		var d := raw as Dictionary
		if d == null:
			continue
		out.append({
			"id": str(d.get("id", "")),
			"name": str(d.get("name", "")),
			"name_en": str(d.get("name_en", "")),
			"portrait": PORTRAIT_DIR + str(d.get("name", "")) + ".png",
			"stats": _stats(d),
			"skill_id": str(d.get("skill_id", "")),
			"collectible": true,
		})
	return out

static func _treasures() -> Array[Dictionary]:
	var text: Dictionary = _text_table().get("treasures", {})
	var out: Array[Dictionary] = []
	for raw in DataRegistry.get_table("treasures").get("treasures", []):
		var d := raw as Dictionary
		if d == null:
			continue
		var id := str(d.get("id", ""))
		var entry: Dictionary = text.get(id, {})
		out.append({
			"id": id,
			"name": str(d.get("name", "")),
			"name_en": str(d.get("name_en", "")),
			"portrait": TREASURE_ICON_DIR + str(d.get("name", "")) + ".png",
			"icon_art": true,
			"category": str(d.get("category", "")),
			"effect": str(entry.get("effect", "")),
			"trigger": str(entry.get("trigger", "")),
			"collectible": true,
		})
	return out

static func _linkages() -> Array[Dictionary]:
	var text: Dictionary = _text_table().get("linkages", {})
	var out: Array[Dictionary] = []
	for raw in DataRegistry.get_table("treasures").get("linkages", []):
		var d := raw as Dictionary
		if d == null:
			continue
		var id := str(d.get("id", ""))
		var entry: Dictionary = text.get(id, {})
		var art := str(LINK_ART_NAME.get(id, ""))
		out.append({
			"id": id,
			"name": str(entry.get("name", art)),
			"portrait": TREASURE_ICON_DIR + art + ".png",
			"icon_art": true,
			"effect": str(entry.get("effect", "")),
			"requires_text": str(entry.get("requires_text", "")),
			"collectible": true,
		})
	return out

static func _pets() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw in DataRegistry.get_table("pets").get("pets", []):
		var d := raw as Dictionary
		if d == null:
			continue
		var id := str(d.get("id", ""))
		out.append({
			"id": id,
			"name": str(d.get("name", "")),
			"name_en": str(d.get("name_en", "")),
			"portrait": PORTRAIT_DIR + str(PET_ART_NAME.get(id, "")) + ".png",
			"effect_key": str(d.get("effect", "")),
			"effect_value": float(d.get("value", 0.0)),
			"collectible": true,
		})
	return out

static func _statuses() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for def in STATUSES:
		var id := str(def.get("id", ""))
		# Localisation keys rather than translated strings: tr() is not callable
		# from a static context, and the UI re-translates on locale change anyway.
		out.append({
			"id": id,
			"name_key": "codex_status_%s" % id,
			"portrait": STATUS_ICON_DIR + str(def.get("icon", "")),
			"icon_art": true,
			"buff": bool(def.get("buff", false)),
			"desc_key": "codex_status_%s_desc" % id,
			# Reference material: always readable, never counted as collection.
			"collectible": false,
		})
	return out

static func _stats(d: Dictionary) -> Dictionary:
	return {
		"hp": int(d.get("hp", 0)),
		"atk": int(d.get("atk", 0)),
		"def": int(d.get("def", 0)),
		"attack_speed": float(d.get("attack_speed", 0.0)),
		"range": int(d.get("range", 0)),
		"move_speed": float(d.get("move_speed", 0.0)),
	}

# --- unlock state --------------------------------------------------------

static func is_unlocked(entry: Dictionary) -> bool:
	if not bool(entry.get("collectible", true)):
		return true
	return PlayerProfile.has_seen(str(entry.get("id", "")))

static func progress_for(category_key: String) -> Vector2i:
	var list := entries_for(category_key)
	var unlocked := 0
	for e in list:
		if is_unlocked(e):
			unlocked += 1
	return Vector2i(unlocked, list.size())

# Pets are never rendered on the battlefield, so they unlock from ownership
# instead of from an encounter. Cheap enough to reconcile on every codex open.
static func sync_owned_pets() -> void:
	PlayerProfile.mark_seen_many(PlayerProfile.owned_pets)
