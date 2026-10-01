class_name CrimsonCombat
extends BattleSimShared

# Crimson combat rules are kept here so the existing races keep their hit order
# and random-number stream. All timers use the simulator's elapsed seconds.

static func tick_fighter(fighter: Dictionary, elapsed: float) -> void:
	if not fighter.has("crimson_drum_atk") and not fighter.has("crimson_drum_speed") and not fighter.has("crimson_resonance_stacks"):
		return
	for key in ["crimson_drum_atk", "crimson_drum_speed"]:
		if not fighter.has(key):
			continue
		var active: Array = []
		for layer in fighter.get(key, []):
			if float((layer as Dictionary).get("until", 0.0)) > elapsed:
				active.append(layer)
		fighter[key] = active
	if float(fighter.get("crimson_resonance_until", 0.0)) <= elapsed:
		fighter.crimson_resonance_stacks = 0


static func pulse(state: Dictionary) -> void:
	var elapsed := float(state.get("elapsed", 0.0))
	var next := float(state.get("crimson_next_pulse", 2.0))
	if elapsed + 0.0001 < next:
		return
	state.crimson_next_pulse = next + 5.0
	for fighter: Dictionary in state.get("player", []) + state.get("enemy", []):
		if not bool(fighter.get("alive", false)) or str(fighter.get("def", {}).get("race", "")) != "crimson":
			continue
		if not bool(_resolve_syn(fighter, state).get("crimson_pulse", false)):
			continue
		fighter.skill_ready = maxf(elapsed, float(fighter.get("skill_ready", 0.0)) - 1.0)
		StatusEffectService.clear_negative_statuses(fighter)
		StatusEffectService.add_status(fighter, "crimson_pulse", 3.6, {"pct": 0.10})
		DamageService.begin_stat_context(state, fighter)
		_heal_unit(fighter, maxi(1, int(round(float(fighter.get("max_hp", 1)) * 0.06))))
		DamageService.clear_stat_context()


static func apply_status(caster: Dictionary, target: Dictionary, kind: String, duration: float, params: Dictionary, state: Dictionary) -> void:
	var syn := _resolve_syn(caster, state)
	if bool(syn.get("crimson_duration", false)):
		if kind in ["silence", "stun", "interrupt", "ice_affected"]:
			duration += minf(duration * 0.20, 0.5)
		else:
			duration *= 1.20
	StatusEffectService.add_status(target, kind, duration, params)
	if StatusEffectService.has_status(target, kind):
		resonance(caster, state)


static func resonance(caster: Dictionary, state: Dictionary) -> void:
	if str(caster.get("def", {}).get("race", "")) != "crimson" or not bool(_resolve_syn(caster, state).get("crimson_resonance", false)):
		return
	caster.crimson_resonance_stacks = mini(10, int(caster.get("crimson_resonance_stacks", 0)) + 1)
	caster.crimson_resonance_until = float(state.get("elapsed", 0.0)) + 4.0


static func passive_attack(attacker: Dictionary, target: Dictionary, state: Dictionary) -> int:
	var d: Dictionary = attacker.get("def", {})
	match str(d.get("skill_id", "")):
		"current_hp_strike":
			if not bool(target.get("alive", false)):
				return 0
			var before := int(attacker.get("crimson_target_hp_before", target.get("hp", 0)))
			var target_def: Dictionary = target.get("def", {})
			var boss := bool(target_def.get("is_boss", false)) or str(target.get("id", "")).begins_with("boss_")
			var pct := float(d.get("boss_hp_pct", 0.05)) if boss else float(d.get("current_hp_pct", 0.10))
			DamageService.set_hit_context("basic", false, "crimson", "current_hp_strike")
			var dealt := DamageService.apply_damage(target, maxi(1, int(round(float(before) * pct))), false)
			if before < int(target.get("max_hp", 1)) * float(d.get("execute_threshold", 0.0)):
				dealt += DamageService.apply_damage(target, maxi(1, int(round(float(attacker.get("atk", 1)) * float(d.get("execute_atk_pct", 0.0))))), false)
			return dealt
		"stacking_def_break":
			if bool(target.get("alive", false)) and RngService.rng.randf() < float(d.get("break_chance", 0.5)):
				target.crimson_def_break = int(target.get("crimson_def_break", 0)) + int(d.get("break_amount", 2))
				resonance(attacker, state)
		"team_random_stack":
			var allies: Array = state.get("player", []) if str(attacker.get("team", "")) == "player" else state.get("enemy", [])
			var roll := RngService.rng.randi_range(0, 2)
			if roll == 2:
				for ally: Dictionary in allies:
					if bool(ally.get("alive", false)):
						_heal_unit(ally, maxi(1, int(round(float(ally.get("max_hp", 1)) * float(d.get("heal_pct", 0.03))))))
			else:
				var key := "crimson_drum_atk" if roll == 0 else "crimson_drum_speed"
				var applied := false
				for ally: Dictionary in allies:
					if not bool(ally.get("alive", false)):
						continue
					var layers: Array = ally.get(key, [])
					if layers.size() >= int(d.get("max_stacks", 5)):
						layers.pop_front()
					layers.append({"until": float(state.get("elapsed", 0.0)) + float(d.get("stack_duration", 3.0)) * (1.20 if bool(_resolve_syn(attacker, state).get("crimson_duration", false)) else 1.0), "pct": float(d.get("stack_pct", 0.03))})
					ally[key] = layers
					applied = true
				if applied:
					resonance(attacker, state)
	return 0


static func skill_dancer(caster: Dictionary, allies: Array, d: Dictionary, state: Dictionary) -> void:
	var pool: Array = []
	for ally: Dictionary in allies:
		if bool(ally.get("alive", false)):
			pool.append(ally)
	for _i in mini(int(d.get("ally_count", 1)), pool.size()):
		var ally: Dictionary = pool.pop_at(RngService.rng.randi_range(0, pool.size() - 1))
		var effect := RngService.rng.randi_range(0, 2)
		if effect == 0:
			ally.skill_ready = maxf(float(state.get("elapsed", 0.0)), float(ally.get("skill_ready", 0.0)) - 2.0)
			resonance(caster, state)
		else:
			apply_status(caster, ally, "crimson_attack" if effect == 1 else "crimson_speed", float(d.get("buff_duration", 3.0)), {"pct": float(d.get("buff_pct", 0.20))}, state)
		caster.vfx_skill_target_uid = str(ally.get("uid", ""))


static func skill_icey(caster: Dictionary, opponents: Array, d: Dictionary, state: Dictionary) -> void:
	var target := _select_target(caster, opponents)
	if target.is_empty() or not bool(target.get("alive", false)):
		return
	caster.vfx_skill_target_uid = str(target.get("uid", ""))
	DamageService.apply_damage(target, maxi(1, int(round(float(caster.get("atk", 1)) * StatusEffectService.attack_multiplier(caster) * float(d.get("damage_atk_pct", 1.70))))), false)
	if bool(target.get("alive", false)):
		apply_status(caster, target, "ice_affected", float(d.get("ice_duration", 3.0)), {}, state)


static func skill_lantern(caster: Dictionary, opponents: Array, d: Dictionary, state: Dictionary) -> void:
	var center := _select_target(caster, opponents)
	if center.is_empty() or not bool(center.get("alive", false)):
		return
	var uids := PackedStringArray()
	for target: Dictionary in opponents:
		if not bool(target.get("alive", false)) or not _can_target(caster, target, opponents) or center.pos.distance_to(target.pos) > float(d.get("aoe_radius", 144.0)):
			continue
		uids.append(str(target.get("uid", "")))
		DamageService.apply_damage(target, maxi(1, int(round(float(caster.get("atk", 1)) * StatusEffectService.attack_multiplier(caster) * float(d.get("damage_atk_pct", 1.30))))), false)
		if bool(target.get("alive", false)):
			apply_status(caster, target, "silence", float(d.get("silence_duration", 2.5)), {}, state)
	caster.vfx_skill_target_uid = ",".join(uids)


static func pierce_targets(attacker: Dictionary, primary: Dictionary, opponents: Array) -> Array:
	var direction: Vector2 = primary.pos - attacker.pos
	if direction.length_squared() < 0.001:
		return []
	direction = direction.normalized()
	var first_distance: float = (primary.pos - attacker.pos).dot(direction)
	var candidates: Array = []
	for target: Dictionary in opponents:
		if target == primary or not bool(target.get("alive", false)) or not _can_target(attacker, target, opponents):
			continue
		var offset: Vector2 = target.pos - attacker.pos
		var along: float = offset.dot(direction)
		var sideways: float = absf(offset.cross(direction))
		if along >= first_distance and sideways <= 36.0:
			candidates.append(target)
	candidates.sort_custom(func(a, b):
		var da: float = (a.pos - attacker.pos).dot(direction)
		var db: float = (b.pos - attacker.pos).dot(direction)
		return da < db if not is_equal_approx(da, db) else str(a.get("uid", "")) < str(b.get("uid", "")))
	return candidates.slice(0, mini(3, candidates.size()))
