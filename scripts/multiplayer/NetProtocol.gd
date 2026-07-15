class_name NetProtocol
extends RefCounted

const SNAPSHOT_VERSION := 2
const BOARD_SIZE := GameConstants.CELL_COUNT

static func team_board_submission(board_slots: Array, mercenary_slots: Array = []) -> Dictionary:
	return {
		"version": SNAPSHOT_VERSION,
		"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
		"round": GameState.round_index,
		"gold": GameState.gold,
		"board": _minimal_slots(board_slots, false),
		"mercenaries": _minimal_slots(mercenary_slots, true),
		"treasures": _sanitize_treasure_ids(GameState.owned_treasures),
		"syn": SynergyService.current_player_flags(),
	}

static func board_snapshot(board_slots: Array, mercenary_slots: Array = []) -> Dictionary:
	# 3v3: carry this player's treasures + synergy flags so the host can apply
	# them to THIS player's units only (per-owner effects, synced for everyone).
	return {"version": SNAPSHOT_VERSION, "round": GameState.round_index, "board": sanitize_board(board_slots), "mercenaries": sanitize_mercenaries(mercenary_slots), "treasures": GameState.owned_treasures.duplicate(), "syn": SynergyService.current_player_flags()}

static func validate_team_snapshot(snapshot: Variant, expected_round: int) -> Dictionary:
	if typeof(snapshot) != TYPE_DICTIONARY:
		return {"ok": false, "reason": "malformed_not_dictionary"}
	var d: Dictionary = snapshot
	if int(d.get("protocol", -1)) != NetworkConfig.NETWORK_PROTOCOL_VERSION:
		return {"ok": false, "reason": "protocol_mismatch"}
	var round_id := int(d.get("round", -1))
	if round_id != int(expected_round):
		return {"ok": false, "reason": "wrong_round:%d" % round_id}
	var board_result := _validate_slots(d.get("board", []), false, BOARD_SIZE)
	if not bool(board_result.get("ok", false)):
		return board_result
	var merc_result := _validate_slots(d.get("mercenaries", []), true, GameState.MERCENARY_SLOTS)
	if not bool(merc_result.get("ok", false)):
		return merc_result
	var treasures_result := _validate_treasures(d.get("treasures", []))
	if not bool(treasures_result.get("ok", false)):
		return treasures_result
	return {
		"ok": true,
		"snapshot": {
			"version": SNAPSHOT_VERSION,
			"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
			"round": round_id,
			"gold": clampi(int(d.get("gold", GameState.START_GOLD)), 0, 9999),
			"board": board_result.get("slots", _empty_board()),
			"mercenaries": merc_result.get("slots", []),
			"treasures": treasures_result.get("treasures", []),
			"syn": d.get("syn", {}) if typeof(d.get("syn", {})) == TYPE_DICTIONARY else {},
		}
	}

static func normalize_snapshot(snapshot: Variant) -> Dictionary:
	if typeof(snapshot) == TYPE_DICTIONARY:
		var d: Dictionary = snapshot
		return {"version": int(d.get("version", SNAPSHOT_VERSION)), "round": int(d.get("round", 0)), "board": sanitize_board(d.get("board", [])), "mercenaries": sanitize_mercenaries(d.get("mercenaries", [])), "treasures": d.get("treasures", []), "syn": d.get("syn", {})}
	if typeof(snapshot) == TYPE_ARRAY:
		return {"version": SNAPSHOT_VERSION, "round": 0, "board": sanitize_board(snapshot), "mercenaries": [], "treasures": [], "syn": {}}
	return {"version": SNAPSHOT_VERSION, "round": 0, "board": _empty_board(), "mercenaries": [], "treasures": [], "syn": {}}

static func extract_treasures(snapshot: Variant) -> Array:
	return normalize_snapshot(snapshot).get("treasures", [])

static func extract_syn(snapshot: Variant) -> Dictionary:
	return normalize_snapshot(snapshot).get("syn", {})

static func extract_board(snapshot: Variant) -> Array:
	return normalize_snapshot(snapshot).get("board", [])

static func extract_mercenaries(snapshot: Variant) -> Array:
	return normalize_snapshot(snapshot).get("mercenaries", [])

static func snapshot_has_units(snapshot: Variant) -> bool:
	for cell in extract_board(snapshot):
		if typeof(cell) == TYPE_DICTIONARY:
			return true
	for cell in extract_mercenaries(snapshot):
		if typeof(cell) == TYPE_DICTIONARY:
			return true
	return false

static func snapshot_round(snapshot: Variant) -> int:
	return int(normalize_snapshot(snapshot).get("round", 0))

static func sanitize_board(board_slots: Variant) -> Array:
	var out := _empty_board()
	if typeof(board_slots) != TYPE_ARRAY:
		return out
	var raw: Array = board_slots
	var overflow: Array = []
	for i in raw.size():
		var clean = sanitize_cell(raw[i])
		if clean == null:
			continue
		if i < BOARD_SIZE and out[i] == null:
			out[i] = clean
		else:
			overflow.append(clean)
	for clean in overflow:
		var empty_index := out.find(null)
		if empty_index < 0:
			break
		out[empty_index] = clean
	return out

static func sanitize_mercenaries(mercenary_slots: Variant) -> Array:
	var out := []
	if typeof(mercenary_slots) != TYPE_ARRAY:
		return out
	var raw: Array = mercenary_slots
	for cell in raw:
		var clean = sanitize_cell(cell)
		if clean != null and typeof(clean) == TYPE_DICTIONARY:
			clean.is_mercenary = true
			out.append(clean)
	return out

static func sanitize_cell(cell: Variant) -> Variant:
	if cell == null or typeof(cell) != TYPE_DICTIONARY:
		return null
	var c: Dictionary = cell
	var is_merc := bool(c.get("is_mercenary", false))
	var def := _trusted_def(str(c.get("id", "")), is_merc)
	if def.is_empty():
		def = _safe_def(c)
	if def.is_empty():
		return null
	return {
		"id": str(c.get("id", def.get("id", ""))),
		"star": clampi(int(c.get("star", 1)), 1, GameState.MAX_UNIT_STAR),
		"def": def,
		"is_mercenary": bool(c.get("is_mercenary", def.get("is_mercenary", false))),
		"merc_cost": int(c.get("merc_cost", def.get("cost", 0))),
		"race_relations": _safe_race_relations(c.get("race_relations", {})),
	}

static func _safe_race_relations(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	var out: Dictionary = {}
	for key_value in (value as Dictionary).keys():
		var key := str(key_value)
		var state_value = (value as Dictionary).get(key_value, {})
		if typeof(state_value) != TYPE_DICTIONARY:
			continue
		var state: Dictionary = state_value
		out[key] = {
			"kind": str(state.get("kind", "")),
			"progress": clampi(int(state.get("progress", 0)), 0, RaceRelationService.MAX_PROGRESS),
			"active": bool(state.get("active", false)),
		}
	return out

static func _safe_def(cell: Dictionary) -> Dictionary:
	var id := str(cell.get("id", ""))
	if id.is_empty():
		return {}
	for table_name in ["race_units", "mercenaries"]:
		var key := "units" if table_name == "race_units" else "mercenaries"
		var rows: Array = DataRegistry.get_table(table_name).get(key, [])
		for row in rows:
			if str(row.get("id", "")) == id:
				return row.duplicate(true)
	return {}

static func _minimal_slots(slots: Variant, mercenary: bool) -> Array:
	var out := []
	if typeof(slots) != TYPE_ARRAY:
		return out
	var raw: Array = slots
	for i in raw.size():
		var cell = raw[i]
		if cell == null or typeof(cell) != TYPE_DICTIONARY:
			continue
		out.append({
			"slot": i,
			"id": str((cell as Dictionary).get("id", "")),
			"star": clampi(int((cell as Dictionary).get("star", 1)), 1, GameState.MAX_UNIT_STAR),
			"is_mercenary": mercenary or bool((cell as Dictionary).get("is_mercenary", false)),
			"race_relations": _safe_race_relations((cell as Dictionary).get("race_relations", {})),
		})
	return out

static func _validate_slots(value: Variant, mercenary: bool, max_slots: int) -> Dictionary:
	var out := [] if mercenary else _empty_board()
	if typeof(value) != TYPE_ARRAY:
		return {"ok": false, "reason": "malformed_slots"}
	var used := {}
	for item in (value as Array):
		if typeof(item) != TYPE_DICTIONARY:
			return {"ok": false, "reason": "malformed_slot_entry"}
		var d: Dictionary = item
		var slot := int(d.get("slot", -1))
		if slot < 0 or slot >= max_slots:
			return {"ok": false, "reason": "invalid_slot:%d" % slot}
		if used.has(slot):
			return {"ok": false, "reason": "duplicate_slot:%d" % slot}
		used[slot] = true
		var id := str(d.get("id", ""))
		var def := _trusted_def(id, mercenary)
		if def.is_empty():
			return {"ok": false, "reason": "invalid_unit_id:%s" % id}
		var star := int(d.get("star", 1))
		if star < 1 or star > GameState.MAX_UNIT_STAR:
			return {"ok": false, "reason": "invalid_star:%d" % star}
		var clean := {
			"id": id,
			"star": star,
			"def": def,
			"is_mercenary": mercenary,
			"merc_cost": int(def.get("cost", 0)),
			"race_relations": _safe_race_relations(d.get("race_relations", {})),
		}
		if mercenary:
			out.append(clean)
		else:
			out[slot] = clean
	return {"ok": true, "slots": out}

static func _trusted_def(id: String, mercenary: bool) -> Dictionary:
	if id.is_empty():
		return {}
	var table_name := "mercenaries" if mercenary else "race_units"
	var key := "mercenaries" if mercenary else "units"
	var rows: Array = DataRegistry.get_table(table_name).get(key, [])
	for row in rows:
		if str(row.get("id", "")) == id:
			return (row as Dictionary).duplicate(true)
	return {}

static func _validate_treasures(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_ARRAY:
		return {"ok": false, "reason": "malformed_treasures"}
	var out := _sanitize_treasure_ids(value)
	if out.size() != (value as Array).size():
		return {"ok": false, "reason": "invalid_treasure_id"}
	if out.size() > TreasureService.MAX_OWNED:
		return {"ok": false, "reason": "too_many_treasures"}
	return {"ok": true, "treasures": out}

static func _sanitize_treasure_ids(value: Variant) -> Array:
	var out := []
	if typeof(value) != TYPE_ARRAY:
		return out
	var known := {}
	for t in DataRegistry.get_table("treasures").get("treasures", []):
		known[str((t as Dictionary).get("id", ""))] = true
	for tid_value in (value as Array):
		var tid := str(tid_value)
		if tid.is_empty() or out.has(tid) or not known.has(tid):
			continue
		out.append(tid)
	return out

static func _empty_board() -> Array:
	var out := []
	out.resize(BOARD_SIZE)
	out.fill(null)
	return out
