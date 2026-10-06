extends SceneTree
var Sim: Script
var Status: Script
var failures := 0
var cases := 0
var samples := 0

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _fighter(definition: Dictionary, team: String, lane: int, star: int = 1) -> Dictionary:
	var f: Dictionary = Sim._fighter_from_def(definition,0,team,lane,1,star)
	f.lane = lane
	f.pos = Vector2(230+270*lane,150)
	return f

func _run() -> void:
	Sim = load("res://scripts/battle/BattleSimulator.gd")
	Status = load("res://scripts/battle/StatusEffectService.gd")
	var fixture = load("res://scripts/qa/FixedBattleFixture.gd")
	fixture.setup_match_state(1,20260823)
	var template: Dictionary = Sim.prepare_team_state(0)
	var fear_def: Dictionary = root.get_node("DataRegistry").canonical_unit_def("dark_fear")
	check(fear_def.get("skill_id") == "fear", "Must use real Fear Demon definition")
	for boundary in 2:
		for direction in [-1,1]:
			for star in [1,4]:
				for cells in [1,3]:
					for speed in [165.0,1650.0]:
						for opened in [false,true]:
							_run_case(template,fear_def,boundary,direction,star,cells,speed,opened)
	print("FEAR_WALL_COLLISION cases=",cases," position_samples=",samples," failures=",failures)
	quit(1 if failures else 0)

func _run_case(template: Dictionary, fear_def: Dictionary, boundary: int, direction: int, star: int, cells: int, speed: float, opened: bool) -> void:
	cases += 1
	var state := template.duplicate(true)
	state.player = []
	state.enemy = []
	state.elapsed = 0.0
	state.owner_syn_by_key = {}
	state.player_syn = {}
	var lane := boundary if direction > 0 else boundary+1
	var wall_x := 365.0+270.0*boundary
	var margin := maxf(15.0*cells,28.0)+3.0
	var definition := fear_def.duplicate(true)
	if star == 4: definition.merge(definition.get("star4",{}),true)
	var caster := _fighter(definition,"player",lane,star)
	var target := _fighter({"id":"fear_wall_target", "hp":99999, "atk":1, "range":1, "move_speed":3.0, "footprint_cells":cells},"enemy",lane)
	target.move_speed_px = speed
	target.pos = Vector2(wall_x-direction*(margin+4.0),260)
	caster.pos = target.pos-Vector2(direction*(15.0+15.0*cells+2.0),0)
	# Use the actual skill dispatcher at legal range (including large bodies).
	state.player.append(caster)
	state.enemy.append(target)
	for other in 3:
		if other == lane: continue
		state.player.append(_fighter({"id":"ally_anchor", "hp":99999},"player",other))
		state.enemy.append(_fighter({"id":"enemy_anchor", "hp":99999},"enemy",other))
	if opened:
		var neighbor := lane+direction
		for f: Dictionary in state.enemy:
			if int(f.lane) == neighbor: f.alive = false
	Sim._tick_skills([caster],state.enemy,state)
	check(Status.has_status(target,"fear"),"Real fear skill must actually apply")
	if not Status.has_status(target,"fear"): return
	var ticks := 0
	while Status.has_status(target,"fear") and ticks < 100:
		Sim._step_team([target],state.player,state.elapsed,state)
		if not opened:
			check((target.pos.x-wall_x)*direction <= -margin+0.001,"Fear crossed closed wall")
		check(target.pos.x >= 95+margin-0.001 and target.pos.x <= 905-margin+0.001,"Fear left playable grass")
		samples += 1
		Status.tick(target,0.1)
		state.elapsed += 0.1
		ticks += 1
	check(ticks >= (29 if star == 4 else 19),"Fear must run through full normal/star4 duration")
	if opened:
		check((target.pos.x-wall_x)*direction > 0.0,"Open wall must permit fear movement")
	else:
		check(absf(target.pos.x-(wall_x-direction*margin)) < 0.01,"Victim must reach and stop against closed wall")
