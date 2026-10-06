extends SceneTree
var failures := 0
var Shared: Script
var Sim: Script

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		push_error(label)

func fighter(team: String, lane: int) -> Dictionary:
	return {"uid":team+str(lane), "team":team, "lane":lane, "pos":Vector2(230+270*lane,260), "alive":true, "hp":100, "footprint_cells":1}

func _run() -> void:
	Shared = load("res://scripts/battle/BattleSimShared.gd")
	Sim = load("res://scripts/battle/BattleSimulator.gd")
	var game = root.get_node("GameState")
	game.team_mode = true
	game.round_index = 1
	var state := {"player":[],"enemy":[]}
	for lane in 3:
		state.player.append(fighter("player",lane))
		state.enemy.append(fighter("enemy",lane))
	for lane in 3:
		check(Shared.lane_band_x(lane).is_equal_approx(Vector2(95+270*lane,365+270*lane)), "Grass lane boundaries")
		var f: Dictionary = state.player[lane]
		Sim._move_without_pushing(f, Vector2(2000,-2000), [], -1, state)
		check(f.pos.x <= 334+270*lane and f.pos.y >= 99, "Walking stays behind closed wall and inside grass")
		f.pos = Vector2(230+270*lane,260)
		Sim._move_without_pushing(f, Vector2(-2000,2000), [], -1, state)
		check(f.pos.x >= 126+270*lane and f.pos.y <= 421, "Fear/slide stays inside grass")
		f.pos = Vector2(10000,-10000)
	Shared.constrain_battle_positions(state)
	check(state.player[1].pos.is_equal_approx(Vector2(604,99)), "Skill teleport repaired before frame emission")
	state.enemy[0].alive = false
	var traveler: Dictionary = state.player[0]
	traveler.pos = Vector2(250,260)
	Sim._move_without_pushing(traveler, Vector2(250,0), [], -1, state)
	check(is_equal_approx(traveler.pos.x,500), "Released left wall allows assistance")
	Sim._move_without_pushing(traveler, Vector2(500,0), [], -1, state)
	check(is_equal_approx(traveler.pos.x,604), "Next closed wall still blocks assistance")
	state.enemy[1].alive = false
	Sim._move_without_pushing(traveler, Vector2(500,0), [], -1, state)
	check(is_equal_approx(traveler.pos.x,874), "Both released walls allow full grass traversal")
	game.team_mode = false
	check(Shared.constrain_fighter_position(traveler,state,Vector2(12,20)) == Vector2(12,20), "Tutorial unchanged")
	game.team_mode = true
	game.round_index = game.FINAL_ROUND
	check(Shared.constrain_fighter_position(traveler,state,Vector2(12,20)) == Vector2(12,20), "Final rotated arena unchanged")
	# Real deterministic PvE/PvP/boss fixture, including opening and every recorded tick.
	var fixture = load("res://scripts/qa/FixedBattleFixture.gd")
	for round_id in [1,5,6]:
		fixture.setup_match_state(round_id,20260823)
		var real: Dictionary = Sim.prepare_team_state(0)
		var samples := 0
		for tick in 450:
			for f: Dictionary in real.player + real.enemy:
				if not f.alive or int(f.get("lane",-1)) < 0: continue
				var lane := int(f.lane)
				var margin := maxf(15.0 * maxi(1,int(f.get("footprint_cells",1))),28.0)+3.0
				check(f.pos.x >= 95+margin-0.01 and f.pos.x <= 905-margin+0.01 and f.pos.y >= 68+margin-0.01 and f.pos.y <= 452-margin+0.01, "Fixture grass bounds")
				if lane <= 0 and not Shared._boundary_released(real,0): check(f.pos.x <= 365-margin+0.01, "Closed left boundary")
				if lane >= 1 and not Shared._boundary_released(real,0): check(f.pos.x >= 365+margin-0.01, "Closed left boundary reverse")
				if lane <= 1 and not Shared._boundary_released(real,1): check(f.pos.x <= 635-margin+0.01, "Closed right boundary")
				if lane >= 2 and not Shared._boundary_released(real,1): check(f.pos.x >= 635+margin-0.01, "Closed right boundary reverse")
				samples += 1
			if real.finished: break
			Sim.step_state(real)
		print("LANE_FIXTURE round=",round_id," kind=",real.kind," samples=",samples," finished=",real.finished)
	print("LANE_PLAYABLE_CHECK failures=",failures)
	quit(1 if failures else 0)
