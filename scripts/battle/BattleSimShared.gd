class_name BattleSimShared
extends RefCounted

const DECAY_START_SEC := 10.0
const DECAY_INTERVAL_SEC := 6.0
const HARD_TIMEOUT_SEC := 180.0
const TICK_SEC := 0.1
const ARENA_W := 1000.0
const ARENA_H := 520.0
const CELL_SPACING := 72.0
const ATTACK_RANGE_SCALE := 72.0
# Tolerance so a unit sitting exactly on the edge of its attack range counts as
# "in range" and attacks, instead of jittering sub-pixel forever due to float
# error in distance_to (which would freeze it just outside range).
const ATTACK_RANGE_EPS := 1.0
const TEAM_LANE_CENTERS := [230.0, 500.0, 770.0]
const OPENING_DISTANCE_PUSH := 58.0


static func _opening_y(team: String, y: float) -> float:
	return y + OPENING_DISTANCE_PUSH if team == "player" else y - OPENING_DISTANCE_PUSH


static func _count_units(board: Array) -> int:
	var c := 0
	for cell in board:
		if cell != null and typeof(cell) == TYPE_DICTIONARY:
			c += 1
	return c


static func _place_in_lane(f: Dictionary, slot: int, team: String, lane: int) -> void:
	var col := slot % GameConstants.BOARD_COLUMNS
	var row := floori(float(slot) / float(GameConstants.BOARD_COLUMNS))
	var lane_x: float = TEAM_LANE_CENTERS[lane] + (float(col) - 1.5) * 24.0
	var y := _opening_y(team, 300.0 + float(row) * 40.0 if team == "player" else 220.0 - float(row) * 40.0)
	f.pos = Vector2(clampf(lane_x, 80.0, ARENA_W - 80.0), clampf(y, 60.0, ARENA_H - 60.0))
	f["lane"] = lane


static func _append_lane_board_fighters(out: Array, board: Array, team: String, lane: int, owner_treasures: Array = [], owner_syn: Dictionary = {}, owner_slot: int = -1, owner_pet: String = "") -> void:
	for i in board.size():
		var cell = board[i]
		if cell == null or typeof(cell) != TYPE_DICTIONARY:
			continue
		var f := _fighter_from_cell(cell, i, team)
		_place_in_lane(f, i, team, lane)
		f.uid = "%s_L%d_%d" % [team, lane, i]
		f["owner_treasures"] = owner_treasures
		f["owner_syn"] = owner_syn
		f["owner_slot"] = owner_slot
		f["owner_pet"] = owner_pet
		out.append(f)

# Per-fighter owner context (3v3): treasures/synergies come from the unit's
# owner, not the local GameState. Helpers used by the combat code below.

static func _f_treasures(f: Dictionary) -> Array:
	# Team units carry their owner's list; 1v1 player units fall back to GameState.
	if f.has("owner_treasures"):
		return f.get("owner_treasures", [])
	if str(f.get("team", "")) == "player":
		return GameState.owned_treasures
	return []


static func _f_has_treasure(f: Dictionary, tid: String) -> bool:
	return tid in _f_treasures(f)


static func _f_pet(f: Dictionary) -> String:
	# Team units carry their owner's active pet; 1v1 player units fall back to the
	# local account profile. Enemy units in 1v1 have no owner_pet → no bonus.
	if f.has("owner_pet"):
		return str(f.get("owner_pet", ""))
	if str(f.get("team", "")) == "player":
		return PlayerProfile.get_active()
	return ""


static func _f_has_set(f: Dictionary, category: String) -> bool:
	return TreasureService.has_set_in(_f_treasures(f), category)


static func _f_has_linkage(f: Dictionary, link_id: String) -> bool:
	return TreasureService.has_linkage_in(_f_treasures(f), link_id)


static func _resolve_syn(f: Dictionary, state: Dictionary) -> Dictionary:
	if f.has("owner_syn"):
		return f.get("owner_syn", {})
	if str(f.get("team", "")) == "player":
		return state.get("player_syn", {})
	return state.get("enemy_syn", {})


static func _f_syn(f: Dictionary) -> Dictionary:
	return f.get("owner_syn", {})


static func _team_syn(state: Dictionary, team: String) -> Dictionary:
	# 1v1 per-team synergy flags (player_syn / enemy_syn).
	return state.get("player_syn", {}) if team == "player" else state.get("enemy_syn", {})

# Per-owner synergy bookkeeping: each player's board (team+lane) tracks its own
# counters (dark stacks, death counts, mother counter, last-stand flag).

static func _owner_key(f: Dictionary) -> String:
	return "%s_%d" % [str(f.get("team", "")), int(f.get("lane", -1))]


static func _owner_state(state: Dictionary, key: String) -> Dictionary:
	var os: Dictionary = state.get("owner_state", {})
	if not os.has(key):
		os[key] = {"dark_enemy_deaths": 0, "dark_stacks": 0, "undead_deaths": 0, "mother_count": 0, "last_stand_used": false}
		state.owner_state = os
	return os[key]


static func _owner_syn(state: Dictionary, key: String) -> Dictionary:
	return state.get("owner_syn_by_key", {}).get(key, {})


static func _attacker_dark_stacks(attacker: Dictionary, state: Dictionary) -> int:
	if state.has("owner_syn_by_key"):
		return int(_owner_state(state, _owner_key(attacker)).get("dark_stacks", 0))
	if str(attacker.get("team", "")) == "enemy":
		return int(state.get("enemy_dark_kill_stacks", 0))
	return int(state.get("dark_kill_stacks", 0))

# Has the owner cleared the enemies in their own lane? (used by effects 1 & 4)

static func _owner_lane_enemies_cleared(state: Dictionary, owner_team: String, lane: int) -> bool:
	var enemy_side: Array = state.get("enemy", []) if owner_team == "player" else state.get("player", [])
	for o in enemy_side:
		if bool(o.get("alive", false)) and int(o.get("lane", -1)) == lane:
			return false
	return true


static func _team_owner_ctx_for_slot(slot_idx: int) -> Dictionary:
	if NetworkService.team_active:
		if _team_slot_state(slot_idx) == "player":
			var snap = NetworkService.team_boards.get(slot_idx, {})
			if snap is Dictionary and not (snap as Dictionary).is_empty():
				return {"treasures": NetProtocol.extract_treasures(snap), "syn": NetProtocol.extract_syn(snap), "pet": NetProtocol.extract_pet(snap)}
		return {"treasures": [], "syn": {}, "pet": ""}
	if slot_idx == 0:
		return {"treasures": GameState.owned_treasures.duplicate(), "syn": SynergyService.current_player_flags(), "pet": PlayerProfile.get_active()}
	return {"treasures": [], "syn": {}, "pet": ""}


static func _round_pick_index(size: int, salt: String, round_index: int = -1) -> int:
	# Deterministic per-match pick so all lanes/players agree, but new rooms vary.
	# round_index < 0 表示"当前回合"；显式传值是为了让备战期能预摇未来回合的内容
	# （见 round_enemy_model_paths）——这一步只依赖 shared_seed + 回合号，
	# 所以未来回合会出什么怪在开局那一刻就已经确定了。
	if size <= 0:
		return 0
	var rn := round_index if round_index >= 0 else GameState.round_index
	var r := RandomNumberGenerator.new()
	r.seed = hash([NetworkService.shared_seed, rn, salt])
	return r.randi_range(0, size - 1)


static func _round_monster_template(round_index: int = -1) -> Dictionary:
	var monsters: Array = DataRegistry.get_table("pve_monsters").get("monsters", [])
	if monsters.is_empty():
		return {}
	return monsters[_round_pick_index(monsters.size(), "monster", round_index)]


static func _round_boss_template(round_index: int = -1) -> Dictionary:
	var bosses: Array = DataRegistry.get_table("bosses").get("bosses", [])
	if bosses.is_empty():
		return {}
	return bosses[_round_pick_index(bosses.size(), "boss", round_index)]


# 某个未来回合会出现的敌方模型路径。备战期拿它来提前加载，避免开打那一帧同步读盘。
#
# PVP / final 回合返回空：对手棋盘取决于他买了什么，开局无法预知。
# 这不影响价值 —— 大多数回合是 PVE / Boss。
static func round_enemy_model_paths(round_index: int) -> Array[String]:
	var out: Array[String] = []
	var kind := RoundService.schedule_kind_for_round(round_index)
	if kind == "pvp" or kind == "final":
		return out
	var templates: Array[Dictionary] = [_round_monster_template(round_index)]
	if kind == "boss":
		templates.append(_round_boss_template(round_index))
	for t in templates:
		for key in ["model", "model_idle_animation"]:
			var p := str(t.get(key, ""))
			if not p.is_empty() and not out.has(p):
				out.append(p)
	return out


static func _append_lane_monsters(out: Array, lane: int, count: int, template: Dictionary) -> void:
	if template.is_empty():
		return
	var growth := PveService.growth_for_completed(GameState.pve_completed)
	for n in count:
		# 已审计（勿降级）：template 来自 DataRegistry 共享表，def 随后被写入。
		var d := template.duplicate(true)
		d.hp = maxi(1, int(round(float(d.get("hp", 1)) * float(growth.hp))))
		d.atk = maxi(1, int(round(float(d.get("atk", 1)) * float(growth.atk))))
		d.def = maxi(0, int(round(float(d.get("def", 0)) * float(growth.def))))
		var f := _fighter_from_def(d, 2 + n, "enemy", n, count)
		var lane_x: float = TEAM_LANE_CENTERS[lane] + (float(n % 3) - 1.0) * 30.0
		var y := _opening_y("enemy", 200.0 - float(n / 3) * 38.0)
		f.pos = Vector2(clampf(lane_x, 80.0, ARENA_W - 80.0), clampf(y, 60.0, ARENA_H - 60.0))
		f.uid = "enemy_L%d_m%d" % [lane, n]
		f["lane"] = lane
		out.append(f)


static func _append_lane_boss(out: Array, lane: int, template: Dictionary) -> void:
	if template.is_empty():
		return
	var growth := BossService.growth_for_completed(GameState.boss_completed)
	var boss_mul := BossService.GLOBAL_STAT_MULTIPLIER
	var d := template.duplicate(true)
	d.hp = maxi(1, int(round(float(d.get("hp", 1)) * float(growth.hp) * boss_mul)))
	d.atk = maxi(1, int(round(float(d.get("atk", 1)) * float(growth.atk) * boss_mul)))
	d.def = maxi(0, int(round(float(d.get("def", 0)) * float(growth.def) * boss_mul)))
	if d.has("skill_damage"):
		d.skill_damage = maxi(1, int(round(float(d.get("skill_damage", 0)) * float(growth.skill_damage) * boss_mul)))
	var f := _fighter_from_def(d, 12, "enemy", 0, 1)
	f.pos = Vector2(TEAM_LANE_CENTERS[lane], _opening_y("enemy", 180.0))
	f.uid = "enemy_L%d_boss" % lane
	f["lane"] = lane
	out.append(f)


static func _dummy_merc_slots(_rng: RandomNumberGenerator) -> Array:
	# Stand-in rival's "sent" mercenaries. The AI only summons mercs it can afford
	# from the gold it has earned by this round (no random spawning); it spends a
	# small share of its economy on the strongest mercs that fit the budget.
	var mercs: Array = DataRegistry.get_table("mercenaries").get("mercenaries", [])
	if mercs.is_empty():
		return []
	var sorted_mercs := mercs.duplicate()
	# C23a：同价佣兵的次级键用 id。否则谁被优先召唤取决于数据表里的行序 ——
	# 调整一次 mercenaries.json 的排列就会静默改变 AI 的召唤结果。
	sorted_mercs.sort_custom(func(a, b):
		var ca: int = int(a.get("cost", 1))
		var cb: int = int(b.get("cost", 1))
		if ca != cb:
			return ca < cb
		return str(a.get("id", "")) < str(b.get("id", ""))
	)
	var budget := int(floor(float(_dummy_total_gold(GameState.round_index)) * DUMMY_MERC_BUDGET_SHARE))
	if budget < int(sorted_mercs[0].get("cost", 1)):
		return []  # not enough gold to summon any mercenary yet
	var out: Array = []
	while out.size() < DUMMY_MAX_MERCS:
		# Send the strongest (most expensive) mercenary still affordable.
		var pick: Dictionary = {}
		for m in sorted_mercs:
			if int(m.get("cost", 1)) <= budget:
				pick = m
		if pick.is_empty():
			break
		budget -= int(pick.get("cost", 1))
		out.append({"id": str(pick.get("id", "")), "star": 1, "def": (pick as Dictionary).duplicate(true), "is_mercenary": true})
	return out


static func _append_lane_mercenaries(out: Array, merc_slots: Array, team: String, lane: int, owner_slot: int = -1) -> void:
	var idx := 0
	for i in merc_slots.size():
		var cell = merc_slots[i]
		if cell == null or typeof(cell) != TYPE_DICTIONARY:
			continue
		var f := _fighter_from_cell(cell, GameConstants.CELL_COUNT + i, team)
		var lane_x: float = TEAM_LANE_CENTERS[lane] + (float(idx % 3) - 1.0) * 28.0
		var y := _opening_y(team, 360.0 + float(idx / 3) * 34.0 if team == "player" else 150.0 - float(idx / 3) * 34.0)
		f.pos = Vector2(clampf(lane_x, 80.0, ARENA_W - 80.0), clampf(y, 60.0, ARENA_H - 60.0))
		f.uid = "%s_L%d_merc%d" % [team, lane, i]
		f["lane"] = lane
		f["owner_treasures"] = []
		f["owner_syn"] = {}
		f["owner_slot"] = owner_slot
		out.append(f)
		idx += 1


static func _team_slot_state(slot_idx: int) -> String:
	var states: Array = NetworkService.team_slot_states if NetworkService.team_active else GameState.team_slot_states
	return str(states[slot_idx]) if slot_idx < states.size() else "empty"


static func _team_slot_is_opponent(slot_idx: int) -> bool:
	# A rival slot counts as an opponent if it holds a host-added dummy (假想敌),
	# or — only when online — a real remote player. Empty slots spawn NOTHING in
	# their lane (no monsters, boss, mercenaries, or pieces).
	var st := _team_slot_state(slot_idx)
	return st == "dummy" or (st == "player" and NetworkService.team_active)


static func _team_board_for_slot(slot_idx: int, rng: RandomNumberGenerator) -> Array:
	# Online: every client builds every board from the SAME broadcast snapshot
	# (including the local player's own) so the state is identical for everyone.
	if NetworkService.team_active:
		var st := _team_slot_state(slot_idx)
		if st == "player":
			var snap = NetworkService.team_boards.get(slot_idx, {})
			if snap is Dictionary and not (snap as Dictionary).is_empty():
				return NetProtocol.extract_board(snap)
			return []
		if st == "dummy":
			return build_dummy_board(rng)
		return []
	# Offline: slot 0 = my board; only explicitly checked dummy slots spawn AI boards.
	if slot_idx == 0:
		return GameState.board_slots
	var st2 := _team_slot_state(slot_idx)
	return build_dummy_board(rng) if st2 == "dummy" else []


static func _team_mercs_for_slot(slot_idx: int, rng: RandomNumberGenerator) -> Array:
	if NetworkService.team_active:
		var st := _team_slot_state(slot_idx)
		if st == "player":
			var snap = NetworkService.team_boards.get(slot_idx, {})
			if snap is Dictionary and not (snap as Dictionary).is_empty():
				return NetProtocol.extract_mercenaries(snap)
			return []
		if st == "dummy":
			return _dummy_merc_slots(rng)
		return []
	# Offline: slot 0 = my mercs; only explicitly checked dummy slots send AI mercs.
	if slot_idx == 0:
		return GameState.mercenary_slots
	var st2 := _team_slot_state(slot_idx)
	return _dummy_merc_slots(rng) if st2 == "dummy" else []


# --- AI ("假想敌") economy ----------------------------------------------------
# The dummy opponent no longer spawns random units. It follows the normal
# economy: it starts with the same gold, earns income every round (win gold +
# interest + base), then spends that budget buying units it can afford and
# leveling them up (3 copies -> a star), exactly like a real player.

const DUMMY_BOARD_BUDGET_SHARE := 0.85   # fraction of earned gold spent on the board
const DUMMY_MERC_BUDGET_SHARE := 0.15    # fraction spent on sent mercenaries
const DUMMY_MAX_MERCS := 3

static func _dummy_total_gold(round_n: int) -> int:
	# Cumulative gold the AI has earned by the start of round_n, mirroring the
	# 3v3 income each round: +5 base, +10% interest, plus rough kill gold. The AI
	# keeps a growing reserve and invests the rest, so interest ramps over time.
	var gold := GameState.START_GOLD
	var earned := gold
	for r in range(2, round_n + 1):
		var interest := int(floor(float(mini(gold, 50)) * EconomyService.BASE_INTEREST_RATE))
		var kill_gold := 2 + r / 3
		var income := 5 + interest + kill_gold
		gold += income
		earned += income
		gold = mini(gold, mini(40, 4 * r))  # spend down to a round-scaled reserve
	return earned

static func _dummy_tier_for_round(round_n: int, rng: RandomNumberGenerator) -> int:
	# Same shop tier odds a real player faces at this round (see PrepShared).
	if round_n >= 15:
		var x := rng.randf()
		return 1 if x < 0.15 else (2 if x < 0.75 else 3)
	if round_n >= 10:
		var y := rng.randf()
		return 1 if y < 0.25 else (2 if y < 0.85 else 3)
	if round_n >= 5:
		return 1 if rng.randf() < 0.50 else 2
	return 1 if rng.randf() < 0.80 else 2

static func build_dummy_board(rng: RandomNumberGenerator) -> Array:
	var board: Array = []
	board.resize(GameConstants.CELL_COUNT)
	board.fill(null)
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	if units.is_empty():
		return board
	var round_n := GameState.round_index
	var budget := int(floor(float(_dummy_total_gold(round_n)) * DUMMY_BOARD_BUDGET_SHARE))
	# The AI commits to a focused comp (a handful of units it stacks and levels),
	# tier-weighted for this round, instead of buying one of everything.
	var comp_size := clampi(2 + round_n / 2, 3, GameConstants.NORMAL_UNIT_CAP)
	var favored: Array = []
	var by_id: Dictionary = {}
	var guard := 0
	while favored.size() < comp_size and guard < 200:
		guard += 1
		var tier := _dummy_tier_for_round(round_n, rng)
		var pool: Array = units.filter(func(u): return int(u.get("tier", 1)) == tier)
		if pool.is_empty():
			pool = units
		var u: Dictionary = pool[rng.randi_range(0, pool.size() - 1)]
		var id := str(u.get("id", ""))
		if by_id.has(id):
			continue
		by_id[id] = u
		favored.append(u)
	if favored.is_empty():
		return board
	var cheapest := 9999
	for u in favored:
		cheapest = mini(cheapest, int(u.get("cost", 1)))
	# Spend the budget buying copies of favored units.
	var counts: Dictionary = {}
	guard = 0
	while budget >= cheapest and guard < 600:
		guard += 1
		var u: Dictionary = favored[rng.randi_range(0, favored.size() - 1)]
		var cost := int(u.get("cost", 1))
		if cost > budget:
			continue
		budget -= cost
		var id := str(u.get("id", ""))
		counts[id] = int(counts.get(id, 0)) + 1
	# Convert copies into starred units (3 copies -> 2★, 9 copies -> 3★).
	var placed: Array = []
	for id in counts:
		var c := int(counts[id])
		var u: Dictionary = by_id[id]
		var threes := c / 9
		var rem := c % 9
		var twos := rem / 3
		var ones := rem % 3
		for _i in threes:
			placed.append({"u": u, "star": 3})
		for _i in twos:
			placed.append({"u": u, "star": 2})
		for _i in ones:
			placed.append({"u": u, "star": 1})
	# 超过上限时保留最强的。C23a：同星级的次级键用单位 id ——
	# 这个排序决定"超员时谁被丢掉"，平手时顺序不定就是阵容不定。
	placed.sort_custom(func(a, b):
		var sa: int = int(a.star)
		var sb: int = int(b.star)
		if sa != sb:
			return sa > sb
		var ua: Dictionary = a.u
		var ub: Dictionary = b.u
		return str(ua.get("id", "")) < str(ub.get("id", ""))
	)
	# Place onto random board cells, capped at the normal unit limit.
	var slots: Array = []
	for i in GameConstants.CELL_COUNT:
		slots.append(i)
	for i in range(slots.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = slots[i]
		slots[i] = slots[j]
		slots[j] = tmp
	var place_count := mini(GameConstants.NORMAL_UNIT_CAP, placed.size())
	for k in place_count:
		var slot := int(slots[k])
		var p: Dictionary = placed[k]
		var u: Dictionary = p.u
		board[slot] = {"def": u.duplicate(true), "star": int(p.star), "is_mercenary": false, "id": str(u.get("id", ""))}
	return board


static func _is_duplicate_unique_cell(cell: Dictionary, unique_ids: Dictionary) -> bool:
	var d: Dictionary = cell.get("def", {})
	if not bool(d.get("unique_on_board", false)):
		return false
	var id := str(cell.get("id", d.get("id", "")))
	if id.is_empty():
		return false
	var limit := maxi(1, int(d.get("board_limit", 1)))
	var used := int(unique_ids.get(id, 0))
	if used >= limit:
		return true
	unique_ids[id] = used + 1
	return false

static func _init_unit_stats(state: Dictionary) -> void:
	state.unit_stats = {}
	for side in ["player", "enemy"]:
		var units: Array = state.get(side, [])
		for f in units:
			if typeof(f) == TYPE_DICTIONARY:
				_register_unit_stat(state, f)


static func _register_unit_stat(state: Dictionary, f: Dictionary) -> void:
	var uid := str(f.get("uid", ""))
	if uid.is_empty():
		return
	var d: Dictionary = f.get("def", {})
	state.unit_stats[uid] = {
		"name": str(f.get("name", d.get("name", f.get("id", "?")))),
		"name_en": str(f.get("name_en", _english_name_from_def(d))),
		"position": _stat_position_label(f),
		"group": _stat_group(f),
		"team": str(f.get("team", "")),
		"owner_slot": int(f.get("owner_slot", -1)),
		"lane": int(f.get("lane", -1)),
		"slot": int(f.get("slot", -1)),
		"is_mercenary": bool(f.get("is_mercenary", false)),
		"damage_dealt": 0,
		"damage_taken": 0,
		"healing_done": 0,
		"debuffs": {},
		"buffs": {},
	}


static func _stat_group(f: Dictionary) -> String:
	var d: Dictionary = f.get("def", {})
	if bool(d.get("is_boss", false)) or str(f.get("id", "")).begins_with("boss_") or d.has("series"):
		return "boss"
	return "player" if str(f.get("team", "")) == "player" else "enemy"


static func _stat_position_label(f: Dictionary) -> String:
	var slot := int(f.get("slot", -1))
	var team_prefix := TranslationServer.translate("name_side_ally") if str(f.get("team", "")) == "player" else TranslationServer.translate("name_side_enemy")
	if bool(f.get("is_mercenary", false)):
		return TranslationServer.translate("name_merc") % [team_prefix, maxi(1, slot - 24)]
	if _stat_group(f) == "boss":
		return "Boss%d" % maxi(1, slot + 1)
	if slot >= 0 and slot < GameConstants.CELL_COUNT:
		return TranslationServer.translate("name_board_slot") % (slot + 1)
	return TranslationServer.translate("name_side_unit") % [team_prefix, maxi(1, slot + 1)]


static func _fighter_from_cell(cell: Dictionary, slot: int, team: String, mirror_enemy_slot: bool = false) -> Dictionary:
	# 已审计（勿降级）：cell 来自 GameState.board_slots，def 随后被写入
	# （hp/atk/def 等），浅拷会把改动泄漏回玩家棋盘数据。开战时才跑，代价可接受。
	var d: Dictionary = cell.def.duplicate(true)
	if not bool(cell.get("is_mercenary", false)):
		var scaled := UnitFactory.apply_star_stats(d, int(cell.get("star", 1)))
		var relation_multiplier := RaceRelationService.stat_multiplier_for_cell(cell)
		d.hp = maxi(1, int(round(float(scaled.hp) * relation_multiplier)))
		d.atk = maxi(1, int(round(float(scaled.atk) * relation_multiplier)))
		d.def = maxi(0, int(round(float(scaled.def) * relation_multiplier)))
	return _fighter_from_def(d, slot, team, slot, GameConstants.CELL_COUNT, int(cell.get("star", 1)), bool(cell.get("is_mercenary", false)), false, mirror_enemy_slot)


static func _fighter_from_def(d: Dictionary, slot: int, team: String, order: int, total: int, star: int = 1, is_mercenary: bool = false, is_formation_ally: bool = false, mirror_enemy_slot: bool = false) -> Dictionary:
	var pos := _slot_to_pos(slot, team, order, total, mirror_enemy_slot)
	var hp := int(d.get("hp", 1))
	return {"uid": "%s_%s_%d" % [team, str(d.get("id", "unit")), order], "id": str(d.get("id", "unit")), "name": str(d.get("name", d.get("id", "unit"))), "name_en": str(d.get("name_en", _english_name_from_def(d))), "team": team, "slot": slot, "def": d, "star": star, "is_mercenary": is_mercenary or bool(d.get("is_mercenary", false)), "is_formation_ally": is_formation_ally, "footprint_cells": maxi(1, int(d.get("footprint_cells", 1))), "hp": hp, "max_hp": hp, "atk": int(d.get("atk", 1)), "defense": int(d.get("def", d.get("defense", 0))), "attack_speed": float(d.get("attack_speed", 1.0)), "range_px": float(d.get("range", 1)) * ATTACK_RANGE_SCALE, "move_speed_px": float(d.get("move_speed", 3.0)) * 55.0, "pos": pos, "next_attack": 0.0, "alive": true, "shield": 0, "attack_count": 0, "skill_ready": 0.0, "skill_stacks": 0, "linked_target_uid": "", "statuses": {}, "dodge": float(d.get("dodge", 0.0)), "revives_left": int(d.get("revives_per_twin", 0)), "treasure_cd": {}}


static func _english_name_from_def(d: Dictionary) -> String:
	var id := str(d.get("id", ""))
	for prefix in ["pve_", "boss_", "merc_"]:
		if id.begins_with(prefix):
			id = id.substr(prefix.length())
	for element in ["land_", "sky_", "water_", "fire_", "ren_"]:
		if id.begins_with(element):
			id = id.substr(element.length())
	var words := id.split("_", false)
	for i in words.size():
		var w := str(words[i])
		words[i] = w.substr(0, 1).to_upper() + w.substr(1)
	return " ".join(words) if not words.is_empty() else str(d.get("name", d.get("id", "Unit")))


static func _slot_to_pos(slot: int, team: String, order: int, total: int, mirror_enemy_slot: bool = false) -> Vector2:
	var column := slot % GameConstants.BOARD_COLUMNS
	var row := floori(float(slot) / float(GameConstants.BOARD_COLUMNS))
	var base_x := ARENA_W * 0.5 + (float(column) - (float(GameConstants.BOARD_COLUMNS) - 1.0) * 0.5) * CELL_SPACING
	var base_y := _opening_y("player", 272.0 + float(row) * CELL_SPACING)
	var x := base_x
	var y := base_y
	if team == "enemy":
		if mirror_enemy_slot:
			x = ARENA_W - base_x
			y = _opening_y("enemy", ARENA_H - (272.0 + float(row) * CELL_SPACING))
		else:
			y = _opening_y("enemy", 80.0 + float(order % maxi(1, total)) * 42.0)
			x = ARENA_W * 0.5 + (float(order % GameConstants.BOARD_COLUMNS) - (float(GameConstants.BOARD_COLUMNS) - 1.0) * 0.5) * CELL_SPACING
	return Vector2(clampf(x, 80.0, ARENA_W - 80.0), clampf(y, 45.0, ARENA_H - 45.0))


static func _mercenary_slot_to_pos(index: int, team: String, mirror_enemy_slot: bool = false) -> Vector2:
	var col := index % 3
	var row := floori(float(index) / 3.0)
	var x := 314.0 + float(col) * 186.0
	var y := _opening_y("player", 424.0 + float(row) * 54.0)
	if team == "enemy":
		if mirror_enemy_slot:
			x = ARENA_W - x
			y = _opening_y("enemy", ARENA_H - (424.0 + float(row) * 54.0))
		else:
			y = _opening_y("enemy", 96.0 + float(row) * 54.0)
	return Vector2(clampf(x, 80.0, ARENA_W - 80.0), clampf(y, 45.0, ARENA_H - 45.0))


static func _effective_attack_distance(attacker: Dictionary, target: Dictionary) -> float:
	var attacker_extra := float(maxi(0, int(attacker.get("footprint_cells", 1)) - 1)) * CELL_SPACING * 0.5
	var target_extra := float(maxi(0, int(target.get("footprint_cells", 1)) - 1)) * CELL_SPACING * 0.5
	return float(attacker.get("range_px", ATTACK_RANGE_SCALE)) + attacker_extra + target_extra

static func _select_target(f: Dictionary, opponents: Array) -> Dictionary:
	var taunter := _nearest_taunter(f, opponents)
	if not taunter.is_empty():
		return taunter
	if GameState.team_mode:
		return _team_select_target(f, opponents)
	if str(f.get("def", {}).get("skill_id", "")) == "death_hunt":
		var low2 := _lowest_targetable_hp_ratio(f, opponents)
		if not low2.is_empty():
			return low2
	if _f_has_set(f, "attack"):
		var low := _lowest_targetable_hp_ratio(f, opponents)
		if not low.is_empty():
			return low
	return _nearest(f, opponents)


static func _team_select_target(f: Dictionary, opponents: Array) -> Dictionary:
	# Fight your own lane first; when it is clear, help the LEFT lane (lower
	# index) before the RIGHT lane.
	var my_lane := int(f.get("lane", 0))
	var lane_order: Array = [my_lane]
	for l in range(my_lane - 1, -1, -1):
		lane_order.append(l)
	for l in range(my_lane + 1, 3):
		lane_order.append(l)
	for lane in lane_order:
		var best: Dictionary = {}
		var best_dist := INF
		for o in opponents:
			if not bool(o.get("alive", false)) or int(o.get("lane", -1)) != lane or not _can_target(f, o, opponents):
				continue
			var dist: float = float(f.pos.distance_squared_to(o.pos))
			if dist < best_dist:
				best_dist = dist
				best = o
		if not best.is_empty():
			return best
	return _nearest(f, opponents)


static func _nearest(f: Dictionary, opponents: Array) -> Dictionary:
	var best: Dictionary = {}
	var best_dist := INF
	for o in opponents:
		if not bool(o.get("alive", false)) or not _can_target(f, o, opponents):
			continue
		var dist: float = float(f.pos.distance_squared_to(o.pos))
		if dist < best_dist:
			best_dist = dist
			best = o
	return best


static func _can_target(attacker: Dictionary, target: Dictionary, opponents: Array = []) -> bool:
	if not GameState.team_mode or str(attacker.get("team", "")) == str(target.get("team", "")):
		return true
	var lane := int(attacker.get("lane", -1))
	if lane < 0 or int(target.get("lane", -1)) == lane:
		return true
	for o in opponents:
		if bool(o.get("alive", false)) and int(o.get("lane", -1)) == lane:
			return false
	return true


static func _teams_have_valid_target_pair(player_units: Array, enemy_units: Array) -> bool:
	for player_unit in player_units:
		for enemy_unit in enemy_units:
			if _can_target(player_unit, enemy_unit, enemy_units) or _can_target(enemy_unit, player_unit, player_units):
				return true
	return false


static func _nearest_taunter(f: Dictionary, opponents: Array) -> Dictionary:
	var best: Dictionary = {}
	var best_dist := INF
	for o in opponents:
		if not bool(o.get("alive", false)) or not bool(o.get("taunt_active", false)) or not _can_target(f, o, opponents):
			continue
		var dist: float = float(f.pos.distance_squared_to(o.pos))
		var radius := float(o.get("taunt_radius", 180.0))
		if radius > 0.0 and dist > radius * radius:
			continue
		if dist < best_dist:
			best_dist = dist
			best = o
	return best


static func _alive(fighters: Array) -> Array:
	var out: Array = []
	for f in fighters:
		if bool(f.get("alive", false)) and int(f.get("hp", 0)) > 0:
			out.append(f)
	return out


static func _survivor_slots(fighters: Array) -> Array[int]:
	var out: Array[int] = []
	for f in fighters:
		if bool(f.get("alive", false)) and int(f.get("slot", -1)) >= 0:
			out.append(int(f.slot))
	return out


static func _team_current_hp(fighters: Array) -> int:
	var total := 0
	for f in fighters:
		if bool(f.get("alive", false)):
			total += maxi(0, int(f.get("hp", 0)))
	return total


static func _team_max_hp(fighters: Array) -> int:
	var total := 0
	for f in fighters:
		total += maxi(0, int(f.get("max_hp", f.get("hp", 0))))
	return total


static func _record_death_history(state: Dictionary, victim: Dictionary) -> void:
	var history: Array = state.get("death_history", [])
	var snapshot := victim.duplicate(true)
	snapshot.alive = false
	snapshot.statuses = {}
	snapshot.erase("parasite_owner")
	snapshot.erase("sacrifice_guardian")
	snapshot.erase("shared_link_uid")
	snapshot.erase("shared_link_peer")
	history.append(snapshot)
	while history.size() > 80:
		history.pop_front()
	state.death_history = history


static func _decay_units(fighters: Array) -> void:
	for f in fighters:
		f.max_hp = maxi(1, int(floor(float(f.max_hp) * 0.8)))
		f.hp = clampi(int(floor(float(f.hp) * 0.8)), 1, int(f.max_hp))
		f.atk = maxi(1, int(floor(float(f.atk) * 0.8)))
		f.defense = maxi(0, int(floor(float(f.defense) * 0.8)))


static func timeout_power(fighters: Array) -> float:
	var total := 0.0
	for f in fighters:
		if bool(f.get("alive", true)):
			total += float(f.get("hp", 0)) + float(f.get("atk", 0)) * 2.0 + float(f.get("defense", f.get("def", 0))) * 5.0
	return total





static func _fire_bonus_multiplier(attacker: Dictionary) -> float:
	if _f_has_linkage(attacker, "link_blood_covenant"):
		return 1.00
	return 0.40


static func _treasure_ready(attacker: Dictionary, key: String, elapsed: float) -> bool:
	if not attacker.has("treasure_cd") or typeof(attacker.treasure_cd) != TYPE_DICTIONARY:
		attacker.treasure_cd = {}
	return elapsed >= float(attacker.treasure_cd.get(key, 0.0))


static func _set_treasure_cd(attacker: Dictionary, key: String, elapsed: float, cd: float) -> void:
	if not attacker.has("treasure_cd") or typeof(attacker.treasure_cd) != TYPE_DICTIONARY:
		attacker.treasure_cd = {}
	attacker.treasure_cd[key] = elapsed + cd


static func _apply_attribute_effect(kind: String, attacker: Dictionary, target: Dictionary) -> void:
	match kind:
		"fire":
			DamageService.apply_damage(target, maxi(1, int(round(float(attacker.atk) * _fire_bonus_multiplier(attacker)))), true)
		"ice":
			StatusEffectService.add_status(target, "slow", 1.5, {"move_pct": 0.35, "attack_speed_pct": 0.35})
			StatusEffectService.add_status(target, "ice_affected", 1.5, {})
		"thunder":
			if RngService.rng.randf() < 0.25:
				StatusEffectService.interrupt(target)
		"poison":
			StatusEffectService.add_poison(target)


static func _element_multiplier(a: String, b: String) -> float:
	if a == "sky" and b == "land": return 1.25
	if a == "land" and b == "ren": return 1.25
	if a == "ren" and b == "sky": return 1.25
	if a == "land" and b == "sky": return 0.85
	if a == "ren" and b == "land": return 0.85
	if a == "sky" and b == "ren": return 0.85
	return 1.0

static func _skill_cast_should_shake(caster: Dictionary) -> bool:
	var d: Dictionary = caster.get("def", {})
	return bool(d.get("is_boss", false)) or d.has("series") or int(d.get("tier", 1)) >= 3


static func _add_visual_event(state: Dictionary, event_type: String, caster: Dictionary, strength: float, duration: float) -> void:
	if not state.has("visual_events") or typeof(state.visual_events) != TYPE_ARRAY:
		state.visual_events = []
	state.visual_events.append({
		"type": event_type,
		"uid": str(caster.get("uid", "")),
		"pos": caster.get("pos", Vector2.ZERO),
		"strength": strength,
		"duration": duration,
		"time": float(state.get("elapsed", 0.0)),
	})


static func _lowest_targetable_hp_ratio(attacker: Dictionary, units: Array) -> Dictionary:
	var best: Dictionary = {}
	var best_ratio := INF
	for u in units:
		if not bool(u.get("alive", false)) or not _can_target(attacker, u, units): continue
		var ratio := float(u.hp) / float(maxi(1, u.max_hp))
		if ratio < best_ratio:
			best_ratio = ratio
			best = u
	return best


static func _lowest_hp_ratio(units: Array) -> Dictionary:
	var best: Dictionary = {}
	var best_ratio := INF
	for u in units:
		if not bool(u.get("alive", false)): continue
		var ratio := float(u.hp) / float(maxi(1, u.max_hp))
		if ratio < best_ratio:
			best_ratio = ratio
			best = u
	return best


static func _dark_duration(base: float, caster: Dictionary, state: Dictionary) -> float:
	if str(caster.get("def", {}).get("race", "")) == "dark":
		var syn: Dictionary = _resolve_syn(caster, state)
		return base * (1.0 + SynergyService.safe_factor(syn, "dark_debuff_duration"))
	return base


static func _group_heal(caster: Dictionary, allies: Array, heal_pct: float) -> void:
	for a in allies:
		if bool(a.get("alive", false)) and caster.pos.distance_to(a.pos) <= 180.0:
			_heal_unit(a, maxi(1, int(round(float(a.max_hp) * heal_pct))))


static func _unit_at_slot(units: Array, slot: int) -> Dictionary:
	for u in units:
		if bool(u.get("alive", false)) and int(u.get("slot", -1)) == slot:
			return u
	return {}


static func _team_has_skill(units: Array, skill_id: String) -> bool:
	for u in units:
		if str(u.get("def", {}).get("skill_id", "")) == skill_id:
			return true
	return false


static func _status_count(fighter: Dictionary) -> int:
	if not fighter.has("statuses") or typeof(fighter.statuses) != TYPE_DICTIONARY:
		return 0
	return fighter.statuses.size()


static func _ignores_treasure(fighter: Dictionary) -> bool:
	return bool(fighter.get("is_mercenary", false)) or bool(fighter.get("is_formation_ally", false))


static func _formation_ally_def_for_hp(hp: int) -> Dictionary:
	var ally_id := FormationAllyService.ally_id_for_hp(hp)
	var allies: Array = DataRegistry.get_table("formation_allies").get("allies", [])
	for a in allies:
		if str(a.get("id", "")) == ally_id:
			var d: Dictionary = a.duplicate(true)
			d.tier = 4
			d.cost = 0
			return d
	return {}


# 判定顺序有意义：法阵友军 0 → 佣兵按费用 → PVE 小怪固定单价 → 其余按 tier/星级。
# PVE 小怪没有 tier 字段，走 pvp_normal_kill_reward 会一律吃 tier 默认值 1，
# 所以这里按局型直接给固定单价；佣兵不算「怪兽」，仍走费用公式。
static func _kill_reward_for_victim(victim: Dictionary, state: Dictionary) -> int:
	if bool(victim.get("is_formation_ally", false)):
		return 0
	var d: Dictionary = victim.get("def", {})
	if bool(victim.get("is_mercenary", false)):
		return EconomyService.pvp_mercenary_kill_reward(int(d.get("cost", 1)))
	if str(state.get("kind", "")) == "pve":
		return EconomyService.PVE_MONSTER_KILL_GOLD
	return EconomyService.pvp_normal_kill_reward(int(d.get("tier", 1)), int(victim.get("star", 1)))


static func _dynamic_attack_speed_multiplier(fighter: Dictionary) -> float:
	var d: Dictionary = fighter.get("def", {})
	if str(d.get("skill_id", "")) == "blood_rampage":
		var missing := 1.0 - float(fighter.hp) / float(maxi(1, int(fighter.max_hp)))
		var steps := int(floor(missing / float(d.get("hp_step", 0.10))))
		return 1.0 + float(steps) * float(d.get("aspd_per_step", 0.10))
	return 1.0


static func _blood_rampage_damage_multiplier(attacker: Dictionary, d: Dictionary) -> float:
	var missing := 1.0 - float(attacker.hp) / float(maxi(1, int(attacker.max_hp)))
	var steps := int(floor(missing / float(d.get("hp_step", 0.10))))
	return 1.0 + float(steps) * 0.03


static func _nearest_n(f: Dictionary, units: Array, count: int) -> Array:
	var pool := []
	for u in units:
		if bool(u.get("alive", false)) and _can_target(f, u, units):
			pool.append(u)
	# C23a：距离相同时必须有稳定次级键。`sort_custom` 是**不稳定排序**，
	# 平手元素的相对顺序由初始排列决定 —— 而这里选出来的是**攻击目标**，
	# 顺序一变整场战斗就变。对称站位下距离完全相等是常见情况，不是边角。
	pool.sort_custom(func(a, b):
		# 显式标类型：f.pos 是 Variant，`:=` 推不出 distance_squared_to 的返回类型
		var da: float = f.pos.distance_squared_to(a.pos)
		var db: float = f.pos.distance_squared_to(b.pos)
		if not is_equal_approx(da, db):
			return da < db
		return str(a.get("uid", "")) < str(b.get("uid", ""))
	)
	return pool.slice(0, mini(maxi(0, count), pool.size()))

static func _heal_unit(unit: Dictionary, amount: int) -> void:
	if amount <= 0 or not bool(unit.get("alive", false)):
		return
	StatusEffectService.ensure_status(unit)
	var final_amount := amount
	if unit.statuses.has("heal_reduction"):
		final_amount = maxi(0, int(round(float(final_amount) * maxf(0.0, 1.0 - float(unit.statuses.heal_reduction.get("pct", 0.0))))))
	var before := int(unit.hp)
	unit.hp = mini(int(unit.max_hp), int(unit.hp) + final_amount)
	var healed := maxi(0, int(unit.hp) - before)
	DamageService.record_heal(unit, healed)
	DamageService.emit_heal_number(unit, healed)

