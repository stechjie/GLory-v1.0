extends "res://tools/ai_arena/ai_arena.gd"

# 审计用，不写任何游戏数据。五个种族的纯种族阵容两两对打，看当前数值下谁强谁弱。
#
# 每个种族 8 枚棋子、棋盘上限 7 枚，所以每族出两套阵容：分别去掉两枚 1 费棋子中的一枚。
# 三条路都摆同一套阵容，站位用 AI 的 BotFormation（role 模式），羁绊按棋盘重算（7 枚同族全开）。
# 不带宝藏、佣兵、宠物、成长；星级和回合：1★ 第 6 回合、2★ 第 12 回合、3★ 第 18 回合（都是对战回合）。
# 每组对阵换边各打一遍，抵消先后手偏差。
#
# 用法：godot --headless --path . res://tools/race_matchup_probe.tscn -- --seeds=4 --out=<绝对路径.json>

const Formation := preload("res://scripts/economy/ai/BotFormation.gd")

const STAGES := [[1, 6], [2, 12], [3, 18]]


func _ready() -> void:
	DataRegistry.load_all()
	var args := _parse_args()
	var seeds := int(args.get("seeds", "4"))
	# 对照实验（只改内存里的表，不写文件）：
	#   --scythe_old=1  偷袭者换回 11-18 之前的机制（5 秒冷却、击杀刷新、开场等冷却）
	#   --only=dark     只跑涉及该种族的对阵
	if str(args.get("scythe_old", "0")) == "1":
		for unit: Dictionary in DataRegistry.get_table("race_units").get("units", []):
			if str(unit.get("id", "")) == "dark_scythe":
				unit.erase("recast_on_target_death")
				unit.erase("skill_global")
				unit["refresh_on_kill"] = true
	#   --stars=2       只跑某个星级（逗号分隔）
	#   --mods=<json>   假设性调整，只改内存：{"units": {"god_king": {"damage_atk_pct": 2.4}, "race:god": {"hp": "*1.2"}},
	#                   "syn": {"god": {"god_lifesteal": 0.4}}}；数值写成 "*1.2" 表示在原值上乘。
	var mods_path := str(args.get("mods", ""))
	if not mods_path.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(mods_path))
		if not parsed is Dictionary:
			push_error("bad mods file")
			get_tree().quit(2)
			return
		_syn_patch = (parsed as Dictionary).get("syn", {})
		var unit_mods: Dictionary = (parsed as Dictionary).get("units", {})
		for unit: Dictionary in DataRegistry.get_table("race_units").get("units", []):
			for key: String in unit_mods:
				if key != str(unit.get("id", "")) and key != "race:" + str(unit.get("race", "")):
					continue
				var fields: Dictionary = unit_mods[key]
				for field: String in fields:
					var value: Variant = fields[field]
					if value is String and (value as String).begins_with("*"):
						var scaled := float(unit.get(field, 0)) * float((value as String).substr(1))
						unit[field] = int(round(scaled)) if typeof(unit.get(field, 0)) == TYPE_INT else scaled
					else:
						unit[field] = value
	var star_filter: Array = []
	for token in str(args.get("stars", "")).split(",", false):
		star_filter.append(int(token))
	var only := str(args.get("only", ""))
	var by_race := {}
	for unit: Dictionary in DataRegistry.get_table("race_units").get("units", []):
		var race := str(unit.get("race", ""))
		if not by_race.has(race):
			by_race[race] = []
		(by_race[race] as Array).append(unit)
	var lineups: Array = []
	for race in RACES:
		var units: Array = by_race.get(race, [])
		var cheap: Array = units.filter(func(u): return int(u.get("tier", 1)) == 1)
		for drop: Dictionary in cheap:
			var ids: Array = []
			for u: Dictionary in units:
				if str(u.id) != str(drop.id):
					ids.append(str(u.id))
			lineups.append({"race": race, "drop": str(drop.id), "ids": ids, "label": "%s(-%s)" % [race, str(drop.get("name", drop.id))]})
	var records: Array = []
	var started := Time.get_ticks_msec()
	for stage in STAGES:
		var star := int(stage[0])
		var round_index := int(stage[1])
		if not star_filter.is_empty() and not star_filter.has(star):
			continue
		for i in lineups.size():
			for j in lineups.size():
				if i == j or str(lineups[i].race) == str(lineups[j].race):
					continue
				if not only.is_empty() and str(lineups[i].race) != only and str(lineups[j].race) != only:
					continue
				# i 在 A 队（下方），j 在 B 队；(j, i) 那一轮就是换边。
				for s0 in seeds:
					var s := s0 + int(args.get("seed0", "0"))
					var battle_seed := absi(hash(["race_matchup", star, i, j, s]))
					var boards := {}
					for slot in 6:
						var lineup: Dictionary = lineups[i] if slot < 3 else lineups[j]
						boards[slot] = _board_snapshot(lineup.ids, star, round_index, str(lineup.race))
					_set_globals(round_index, battle_seed, boards, [50, 50], 0, 0)
					var result := _run_battle(0)
					var outcome := "draw" if bool(result.get("is_draw", false)) else ("a" if bool(result.get("player_wins", false)) else "b")
					# 每枚棋子的输出 / 承伤 / 治疗，按 队伍:棋子 汇总（三条路相加）。
					var units := {}
					var stats: Dictionary = result.get("unit_stats", {})
					for uid in stats:
						var st: Dictionary = stats[uid]
						var key := "%s:%s" % ["a" if str(st.get("team", "")) == "player" else "b", str(st.get("id", ""))]
						var entry: Array = units.get(key, [0, 0, 0])
						entry[0] += int(st.get("damage_dealt", 0))
						entry[1] += int(st.get("damage_taken", 0))
						entry[2] += int(st.get("healing_done", 0))
						units[key] = entry
					records.append({"star": star, "a": i, "b": j, "seed": s, "outcome": outcome, "kind": str(result.get("kind", "")),
						"elapsed": float(result.get("elapsed", 0.0)), "a_alive": int(result.get("player_alive", 0)),
						"b_alive": int(result.get("enemy_alive", 0)), "units": units})
		print("RACE_PROBE stage star=%d done records=%d sec=%.1f" % [star, records.size(), (Time.get_ticks_msec() - started) / 1000.0])
	var out := str(args.get("out", ""))
	if not out.is_empty():
		var file := FileAccess.open(out, FileAccess.WRITE)
		file.store_string(JSON.stringify({"lineups": lineups, "records": records}))
		file.close()
	print("RACE_PROBE_DONE records=%d" % records.size())
	get_tree().quit(0)


var _syn_patch: Dictionary = {}


func _board_snapshot(ids: Array, star: int, round_index: int, race: String = "") -> Dictionary:
	var defs := {}
	for unit: Dictionary in DataRegistry.get_table("race_units").get("units", []):
		defs[str(unit.id)] = unit
	var units: Array = []
	for id in ids:
		units.append({"def": defs[str(id)], "star": star, "id": str(id)})
	var board: Array = []
	board.resize(GameConstants.CELL_COUNT)
	for pair in Formation.arrange(units, "role"):
		var u: Dictionary = pair[0]
		board[int(pair[1])] = {"id": str(u.id), "uid": "", "star": star, "def": (u.def as Dictionary).duplicate(true), "is_mercenary": false}
	var syn := NetProtocol.rebuild_syn_from_board(board)
	var patch: Dictionary = _syn_patch.get(race, {})
	for key in patch:
		syn[key] = patch[key]
	return {"version": NetProtocol.SNAPSHOT_VERSION, "round": round_index, "board": board,
		"mercenaries": [], "treasures": [], "syn": syn, "pet": "", "gold": 0}
