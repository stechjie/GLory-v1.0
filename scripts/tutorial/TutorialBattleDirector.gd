extends RefCounted
## Select a real, deterministic combat replay satisfying the lesson contract.
## No result/frame/remaining-HP rewriting. Failed or canceled searches publish nothing.
static func accepts(replay: Dictionary) -> bool:
	var result: Dictionary = replay.get("result", {})
	if result.is_empty() or bool(result.get("is_draw", false)):
		return false
	var win := TutorialMode.script_round_expects_win()
	if bool(result.get("player_wins", false)) != win:
		return false
	var survivors := int(result.get("player_alive" if win else "enemy_alive", 0))
	if survivors <= 0 or int(result.get("enemy_alive" if win else "player_alive", 0)) != 0:
		return false
	if GameState.round_index >= TutorialMode.SCRIPT_FINAL_ROUND:
		return true
	var losing_hp := GameState.enemy_team_hp if win else GameState.team_hp
	return survivors < losing_hp

static func prepare(active: Callable) -> Dictionary:
	if not bool(active.call()):
		TutorialMode.clear_ai_roster_plan()
		return {}
	var win := TutorialMode.script_round_expects_win()
	if GameState.round_index < TutorialMode.SCRIPT_FINAL_ROUND and (GameState.enemy_team_hp if win else GameState.team_hp) <= 1:
		TutorialMode.clear_ai_roster_plan()
		return {} # A positive, nonlethal hit is impossible from a one-HP checkpoint.
	var sim = load("res://scripts/battle/BattleSimulator.gd")
	# Preserve the existing star-based plans when one already satisfies both rules.
	for notch in 4:
		TutorialMode.set_ai_roster_plan(notch)
		var probe: Dictionary = await _probe(sim, active)
		if not bool(active.call()):
			TutorialMode.clear_ai_roster_plan()
			return {}
		if accepts(probe):
			var replay: Dictionary = await sim.compute_team_replay_async(0)
			if bool(active.call()) and accepts(replay):
				return replay
		# More star advantage cannot fix an already overwhelming victory.
		if bool(probe.get("result", {}).get("player_wins", false)) == win and not bool(probe.get("result", {}).get("is_draw", false)):
			break
	# Star caps alone cannot balance every player roster. Search continuous AI
	# strength around the win/loss boundary, where actual casualties limit damage.
	for pressure in [1.0, 0.5, 2.0, 4.0]:
		var low := -6.0
		var high := 6.0
		for attempt in 18:
			var balance := low if attempt == 0 else (high if attempt == 1 else (low + high) * 0.5)
			TutorialMode.set_ai_roster_plan(0, balance, pressure)
			var probe: Dictionary = await _probe(sim, active)
			if not bool(active.call()):
				TutorialMode.clear_ai_roster_plan()
				return {}
			if accepts(probe):
				# Record only the selected fight, then verify the recorded outcome too.
				var replay: Dictionary = await sim.compute_team_replay_async(0)
				if bool(active.call()) and accepts(replay):
					print("[TUTORIAL] verified round=%d balance=%.5f pressure=%.2f survivors=%d/%d" % [GameState.round_index, balance, pressure, int(replay.result.player_alive), int(replay.result.enemy_alive)])
					return replay
			if attempt < 2:
				continue
			if bool(probe.get("result", {}).get("player_wins", false)):
				high = balance
			else:
				low = balance
	TutorialMode.clear_ai_roster_plan()
	push_warning("Tutorial battle could not satisfy its outcome/damage contract; refusing invalid playback.")
	return {}


# Trial battles need the actual simulation, not hundreds of replay-frame copies.
# Only a selected candidate is recorded for playback; both runs start at the same seed.
static func _probe(sim: GDScript, active: Callable) -> Dictionary:
	var state: Dictionary = sim.prepare_team_state(0)
	var tree := Engine.get_main_loop() as SceneTree
	var started := Time.get_ticks_usec()
	var steps := 0
	while not bool(state.get("finished", false)) and steps < 4000:
		sim.step_state(state)
		steps += 1
		if tree != null and Time.get_ticks_usec() - started >= 8000:
			await tree.process_frame
			if not bool(active.call()):
				return {}
			started = Time.get_ticks_usec()
	return {"result": sim.result_from_state(state)}
