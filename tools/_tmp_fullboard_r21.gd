extends "res://scripts/qa/battle_presentation_baseline.gd"
# 临时：第 21 回合满棋盘（每路 7 棋子 + 8 雇佣兵）看全屏下棋子会不会站到墙上。用完删。

static var MERC_COUNT := int(OS.get_environment("R21_MERCS")) if OS.has_environment("R21_MERCS") else -1
const POSITIONS := [0, 3, 12, 15, 1, 14, 6]
const EXTRA_A := ["human_knight", "god_angel", "human_priest", "god_priest", "human_cavalry", "god_guard"]
const MERCS := ["merc_pisces_bubble", "merc_cancer_shell", "merc_libra_judge", "merc_taurus_charge",
	"merc_virgo_heal", "merc_gemini_assassin", "merc_leo_sun", "merc_sagittarius_rain",
	"merc_aries_blood", "merc_capricorn_steel", "merc_aquarius_time", "merc_scorpio_death"]


func _setup_match_state(round_index: int) -> void:
	super._setup_match_state(round_index)
	var defs := Fixture.unit_defs()
	var merc_defs := {}
	for m in DataRegistry.get_table("mercenaries").get("mercenaries", []):
		merc_defs[str(m.get("id", ""))] = m
	var all_ids: Array = defs.keys()
	all_ids.sort()
	var boards: Dictionary = {}
	for slot in 6:
		var team := "a" if slot < 3 else "b"
		var lane: Array = (Fixture.lineup(team)[slot % 3] as Array).duplicate()
		var k := slot * 7
		while lane.size() < POSITIONS.size():
			var candidate := str(all_ids[k % all_ids.size()])
			k += 1
			if not lane.has(candidate) and not candidate.begins_with("merc_"):
				lane.append(candidate)
		var board: Array = []
		board.resize(GameConstants.CELL_COUNT)
		for i in POSITIONS.size():
			var uid := str(lane[i])
			if defs.has(uid):
				board[POSITIONS[i]] = {"id": uid, "star": 3, "def": (defs[uid] as Dictionary).duplicate(true)}
		var mercs: Array = Fixture.empty_mercenary_slots()
		for i in (MERC_COUNT if MERC_COUNT >= 0 else mercs.size()):
			var mid := str(MERCS[(i + slot) % MERCS.size()])
			if merc_defs.has(mid):
				mercs[i] = {"id": mid, "star": 1, "def": (merc_defs[mid] as Dictionary).duplicate(true), "is_mercenary": true}
		if slot == 0:
			GameState.board_slots = board
			GameState.mercenary_slots = mercs
		boards[slot] = Fixture.board_submission(board, mercs)
	NetworkService.team_boards = boards
