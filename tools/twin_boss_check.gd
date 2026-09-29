extends Node

# 双生守门人（boss_twin_gate）在组队模式下：
#   1. 每一路生成两只，第二只是 twin_second_element 形态，两只带同一个分路分组；
#   2. 一只死了、同路另一只还活着 -> 到点复活；
#   3. 同路两只都死了 -> 不复活，哪怕别的路的双生还活着（分组必须分路）；
#   4. 回放名单把分组带给客户端（双生连线 / 复活表现靠它找同伴）。
#
# 07-17 删掉单人模式的敌方生成函数时，双生的生成跟着没了：团队模式只生成一只，
# 复活因为找不到同伴一直失效，直到 09-26 才被发现。这道门禁防它再丢一次。

const Harness := preload("res://tools/CheckHarness.gd")
const TWIN_ID := "boss_twin_gate"

var _h


func _ready() -> void:
	_h = Harness.new("twin_boss")
	GameState.reset_run()
	GameState.team_mode = true
	var twin := _boss(TWIN_ID)
	var other := _boss("boss_rage_beast")
	if not _h.expect(not twin.is_empty() and bool(twin.get("is_twin", false)) and not other.is_empty(),
			"data", "bosses.json 里找不到双生守门人或对照 Boss"):
		_h.finish(get_tree())
		return
	_check_spawn(twin, other)
	_check_revive_with_partner(twin)
	_check_no_revive_across_lanes(twin)
	_check_roster(twin)
	GameState.reset_run()
	GameState.team_mode = false
	_h.finish(get_tree())


func _boss(id: String) -> Dictionary:
	for b in DataRegistry.get_table("bosses").get("bosses", []):
		if str(b.get("id", "")) == id:
			return b
	return {}


func _lane(template: Dictionary, lane: int) -> Array:
	var out: Array = []
	BattleSimShared._append_lane_boss(out, lane, template)
	return out


func _state(player: Array, enemy: Array) -> Dictionary:
	var st := {
		"kind": "boss", "player": player, "enemy": enemy, "elapsed": 0.0,
		"next_sudden_death_tick": BattleFrenzyService.SUDDEN_DEATH_SEC, "finished": false, "log": [],
		"player_syn": {}, "enemy_syn": {}, "enemy_deaths": 0, "total_deaths": 0,
		"field_death_count": 0, "mother_death_counter": 0, "dark_kill_stacks": 0,
		"undead_trait_death_counter": 0, "race_trait_processed_deaths": {},
		"death_history": [], "revive_queue": [], "player_kill_gold": 0, "enemy_kill_gold": 0,
		"kill_gold_by_slot": {}, "player_kills": [], "enemy_kills": [], "bonus_gold": 0,
		"temporary_deaths": [], "visual_events": [], "unit_stats": {},
	}
	BattleSimShared._init_unit_stats(st)
	DamageService.set_stat_state(st)
	return st


func _killer() -> Dictionary:
	var d := {"id": "probe_killer", "name": "probe", "hp": 3000, "atk": 100, "def": 0,
		"attack_speed": 1.0, "range": 1, "move_speed": 3.0, "crit": 0.0, "crit_dmg": 1.0,
		"skill_id": "none", "tier": 1, "element": "-", "race": "-"}
	var f: Dictionary = BattleSimShared._fighter_from_def(d, 0, "player", 0, 1, 1, false, false)
	f["lane"] = 0
	f["owner_treasures"] = []
	return f


func _kill(victim: Dictionary, killer: Dictionary, st: Dictionary) -> void:
	victim.hp = 0
	victim.alive = false
	BattleSimulator._on_unit_killed(killer, victim, st, st.player, st.enemy)


func _alive_in_group(st: Dictionary, group_id: String) -> int:
	var n := 0
	for f in st.enemy:
		if bool(f.get("alive", false)) and str(f.get("twin_group_id", "")) == group_id:
			n += 1
	return n


func _check_spawn(twin: Dictionary, other: Dictionary) -> void:
	for lane in 3:
		var fighters := _lane(twin, lane)
		if not _h.expect(fighters.size() == 2, "twin_count", "lane %d spawned %d twin bodies" % [lane, fighters.size()]):
			continue
		var a: Dictionary = fighters[0]
		var b: Dictionary = fighters[1]
		var group := "%s_L%d" % [TWIN_ID, lane]
		_h.expect(str(a.get("twin_group_id", "")) == group and str(b.get("twin_group_id", "")) == group,
			"twin_group", "lane %d groups %s / %s" % [lane, str(a.get("twin_group_id")), str(b.get("twin_group_id"))])
		_h.expect(int(a.get("twin_member_index", -1)) == 0 and int(b.get("twin_member_index", -1)) == 1,
			"twin_index", "lane %d member indexes" % lane)
		_h.expect(str(a.uid) != str(b.uid), "twin_uid", "lane %d twins share a uid" % lane)
		_h.expect(str(b.get("def", {}).get("element", "")) == str(twin.get("twin_second_element", "")),
			"twin_element", "lane %d second twin element %s" % [lane, str(b.get("def", {}).get("element", ""))])
		var center: float = BattleSimShared.TEAM_LANE_CENTERS[lane]
		_h.expect(absf(float(a.pos.x) - center) <= 70.0 and absf(float(b.pos.x) - center) <= 70.0
				and float(a.pos.x) < float(b.pos.x), "twin_in_lane", "lane %d x %.0f / %.0f" % [lane, a.pos.x, b.pos.x])
		_h.expect(BattleSimulator._is_boss_fighter(a) and BattleSimulator._is_boss_fighter(b), "twin_is_boss", "lane %d" % lane)
	var single := _lane(other, 1)
	_h.expect(single.size() == 1 and str((single[0] as Dictionary).uid) == "enemy_L1_boss"
			and not (single[0] as Dictionary).has("twin_group_id"), "single_boss", "non-twin boss spawn changed")


func _check_revive_with_partner(twin: Dictionary) -> void:
	var killer := _killer()
	var enemies := _lane(twin, 0)
	var st := _state([killer], enemies)
	var victim: Dictionary = enemies[0]
	_kill(victim, killer, st)
	_h.expect((st.revive_queue as Array).size() == 1, "revive_queued", "queue %d" % (st.revive_queue as Array).size())
	st.elapsed = float(twin.get("revive_delay", 5.0)) + 0.1
	BattleSimTreasures._process_revives(st)
	_h.expect(_alive_in_group(st, "%s_L0" % TWIN_ID) == 2, "revived", "alive in group after revive: %d" % _alive_in_group(st, "%s_L0" % TWIN_ID))


func _check_no_revive_across_lanes(twin: Dictionary) -> void:
	var killer := _killer()
	var lane0 := _lane(twin, 0)
	var lane2 := _lane(twin, 2)
	var st := _state([killer], lane0 + lane2)
	_kill(lane0[1], killer, st)
	_kill(lane0[0], killer, st)
	st.elapsed = float(twin.get("revive_delay", 5.0)) + 0.1
	BattleSimTreasures._process_revives(st)
	_h.expect(_alive_in_group(st, "%s_L0" % TWIN_ID) == 0, "no_cross_lane_revive",
		"lane 0 revived although both lane-0 twins died (lane 2 alive: %d)" % _alive_in_group(st, "%s_L2" % TWIN_ID))
	_h.expect(_alive_in_group(st, "%s_L2" % TWIN_ID) == 2, "other_lane_untouched", "lane 2 twins affected")


func _check_roster(twin: Dictionary) -> void:
	var st := _state([_killer()], _lane(twin, 0))
	var roster := {}
	BattleSimulator._replay_capture_roster(st, roster)
	var twin_entries := 0
	var leaked := 0
	for uid in roster:
		var r: Dictionary = roster[uid]
		if str(r.get("team", "")) == "enemy":
			if str(r.get("twin_group_id", "")) == "%s_L0" % TWIN_ID and r.has("twin_member_index"):
				twin_entries += 1
		elif r.has("twin_group_id"):
			leaked += 1
	_h.expect(twin_entries == 2 and leaked == 0, "roster", "twin roster entries %d, non-twin with field %d" % [twin_entries, leaked])
