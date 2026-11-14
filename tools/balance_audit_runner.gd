extends Node

# Isolated balance audit: no production data or battle rules are written.
const Fixture = preload("res://scripts/qa/FixedBattleFixture.gd")
const Sim = preload("res://scripts/battle/BattleSimulator.gd")
const BOSS_IDS = ["boss_twin_gate", "boss_rage_beast", "boss_blood_demon", "boss_apocalypse", "boss_soul_devourer", "boss_thunder_core"]

func _ready() -> void:
	DataRegistry.ensure_loaded()
	var args := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var p := a.substr(2).split("=", true, 1)
			args[p[0]] = p[1]
	var count := int(args.get("count", "2"))
	var seed_base := int(args.get("seed", "910000"))
	var out := str(args.get("out", ""))
	var mode := str(args.get("mode", "all"))
	var original: Array = DataRegistry.get_table("bosses").get("bosses", []).duplicate(true)
	var records: Array = []
	for star in [2, 3, 4]:
		for n in count:
			records.append(_run(21, seed_base + n, star, {}, true))
			records.append(_run(21, seed_base + n, star, {}, false))
			for round_index in ([] if mode == "final" else [5, 10, 15, 20]):
				for boss in original:
					if str(boss.get("id", "")) in BOSS_IDS:
						records.append(_run(round_index, seed_base + n, star, boss, true))
	DataRegistry.get_table("bosses")["bosses"] = original
	var report := {"schema": 2, "balance_version": DataRegistry.get_table("final_status").get("balance_version", ""), "runner_sha256": FileAccess.get_sha256("res://tools/balance_audit_runner.gd"), "engine": Engine.get_version_info().get("string", ""), "seed_base": seed_base, "seeds_per_scenario": count, "fixture": "FixedBattleFixture: 4 units per lane, fixed stars; no treasures, pets or mercenaries; full HP guardians; not a measured player population", "records": records}
	if out.is_empty():
		push_error("Missing --out")
		get_tree().quit(2)
		return
	var file := FileAccess.open(out, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write report: " + out)
		get_tree().quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("BALANCE_AUDIT_OK records=%d out=%s" % [records.size(), out])
	get_tree().quit(0)

func _run(round_index: int, seed_value: int, star: int, boss: Dictionary, guardians: bool) -> Dictionary:
	DataRegistry.get_table("bosses")["bosses"] = [boss.duplicate(true)] if not boss.is_empty() else DataRegistry.get_table("bosses").get("bosses", [])
	Fixture.setup_match_state(round_index, seed_value)
	GameState.pve_completed = {5: 4, 10: 7, 15: 10, 20: 13, 21: 13}.get(round_index, 0)
	GameState.boss_completed = {5: 0, 10: 1, 15: 2, 20: 3, 21: 4}.get(round_index, 0)
	for snapshot in NetworkService.team_boards.values():
		for cell in snapshot.get("board", []):
			if cell is Dictionary and not cell.is_empty():
				cell["star"] = star
	var state: Dictionary = Sim.prepare_team_state(0)
	if round_index == 21 and not guardians:
		state.player = state.player.filter(func(f): return not bool(f.get("is_formation_ally", false)))
		state.enemy = state.enemy.filter(func(f): return not bool(f.get("is_formation_ally", false)))
	var first_death := -1.0
	var initial_units: Array = (state.player + state.enemy).duplicate()
	var event_cursor := 0
	var boss_peak_stacks := 0
	var rage_seen := false
	var charge_started := false
	var charge_finished := false
	var twin_revived := false
	var checkpoints := {}
	var initial_roster := []
	for fighter in initial_units:
		initial_roster.append({"uid": fighter.uid, "id": fighter.id, "star": fighter.star, "hp": fighter.hp, "atk": fighter.atk, "defense": fighter.defense, "mres": fighter.get("mres", 0), "team": fighter.team})
	var steps := 0
	while not bool(state.get("finished", false)) and steps < 4000:
		Sim.step_state(state)
		if first_death < 0.0:
			for original_unit in initial_units:
				if not bool(original_unit.get("alive", false)):
					first_death = float(state.elapsed)
					break
		for f in state.enemy:
			if str(f.get("id", "")).begins_with("boss_"):
				boss_peak_stacks = maxi(boss_peak_stacks, int(f.get("skill_stacks", 0)))
				rage_seen = rage_seen or bool(f.get("blood_rage_active", false))
				charge_started = charge_started or f.has("apocalypse_due")
				twin_revived = twin_revived or str(f.get("uid", "")).contains("_revive_")
		var events: Array = state.get("visual_events", [])
		while event_cursor < events.size():
			var e: Dictionary = events[event_cursor]
			if str(e.get("skill_id", "")) == "apocalypse_charge" and str(e.get("type", "")) == "hit_number":
				charge_finished = true
			event_cursor += 1
		for sec in [1, 3, 5]:
			if not checkpoints.has(str(sec)) and float(state.elapsed) + 0.00001 >= float(sec):
				checkpoints[str(sec)] = {"time": state.elapsed, "stats": state.get("unit_stats", {}).duplicate(true), "player_alive": _alive_count(state.player), "enemy_alive": _alive_count(state.enemy)}
		steps += 1
	var result: Dictionary = Sim.result_from_state(state)
	return {"initial_roster": initial_roster, "checkpoints": checkpoints, "finished": bool(state.get("finished", false)), "round": round_index, "seed": seed_value, "star": star, "guardians": guardians, "boss": str(boss.get("id", "")), "elapsed": result.get("elapsed", 0.0), "win": result.get("player_wins", false), "draw": result.get("is_draw", false), "reason": result.get("reason", ""), "first_death": first_death, "player_alive": result.get("player_alive", 0), "enemy_alive": result.get("enemy_alive", 0), "enemy_hp_current": result.get("enemy_hp_current", 0), "enemy_hp_max": result.get("enemy_hp_max", 0), "boss_peak_stacks": boss_peak_stacks, "blood_rage_seen": rage_seen, "apocalypse_charge_seen": charge_started, "apocalypse_hit_event_seen": charge_finished, "twin_revived_seen": twin_revived, "unit_stats": result.get("unit_stats", {}), "steps": steps}

func _alive_count(units: Array) -> int:
	var count := 0
	for f in units:
		if bool(f.get("alive", false)):
			count += 1
	return count