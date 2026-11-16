extends Node

# 11.16 用户定：凤凰涅槃、双生守门人复活、亡魂反击、哀鸣共鸣，被技能 / AOE /
# 持续伤害打死也要触发（以前只挂在普攻致死入口 _on_unit_killed 上）。
# 补结算在 BattleSimulator._process_pending_kill_effects。本检查全部调用真实战斗代码。

const Harness := preload("res://tools/CheckHarness.gd")
const PHOENIX := ["atk_wail_resonance", "def_soul_counter"]

var _h


func _ready() -> void:
	_h = Harness.new("kill_effects_any_death")
	_probe_skill_kill()
	_probe_dot_death()
	_probe_attack_kill_not_doubled()
	_probe_revived_copy()
	_probe_twin_skill_kill()
	_probe_real_team_battles()
	GameState.reset_run()
	GameState.team_mode = false
	NetworkService.team_active = false
	NetworkService.team_boards = {}
	_h.finish(get_tree())


# --- helpers -----------------------------------------------------------------

func _def(id: String) -> Dictionary:
	return {"id": id, "name": id, "hp": 3000, "atk": 100, "def": 0,
		"attack_speed": 1.0, "range": 1, "move_speed": 3.0, "crit": 0.0, "crit_dmg": 1.0,
		"skill_id": "none", "tier": 1, "element": "-", "race": "human"}


func _fighter(uid: String, team: String, treasures: Array, pos: Vector2) -> Dictionary:
	var f: Dictionary = BattleSimShared._fighter_from_def(_def("probe_" + uid), 0, team, 0, 1, 1, false, false)
	f.uid = uid
	f["lane"] = 0
	f["owner_treasures"] = treasures.duplicate()
	f["owner_syn"] = {}
	f.pos = pos
	return f


func _state(player: Array, enemy: Array) -> Dictionary:
	var st := {
		"kind": "pvp", "player": player, "enemy": enemy, "elapsed": 0.0,
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


# 模拟「技能打死」：伤害来源记成 killer，但不走普攻的 _on_unit_killed。
func _skill_kill(state: Dictionary, killer: Dictionary, victim: Dictionary) -> void:
	DamageService.begin_stat_context(state, killer)
	DamageService.apply_damage(victim, int(victim.hp) + 9999, true)
	DamageService.clear_stat_context()


func _queued(state: Dictionary, prefix: String) -> int:
	var n := 0
	for item in state.get("revive_queue", []):
		if str((item.get("fighter", {}) as Dictionary).get("uid", "")).begins_with(prefix):
			n += 1
	return n


# --- probes ------------------------------------------------------------------

func _probe_skill_kill() -> void:
	var victim := _fighter("v", "player", PHOENIX, Vector2(400, 300))
	var killer := _fighter("k", "enemy", [], Vector2(430, 300))
	var st := _state([victim], [killer])
	_skill_kill(st, killer, victim)
	_h.expect(not bool(victim.alive) and str(victim.get("killer_uid", "")) == "k", "setup_skill_kill", "前置：技能致死要记下凶手")
	_h.expect(_queued(st, "v_phoenix_") == 0, "setup_not_yet", "前置：补扫前凤凰尚未排队（证明不是 apply_damage 自己触发的）")
	var killer_hp_before := int(killer.hp)
	BattleSimulator._process_pending_kill_effects(st)
	_h.expect(_queued(st, "v_phoenix_") == 1, "phoenix_skill_kill", "被技能打死：凤凰涅槃要排队复活")
	var expect_soul := int(round(float(killer.max_hp) * 0.35))
	_h.expect(killer_hp_before - int(killer.hp) == expect_soul, "soul_counter_skill_kill",
		"被技能打死：亡魂反击要对凶手造成最大生命 35%% 真伤（期望 %d，实际 %d）" % [expect_soul, killer_hp_before - int(killer.hp)])
	BattleSimulator._process_pending_kill_effects(st)
	_h.expect(_queued(st, "v_phoenix_") == 1, "sweep_idempotent", "补扫重复跑不能再排一次凤凰")

	# 哀鸣共鸣：凶手持有，技能击杀后 180 内敌人受 15% 最大生命真伤。
	var wailer := _fighter("w", "player", ["atk_wail_resonance"], Vector2(400, 300))
	var dead := _fighter("d", "enemy", [], Vector2(430, 300))
	var near := _fighter("n", "enemy", [], Vector2(480, 300))
	var far := _fighter("f", "enemy", [], Vector2(900, 300))
	var st2 := _state([wailer], [dead, near, far])
	_skill_kill(st2, wailer, dead)
	var near_before := int(near.hp)
	var far_before := int(far.hp)
	BattleSimulator._process_pending_kill_effects(st2)
	_h.expect(near_before - int(near.hp) == int(round(float(near.max_hp) * 0.15)), "wail_skill_kill", "技能击杀：哀鸣共鸣要伤到 180 内的敌人")
	_h.expect(far_before == int(far.hp), "wail_range", "哀鸣共鸣不能伤到 180 外的敌人")


func _probe_dot_death() -> void:
	var victim := _fighter("v", "player", PHOENIX, Vector2(400, 300))
	var other := _fighter("o", "enemy", [], Vector2(430, 300))
	var st := _state([victim], [other])
	DamageService.clear_stat_context()
	DamageService.apply_damage(victim, int(victim.hp) + 9999, true)
	var other_before := int(other.hp)
	BattleSimulator._process_pending_kill_effects(st)
	_h.expect(_queued(st, "v_phoenix_") == 1, "phoenix_dot", "无来源死亡（持续伤害）：凤凰也要复活")
	_h.expect(int(other.hp) == other_before, "soul_counter_no_killer", "无来源死亡：亡魂反击没有凶手，不能乱打别人")


func _probe_attack_kill_not_doubled() -> void:
	var victim := _fighter("v", "player", PHOENIX, Vector2(400, 300))
	var killer := _fighter("k", "enemy", [], Vector2(430, 300))
	var st := _state([victim], [killer])
	_skill_kill(st, killer, victim)
	BattleSimulator._on_unit_killed(killer, victim, st, st.enemy, st.player)
	var hp_after_attack_path := int(killer.hp)
	BattleSimulator._process_pending_kill_effects(st)
	_h.expect(_queued(st, "v_phoenix_") == 1, "attack_kill_single_phoenix", "普攻致死已结算过，补扫不能再排一次凤凰")
	_h.expect(int(killer.hp) == hp_after_attack_path, "attack_kill_single_soul", "普攻致死已结算过，亡魂反击不能打第二次")


func _probe_revived_copy() -> void:
	var victim := _fighter("v", "player", PHOENIX, Vector2(400, 300))
	var killer := _fighter("k", "enemy", [], Vector2(430, 300))
	var st := _state([victim], [killer])
	_skill_kill(st, killer, victim)
	BattleSimulator._process_pending_kill_effects(st)
	st.elapsed = 0.2
	BattleSimTreasures._process_revives(st)
	var copy: Dictionary = {}
	for f in st.player:
		if str(f.uid).begins_with("v_phoenix_"):
			copy = f
	_h.expect(not copy.is_empty() and bool(copy.get("alive", false)), "phoenix_copy_spawned", "凤凰复活体要真的回到场上")
	if copy.is_empty():
		return
	_h.expect(not copy.has("kill_effects_done"), "copy_flag_cleared", "复活体不能继承「已结算」标记，否则它再死时补扫会跳过")
	copy.statuses = {}
	var killer_before := int(killer.hp)
	_skill_kill(st, killer, copy)
	BattleSimulator._process_pending_kill_effects(st)
	_h.expect(_queued(st, "v_phoenix_") == 0, "copy_no_second_phoenix", "复活体再死不能再次凤凰（每枚每场 1 次）")
	_h.expect(killer_before - int(killer.hp) > 0, "copy_soul_counter", "复活体被技能打死时，亡魂反击照样生效")


func _probe_twin_skill_kill() -> void:
	var a := _fighter("ta", "enemy", [], Vector2(600, 300))
	var b := _fighter("tb", "enemy", [], Vector2(640, 300))
	for t in [a, b]:
		var d: Dictionary = (t.def as Dictionary).duplicate()
		d.skill_id = "twin_revive"
		d.revive_delay = 5.0
		t.def = d
		t.revives_left = 1
		t.twin_group_id = "g"
	a.twin_member_index = 0
	b.twin_member_index = 1
	var p := _fighter("p", "player", [], Vector2(400, 300))
	var st := _state([p], [a, b])
	_skill_kill(st, p, a)
	BattleSimulator._process_pending_kill_effects(st)
	_h.expect(_queued(st, "ta_revive_") == 1, "twin_skill_kill", "双生守门人被技能打死（同伴还活着）也要排队复活")


# 真实 3v3 流程（与 treasure_set_effect_check 同款搭建）：带凤凰的席位，
# 普通棋子的每一次「第一次死亡」都要复活，不论被什么打死。
func _team_state(seed_base: int, treasures: Array) -> Dictionary:
	GameState.reset_run()
	GameState.team_mode = true
	GameState.round_index = 10
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.shared_seed = seed_base
	NetworkService.team_slot_states = ["player", "player", "player", "player", "player", "player"]
	var boards: Dictionary = {}
	for slot in 6:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_base * 10 + slot
		var board := BattleSimShared.build_dummy_board(rng)
		boards[slot] = {"version": NetProtocol.SNAPSHOT_VERSION, "round": 10, "board": board,
			"mercenaries": [], "treasures": treasures.duplicate() if slot == 0 else [],
			"syn": NetProtocol.rebuild_syn_from_board(board), "pet": "", "gold": 0}
	NetworkService.team_boards = boards
	return BattleSimulator.prepare_team_state(0)


func _is_original_piece(f: Dictionary) -> bool:
	var uid := str(f.get("uid", ""))
	for tag in ["_phoenix_", "_mirror_", "_parasite_", "_revive_"]:
		if uid.contains(tag):
			return false
	return not bool(f.get("is_mercenary", false)) and not bool(f.get("is_formation_ally", false))


func _probe_real_team_battles() -> void:
	var deaths := 0
	var missed := 0
	for s in [5, 7, 12]:
		var st := _team_state(1000 + s * 7, PHOENIX)
		var seen := {}
		var guard := 0
		while not bool(st.get("finished", false)) and guard < 3000:
			guard += 1
			BattleSimulator.step_state(st)
			for f in st.player + st.enemy:
				if int(f.get("owner_slot", -1)) != 0 or bool(f.get("alive", true)) or not _is_original_piece(f):
					continue
				seen[str(f.uid)] = true
		for uid in seen.keys():
			deaths += 1
			var got := _queued(st, str(uid) + "_phoenix_") > 0
			for f in st.player + st.enemy:
				if str(f.get("uid", "")).begins_with(str(uid) + "_phoenix_"):
					got = true
			if not got:
				missed += 1
	# 这三个种子在修复前共有 7 次「被 Boss 技能打死、凤凰没发动」。
	_h.expect(deaths >= 5, "team_setup", "前置：3v3 样本要有足够死亡（实际 %d）" % deaths)
	_h.expect(missed == 0, "team_phoenix_all_deaths", "真实 3v3：%d 次死亡里 %d 次凤凰没发动" % [deaths, missed])
