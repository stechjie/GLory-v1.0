class_name BattleSimTreasures
extends BattleSimShared

static func _process_race_death_traits(state: Dictionary) -> void:
	var fighters: Array = []
	fighters.append_array(state.get("player", []))
	fighters.append_array(state.get("enemy", []))
	for f in fighters:
		if bool(f.get("alive", true)) or int(f.get("hp", 0)) > 0:
			continue
		_process_single_race_death(state, f)


static func _process_single_race_death(state: Dictionary, victim: Dictionary) -> void:
	if victim.is_empty():
		return
	var uid := str(victim.get("uid", ""))
	if uid.is_empty():
		return
	var processed: Dictionary = state.get("race_trait_processed_deaths", {})
	if bool(processed.get(uid, false)):
		return
	processed[uid] = true
	state.race_trait_processed_deaths = processed
	if bool(victim.get("mother_execute_kill", false)):
		return
	state.field_death_count = int(state.get("field_death_count", 0)) + 1
	_record_death_history(state, victim)
	# 母灵计数在这里进行：此路径覆盖普攻/技能/AOE 所有致死方式，
	# 且上面的 mother_execute_kill 早退已把处决击杀排除在外。
	_credit_mother_kill(state, victim)
	if state.has("owner_syn_by_key"):
		# 3v3: each effect uses the dead unit's / opponent's OWNER synergy.
		_owner_god_cleanse(state, victim)
		_owner_dark_stack_on_death(state, victim)
		_owner_undead_clone_on_death(state, victim)
		return
	# 1v1: both sides use their own synergy (player_syn / enemy_syn).
	var vteam := str(victim.get("team", ""))
	var opp := "enemy" if vteam == "player" else "player"
	_maybe_god_death_cleanse(state, vteam)
	_apply_dark_death_stack(state, opp)
	_maybe_undead_death_clone(state, "player")
	_maybe_undead_death_clone(state, "enemy")

# (1) 神族·死亡净化: owner's unit dies -> cleanse one of the owner's units,
# preferring its own; once the owner's lane enemies are cleared, can extend to
# the owner's allies (same team, other lanes).

static func _owner_god_cleanse(state: Dictionary, victim: Dictionary) -> void:
	var key := _owner_key(victim)
	if not bool(_owner_syn(state, key).get("god_death_cleanse", false)):
		return
	var team := str(victim.get("team", ""))
	var lane := int(victim.get("lane", -1))
	var side: Array = state.get("player", []) if team == "player" else state.get("enemy", [])
	var pool: Array = []
	var extend := _owner_lane_enemies_cleared(state, team, lane)
	for f in side:
		if not bool(f.get("alive", false)) or int(f.get("hp", 0)) <= 0:
			continue
		if extend or int(f.get("lane", -1)) == lane:
			pool.append(f)
	if pool.is_empty():
		return
	var target: Dictionary = pool[RngService.rng.randi() % pool.size()]
	if StatusEffectService.clear_negative_statuses(target) > 0:
		state.log.append(TranslationServer.translate("log_god_cleanse") % str(target.get("name", TranslationServer.translate("name_ally"))))

# (2) 暗族·死亡叠伤: count ALL deaths of the opposing team for each dark owner.

static func _owner_dark_stack_on_death(state: Dictionary, victim: Dictionary) -> void:
	var opp_team := "enemy" if str(victim.get("team", "")) == "player" else "player"
	for lane in 3:
		var key := "%s_%d" % [opp_team, lane]
		if not bool(_owner_syn(state, key).get("dark_death_stack_enabled", false)):
			continue
		var os := _owner_state(state, key)
		os.dark_enemy_deaths = int(os.get("dark_enemy_deaths", 0)) + 1
		os.dark_stacks = floori(float(int(os.dark_enemy_deaths)) / 3.0)

# (3) 亡灵·死亡克隆: count ALL deaths (whole field) for each undead owner.

static func _owner_undead_clone_on_death(state: Dictionary, victim: Dictionary) -> void:
	for key in state.get("owner_syn_by_key", {}):
		var threshold := int(_owner_syn(state, key).get("undead_death_clone_threshold", 0))
		if threshold <= 0:
			continue
		var os := _owner_state(state, key)
		os.undead_deaths = int(os.get("undead_deaths", 0)) + 1
		if int(os.undead_deaths) < threshold:
			continue
		os.undead_deaths = 0
		_owner_clone_dead_undead(state, key)


static func _owner_clone_dead_undead(state: Dictionary, key: String) -> void:
	var parts := key.split("_")
	if parts.size() < 2:
		return
	var team := str(parts[0])
	var lane := int(parts[1])
	var side: Array = state.get("player", []) if team == "player" else state.get("enemy", [])
	var summoner: Dictionary = {}
	for f in side:
		if bool(f.get("alive", false)) and int(f.get("hp", 0)) > 0 and int(f.get("lane", -1)) == lane and str(f.get("def", {}).get("race", "")) == "undead" and not bool(f.get("is_race_trait_clone", false)):
			summoner = f
			break
	if summoner.is_empty():
		return
	var sources: Array = []
	for h in state.get("death_history", []):
		if str(h.get("team", "")) == team and int(h.get("lane", -1)) == lane and str(h.get("def", {}).get("race", "")) == "undead":
			sources.append(h)
	if sources.is_empty():
		return
	var source: Dictionary = sources[RngService.rng.randi() % sources.size()]
	_spawn_undead_trait_clone(state, summoner, source, int(state.get("field_death_count", 0)))
	state.log.append(TranslationServer.translate("log_necro_summon"))


static func _maybe_god_death_cleanse(state: Dictionary, team: String) -> void:
	# A unit of `team` died -> that team's god synergy cleanses one of its units.
	var syn: Dictionary = _team_syn(state, team)
	if not bool(syn.get("god_death_cleanse", false)):
		return
	var side: Array = state.get("player", []) if team == "player" else state.get("enemy", [])
	var candidates: Array = []
	for f in side:
		if bool(f.get("alive", false)) and int(f.get("hp", 0)) > 0:
			candidates.append(f)
	if candidates.is_empty():
		return
	var target: Dictionary = candidates[RngService.rng.randi() % candidates.size()]
	var removed := StatusEffectService.clear_negative_statuses(target)
	if removed > 0:
		state.log.append(TranslationServer.translate("log_god_cleanse") % str(target.get("name", TranslationServer.translate("name_ally"))))


static func _apply_dark_death_stack(state: Dictionary, team: String) -> void:
	# `team` is the dark-benefiting side; it counts the opposing side's deaths.
	var syn: Dictionary = _team_syn(state, team)
	if not bool(syn.get("dark_death_stack_enabled", false)):
		return
	var deaths_key := "enemy_deaths" if team == "player" else "player_deaths"
	var stacks_key := "dark_kill_stacks" if team == "player" else "enemy_dark_kill_stacks"
	state[deaths_key] = int(state.get(deaths_key, 0)) + 1
	var new_stacks := floori(float(int(state[deaths_key])) / 3.0)
	if new_stacks > int(state.get(stacks_key, 0)):
		state[stacks_key] = new_stacks
		state.log.append(TranslationServer.translate("log_dark_stack") % [int(state[deaths_key]), new_stacks * 6])


static func _maybe_undead_death_clone(state: Dictionary, team: String) -> void:
	# Whole-field deaths accumulate per undead owner; each side clones independently.
	var syn: Dictionary = _team_syn(state, team)
	var threshold := int(syn.get("undead_death_clone_threshold", 0))
	if threshold <= 0:
		return
	var counter_key := "undead_trait_death_counter" if team == "player" else "enemy_undead_trait_death_counter"
	state[counter_key] = int(state.get(counter_key, 0)) + 1
	if int(state[counter_key]) < threshold:
		return
	state[counter_key] = 0
	var history: Array = state.get("death_history", [])
	if history.is_empty():
		return
	var side: Array = state.get("player", []) if team == "player" else state.get("enemy", [])
	var summoners: Array = []
	for f in side:
		if bool(f.get("alive", false)) and int(f.get("hp", 0)) > 0 and str(f.get("def", {}).get("race", "")) == "undead" and not bool(f.get("is_race_trait_clone", false)):
			summoners.append(f)
	if summoners.is_empty():
		return
	var spawned := 0
	for summoner in summoners:
		var source: Dictionary = history[RngService.rng.randi() % history.size()]
		_spawn_undead_trait_clone(state, summoner, source, spawned)
		spawned += 1
	if spawned > 0:
		state.log.append(TranslationServer.translate("log_necro_threshold") % [threshold, spawned])


static func _spawn_undead_trait_clone(state: Dictionary, summoner: Dictionary, source: Dictionary, idx: int) -> void:
	# 已审计（勿降级）：source 来自 death_history 共享数据，clone/def 随后被
	# 大量写入（erase/改 id），浅拷会污染历史记录和原单位 def。每场只跑几次。
	var clone := source.duplicate(true)
	var cloned_def: Dictionary = clone.get("def", {}).duplicate(true)
	var base_id := str(source.get("id", cloned_def.get("id", "unit")))
	var clone_id := "undead_trait_clone_%s" % base_id
	cloned_def.id = clone_id
	cloned_def.name = TranslationServer.translate("name_clone_suffix") % str(source.get("name", cloned_def.get("name", TranslationServer.translate("name_unit"))))
	cloned_def.erase("is_boss")
	cloned_def.erase("series")
	cloned_def.erase("unique_on_board")
	cloned_def.erase("remove_on_death")
	clone.uid = "%s_undead_trait_%d_%d" % [str(summoner.get("uid", "undead")), int(state.get("field_death_count", 0)), idx]
	clone.id = clone_id
	clone.name = str(cloned_def.name)
	clone.team = str(summoner.get("team", "player"))
	clone["lane"] = int(summoner.get("lane", -1))
	clone["owner_treasures"] = []
	clone["owner_syn"] = summoner.get("owner_syn", {})
	clone.slot = -1
	clone.def = cloned_def
	clone.star = 1
	clone.is_mercenary = false
	clone.is_formation_ally = false
	clone.is_race_trait_clone = true
	clone.max_hp = maxi(1, int(round(float(source.get("max_hp", source.get("hp", cloned_def.get("hp", 1)))) * 0.40)))
	clone.hp = int(clone.max_hp)
	clone.atk = maxi(1, int(round(float(source.get("atk", cloned_def.get("atk", 1))) * 0.40)))
	clone.defense = maxi(0, int(round(float(source.get("defense", cloned_def.get("def", 0))) * 0.40)))
	cloned_def.hp = int(clone.max_hp)
	cloned_def.atk = int(clone.atk)
	cloned_def.def = int(clone.defense)
	clone.attack_speed = float(source.get("attack_speed", cloned_def.get("attack_speed", 1.0)))
	clone.range_px = float(source.get("range_px", float(cloned_def.get("range", 1)) * ATTACK_RANGE_SCALE))
	clone.move_speed_px = float(source.get("move_speed_px", float(cloned_def.get("move_speed", 3.0)) * 55.0))
	var offset_x := (float(idx % GameConstants.BOARD_COLUMNS) - (float(GameConstants.BOARD_COLUMNS) - 1.0) * 0.5) * 18.0
	var offset_y := float(floori(float(idx) / float(GameConstants.BOARD_COLUMNS)) + 1) * 18.0
	clone.pos = Vector2(clampf(float(summoner.pos.x) + offset_x, 80.0, ARENA_W - 80.0), clampf(float(summoner.pos.y) + offset_y, 45.0, ARENA_H - 45.0))
	clone.next_attack = float(state.get("elapsed", 0.0)) + 0.2
	clone.alive = true
	clone.shield = 0
	clone.attack_count = 0
	clone.skill_ready = 9999.0
	clone.skill_stacks = 0
	clone.linked_target_uid = ""
	clone.statuses = {}
	clone.dodge = float(source.get("dodge", cloned_def.get("dodge", 0.0)))
	clone.revives_left = 0
	clone.treasure_cd = {}
	clone.erase("parasite_owner")
	clone.erase("sacrifice_guardian")
	clone.erase("shared_link_uid")
	clone.erase("shared_link_peer")
	if str(clone.team) == "player":
		state.player.append(clone)
	else:
		state.enemy.append(clone)


static func _apply_attack_treasure_effects(attacker: Dictionary, target: Dictionary, state: Dictionary) -> void:
	if _ignores_treasure(attacker):
		return
	if _f_has_treasure(attacker, "atk_frenzy_assault"):
		_apply_frenzy_assault(attacker, target)
	if _f_has_treasure(attacker, "elem_flame_shatter") and RngService.rng.randf() < 0.25:
		_apply_attribute_effect("fire", attacker, target)
	if _f_has_treasure(attacker, "elem_frost_blade") and RngService.rng.randf() < 0.25:
		_apply_attribute_effect("ice", attacker, target)
	if _f_has_treasure(attacker, "elem_thunder_haste") and RngService.rng.randf() < 0.25:
		StatusEffectService.add_status(attacker, "speed_bonus", 3.0, {"pct": 0.60})
	if _f_has_treasure(attacker, "elem_toxic_spread") and RngService.rng.randf() < 0.25:
		_apply_attribute_effect("poison", attacker, target)
	if _f_has_set(attacker, "element") and RngService.rng.randf() < 0.20:
		_apply_element_set_burst(attacker, target, state)
	if _f_has_treasure(attacker, "ctrl_shockwave") and _treasure_ready(attacker, "ctrl_shockwave", float(state.elapsed)):
		var shock_duration := 2.0 if _f_has_linkage(attacker, "link_hu_pai_master") else 1.0
		StatusEffectService.add_status(target, "stun", shock_duration, {})
		_set_treasure_cd(attacker, "ctrl_shockwave", float(state.elapsed), 5.0)
	if _f_has_treasure(attacker, "ctrl_corrosive_needle") and int(attacker.get("attack_count", 0)) % 4 == 0 and _treasure_ready(attacker, "ctrl_corrosive_needle", float(state.elapsed)):
		StatusEffectService.add_bleed(target, 3.0, 0.06)
		_set_treasure_cd(attacker, "ctrl_corrosive_needle", float(state.elapsed), 5.0)
	if _f_has_treasure(attacker, "ctrl_interrupt_chain") and _treasure_ready(attacker, "ctrl_interrupt_chain", float(state.elapsed)):
		if RngService.rng.randf() < 0.25:
			StatusEffectService.interrupt(target)
			if _f_has_linkage(attacker, "link_paralysis_shackles"):
				_apply_attribute_effect("ice", attacker, target)
				StatusEffectService.add_status(target, "ice_vulnerable", 3.0, {"pct": 0.15})
		_set_treasure_cd(attacker, "ctrl_interrupt_chain", float(state.elapsed), 5.0)
	if _f_has_treasure(attacker, "ctrl_binding_weight") and _treasure_ready(attacker, "ctrl_binding_weight", float(state.elapsed)):
		StatusEffectService.add_status(target, "slow", 2.0, {"move_pct": 0.25, "attack_speed_pct": 0.20})
		_set_treasure_cd(attacker, "ctrl_binding_weight", float(state.elapsed), 5.0)




static func _apply_opening_treasures(player: Array, event_log: Array[String]) -> void:
	for f in player:
		if _ignores_treasure(f):
			continue
		if _f_has_treasure(f, "def_iron_wall"):
			f.defense = int(f.get("defense", 0)) + 10
		if _f_has_treasure(f, "def_life_monument"):
			var life_multiplier := 1.40 if _f_has_linkage(f, "link_hu_pai_master") else 1.20
			f.max_hp = maxi(1, int(round(float(f.max_hp) * life_multiplier)))
			f.hp = int(f.max_hp)
		if _f_has_treasure(f, "def_phantom_step"):
			f.dodge = float(f.get("dodge", 0.0)) + 0.20
		if _f_has_treasure(f, "ctrl_time_compress"):
			f.skill_cd_multiplier = 0.75
			f.skill_ready = float(f.get("skill_ready", 0.0)) * 0.75
		if _f_has_treasure(f, "atk_blood_pact"):
			var blood_multiplier := 1.50 if _f_has_linkage(f, "link_hu_pai_master") else 1.25
			f.atk = maxi(1, int(round(float(f.atk) * blood_multiplier)))
			StatusEffectService.add_bleed(f, 999.0, 0.06)
		if _f_has_treasure(f, "atk_burst_core"):
			f.crit_bonus = float(f.get("crit_bonus", 0.0)) + 0.25
		# 宠物开局加成（按该棋子所属者的出战宠物）：蘑菇 +生命 / 鸭子 +攻击。
		var pet_id := _f_pet(f)
		if not pet_id.is_empty():
			var hp_mult := PetService.opening_hp_mult(pet_id)
			if hp_mult != 1.0:
				f.max_hp = maxi(1, int(round(float(f.max_hp) * hp_mult)))
				f.hp = int(f.max_hp)
			var atk_mult := PetService.opening_atk_mult(pet_id)
			if atk_mult != 1.0:
				f.atk = maxi(1, int(round(float(f.atk) * atk_mult)))
	if GameState.owned_treasures.has("ctrl_time_compress"):
		event_log.append(TranslationServer.translate("log_time_compress"))


static func _apply_post_damage_treasures(attacker: Dictionary, target: Dictionary, state: Dictionary, dealt: int) -> void:
	if _ignores_treasure(attacker) or dealt <= 0:
		return
	if _f_has_treasure(attacker, "def_lifesteal_emblem"):
		_heal_unit(attacker, maxi(1, int(round(float(dealt) * 0.20))))
	if _f_has_linkage(attacker, "link_toxic_burst"):
		_try_toxic_burst(target)
	if _f_has_linkage(attacker, "link_rich_path"):
		if RngService.rng.randf() < 0.10:
			state.bonus_gold = int(state.get("bonus_gold", 0)) + 10


static func _apply_defender_treasure_reaction(defender: Dictionary, attacker: Dictionary, state: Dictionary, _dealt: int) -> void:
	if _ignores_treasure(defender) or not bool(attacker.get("alive", true)):
		return
	var prev_source := DamageService.current_stat_source_uid()
	DamageService.begin_stat_context(state, defender)
	if _f_has_linkage(defender, "link_oppression_counter"):
		_apply_frenzy_assault(defender, attacker)
		StatusEffectService.add_status(attacker, "attack_down", 2.0, {"pct": 0.20})
	if _f_has_linkage(defender, "link_iron_maiden") and _treasure_ready(defender, "link_iron_maiden", float(state.elapsed)):
		StatusEffectService.add_bleed(attacker, 3.0, 0.06)
		StatusEffectService.add_status(attacker, "defense_flat_down", 3.0, {"amount": 6})
		_set_treasure_cd(defender, "link_iron_maiden", float(state.elapsed), 5.0)
	DamageService.set_stat_source_uid(prev_source)


static func _apply_kill_treasures(killer: Dictionary, victim: Dictionary, enemies: Array) -> void:
	if _ignores_treasure(killer):
		return
	if _f_has_treasure(killer, "atk_wail_resonance"):
		for o in enemies:
			if bool(o.get("alive", false)) and _can_target(killer, o, enemies) and victim.pos.distance_to(o.pos) <= 180.0:
				DamageService.apply_damage(o, maxi(1, int(round(float(o.max_hp) * 0.15))), true)




static func _try_toxic_burst(target: Dictionary) -> void:
	StatusEffectService.ensure_status(target)
	if not bool(target.get("alive", false)) or not target.statuses.has("poison") or RngService.rng.randf() >= 0.50:
		return
	var poison: Dictionary = target.statuses.get("poison", {})
	var remaining := maxf(0.0, float(poison.get("remaining", 0.0)))
	var ticks := int(ceil(remaining / StatusEffectService.POISON_TICK_SEC))
	if ticks <= 0:
		return
	var tick_damage := maxi(1, int(floor(float(target.max_hp) * float(poison.get("pct_max_hp", 0.03)))))
	DamageService.apply_damage(target, tick_damage * ticks, true)
	target.statuses.erase("poison")

static func _apply_soul_counter_treasure(killer: Dictionary, victim: Dictionary) -> void:
	if _ignores_treasure(victim):
		return
	if not _f_has_treasure(victim, "def_soul_counter"):
		return
	if not bool(killer.get("alive", false)):
		return
	DamageService.apply_damage(killer, maxi(1, int(round(float(killer.get("max_hp", 1)) * 0.35))), true)


static func _queue_phoenix_revive(victim: Dictionary, state: Dictionary) -> void:
	if _ignores_treasure(victim):
		return
	if not _f_has_linkage(victim, "link_phoenix"):
		return
	if bool(victim.get("phoenix_used", false)):
		return
	var revived := victim.duplicate(true)
	revived.uid = "%s_phoenix_%d" % [str(victim.uid), int(state.get("total_deaths", 0))]
	revived.alive = true
	revived.phoenix_used = true
	revived.hp = maxi(1, int(round(float(victim.max_hp) * 0.40)))
	revived.statuses = {}
	# duplicate() 会把原体的死亡标记一起带过来：清掉，让复活体作为全新单位重新计死。
	revived.erase("kill_reward_paid")
	revived.erase("killer_uid")
	var queue: Array = state.get("revive_queue", [])
	queue.append({"due": float(state.elapsed) + 0.1, "fighter": revived})
	state.revive_queue = queue
	var temp: Array = state.get("temporary_deaths", [])
	temp.append({"due": float(state.elapsed) + 3.1, "uid": str(revived.uid)})
	state.temporary_deaths = temp


static func _process_temporary_deaths(state: Dictionary) -> void:
	var queue: Array = state.get("temporary_deaths", [])
	if queue.is_empty():
		return
	var keep: Array = []
	for item in queue:
		if float(state.elapsed) >= float(item.get("due", 0.0)):
			var uid := str(item.get("uid", ""))
			for f in state.get("player", []) + state.get("enemy", []):
				if str(f.get("uid", "")) == uid and bool(f.get("alive", false)):
					DamageService.set_stat_state(state)
					DamageService.record_forced_hp_loss(f, -1, false)
					f.hp = 0
					f.alive = false
		else:
			keep.append(item)
	state.temporary_deaths = keep

static func _apply_element_set_burst(attacker: Dictionary, target: Dictionary, state: Dictionary) -> void:
	var opponents: Array = state.enemy if str(attacker.team) == "player" else state.player
	for o in opponents:
		if bool(o.get("alive", false)) and _can_target(attacker, o, opponents) and target.pos.distance_to(o.pos) <= 180.0:
			DamageService.apply_damage(o, maxi(1, int(round(float(o.max_hp) * 0.10))), true)


static func _apply_frenzy_assault(attacker: Dictionary, target: Dictionary) -> void:
	var target_uid := str(target.get("uid", ""))
	if str(attacker.get("frenzy_target_uid", "")) != target_uid:
		attacker.frenzy_target_uid = target_uid
		attacker.frenzy_stacks = 0
	attacker.frenzy_stacks = int(attacker.get("frenzy_stacks", 0)) + 1
	attacker.attack_speed = clampf(float(attacker.attack_speed) * 1.15, 0.25, 2.5)

static func _apply_defender_reaction(attacker: Dictionary, target: Dictionary, dealt: int) -> void:
	var d: Dictionary = target.get("def", {})
	var prev_source := DamageService.current_stat_source_uid()
	DamageService.set_stat_source_uid(str(target.get("uid", "")))
	if str(d.get("skill_id", "")) == "overload_counter" and dealt > 0 and bool(target.get("alive", false)):
		target.skill_stacks = int(target.get("skill_stacks", 0)) + 1
		if int(target.skill_stacks) >= int(d.get("hit_threshold", 8)):
			target.skill_stacks = 0
			DamageService.apply_damage(attacker, maxi(1, int(d.get("skill_damage", 300))), true)
			if RngService.rng.randf() < float(d.get("interrupt_chance", 0.25)):
				StatusEffectService.interrupt(attacker)
	if str(d.get("skill_id", "")) == "poison_reflect_armor_stack" and dealt > 0 and bool(target.get("alive", false)):
		DamageService.apply_damage(attacker, maxi(1, int(round(float(dealt) * float(d.get("reflect_taken_damage_pct", 0.12))))), true)
		StatusEffectService.add_poison(attacker)
		target.skill_stacks = mini(int(d.get("max_stacks", 10)), int(target.get("skill_stacks", 0)) + 1)
		target.defense = int(target.get("defense", 0)) + int(d.get("armor_per_hit", 2))
	DamageService.set_stat_source_uid(prev_source)


# 亡灵·母体处决的计数（理解 B）。每次己方棋子杀死一个敌人就给母灵 +1——
# 普攻/技能/AOE 都算，唯独母灵的处决技能杀死的不算（调用点已用 mother_execute_kill 拦掉）。
# 归属规则：按"击杀者"归属。组队模式只算母灵自己那位玩家（同 owner_key）的棋子击杀，
# 队友先不算；1v1 只有一个玩家，己方所有棋子的击杀都算。数满阈值就处决一个目标。
# 中毒/失血/衰减这类无来源死亡（killer_uid 为空）无法归属，不计数。
static func _credit_mother_kill(state: Dictionary, victim: Dictionary) -> void:
	var killer_uid := str(victim.get("killer_uid", ""))
	if killer_uid.is_empty():
		return
	var killer := _find_fighter_by_uid(state, killer_uid)
	if killer.is_empty():
		return
	# 只算跨队击杀：击杀者和死者不同队，才是"己方杀了敌人"。自相残杀不喂母灵。
	if str(killer.get("team", "")) == str(victim.get("team", "")):
		return
	var team_mode := state.has("owner_syn_by_key")
	var killer_is_player := str(killer.get("team", "")) == "player"
	var killer_owner := _owner_key(killer)
	var side: Array = state.get("player", []) if killer_is_player else state.get("enemy", [])
	for mother in side:
		if not bool(mother.get("alive", false)) or str(mother.get("def", {}).get("skill_id", "")) != "unique_death_execute":
			continue
		# 组队：只有击杀者所属玩家（同 owner_key）的母灵计数，队友不算。
		# 1v1：本方只有一个玩家，所有母灵都算。
		if team_mode and _owner_key(mother) != killer_owner:
			continue
		var owner_syn: Dictionary
		if team_mode:
			owner_syn = _owner_syn(state, _owner_key(mother))
		else:
			owner_syn = state.get("player_syn", {}) if killer_is_player else state.get("enemy_syn", {})
		var threshold := maxi(1, int(ceil(5.0 * SynergyService.safe_factor(owner_syn, "undead_threshold_mul", 1.0, 1.0))))
		var os := _owner_state(state, "mother_%s" % str(mother.get("uid", "")))
		os.mother_count = int(os.get("mother_count", 0)) + 1
		if int(os.mother_count) < threshold:
			continue
		os.mother_count = 0
		if killer_is_player:
			# 玩家母灵：优先处决自己路上的敌人，没有再退到全场敌人。
			_mother_execute_target(state, int(mother.get("lane", -1)), mother)
		else:
			# 敌方母灵（1v1 镜像）：处决玩家单位。
			_mother_execute_on(state, _alive(state.get("player", [])), mother)


static func _find_fighter_by_uid(state: Dictionary, uid: String) -> Dictionary:
	for f in state.get("player", []):
		if str(f.get("uid", "")) == uid:
			return f
	for f in state.get("enemy", []):
		if str(f.get("uid", "")) == uid:
			return f
	return {}


static func _mother_execute_target(state: Dictionary, lane: int, mother: Dictionary) -> void:
	var own_lane: Array = []
	var all_alive: Array = []
	for o in state.get("enemy", []):
		if bool(o.get("alive", false)):
			all_alive.append(o)
			if int(o.get("lane", -1)) == lane:
				own_lane.append(o)
	_mother_execute_on(state, own_lane if not own_lane.is_empty() else all_alive, mother)


static func _mother_execute_on(state: Dictionary, candidates: Array, mother: Dictionary) -> void:
	# 处决按星级掷骰：50% 拿一个 t1、35% 拿一个 t2、10% 拿一个 t3，抽中的星级没人
	# 就退到相邻星级。触发次数（=规则）由调用方的计数决定，这里不改。
	#
	# 书本 VFX 只跟"处决触发了"绑定，跟"有没有活目标"解耦：只要达到触发次数，
	# 母灵头上就一定放书。哪怕这一刻敌人已经被队友清光、或选中的目标先死了，
	# 事件照发（target_uid 留空），前端就把书放在母灵头上。
	if not state.has("visual_events") or typeof(state.visual_events) != TYPE_ARRAY:
		state.visual_events = []
	var target: Dictionary = {}
	if not candidates.is_empty():
		var roll := RngService.rng.randf()
		var wanted_tier := 1 if roll < 0.50 else (2 if roll < 0.85 else 3)
		target = _pick_execute_target(candidates, wanted_tier)
	# 事件永远发。三条路互不重叠：普通处决（目标已死）走 death_events；Boss 扣血
	# （目标存活）与无目标（target_uid 空）走前端的 mother_execute 分支。
	state.visual_events.append({"type":"mother_execute","source_uid":str(mother.get("uid","")),"target_uid":str(target.get("uid","")),"time":float(state.get("elapsed",0.0))})
	if target.is_empty():
		return
	if bool(target.get("def", {}).get("is_boss", false)):
		DamageService.apply_damage(target, maxi(1, int(round(float(target.max_hp) * 0.20))), true)
		return
	target.mother_execute_kill = true
	# Preserve the real Mother Wisp as the lethal damage source so the VFX
	# dispatcher can resolve the caster after the victim is removed.
	var previous_source_uid := DamageService.current_stat_source_uid()
	DamageService.set_stat_source_uid(str(mother.get("uid", "")))
	DamageService.apply_damage(target, int(target.hp), true)
	DamageService.set_stat_source_uid(previous_source_uid)

# 从候选里挑一个处决目标：先取抽中的星级，没有就往相邻星级退，
# 保证只要场上还有存活单位就一定能挑到一个。Boss 也可被挑中（交给调用方按
# is_boss 决定是处决还是扣血）。
static func _pick_execute_target(candidates: Array, wanted_tier: int) -> Dictionary:
	# 按到目标星级的距离排序：先同星级，再相邻，最后最远。同距离时保持随机。
	var order: Array = [wanted_tier]
	for distance in range(1, 3):
		order.append(wanted_tier + distance)
		order.append(wanted_tier - distance)
	for tier in order:
		if tier < 1 or tier > 3:
			continue
		var pool: Array = []
		for candidate in candidates:
			if int(candidate.get("def", {}).get("tier", 1)) == tier:
				pool.append(candidate)
		if not pool.is_empty():
			return pool[RngService.rng.randi() % pool.size()]
	# 星级数据缺失等异常情况的兜底：从全部候选里随便挑一个，仍然保证有人死。
	return candidates[RngService.rng.randi() % candidates.size()]


static func _apply_boss_attacker_passives(attacker: Dictionary) -> void:
	var d: Dictionary = attacker.get("def", {})
	if str(d.get("skill_id", "")) == "rage_stack":
		var old_stacks := int(attacker.get("skill_stacks", 0))
		var new_stacks := mini(int(d.get("max_stacks", 20)), old_stacks + 1)
		if new_stacks > old_stacks:
			attacker.skill_stacks = new_stacks
			attacker.atk = maxi(1, int(round(float(attacker.atk) * (1.0 + float(d.get("atk_per_hit", 0.03))))))
			attacker.attack_speed = clampf(float(attacker.attack_speed) + float(d.get("aspd_per_hit", 0.03)), 0.25, 2.5)
	elif str(d.get("skill_id", "")) == "blood_rage" and not bool(attacker.get("blood_rage_active", false)) and float(attacker.hp) / float(maxi(1, int(attacker.max_hp))) <= float(d.get("trigger_hp_pct", 0.35)):
		attacker.blood_rage_active = true
		attacker.atk = maxi(1, int(round(float(attacker.atk) * (1.0 + float(d.get("atk_bonus", 0.40))))))
		attacker.attack_speed = clampf(float(attacker.attack_speed) + float(d.get("aspd_bonus", 0.30)), 0.25, 2.5)


static func _apply_boss_attack_lifesteal(attacker: Dictionary, d: Dictionary, dealt: int) -> void:
	if dealt <= 0 or str(d.get("skill_id", "")) != "blood_rage" or not bool(attacker.get("blood_rage_active", false)):
		return
	_heal_unit(attacker, maxi(1, int(round(float(dealt) * float(d.get("lifesteal", 0.10))))))


static func _maybe_control_set_extra_debuff(attacker: Dictionary, target: Dictionary, _state: Dictionary, before_count: int) -> void:
	if not _f_has_set(attacker, "control"):
		return
	var after_count := _status_count(target)
	if after_count > before_count:
		_apply_control_set_random_debuff(target)


static func _apply_control_set_random_debuff(target: Dictionary) -> void:
	StatusEffectService.ensure_status(target)
	var choices: Array[String] = []
	for kind in StatusEffectService.DEBUFF_POOL:
		if not target.statuses.has(kind):
			choices.append(kind)
	if choices.is_empty():
		choices.assign(StatusEffectService.DEBUFF_POOL)
	var picked := choices[RngService.rng.randi() % choices.size()]
	match picked:
		"slow":
			StatusEffectService.add_status(target, "slow", 2.0, {"move_pct": 0.20, "attack_speed_pct": 0.20})
		"attack_down":
			StatusEffectService.add_status(target, "attack_down", 2.0, {"pct": 0.12})
		"silence":
			StatusEffectService.add_status(target, "silence", 1.0, {})
		"stun":
			StatusEffectService.add_status(target, "stun", 0.5, {})
		"poison":
			StatusEffectService.add_poison(target)
		"interrupt":
			StatusEffectService.interrupt(target)
		"bleed":
			StatusEffectService.add_bleed(target, 3.0, 0.06)



static func _process_revives(state: Dictionary) -> void:
	var queue: Array = state.get("revive_queue", [])
	if queue.is_empty():
		return
	var keep: Array = []
	for item in queue:
		if float(state.elapsed) >= float(item.get("due", 0.0)):
			var f: Dictionary = item.get("fighter", {})
			if str(f.get("def", {}).get("skill_id", "")) == "twin_revive" and not _has_living_twin_partner(f, state):
				state.log.append(TranslationServer.translate("log_twin_revive_fail"))
				continue
			f.alive = true
			f.statuses = {}
			f.hp = maxi(1, int(round(float(f.max_hp) * float(f.get("def", {}).get("revive_hp_pct", 0.30)))))
			f.shield = 0
			f.next_attack = float(state.elapsed) + 0.5
			# 凤凰涅槃：复活即满血并获得 3 秒无敌，撑到 temporary_deaths 的强制真死（+3.1s）。
			if bool(f.get("phoenix_used", false)):
				f.hp = int(f.max_hp)
				StatusEffectService.add_status(f, "invulnerable", 3.0, {})
			# 复活即清死亡标记：之后再被打死要能重新结算击杀金，也避免用到陈旧的致死来源。
			f.erase("kill_reward_paid")
			f.erase("killer_uid")
			if str(f.team) == "enemy":
				state.enemy.append(f)
			else:
				state.player.append(f)
			state.log.append(TranslationServer.translate("log_twin_revive_ok"))
		else:
			keep.append(item)
	state.revive_queue = keep


static func _has_living_twin_partner(fighter: Dictionary, state: Dictionary) -> bool:
	var group_id := str(fighter.get("twin_group_id", ""))
	var member_index := int(fighter.get("twin_member_index", -1))
	if group_id.is_empty() or member_index < 0:
		return false
	var team_units: Array = state.get("enemy", []) if str(fighter.get("team", "")) == "enemy" else state.get("player", [])
	for candidate in team_units:
		if not bool(candidate.get("alive", false)) or int(candidate.get("hp", 0)) <= 0:
			continue
		if str(candidate.get("twin_group_id", "")) == group_id and int(candidate.get("twin_member_index", -1)) != member_index:
			return true
	return false


static func _queue_twin_revive(victim: Dictionary, state: Dictionary) -> void:
	var d: Dictionary = victim.get("def", {})
	if str(d.get("skill_id", "")) != "twin_revive" or int(victim.get("revives_left", 0)) <= 0:
		return
	var revived := victim.duplicate(true)
	revived.revives_left = int(victim.get("revives_left", 0)) - 1
	revived.uid = "%s_revive_%d" % [str(victim.uid), int(state.get("total_deaths", 0))]
	var queue: Array = state.get("revive_queue", [])
	queue.append({"due": float(state.elapsed) + float(d.get("revive_delay", 5.0)), "fighter": revived})
	state.revive_queue = queue
	if not _has_living_twin_partner(victim, state):
		_cancel_twin_group_revives(state, str(victim.get("twin_group_id", "")))
		state.log.append(TranslationServer.translate("log_twin_all_dead"))
		return
	state.log.append(TranslationServer.translate("log_twin_revive_delay") % float(d.get("revive_delay", 5.0)))


static func _cancel_twin_group_revives(state: Dictionary, group_id: String) -> void:
	if group_id.is_empty():
		return
	var keep: Array = []
	for item in state.get("revive_queue", []):
		var queued: Dictionary = item.get("fighter", {})
		if str(queued.get("twin_group_id", "")) != group_id:
			keep.append(item)
	state.revive_queue = keep


static func _apply_human_last_stand(state: Dictionary, _p_alive: Array) -> void:
	# (5) 人族·背水一战: per OWNER. Counts only the owner's own normal units, so
	# it fires when a single player is down to their last unit (allies ignored).
	if state.has("owner_syn_by_key"):
		for lane in 3:
			_owner_last_stand(state, "player", lane)
			if str(state.get("kind", "")) == "pvp":
				_owner_last_stand(state, "enemy", lane)
		return
	_team_last_stand_1v1(state, "player")
	_team_last_stand_1v1(state, "enemy")


static func _team_last_stand_1v1(state: Dictionary, team: String) -> void:
	var syn: Dictionary = _team_syn(state, team)
	var used_key := "human_last_stand_used" if team == "player" else "enemy_human_last_stand_used"
	if not bool(syn.get("human_last_stand", false)) or bool(state.get(used_key, false)):
		return
	var side: Array = state.get("player", []) if team == "player" else state.get("enemy", [])
	var normals := []
	for f in side:
		if bool(f.get("alive", false)) and int(f.get("hp", 0)) > 0 and not _ignores_treasure(f):
			normals.append(f)
	if normals.size() != 1:
		return
	_trigger_last_stand(state, normals[0])
	state[used_key] = true


static func _owner_last_stand(state: Dictionary, team: String, lane: int) -> void:
	var key := "%s_%d" % [team, lane]
	if not bool(_owner_syn(state, key).get("human_last_stand", false)):
		return
	var os := _owner_state(state, key)
	if bool(os.get("last_stand_used", false)):
		return
	var side: Array = state.get("player", []) if team == "player" else state.get("enemy", [])
	var normals := []
	for f in side:
		if bool(f.get("alive", false)) and int(f.get("hp", 0)) > 0 and int(f.get("lane", -1)) == lane and not _ignores_treasure(f):
			normals.append(f)
	if normals.size() != 1:
		return
	_trigger_last_stand(state, normals[0])
	os.last_stand_used = true


static func _trigger_last_stand(state: Dictionary, last: Dictionary) -> void:
	last.max_hp = maxi(1, int(round(float(last.max_hp) * 2.0)))
	DamageService.begin_stat_context(state, last)
	_heal_unit(last, maxi(1, int(round(float(last.max_hp) * 0.50))))
	DamageService.clear_stat_context()
	last.defense = maxi(0, int(round(float(last.get("defense", last.get("def", 0))) * 2.0)))
	last.atk = maxi(1, int(round(float(last.atk) * 2.0)))
	last.attack_speed = clampf(float(last.attack_speed) * 2.0, 0.25, 2.5)
	last.crit_bonus = maxf(float(last.get("crit_bonus", 0.0)), 1.0)
	last.crit_dmg_bonus = maxf(float(last.get("crit_dmg_bonus", 0.0)), 0.50)
	state.log.append(TranslationServer.translate("log_last_stand") % str(last.get("name", TranslationServer.translate("name_last_unit"))))


static func _apply_blood_rampage_lifesteal(attacker: Dictionary, d: Dictionary, dealt: int) -> void:
	if dealt <= 0 or str(d.get("skill_id", "")) != "blood_rampage":
		return
	var missing := 1.0 - float(attacker.hp) / float(maxi(1, int(attacker.max_hp)))
	var steps := int(floor(missing / float(d.get("hp_step", 0.10))))
	var pct := float(steps) * float(d.get("lifesteal_per_step", 0.05))
	if pct > 0.0:
		_heal_unit(attacker, maxi(1, int(round(float(dealt) * pct))))

