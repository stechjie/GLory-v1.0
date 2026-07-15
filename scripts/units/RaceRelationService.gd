class_name RaceRelationService
extends RefCounted

const ENABLED := false
const MAX_PROGRESS := 4
const STAT_CHANGE := 0.15
const BOARD_COLUMNS := GameConstants.BOARD_COLUMNS

const RELATION_RULES := {
	"god|human": "friendly",
	"dark|undead": "friendly",
	"dark|god": "hostile",
	"human|undead": "hostile",
}

static func reconcile_board(board_slots: Array, bench_slots: Array = [], advance_existing: bool = false, preserve_disconnected: bool = false) -> void:
	if not ENABLED:
		_clear_all_relation_data(board_slots)
		_clear_all_relation_data(bench_slots)
		return
	for cell in bench_slots:
		clear_cell_relations(cell)
	if preserve_disconnected:
		_remember_current_relations(board_slots)
	var next_states: Dictionary = {}
	for relation_key_value in RELATION_RULES.keys():
		var relation_key := str(relation_key_value)
		var parts := relation_key.split("|")
		if parts.size() != 2:
			continue
		var race_a := str(parts[0])
		var race_b := str(parts[1])
		var visited: Dictionary = {}
		for start_index in board_slots.size():
			if visited.has(start_index) or not _cell_has_pair_race(board_slots[start_index], race_a, race_b):
				continue
			var component := _collect_component(board_slots, start_index, race_a, race_b, visited)
			if component.size() < 2:
				continue
			var previous_progress := 0
			var was_active := false
			for cell_index in component:
				var cell: Dictionary = board_slots[int(cell_index)]
				var state: Dictionary = _best_saved_relation_state(cell, relation_key)
				previous_progress = maxi(previous_progress, int(state.get("progress", 0)))
				was_active = was_active or bool(state.get("active", false))
			var progress := 1 if previous_progress <= 0 else previous_progress
			var active := was_active
			if advance_existing and previous_progress > 0 and not was_active:
				if previous_progress < MAX_PROGRESS:
					progress = previous_progress + 1
				active = progress >= MAX_PROGRESS
			for cell_index in component:
				var index := int(cell_index)
				var states: Dictionary = next_states.get(index, {})
				states[relation_key] = {
					"kind": str(RELATION_RULES[relation_key]),
					"progress": progress,
					"active": active,
				}
				next_states[index] = states
	for index in board_slots.size():
		var cell = board_slots[index]
		if typeof(cell) != TYPE_DICTIONARY:
			continue
		var next: Dictionary = next_states.get(index, {})
		if next.is_empty():
			cell.erase("race_relations")
		else:
			cell["race_relations"] = next
		if not preserve_disconnected:
			cell.erase("race_relation_memory")

static func advance_round(board_slots: Array, bench_slots: Array = []) -> void:
	reconcile_board(board_slots, bench_slots, true, false)

static func finalize_for_battle(board_slots: Array, bench_slots: Array = []) -> void:
	reconcile_board(board_slots, bench_slots, false, false)

static func clear_cell_relations(cell: Variant) -> void:
	if typeof(cell) == TYPE_DICTIONARY:
		(cell as Dictionary).erase("race_relations")
		(cell as Dictionary).erase("race_relation_memory")

static func _clear_all_relation_data(cells: Array) -> void:
	for cell_value in cells:
		clear_cell_relations(cell_value)
static func _remember_current_relations(board_slots: Array) -> void:
	for cell_value in board_slots:
		if typeof(cell_value) != TYPE_DICTIONARY:
			continue
		var cell: Dictionary = cell_value
		var current: Dictionary = cell.get("race_relations", {})
		if current.is_empty():
			continue
		var memory: Dictionary = cell.get("race_relation_memory", {})
		for key_value in current.keys():
			var key := str(key_value)
			var current_state: Dictionary = current.get(key_value, {})
			var saved_state: Dictionary = memory.get(key, {})
			if int(current_state.get("progress", 0)) >= int(saved_state.get("progress", 0)):
				memory[key] = current_state.duplicate(true)
		cell["race_relation_memory"] = memory

static func _best_saved_relation_state(cell: Dictionary, relation_key: String) -> Dictionary:
	var current: Dictionary = cell.get("race_relations", {}).get(relation_key, {})
	var memory: Dictionary = cell.get("race_relation_memory", {}).get(relation_key, {})
	if int(memory.get("progress", 0)) > int(current.get("progress", 0)):
		return memory
	if bool(memory.get("active", false)) and not bool(current.get("active", false)):
		return memory
	return current

static func stat_multiplier_for_cell(cell: Dictionary) -> float:
	if not ENABLED:
		return 1.0
	var has_friendly := false
	var has_hostile := false
	var relations: Dictionary = cell.get("race_relations", {})
	for state_value in relations.values():
		if typeof(state_value) != TYPE_DICTIONARY:
			continue
		var state: Dictionary = state_value
		if not bool(state.get("active", false)):
			continue
		if str(state.get("kind", "")) == "friendly":
			has_friendly = true
		elif str(state.get("kind", "")) == "hostile":
			has_hostile = true
	return 1.0 + (STAT_CHANGE if has_friendly else 0.0) - (STAT_CHANGE if has_hostile else 0.0)

static func visual_states_for_cell(cell: Variant) -> Array:
	if not ENABLED:
		return []
	var out: Array = []
	if typeof(cell) != TYPE_DICTIONARY:
		return out
	var relations: Dictionary = (cell as Dictionary).get("race_relations", {})
	var keys: Array = relations.keys()
	keys.sort()
	for relation_key_value in keys:
		var relation_key := str(relation_key_value)
		var state_value = relations.get(relation_key, {})
		if typeof(state_value) != TYPE_DICTIONARY:
			continue
		var state: Dictionary = (state_value as Dictionary).duplicate(true)
		state["pair"] = relation_key
		out.append(state)
	return out

static func _collect_component(board_slots: Array, start_index: int, race_a: String, race_b: String, visited: Dictionary) -> Array:
	var component: Array = []
	var queue: Array[int] = [start_index]
	visited[start_index] = true
	while not queue.is_empty():
		var index: int = int(queue.pop_front())
		component.append(index)
		var race := _cell_race(board_slots[index])
		for neighbor_index in _orthogonal_neighbors(index, board_slots.size()):
			if visited.has(neighbor_index):
				continue
			var neighbor_race := _cell_race(board_slots[neighbor_index])
			if not _races_form_pair(race, neighbor_race, race_a, race_b):
				continue
			visited[neighbor_index] = true
			queue.append(neighbor_index)
	return component

static func _orthogonal_neighbors(index: int, board_size: int) -> Array[int]:
	var out: Array[int] = []
	var column := index % BOARD_COLUMNS
	if column > 0:
		out.append(index - 1)
	if column < BOARD_COLUMNS - 1 and index + 1 < board_size:
		out.append(index + 1)
	if index - BOARD_COLUMNS >= 0:
		out.append(index - BOARD_COLUMNS)
	if index + BOARD_COLUMNS < board_size:
		out.append(index + BOARD_COLUMNS)
	return out

static func _cell_has_pair_race(cell: Variant, race_a: String, race_b: String) -> bool:
	var race := _cell_race(cell)
	return race == race_a or race == race_b

static func _cell_race(cell: Variant) -> String:
	if typeof(cell) != TYPE_DICTIONARY:
		return ""
	var dict: Dictionary = cell
	if bool(dict.get("is_mercenary", false)):
		return ""
	return str(dict.get("def", {}).get("race", ""))

static func _races_form_pair(first: String, second: String, race_a: String, race_b: String) -> bool:
	return (first == race_a and second == race_b) or (first == race_b and second == race_a)
