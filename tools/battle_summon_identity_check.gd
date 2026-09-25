extends Node

const Harness := preload("res://tools/CheckHarness.gd")
const PerfFixture := preload("res://tools/battle_perf_check_node.gd")
var _h := Harness.new("battle_summon_identity")


func _ready() -> void:
	NetworkService.set_process(false)
	NetworkService.enter_test_server_mode()
	DataRegistry.load_all()
	_check_mirror_lanes()
	_check_repeated_twin()
	var fixture := PerfFixture.new()
	fixture._build_worst_case(7, 8, 20)
	fixture.free()
	GameState.boss_completed = 3
	var cases := 0
	for seed_value in range(8100, 8200):
		NetworkService.shared_seed = seed_value
		if str(BattleSimShared._round_boss_template().get("id", "")) != "boss_mirror_lord":
			continue
		var replay := BattleSimulator.compute_team_replay(0, "summon-identity:%d" % seed_value)
		var collisions := 0
		var mirror_rows := 0
		for frame in replay.frames:
			var seen := {}
			for row in frame:
				var uid := str(row[0])
				if seen.has(uid):
					collisions += 1
				seen[uid] = true
				if uid.begins_with("enemy_mirror_"):
					mirror_rows += 1
		_h.expect(collisions == 0, "replay_duplicate_uid", "seed=%d duplicate unit rows=%d" % [seed_value, collisions])
		_h.expect(mirror_rows > 0, "fixture_no_mirrors", "Mirror fixture never spawned clones")
		var settlement: Dictionary = replay.result.duplicate(true)
		for field in ["log", "unit_stats", "player_kills", "enemy_kills"]:
			settlement.erase(field)
		_h.note("seed=%d frames=%d mirror_rows=%d collisions=%d settlement=%s" % [seed_value, replay.frames.size(), mirror_rows, collisions, JSON.stringify(settlement)])
		cases += 1
		if cases == 3:
			break
	_h.expect(cases == 3, "fixture_seed_count", "Could not find three deterministic mirror battles")
	DamageService.clear_stat_context()
	_h.finish(get_tree())


func _caster(uid: String, lane: int) -> Dictionary:
	return {
		"uid": uid, "team": "enemy", "lane": lane, "hp": 500, "max_hp": 1000,
		"atk": 100, "defense": 20, "alive": true, "statuses": {}, "skill_ready": 0.0,
	}


func _check_mirror_lanes() -> void:
	var state := {"player": [], "enemy": [], "total_deaths": 0}
	var uids := {}
	for lane in 3:
		var caster := _caster("enemy_L%d_boss" % lane, lane)
		_h.expect(BattleSimSkills._skill_mirror_clone(caster, state, {}) == 2, "mirror_count", "50% health should spawn two mirrors")
		_h.expect(BattleSimSkills._skill_mirror_clone(caster, state, {}) == 0, "mirror_repeat", "Same damage threshold must not respawn")
		caster.hp = 250
		_h.expect(BattleSimSkills._skill_mirror_clone(caster, state, {}) == 1, "mirror_next", "Next damage threshold should add one mirror")
	for clone in state.enemy:
		_h.expect(not uids.has(clone.uid), "mirror_cross_lane_uid", "Multiple casters share clone uid %s" % clone.uid)
		uids[clone.uid] = true
		_h.expect(clone.hp == 300 and clone.max_hp == 300 and clone.atk == 40 and clone.defense == 0,
			"mirror_attributes", "Identity fix changed mirror combat attributes")
		_h.expect(not BattleSimTreasures._is_board_piece(clone), "mirror_board_class", "Mirror must remain excluded from board-piece death rally")
	_h.expect(uids.size() == 9, "mirror_identity_count", "Three lanes and three mirrors must have nine identities")


func _check_repeated_twin() -> void:
	var state := {"player": [], "enemy": [], "total_deaths": 0}
	var caster := _caster("enemy_L1_merc2", 1)
	for index in 3:
		BattleSimSkills._skill_twin_strike(caster, state, {})
	var uids := {}
	for clone in state.enemy:
		_h.expect(not uids.has(clone.uid), "twin_repeated_uid", "Repeated cast without deaths reused %s" % clone.uid)
		uids[clone.uid] = true
		_h.expect(clone.hp == 300 and clone.atk == 40, "twin_attributes", "Identity fix changed twin combat attributes")
		_h.expect(not BattleSimTreasures._is_board_piece(clone), "twin_board_class", "Twin must remain excluded from board-piece death rally")
