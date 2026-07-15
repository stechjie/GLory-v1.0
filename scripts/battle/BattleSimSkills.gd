class_name BattleSimSkills
extends BattleSimShared

static func _apply_death_servant_aura(servant: Dictionary, team_units: Array, d: Dictionary) -> void:
	var amount := int(d.get("ally_def_bonus", 3))
	var duration := float(d.get("ally_def_duration", 5.0))
	if amount <= 0 or duration <= 0.0:
		return
	var slot := int(servant.get("slot", -99))
	for a in team_units:
		if not bool(a.get("alive", false)) or a == servant:
			continue
		if abs(int(a.get("slot", -99)) - slot) <= 1:
			StatusEffectService.add_status(a, "defense_flat_up", duration, {"amount": amount})

static func _skill_lowest_ally_heal(_caster: Dictionary, allies: Array, d: Dictionary) -> void:
	var target := _lowest_hp_ratio(allies)
	if target.is_empty(): return
	var heal := maxi(1, int(float(target.max_hp) * float(d.get("heal_pct", 0.06))))
	_heal_unit(target, heal)
	if RngService.rng.randf() < float(d.get("cleanse_chance", 0.25)):
		StatusEffectService.clear_negative_statuses(target)


static func _skill_nearest_ally_bless(caster: Dictionary, allies: Array, d: Dictionary) -> void:
	var target := _nearest(caster, allies.filter(func(a): return a != caster and bool(a.get("alive", false))))
	if target.is_empty(): return
	target.atk = maxi(1, int(round(float(target.atk) * (1.0 + float(d.get("atk_bonus", 0.12))))))
	target.attack_speed = clampf(float(target.attack_speed) + float(d.get("aspd_bonus", 0.15)), 0.25, 2.5)
	StatusEffectService.clear_negative_statuses(target)


static func _skill_nearby_ally_heal_buff(caster: Dictionary, allies: Array, d: Dictionary) -> void:
	for a in allies:
		if not bool(a.get("alive", false)) or caster.pos.distance_to(a.pos) > 180.0: continue
		_heal_unit(a, maxi(1, int(float(a.max_hp) * float(d.get("heal_pct", 0.08)))))
		a.atk = maxi(1, int(round(float(a.atk) * (1.0 + float(d.get("atk_bonus", 0.10))))))
		a.attack_speed = clampf(float(a.attack_speed) + float(d.get("aspd_bonus", 0.15)), 0.25, 2.5)
		StatusEffectService.clear_negative_statuses(a)


static func _skill_random_attribute_bolt(caster: Dictionary, opponents: Array, d: Dictionary) -> void:
	var alive := opponents.filter(func(o): return bool(o.get("alive", false)) and _can_target(caster, o, opponents))
	if alive.is_empty():
		return
	var target: Dictionary = alive[RngService.rng.randi() % alive.size()]
	DamageService.apply_damage(target, maxi(1, int(round(float(caster.atk) * float(d.get("damage_atk_pct", 3.0))))), false)
	_apply_attribute_effect(["fire", "ice", "thunder", "poison"][RngService.rng.randi() % 4], caster, target)


static func _skill_judgement(caster: Dictionary, opponents: Array, d: Dictionary) -> void:
	var target := _nearest(caster, opponents)
	if target.is_empty(): return
	DamageService.apply_damage(target, maxi(1, int(float(caster.atk) * float(d.get("damage_atk_pct", 2.2)))), false)
	caster.skill_stacks = mini(int(d.get("max_stacks", 5)), int(caster.get("skill_stacks", 0)) + 1)
	caster.defense = int(round(float(caster.defense) * (1.0 + float(d.get("def_stack_pct", 0.06)))))


static func _skill_archangel(_caster: Dictionary, allies: Array, d: Dictionary) -> void:
	var alive := _alive(allies)
	if alive.is_empty(): return
	var target: Dictionary = alive[RngService.rng.randi() % alive.size()]
	StatusEffectService.add_status(target, "damage_reduction", float(d.get("duration", 6.0)), {"pct": float(d.get("damage_reduction", 0.5))})


static func _skill_god_king(caster: Dictionary, opponents: Array, d: Dictionary) -> void:
	for o in opponents:
		if not bool(o.get("alive", false)) or not _can_target(caster, o, opponents): continue
		var dmg := int(float(caster.atk) * float(d.get("damage_atk_pct", 1.6))) + int(float(o.max_hp) * float(d.get("max_hp_bonus_pct", 0.08)))
		DamageService.apply_damage(o, maxi(1, dmg), false)


static func _skill_silence_bolt(caster: Dictionary, opponents: Array, d: Dictionary, state: Dictionary) -> void:
	var target := _nearest(caster, opponents)
	if target.is_empty(): return
	var dur := _dark_duration(float(d.get("silence_sec", 1.2)), caster, state)
	StatusEffectService.add_status(target, "silence", dur, {})
	DamageService.apply_damage(target, maxi(1, int(float(caster.atk) * float(d.get("damage_atk_pct", 1.7)))), false)


static func _skill_fear(caster: Dictionary, opponents: Array, d: Dictionary, state: Dictionary) -> void:
	var target := _nearest(caster, opponents)
	if target.is_empty(): return
	var dur := _dark_duration(float(d.get("fear_sec", 1.5)), caster, state)
	StatusEffectService.add_status(target, "stun", dur, {})
	var away: Vector2 = (target.pos - caster.pos).normalized()
	target.pos += away * 90.0


static func _skill_stun(caster: Dictionary, opponents: Array, d: Dictionary, state: Dictionary) -> void:
	var target := _nearest(caster, opponents)
	if target.is_empty(): return
	StatusEffectService.add_status(target, "stun", _dark_duration(float(d.get("stun_sec", 1.0)), caster, state), {})


static func _skill_black_hole(caster: Dictionary, opponents: Array, d: Dictionary, state: Dictionary) -> void:
	var dur := _dark_duration(float(d.get("pull_sec", 2.0)), caster, state)
	for o in opponents:
		if not bool(o.get("alive", false)) or not _can_target(caster, o, opponents) or caster.pos.distance_to(o.pos) > 220.0: continue
		StatusEffectService.add_status(o, "stun", dur, {})
		o.pos = o.pos.lerp(caster.pos, 0.45)
		DamageService.apply_damage(o, maxi(1, int(float(caster.atk) * float(d.get("damage_atk_pct", 2.2)))), false)


static func _skill_blink_low_def_backline(caster: Dictionary, allies: Array, opponents: Array, d: Dictionary, state: Dictionary) -> bool:
	var target := BattleSimulator._lowest_def_backline(caster, opponents)
	if target.is_empty():
		return false
	var side := -1.0 if str(caster.get("team", "")) == "player" else 1.0
	caster.pos = target.pos + Vector2(28.0 * side, 0.0)
	var was_alive := bool(target.get("alive", false))
	DamageService.apply_damage(target, maxi(1, int(round(float(caster.atk) * float(d.get("damage_atk_pct", 2.0))))), false)
	BattleSimulator._handle_attack_kill(caster, target, state, allies, opponents, was_alive)
	return was_alive and not bool(target.get("alive", false))


static func _skill_front_cone_stun(caster: Dictionary, opponents: Array, d: Dictionary, state: Dictionary) -> void:
	var target := _nearest(caster, opponents)
	if target.is_empty():
		return
	DamageService.apply_damage(target, maxi(1, int(round(float(caster.atk) * float(d.get("damage_atk_pct", 1.5))))), false)
	StatusEffectService.add_status(target, "stun", _dark_duration(float(d.get("stun_sec", 1.0)), caster, state), {})

static func _skill_element_meteor(caster: Dictionary, opponents: Array, d: Dictionary) -> void:
	var target := _nearest(caster, opponents)
	if target.is_empty():
		return
	for o in opponents:
		if bool(o.get("alive", false)) and _can_target(caster, o, opponents) and target.pos.distance_to(o.pos) <= 180.0:
			DamageService.apply_damage(o, maxi(1, int(d.get("skill_damage", 120))), true)
			_apply_attribute_effect(str(d.get("element", "fire")), caster, o)


static func _skill_holy_purify(_caster: Dictionary, allies: Array, d: Dictionary) -> void:
	for a in allies:
		if not bool(a.get("alive", false)):
			continue
		a.statuses = {}
		_heal_unit(a, maxi(1, int(round(float(a.max_hp) * float(d.get("heal_pct", 0.12))))))
		a.shield = int(a.get("shield", 0)) + maxi(1, int(round(float(a.max_hp) * float(d.get("shield_pct", 0.10)))))


static func _skill_apocalypse_charge(caster: Dictionary, state: Dictionary, d: Dictionary) -> void:
	if caster.has("apocalypse_due"):
		return
	var shield := maxi(1, int(round(float(caster.max_hp) * float(d.get("charge_shield_pct", 0.10)))))
	caster.shield = int(caster.get("shield", 0)) + shield
	caster.apocalypse_due = float(state.elapsed) + float(d.get("charge_sec", 2.0))
	caster.apocalypse_damage_atk_pct = float(d.get("damage_atk_pct", 2.5))
	caster.apocalypse_ignore_def = bool(d.get("ignore_def", true))
	state.log.append(TranslationServer.translate("log_arbiter_charging"))


static func _skill_mirror_clone(caster: Dictionary, state: Dictionary, d: Dictionary) -> void:
	var missing := 1.0 - (float(caster.hp) / float(maxi(1, int(caster.max_hp))))
	var should_have := int(floor(missing / float(d.get("clone_per_missing_hp_pct", 0.25))))
	var have := int(caster.get("mirror_clones_spawned", 0))
	if should_have <= have:
		return
	for idx in range(have + 1, should_have + 1):
		var clone := caster.duplicate(true)
		clone.uid = "%s_mirror_%d" % [str(caster.team), idx]
		clone.hp = maxi(1, int(round(float(caster.max_hp) * float(d.get("clone_hp_pct", 0.30)))))
		clone.max_hp = clone.hp
		clone.atk = maxi(1, int(round(float(caster.atk) * float(d.get("clone_atk_pct", 0.40)))))
		clone.defense = int(d.get("clone_def", 0))
		clone.alive = true
		clone.statuses = {}
		clone.skill_ready = 9999.0
		if str(caster.team) == "enemy":
			state.enemy.append(clone)
		else:
			state.player.append(clone)
	caster.mirror_clones_spawned = should_have


static func _skill_bubble_dream(caster: Dictionary, allies: Array, opponents: Array, d: Dictionary) -> void:
	var ally := _lowest_hp_ratio(allies)
	if not ally.is_empty():
		_heal_unit(ally, int(d.get("heal", 80)))
	var target := _nearest(caster, opponents)
	if not target.is_empty():
		StatusEffectService.add_status(target, "slow", 3.0, {"move_pct": float(d.get("slow_pct", 0.30)), "attack_speed_pct": float(d.get("slow_pct", 0.30))})
		DamageService.apply_damage(target, int(d.get("burst_damage", 70)), true)


static func _skill_holy_song(_caster: Dictionary, allies: Array, d: Dictionary) -> void:
	for a in allies:
		if not bool(a.get("alive", false)):
			continue
		_heal_unit(a, maxi(1, int(round(float(a.max_hp) * float(d.get("heal_pct", 0.15))))))
		if bool(d.get("cleanse_control", true)):
			for key in ["slow", "attack_down", "silence", "stun", "interrupt", "defense_down", "defense_flat_down", "heal_reduction"]:
				if a.has("statuses") and typeof(a.statuses) == TYPE_DICTIONARY:
					a.statuses.erase(key)


static func _skill_twin_strike(caster: Dictionary, state: Dictionary, d: Dictionary) -> void:
	var clone := caster.duplicate(true)
	clone.uid = "%s_twin_%d" % [str(caster.uid), int(state.get("total_deaths", 0))]
	clone.hp = maxi(1, int(round(float(caster.max_hp) * float(d.get("clone_hp_pct", 0.30)))))
	clone.max_hp = clone.hp
	clone.atk = maxi(1, int(round(float(caster.atk) * float(d.get("clone_atk_pct", 0.40)))))
	clone.statuses = {}
	clone.skill_ready = 9999.0
	if str(caster.team) == "player": state.player.append(clone)
	else: state.enemy.append(clone)


static func _skill_arrow_rain(caster: Dictionary, opponents: Array, d: Dictionary) -> void:
	var targets := _nearest_n(caster, opponents, int(d.get("targets", 5)))
	for o in targets:
		DamageService.apply_damage(o, maxi(1, int(round(float(caster.atk) * 0.85))), false)


static func _skill_steel_order(caster: Dictionary, allies: Array, d: Dictionary) -> void:
	var targets := _nearest_n(caster, allies, int(d.get("buff_targets", 3)))
	for a in targets:
		if not bool(a.get("alive", false)):
			continue
		StatusEffectService.add_status(a, "damage_reduction", float(d.get("duration", 8.0)), {"pct": float(d.get("damage_reduction", 0.20))})
		StatusEffectService.add_status(a, "speed_bonus", float(d.get("duration", 8.0)), {"pct": float(d.get("aspd_bonus", 0.20))})
		StatusEffectService.add_status(a, "control_time_reduction", float(d.get("duration", 8.0)), {"pct": float(d.get("control_time_reduction", 0.30))})


static func _skill_time_slow(caster: Dictionary, opponents: Array, d: Dictionary) -> void:
	StatusEffectService.add_status(caster, "dodge_bonus", 1.2, {"pct": 0.50})
	for o in opponents:
		if bool(o.get("alive", false)) and _can_target(caster, o, opponents):
			StatusEffectService.add_status(o, "slow", float(d.get("duration", 5.0)), {"move_pct": float(d.get("slow_pct", 0.35)), "attack_speed_pct": float(d.get("slow_pct", 0.35))})


static func _skill_gold_charge(caster: Dictionary, opponents: Array, d: Dictionary) -> void:
	var target := _nearest(caster, opponents)
	if target.is_empty(): return
	caster.pos = target.pos + Vector2(-24, 0) if str(caster.team) == "player" else target.pos + Vector2(24, 0)
	DamageService.apply_damage(target, int(d.get("skill_damage", 120)), true)
	StatusEffectService.add_status(target, "stun", float(d.get("stun_sec", 1.2)), {})


static func _skill_king_aura(caster: Dictionary, allies: Array, d: Dictionary) -> void:
	var radius := float(d.get("aura_radius", 2)) * ATTACK_RANGE_SCALE
	for a in allies:
		if bool(a.get("alive", false)) and caster.pos.distance_to(a.pos) <= radius:
			StatusEffectService.add_status(a, "speed_bonus", 2.2, {"pct": float(d.get("ally_aspd_bonus", 0.25))})
			a.crit_bonus = maxf(float(a.get("crit_bonus", 0.0)), float(d.get("ally_crit_bonus", 0.15)))


static func _skill_shell_guard(caster: Dictionary, d: Dictionary) -> void:
	StatusEffectService.add_status(caster, "damage_reduction", float(d.get("duration", 5.0)), {"pct": float(d.get("reduction", 0.50))})
