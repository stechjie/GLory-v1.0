extends "res://tools/ai_arena/ai_arena.gd"

# Audit only. Inherits the current full-match economy; never writes game data.
var contexts: Array = []
var capturing := false
var cohort_id := ""
var probe_variant := "baseline"
var original_bosses: Array = []
var original_allies: Array = []
var original_units: Array = []

func _ready() -> void:
	DataRegistry.load_all()
	original_bosses = DataRegistry.get_table("bosses").bosses.duplicate(true)
	original_allies = DataRegistry.get_table("formation_allies").get("allies", []).duplicate(true)
	original_units = DataRegistry.get_table("race_units").units.duplicate(true)
	var args := _parse_args()
	var out := str(args.get("out", ""))
	if out.is_empty() or FileAccess.file_exists(out):
		push_error("Output missing or already exists")
		get_tree().quit(2)
		return
	var started := Time.get_ticks_msec()
	var records: Array = []
	var matches: Array = []
	if str(args.get("mode", "capture")) == "capture":
		capturing = true
		for level in str(args.get("levels", "L2,L3,L5")).split(","):
			for n in int(args.get("count", "2")):
				var seed_value := int(args.get("seed", "1300000")) + n
				cohort_id = "%s_%d" % [level, seed_value]
				matches.append(_play_match(seed_value, level, level))
				print("COHORT_CAPTURE %s contexts=%d" % [cohort_id, contexts.size()])
		capturing = false
	else:
		var loaded: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(args.get("input", ""))))
		if not loaded is Dictionary:
			get_tree().quit(2)
			return
		contexts = loaded.get("contexts", [])
		var round_filter := int(args.get("round", "21"))
		var selected_boss := str(args.get("boss", ""))
		probe_variant = str(args.get("variant", "baseline"))
		var repeats := int(args.get("count", "1"))
		var eligible: Array = contexts.filter(func(c): return int(c.round) == round_filter)
		if eligible.is_empty():
			push_error("No naturally reached contexts for requested round")
			get_tree().quit(2)
			return
		for n in repeats:
			var c: Dictionary = eligible[n % eligible.size()]
			DataRegistry.get_table("race_units").units = original_units.duplicate(true)
			var boards := {}
			for slot in c.boards:
				boards[int(slot)] = c.boards[slot].duplicate(true)
				if str(args.get("rebuild_syn", "0")) == "1":
					boards[int(slot)].syn = NetProtocol.rebuild_syn_from_board(boards[int(slot)].board)
			if str(args.get("mirror", "0")) == "1":
				var source_side := int(args.get("mirror_side", "0")) * 3
				var original_boards: Dictionary = boards.duplicate(true)
				for lane in 3:
					boards[lane] = original_boards[source_side + lane].duplicate(true)
					boards[lane + 3] = original_boards[source_side + lane].duplicate(true)
			if probe_variant.begins_with("pace_"):
				_apply_pacing_boards(boards)
			if probe_variant == "no_mercenaries":
				for board in boards.values():
					board.mercenaries = []
			if probe_variant == "no_treasures":
				for board in boards.values():
					board.treasures = []
			if probe_variant == "swap":
				var before: Dictionary = boards.duplicate(true)
				for slot in 6:
					boards[slot] = before[(slot + 3) % 6]
			var hp: Array = c.hp.duplicate()
			if str(args.get("mirror", "0")) == "1":
				hp = [50, 50]
			if probe_variant == "swap":
				hp.reverse()
			DataRegistry.get_table("bosses").bosses = original_bosses.duplicate(true)
			DataRegistry.get_table("formation_allies")["allies"] = original_allies.duplicate(true)
			if probe_variant in ["guardian_opening_5", "pace_opening", "pace_combined", "pace_combined_high", "pace_budget"]:
				for ally in DataRegistry.get_table("formation_allies").get("allies", []):
					if str(ally.id) == "ally_eternal_night":
						ally.opening_cd = 5.0
			if probe_variant.ends_with("_late"):
				for ally in DataRegistry.get_table("formation_allies").get("allies", []):
					if ally.has("opening_cd"):
						ally.opening_cd = float(ally.opening_cd) * 2.0
			if not selected_boss.is_empty():
				for b in original_bosses:
					if str(b.id) == selected_boss:
						var modified: Dictionary = b.duplicate(true)
						if probe_variant.begins_with("boss_hp_"):
							modified.hp = int(round(float(modified.hp) * float(probe_variant.trim_prefix("boss_hp_"))))
						if probe_variant == "boss_early_hp_1.25":
							modified.hp = int(round(float(modified.hp) * 1.25 * pow(1.35 / 1.45, int(c.boss_completed))))
						if probe_variant.begins_with("apocalypse_damage_"):
							modified.damage_atk_pct = float(probe_variant.trim_prefix("apocalypse_damage_"))
						if probe_variant.begins_with("apocalypse_shield_"):
							modified.charge_shield_pct = float(probe_variant.trim_prefix("apocalypse_shield_"))
						if probe_variant == "boss_resist_20":
							modified["def"] = int(modified.get("def", 0)) + 20
							modified.mres = int(modified.get("mres", 0)) + 20
						DataRegistry.get_table("bosses").bosses = [modified]
			var battle_seed := int(args.get("seed", "2300000")) + n
			if str(args.get("original_seed", "0")) == "1":
				battle_seed = int(c.battle_seed)
			_set_globals(int(c.round), battle_seed, boards, hp, int(c.pve), int(c.boss_completed))
			var record := _probe(int(args.get("team", "0")), str(args.get("detail", "0")) == "1")
			record.merge({"cohort": c.id, "seed": battle_seed, "round": round_filter, "boss": selected_boss, "variant": probe_variant})
			records.append(record)
			if (n + 1) % 100 == 0:
				print("COHORT_PROBE %d/%d" % [n + 1, repeats])
	DataRegistry.get_table("bosses").bosses = original_bosses
	var report := {"schema": 1, "args": args, "contexts": contexts if capturing or records.is_empty() else [], "matches": matches, "records": records, "wall_sec": (Time.get_ticks_msec() - started) / 1000.0, "runner_sha256": FileAccess.get_sha256("res://tools/balance_cohort_runner.gd"), "arena_sha256": FileAccess.get_sha256("res://tools/ai_arena/ai_arena.gd"), "balance_version": DataRegistry.get_table("final_status").get("balance_version", ""), "engine": Engine.get_version_info().string, "scope": "Current AI full-match economy, naturally reached rounds, no pets; AI settlement does not currently award persistent king growth. Not human telemetry."}
	var file := FileAccess.open(out, FileAccess.WRITE)
	if file == null:
		get_tree().quit(2)
		return
	file.store_string(JSON.stringify(report))
	file.close()
	print("COHORT_OK wall_sec=%.2f records=%d contexts=%d" % [report.wall_sec, records.size(), contexts.size()])
	get_tree().quit(0)

func _set_globals(round_index: int, battle_seed: int, boards: Dictionary, team_hp: Array, pve_completed: int, boss_completed: int) -> void:
	super._set_globals(round_index, battle_seed, boards, team_hp, pve_completed, boss_completed)
	if capturing and round_index in [5, 10, 15, 20, 21]:
		contexts.append({"id": cohort_id, "round": round_index, "battle_seed": battle_seed, "boards": boards.duplicate(true), "hp": team_hp.duplicate(), "pve": pve_completed, "boss_completed": boss_completed})
		print("COHORT_ROUND %s r=%d" % [cohort_id, round_index])

func _probe(team: int, detail: bool) -> Dictionary:
	var state: Dictionary = BattleSim.prepare_team_state(team)
	if probe_variant == "no_guardians":
		state.player = state.player.filter(func(f): return not bool(f.get("is_formation_ally", false)))
		state.enemy = state.enemy.filter(func(f): return not bool(f.get("is_formation_ally", false)))
	if probe_variant.contains("_ward") and GameState.round_index == 21:
		var strong := probe_variant.ends_with("_ward65")
		var extended := probe_variant.ends_with("_ward70")
		for fighter in state.player + state.enemy:
			StatusEffectService.add_status(fighter, "damage_reduction", 18.0 if extended else (15.0 if strong else 12.0), {"pct": 0.70 if extended else (0.65 if strong else 0.50)})
	var initial: Array = (state.player + state.enemy).duplicate()
	var roster: Array = []
	for f in initial:
		roster.append({"uid": f.uid, "id": f.id, "team": f.team, "hp": f.max_hp, "atk": f.atk, "def": f.defense, "mres": f.mres, "star": f.star, "owner": f.get("owner_slot", -1), "guardian": f.get("is_formation_ally", false), "skill_ready": f.get("skill_ready", 0.0), "base_hp": f.get("def", {}).get("hp", 0)})
	var checkpoints := {}
	var deaths := {}
	var proc_events := {}
	var events_out: Array = []
	var stacks := {}
	var first_death := -1.0
	var cursor := 0
	var steps := 0
	while not bool(state.finished) and steps < MAX_STEPS:
		BattleSim.step_state(state)
		for f in initial:
			if not bool(f.alive) and not deaths.has(str(f.uid)):
				deaths[str(f.uid)] = state.elapsed
				if first_death < 0:
					first_death = state.elapsed
		for f in state.enemy:
			if str(f.id).begins_with("boss_"):
				stacks[str(f.uid)] = maxi(int(stacks.get(str(f.uid), 0)), int(f.get("skill_stacks", 0)))
		var events: Array = state.visual_events
		while cursor < events.size():
			var event: Dictionary = events[cursor]
			var key := str(event.get("type", "")) + ":" + str(event.get("skill_id", ""))
			proc_events[key] = int(proc_events.get(key, 0)) + 1
			if detail and float(state.elapsed) <= 5.00001:
				var timed: Dictionary = event.duplicate(true)
				timed["step_end"] = state.elapsed
				events_out.append(timed)
			cursor += 1
		if detail:
			for sec in [1, 3, 5]:
				if not checkpoints.has(str(sec)) and float(state.elapsed) + 0.00001 >= float(sec):
					checkpoints[str(sec)] = {"stats": state.unit_stats.duplicate(true), "element_damage": state.get("element_damage_by_slot", {}).duplicate(true)}
		steps += 1
	var result: Dictionary = BattleSim.result_from_state(state)
	var row := {"elapsed": result.get("elapsed", 0), "win": result.get("player_wins", false), "draw": result.get("is_draw", false), "reason": result.get("reason", ""), "finished": state.finished, "first_death": first_death, "player_alive": result.get("player_alive", 0), "enemy_alive": result.get("enemy_alive", 0), "player_hp_current": result.get("player_hp_current", 0), "player_hp_max": result.get("player_hp_max", 1), "boss_stacks": stacks, "events": proc_events}
	if detail:
		row.merge({"roster": roster, "checkpoints": checkpoints, "deaths": deaths, "opening_events": events_out, "stats": result.get("unit_stats", {}), "element_damage": state.get("element_damage_by_slot", {})})
	return row
func _apply_pacing_boards(_boards: Dictionary) -> void:
	# Network sanitization correctly replaces submitted defs with trusted registry rows.
	# Change the in-memory registry, then exercise the normal sanitization path.
	var tanks := ["god_guard", "undead_titan", "human_swordsman", "human_death_servant", "dark_doom", "armbreaker", "crimson"]
	var first_cast := {"god_king": 5.0, "dark_dragon": 4.0, "dark_scythe": 3.0, "god_arbiter": 3.0, "human_swordsman": 2.0, "Icey": 3.0}
	for d in DataRegistry.get_table("race_units").units:
		var id := str(d.get("id", ""))
		if probe_variant != "pace_opening":
			var factor := 1.5 if id in tanks else 1.25
			if probe_variant.begins_with("pace_budget_hp"):
				factor = float(probe_variant.trim_prefix("pace_budget_hp").split("_")[0])
			if probe_variant == "pace_combined_high":
				factor = 2.0 if id in tanks else 1.5
			d.hp = int(round(float(d.get("hp", 1)) * factor))
		if probe_variant != "pace_hp" and first_cast.has(id):
			d.opening_cd = first_cast[id]

		if probe_variant.begins_with("pace_budget") and d.has("star4"):
			var adjustments := {
				"human_mage": {"damage_atk_pct": 4.5, "skill_cd": 2.25},
				"god_arbiter": {"damage_atk_pct": 3.2, "skill_cd": 2.5},
				"dark_scythe": {"damage_atk_pct": 3.75},
				"god_king": {"damage_atk_pct": 2.4, "max_hp_bonus_pct": 0.12, "skill_cd": 7.0}
			}
			if adjustments.has(id):
				d.star4.merge(adjustments[id], true)

		if probe_variant.ends_with("_soft"):
			d.atk = maxi(1, int(round(float(d.atk) * 0.75)))
			if id == "god_king":
				d.star4.max_hp_bonus_pct = 0.08
			if id == "undead_bomb":
				d.star4.damage_atk_pct = 2.25
				d.star4.poisoned_damage_atk_pct = 2.75

		if probe_variant.ends_with("_late") and first_cast.has(id):
			d.opening_cd = float(first_cast[id]) * 2.0
