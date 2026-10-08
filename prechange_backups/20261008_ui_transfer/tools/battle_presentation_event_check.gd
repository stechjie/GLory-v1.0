extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")
const EventSchema := preload("res://scripts/battle/BattlePresentationEvent.gd")

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new("battle_presentation_event")
	_check_pure_schema()
	await _check_replay_schema()
	_h.finish(get_tree())


func _check_pure_schema() -> void:
	var raw := {
		"type": "hit_number",
		"source_uid": "player_archer_0",
		"target_uid": "enemy_monster_0",
		"skill_id": "basic_ranged",
		"kind": "dmg",
		"crit": true,
		"amount": 27,
		"is_lethal": false,
		"time": 1.2,
	}
	var first: Dictionary = EventSchema.normalize(raw, "test:room:1:team0", 12, 3)
	var second: Dictionary = EventSchema.normalize(raw, "test:room:1:team0", 12, 3)
	_h.expect(JSON.stringify(first, "", true, true) == JSON.stringify(second, "", true, true),
		"normalize_repeat", "identical inputs must produce byte-identical canonical JSON")
	_h.expect(str(first.get("event_key", "")) == "test:room:1:team0:12:3",
		"event_key", "event_key must be battle_id + tick + ordinal")
	_h.expect(first.get("target_uids", []) == ["enemy_monster_0"],
		"target_alias", "legacy target_uid must normalize to target_uids")
	_h.expect(str(first.get("source_uid", "")) == "player_archer_0",
		"source_uid", "source_uid was not preserved")
	_h.expect(str(first.get("skill_id", "")) == "basic_ranged",
		"skill_id", "stable skill_id was not preserved")
	_h.expect(bool(first.get("is_crit", false)) and not bool(first.get("is_lethal", true)),
		"resolved_flags", "resolved critical/lethal flags are wrong")
	_h.expect(EventSchema.validate(first).is_empty(),
		"valid_schema", "normalized known event failed validation: %s" % str(EventSchema.validate(first)))

	var keys: Array = first.keys()
	var core: Array = EventSchema.core_field_order()
	_h.expect(keys.slice(0, core.size()) == core,
		"field_order", "core event fields are not in the frozen order: %s" % str(keys))

	# Schema normalization must not advance combat RNG. Compare the next value with
	# and without an intervening normalization call.
	RngService.rng.seed = 912345
	var expected_next := RngService.rng.randi()
	RngService.rng.seed = 912345
	EventSchema.normalize(raw, "test:rng:team0", 0, 0)
	var actual_next := RngService.rng.randi()
	_h.expect(actual_next == expected_next,
		"rng_isolation", "event normalization consumed or altered RngService")

	EventSchema.clear_unknown_warning_cache()
	var unknown_raw := {"type": "future_unknown_cue", "source_uid": "unit_1"}
	var unknown_1: Dictionary = EventSchema.normalize(unknown_raw, "test:unknown:team0", 1, 0)
	var unknown_2: Dictionary = EventSchema.normalize(unknown_raw, "test:unknown:team0", 1, 0)
	var unknown_errors := EventSchema.validate(unknown_1)
	_h.expect(JSON.stringify(unknown_1, "", true, true) == JSON.stringify(unknown_2, "", true, true),
		"unknown_stable", "unknown event normalization must remain deterministic")
	_h.expect(EventSchema.unknown_warning_count() == 1,
		"unknown_warn_once", "the same unknown event type must only enter the warning cache once")
	_h.expect(unknown_errors.has("unknown_type:future_unknown_cue"),
		"unknown_rejected", "unknown event type was not reported by validation")


func _check_replay_schema() -> void:
	_setup_fixed_replay_state()
	var sync_1: Dictionary = BattleSim.compute_team_replay(0, "schema-check:round3")
	_setup_fixed_replay_state()
	var sync_2: Dictionary = BattleSim.compute_team_replay(0, "schema-check:round3")
	_setup_fixed_replay_state()
	var async_1: Dictionary = await BattleSim.compute_team_replay_async(0, 8000, "schema-check:round3")

	var events_1: Array = sync_1.get("frame_events", [])
	var events_2: Array = sync_2.get("frame_events", [])
	var events_async: Array = async_1.get("frame_events", [])
	_h.expect(not events_1.is_empty(), "event_buckets", "replay produced no frame_event buckets")
	_h.expect(events_1.size() == (sync_1.get("frames", []) as Array).size(),
		"bucket_count", "frame_events count does not match frames count")
	_h.expect(_sha256_variant(events_1) == _sha256_variant(events_2),
		"sync_event_repeat", "semantic event SHA-256 differs between repeated sync replays")
	_h.expect(_sha256_variant(events_1) == _sha256_variant(events_async),
		"sync_async_events", "semantic event SHA-256 differs between sync and async replay")
	_h.expect(_sha256_final_state(sync_1) == _sha256_final_state(sync_2),
		"sync_final_repeat", "final-state SHA-256 differs between repeated sync replays")
	_h.expect(_sha256_final_state(sync_1) == _sha256_final_state(async_1),
		"sync_async_final", "final-state SHA-256 differs between sync and async replay")

	var roster: Dictionary = sync_1.get("roster", {})
	var seen_keys: Dictionary = {}
	var event_count := 0
	for tick in events_1.size():
		var bucket: Variant = events_1[tick]
		if not _h.expect(bucket is Array, "bucket_type", "tick %d frame_events is not an Array" % tick):
			continue
		for ordinal in (bucket as Array).size():
			var value: Variant = (bucket as Array)[ordinal]
			if not _h.expect(value is Dictionary, "event_type", "tick %d ordinal %d is not a Dictionary" % [tick, ordinal]):
				continue
			var event: Dictionary = value
			event_count += 1
			var errors := EventSchema.validate(event)
			_h.expect(errors.is_empty(), "event_schema", "tick %d ordinal %d errors=%s" % [tick, ordinal, str(errors)])
			_h.expect(int(event.get("tick", -1)) == tick and int(event.get("ordinal", -1)) == ordinal,
				"event_position", "event position fields do not match bucket position at %d/%d" % [tick, ordinal])
			var key := str(event.get("event_key", ""))
			_h.expect(not seen_keys.has(key), "event_key_unique", "duplicate event_key: %s" % key)
			seen_keys[key] = true
			var event_keys: Array = event.keys()
			var core: Array = EventSchema.core_field_order()
			_h.expect(event_keys.slice(0, core.size()) == core,
				"replay_field_order", "event %s core field order changed" % key)
			var source_uid := str(event.get("source_uid", ""))
			_h.expect(roster.has(source_uid), "source_in_roster", "event %s source_uid missing from roster: %s" % [key, source_uid])
			for target_uid in (event.get("target_uids", []) as Array):
				_h.expect(roster.has(str(target_uid)), "target_in_roster", "event %s target_uid missing from roster: %s" % [key, str(target_uid)])
	_h.expect(event_count > 0, "event_count", "fixed replay produced zero semantic events")
	_h.note("events=%d event_sha256=%s final_state_sha256=%s" % [
		event_count, _sha256_variant(events_1), _sha256_final_state(sync_1)])


func _setup_fixed_replay_state() -> void:
	GameState.reset_run()
	DataRegistry.load_all()
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	_h.expect(units.size() >= 4, "unit_fixture", "race_units needs at least four units")
	if units.size() < 4:
		return
	for index in 8:
		var definition: Dictionary = (units[index % 4] as Dictionary).duplicate(true)
		GameState.board_slots[index] = {
			"id": definition.get("id", "unit"),
			"star": 1,
			"def": definition,
		}
	GameState.team_mode = true
	GameState.round_index = 3
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.shared_seed = 424242
	NetworkService.team_slot_states = ["player", "dummy", "dummy", "dummy", "dummy", "dummy"]
	var snapshot: Dictionary = NetProtocol.team_board_submission(GameState.board_slots, GameState.mercenary_slots)
	# Keep this fixture independent from the account's current pet selection.
	snapshot["pet"] = ""
	NetworkService.team_boards = {0: snapshot}


func _sha256_final_state(replay: Dictionary) -> String:
	var frames: Array = replay.get("frames", [])
	return _sha256_variant({
		"final_frame_index": frames.size() - 1,
		"final_frame": frames[-1] if not frames.is_empty() else [],
		"result": replay.get("result", {}),
	})


func _sha256_variant(value: Variant) -> String:
	var text := JSON.stringify(value, "", true, true)
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(text.to_utf8_buffer())
	return context.finish().hex_encode()
