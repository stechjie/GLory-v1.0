extends "res://tools/ai_arena/ai_arena.gd"
## 只读统计：六个 AI 打整局，记下每个座位每回合结束时伤害牌会显示的总数
## （口径同 BattleSimulator._replay_capture_frame：本座位棋子 damage_dealt（不含 Boss）+ 元素伤害），
## 用来核对 BattleCombatFeedback 的档位阈值够不够得着。不写游戏数据。
## 用法：godot --headless --path . res://tools/damage_tier_probe.tscn -- --levels=L1,L3,L5 --count=4 --seed=1000 --out=<绝对路径.json>
var _round := 0
var _rows: Array = []
var _level := ""
var _seed := 0

func _ready() -> void:
	DataRegistry.load_all()
	var args := _parse_args()
	var out := str(args.get("out", ""))
	if out.is_empty():
		push_error("damage_tier_probe requires --out")
		get_tree().quit(2)
		return
	for level in str(args.get("levels", "L1,L3,L5")).split(","):
		for n in int(args.get("count", "2")):
			_level = level
			_seed = int(args.get("seed", "1000")) + n
			var played := _play_match(_seed, level, level)
			print("TIER_PROBE %s seed=%d rounds=%d wall_ms=%d" % [level, _seed, int(played.rounds_played), int(played.wall_ms)])
	var file := FileAccess.open(out, FileAccess.WRITE)
	file.store_string(JSON.stringify({"rows": _rows, "balance_version": DataRegistry.get_table("final_status").get("balance_version", "")}))
	file.close()
	print("TIER_PROBE_OK rows=%d" % _rows.size())
	get_tree().quit(0)

func _set_globals(round_index: int, battle_seed: int, boards: Dictionary, team_hp: Array,
		pve_completed: int, boss_completed: int) -> void:
	_round = round_index
	super._set_globals(round_index, battle_seed, boards, team_hp, pve_completed, boss_completed)

func _run_battle(team: int) -> Dictionary:
	var state := BattleSim.prepare_team_state(team)
	var steps := 0
	while not bool(state.get("finished", false)) and steps < MAX_STEPS:
		BattleSim.step_state(state)
		steps += 1
	var result := BattleSim.result_from_state(state)
	result["kind"] = str(state.get("kind", result.get("kind", "pve")))
	var slot_damage: Array = [0, 0, 0, 0, 0, 0]
	var stats: Dictionary = state.get("unit_stats", {})
	for entry: Dictionary in stats.values():
		var slot := int(entry.get("owner_slot", -1))
		if slot < 0 and str(entry.get("team", "")) == "player":
			slot = 0
		if slot >= 0 and slot < 6 and str(entry.get("group", "")) != "boss":
			slot_damage[slot] += maxi(0, int(entry.get("damage_dealt", 0)))
	var elemental: Dictionary = state.get("element_damage_by_slot", {})
	for slot in range(6):
		slot_damage[slot] += maxi(0, int(elemental.get(slot, elemental.get(str(slot), 0))))
	_rows.append({"level": _level, "seed": _seed, "round": _round, "kind": result.kind, "team": team,
		"elapsed": float(result.get("elapsed", 0.0)), "slot_damage": slot_damage})
	return result
