extends Node

# headless 整局 AI 对战台（2026-11-07，五档难度的量尺）。
#
# 六个座位全是 AI，按战斗服务器同一套规则从第 1 回合打到第 21 回合（或一队水晶归零）：
#   备战   每个座位 policy.prepare_round（和线上 LiveBotEconomy 调的同一个入口）
#   战斗   BattleSimulator.prepare_team_state + step_state，与 BattleReplayJob 相同：
#          PvP 只算一场、B 队结果是 A 的副本；PvE / Boss 两队各算一场
#   结算   stamp_team_round_damages → TeamOutcome → 水晶扣血 / 回血（同 NetworkService
#          _publish 那段）→ policy.settle_round（金币、宝藏）
# 不抓回放帧、不打包，只要结果。
#
# 用法（参数放在 -- 之后）：
#   godot --headless --path . res://tools/ai_arena/ai_arena.tscn -- --a=L3 --b=legacy --seed=1000 --count=10 --out=user://arena.json
#   --a / --b    两队的策略：legacy（11-07 前的 AI，冻结基线）或 L1..L5
#   --swap=1     每个种子再交换两队打一遍，抵消座位先后的偏差（默认开）
# 并行跑大批量用 tools/ai_arena/run_arena.py。

const Legacy := preload("res://scripts/economy/ai/LegacyBotPlayer.gd")
const Bot := preload("res://scripts/economy/BotPlayer.gd")
const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")
const CarrotRules := preload("res://scripts/economy/CarrotEconomy.gd")
const Profile := preload("res://scripts/economy/ai/BotProfile.gd")

const MAX_STEPS := 4000
const RACES := ["god", "dark", "undead", "human", "crimson"]


func _ready() -> void:
	DataRegistry.load_all()
	var args := _parse_args()
	var seed0 := int(args.get("seed", "1000"))
	var count := int(args.get("count", "2"))
	var label_a := str(args.get("a", "legacy"))
	var label_b := str(args.get("b", "legacy"))
	var swap := str(args.get("swap", "1")) == "1"
	# 调参（tools/ai_arena/tune.py）：--override=某个 json，形如 {"5": {...}}，只在这个进程里
	# 盖掉对应档位的参数，不动 data/ai/bot_profiles.json。
	var override_path := str(args.get("override", ""))
	if not override_path.is_empty():
		_apply_override(override_path)
	var matches: Array = []
	var started := Time.get_ticks_msec()
	for i in count:
		var seed_value := seed0 + i
		matches.append(_play_match(seed_value, label_a, label_b))
		if swap:
			matches.append(_play_match(seed_value, label_b, label_a))
	var report := {"schema": 1, "a": label_a, "b": label_b, "seed": seed0, "count": count,
		"swap": swap, "wall_sec": (Time.get_ticks_msec() - started) / 1000.0, "matches": matches}
	_print_summary(report)
	var out := str(args.get("out", ""))
	if not out.is_empty():
		var file := FileAccess.open(out, FileAccess.WRITE)
		if file == null:
			push_error("[arena] 写不了 %s" % out)
			get_tree().quit(2)
			return
		file.store_string(JSON.stringify(report))
		file.close()
		print("[arena] report=%s" % ProjectSettings.globalize_path(out))
	get_tree().quit(0)


func _apply_override(path: String) -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[arena] 读不了覆盖文件 %s" % path)
		get_tree().quit(2)
		return
	var levels: Dictionary = Profile.table().get("levels", {})
	for level in parsed:
		var row: Dictionary = levels.get(str(level), {})
		row.merge(parsed[level], true)
		levels[str(level)] = row
	Profile._cache.clear()
	Profile._cache_source = null
	print("[arena] override %s levels=%s" % [path, str((parsed as Dictionary).keys())])


func _parse_args() -> Dictionary:
	var out := {}
	for raw in OS.get_cmdline_user_args():
		var arg := str(raw)
		if arg.begins_with("--") and arg.contains("="):
			var parts := arg.substr(2).split("=", true, 1)
			out[parts[0]] = parts[1]
	return out


func _policy(label: String) -> Dictionary:
	if label == "legacy":
		return {"label": label, "script": Legacy, "level": 0}
	if label.begins_with("L") and label.substr(1).is_valid_int():
		return {"label": label, "script": Bot, "level": clampi(int(label.substr(1)), 1, 5)}
	push_error("[arena] 不认识的策略 %s" % label)
	return {"label": "legacy", "script": Legacy, "level": 0}


# 一整局。label_a 坐 A 队（座位 0-2），label_b 坐 B 队（3-5）。
func _play_match(seed_value: int, label_a: String, label_b: String) -> Dictionary:
	var started := Time.get_ticks_usec()
	GameState.reset_run()
	var policies: Array = []
	var bots := {}
	# 升级石仓库每队一份，三个座位共用同一个 Dictionary（线上 _room_team_stones 也是引用）。
	var stones := [CarrotRules.empty_stones(), CarrotRules.empty_stones()]
	for slot in 6:
		var team := GameConstants.team_of_slot(slot)
		var policy := _policy(label_a if team == 0 else label_b)
		policies.append(policy)
		var bot: Dictionary = policy.script.new_state(seed_value, slot)
		if int(policy.level) > 0:
			bot["ai_level"] = int(policy.level)
		bot["ruleset"] = "normal"
		bot["final_round"] = 21
		bot["server_treasures"] = false   # 宝藏由 settle_round 自己 3 选 1
		bot["stones"] = stones[team]
		bots[slot] = bot
	var team_hp := [GameState.START_FORMATION_HP, GameState.START_FORMATION_HP]
	var loss_streak := [0, 0]
	var pve_completed := 0
	var boss_completed := 0
	var rounds: Array = []
	var outcome := -1
	var final_round := 21
	var completed := 0
	var prep_us := [0, 0, 0, 0, 0, 0]
	var prep_max_us := [0, 0, 0, 0, 0, 0]
	for round_index in range(1, final_round + 1):
		var battle_seed := absi(hash(["glory_ai_arena", seed_value, round_index]))
		var boards := {}
		var unspent := []
		for slot in 6:
			var bot: Dictionary = bots[slot]
			bot["stones"] = stones[GameConstants.team_of_slot(slot)]
			var t0 := Time.get_ticks_usec()
			policies[slot].script.prepare_round(bot, round_index)
			var spent := Time.get_ticks_usec() - t0
			prep_us[slot] += spent
			prep_max_us[slot] = maxi(prep_max_us[slot], spent)
			var view: Dictionary = policies[slot].script.view(bot)
			unspent.append(int(view.get("gold", 0)))
			boards[slot] = {"version": NetProtocol.SNAPSHOT_VERSION, "round": round_index,
				"board": view.board, "mercenaries": view.mercs, "treasures": view.treasures,
				"syn": view.syn, "pet": "", "gold": int(view.get("gold", 0))}
		_set_globals(round_index, battle_seed, boards, team_hp, pve_completed, boss_completed)
		var res_a := _run_battle(0)
		var kind := str(res_a.get("kind", "pve"))
		var rep_a := {"kind": kind, "result": res_a}
		var rep_b: Dictionary
		if kind == "pvp":
			rep_b = {"kind": kind, "result": res_a.duplicate(true)}
		else:
			rep_b = {"kind": kind, "result": _run_battle(1)}
		BattleSim.stamp_team_round_damages(rep_a, rep_b)
		var ra: Dictionary = rep_a.result
		var rb: Dictionary = rep_b.result
		var team_wins := [TeamOutcome.team_wins_battle(ra, rb, kind, TeamOutcome.TEAM_A),
			TeamOutcome.team_wins_battle(ra, rb, kind, TeamOutcome.TEAM_B)]
		for t in 2:
			loss_streak[t] = 0 if team_wins[t] else int(loss_streak[t]) + 1
		# 金色祭坛：没用过祭坛的持有者每回合给本队 +1（AI 从不主动用祭坛）。
		var altar := [0, 0]
		for slot in 6:
			if (bots[slot].treasures as Array).has("money_golden_altar"):
				altar[GameConstants.team_of_slot(slot)] += 1
		var hp_a := maxi(0, int(team_hp[0]) - maxi(0, int(ra.get("team_damage_self", 0))))
		var hp_b := maxi(0, int(team_hp[1]) - maxi(0, int(ra.get("team_damage_rival", 0))))
		if hp_a > 0:
			hp_a = mini(GameState.START_FORMATION_HP, hp_a + maxi(0, int(ra.get("team_heal_self", 0)) + altar[0]))
		if hp_b > 0:
			hp_b = mini(GameState.START_FORMATION_HP, hp_b + maxi(0, int(ra.get("team_heal_rival", 0)) + altar[1]))
		team_hp = [hp_a, hp_b]
		if kind == "pve":
			pve_completed += 1
		elif kind == "boss":
			boss_completed += 1
		for slot in 6:
			var team := GameConstants.team_of_slot(slot)
			var ctx := {"kind": kind, "player_wins": bool(team_wins[team]), "round_index": round_index}
			policies[slot].script.settle_round(bots[slot], ra if team == 0 else rb, ctx)
		rounds.append({"r": round_index, "kind": kind, "win": team_wins.duplicate(),
			"hp": team_hp.duplicate(), "unspent": unspent})
		completed = round_index
		if hp_a <= 0 or hp_b <= 0 or round_index >= final_round:
			outcome = TeamOutcome.run_outcome({"completed_round": round_index, "final_round": final_round,
				"hp_a": hp_a, "hp_b": hp_b, "kind": kind,
				"battle_a_wins": bool(ra.get("player_wins", false)),
				"battle_is_draw": bool(ra.get("is_draw", false))})
			break
	var seats: Array = []
	for slot in 6:
		var stats := _seat_stats(bots[slot], policies[slot], rounds, slot)
		stats["prep_ms_total"] = prep_us[slot] / 1000.0
		stats["prep_ms_max"] = prep_max_us[slot] / 1000.0
		seats.append(stats)
	return {"seed": seed_value, "a": label_a, "b": label_b, "outcome": outcome,
		"winner": label_a if outcome == TeamOutcome.TEAM_A else (label_b if outcome == TeamOutcome.TEAM_B else "draw"),
		"rounds_played": completed, "hp": team_hp, "rounds": rounds, "seats": seats,
		"wall_ms": (Time.get_ticks_usec() - started) / 1000.0}


func _set_globals(round_index: int, battle_seed: int, boards: Dictionary, team_hp: Array,
		pve_completed: int, boss_completed: int) -> void:
	var states := ["player", "player", "player", "player", "player", "player"]
	GameState.team_mode = true
	GameState.team_slot_states = states.duplicate()
	GameState.round_index = round_index
	GameState.FINAL_ROUND = 21
	GameState.pve_completed = pve_completed
	GameState.boss_completed = boss_completed
	GameState.final_round_played = false
	GameState.team_hp = int(team_hp[0])
	GameState.enemy_team_hp = int(team_hp[1])
	GameState.owned_treasures = []
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.team_slot_states = states.duplicate()
	NetworkService.team_boards = boards
	NetworkService.shared_seed = battle_seed
	NetworkService.team_bot_states = {}


func _run_battle(team: int) -> Dictionary:
	var state := BattleSim.prepare_team_state(team)
	var steps := 0
	while not bool(state.get("finished", false)) and steps < MAX_STEPS:
		BattleSim.step_state(state)
		steps += 1
	var result := BattleSim.result_from_state(state)
	result["kind"] = str(state.get("kind", result.get("kind", "pve")))
	return result


func _seat_stats(bot: Dictionary, policy: Dictionary, rounds: Array, slot: int) -> Dictionary:
	var stars := {1: 0, 2: 0, 3: 0, 4: 0}
	for unit in bot.roster:
		stars[int(unit.star)] = int(stars.get(int(unit.star), 0)) + 1
	var view: Dictionary = policy.script.view(bot)
	var counts := {}
	for cell in view.board:
		if cell is Dictionary:
			var race := str((cell.def as Dictionary).get("race", ""))
			counts[race] = int(counts.get(race, 0)) + 1
	var top_race := 0
	for race in counts:
		top_race = maxi(top_race, int(counts[race]))
	var last: Dictionary = rounds.back() if not rounds.is_empty() else {}
	return {"slot": slot, "policy": str(policy.label), "gold": int(bot.gold),
		"unspent_last_prep": int((last.get("unspent", []) as Array)[slot]) if not last.is_empty() else 0,
		"stone_draws": int(bot.get("stone_draws", 0)), "carrot_spent": int(bot.get("carrot_spent", 0)),
		"tech": int(bot.get("tech", 0)), "stars": stars, "top_race_on_board": top_race,
		"board_units": counts.values().reduce(func(a, b): return a + b, 0),
		"treasures": (bot.treasures as Array).size(), "treasure_ids": (bot.treasures as Array).duplicate(),
		# 金钱套（4 件金钱宝藏）+ 手上金币 → 开场血攻最多 +100%（每 1000 金 +10%）。
		"money_set": TreasureService.has_set_in(bot.treasures, "money")}


func _print_summary(report: Dictionary) -> void:
	var wins := {}
	var draws := 0
	var stones := {}
	var fours := {}
	var unspent := {}
	var prep_max := {}
	var prep_total := {}
	var seat_count := {}
	for match in report.matches:
		if str(match.winner) == "draw":
			draws += 1
		else:
			wins[match.winner] = int(wins.get(match.winner, 0)) + 1
		for seat in match.seats:
			var p := str(seat.policy)
			seat_count[p] = int(seat_count.get(p, 0)) + 1
			stones[p] = int(stones.get(p, 0)) + int(seat.stone_draws)
			fours[p] = int(fours.get(p, 0)) + int((seat.stars as Dictionary).get(4, 0))
			unspent[p] = int(unspent.get(p, 0)) + int(seat.unspent_last_prep)
			prep_max[p] = maxf(float(prep_max.get(p, 0.0)), float(seat.get("prep_ms_max", 0.0)))
			prep_total[p] = float(prep_total.get(p, 0.0)) + float(seat.get("prep_ms_total", 0.0))
	var total: int = (report.matches as Array).size()
	print("[arena] %s vs %s  matches=%d  wall=%.1fs (%.1fs/match)" % [report.a, report.b, total,
		float(report.wall_sec), float(report.wall_sec) / maxf(1.0, total)])
	for p in seat_count:
		print("[arena]   %-7s wins=%d/%d  stones/seat=%.2f  4star/seat=%.2f  unspent_last_prep/seat=%.0f  prep_ms/seat-match=%.0f max_round_ms=%.1f" % [p,
			int(wins.get(p, 0)), total, float(stones[p]) / seat_count[p], float(fours[p]) / seat_count[p],
			float(unspent[p]) / seat_count[p], float(prep_total[p]) / seat_count[p], float(prep_max[p])])
	print("[arena]   draws=%d" % draws)
