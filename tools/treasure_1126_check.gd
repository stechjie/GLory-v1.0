extends Node

# 11.26 宝藏调整（用户定）：
#   · 铁壁之护：开战防御 +10 → 防御 +15、魔抗 +20；
#   · 法阵回春：每位持有人 胜 / 平 +1、败 +2 → 胜 / 平 +2、败 +3；
#   · 打断锁链：缴械 1.5 → 2 秒。

const Harness := preload("res://tools/CheckHarness.gd")

var _h


func _ready() -> void:
	_h = Harness.new("treasure_1126")
	DataRegistry.load_all()

	# 铁壁之护：有魔抗的各加各的；没填魔抗的按加成前的防御取底。
	var with_mres := _unit({"defense": 12, "mres": 8}, ["def_iron_wall"])
	var no_mres := _unit({"defense": 12}, ["def_iron_wall"])
	var merc := _unit({"defense": 12, "mres": 8, "is_mercenary": true}, ["def_iron_wall"])
	var plain := _unit({"defense": 12, "mres": 8}, [])
	var log: Array[String] = []
	BattleSimTreasures._apply_opening_treasures([with_mres, no_mres, merc, plain], log)
	_h.expect(int(with_mres.defense) == 27 and int(with_mres.mres) == 28, "iron_wall_values",
		"防御 12 → 27、魔抗 8 → 28，实际 %d / %d" % [int(with_mres.defense), int(with_mres.mres)])
	_h.expect(int(no_mres.defense) == 27 and int(no_mres.mres) == 32, "iron_wall_mres_fallback",
		"没填魔抗的按原防御 12 取底再 +20 = 32，实际 %d" % int(no_mres.get("mres", -1)))
	_h.expect(int(merc.defense) == 12 and int(merc.mres) == 8, "iron_wall_no_merc", "佣兵不吃宝藏")
	_h.expect(int(plain.defense) == 12 and int(plain.mres) == 8, "iron_wall_needs_treasure", "没有铁壁之护的不变")
	DamageService.set_stat_state({"player": [with_mres], "enemy": [], "elapsed": 5.0, "kind": "pve", "unit_stats": {}})
	_h.expect(DamageService.effective_magic_resist(with_mres) == 28, "iron_wall_effective_mres", "结算时读到的魔抗是 28")

	# 法阵回春：一位持有人。A 胜 B 败（PvP）→ A +2、B +3；平局都 +2；两位持有人翻倍。
	_h.expect(BattleSimulator.FORMATION_HEAL_WIN == 2 and BattleSimulator.FORMATION_HEAL_LOSS == 3, "formation_heal_values", "法阵回春应为胜 +2、败 +3")
	var heal := _stamp("pvp", true, false, 1, 1)
	_h.expect(heal == [2, 3], "formation_heal_pvp", "PvP：胜方 +2、败方 +3，实际 %s" % str(heal))
	heal = _stamp("pvp", false, true, 1, 1)
	_h.expect(heal == [2, 2], "formation_heal_draw", "平局双方各 +2，实际 %s" % str(heal))
	heal = _stamp("pvp", false, false, 2, 0)
	_h.expect(heal == [6, 0], "formation_heal_two_holders", "败方两位持有人 +6、没人持有 +0，实际 %s" % str(heal))
	heal = _stamp("pve", true, false, 1, 1, false)
	_h.expect(heal == [2, 3], "formation_heal_pve", "打怪：A 赢 +2、B 输 +3，实际 %s" % str(heal))

	# 打断锁链：缴械 2 秒（概率和冷却不变）。触发带随机，直接钉源码里的那一行。
	var src := FileAccess.get_file_as_string("res://scripts/battle/BattleSimTreasures.gd")
	_h.expect(src.contains("StatusEffectService.interrupt(target, 2.0)") and not src.contains("StatusEffectService.interrupt(target, 1.5)"),
		"interrupt_chain_two_sec", "打断锁链缴械应为 2 秒")
	_h.expect(src.contains('_set_treasure_cd(attacker, "ctrl_interrupt_chain", float(state.elapsed), 3.0)'), "interrupt_chain_cd_kept", "打断锁链冷却仍是 3 秒")
	_h.finish(get_tree())


func _unit(extra: Dictionary, treasures: Array) -> Dictionary:
	var f := {"uid": "u%d" % randi(), "id": "dummy", "team": "player", "def": {"id": "dummy", "race": "human"}, "alive": true,
		"hp": 1000, "max_hp": 1000, "atk": 10, "shield": 0, "dodge": 0.0, "statuses": {}, "owner_treasures": treasures, "skill_ready": 0.0}
	f.merge(extra, true)
	return f


# 返回 [A 队回血, B 队回血]。holders_* 是各队持有法阵回春的人数。
func _stamp(kind: String, a_wins: bool, draw: bool, holders_a: int, holders_b: int, b_wins := false) -> Array:
	var replay_a := {"kind": kind, "result": {"player_wins": a_wins, "is_draw": draw, "player_alive": 2, "enemy_alive": 2,
		"team_heal_ally": holders_a, "team_heal_rival": holders_b}}
	var replay_b := {"kind": kind, "result": {"player_wins": b_wins, "is_draw": draw, "player_alive": 2, "enemy_alive": 2}}
	BattleSimulator.stamp_team_round_damages(replay_a, replay_b)
	return [int(replay_a.result.team_heal_self), int(replay_a.result.team_heal_rival)]
