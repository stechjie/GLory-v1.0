extends Node

# Regression coverage for renamed unit display fields crossing three boundaries:
# dedicated-server shop payload -> purchased def copy -> persisted slot migration.
# Gameplay fields are deliberately seeded and compared so a display-name repair
# can never silently replace skill/star4/uid state.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BattleRendererScript := preload("res://scenes/battle/BattleRenderer.gd")

const CHECK_NAME := "unit_name_consistency"
const RENAMED_EN := {
	"god_priest": ["Divine Servant", "Godhand"],
	"god_priestess": ["High Priestess", "Priestess"],
	"god_guard": ["Light Guardian", "Lightguard"],
	"god_aurora": ["Aurora Archer", "Aurora"],
	"dark_mage": ["Shadow Mage", "Hexmage"],
	"dark_dragon": ["Black Dragon", "Blackwyrm"],
	"undead_poison": ["Poison Wisp", "Venom"],
	"undead_parasite": ["Parasite Wisp", "Leech Wisp"],
	"undead_mother": ["Mother Wisp", "Matron"],
	"human_death_servant": ["Death Servant", "Deathbound"],
}

var _h: CheckHarness
var _prep: Node
var _saved_team_active := false
var _saved_is_host := false
var _saved_server_shop: Dictionary = {}
var _saved_locale := ""


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	DataRegistry.load_all()
	GameState.reset_run()
	_saved_team_active = NetworkService.team_active
	_saved_is_host = NetworkService.is_host
	_saved_server_shop = NetworkService.server_shop.duplicate(true)
	_saved_locale = LocaleManager.get_locale()
	LocaleManager.set_locale("en")

	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "PrepScreen.tscn cannot load"):
		_finish()
		return
	_prep = packed.instantiate()
	add_child(_prep)
	await get_tree().process_frame
	await get_tree().process_frame
	# PrepScreen applies the saved profile locale during its own initialization.
	# Set English after those frames so every display-name assertion is deterministic.
	LocaleManager.set_locale("en")

	_case_all_renames_have_one_local_truth()
	_case_old_server_offer_is_canonicalized()
	_case_saved_slots_migrate_names_only()
	_case_same_id_stale_name_cannot_poison_shop_cache()
	_case_battle_replay_uses_full_canonical_names()
	_finish()


func _case_all_renames_have_one_local_truth() -> void:
	for unit_id in RENAMED_EN:
		var old_and_new: Array = RENAMED_EN[unit_id]
		var canonical := DataRegistry.canonical_unit_def(unit_id)
		_h.expect(not canonical.is_empty(), "missing_canonical_unit",
			"No canonical row for %s" % unit_id)
		_h.expect(str(canonical.get("name_en", "")) == str(old_and_new[1]),
			"wrong_canonical_name", "%s resolved to %s, expected %s" % [
				unit_id, str(canonical.get("name_en", "")), str(old_and_new[1])])
		var stale := canonical.duplicate(true)
		stale["name_en"] = old_and_new[0]
		DataRegistry.canonicalize_unit_display_names(stale)
		_h.expect(str(stale.get("name_en", "")) == str(old_and_new[1]),
			"stale_name_survived", "%s survived canonicalization for %s" % [old_and_new[0], unit_id])


func _case_old_server_offer_is_canonicalized() -> void:
	var canonical := DataRegistry.canonical_unit_def("dark_mage")
	if canonical.is_empty():
		return
	var stale_offer := canonical.duplicate(true)
	stale_offer["name_en"] = "Shadow Mage"
	stale_offer["probe_skill"] = {"damage": 731, "trigger": "on_cast"}
	stale_offer["star4"] = {"skill_multiplier": 4.25, "probe": true}
	var offers: Array = [stale_offer]
	while offers.size() < GameState.SHOP_UNIT_SLOTS:
		offers.append({})
	NetworkService.team_active = true
	NetworkService.is_host = false
	NetworkService.server_shop = {
		"offer_id": "old-server-name-probe",
		"offers": offers,
		"sold": [false, false, false, false],
	}
	_h.expect(bool(_prep.call("_adopt_server_shop")), "server_shop_not_adopted",
		"Old server shop fixture was not adopted")
	var adopted: Dictionary = GameState.shop_offers[0]
	_h.expect(str(adopted.get("name_en", "")) == "Hexmage", "server_old_name_survived",
		"Server Shadow Mage entered the client shop")
	_h.expect(str(adopted.get("id", "")) == "dark_mage", "server_id_changed",
		"Display repair changed the gameplay id")
	_h.expect(adopted.get("probe_skill") == stale_offer.get("probe_skill"), "server_skill_changed",
		"Display repair changed skill data")
	_h.expect(adopted.get("star4") == stale_offer.get("star4"), "server_star4_changed",
		"Display repair changed four-star data")
	# Purchasing uses offer.duplicate(true); cover that exact boundary without
	# invoking save_run() and touching the developer's real user:// save.
	var purchased := {"id": adopted.id, "uid": "probe-uid", "star": 4, "def": adopted.duplicate(true)}
	_h.expect(str(purchased.def.get("name_en", "")) == "Hexmage", "purchase_name_regressed",
		"Purchased copy reverted to Shadow Mage")
	_h.expect(int(purchased.star) == 4 and str(purchased.uid) == "probe-uid", "purchase_identity_changed",
		"Purchased copy lost star/uid state")


func _case_saved_slots_migrate_names_only() -> void:
	var canonical := DataRegistry.canonical_unit_def("dark_mage")
	if canonical.is_empty():
		return
	var stale_def := canonical.duplicate(true)
	stale_def["name_en"] = "Shadow Mage"
	stale_def["probe_skill"] = {"power": 913}
	stale_def["star4"] = {"power": 1777}
	var before_non_names := stale_def.duplicate(true)
	before_non_names.erase("name")
	before_non_names.erase("name_en")
	GameState.board_slots[0] = {
		"id": "dark_mage", "uid": "saved-four-star", "star": 4,
		"def": stale_def.duplicate(true),
	}
	GameState.bench_slots[0] = {
		"id": "dark_mage", "uid": "saved-bench", "star": 3,
		"def": stale_def.duplicate(true),
	}
	GameState.shop_offers[0] = stale_def.duplicate(true)
	SaveManager.call("_normalize_unit_display_names")
	for cell in [GameState.board_slots[0], GameState.bench_slots[0]]:
		var migrated: Dictionary = (cell as Dictionary).def
		var migrated_non_names := migrated.duplicate(true)
		migrated_non_names.erase("name")
		migrated_non_names.erase("name_en")
		_h.expect(str(migrated.get("name_en", "")) == "Hexmage", "save_old_name_survived",
			"Saved slot still displays Shadow Mage")
		_h.expect(migrated_non_names == before_non_names, "save_gameplay_fields_changed",
			"Save migration changed a non-name def field")
	_h.expect(int((GameState.board_slots[0] as Dictionary).star) == 4, "save_star_changed",
		"Save migration changed four-star state")
	_h.expect(str((GameState.board_slots[0] as Dictionary).uid) == "saved-four-star", "save_uid_changed",
		"Save migration changed uid")
	_h.expect(str((GameState.shop_offers[0] as Dictionary).get("name_en", "")) == "Hexmage",
		"save_shop_old_name_survived", "Saved shop offer still displays Shadow Mage")
	var history_row := {"id": "dark_mage", "name": canonical.name, "name_en": "Shadow Mage"}
	var history_name := BattleStatsFormat.stats_display_name(history_row)
	_h.expect(history_name == "Hexmage", "battle_history_old_name_survived",
		"Last Battle resolved %s (locale=%s), expected Hexmage" % [history_name, LocaleManager.get_locale()])


func _case_same_id_stale_name_cannot_poison_shop_cache() -> void:
	var canonical := DataRegistry.canonical_unit_def("dark_mage")
	if canonical.is_empty():
		return
	GameState.shop_offers[0] = canonical.duplicate(true)
	GameState.shop_sold[0] = false
	_prep.get("_shop").call("refresh")
	var labels: Array = _prep.get("_shop").get("card_labels")
	if not _h.expect(not labels.is_empty(), "shop_labels_missing", "Shop name labels are missing"):
		return
	var stale_same_id := canonical.duplicate(true)
	stale_same_id["name_en"] = "Shadow Mage"
	GameState.shop_offers[0] = stale_same_id
	_prep.get("_shop").call("refresh")
	_h.expect(str((labels[0] as Label).text) == "Hexmage", "shop_name_cache_poisoned",
		"Same-id stale payload rendered %s (locale=%s)" % [
			str((labels[0] as Label).text), LocaleManager.get_locale()])


func _case_battle_replay_uses_full_canonical_names() -> void:
	var renderer := BattleRendererScript.new()
	for unit_id in RENAMED_EN:
		var full_name := str((RENAMED_EN[unit_id] as Array)[1])
		var text_width := ThemeDB.fallback_font.get_string_size(
			full_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
		_h.expect(text_width <= 76.0, "battle_head_name_too_wide",
			"%s is %.1fpx wide and does not fit the 82px label with outline" % [full_name, text_width])
	var divine := {
		"uid": "old-replay-divine", "id": "god_priest", "name": "神圣仆从",
		"name_en": "Divine Servant", "def": {"id": "god_priest", "name_en": "Divine Servant"},
		"team": "player", "owner_slot": 0, "atk": 31, "damage_dealt": 359,
	}
	var priestess := {
		"uid": "old-replay-priestess", "id": "god_priestess", "name": "高阶女祭司",
		"name_en": "High Priestess", "def": {"id": "god_priestess", "name_en": "High Priestess"},
		"team": "player", "owner_slot": 0, "atk": 26, "damage_dealt": 256,
	}
	_h.expect(str(renderer.call("_fighter_display_name", divine)) == "Godhand",
		"battle_divine_old_name_survived", "Battle replay still displays Divine Servant")
	_h.expect(str(renderer.call("_fighter_display_name", priestess)) == "Priestess",
		"battle_priestess_old_name_survived", "Battle replay still displays High Priestess")

	var unit_node := renderer.call("_make_unit_node", priestess) as Control
	var head_label := unit_node.get_node_or_null("Name") as Label
	_h.expect(head_label != null and head_label.text == "Priestess", "battle_head_name_truncated",
		"Battle head label is not the full canonical Priestess name")

	var top_atk := RichTextLabel.new()
	renderer.set("_top5_atk_lbl", top_atk)
	renderer.set("_top5_next_refresh_msec", 0)
	renderer.set("_state", {"unit_stats": {}})
	renderer.call("_refresh_top5_atk", [divine, priestess])
	_h.expect(top_atk.text.contains("Godhand") and top_atk.text.contains("Priestess"),
		"battle_top_atk_name_truncated", "Top ATK does not contain both full canonical names")
	_h.expect(not top_atk.text.contains("Divine") and not top_atk.text.contains("High Pr"),
		"battle_top_atk_old_name_survived", "Top ATK still contains old replay names")
	unit_node.free()
	top_atk.free()
	renderer.free()


func _finish() -> void:
	NetworkService.team_active = _saved_team_active
	NetworkService.is_host = _saved_is_host
	NetworkService.server_shop = _saved_server_shop
	LocaleManager.set_locale(_saved_locale)
	_h.finish(get_tree())
