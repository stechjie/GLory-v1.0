extends RefCounted
class_name FixedBattleFixture

# The one definition of the fixed 3v3 battle every diagnostic tool replays.
#
# Before this existed, scripts/qa/battle_presentation_baseline.gd and tools/promo_capture.gd
# each carried their own copy of the lineup and the match-state setup, with a comment
# telling the next person to keep them identical by hand. scenes/debug/BattleVfxReview.gd
# then shipped without the setup at all, which is why its "Run fixed battle" button
# produced an empty replay: it set the seed and the round but never filled the boards
# or turned team mode on, so BattleSimulator had nothing to simulate.
#
# Anything that changes here changes the frozen D0/D1 hashes, so treat it as frozen
# data, not as a knob.

# Keep this identical to the existing D0 evidence.
const FILL_ORDER: Array[int] = [1, 2, 0, 3, 5, 6, 4, 7]

const LINEUP := {
	"a": [
		["human_swordsman", "human_archer", "human_king", "human_mage"],
		["god_guard", "god_arbiter", "god_king", "god_priestess"],
		["human_militia", "god_aurora", "god_archangel", "human_cleric"],
	],
	"b": [
		["dark_suc", "dark_scythe", "dark_dragon", "dark_mage"],
		["undead_spike", "undead_bomb", "undead_mother", "undead_poison"],
		["dark_fear", "undead_titan", "dark_doom", "undead_fly"],
	],
}

# A reproducible fixture cannot inherit the account's currently selected pet.
# D0 was recorded with no pet; pin that without touching PlayerProfile.
const FIXED_PET_ID := ""


# Puts GameState and NetworkService into the exact state the fixed battle needs.
# `unknown_unit_sink` is optional: pass a Callable taking (unit_id: String) to be
# told about a lineup entry that no longer exists in the data tables, instead of
# silently dropping it.
static func setup_match_state(round_index: int, seed_value: int, unknown_unit_sink: Callable = Callable()) -> void:
	GameState.reset_run()
	GameState.team_mode = true
	GameState.round_index = round_index
	GameState.team_hp = GameState.START_FORMATION_HP
	GameState.enemy_team_hp = GameState.START_FORMATION_HP
	GameState.board_slots = board_from_ids((LINEUP["a"] as Array)[0], unknown_unit_sink)
	GameState.mercenary_slots = empty_mercenary_slots()

	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.shared_seed = seed_value
	NetworkService.team_slot_states = ["player", "player", "player", "player", "player", "player"]
	var boards: Dictionary = {}
	for lane in 3:
		boards[lane] = board_submission(board_from_ids((LINEUP["a"] as Array)[lane], unknown_unit_sink), empty_mercenary_slots())
		boards[lane + 3] = board_submission(board_from_ids((LINEUP["b"] as Array)[lane], unknown_unit_sink), empty_mercenary_slots())
	NetworkService.team_boards = boards


static func board_submission(board: Array, mercenaries: Array) -> Dictionary:
	var snapshot: Dictionary = NetProtocol.team_board_submission(board, mercenaries)
	snapshot["pet"] = FIXED_PET_ID
	return snapshot


static func board_from_ids(unit_ids: Array, unknown_unit_sink: Callable = Callable()) -> Array:
	var board: Array = []
	board.resize(GameConstants.CELL_COUNT)
	var defs := unit_defs()
	var placed := 0
	for value in unit_ids:
		if placed >= FILL_ORDER.size() or placed >= GameState.MAX_NORMAL_UNITS:
			break
		var unit_id := str(value)
		if not defs.has(unit_id):
			if unknown_unit_sink.is_valid():
				unknown_unit_sink.call(unit_id)
			continue
		var unit_def: Dictionary = (defs[unit_id] as Dictionary).duplicate(true)
		board[FILL_ORDER[placed]] = {"id": unit_id, "star": 3, "def": unit_def}
		placed += 1
	return board


static func empty_mercenary_slots() -> Array:
	var slots: Array = []
	slots.resize(GameState.MERCENARY_SLOTS)
	return slots


static func unit_defs() -> Dictionary:
	var defs: Dictionary = {}
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	for value in units:
		if value is Dictionary:
			var unit_def := value as Dictionary
			defs[str(unit_def.get("id", ""))] = unit_def
	return defs


# Every unit id the fixture places, both teams, in lineup order.
static func all_unit_ids() -> Array[String]:
	var out: Array[String] = []
	for team in ["a", "b"]:
		for lane in (LINEUP[team] as Array):
			for unit_id in (lane as Array):
				out.append(str(unit_id))
	return out
