extends Node

# 用相同种子与同一批真实单位数据，比对服务端 PvP 构建与离线自测每一个回放帧。
const ROUND_INDEX := 6
const SHARED_SEED := 20260929
const STEPS := 180


func _ready() -> void:
	GameState.team_mode = true
	GameState.round_index = ROUND_INDEX
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.team_slot_states = ["player", "player", "player", "player", "player", "player"]
	NetworkService.shared_seed = SHARED_SEED
	var placements := [
		{"slot": 0, "cell": 5, "kind": "piece", "unit_id": "god_king", "star": 1},
		{"slot": 0, "cell": 1, "kind": "piece", "unit_id": "dark_fear", "star": 1},
		{"slot": 0, "cell": 2, "kind": "piece", "unit_id": "dark_suc", "star": 1},
		{"slot": 0, "cell": 13, "kind": "merc", "unit_id": "merc_pisces_bubble", "star": 1},
		{"slot": 1, "cell": 5, "kind": "piece", "unit_id": "undead_poison", "star": 1},
		{"slot": 1, "cell": 6, "kind": "piece", "unit_id": "undead_fly", "star": 1},
		{"slot": 3, "cell": 5, "kind": "piece", "unit_id": "human_king", "star": 1},
		{"slot": 3, "cell": 6, "kind": "piece", "unit_id": "dark_suc", "star": 1},
		{"slot": 3, "cell": 13, "kind": "merc", "unit_id": "merc_pisces_bubble", "star": 1},
	]
	var by_slot := {}
	var mercs_by_slot := {}
	for slot in 6:
		var board: Array = []
		board.resize(GameConstants.CELL_COUNT)
		board.fill(null)
		by_slot[slot] = board
		mercs_by_slot[slot] = []
	for p in placements:
		var kind := str(p.get("kind", "piece"))
		var d := OfficeTestSim.find_def(kind, str(p.unit_id))
		if d.is_empty():
			push_error("Missing unit: %s" % str(p.unit_id))
			get_tree().quit(1)
			return
		var cell := {"id": str(p.unit_id), "def": d, "star": int(p.star)}
		if kind == "merc":
			cell["is_mercenary"] = true
			(mercs_by_slot[int(p.slot)] as Array).append(cell)
		else:
			(by_slot[int(p.slot)] as Array)[int(p.cell)] = cell
	var snapshots := {}
	var money_set := ["money_compound", "money_generous_fate", "money_discount", "money_golden_altar"]
	for slot in 6:
		var board: Array = by_slot[slot]
		snapshots[slot] = {"version": NetProtocol.SNAPSHOT_VERSION, "round": ROUND_INDEX,
			"board": board, "mercenaries": mercs_by_slot[slot], "treasures": money_set if slot == 0 else [],
			"syn": NetProtocol.rebuild_syn_from_board(board), "pet": "pet_cat" if slot == 0 else "",
			"gold": 2000 if slot == 0 else 0}
	NetworkService.team_boards = snapshots
	var online := BattleSimulator.prepare_team_state(0)
	var online_rng_state := RngService.rng.state
	var config := {"placements": placements, "slot_treasures": {0: money_set},
		"slot_gold": {0: 2000}, "slot_pets": {0: "pet_cat"},
		"shared_seed": SHARED_SEED, "round_index": ROUND_INDEX}
	var offline := OfficeTestSim.build_test_state(config)
	var offline_rng_state := RngService.rng.state
	if online_rng_state != offline_rng_state:
		push_error("OFFICETEST_ONLINE_PARITY FAIL RNG after setup")
		get_tree().quit(1)
		return
	if not _same_frame(online, offline):
		push_error("OFFICETEST_ONLINE_PARITY FAIL opening state")
		get_tree().quit(1)
		return
	var seen := {"fear": 0, "stun": 0, "poison": 0}
	for tick in STEPS:
		RngService.rng.state = online_rng_state
		DamageService.set_stat_state(online)
		BattleSimulator.step_state(online)
		var next_online_rng_state := RngService.rng.state
		RngService.rng.state = offline_rng_state
		DamageService.set_stat_state(offline)
		BattleSimulator.step_state(offline)
		var next_offline_rng_state := RngService.rng.state
		if next_online_rng_state != next_offline_rng_state:
			push_error("OFFICETEST_ONLINE_PARITY FAIL RNG tick=%d" % tick)
			get_tree().quit(1)
			return
		online_rng_state = next_online_rng_state
		offline_rng_state = next_offline_rng_state
		if not _same_frame(online, offline):
			push_error("OFFICETEST_ONLINE_PARITY FAIL tick=%d elapsed=%s/%s" % [tick, str(online.elapsed), str(offline.elapsed)])
			get_tree().quit(1)
			return
		for f in (online.player + online.enemy):
			for kind in seen.keys():
				if StatusEffectService.has_status(f, str(kind)):
					seen[kind] = int(seen[kind]) + 1
		if bool(online.finished) or bool(offline.finished):
			break
	print("OFFICETEST_ONLINE_PARITY PASS ticks=%d observed=%s" % [STEPS, str(seen)])
	get_tree().quit(0)


func _same_frame(a: Dictionary, b: Dictionary) -> bool:
	if bool(a.finished) != bool(b.finished):
		return false
	var af: Array = []
	var bf: Array = []
	var ae: Array = []
	var be: Array = []
	BattleSimulator._replay_capture_frame(a, af, ae)
	BattleSimulator._replay_capture_frame(b, bf, be)
	if af != bf:
		print("PARITY_FRAME_SIZE online=%d offline=%d" % [(af[0] as Array).size(), (bf[0] as Array).size()])
		for i in mini((af[0] as Array).size(), (bf[0] as Array).size()):
			if af[0][i] != bf[0][i]:
				print("PARITY_FIRST_DIFF online=", af[0][i], " offline=", bf[0][i])
				break
	if ae != be:
		print("PARITY_EVENTS online=", ae, " offline=", be)
	return af == bf and ae == be
