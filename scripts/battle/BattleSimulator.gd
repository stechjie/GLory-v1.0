class_name BattleSimulator
extends BattleSimShared

const BattlePresentationEventSchema := preload("res://scripts/battle/BattlePresentationEvent.gd")

# 教学专用战斗。唯一入口是 BattleScreen 的 `team_mode == false` 分支，而 team_mode
# 只有 Main._select_language() → TutorialMode.start() 这一条路会留成 false，
# 所以这里恒为教学模式（联机 3v3 与离线自测都走 prepare_team_state）。
# 以后若真要做 1v1，请另起一套，不要复用本函数——它假定了教学的前提。
static func prepare_tutorial_state(kind: String) -> Dictionary:
	RngService.rng.randomize()
	var player := build_tutorial_player_fighters(kind)
	var enemy := build_tutorial_enemy_fighters(kind)
	if kind == "final":
		_add_final_formation_allies(player, enemy)
		_apply_final_round_left_right_layout(player, enemy)
	var battle_log: Array[String] = []
	var player_syn := SynergyService.current_player_flags()
	var enemy_syn := _enemy_syn_for_kind(kind)
	if player.is_empty():
		return {"kind": kind, "player": player, "enemy": enemy, "elapsed": 0.0, "next_decay": DECAY_START_SEC, "finished": true, "forced_result": {"player_wins": false, "reason": "no_player_units", "log": [TranslationServer.translate("log_no_player_units")]}}
	if enemy.is_empty():
		return {"kind": kind, "player": player, "enemy": enemy, "elapsed": 0.0, "next_decay": DECAY_START_SEC, "finished": true, "forced_result": {"player_wins": true, "reason": "no_enemy_units", "log": [TranslationServer.translate("log_enemy_empty")]}}
	battle_log.append(TranslationServer.translate("log_unit_counts") % [player.size(), enemy.size()])
	var state := {"kind": kind, "player": player, "enemy": enemy, "elapsed": 0.0, "next_decay": DECAY_START_SEC, "finished": false, "log": battle_log, "player_syn": player_syn, "enemy_deaths": 0, "total_deaths": 0, "field_death_count": 0, "mother_death_counter": 0, "dark_kill_stacks": 0, "undead_trait_death_counter": 0, "race_trait_processed_deaths": {}, "death_history": [], "revive_queue": [], "player_kill_gold": 0, "enemy_kill_gold": 0, "kill_gold_by_slot": {}, "player_kills": [], "enemy_kills": [], "bonus_gold": 0, "temporary_deaths": [], "visual_events": [], "unit_stats": {}}
	state["enemy_syn"] = enemy_syn
	_init_unit_stats(state)
	DamageService.set_stat_state(state)
	if TreasureService.has_set("defense"):
		for f in player:
			if not _ignores_treasure(f):
				f.max_hp = maxi(1, int(round(float(f.max_hp) * 1.30)))
				f.hp = int(f.max_hp)
				f.defense = maxi(0, int(round(float(f.defense) * 1.30)))
				f.dodge = float(f.get("dodge", 0.0)) + 0.15
		battle_log.append(TranslationServer.translate("log_defense_set"))
	if bool(player_syn.get("god_invulnerable_opening", false)):
		for f in player:
			if not _ignores_treasure(f):
				DamageService.begin_stat_context(state, f)
				StatusEffectService.add_status(f, "invulnerable", 1.5, {})
				DamageService.clear_stat_context()
		battle_log.append(TranslationServer.translate("log_god_invuln"))
	if bool(player_syn.get("human_shield", false)):
		for f in player:
			if not _ignores_treasure(f):
				f.shield = maxi(1, int(float(f.max_hp) * 0.08))
		battle_log.append(TranslationServer.translate("log_human_shield"))
	if bool(enemy_syn.get("god_invulnerable_opening", false)):
		for f in enemy:
			if not _ignores_treasure(f):
				DamageService.begin_stat_context(state, f)
				StatusEffectService.add_status(f, "invulnerable", 1.5, {})
				DamageService.clear_stat_context()
	if bool(enemy_syn.get("human_shield", false)):
		for f in enemy:
			if not _ignores_treasure(f):
				f.shield = maxi(1, int(float(f.max_hp) * 0.08))
	_apply_opening_unit_skills(player, enemy, battle_log, state)
	BattleSimTreasures._apply_opening_treasures(player, battle_log)
	return state

# --- 3v3 team mode (prototype) ---------------------------------------------
static func prepare_team_state(forced_team: int = -1) -> Dictionary:
	# 3v3 keeps the normal round schedule (PvE / Boss / PvP) — BUT enemy content only
	# spawns when the opposing team actually has someone in it (a real player or a
	# host-added dummy). With no opponent, the enemy side is empty (see has_opponent
	# below): no monsters, no boss, no mercenaries, no pieces.
	var kind := RoundService.schedule_kind_for_round(GameState.round_index)
	var is_final_round := kind == "final"
	if is_final_round:
		kind = "pvp"
	var my_slot: int = NetworkService.team_local_slot if NetworkService.team_active else 0
	if my_slot < 0:
		my_slot = 0
	var my_team := GameConstants.team_of_slot(my_slot)
	if forced_team >= 0:
		my_team = forced_team
	# Canonical arrangement so every client watching this battle builds the exact
	# same state (required for deterministic identical playback). PvP: all 6 see
	# team A (slots 0-2) at the bottom vs team B (3-5). PvE/Boss: each team sees
	# their own 3 boards vs monsters.
	var ally_slots: Array
	var rival_slots: Array
	var seed_parts: Array
	if kind == "pvp":
		ally_slots = [0, 1, 2]
		rival_slots = [3, 4, 5]
		seed_parts = [NetworkService.shared_seed, GameState.round_index, "pvp"]
	else:
		ally_slots = [0, 1, 2] if my_team == 0 else [3, 4, 5]
		rival_slots = [3, 4, 5] if my_team == 0 else [0, 1, 2]
		seed_parts = [NetworkService.shared_seed, GameState.round_index, my_team]
	if NetworkService.team_active:
		RngService.seed_from_parts(seed_parts)
	else:
		RngService.rng.randomize()
	var rng := RngService.rng
	# Ally side (bottom): lane = position within your team. Each board carries its
	# owner's treasures/synergies so the host applies them to that owner's units.
	var lane_boards: Array = []
	var ally_ctx: Array = []
	var rival_ctx: Array = []
	for lane in 3:
		lane_boards.append(_team_board_for_slot(ally_slots[lane], rng))
		ally_ctx.append(_team_owner_ctx_for_slot(ally_slots[lane]))
		rival_ctx.append(_team_owner_ctx_for_slot(rival_slots[lane]))
	var player: Array = []
	for lane in 3:
		_append_lane_board_fighters(player, lane_boards[lane], "player", lane, ally_ctx[lane].treasures, ally_ctx[lane].syn, ally_slots[lane], ally_ctx[lane].get("pet", ""))
	# Enemy side only exists if the opposing team has a real opponent: a host-added
	# dummy (假想敌), or — only when online — a remote player. Offline there is just
	# ONE real player (you), so a stray "player" slot marker must NOT count as an
	# opponent; only dummies do. No opponent => empty enemy for EVERY round type.
	var has_opponent := false
	for s in rival_slots:
		if _team_slot_is_opponent(int(s)):
			has_opponent = true
			break
	# Enemy side (top): per-lane by round type. Enemy TYPE picked once per round.
	var monster_template := _round_monster_template()
	var boss_template := _round_boss_template()
	# (5) Monster count is a FIXED per-round number, NOT tied to how many pieces the
	# player fielded. Same table single-player PvE uses.
	var monster_count_by_round: Dictionary = DataRegistry.get_table("pve_monsters").get("enemy_count_by_round", {})
	var lane_monster_count := maxi(1, int(monster_count_by_round.get(str(GameState.round_index), 3)))
	var enemy: Array = []
	if has_opponent:
		for lane in 3:
			# Per-lane gate: an empty rival slot means this lane gets NO enemy
			# content at all (no monsters, no boss, no pieces).
			if not _team_slot_is_opponent(int(rival_slots[lane])):
				continue
			match kind:
				"boss":
					_append_lane_boss(enemy, lane, boss_template)
					_append_lane_monsters(enemy, lane, lane_monster_count, monster_template)
				"pvp":
					_append_lane_board_fighters(enemy, _team_board_for_slot(rival_slots[lane], rng), "enemy", lane, rival_ctx[lane].treasures, rival_ctx[lane].syn, rival_slots[lane], rival_ctx[lane].get("pet", ""))
				_:
					_append_lane_monsters(enemy, lane, lane_monster_count, monster_template)
		# Mercenaries (Legion TD 2 "send"): PvP -> own mercs fight WITH you and the
		# rival's with them; PvE/Boss -> your mercs are sent to your rival's lane, so
		# the RIVAL lane partner's mercs appear in YOUR lane as enemies.
		for lane in 3:
			if kind == "pvp":
				_append_lane_mercenaries(player, _team_mercs_for_slot(ally_slots[lane], rng), "player", lane, ally_slots[lane])
				_append_lane_mercenaries(enemy, _team_mercs_for_slot(rival_slots[lane], rng), "enemy", lane, rival_slots[lane])
			else:
				_append_lane_mercenaries(enemy, _team_mercs_for_slot(rival_slots[lane], rng), "enemy", lane, rival_slots[lane])
	if is_final_round:
		_add_team_final_formation_allies(player, enemy)
		_apply_final_round_left_right_layout(player, enemy)

	var battle_log: Array[String] = []
	battle_log.append(TranslationServer.translate("log_team_unit_counts") % [kind.to_upper(), player.size(), enemy.size()])
	var state := {"kind": kind, "player": player, "enemy": enemy, "elapsed": 0.0, "next_decay": DECAY_START_SEC, "finished": false, "log": battle_log, "player_syn": {}, "enemy_deaths": 0, "total_deaths": 0, "field_death_count": 0, "mother_death_counter": 0, "dark_kill_stacks": 0, "undead_trait_death_counter": 0, "race_trait_processed_deaths": {}, "death_history": [], "revive_queue": [], "player_kill_gold": 0, "enemy_kill_gold": 0, "kill_gold_by_slot": {}, "player_kills": [], "enemy_kills": [], "bonus_gold": 0, "temporary_deaths": [], "visual_events": [], "unit_stats": {}}
	# lane -> 座位 的映射：跨路击杀分账要靠它找到「路线主」（见 _add_kill_reward）。
	# 教学的 prepare_tutorial_state 不会有这两个键，那边棋子的 lane 恒为 -1，分账自动跳过。
	state["ally_slots"] = ally_slots.duplicate()
	state["rival_slots"] = rival_slots.duplicate()
	# (Formation Heal in 3v3) Total post-battle team HP regen per side, from each
	# owner's treasures. Host-authoritative so every client applies the same amount.
	state.team_heal_ally = _team_formation_heal_total(ally_ctx)
	state.team_heal_rival = _team_formation_heal_total(rival_ctx)
	if player.is_empty():
		state.finished = true
		state.forced_result = {"player_wins": false, "reason": "no_player_units", "log": [TranslationServer.translate("log_no_ally_units")]}
		return state
	if enemy.is_empty():
		state.finished = true
		state.forced_result = {"player_wins": true, "reason": "no_enemy_units", "log": [TranslationServer.translate("log_no_enemy_units")]}
		return state
	# Per-owner synergy bookkeeping (keyed by team+lane = a single player's board).
	var owner_syn_by_key: Dictionary = {}
	for lane in 3:
		owner_syn_by_key["player_%d" % lane] = ally_ctx[lane].syn
		if kind == "pvp":
			owner_syn_by_key["enemy_%d" % lane] = rival_ctx[lane].syn
	state.owner_syn_by_key = owner_syn_by_key
	state.owner_state = {}
	for f in (player + enemy):
		if _ignores_treasure(f):
			continue
		if _f_has_set(f, "defense"):
			f.max_hp = maxi(1, int(round(float(f.max_hp) * 1.30)))
			f.hp = int(f.max_hp)
			f.defense = maxi(0, int(round(float(f.defense) * 1.30)))
			f.dodge = float(f.get("dodge", 0.0)) + 0.15
		# (7) human opening shield: only the owner's own units.
		if bool(_f_syn(f).get("human_shield", false)):
			f.shield = maxi(int(f.get("shield", 0)), int(float(f.get("max_hp", 1)) * 0.08))
		# (6) god opening invulnerability: only the owner's own units.
		if bool(_f_syn(f).get("god_invulnerable_opening", false)):
			StatusEffectService.add_status(f, "invulnerable", 1.5, {})
	_init_unit_stats(state)
	DamageService.set_stat_state(state)
	_apply_opening_unit_skills(player, enemy, battle_log, state)
	# Opening treasures run AFTER opening skills (matching 1v1 order) so cooldown
	# treasures like Time Compress apply their -25% to the opening skill_ready that
	# the skills just set.
	BattleSimTreasures._apply_opening_treasures(player, battle_log)
	BattleSimTreasures._apply_opening_treasures(enemy, battle_log)
	return state

# --- B: host computes the whole battle and records a replay -----------------
# roster: uid -> render info (incl. def for the 3D model). frames: per-tick
# arrays of [uid, x, y, hp, alive, attack_count, skill_ready, shield, skill_stacks, statuses].
# Clients play this back instead of simulating.

static func compute_team_replay(forced_team: int, battle_id: String = "") -> Dictionary:
	var state := prepare_team_state(forced_team)
	state["_presentation_battle_id"] = _presentation_battle_id(state, forced_team, battle_id)
	var roster: Dictionary = {}
	var frames: Array = []
	var frame_events: Array = []
	_replay_capture_roster(state, roster)
	var steps := 0
	while not bool(state.get("finished", false)) and steps < 4000:
		step_state(state)
		steps += 1
		_replay_capture_roster(state, roster)
		_replay_capture_frame(state, frames, frame_events)
	return _team_replay_payload(state, roster, frames, frame_events)

# 分帧版：与上面同一循环，但超出每帧时间预算就 await 到下一帧再继续，
# 避免整场战斗在一帧内算完导致开战冻屏。确定性依据：RngService.rng 只被
# 模拟代码消费（见 RngService.gd），await 期间穿插的帧逻辑不会扰动 RNG 流，
# 因此 pvp 下先后计算的 replay_a / replay_b 仍然一致。
static func compute_team_replay_async(forced_team: int, budget_usec: int = 8000, battle_id: String = "") -> Dictionary:
	var state := prepare_team_state(forced_team)
	state["_presentation_battle_id"] = _presentation_battle_id(state, forced_team, battle_id)
	var roster: Dictionary = {}
	var frames: Array = []
	var frame_events: Array = []
	_replay_capture_roster(state, roster)
	var steps := 0
	var tree := Engine.get_main_loop() as SceneTree
	var slice_start := Time.get_ticks_usec()
	while not bool(state.get("finished", false)) and steps < 4000:
		step_state(state)
		steps += 1
		_replay_capture_roster(state, roster)
		_replay_capture_frame(state, frames, frame_events)
		if tree != null and Time.get_ticks_usec() - slice_start > budget_usec:
			await tree.process_frame
			slice_start = Time.get_ticks_usec()
	return _team_replay_payload(state, roster, frames, frame_events)


static func _presentation_battle_id(state: Dictionary, forced_team: int, requested_id: String) -> String:
	var base_id := requested_id.strip_edges()
	if base_id.is_empty():
		# Local/review paths do not own a server room id. The authoritative battle
		# inputs form a rebuildable identity, while fixed-seed tests intentionally
		# reproduce the same keys on repeated runs.
		base_id = "local:%d:%d:%s" % [
			int(NetworkService.shared_seed),
			int(GameState.round_index),
			str(state.get("kind", "unknown")),
		]
	return "%s:team%d" % [base_id, forced_team]


static func _replay_capture_frame(state: Dictionary, frames: Array, frame_events: Array = []) -> void:
	# 本帧内新产生的视觉事件（母灵处决 / 屏震 / 技能演出等）也要记进回放，
	# 否则 team/回放模式下这些只在 live sim 里出现的事件全部丢失（母灵的书就是这么没的）。
	var ve: Array = state.get("visual_events", [])
	var cursor := int(state.get("_replay_ve_cursor", 0))
	var new_events: Array = []
	var tick := frames.size()
	var battle_id := str(state.get("_presentation_battle_id", ""))
	var ordinal := 0
	for i in range(cursor, ve.size()):
		if ve[i] is Dictionary:
			new_events.append(BattlePresentationEventSchema.normalize(ve[i] as Dictionary, battle_id, tick, ordinal))
		else:
			# Preserve malformed legacy values so the schema/Director can reject them
			# explicitly instead of hiding corruption during capture.
			new_events.append(ve[i])
		ordinal += 1
	state["_replay_ve_cursor"] = ve.size()
	frame_events.append(new_events)
	var frame_stats: Dictionary = state.get("unit_stats", {})
	var frame: Array = []
	for f in (state.get("player", []) + state.get("enemy", [])):
		frame.append([
			str(f.get("uid", "")),
			float(f.pos.x),
			float(f.pos.y),
			int(f.get("hp", 0)),
			bool(f.get("alive", false)),
			int(f.get("attack_count", 0)),
			float(f.get("skill_ready", 0.0)),
			int(f.get("shield", 0)),
			int(f.get("skill_stacks", 0)),
			_replay_statuses(f),
			int((frame_stats.get(str(f.get("uid", "")), {}) as Dictionary).get("damage_dealt", 0)),
			str(f.get("vfx_attack_target_uid", "")),
			str(f.get("vfx_skill_target_uid", "")),
		])
	frames.append(frame)

static func _team_replay_payload(state: Dictionary, roster: Dictionary, frames: Array, frame_events: Array = []) -> Dictionary:
	var replay_result := result_from_state(state)
	replay_result["team_heal_ally"] = int(state.get("team_heal_ally", 0))
	replay_result["team_heal_rival"] = int(state.get("team_heal_rival", 0))
	return {"kind": str(state.get("kind", "pve")), "roster": roster, "frames": frames, "frame_events": frame_events, "result": replay_result}

# (1/2) Compute how much HP each team loses this round and stamp it into BOTH
# replays' results, so every client can drive team_hp and enemy_team_hp
# deterministically from the replay it plays. Team A = "player" side of replay_a.
static func stamp_team_round_damages(replay_a: Dictionary, replay_b: Dictionary) -> void:
	var kind := str(replay_a.get("kind", "pve"))
	var ra: Dictionary = replay_a.get("result", {})
	var dmg_a := 0
	var dmg_b := 0
	if kind == "pvp":
		# Single battle (team A bottom vs team B top). The loser takes damage equal
		# to the winner's surviving units.
		if bool(ra.get("player_wins", false)):
			dmg_b = maxi(1, int(ra.get("player_alive", 1)))
		else:
			dmg_a = maxi(1, int(ra.get("enemy_alive", 1)))
	else:
		# PvE / Boss: two independent battles vs monsters.
		dmg_a = _team_replay_self_damage(replay_a)
		dmg_b = _team_replay_self_damage(replay_b)
	# Formation Heal: replay_a carries BOTH teams' heal (ally = team A, rival = team B),
	# so orient self/rival per replay just like the damage.
	var heal_a := int((replay_a.get("result", {}) as Dictionary).get("team_heal_ally", 0))
	var heal_b := int((replay_a.get("result", {}) as Dictionary).get("team_heal_rival", 0))
	var res_a: Dictionary = replay_a.get("result", {})
	res_a["team_damage_self"] = dmg_a
	res_a["team_damage_rival"] = dmg_b
	res_a["team_heal_self"] = heal_a
	res_a["team_heal_rival"] = heal_b
	if kind == "pvp":
		res_a["player_survivor_slots"] = ra.get("player_survivor_slots", [])
	replay_a["result"] = res_a
	var res_b: Dictionary = replay_b.get("result", {})
	res_b["team_damage_self"] = dmg_b
	res_b["team_damage_rival"] = dmg_a
	res_b["team_heal_self"] = heal_b
	res_b["team_heal_rival"] = heal_a
	if kind == "pvp":
		res_b["player_survivor_slots"] = ra.get("enemy_survivor_slots", [])
	replay_b["result"] = res_b

static func _team_replay_self_damage(replay: Dictionary) -> int:
	var r: Dictionary = replay.get("result", {})
	if bool(r.get("player_wins", false)):
		return 0
	return maxi(1, int(r.get("enemy_alive", 1)))

static func _team_formation_heal_total(ctx_list: Array) -> int:
	var total := 0
	for ctx in ctx_list:
		var treasures: Array = (ctx as Dictionary).get("treasures", [])
		if treasures.has("def_formation_heal"):
			total += 2 if TreasureService.has_linkage_in(treasures, "link_hu_pai_master") else 1
	return total

static func _replay_statuses(f: Dictionary) -> Dictionary:
	var statuses = f.get("statuses", {})
	if typeof(statuses) != TYPE_DICTIONARY:
		return {}
	return (statuses as Dictionary).duplicate(true)


static func _replay_capture_roster(state: Dictionary, roster: Dictionary) -> void:
	for f in (state.get("player", []) + state.get("enemy", [])):
		var uid := str(f.get("uid", ""))
		if uid.is_empty() or roster.has(uid):
			continue
		roster[uid] = {
			"uid": uid,
			"id": str(f.get("id", "")),
			"name": str(f.get("name", "")),
			"name_en": str(f.get("name_en", "")),
			"team": str(f.get("team", "")),
			"lane": int(f.get("lane", 0)),
			"max_hp": int(f.get("max_hp", 1)),
			"is_mercenary": bool(f.get("is_mercenary", false)),
			"is_formation_ally": bool(f.get("is_formation_ally", false)),
			"star": int(f.get("star", 1)),
			"footprint_cells": int(f.get("footprint_cells", 1)),
			"owner_slot": int(f.get("owner_slot", -1)),
			"def": f.get("def", {}),
		}


static func step_state(state: Dictionary) -> void:
	if bool(state.get("finished", false)):
		return
	var player: Array = state.player
	var enemy: Array = state.enemy
	BattleSimTreasures._process_revives(state)
	BattleSimTreasures._process_temporary_deaths(state)
	var p_alive := _alive(player)
	var e_alive := _alive(enemy)
	BattleSimTreasures._apply_human_last_stand(state, p_alive)
	if p_alive.is_empty() or (e_alive.is_empty() and state.get("revive_queue", []).is_empty()) or float(state.elapsed) >= HARD_TIMEOUT_SEC:
		state.finished = true
		return
	if not e_alive.is_empty() and not _teams_have_valid_target_pair(p_alive, e_alive):
		state.log.append(TranslationServer.translate("log_stalemate_power"))
		state.finished = true
		return
	_tick_statuses(p_alive + e_alive, state)
	_tick_skills(p_alive, e_alive, state)
	_tick_skills(e_alive, p_alive, state)
	_process_boss_charges(state)
	if float(state.elapsed) >= float(state.next_decay):
		_decay_units(p_alive + e_alive)
		state.log.append(TranslationServer.translate("log_decay_triggered") % float(state.elapsed))
		state.next_decay = float(state.next_decay) + DECAY_INTERVAL_SEC
	_step_team(player, e_alive, float(state.elapsed), state)
	_step_team(enemy, p_alive, float(state.elapsed), state)
	_process_shared_links(state)
	# 本 tick 所有伤害都结算完了，再补发非普攻致死的击杀金（必须在 _step_team 之后）。
	_process_pending_kill_rewards(state)
	BattleSimTreasures._process_race_death_traits(state)
	state.elapsed = float(state.elapsed) + TICK_SEC


static func result_from_state(state: Dictionary) -> Dictionary:
	if state.has("forced_result"):
		var forced: Dictionary = state.forced_result
		var forced_player: Array = state.get("player", [])
		var forced_enemy: Array = state.get("enemy", [])
		var forced_player_alive := _alive(forced_player)
		var forced_enemy_alive := _alive(forced_enemy)
		return {
			"kind": state.get("kind", "pve"),
			"player_wins": bool(forced.get("player_wins", false)),
			"reason": str(forced.get("reason", "forced")),
			"elapsed": float(state.get("elapsed", 0.0)),
			"player_alive": forced_player_alive.size(),
			"enemy_alive": forced_enemy_alive.size(),
			"player_power": timeout_power(forced_player_alive),
			"enemy_power": timeout_power(forced_enemy_alive),
			"player_hp_current": _team_current_hp(forced_player),
			"player_hp_max": _team_max_hp(forced_player),
			"enemy_hp_current": _team_current_hp(forced_enemy),
			"enemy_hp_max": _team_max_hp(forced_enemy),
			"log": forced.get("log", []),
			"kill_gold_by_slot": state.get("kill_gold_by_slot", {}),
			"unit_stats": state.get("unit_stats", {}),
		}
	var player: Array = state.player
	var enemy: Array = state.enemy
	var p_end := _alive(player)
	var e_end := _alive(enemy)
	var player_wins := false
	var reason := "wipeout"
	# is_draw：这一场**真正打平**了（双方全灭，或超时且战力完全相等）。
	# player_wins 保留原有回退值不动 —— 经济结算、伤害盖戳、UI 字幕都在读它，
	# 改它会牵动整条链。真正需要区分平局的地方（第 21 回合 PVP 的整局归属）
	# 单独读 is_draw，见 TeamOutcome.run_outcome。
	# 注意这两处回退都偏向 "player" 侧，而 PVP 的规范化棋局里 "player" 恒为 A 队 ——
	# 也就是说不看 is_draw 就等于默认判 A 队胜。
	var is_draw := false
	if p_end.is_empty() and e_end.is_empty():
		player_wins = true
		is_draw = true
		reason = "double_ko"
	elif e_end.is_empty():
		player_wins = true
	elif p_end.is_empty():
		player_wins = false
	else:
		reason = "hard_timeout_power"
		var p_power := timeout_power(p_end)
		var e_power := timeout_power(e_end)
		if is_equal_approx(p_power, e_power):
			is_draw = true
			player_wins = GameState.player_formation_hp >= GameState.enemy_formation_hp
		else:
			player_wins = p_power > e_power
		state.log.append(TranslationServer.translate("log_timeout_power") % [p_power, e_power])
	return {
		"kind": state.get("kind", "pve"),
		"player_wins": player_wins,
		"is_draw": is_draw,
		"reason": reason,
		"elapsed": float(state.get("elapsed", 0.0)),
		"player_alive": p_end.size(),
		"enemy_alive": e_end.size(),
		"player_power": timeout_power(p_end),
		"enemy_power": timeout_power(e_end),
		"player_hp_current": _team_current_hp(player),
		"player_hp_max": _team_max_hp(player),
		"enemy_hp_current": _team_current_hp(enemy),
		"enemy_hp_max": _team_max_hp(enemy),
		"player_survivor_slots": _survivor_slots(p_end),
		"enemy_survivor_slots": _survivor_slots(e_end),
		"log": state.get("log", []),
		"player_kill_gold": int(state.get("player_kill_gold", 0)),
		"enemy_kill_gold": int(state.get("enemy_kill_gold", 0)),
		"kill_gold_by_slot": state.get("kill_gold_by_slot", {}),
		"player_kills": state.get("player_kills", []),
		"enemy_kills": state.get("enemy_kills", []),
		"bonus_gold": int(state.get("bonus_gold", 0)),
		"unit_stats": state.get("unit_stats", {}),
	}


static func build_tutorial_player_fighters(kind: String) -> Array:
	var out: Array = []
	var unique_ids := {}
	for i in GameState.board_slots.size():
		var cell = GameState.board_slots[i]
		if cell == null or _is_duplicate_unique_cell(cell, unique_ids):
			continue
		out.append(_fighter_from_cell(cell, i, "player"))
	if kind == "pvp" or kind == "final":
		_add_mercenary_fighters(out, GameState.mercenary_slots, "player", false)
	return out


static func build_tutorial_enemy_fighters(kind: String) -> Array:
	match kind:
		"boss": return _build_tutorial_boss_fighters()
		"pvp": return _build_pvp_fighters()
		_: return _build_tutorial_pve_fighters()


static func _enemy_syn_for_kind(kind: String) -> Dictionary:
	# PvP/final: the opponent's race synergies come from their board snapshot.
	# PvE/Boss enemies are monsters with no synergies.
	if kind == "pvp" or kind == "final":
		return NetProtocol.extract_syn(_pvp_opponent_snapshot())
	return {}

# 教学 PVP 的对手棋盘由 TutorialMode.begin_battle() 自己伪造。
# 这里原先读 NetworkService.opponent_board_snapshot，但 1v1 P2P 联机整体删除后
# receive_opponent_snapshot() 已没有任何调用方，那个字典恒为 {} —— 敌方数组为空，
# prepare_tutorial_state 就走 no_enemy_units 提前返回，最后一场 PVP 演示看不到敌人。
static func _pvp_opponent_snapshot() -> Dictionary:
	if not TutorialMode.opponent_snapshot.is_empty():
		return TutorialMode.opponent_snapshot
	return NetworkService.opponent_board_snapshot


static func living_units(state: Dictionary) -> Array:
	return _alive(state.get("player", [])) + _alive(state.get("enemy", []))


static func _build_pvp_fighters() -> Array:
	var snapshot := _pvp_opponent_snapshot()
	var board := NetProtocol.extract_board(snapshot)
	var out: Array = []
	var unique_ids := {}
	for i in board.size():
		var cell = board[i]
		if cell == null or typeof(cell) != TYPE_DICTIONARY or _is_duplicate_unique_cell(cell, unique_ids):
			continue
		out.append(_fighter_from_cell(cell, i, "enemy", true))
	_add_mercenary_fighters(out, NetProtocol.extract_mercenaries(snapshot), "enemy", true)
	return out

static func _build_tutorial_pve_fighters() -> Array:
	var monsters: Array = DataRegistry.get_table("pve_monsters").get("monsters", [])
	if monsters.is_empty():
		return []
	var count := TutorialMode.pve_enemy_count()
	var out: Array = []
	for n in count:
		var d := _tutorial_enemy_def(monsters[n % monsters.size()], 80, 6, 0)
		out.append(_fighter_from_def(d, 2 + n, "enemy", n, count))
	return out

static func _build_tutorial_boss_fighters() -> Array:
	var bosses: Array = DataRegistry.get_table("bosses").get("bosses", [])
	if bosses.is_empty():
		return []
	var d := _tutorial_enemy_def(bosses[0], 650, 18, 0)
	var boss := _fighter_from_def(d, 12, "enemy", 0, 1)
	boss.pos = Vector2(500.0, 116.0)
	return [boss]

static func _tutorial_enemy_def(source: Dictionary, hp: int, atk: int, defense: int) -> Dictionary:
	var d := source.duplicate(true)
	d.hp = hp
	d.atk = atk
	d.def = defense
	d.erase("skill_id")
	d.erase("skill_damage")
	return d

static func _add_mercenary_fighters(out: Array, mercenary_slots: Array, team: String, mirror_enemy_slot: bool) -> void:
	for i in mercenary_slots.size():
		var cell = mercenary_slots[i]
		if cell == null or typeof(cell) != TYPE_DICTIONARY:
			continue
		var visual_slot := GameConstants.CELL_COUNT + i
		var fighter := _fighter_from_cell(cell, visual_slot, team, mirror_enemy_slot)
		fighter.pos = _mercenary_slot_to_pos(i, team, mirror_enemy_slot)
		out.append(fighter)


static func _step_team(team_units: Array, opponents: Array, elapsed: float, state: Dictionary) -> void:
	for f in team_units:
		if not bool(f.get("alive", false)):
			continue
		if StatusEffectService.is_stunned(f):
			continue
		var target := _select_target(f, opponents)
		if target.is_empty():
			continue
		var delta: Vector2 = target.pos - f.pos
		var dist: float = delta.length()
		var attack_distance := _effective_attack_distance(f, target)
		if dist > attack_distance + ATTACK_RANGE_EPS:
			var step := minf(float(f.move_speed_px) * StatusEffectService.move_speed_multiplier(f) * TICK_SEC, maxf(0.0, dist - attack_distance))
			if dist > 0.001:
				f.pos += delta.normalized() * step
		elif elapsed >= float(f.next_attack):
			# Render-only telemetry: preserve the simulator's exact chosen target so
			# projectiles and hit VFX never have to guess from nearby damaged units.
			f.vfx_attack_target_uid = str(target.get("uid", ""))
			DamageService.begin_stat_context(state, f)
			var was_alive := bool(target.get("alive", false))
			var dealt := _perform_attack(f, target, state)
			_handle_attack_kill(f, target, state, team_units, opponents, was_alive)
			if bool(target.get("alive", false)) and str(f.get("def", {}).get("skill_id", "")) == "every_fourth_combo" and int(f.get("attack_count", 0)) % int(f.get("def", {}).get("every", 4)) == 0:
				var combo_alive := bool(target.get("alive", false))
				DamageService.apply_damage(target, maxi(1, int(round(float(f.atk) * float(f.get("def", {}).get("combo_atk_pct", 0.70))))), false)
				_handle_attack_kill(f, target, state, team_units, opponents, combo_alive)
			if str(f.get("def", {}).get("skill_id", "")) == "every_fifth_group_heal" and int(f.get("attack_count", 0)) % int(f.get("def", {}).get("every", 5)) == 0:
				_group_heal(f, team_units, float(f.get("def", {}).get("heal_pct", 0.05)))
			var aspd := clampf(float(f.attack_speed) * StatusEffectService.attack_speed_multiplier(f) * _dynamic_attack_speed_multiplier(f), 0.25, 2.5)
			f.next_attack = elapsed + (1.0 / aspd)
			DamageService.clear_stat_context()


static func _handle_attack_kill(killer: Dictionary, target: Dictionary, state: Dictionary, killer_team: Array, victim_team: Array, was_alive: bool) -> void:
	if not was_alive or bool(target.get("alive", false)):
		return
	_on_unit_killed(killer, target, state, killer_team, victim_team)


static func _tick_statuses(fighters: Array, state: Dictionary) -> void:
	DamageService.set_stat_state(state)
	for f in fighters:
		DamageService.clear_stat_context()
		StatusEffectService.tick(f, TICK_SEC)
	DamageService.clear_stat_context()


static func _perform_attack(attacker: Dictionary, target: Dictionary, state: Dictionary) -> int:
	if StatusEffectService.has_status(attacker, "interrupt"):
		return 0
	var d: Dictionary = attacker.get("def", {})
	var base := float(attacker.get("atk", 1)) * StatusEffectService.attack_multiplier(attacker)
	base *= _element_multiplier(str(d.get("element", "")), str(target.get("def", {}).get("element", "")))
	var syn: Dictionary = _resolve_syn(attacker, state)
	if str(d.get("race", "")) == "dark":
		base *= 1.0 + SynergyService.safe_factor(syn, "dark_damage_bonus") + float(_attacker_dark_stacks(attacker, state)) * 0.06
	if str(d.get("skill_id", "")) == "balance_judge" and int(target.hp) > int(attacker.hp):
		base *= 1.0 + float(d.get("bonus_vs_higher_hp", 0.40))
	if str(d.get("skill_id", "")) == "blood_rampage":
		base *= _blood_rampage_damage_multiplier(attacker, d)
	if str(d.get("skill_id", "")) == "same_target_damage_stack" and str(attacker.get("linked_target_uid", "")) == str(target.get("uid", "")):
		base *= 1.0 + float(attacker.get("skill_stacks", 0)) * float(d.get("stack_damage", 0.06))
	var is_crit := false
	attacker.attack_count = int(attacker.get("attack_count", 0)) + 1
	if str(d.get("race", "")) == "human" and int(attacker.attack_count) % 3 == 0:
		is_crit = true
	elif RngService.rng.randf() < float(d.get("crit", 0.05)) + float(attacker.get("crit_bonus", 0.0)):
		is_crit = true
	if is_crit:
		base *= float(d.get("crit_dmg", 1.5)) + float(attacker.get("crit_dmg_bonus", 0.0))
	var before_status_count := _status_count(target)
	# Only the crit base hit surfaces a floating number; the true-damage rider,
	# combo strikes and treasure reactions below stay silent.
	var basic_skill_id := "basic_ranged" if float(d.get("range", 1.0)) > 1.0 else "basic_melee"
	# D4: windup and contact beats are emitted before the damage call so the tick
	# reads attack_start -> [projectile_spawn] -> impact -> hit_number -> death.
	# Nothing here touches RNG, so the crit roll above keeps its exact position in
	# the deterministic stream.
	DamageService.emit_attack_start(attacker, target, basic_skill_id, basic_skill_id == "basic_ranged")
	DamageService.emit_impact(attacker, target, basic_skill_id, is_crit)
	DamageService.set_hit_context("basic", is_crit, str(d.get("race", "")), basic_skill_id)
	var dealt := DamageService.apply_damage(target, maxi(1, int(round(base))), false)
	DamageService.clear_hit_context()
	if str(d.get("skill_id", "")) == "true_damage_attack":
		var true_pct := float(d.get("true_damage_pct", 0.18))
		# 4 星：每第 3 次攻击真伤翻倍。attack_count 在上面已经自增过，与
		# every_fourth_combo / every_fifth_group_heal 用的是同一个计数与同一种取模写法。
		# 字段只在 4 星的 star4 覆写里出现，所以 1~3 星走的还是原来那一行。
		if bool(d.get("third_hit_double", false)) and int(attacker.get("attack_count", 0)) % 3 == 0:
			true_pct *= 2.0
		dealt += DamageService.apply_damage(target, maxi(1, int(round(float(attacker.atk) * true_pct))), true)
	_apply_attack_statuses(attacker, target, state)
	BattleSimTreasures._apply_attack_treasure_effects(attacker, target, state)
	BattleSimTreasures._maybe_control_set_extra_debuff(attacker, target, state, before_status_count)
	BattleSimTreasures._apply_defender_reaction(attacker, target, dealt)
	BattleSimTreasures._apply_defender_treasure_reaction(target, attacker, state, dealt)
	BattleSimTreasures._apply_boss_attacker_passives(attacker)
	BattleSimTreasures._apply_post_damage_treasures(attacker, target, state, dealt)
	BattleSimTreasures._apply_blood_rampage_lifesteal(attacker, d, dealt)
	BattleSimTreasures._apply_boss_attack_lifesteal(attacker, d, dealt)
	if str(d.get("skill_id", "")) == "same_target_damage_stack":
		if str(attacker.get("linked_target_uid", "")) == str(target.get("uid", "")):
			attacker.skill_stacks = mini(int(d.get("max_stacks", 5)), int(attacker.get("skill_stacks", 0)) + 1)
		else:
			attacker.linked_target_uid = str(target.get("uid", ""))
			attacker.skill_stacks = 1
	var lifesteal := SynergyService.safe_factor(syn, "god_lifesteal")
	if lifesteal > 0.0:
		_heal_unit(attacker, maxi(1, int(round(float(dealt) * lifesteal))))
	return dealt


static func _apply_attack_statuses(attacker: Dictionary, target: Dictionary, state: Dictionary) -> void:
	var d: Dictionary = attacker.get("def", {})
	var sid := str(d.get("skill_id", ""))
	var syn: Dictionary = _resolve_syn(attacker, state)
	var strength := 1.0 + SynergyService.safe_factor(syn, "dark_debuff_strength")
	var duration_bonus := 1.0 + SynergyService.safe_factor(syn, "dark_debuff_duration")
	if sid == "curse_attack":
		StatusEffectService.add_status(target, "attack_down", float(d.get("duration", 4.0)) * duration_bonus, {"pct": float(d.get("attack_down", 0.08)) * strength})
		StatusEffectService.add_status(target, "slow", float(d.get("duration", 4.0)) * duration_bonus, {"attack_speed_pct": float(d.get("aspd_down", 0.08)) * strength, "move_pct": 0.0})
	elif sid == "burn_claw":
		StatusEffectService.add_poison(target, float(d.get("burn_duration", 3.0)), 0.0, 0.0)
		StatusEffectService.add_status(target, "burn", float(d.get("burn_duration", 3.0)), {"dps": float(d.get("burn_dps", 36.0)), "tick_left": 0.0})
	elif sid == "devour_bite":
		_heal_unit(attacker, maxi(1, int(round(float(attacker.atk) * float(d.get("lifesteal", 0.18))))))
	elif sid == "parasite_on_kill":
		target.parasite_owner = attacker
	elif sid == "poison_attack":
		# Poison strength and duration come from the unit def. They used to be
		# hardcoded 0.03 / 4.0 here, which meant the 4-star tier could not touch
		# them -- and poison damage is a share of the TARGET's max HP, so the
		# +15% attack a 4-star grants does nothing for a poison unit's main
		# output (it is 82-93% of what undead_poison actually deals).
		# Defaults match the old constants exactly, so 1-3 star behaviour is
		# unchanged. undead_poison and undead_fly can now be tuned separately.
		StatusEffectService.add_poison(target,
			float(d.get("poison_duration", 4.0)) * duration_bonus,
			float(d.get("poison_pct_max_hp", 0.03)),
			SynergyService.safe_factor(syn, "undead_poison_bonus"))
	elif sid == "defense_down_attack":
		StatusEffectService.add_status(target, "defense_down", float(d.get("duration", 5.0)) * duration_bonus, {"pct": float(d.get("def_down_pct", 0.10)) * strength})
	elif sid == "death_hunt":
		StatusEffectService.add_status(target, "defense_flat_down", float(d.get("duration", 4.0)), {"amount": int(d.get("armor_break", 8))})
		StatusEffectService.add_status(target, "heal_reduction", float(d.get("duration", 4.0)), {"pct": float(d.get("heal_reduction", 0.50))})
	elif sid == "attack_interrupt" and RngService.rng.randf() < float(d.get("interrupt_chance", 0.12)):
		# 4 星把「打断」换成「眩晕」（设计文档 §5.4）：interrupt 只锁普攻、时长硬编码
		# 1 秒；stun 是完整定身、连技能一起锁。stun_sec 只在 4 星的 star4 覆写里有，
		# 所以 1~3 星仍然走 interrupt，行为不变。
		var militia_stun := float(d.get("stun_sec", 0.0))
		if militia_stun > 0.0:
			StatusEffectService.add_status(target, "stun", militia_stun, {})
		else:
			StatusEffectService.interrupt(target)
		var visual_events: Array = state.get("visual_events", [])
		visual_events.append({
			"type": "unit_skill_proc",
			"skill_id": sid,
			"source_uid": str(attacker.get("uid", "")),
			"target_uid": str(target.get("uid", "")),
			"time": float(state.get("elapsed", 0.0)),
		})
		state["visual_events"] = visual_events
	elif sid == "random_attribute_attack":
		_apply_attribute_effect(["fire", "ice", "thunder", "poison"][RngService.rng.randi() % 4], attacker, target)


static func _apply_opening_unit_skills(player: Array, enemy: Array, event_log: Array[String], state: Dictionary) -> void:
	var all_teams := [player, enemy]
	for team_units in all_teams:
		for f in team_units:
			DamageService.begin_stat_context(state, f)
			var d: Dictionary = f.get("def", {})
			var sid := str(d.get("skill_id", ""))
			if d.has("opening_cd"):
				var open_cd := float(d.get("opening_cd", 0.0))
				if open_cd > 0.0:
					f.skill_ready = maxf(float(f.get("skill_ready", 0.0)), open_cd)
			# 4 星天使：开场若干秒控制免疫。注意 opening_cd 是**开场冷却**，
			# 与这个是两件事（设计文档里点名过原稿把两者混为一谈）。
			var immune_sec := float(d.get("control_immune_sec", 0.0))
			if immune_sec > 0.0:
				StatusEffectService.add_status(f, "control_immune", immune_sec, {})
			if sid == "guardian_shield_taunt":
				f.shield = int(f.get("shield", 0)) + maxi(1, int(round(float(f.max_hp) * float(d.get("start_shield_pct", 0.20)))))
				f.taunt_active = true
				f.taunt_radius = float(d.get("taunt_radius", 180.0))
			elif sid == "left_neighbor_sacrifice":
				BattleSimSkills._apply_death_servant_aura(f, team_units, d)
				# 3 星只绑左邻；4 星左右各绑一个（设计文档：绑定左邻是这只棋子唯一的
				# 站位谜题，双向绑定保留博弈、价值翻倍）。死侍只能牺牲一次 ——
				# DamageService._try_sacrifice_revive 会判 guard.alive，
				# 先死的那一侧用掉之后另一侧自然失效，不需要额外记账。
				var servant_slot := int(f.get("slot", -1))
				var bind_offsets: Array = [-1, 1] if float(d.get("ally_def_pct", 0.0)) > 0.0 else [-1]
				for offset in bind_offsets:
					var target := _unit_at_slot(team_units, servant_slot + int(offset))
					if target.is_empty():
						continue
					target.sacrifice_guardian = f
					f.guard_target_uid = str(target.get("uid", ""))
					f.vfx_skill_target_uid = str(target.get("uid", ""))
			DamageService.clear_stat_context()
	if _team_has_skill(player, "guardian_shield_taunt"):
		event_log.append(TranslationServer.translate("log_light_guard"))
	if _team_has_skill(player, "left_neighbor_sacrifice"):
		event_log.append(TranslationServer.translate("log_deadpool_bind"))


# 施法前的距离判定：和普攻用同一套目标选择 + 有效射程。射程内有合法敌人才允许施法。
# 辅助技（治疗/增益）也走这条：nearest 敌人进入自己射程 = 本路已交战，才开始起作用。
static func _skill_target_in_range(caster: Dictionary, opponents: Array) -> bool:
	var target := _select_target(caster, opponents)
	if target.is_empty():
		return false
	var caster_pos: Vector2 = caster.get("pos", Vector2.ZERO)
	var target_pos: Vector2 = target.get("pos", Vector2.ZERO)
	return caster_pos.distance_to(target_pos) <= _effective_attack_distance(caster, target) + ATTACK_RANGE_EPS

static func _tick_skills(casters: Array, opponents: Array, state: Dictionary) -> void:
	for caster in casters:
		if not bool(caster.get("alive", false)):
			continue
		var d: Dictionary = caster.get("def", {})
		var sid := str(d.get("skill_id", ""))
		if sid.is_empty() or sid == "none":
			continue
		if StatusEffectService.has_status(caster, "silence"):
			continue
		if float(state.elapsed) < float(caster.get("skill_ready", 0.0)):
			continue
		# 技能距离判定（方案 A）：自己射程内没有敌人就不放，冷却不消耗，
		# 等敌人进入射程再放。复用普攻同一套 _select_target + _effective_attack_distance，
		# 实现"用单位自己的射程"，堵住"开场冷却一到就隔着半张地图乱开"。
		# 治疗/增益等辅助技也一并按此判定：等自己这一路真正交战了才开始起作用。
		#
		# 例外 skill_global：全场技不吃射程判定。法阵友军里的近战体型（噬兽、厄夜）
		# 否则要贴到脸上才能放"全场"大招，多半没走到就死了。这批的开场时机改由
		# opening_cd 把关，不会一到 0 秒就隔着半张地图开。
		if not bool(d.get("skill_global", false)) and not _skill_target_in_range(caster, opponents):
			continue
		var old_ready := float(caster.get("skill_ready", 0.0))
		DamageService.begin_stat_context(state, caster)
		# Every apply_damage inside this dispatch is skill damage. clear_stat_context()
		# at the end of this iteration resets the tag (see DamageService).
		DamageService.set_hit_context("skill", false, str(d.get("race", "")), sid)
		match sid:
			"lowest_ally_heal":
				BattleSimSkills._skill_lowest_ally_heal(caster, casters, d)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 4.0))
			"nearest_ally_bless":
				BattleSimSkills._skill_nearest_ally_bless(caster, casters, d)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 6.0))
			"nearby_ally_heal_buff":
				BattleSimSkills._skill_nearby_ally_heal_buff(caster, casters, d)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 7.0))
			"random_attribute_bolt":
				BattleSimSkills._skill_random_attribute_bolt(caster, opponents, d)
				caster.attack_count = int(caster.get("attack_count", 0)) + 1
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 2.5))
			"judgement_strike":
				BattleSimSkills._skill_judgement(caster, opponents, d)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 2.0))
			"random_ally_damage_reduction":
				BattleSimSkills._skill_archangel(caster, casters, d)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 6.0))
			"global_divine_blast":
				BattleSimSkills._skill_god_king(caster, opponents, d)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 8.0))
			"silence_bolt":
				BattleSimSkills._skill_silence_bolt(caster, opponents, d, state)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 4.0))
			"fear":
				BattleSimSkills._skill_fear(caster, opponents, d, state)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 6.0))
			"stun":
				BattleSimSkills._skill_stun(caster, opponents, d, state)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 5.0))
			"black_hole":
				BattleSimSkills._skill_black_hole(caster, opponents, d, state)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 8.0))
			"blink_low_def_backline":
				var killed := BattleSimSkills._skill_blink_low_def_backline(caster, casters, opponents, d, state)
				caster.skill_ready = float(state.elapsed) if killed and bool(d.get("refresh_on_kill", false)) else float(state.elapsed) + float(d.get("skill_cd", 5.0))
			"shared_hp_link":
				_skill_shared_hp_link(caster, opponents, d, state)
				caster.skill_ready = float(state.elapsed) + 1.0
			"front_cone_stun":
				BattleSimSkills._skill_front_cone_stun(caster, opponents, d, state)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 5.0))
			"element_meteor":
				BattleSimSkills._skill_element_meteor(caster, opponents, d)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 6.0))
			"holy_purify":
				BattleSimSkills._skill_holy_purify(caster, casters, d)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 8.0))
			"apocalypse_charge":
				BattleSimSkills._skill_apocalypse_charge(caster, state, d)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 10.0))
			"mirror_clone":
				BattleSimSkills._skill_mirror_clone(caster, state, d)
				caster.skill_ready = float(state.elapsed) + 1.0
			"shell_guard":
				BattleSimSkills._skill_shell_guard(caster, d)
				caster.skill_ready = float(state.elapsed) + 6.0
			"bubble_dream":
				BattleSimSkills._skill_bubble_dream(caster, casters, opponents, d)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 6.0))
			"holy_song":
				BattleSimSkills._skill_holy_song(caster, casters, d)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 10.0))
			"twin_strike":
				BattleSimSkills._skill_twin_strike(caster, state, d)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 10.0))
			"arrow_rain":
				BattleSimSkills._skill_arrow_rain(caster, opponents, d)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 6.0))
			"steel_order":
				BattleSimSkills._skill_steel_order(caster, casters, d)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 8.0))
			"time_slow":
				BattleSimSkills._skill_time_slow(caster, opponents, d)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 8.0))
			"gold_charge":
				BattleSimSkills._skill_gold_charge(caster, opponents, d)
				caster.skill_ready = float(state.elapsed) + 7.0
			"king_aura":
				BattleSimSkills._skill_king_aura(caster, casters, d)
				caster.skill_ready = float(state.elapsed) + 2.0
			# 法阵友军。全场技在场上没有可打目标时返回 false，此时不进冷却，留到真正
			# 有敌人时再放——一只只活十几秒的守护者，空放掉一发就等于没有这个技能。
			"burn_claw":
				BattleSimSkills._skill_ally_self_sustain(caster, d)
				caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 5.0))
			"soul_chain":
				if BattleSimSkills._skill_ally_mass_stun(caster, opponents, d):
					caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 9.0))
			"devour_bite":
				if BattleSimSkills._skill_ally_mass_silence(caster, opponents, d):
					caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 12.0))
			"hell_burst":
				if BattleSimSkills._skill_ally_inferno(caster, opponents, d):
					caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 9.0))
			"eternal_night":
				if BattleSimSkills._skill_ally_meteor(caster, opponents, d):
					caster.skill_ready = float(state.elapsed) + float(d.get("skill_cd", 12.0))
		var new_ready := float(caster.get("skill_ready", old_ready))
		if new_ready > float(state.elapsed) and float(caster.get("skill_cd_multiplier", 1.0)) < 1.0:
			caster.skill_ready = float(state.elapsed) + (new_ready - float(state.elapsed)) * float(caster.skill_cd_multiplier)
		if float(caster.get("skill_ready", old_ready)) != old_ready and _skill_cast_should_shake(caster):
			_add_visual_event(state, "skill_shake", caster, 9.0 if bool(d.get("is_boss", false)) or d.has("series") else 6.5, 0.22)
		DamageService.clear_stat_context()


static func _on_unit_killed(killer: Dictionary, victim: Dictionary, state: Dictionary, killer_team: Array, victim_team: Array) -> void:
	state.total_deaths = int(state.get("total_deaths", 0)) + 1
	if str(killer.get("def", {}).get("skill_id", "")) == "death_hunt":
		_heal_unit(killer, maxi(1, int(round(float(killer.max_hp) * float(killer.get("def", {}).get("kill_heal_pct", 0.15))))))
	if str(killer.get("def", {}).get("skill_id", "")) == "soul_devour":
		_heal_unit(killer, maxi(1, int(round(float(killer.max_hp) * float(killer.get("def", {}).get("kill_heal_pct", 0.15))))))
		killer.atk = maxi(1, int(round(float(killer.atk) * (1.0 + float(killer.get("def", {}).get("atk_stack", 0.10))))))
	BattleSimTreasures._queue_twin_revive(victim, state)
	BattleSimTreasures._queue_phoenix_revive(victim, state)
	BattleSimTreasures._apply_soul_counter_treasure(killer, victim)
	if str(victim.get("team", "")) == "enemy":
		_add_kill_reward(state, killer, victim, true)
	else:
		_add_kill_reward(state, killer, victim, false)
	BattleSimTreasures._apply_kill_treasures(killer, victim, victim_team)
	var vd: Dictionary = victim.get("def", {})
	if str(vd.get("skill_id", "")) == "death_poison_explosion":
		for o in killer_team:
			if bool(o.get("alive", false)) and _can_target(victim, o, killer_team) and victim.pos.distance_to(o.pos) <= 180.0:
				DamageService.apply_damage(o, maxi(1, int(round(float(victim.atk) * float(vd.get("damage_atk_pct", 2.5))))), true)
				StatusEffectService.add_poison(o)
	var parasite_owner: Dictionary = victim.get("parasite_owner", {}) if typeof(victim.get("parasite_owner", {})) == TYPE_DICTIONARY else {}
	if not parasite_owner.is_empty() and bool(parasite_owner.get("alive", false)):
		var clone := victim.duplicate(true)
		clone.uid = "%s_parasite_%d" % [str(parasite_owner.team), int(state.get("total_deaths", 0))]
		clone.team = str(parasite_owner.team)
		clone.hp = maxi(1, int(round(float(victim.max_hp) * float(parasite_owner.get("def", {}).get("clone_hp_pct", 0.10)))))
		clone.max_hp = clone.hp
		clone.atk = maxi(1, int(round(float(victim.atk) * float(parasite_owner.get("def", {}).get("clone_atk_def_pct", 0.50)))))
		clone.defense = maxi(0, int(round(float(victim.defense) * float(parasite_owner.get("def", {}).get("clone_atk_def_pct", 0.50)))))
		clone.alive = true
		clone.statuses = {}
		((state.player) if str(parasite_owner.team) == "player" else (state.enemy)).append(clone)
	# 母灵计数已移到每 tick 的死亡清扫 _process_single_race_death 里，
	# 那条路能捕获普攻/技能/AOE 所有致死方式（本入口只覆盖普攻），且天然排除处决。


static func _skill_shared_hp_link(caster: Dictionary, opponents: Array, _d: Dictionary, state: Dictionary) -> void:
	if bool(caster.get("shared_link_spent", false)):
		return
	var current := _fighter_by_uid(state.get("player", []) + state.get("enemy", []), str(caster.get("shared_link_uid", "")))
	if not current.is_empty() and bool(current.get("alive", false)):
		if _is_boss_fighter(current):
			current.erase("shared_link_uid")
			current.erase("shared_link_last_hp")
			caster.erase("shared_link_uid")
			caster.erase("shared_link_last_hp")
		else:
			return
	var target := _nearest_non_boss(caster, opponents)
	if target.is_empty():
		return
	_convert_link_target_to_caster_team(caster, target, opponents, state)
	caster.shared_link_uid = str(target.uid)
	target.shared_link_uid = str(caster.uid)
	caster.vfx_skill_target_uid = str(target.uid)
	caster.shared_link_last_hp = int(caster.hp)
	target.shared_link_last_hp = int(target.hp)
	caster.shared_link_spent = true
	state.log.append(TranslationServer.translate("log_convert") % [str(caster.get("name", "?")), str(target.get("name", "?"))])


static func _nearest_non_boss(f: Dictionary, opponents: Array) -> Dictionary:
	var best: Dictionary = {}
	var best_dist := INF
	for o in opponents:
		if not bool(o.get("alive", false)) or _is_boss_fighter(o) or not _can_target(f, o, opponents):
			continue
		var dist: float = float(f.pos.distance_squared_to(o.pos))
		if dist < best_dist:
			best_dist = dist
			best = o
	return best


static func _is_boss_fighter(fighter: Dictionary) -> bool:
	var d: Dictionary = fighter.get("def", {})
	var id := str(fighter.get("id", d.get("id", "")))
	return bool(d.get("is_boss", false)) or id.begins_with("boss_")


static func _convert_link_target_to_caster_team(caster: Dictionary, target: Dictionary, opponents: Array, state: Dictionary) -> void:
	var caster_team := str(caster.get("team", ""))
	var old_team := str(target.get("team", ""))
	if caster_team.is_empty() or old_team == caster_team:
		return
	var from_team: Array = state.get("player", []) if old_team == "player" else state.get("enemy", [])
	var to_team: Array = state.get("player", []) if caster_team == "player" else state.get("enemy", [])
	from_team.erase(target)
	opponents.erase(target)
	target.team = caster_team
	to_team.append(target)


static func _lowest_def_backline(caster: Dictionary, opponents: Array) -> Dictionary:
	var pool := []
	for o in opponents:
		if bool(o.get("alive", false)) and _can_target(caster, o, opponents):
			pool.append(o)
	if pool.is_empty():
		return {}
	pool.sort_custom(func(a, b):
		var ad := int(a.get("defense", 0))
		var bd := int(b.get("defense", 0))
		if ad != bd:
			return ad < bd
		var aback := float(a.pos.y) if str(caster.get("team", "")) == "player" else ARENA_H - float(a.pos.y)
		var bback := float(b.pos.y) if str(caster.get("team", "")) == "player" else ARENA_H - float(b.pos.y)
		# C23a：防御和纵深都相同时的稳定次级键。同样是选目标的排序，
		# 平手时顺序不定 = 战斗结果不定。
		if not is_equal_approx(aback, bback):
			return aback < bback
		return str(a.get("uid", "")) < str(b.get("uid", ""))
	)
	return pool[0]


static func _process_shared_links(state: Dictionary) -> void:
	var fighters: Array = state.get("player", []) + state.get("enemy", [])
	var processed := {}
	for f in fighters:
		if not bool(f.get("alive", false)):
			_clear_shared_link_for_dead_unit(f, fighters)
			continue
		var uid := str(f.get("uid", ""))
		if processed.has(uid):
			continue
		var peer_uid := str(f.get("shared_link_uid", ""))
		if peer_uid.is_empty():
			continue
		var peer := _fighter_by_uid(fighters, peer_uid)
		if peer.is_empty() or not bool(peer.get("alive", false)):
			f.erase("shared_link_uid")
			f.erase("shared_link_last_hp")
			continue
		processed[uid] = true
		processed[str(peer.get("uid", ""))] = true
		var f_loss := maxi(0, int(f.get("shared_link_last_hp", f.hp)) - int(f.hp))
		var peer_loss := maxi(0, int(peer.get("shared_link_last_hp", peer.hp)) - int(peer.hp))
		if f_loss > 0:
			DamageService.apply_damage(peer, f_loss, true)
		if peer_loss > 0:
			DamageService.apply_damage(f, peer_loss, true)
		f.shared_link_last_hp = int(f.hp)
		peer.shared_link_last_hp = int(peer.hp)
		# 4 星末日守卫：链接期间每秒回自己一定比例的最大生命。
		# 原稿写的是「每秒回 30 血」的绝对值 —— 全表唯一，4 星完全没变强，
		# 所以改成百分比（设计文档 §5.7）。link_regen_pct 只在 4 星的 star4
		# 覆写里有，1~3 星这里一行都不执行。
		_apply_shared_link_regen(f, peer)


# 链接双方里，谁是末日守卫谁回血（另一方是被链接的敌人，不回）。
# 按 tick 折算：TICK_SEC 是 0.1 秒，所以每 tick 回「每秒量」的十分之一。
static func _apply_shared_link_regen(a: Dictionary, b: Dictionary) -> void:
	for unit in [a, b]:
		var pct := float((unit.get("def", {}) as Dictionary).get("link_regen_pct", 0.0))
		if pct <= 0.0:
			continue
		var per_tick := int(round(float(unit.get("max_hp", 0)) * pct * TICK_SEC))
		if per_tick > 0:
			_heal_unit(unit, per_tick)


static func _clear_shared_link_for_dead_unit(unit: Dictionary, fighters: Array) -> void:
	var peer_uid := str(unit.get("shared_link_uid", ""))
	if peer_uid.is_empty():
		return
	var peer := _fighter_by_uid(fighters, peer_uid)
	unit.erase("shared_link_uid")
	unit.erase("shared_link_last_hp")
	if not peer.is_empty():
		peer.erase("shared_link_uid")
		peer.erase("shared_link_last_hp")

static func _fighter_by_uid(fighters: Array, uid: String) -> Dictionary:
	if uid.is_empty():
		return {}
	for f in fighters:
		if str(f.get("uid", "")) == uid:
			return f
	return {}


static func _process_boss_charges(state: Dictionary) -> void:
	for caster in state.get("player", []) + state.get("enemy", []):
		if not bool(caster.get("alive", false)) or not caster.has("apocalypse_due"):
			continue
		if int(caster.get("shield", 0)) <= 0:
			caster.erase("apocalypse_due")
			state.log.append(TranslationServer.translate("log_arbiter_interrupted"))
			continue
		if float(state.elapsed) < float(caster.apocalypse_due):
			continue
		var opponents: Array = state.player if str(caster.team) == "enemy" else state.enemy
		DamageService.begin_stat_context(state, caster)
		for o in opponents:
			if bool(o.get("alive", false)) and _can_target(caster, o, opponents):
				DamageService.apply_damage(o, maxi(1, int(round(float(caster.atk) * float(caster.get("apocalypse_damage_atk_pct", 2.5))))), bool(caster.get("apocalypse_ignore_def", true)))
		DamageService.clear_stat_context()
		state.log.append(TranslationServer.translate("log_arbiter_charged"))
		caster.erase("apocalypse_due")
		caster.erase("apocalypse_damage_atk_pct")
		caster.erase("apocalypse_ignore_def")


static func _add_team_final_formation_allies(player: Array, enemy: Array) -> void:
	var pd := _formation_ally_def_for_hp(GameState.team_hp)
	if not pd.is_empty():
		var p := _fighter_from_def(pd, 22, "player", player.size(), 26, 1, false, true)
		p.pos = Vector2(TEAM_LANE_CENTERS[1], _opening_y("player", 180.0))
		p["lane"] = 1
		p.uid = "player_team_final_ally"
		player.append(p)
	var ed := _formation_ally_def_for_hp(GameState.enemy_team_hp)
	if not ed.is_empty():
		var e := _fighter_from_def(ed, 2, "enemy", enemy.size(), 26, 1, false, true)
		e.pos = Vector2(TEAM_LANE_CENTERS[1], _opening_y("enemy", 180.0))
		e["lane"] = 1
		e.uid = "enemy_team_final_ally"
		enemy.append(e)

static func _add_final_formation_allies(player: Array, enemy: Array) -> void:
	var pd := _formation_ally_def_for_hp(GameState.player_formation_hp)
	if not pd.is_empty():
		player.append(_fighter_from_def(pd, 22, "player", player.size(), 26, 1, false, true))
	var ed := _formation_ally_def_for_hp(GameState.enemy_formation_hp)
	if not ed.is_empty():
		enemy.append(_fighter_from_def(ed, 2, "enemy", enemy.size(), 26, 1, false, true))


# Final Round alone changes the real combat axis. Rotating simulation positions
# keeps movement, targeting, projectiles, attack range and replay visuals aligned.
static func _apply_final_round_left_right_layout(player: Array, enemy: Array) -> void:
	for fighter in player + enemy:
		var old_pos := Vector2(fighter.get("pos", Vector2(ARENA_W * 0.5, ARENA_H * 0.5)))
		var rotated := Vector2(
			(1.0 - old_pos.y / ARENA_H) * ARENA_W,
			old_pos.x / ARENA_W * ARENA_H
		)
		fighter.pos = Vector2(
			clampf(rotated.x, 80.0, ARENA_W - 80.0),
			clampf(rotated.y, 60.0, ARENA_H - 60.0)
		)
	for fighter in player:
		if bool(fighter.get("is_formation_ally", false)):
			fighter.pos = Vector2(440.0, 195.0)
			fighter["lane"] = 1
	for fighter in enemy:
		if bool(fighter.get("is_formation_ally", false)):
			fighter.pos = Vector2(560.0, 195.0)
			fighter["lane"] = 1


# 击杀金补结算：普通攻击打死目标时 _handle_attack_kill 会即时结算，但技能 / AOE /
# 反伤等其他致死路径不走那条线，过去这些击杀一分钱都不产生（阵容里 AOE 越多收入越低）。
# 这里在每个 tick 收尾扫一遍新死亡、按 DamageService 记下的 killer_uid 找回击杀者补上。
# 与 _process_race_death_traits 同款清扫模式。
# 无来源的死亡（中毒/失血/衰减：_tick_statuses 会清空来源上下文）仍不结算——
# 找不到归属者，见 docs/金币系统.md 的「既存限制」。
static func _process_pending_kill_rewards(state: Dictionary) -> void:
	var fighters: Array = state.get("player", []) + state.get("enemy", [])
	var by_uid := {}
	for f in fighters:
		by_uid[str(f.get("uid", ""))] = f
	for f in fighters:
		if bool(f.get("alive", true)) and int(f.get("hp", 0)) > 0:
			continue
		if bool(f.get("kill_reward_paid", false)):
			continue
		var killer_uid := str(f.get("killer_uid", ""))
		if killer_uid.is_empty() or not by_uid.has(killer_uid):
			continue
		var killer: Dictionary = by_uid[killer_uid]
		if str(killer.get("uid", "")) == str(f.get("uid", "")):
			continue
		_add_kill_reward(state, killer, f, str(f.get("team", "")) == "enemy")


static func _credit_slot(state: Dictionary, slot: int, amount: int) -> void:
	if slot < 0 or amount <= 0:
		return
	var by_slot: Dictionary = state.get("kill_gold_by_slot", {})
	by_slot[slot] = int(by_slot.get(slot, 0)) + amount
	state.kill_gold_by_slot = by_slot


# 跨路击杀时被入侵那条路的主人（清空自己路的棋子可以去支援别路，见 _can_target）。
# 没有跨路、或拿不到映射时返回 -1。lane 是出生时定死的归属路，棋子跑位不会影响判定。
static func _lane_owner_slot_for_kill(state: Dictionary, killer: Dictionary, victim: Dictionary, player_killed_enemy: bool) -> int:
	var killer_lane := int(killer.get("lane", -1))
	var victim_lane := int(victim.get("lane", -1))
	if killer_lane < 0 or victim_lane < 0 or killer_lane == victim_lane:
		return -1
	var lane_map: Array = state.get("ally_slots", []) if player_killed_enemy else state.get("rival_slots", [])
	if victim_lane >= lane_map.size():
		return -1
	return int(lane_map[victim_lane])


static func _add_kill_reward(state: Dictionary, killer: Dictionary, victim: Dictionary, player_killed_enemy: bool) -> void:
	# 标记本次死亡已结算，_process_pending_kill_rewards 的补结算清扫据此跳过。
	# 复活时会被清掉，所以复活后再被打死仍会再次结算（与既有行为一致）。
	victim["kill_reward_paid"] = true
	var reward := _kill_reward_for_victim(victim, state)
	var rec := {"killer": str(killer.get("id", "")), "victim": str(victim.get("id", "")), "reward": reward}
	var owner_slot := int(killer.get("owner_slot", -1))
	# 跨路击杀：赏金对半分，一半给击杀者、一半给路线主（奇数时余数归击杀者）。
	# 回合奖励/胜利金按队伍发放，不在这里参与分配。
	var lane_owner_slot := _lane_owner_slot_for_kill(state, killer, victim, player_killed_enemy)
	if owner_slot >= 0 and lane_owner_slot >= 0 and lane_owner_slot != owner_slot:
		var lane_share := reward / 2
		_credit_slot(state, owner_slot, reward - lane_share)
		_credit_slot(state, lane_owner_slot, lane_share)
	else:
		_credit_slot(state, owner_slot, reward)
	state.log.append(TranslationServer.translate("log_kill") % [str(killer.get("name", killer.get("id", "?"))), str(victim.get("name", victim.get("id", "?"))), reward])
	if player_killed_enemy:
		state.player_kill_gold = int(state.get("player_kill_gold", 0)) + reward
		var arr: Array = state.get("player_kills", [])
		arr.append(rec)
		state.player_kills = arr
	else:
		state.enemy_kill_gold = int(state.get("enemy_kill_gold", 0)) + reward
		var arr2: Array = state.get("enemy_kills", [])
		arr2.append(rec)
		state.enemy_kills = arr2
