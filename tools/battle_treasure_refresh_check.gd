extends Node

const Probe := preload("res://tools/battle_treasure_refresh_probe.gd")
const Harness := preload("res://tools/CheckHarness.gd")
var h = Harness.new("battle_treasure_refresh")
var legacy_script: GDScript
var metrics: Array = []


func _ready() -> void:
	call_deferred("_run")


func _fighter(uid: String, owner: int, team: String, sets: Array = []) -> Dictionary:
	return {"uid": uid, "probe_key": uid, "id": "probe_piece", "owner_slot": owner,
		"team": team, "alive": true, "hp": 80, "max_hp": 100, "lane": 0,
		"treasure_sets": sets, "def": {}}


func _pair(state: Dictionary) -> Array:
	var old = legacy_script.new()
	var current = Probe.new()
	old.set("_state", state.duplicate(true))
	current.set("_state", state.duplicate(true))
	return [old, current]


func _compare(pair: Array, label: String) -> void:
	for probe in pair:
		probe.reset_counts()
		probe._update_treasure_set_presentation()
	h.expect(pair[0].visual_calls == pair[1].visual_calls, "visual_order_" + label,
		label + ": visual submission and removal order must match the legacy route")
	h.expect(pair[0].visual_state() == pair[1].visual_state(), "visual_state_" + label,
		label + ": marks, geometry, palette, defense ownership must be unchanged")
	h.expect(pair[1].index_builds == 1, "one_index_" + label,
		label + ": exactly one current-state index must serve both treasure loops")
	metrics.append({"case": label, "legacy_lookup_calls": pair[0].lookup_calls,
		"current_lookup_calls": pair[1].lookup_calls,
		"legacy_raw_visits": pair[0].lookup_raw_visits,
		"current_raw_visits": pair[1].lookup_raw_visits,
		"current_index_builds": pair[1].index_builds,
		"current_index_raw_visits": pair[1].index_raw_visits})


func _free_pair(pair: Array) -> void:
	for probe in pair:
		probe.free()


func _run() -> void:
	NetworkService.set_process(false)
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	GameState.team_mode = true
	legacy_script = GDScript.new()
	legacy_script.source_code = "extends \"res://tools/battle_treasure_refresh_probe.gd\"\n\n" + FileAccess.get_file_as_string("res://tools/fixtures/battle_treasure_refresh_legacy.gd.txt")
	var error := legacy_script.reload()
	h.expect(error == OK, "legacy_compiles", "The retained legacy functions must compile")
	if error != OK:
		h.finish(get_tree())
		return
	var state := {"player": [_fighter("own", 0, "player", ["attack"]),
		_fighter("ally", 1, "player", ["defense"])],
		"enemy": [_fighter("enemy", 3, "enemy"), _fighter("other_lane", 4, "enemy")]}
	state.enemy[1].lane = 1
	var pair := _pair(state)
	_compare(pair, "team_initial")
	h.expect(pair[1]._set_execute_marked == {"enemy": true}, "team_ownership",
		"Execute marks must exclude self, allies and other lanes")
	for _i in 30:
		_compare(pair, "same_state_%d" % _i)
	h.expect(pair[1].lookup_calls == 0, "stable_no_rescans", "Stable treasure refresh must not scan state by UID")
	# Replacing replay dictionaries and changing ownership must be visible immediately.
	for probe in pair:
		probe._state = {"player": [_fighter("own", 0, "player", ["attack"])],
			"enemy": [_fighter("enemy", 1, "enemy"), _fighter("new_enemy", 3, "enemy")]}
	_compare(pair, "replay_replace_conversion")
	h.expect(pair[1]._set_execute_marked == {"new_enemy": true}, "converted_ally_unmarked",
		"A just-converted ally must lose the enemy execute mark in the same refresh")
	await get_tree().process_frame
	for probe in pair:
		probe._state.player[0].treasure_sets = []
	_compare(pair, "attack_set_removed")
	h.expect(pair[1]._set_execute_marked.is_empty(), "set_removal", "Removing the attack set must clear existing marks")
	await get_tree().process_frame
	_free_pair(pair)
	# Duplicates intentionally disagree: the last raw row must own UID predicates,
	# while raw alive/lane/HP still come from the row currently being rendered.
	state = {"player": [_fighter("dup", 0, "player", ["attack"]),
		_fighter("owner", 0, "player", ["attack"]), _fighter("dup", 2, "player")],
		"enemy": [_fighter("dup", 3, "enemy", ["defense"]), {"alive": true, "lane": 0},
		{"uid": "", "team": "enemy", "owner_slot": 3, "alive": true, "lane": 0}, null, 42]}
	state.player[0].probe_key = "dup_first"
	state.player[2].probe_key = "dup_middle"
	state.enemy[0].probe_key = "dup_last"
	pair = _pair(state)
	_compare(pair, "duplicate_missing_uid")
	var indexed: Dictionary = pair[1]._treasure_state_units_by_uid()
	h.expect(is_same(indexed.dup, pair[1]._state.enemy[0]), "last_duplicate_wins", "Enemy's last duplicate must beat both earlier player rows")
	h.expect(is_same(indexed[""], pair[1]._state.enemy[2]), "empty_uid_priority", "Missing UID and explicit empty UID must retain last-match priority")
	_free_pair(pair)
	# Exercise the actual persistent sigil and opening shield, including reuse and
	# removal, instead of treating matching predicates as proof that VFX still spawn.
	pair = _pair({"player": [_fighter("defender", 0, "player", ["defense"])], "enemy": []})
	var worlds: Array[Node3D] = []
	for probe in pair:
		var world := Node3D.new()
		add_child(world)
		worlds.append(world)
		var actor := Node3D.new()
		world.add_child(actor)
		var hit := Node3D.new()
		hit.name = "HitAnchor"
		hit.position.y = 0.5
		actor.add_child(hit)
		probe._battle_3d_models.defender = actor
		probe._battle_3d_vfx_root = world
	_compare(pair, "real_defense_spawn")
	var sigils: Array = []
	for i in pair.size():
		var probe = pair[i]
		h.expect(probe._set_defense_sigils.size() == 1 and probe._set_defense_shown == {"defender": true},
			"real_defense_present", "Defense set must create the actual persistent sigil and opening shield")
		h.expect(worlds[i].get_child_count() == 3, "real_defense_layers", "Actor, persistent sigil and opening-shield block must all exist")
		sigils.append(probe._set_defense_sigils.defender)
	_compare(pair, "real_defense_stable")
	for i in pair.size():
		h.expect(is_same(sigils[i], pair[i]._set_defense_sigils.defender) and worlds[i].get_child_count() == 3,
			"real_defense_reused", "Unchanged state must preserve the same sigil and not replay the opening shield")
		pair[i]._state.player[0].alive = false
	_compare(pair, "real_defense_death")
	for i in pair.size():
		h.expect(pair[i]._set_defense_sigils.is_empty() and sigils[i].get("_stopping") == true,
			"real_defense_stops", "Death must stop and unregister the actual persistent sigil")
	_free_pair(pair)
	for world in worlds:
		world.free()
	# Explicit sets take priority over ignore rules; legacy fallback uses real set logic.
	pair = _pair({"player": [], "enemy": []})
	var fallback := _fighter("snapshot_only", 0, "player", ["attack"])
	pair[0]._vfx_prev_units.snapshot_only = fallback
	pair[1]._vfx_prev_units.snapshot_only = fallback
	for probe in pair:
		h.expect(probe._unit_has_treasure_set("snapshot_only", "attack"), "snapshot_fallback", "UID event callers must retain previous-snapshot fallback")
		var ignored := {"uid": "merc", "is_mercenary": true, "treasure_sets": ["defense"]}
		probe._state.player = [ignored]
		h.expect(probe._unit_has_treasure_set("merc", "defense"), "explicit_set_priority", "Explicit replay treasure_sets must still win before ignore rules")
		ignored.erase("treasure_sets")
		h.expect(not probe._unit_has_treasure_set("merc", "defense"), "ignored_fallback", "Raw mercenaries without explicit sets must retain the ignore rule")
	_free_pair(pair)
	# Offline ownership remains team+owner based, including missing fields.
	NetworkService.team_active = false
	GameState.team_mode = false
	pair = _pair({"player": [_fighter("own", -1, "player", ["attack"])],
		"enemy": [_fighter("enemy", -1, "enemy"), {"uid": "missing_fields", "alive": true, "lane": 0}]})
	_compare(pair, "offline_missing_owner")
	h.expect(pair[1]._set_execute_marked.has("enemy") and pair[1]._set_execute_marked.has("missing_fields"), "offline_ownership", "Missing-owner enemies must retain offline enemy marks")
	_free_pair(pair)
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	GameState.team_mode = true
	for count in [20, 60, 120]:
		var units: Array = []
		for i in count:
			units.append(_fighter("unit_%d" % i, i % 6, "player" if i % 6 < 3 else "enemy"))
		pair = _pair({"player": units, "enemy": []})
		_compare(pair, "no_set_%d_units" % count)
		h.expect(pair[0].lookup_raw_visits >= 3 * count * count and pair[1].lookup_raw_visits == 0 and pair[1].index_raw_visits == count,
			"quadratic_removed_%d" % count, "No-set all-alive baseline must remove the actual quadratic resolver calls")
		_free_pair(pair)
	print("TREASURE_REFRESH_COUNTS ", JSON.stringify(metrics))
	NetworkService.team_active = false
	GameState.team_mode = false
	h.finish(get_tree())
